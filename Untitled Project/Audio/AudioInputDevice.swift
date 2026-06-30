import Foundation
import CoreAudio

/// A selectable CoreAudio device (input or output). `id` is the device's stable UID
/// string (persists across replug/reboot, unlike the transient `AudioDeviceID`).
nonisolated struct AudioDevice: Identifiable, Hashable, Sendable {
    let id: String          // kAudioDevicePropertyDeviceUID
    let name: String
    let deviceID: AudioDeviceID
}

/// CoreAudio helpers for listing input/output devices and resolving a UID back to a
/// live `AudioDeviceID`. `nonisolated` so both the UI (MainActor) and the audio
/// engine (off-actor) can call it.
nonisolated enum AudioDevices {
    /// Hardware devices exposing at least one input channel.
    static func inputDevices() -> [AudioDevice] { devices(scope: kAudioObjectPropertyScopeInput) }

    /// Hardware devices exposing at least one output channel.
    static func outputDevices() -> [AudioDevice] { devices(scope: kAudioObjectPropertyScopeOutput) }

    /// Resolves a persisted UID to a current `AudioDeviceID`, or nil if the device is
    /// no longer present (caller should fall back to the system default device).
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allDeviceIDs().first { stringProperty($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    // MARK: - Enumeration

    private static func devices(scope: AudioObjectPropertyScope) -> [AudioDevice] {
        allDeviceIDs().compactMap { id in
            guard channelCount(id, scope: scope) > 0,
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else { return nil }
            let name = stringProperty(id, kAudioDevicePropertyDeviceNameCFString) ?? "Unknown Device"
            return AudioDevice(id: uid, name: name, deviceID: id)
        }
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &dataSize) == noErr else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &dataSize, &ids) == noErr else { return [] }
        return ids
    }

    /// Channel count a device exposes in the given scope (input or output).
    private static func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ id: AudioDeviceID,
                                       _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        return status == noErr ? value as String : nil
    }
}
