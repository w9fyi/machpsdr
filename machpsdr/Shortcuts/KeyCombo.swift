import AppKit

/// A captured keyboard combination (key + modifiers) with a precomputed display string.
/// Matching is by `keyCode` + `modifiers`; `display` is derived and shown in the UI.
nonisolated struct KeyCombo: Codable, Hashable {
    var keyCode: UInt16
    var modifiers: UInt   // cleaned NSEvent.ModifierFlags rawValue
    var display: String

    init(event: NSEvent) {
        keyCode = event.keyCode
        let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let mods = event.modifierFlags.intersection(relevant)
        modifiers = mods.rawValue
        display = KeyCombo.makeDisplay(mods: mods, keyCode: event.keyCode,
                                       chars: event.charactersIgnoringModifiers ?? "")
    }

    /// True if the combo carries no modifier keys (plain key press).
    var hasNoModifiers: Bool { modifiers == 0 }

    private static func makeDisplay(mods: NSEvent.ModifierFlags, keyCode: UInt16, chars: String) -> String {
        var result = ""
        if mods.contains(.control) { result += "⌃" }
        if mods.contains(.option)  { result += "⌥" }
        if mods.contains(.shift)   { result += "⇧" }
        if mods.contains(.command) { result += "⌘" }
        result += keyName(keyCode: keyCode, chars: chars)
        return result
    }

    private static func keyName(keyCode: UInt16, chars: String) -> String {
        switch keyCode {
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 49:  return "Space"
        case 36:  return "Return"
        case 48:  return "Tab"
        case 53:  return "Esc"
        case 51:  return "Delete"
        default:
            let upper = chars.uppercased()
            return upper.isEmpty ? "Key\(keyCode)" : upper
        }
    }
}
