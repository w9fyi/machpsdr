import Foundation
import Observation

/// A snapshot of the operator settings remembered per band (Thetis-style band
/// memory): AGC, mic gain, drive, and the TX processing preset. Each band can
/// carry different values, e.g. a higher AGC-T on 20 m than on noisy 80 m.
nonisolated struct BandSettings: Codable, Equatable {
    var agcMode: Int
    var agcThreshold: Double
    var micGain: Double
    var driveLevel: Double
    var txProcessing: TXProcessing
}

/// Stores a `BandSettings` snapshot per band ID, persisted to UserDefaults.
/// RadioSession writes through on every settings change and recalls a band's
/// snapshot when tuning crosses into it.
@MainActor
@Observable
final class BandSettingsStore {
    private var values: [String: BandSettings] = [:]
    private let defaultsKey = "bandSettings"

    init() { load() }

    func settings(for bandID: String) -> BandSettings? {
        values[bandID]
    }

    func save(_ settings: BandSettings, for bandID: String) {
        guard values[bandID] != settings else { return }
        values[bandID] = settings
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        if let encoded = try? JSONEncoder().encode(values) {
            UserDefaults.standard.set(encoded, forKey: defaultsKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: BandSettings].self, from: data) else { return }
        values = decoded
    }
}
