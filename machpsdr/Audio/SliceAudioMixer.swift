import Foundation
import AVFoundation
import AudioToolbox

/// Mixes the mono audio of several receive slices into one stereo output device.
/// Each slice has an independent gain-less mono ring (volume is applied upstream in
/// WDSP) plus a stereo *pan*: pan −1 = hard left, 0 = center (equal in both), +1 =
/// hard right. Slice outputs are summed per channel and clamped to avoid overflow.
///
/// The render callback pulls one block from each enabled slice ring every cycle, so
/// every active slice is drained at the device rate regardless of pan.
///
/// `nonisolated` so it can be owned and driven from the connection actor / network thread.
nonisolated final class SliceAudioMixer: @unchecked Sendable {
    /// Upper bound on slice channels the mixer can hold (≥ app's max slices).
    static let capacity = 16
    static let sampleRate: Double = Double(WDSPRadio.audioRate)

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let deviceUID: String?

    private let scratchCapacity = 8192
    private let scratch: UnsafeMutablePointer<Float>

    // Per-slice mix state, guarded by `lock`. Indexed by slice number.
    private var lock = os_unfair_lock()
    private var rings: [AudioRingBuffer?]
    private var panL: [Float]
    private var panR: [Float]
    private var enabled: [Bool]

    // Diagnostics: frames rendered and real (non-silence) samples pulled per slice,
    // logged ~1×/sec. real << 48000/s for an enabled slice means the ring is underrunning.
    private var dbgFrames = 0
    private var dbgReal: [Int]

    init(deviceUID: String? = nil) {
        self.deviceUID = deviceUID
        rings = [AudioRingBuffer?](repeating: nil, count: Self.capacity)
        panL = [Float](repeating: 1, count: Self.capacity)
        panR = [Float](repeating: 1, count: Self.capacity)
        enabled = [Bool](repeating: false, count: Self.capacity)
        dbgReal = [Int](repeating: 0, count: Self.capacity)

        scratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchCapacity)
        scratch.initialize(repeating: 0, count: scratchCapacity)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 2) else {
            NSLog("SliceAudioMixer: could not create \(Int(Self.sampleRate)) Hz stereo format; mixer disabled.")
            return
        }
        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList in
            self?.render(frameCount: frameCount, audioBufferList: audioBufferList) ?? noErr
        }
        sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    /// Converts a pan (−1…+1) into left/right weights. Center is full in both channels
    /// (matching the old mono-duplicated behavior); hard pan zeroes the opposite side.
    static func panWeights(_ pan: Float) -> (left: Float, right: Float) {
        let p = max(-1, min(1, pan))
        return (min(1, 1 - p), min(1, 1 + p))
    }

    /// Registers (or updates) a slice's audio source.
    func setSlice(_ index: Int, ring: AudioRingBuffer, pan: Float, enabled on: Bool) {
        guard index >= 0, index < Self.capacity else { return }
        let w = Self.panWeights(pan)
        os_unfair_lock_lock(&lock)
        rings[index] = ring
        panL[index] = w.left
        panR[index] = w.right
        enabled[index] = on
        os_unfair_lock_unlock(&lock)
    }

    /// Updates just the pan of an existing slice.
    func setPan(_ index: Int, pan: Float) {
        guard index >= 0, index < Self.capacity else { return }
        let w = Self.panWeights(pan)
        os_unfair_lock_lock(&lock)
        panL[index] = w.left
        panR[index] = w.right
        os_unfair_lock_unlock(&lock)
    }

    /// Removes a slice from the mix (its ring is no longer drained).
    func removeSlice(_ index: Int) {
        guard index >= 0, index < Self.capacity else { return }
        os_unfair_lock_lock(&lock)
        enabled[index] = false
        rings[index] = nil
        os_unfair_lock_unlock(&lock)
    }

    func start() throws {
        if let deviceUID, let devID = AudioDevices.deviceID(forUID: deviceUID), let au = engine.outputNode.audioUnit {
            var dev = devID
            let status = AudioUnitSetProperty(au,
                                              kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global,
                                              0,
                                              &dev,
                                              UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr {
                NSLog("SliceAudioMixer: could not select output device \(deviceUID) (status \(status)); using default.")
            }
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.stop()
    }

    deinit {
        scratch.deallocate()
    }

    // MARK: - Render

    private func render(frameCount: AVAudioFrameCount,
                        audioBufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let frames = Int(frameCount)
        let n = min(frames, scratchCapacity)
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)

        // Standard stereo format is non-interleaved: buffer 0 = L, buffer 1 = R.
        guard buffers.count >= 2,
              let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
              let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else {
            for buffer in buffers {
                if let d = buffer.mData?.assumingMemoryBound(to: Float.self) {
                    for i in 0..<frames { d[i] = 0 }
                }
            }
            return noErr
        }

        for i in 0..<frames { left[i] = 0; right[i] = 0 }

        os_unfair_lock_lock(&lock)
        for idx in 0..<Self.capacity {
            guard enabled[idx], let ring = rings[idx] else { continue }
            let real = ring.read(into: scratch, count: n)
            dbgReal[idx] += real
            let pl = panL[idx], pr = panR[idx]
            for i in 0..<n {
                let s = scratch[i]
                left[i] += s * pl
                right[i] += s * pr
            }
        }
        dbgFrames += n
        var logLine: String?
        if dbgFrames >= Int(Self.sampleRate) {   // ~1×/sec
            let parts = (0..<Self.capacity).filter { enabled[$0] }.map { "s\($0)=\(dbgReal[$0])" }
            logLine = "MIX: rendered=\(dbgFrames)f realSamples/s [\(parts.joined(separator: " "))]"
            dbgFrames = 0
            for idx in 0..<Self.capacity { dbgReal[idx] = 0 }
        }
        os_unfair_lock_unlock(&lock)
        if let logLine { NSLog(logLine) }

        // Guard against summed overflow when several loud slices overlap.
        for i in 0..<frames {
            left[i] = max(-1, min(1, left[i]))
            right[i] = max(-1, min(1, right[i]))
        }
        return noErr
    }
}
