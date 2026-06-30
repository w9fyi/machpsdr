import AppKit

/// Captures a single key combination (used by the "Add Shortcut" flow).
/// Installs a one-shot local key monitor that consumes the next key press.
@MainActor
final class KeyCaptureController {
    private var monitor: Any?

    /// Begins listening; `completion` is called with the next key combo, once.
    func start(_ completion: @escaping (KeyCombo) -> Void) {
        cancel()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let combo = KeyCombo(event: event)
            self?.cancel()
            completion(combo)
            return nil // consume so the key doesn't act while recording
        }
    }

    func cancel() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}

/// While installed, watches all key-down events and runs any bound shortcut command
/// against the session. Plain (modifier-less) shortcuts are ignored while a text
/// field is being edited so typing a frequency still works.
@MainActor
final class ShortcutKeyMonitor {
    private var monitor: Any?

    func install(store: ShortcutStore, session: RadioSession) {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let commandID = store.commandID(for: event) else { return event }
            let combo = KeyCombo(event: event)
            if combo.hasNoModifiers,
               NSApp.keyWindow?.firstResponder is NSText {
                return event // let plain keystrokes reach the text field
            }
            session.execute(commandID: commandID)
            return nil // consume
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
