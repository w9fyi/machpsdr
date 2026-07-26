import Foundation

/// Transmit audio processing presets. Higher tiers compress harder for more talk
/// power; DX+ also enables CESSB (controlled-envelope SSB) for maximum average power.
nonisolated enum TXProcessing: String, CaseIterable, Identifiable, Sendable, Codable {
    case off = "Off"
    case normal = "Normal"
    case dx = "DX"
    case dxPlus = "DX+"

    var id: String { rawValue }
    var compressorOn: Bool { self != .off }
    var compressorGain: Double {
        switch self {
        case .off:    return 0
        case .normal: return 3
        case .dx:     return 7
        case .dxPlus: return 10
        }
    }
    var usesCESSB: Bool { self == .dxPlus }
}
