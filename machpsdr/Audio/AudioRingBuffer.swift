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
    /// is safe to call directly from an audio tap/render callback.
    func write(_ samples: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        for k in 0..<count {
            storage[writeIndex] = samples[k]
            writeIndex = (writeIndex + 1) % capacity
            if available < capacity {
                available += 1
            } else {
                // Buffer full: advance read index, dropping the oldest sample.
                readIndex = (readIndex + 1) % capacity
            }
        }
    }

    /// Consumer: copy up to `count` samples into `destination`, zero-filling any
    /// shortfall. Returns the number of real (non-silence) samples provided.
    @discardableResult
    func read(into destination: UnsafeMutablePointer<Float>, count: Int) -> Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let real = min(count, available)
        for i in 0..<real {
            destination[i] = storage[readIndex]
            readIndex = (readIndex + 1) % capacity
        }
        available -= real
        if real < count {
            for i in real..<count { destination[i] = 0 }
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
}
