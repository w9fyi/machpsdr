import Foundation

/// A ham band with its frequency edges, a default dial frequency, and conventional
/// mode. Used by band-select shortcuts and to auto-detect the band while tuning.
nonisolated struct Band: Identifiable, Hashable {
    let id: String
    let name: String
    let lowerHz: UInt32
    let upperHz: UInt32
    let frequencyHz: UInt32   // default dial frequency
    let mode: RadioMode

    func contains(_ hz: UInt32) -> Bool { hz >= lowerHz && hz <= upperHz }

    static let all: [Band] = [
        Band(id: "160m", name: "160 m", lowerHz: 1_800_000,  upperHz: 2_000_000,  frequencyHz: 1_900_000,  mode: .lsb),
        Band(id: "80m",  name: "80 m",  lowerHz: 3_500_000,  upperHz: 4_000_000,  frequencyHz: 3_800_000,  mode: .lsb),
        Band(id: "60m",  name: "60 m",  lowerHz: 5_330_000,  upperHz: 5_410_000,  frequencyHz: 5_357_000,  mode: .usb),
        Band(id: "40m",  name: "40 m",  lowerHz: 7_000_000,  upperHz: 7_300_000,  frequencyHz: 7_175_000,  mode: .lsb),
        Band(id: "30m",  name: "30 m",  lowerHz: 10_100_000, upperHz: 10_150_000, frequencyHz: 10_125_000, mode: .cwu),
        Band(id: "20m",  name: "20 m",  lowerHz: 14_000_000, upperHz: 14_350_000, frequencyHz: 14_225_000, mode: .usb),
        Band(id: "17m",  name: "17 m",  lowerHz: 18_068_000, upperHz: 18_168_000, frequencyHz: 18_130_000, mode: .usb),
        Band(id: "15m",  name: "15 m",  lowerHz: 21_000_000, upperHz: 21_450_000, frequencyHz: 21_300_000, mode: .usb),
        Band(id: "12m",  name: "12 m",  lowerHz: 24_890_000, upperHz: 24_990_000, frequencyHz: 24_950_000, mode: .usb),
        Band(id: "10m",  name: "10 m",  lowerHz: 28_000_000, upperHz: 29_700_000, frequencyHz: 28_400_000, mode: .usb),
        Band(id: "6m",   name: "6 m",   lowerHz: 50_000_000, upperHz: 54_000_000, frequencyHz: 50_125_000, mode: .usb),
    ]

    /// The band containing `hz`, or nil if the frequency is between bands.
    static func band(for hz: UInt32) -> Band? {
        all.first { $0.contains(hz) }
    }
}
