import Foundation
import FT8Kit

/// Background worker that turns the 48 kHz slice-audio tap into per-slot
/// FT8/FT4 decodes. Runs its own thread (like `RadioConnection.IO`): it
/// aligns to UTC slot boundaries, drains the tap ring every 100 ms,
/// decimates 48 kHz → 12 kHz, feeds the monitor, and decodes shortly before
/// each slot ends (so a reply can be keyed at the very next boundary).
nonisolated final class FT8SlotWorker: @unchecked Sendable {

    private let mode: FTxProtocolMode
    private let ring: AudioRingBuffer
    /// Called on the worker thread at every slot boundary.
    private let onSlotStart: @Sendable (_ slotIndex: Int) -> Void
    /// Called on the worker thread once per slot with that slot's decodes.
    private let onDecodes: @Sendable (_ slotIndex: Int, _ slotStart: Date, _ decodes: [FT8Decode]) -> Void

    private var lock = os_unfair_lock()
    private var _running = false
    private var running: Bool {
        get { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return _running }
        set { os_unfair_lock_lock(&lock); _running = newValue; os_unfair_lock_unlock(&lock) }
    }

    init(mode: FTxProtocolMode, ring: AudioRingBuffer,
         onSlotStart: @escaping @Sendable (Int) -> Void,
         onDecodes: @escaping @Sendable (Int, Date, [FT8Decode]) -> Void) {
        self.mode = mode
        self.ring = ring
        self.onSlotStart = onSlotStart
        self.onDecodes = onDecodes
    }

    func start() {
        guard !running else { return }
        running = true
        let thread = Thread { [self] in run() }
        thread.name = "FT8.decode"
        thread.stackSize = 1 << 20
        thread.start()
    }

    func stop() {
        running = false
    }

    private func run() {
        let slotLen = mode.slotSeconds
        // Decode early enough to render + key a reply at the next boundary.
        // An FT8 signal starting on time ends 13.14 s in; 13.65 s covers
        // late starters while leaving ~1.3 s of headroom.
        let decodeAt = slotLen - 1.35
        let monitor = FT8Monitor(mode: mode)
        var chunk = [Float](repeating: 0, count: 4_800)   // 100 ms at 48 kHz
        var mono12 = [Float]()
        mono12.reserveCapacity(1_400)

        // Boxcar 4:1 decimation state carried across reads.
        var decSum: Float = 0
        var decFill = 0

        // Align to the next slot boundary, discarding stale audio.
        waitForBoundary(slotLen: slotLen)
        ring.clear()

        while running {
            let slotIndex = Int(Date().timeIntervalSince1970 / slotLen + 0.5)
            let slotStart = Double(slotIndex) * slotLen
            onSlotStart(slotIndex)
            monitor.reset()
            decSum = 0
            decFill = 0
            var decoded = false

            while running {
                let t = Date().timeIntervalSince1970 - slotStart
                if t >= slotLen - 0.03 { break }

                // Drain whatever the DSP thread has produced.
                let got = chunk.withUnsafeMutableBufferPointer {
                    ring.read(into: $0.baseAddress!, count: $0.count)
                }
                if got > 0, !decoded {
                    mono12.removeAll(keepingCapacity: true)
                    for i in 0..<got {
                        decSum += chunk[i]
                        decFill += 1
                        if decFill == 4 {
                            mono12.append(decSum * 0.25)
                            decSum = 0
                            decFill = 0
                        }
                    }
                    monitor.feed(mono12)
                }

                if !decoded, t >= decodeAt || monitor.isFull {
                    decoded = true
                    let results = monitor.decode()
                    onDecodes(slotIndex, Date(timeIntervalSince1970: slotStart), results)
                }

                Thread.sleep(forTimeInterval: 0.1)
            }
            if running, !decoded {
                onDecodes(slotIndex, Date(timeIntervalSince1970: slotStart), monitor.decode())
            }
        }
    }

    private func waitForBoundary(slotLen: Double) {
        let now = Date().timeIntervalSince1970
        let next = (floor(now / slotLen) + 1) * slotLen
        while running, Date().timeIntervalSince1970 < next {
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
}
