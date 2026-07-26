import Foundation

/// An assignable function that a keyboard shortcut can trigger. Each has a stable
/// `id` (persisted in bindings), a `category` for grouping, and a display `name`.
nonisolated struct ShortcutCommand: Identifiable, Hashable {
    let id: String
    let category: String
    let name: String

    /// All assignable commands: every band, every mode, slice focus, plus common actions.
    static let all: [ShortcutCommand] = {
        var commands: [ShortcutCommand] = []
        for band in Band.all {
            commands.append(ShortcutCommand(id: "band.\(band.id)", category: "Band", name: band.name))
        }
        for mode in RadioMode.allCases {
            commands.append(ShortcutCommand(id: "mode.\(mode.rawValue)", category: "Mode", name: mode.rawValue))
        }
        for index in 0..<10 {
            commands.append(ShortcutCommand(id: "slice.\(index)", category: "Slice", name: "Focus \(sliceName(for: index))"))
        }
        commands.append(contentsOf: [
            ShortcutCommand(id: "tune.up",            category: "Action", name: "Tune Up"),
            ShortcutCommand(id: "tune.down",          category: "Action", name: "Tune Down"),
            ShortcutCommand(id: "filter.narrower",    category: "Action", name: "Filter Narrower"),
            ShortcutCommand(id: "filter.wider",       category: "Action", name: "Filter Wider"),
            ShortcutCommand(id: "nr.toggle",          category: "Action", name: "Toggle Noise Reduction"),
            ShortcutCommand(id: "audio.mute",         category: "Action", name: "Toggle Mute"),
            ShortcutCommand(id: "volume.up",          category: "Action", name: "Volume Up"),
            ShortcutCommand(id: "volume.down",        category: "Action", name: "Volume Down"),
            ShortcutCommand(id: "tx.ptt",             category: "Action", name: "Transmit (PTT)"),
            ShortcutCommand(id: "tx.tune",            category: "Action", name: "Tune On / Off"),
            ShortcutCommand(id: "drive.up",           category: "Action", name: "Drive Up"),
            ShortcutCommand(id: "drive.down",         category: "Action", name: "Drive Down"),
            ShortcutCommand(id: "connection.toggle",  category: "Action", name: "Connect / Disconnect"),
        ])
        return commands
    }()

    /// Categories in display order.
    static let categories = ["Band", "Mode", "Slice", "Action"]

    static func name(for id: String) -> String {
        all.first { $0.id == id }?.name ?? id
    }

    private static func sliceName(for index: Int) -> String {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        if letters.indices.contains(index) { return "Slice \(letters[index])" }
        return "Slice \(index + 1)"
    }
}
