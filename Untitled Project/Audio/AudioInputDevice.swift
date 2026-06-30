import Foundation
import CoreAudio

/// A selectable CoreAudio input device. `id` is the device's stable UID string
/// (persists across replug/reboot, unlike the transient `AudioDeviceID`).
nonisolated struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let id: String          // kAudioDevicePropertyDeviceUID
    let name: String
    let deviceID: AudioDeviceID
}

/// CoreAudio helpers for listing input devices and resolving a UID back to a
/// live `AudioDeviceID`. `nonisolated` so both the UI (MainActor) and the audio
/// engine (off-actor) can call it.
nonisolated enum AudioDevices {
    /// All hardware devices that expose at least one input channel.
    static func inputDevices() -> [AudioInputDevice] {
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

        return ids.compactMap { id in
            guard hasInputChannels(id),
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else { return nil }
            let name = stringProperty(id, kAudioDevicePropertyDeviceNameCFString) ?? "Unknown Device"
            return AudioInputDevice(id: uid, name: name, deviceID: id)
        }
    }

    /// Resolves a persisted UID to a current `AudioDeviceID`, or nil if that
    /// device is no longer present (caller should fall back to the default input).
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        inputDevices().first { $0.id == uid }?.deviceID
    }

    /// True if the device has one or more input channels in its input scope.
    private static func hasInputChannels(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return false }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                    alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return false }

        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }

    /// Reads a CFString device property (name, UID) as a Swift `String`.
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
