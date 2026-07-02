import SwiftUI

@main struct MyApp: App {
    @State private var session = RadioSession()
    @State private var shortcuts = ShortcutStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(session)
                .environment(shortcuts)
        }
        .defaultSize(width: 760, height: 520)

        Settings {
            SettingsView()
                .environment(shortcuts)
                .environment(session)
        }
    }
}
