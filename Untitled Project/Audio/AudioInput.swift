import Foundation
import AVFoundation
import AudioToolbox

/// Captures microphone audio via AVAudioEngine, converts it to 48 kHz mono Float,
/// and writes it into a ring buffer for the transmit path to consume.
///
/// `nonisolated` so the connection actor / network thread can own it.
nonisolated final class AudioInput: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let ring: AudioRingBuffer
    private let targetRate: Double = 48_000
    /// Selected input device UID, or nil to use the macOS default input.
    private let deviceUID: String?

    init(ring: AudioRingBuffer, deviceUID: String? = nil) {
        self.ring = ring
        self.deviceUID = deviceUID
    }

    func start() throws {
        let input = engine.inputNode
        // Route the input node's HAL unit to the chosen device (before reading its
        // format or starting). Unresolved/nil UID leaves the system default in place.
        if let deviceUID, let devID = AudioDevices.deviceID(forUID: deviceUID), let au = input.audioUnit {
            var dev = devID
            let status = AudioUnitSetProperty(au,
                                              kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global,
                                              0,
                                              &dev,
                                              UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr {
                NSLog("AudioInput: could not select input device \(deviceUID) (status \(status)); using default.")
            }
        }
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
              let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: targetRate,
                                               channels: 1,
                                               interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw NSError(domain: "AudioInput", code: -1)
        }

        let ringRef = ring
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            let ratio = targetFormat.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

            var error: NSError?
            var provided = false
            converter.convert(to: outBuffer, error: &error) { _, status in
                if provided { status.pointee = .noDataNow; return nil }
                provided = true
                status.pointee = .haveData
                return buffer
            }

            guard let channel = outBuffer.floatChannelData?[0] else { return }
            let count = Int(outBuffer.frameLength)
            guard count > 0 else { return }
            var samples = [Float](repeating: 0, count: count)
            for i in 0..<count { samples[i] = channel[i] }
            ringRef.write(samples)
        }

        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
