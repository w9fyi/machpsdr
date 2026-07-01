import AppKit
import Observation

/// Persists user keyboard-shortcut bindings (combo → command) and resolves
/// incoming key events to commands. Stored in UserDefaults as JSON.
@MainActor
@Observable
final class ShortcutStore {
    struct Binding: Codable, Identifiable, Hashable {
        var id = UUID()
        var combo: KeyCombo
        var commandID: String
    }

    private(set) var bindings: [Binding] = []
    private let defaultsKey = "keyboardShortcutBindings"

    init() { load() }

    /// Adds or replaces the binding for `combo`.
    func add(combo: KeyCombo, commandID: String) {
        bindings.removeAll { $0.combo == combo }
        bindings.append(Binding(combo: combo, commandID: commandID))
        bindings.sort { ShortcutCommand.name(for: $0.commandID) < ShortcutCommand.name(for: $1.commandID) }
        save()
    }

    func remove(_ binding: Binding) {
        bindings.removeAll { $0.id == binding.id }
        save()
    }

    /// Returns the command id bound to the given key event, if any.
    func commandID(for event: NSEvent) -> String? {
        let combo = KeyCombo(event: event)
        return bindings.first { $0.combo == combo }?.commandID
    }

    private func save() {
        if let data = try? JSONEncoder().encode(bindings) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([Binding].self, from: data) else { return }
        bindings = decoded
    }
}
