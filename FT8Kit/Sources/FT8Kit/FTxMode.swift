import CFT8

/// FT8-family digital protocol variants supported by the codec.
public enum FTxProtocolMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case ft8 = "FT8"
    case ft4 = "FT4"

    public var id: String { rawValue }

    /// Length of one transmit/receive cycle in seconds.
    public var slotSeconds: Double {
        switch self {
        case .ft8: return 15.0
        case .ft4: return 7.5
        }
    }

    /// Duration of a single FSK symbol in seconds.
    public var symbolPeriod: Double {
        switch self {
        case .ft8: return 0.160
        case .ft4: return 0.048
        }
    }

    /// Number of channel symbols in one transmission.
    public var toneCount: Int {
        switch self {
        case .ft8: return 79   // FT8_NN
        case .ft4: return 105  // FT4_NN
        }
    }

    /// GFSK smoothing bandwidth factor.
    public var symbolBT: Float {
        switch self {
        case .ft8: return 2.0
        case .ft4: return 1.0
        }
    }

    /// Tone spacing in Hz (= 1 / symbol period).
    public var toneSpacingHz: Double { 1.0 / symbolPeriod }

    /// On-air duration of one transmission in seconds (12.64 s FT8, 5.04 s FT4).
    public var transmitSeconds: Double { Double(toneCount) * symbolPeriod }

    /// Nominal delay from the slot boundary to the start of transmission.
    public var txStartDelaySeconds: Double { 0.5 }

    var cProtocol: ftx_protocol_t {
        switch self {
        case .ft8: return FTX_PROTOCOL_FT8
        case .ft4: return FTX_PROTOCOL_FT4
        }
    }
}
