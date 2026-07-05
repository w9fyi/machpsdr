import SwiftUI

@main struct MyApp: App {
    @State private var session: RadioSession
    @State private var shortcuts = ShortcutStore()
    @State private var ft8: FT8Controller

    init() {
        let session = RadioSession()
        _session = State(initialValue: session)
        _ft8 = State(initialValue: FT8Controller(session: session))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(session)
                .environment(shortcuts)
                .environment(ft8)
        }
        .defaultSize(width: 760, height: 520)

        Settings {
            SettingsView()
                .environment(shortcuts)
                .environment(session)
                .environment(ft8)
        }
    }
}
