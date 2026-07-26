import Foundation
import CoreMIDI

/// Listens to all MIDI sources (e.g. the Lynovation CTR2-MIDI) and surfaces:
///   - a rolling log of incoming messages (a "monitor" so a device reveals its mapping), and
///   - a relative tuning callback driven by the VFO encoder.
///
/// The CTR2-MIDI's VFO knob is a relative encoder, by default Control Change 100 on
/// channel 1: value 1 = step up, value ~126/127 = step down, with several messages
/// sent per detent when spun quickly.
@MainActor
@Observable
final class MIDIManager {
    struct LogEntry: Identifiable {
        let id = UUID()
        let text: String
    }

    struct ControlChange: Equatable {
        let channel: UInt8
        let number: UInt8
    }

    private(set) var log: [LogEntry] = []
    private(set) var sourceNames: [String] = []
    private(set) var isRunning = false
    private(set) var lastControlChange: ControlChange?

    /// Control Change number treated as the VFO tuning encoder.
    private(set) var tuningCC: UInt8
    /// Called with a signed number of detents (+ = up, - = down) when the knob turns.
    var onTuneStep: ((Int) -> Void)?

    private let defaultsKey = "midiTuningCC"
    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()

    init() {
        let saved = UserDefaults.standard.object(forKey: defaultsKey) == nil ? 100 : UserDefaults.standard.integer(forKey: defaultsKey)
        tuningCC = UInt8(clamping: saved)
    }

    func setTuningCC(_ cc: UInt8) {
        tuningCC = cc
        UserDefaults.standard.set(Int(cc), forKey: defaultsKey)
        append("Tuning CC set to #\(cc)")
    }

    func learnTuningCCFromLastMessage() {
        guard let lastControlChange else { return }
        setTuningCC(lastControlChange.number)
    }

    /// Creates the MIDI client/port and connects to every current source.
    func start() {
        guard !isRunning else { return }

        var status = MIDIClientCreateWithBlock("machpsdr" as CFString, &client) { _ in }
        guard status == noErr else {
            append("MIDI client error: \(status)")
            return
        }

        let receive: MIDIReadBlock = { [weak self] listPtr, _ in
            // Runs on Core MIDI's high-priority thread. Extract raw messages, hop to main.
            var messages: [[UInt8]] = []
            let count = Int(listPtr.pointee.numPackets)
            guard let packetOffset = MemoryLayout<MIDIPacketList>.offset(of: \.packet) else { return }
            var packet = UnsafeMutableRawPointer(mutating: listPtr)
                .advanced(by: packetOffset)
                .assumingMemoryBound(to: MIDIPacket.self)
            for _ in 0..<count {
                let length = Int(packet.pointee.length)
                withUnsafeBytes(of: packet.pointee.data) { raw in
                    var i = 0
                    while i < length {
                        let statusByte = raw[i]
                        guard statusByte >= 0x80 else { i += 1; continue }
                        let highNibble = statusByte & 0xF0
                        let size = (highNibble == 0xC0 || highNibble == 0xD0) ? 2 : 3
                        if i + size <= length {
                            messages.append((0..<size).map { raw[i + $0] })
                        }
                        i += size
                    }
                }
                packet = MIDIPacketNext(packet)
            }
            let captured = messages
            Task { @MainActor [weak self] in self?.handle(captured) }
        }

        status = MIDIInputPortCreateWithBlock(client, "machpsdr-in" as CFString, &inputPort, receive)
        guard status == noErr else {
            append("MIDI port error: \(status)")
            return
        }

        connectAllSources()
        isRunning = true
        if sourceNames.isEmpty {
            append("No MIDI sources found. Plug in the CTR2-MIDI and Rescan.")
        } else {
            append("Listening to: \(sourceNames.joined(separator: ", "))")
        }
    }

    /// Reconnects to the current set of MIDI sources (e.g. after hot-plugging).
    func rescan() {
        guard isRunning else { start(); return }
        connectAllSources()
        append("Rescanned. Sources: \(sourceNames.isEmpty ? "none" : sourceNames.joined(separator: ", "))")
    }

    private func connectAllSources() {
        sourceNames.removeAll()
        let count = MIDIGetNumberOfSources()
        for i in 0..<count {
            let source = MIDIGetSource(i)
            MIDIPortConnectSource(inputPort, source, nil)
            sourceNames.append(Self.displayName(of: source))
        }
    }

    private static func displayName(of object: MIDIObjectRef) -> String {
        var unmanaged: Unmanaged<CFString>?
        let status = MIDIObjectGetStringProperty(object, kMIDIPropertyDisplayName, &unmanaged)
        if status == noErr, let cf = unmanaged?.takeRetainedValue() {
            return cf as String
        }
        return "Unknown source"
    }

    private func handle(_ messages: [[UInt8]]) {
        for message in messages {
            let description = Self.describe(message)
            append(description)
            guard message.count == 3 else { continue }
            let opcode = message[0] & 0xF0
            if opcode == 0xB0 {
                lastControlChange = ControlChange(channel: (message[0] & 0x0F) + 1, number: message[1])
            }
            // Control Change on the tuning encoder -> relative steps.
            if opcode == 0xB0, message[1] == tuningCC {
                // CTR2 relative encoder: value is a signed velocity offset from 64
                // (65 = +1 slow, 74 = +10 fast, 63 = -1, 54 = -10). value > 64 = up.
                let delta = max(-32, min(32, Int(message[2]) - 64))
                if delta != 0 { onTuneStep?(delta) }
            }
        }
    }

    private static func describe(_ message: [UInt8]) -> String {
        guard let status = message.first else { return "empty" }
        let channel = (status & 0x0F) + 1
        switch status & 0xF0 {
        case 0xB0 where message.count == 3:
            return "CC  ch\(channel)  #\(message[1]) = \(message[2])"
        case 0x90 where message.count == 3:
            return "NoteOn  ch\(channel)  #\(message[1])  vel \(message[2])"
        case 0x80 where message.count == 3:
            return "NoteOff ch\(channel)  #\(message[1])"
        default:
            return message.map { String(format: "%02X", $0) }.joined(separator: " ")
        }
    }

    private func append(_ text: String) {
        log.append(LogEntry(text: text))
        if log.count > 12 { log.removeFirst(log.count - 12) }
    }
}
