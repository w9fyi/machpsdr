import Foundation
import Darwin

/// The HPSDR/openHPSDR board reported by a radio during Protocol 1 discovery.
/// Device IDs come from byte 10 of the discovery reply. The ANAN-10E is built on
/// the Hermes board and therefore reports as `.hermes`.
///
/// Marked `nonisolated` so it can be constructed on the background discovery thread
/// even though the project defaults to MainActor isolation.
nonisolated enum HPSDRBoard: Equatable, Hashable {
    case metis
    case hermes
    case griffin
    case angelia
    case orion
    case hermesLite
    case orion2
    case unknown(UInt8)

    init(deviceID: UInt8) {
        switch deviceID {
        case 0: self = .metis
        case 1: self = .hermes
        case 2: self = .griffin
        case 4: self = .angelia
        case 5: self = .orion
        case 6: self = .hermesLite
        case 10: self = .orion2
        default: self = .unknown(deviceID)
        }
    }

    /// A human-readable name. ANAN model names in parentheses where the board is shared.
    var displayName: String {
        switch self {
        case .metis: return "Metis"
        case .hermes: return "Hermes (ANAN-10 / 10E / 100B)"
        case .griffin: return "Griffin"
        case .angelia: return "Angelia (ANAN-100D)"
        case .orion: return "Orion (ANAN-200D)"
        case .hermesLite: return "Hermes Lite"
        case .orion2: return "Orion2 (ANAN-7000 / 8000)"
        case .unknown(let id): return "Unknown board (ID \(id))"
        }
    }
}

/// Whether the radio is idle or already streaming I/Q data.
nonisolated enum RadioStatus: Equatable, Hashable {
    case idle
    case sending
}

/// A radio found on the local network via openHPSDR Protocol 1 discovery.
nonisolated struct DiscoveredRadio: Identifiable, Hashable {
    /// Stable identity across rescans (a fresh UUID per scan made SwiftUI treat every
    /// rediscovered radio as a new list row).
    var id: String { macAddress }
    let ipAddress: String
    let macAddress: String
    let board: HPSDRBoard
    /// Raw firmware/gateware version byte (byte 9 of the reply).
    let firmwareVersionRaw: Int
    let status: RadioStatus

    /// Version formatted as "major.minor" (e.g. raw 33 -> "3.3").
    var firmwareVersion: String {
        "\(firmwareVersionRaw / 10).\(firmwareVersionRaw % 10)"
    }

    init?(reply buffer: [UInt8], from address: sockaddr_in) {
        // Valid replies start with 0xEF 0xFE and a status byte of 0x02 (idle) or 0x03 (sending).
        guard buffer.count >= 11,
              buffer[0] == 0xEF, buffer[1] == 0xFE,
              buffer[2] == 0x02 || buffer[2] == 0x03 else {
            return nil
        }
        self.macAddress = (3...8)
            .map { String(format: "%02X", buffer[$0]) }
            .joined(separator: ":")
        self.firmwareVersionRaw = Int(buffer[9])
        self.board = HPSDRBoard(deviceID: buffer[10])
        self.status = buffer[2] == 0x03 ? .sending : .idle
        self.ipAddress = DiscoveredRadio.ipString(from: address)
    }

    private static func ipString(from address: sockaddr_in) -> String {
        var addr = address
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addr.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buffer)
    }
}
