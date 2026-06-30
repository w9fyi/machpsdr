import Foundation

/// An assignable function that a keyboard shortcut can trigger. Each has a stable
/// `id` (persisted in bindings), a `category` for grouping, and a display `name`.
nonisolated struct ShortcutCommand: Identifiable, Hashable {
    let id: String
    let category: String
    let name: String

    /// All assignable commands: every band, every mode, plus common actions.
    static let all: [ShortcutCommand] = {
        var commands: [ShortcutCommand] = []
        for band in Band.all {
            commands.append(ShortcutCommand(id: "band.\(band.id)", category: "Band", name: band.name))
        }
        for mode in RadioMode.allCases {
            commands.append(ShortcutCommand(id: "mode.\(mode.rawValue)", category: "Mode", name: mode.rawValue))
        }
        commands.append(contentsOf: [
            ShortcutCommand(id: "tune.up",            category: "Action", name: "Tune Up"),
            ShortcutCommand(id: "tune.down",          category: "Action", name: "Tune Down"),
            ShortcutCommand(id: "filter.narrower",    category: "Action", name: "Filter Narrower"),
            ShortcutCommand(id: "filter.wider",       category: "Action", name: "Filter Wider"),
            ShortcutCommand(id: "nr.toggle",          category: "Action", name: "Toggle Noise Reduction"),
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
    static let categories = ["Band", "Mode", "Action"]

    static func name(for id: String) -> String {
        all.first { $0.id == id }?.name ?? id
    }
}
