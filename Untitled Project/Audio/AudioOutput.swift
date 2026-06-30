import Foundation
import AVFoundation
import AudioToolbox

/// Plays the demodulated audio stream through the default output device using
/// AVAudioEngine. A render callback pulls mono samples from the ring buffer and
/// duplicates them across output channels.
///
/// `nonisolated` so it can be owned and driven from the connection actor / network thread.
nonisolated final class AudioOutput: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let ring: AudioRingBuffer
    private var sourceNode: AVAudioSourceNode?
    /// Selected output device UID, or nil to use the macOS default output.
    private let deviceUID: String?

    static let sampleRate: Double = Double(Demodulator.audioRate)
    private let scratchCapacity = 8192
    private let scratch: UnsafeMutablePointer<Float>

    init(ring: AudioRingBuffer, deviceUID: String? = nil) {
        self.ring = ring
        self.deviceUID = deviceUID
        scratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchCapacity)
        scratch.initialize(repeating: 0, count: scratchCapacity)

        let format = AVAudioFormat(standardFormatWithSampleRate: AudioOutput.sampleRate, channels: 2)!
        let capacity = scratchCapacity
        let scratchPtr = scratch
        let ringRef = ring

        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let frames = Int(frameCount)
            let n = min(frames, capacity)
            ringRef.read(into: scratchPtr, count: n)
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for buffer in buffers {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for i in 0..<n { data[i] = scratchPtr[i] }
                if frames > n {
                    for i in n..<frames { data[i] = 0 }
                }
            }
            return noErr
        }

        sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    func start() throws {
        // Route the engine output to the chosen device before starting; an
        // unresolved/nil UID leaves the system default output in place.
        if let deviceUID, let devID = AudioDevices.deviceID(forUID: deviceUID), let au = engine.outputNode.audioUnit {
            var dev = devID
            let status = AudioUnitSetProperty(au,
                                              kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global,
                                              0,
                                              &dev,
                                              UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr {
                NSLog("AudioOutput: could not select output device \(deviceUID) (status \(status)); using default.")
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
}
