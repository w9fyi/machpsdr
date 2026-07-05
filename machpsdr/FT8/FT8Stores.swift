import Foundation
import FT8Kit

/// Persists the operator's station details (callsign, grid, QTH, zones).
@MainActor @Observable final class StationConfigStore {
    var info: StationInfo {
        didSet { save() }
    }

    private let defaultsKey = "stationInfo"

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode(StationInfo.self, from: data) {
            info = saved
        } else {
            info = StationInfo()
        }
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(info) {
            UserDefaults.standard.set(encoded, forKey: defaultsKey)
        }
    }
}

/// Persists the list of callsign alerts (watch list).
@MainActor @Observable final class FT8AlertStore {
    private(set) var alerts: [CallsignAlert] = []

    private let defaultsKey = "ft8CallsignAlerts"

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode([CallsignAlert].self, from: data) {
            alerts = saved
        }
    }

    func add(callsign: String, bandID: String?) {
        let call = callsign.uppercased().trimmingCharacters(in: .whitespaces)
        guard !call.isEmpty else { return }
        alerts.append(CallsignAlert(callsign: call, bandID: bandID))
        save()
    }

    func remove(id: UUID) {
        alerts.removeAll { $0.id == id }
        save()
    }

    func setEnabled(_ enabled: Bool, id: UUID) {
        guard let i = alerts.firstIndex(where: { $0.id == id }) else { return }
        alerts[i].enabled = enabled
        save()
    }

    /// Alerts matching a decoded message on the current band.
    func matches(parsed: FT8ParsedMessage, currentBandID: String?) -> [CallsignAlert] {
        alerts.filter { $0.matches(parsed: parsed, currentBandID: currentBandID) }
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(alerts) {
            UserDefaults.standard.set(encoded, forKey: defaultsKey)
        }
    }
}
