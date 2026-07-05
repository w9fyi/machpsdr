import Foundation

/// A standard FT8/FT4 operating channel: band + dial frequency.
public struct FTxChannel: Sendable, Identifiable, Equatable {
    /// Band identifier matching the app's band IDs ("20m", "40m", ...).
    public let bandID: String
    public let mode: FTxProtocolMode
    /// USB dial (suppressed-carrier) frequency in Hz.
    public let dialFrequencyHz: UInt32
    /// True for the primary (most popular) channel on the band.
    public let isPrimary: Bool

    public var id: String { "\(bandID)-\(mode.rawValue)-\(dialFrequencyHz)" }

    public var displayName: String {
        let mhz = Double(dialFrequencyHz) / 1_000_000
        return String(format: "%@ — %.4f MHz%@", bandID, mhz, isPrimary ? "" : " (alt)")
    }
}

/// Standard FT8 and FT4 dial frequencies per band (IARU band plans /
/// WSJT-X defaults).
public enum FTxBandPlan {

    public static let channels: [FTxChannel] = [
        // FT8 primary dial frequencies
        FTxChannel(bandID: "160m", mode: .ft8, dialFrequencyHz: 1_840_000, isPrimary: true),
        FTxChannel(bandID: "80m", mode: .ft8, dialFrequencyHz: 3_573_000, isPrimary: true),
        FTxChannel(bandID: "60m", mode: .ft8, dialFrequencyHz: 5_357_000, isPrimary: true),
        FTxChannel(bandID: "40m", mode: .ft8, dialFrequencyHz: 7_074_000, isPrimary: true),
        FTxChannel(bandID: "30m", mode: .ft8, dialFrequencyHz: 10_136_000, isPrimary: true),
        FTxChannel(bandID: "20m", mode: .ft8, dialFrequencyHz: 14_074_000, isPrimary: true),
        FTxChannel(bandID: "17m", mode: .ft8, dialFrequencyHz: 18_100_000, isPrimary: true),
        FTxChannel(bandID: "15m", mode: .ft8, dialFrequencyHz: 21_074_000, isPrimary: true),
        FTxChannel(bandID: "12m", mode: .ft8, dialFrequencyHz: 24_915_000, isPrimary: true),
        FTxChannel(bandID: "10m", mode: .ft8, dialFrequencyHz: 28_074_000, isPrimary: true),
        FTxChannel(bandID: "6m", mode: .ft8, dialFrequencyHz: 50_313_000, isPrimary: true),
        // FT8 popular alternates (DXpedition / overflow)
        FTxChannel(bandID: "40m", mode: .ft8, dialFrequencyHz: 7_071_000, isPrimary: false),
        FTxChannel(bandID: "20m", mode: .ft8, dialFrequencyHz: 14_071_000, isPrimary: false),
        FTxChannel(bandID: "6m", mode: .ft8, dialFrequencyHz: 50_323_000, isPrimary: false),
        // FT4
        FTxChannel(bandID: "80m", mode: .ft4, dialFrequencyHz: 3_568_000, isPrimary: true),
        FTxChannel(bandID: "40m", mode: .ft4, dialFrequencyHz: 7_047_500, isPrimary: true),
        FTxChannel(bandID: "30m", mode: .ft4, dialFrequencyHz: 10_140_000, isPrimary: true),
        FTxChannel(bandID: "20m", mode: .ft4, dialFrequencyHz: 14_080_000, isPrimary: true),
        FTxChannel(bandID: "17m", mode: .ft4, dialFrequencyHz: 18_104_000, isPrimary: true),
        FTxChannel(bandID: "15m", mode: .ft4, dialFrequencyHz: 21_140_000, isPrimary: true),
        FTxChannel(bandID: "12m", mode: .ft4, dialFrequencyHz: 24_919_000, isPrimary: true),
        FTxChannel(bandID: "10m", mode: .ft4, dialFrequencyHz: 28_180_000, isPrimary: true),
        FTxChannel(bandID: "6m", mode: .ft4, dialFrequencyHz: 50_318_000, isPrimary: true),
    ]

    /// Channels for a given protocol, in band order.
    public static func channels(for mode: FTxProtocolMode) -> [FTxChannel] {
        channels.filter { $0.mode == mode }
    }

    /// The primary channel for a band + protocol, if one exists.
    public static func primaryChannel(bandID: String, mode: FTxProtocolMode) -> FTxChannel? {
        channels.first { $0.bandID == bandID && $0.mode == mode && $0.isPrimary }
    }
}
