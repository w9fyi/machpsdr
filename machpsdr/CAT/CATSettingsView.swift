import SwiftUI

/// Settings pane for the CAT server: enable toggle, TCP port, and live status.
struct CATSettingsView: View {
    @Environment(RadioSession.self) private var session
    @State private var portText = ""

    var body: some View {
        Form {
            Section("CAT Server (Kenwood TS-2000)") {
                Toggle("Enable CAT over TCP", isOn: Binding(
                    get: { session.catEnabled },
                    set: { session.setCATEnabled($0) }
                ))
                HStack {
                    TextField("Port", text: $portText)
                        .frame(width: 100)
                        .onSubmit(applyPort)
                    Button("Apply") { applyPort() }
                        .disabled(Int(portText) == nil || Int(portText) == session.catPort)
                }
                statusRow
                Text("Lets logging and digimode software control the radio. In WSJT-X: Settings ▸ Radio ▸ Rig \"Kenwood TS-2000\", CAT Control ▸ Network Server \"127.0.0.1:\(String(session.catPort))\", PTT Method \"CAT\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { portText = String(session.catPort) }
    }

    @ViewBuilder private var statusRow: some View {
        if let error = session.catServer.lastError {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        } else if session.catServer.isRunning {
            let clients = session.catServer.clientCount
            Label("Listening on port \(String(session.catServer.port)) — \(clients) client\(clients == 1 ? "" : "s") connected",
                  systemImage: "antenna.radiowaves.left.and.right")
                .foregroundStyle(.green)
        } else {
            Label("Stopped", systemImage: "stop.circle")
                .foregroundStyle(.secondary)
        }
    }

    private func applyPort() {
        guard let port = Int(portText) else { return }
        session.setCATPort(port)
        portText = String(session.catPort)
    }
}
