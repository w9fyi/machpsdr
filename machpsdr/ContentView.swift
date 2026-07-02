import SwiftUI

/// Root view: radio browser sidebar plus the detail pane for the selected radio.
struct ContentView: View {
    @Environment(RadioSession.self) private var session
    @Environment(ShortcutStore.self) private var shortcuts
    @State private var browser = RadioBrowser()
    @State private var selection: DiscoveredRadio.ID?
    @State private var keyMonitor = ShortcutKeyMonitor()

    var body: some View {
        NavigationSplitView {
            radioList
                .navigationTitle("Radios")
                .toolbar {
                    ToolbarItem {
                        Button {
                            Task { await browser.scan() }
                        } label: {
                            Label("Scan", systemImage: "antenna.radiowaves.left.and.right")
                        }
                        .disabled(browser.isScanning)
                    }
                }
        } detail: {
            detail
        }
        .task {
            await browser.scan()
        }
        .onAppear { keyMonitor.install(store: shortcuts, session: session) }
        .onDisappear { keyMonitor.remove() }
    }

    @ViewBuilder
    private var radioList: some View {
        List(selection: $selection) {
            if let errorMessage = browser.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            ForEach(browser.radios) { radio in
                VStack(alignment: .leading, spacing: 2) {
                    Text(radio.board.displayName)
                        .font(.headline)
                    Text(radio.ipAddress)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .tag(radio.id)
            }
        }
        .overlay {
            if browser.isScanning && browser.radios.isEmpty {
                ProgressView("Scanning…")
            } else if browser.radios.isEmpty {
                ContentUnavailableView(
                    "No radios found",
                    systemImage: "antenna.radiowaves.left.and.right.slash",
                    description: Text("Make sure your ANAN-10E is powered on and on the same network, then scan again.")
                )
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selection, let radio = browser.radios.first(where: { $0.id == selection }) {
            RadioDetailView(radio: radio, session: session)
        } else {
            ContentUnavailableView("Select a radio", systemImage: "dot.radiowaves.left.and.right")
        }
    }
}

#Preview {
    ContentView()
}
