import Foundation

/// A single-producer / single-consumer float ring buffer bridging the network
/// thread (which writes demodulated audio) and the CoreAudio render thread
/// (which reads it). Guarded by an `os_unfair_lock`; the critical sections are
/// short copies. Overruns drop the oldest samples; underruns read silence.
///
/// `nonisolated` so both threads can touch it under the project's MainActor-default isolation.
nonisolated final class AudioRingBuffer: @unchecked Sendable {
    private var storage: [Float]
    private let capacity: Int
    private var readIndex = 0
    private var writeIndex = 0
    private var available = 0
    private var lock = os_unfair_lock()

    /// Default capacity holds ~0.5 s at 48 kHz, plenty of slack against jitter.
    init(capacity: Int = 24_000) {
        self.capacity = capacity
        self.storage = [Float](repeating: 0, count: capacity)
    }

    /// Producer: append samples, overwriting the oldest if full.
    func write(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        samples.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            write(base, count: buf.count)
        }
    }

    /// Producer: append `count` samples from a raw pointer. Allocation-free, so it
    /// is safe to call directly from an audio tap/render callback. Copies at most
    /// two contiguous segments (memcpy) so the lock is held only briefly.
    func write(_ samples: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        storage.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            if count >= capacity {
                // Larger than the ring: only the newest `capacity` samples survive.
                base.update(from: samples + (count - capacity), count: capacity)
                writeIndex = 0
                readIndex = 0
                available = capacity
                return
            }
            let first = min(count, capacity - writeIndex)
            (base + writeIndex).update(from: samples, count: first)
            if count > first {
                base.update(from: samples + first, count: count - first)
            }
            writeIndex += count
            if writeIndex >= capacity { writeIndex -= capacity }
            if available + count > capacity {
                // Buffer full: the write overwrote the oldest samples.
                readIndex = writeIndex
                available = capacity
            } else {
                available += count
            }
        }
    }

    /// Consumer: copy up to `count` samples into `destination`, zero-filling any
    /// shortfall. Returns the number of real (non-silence) samples provided.
    @discardableResult
    func read(into destination: UnsafeMutablePointer<Float>, count: Int) -> Int {
        guard count > 0 else { return 0 }
        os_unfair_lock_lock(&lock)
        let real = min(count, available)
        if real > 0 {
            storage.withUnsafeBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                let first = min(real, capacity - readIndex)
                destination.update(from: base + readIndex, count: first)
                if real > first {
                    (destination + first).update(from: base, count: real - first)
                }
            }
            readIndex += real
            if readIndex >= capacity { readIndex -= capacity }
            available -= real
        }
        os_unfair_lock_unlock(&lock)
        if real < count {
            (destination + real).update(repeating: 0, count: count - real)
        }
        return real
    }

    /// Discards all buffered samples (e.g. on retune to avoid stale audio).
    func clear() {
        os_unfair_lock_lock(&lock)
        readIndex = 0
        writeIndex = 0
        available = 0
        os_unfair_lock_unlock(&lock)
    }

    /// Discards all buffered samples and refills with `count` samples of silence.
    /// The producer and consumer run at the same nominal rate, so a ring left empty
    /// never rebuilds slack: every consumer read races the next producer write and
    /// scheduling jitter turns into audible dropouts until clock drift (a few
    /// samples/second) slowly accumulates a cushion. Priming restores the cushion
    /// instantly, trading `count` samples of latency for jitter immunity.
    func reset(primingSilence count: Int) {
        os_unfair_lock_lock(&lock)
        let n = max(0, min(count, capacity))
        if n > 0 {
            storage.withUnsafeMutableBufferPointer { buf in
                buf.baseAddress?.update(repeating: 0, count: n)
            }
        }
        readIndex = 0
        writeIndex = n == capacity ? 0 : n
        available = n
        os_unfair_lock_unlock(&lock)
    }
}
