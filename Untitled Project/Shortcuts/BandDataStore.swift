import Foundation
import Observation

/// Stores the per-band open-collector (OC) output values used for amplifier band
/// data, plus a master enable. Persisted to UserDefaults. Defaults to standard
/// Yaesu BCD codes (assuming OC1–4 are wired to the amp's Band A–D).
@MainActor
@Observable
final class BandDataStore {
    var enabled = false
    private var values: [String: UInt8] = [:]
    private let defaultsKey = "bandDataConfig"

    /// Band-data OC codes calibrated against the user's Expert 2K-FA amplifier.
    static let defaultCodes: [String: UInt8] = [
        "6m": 5, "10m": 6, "12m": 7, "15m": 8, "17m": 9, "20m": 10,
        "30m": 11, "40m": 12, "80m": 13, "160m": 14, "60m": 15,
    ]

    init() { load() }

    func value(for bandID: String) -> UInt8 {
        values[bandID] ?? BandDataStore.defaultCodes[bandID] ?? 0
    }

    func setValue(_ value: UInt8, for bandID: String) {
        values[bandID] = value & 0x7F
        save()
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        save()
    }

    // MARK: - Persistence

    private struct Persisted: Codable {
        var enabled: Bool
        var values: [String: UInt8]
    }

    private func save() {
        let data = Persisted(enabled: enabled, values: values)
        if let encoded = try? JSONEncoder().encode(data) {
            UserDefaults.standard.set(encoded, forKey: defaultsKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        enabled = decoded.enabled
        values = decoded.values
    }
}
