import SwiftUI

/// The app's Settings window (App ▸ Settings, ⌘,). Currently hosts the keyboard
/// shortcuts pane; future "set-and-forget" configuration panes can be added as tabs.
struct SettingsView: View {
    var body: some View {
        TabView {
            ShortcutsSettingsView()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            AudioSettingsView()
                .tabItem { Label("Audio", systemImage: "mic") }
            MIDISettingsView()
                .tabItem { Label("MIDI", systemImage: "pianokeys") }
            BandDataSettingsView()
                .tabItem { Label("Band Data", systemImage: "fibrechannel") }
            CATSettingsView()
                .tabItem { Label("CAT", systemImage: "network") }
            CalibrationSettingsView()
                .tabItem { Label("Calibration", systemImage: "tuningfork") }
            StationSettingsView()
                .tabItem { Label("Station", systemImage: "person.crop.circle") }
        }
        .frame(width: 480, height: 500)
    }
}

/// Frequency (ppm) calibration: manual correction entry plus one-click automatic
/// calibration against WWV's atomic-clock carriers, and an RF-free NTP method
/// that measures the sample clock against an NTP server over ~15 minutes.
struct CalibrationSettingsView: View {
    @Environment(RadioSession.self) private var session
    @AppStorage("ntpServer") private var ntpServer = "time.apple.com"
    @AppStorage("ntpCustomHost") private var ntpCustomHost = ""

    /// Preset servers plus a custom entry. The tag is the hostname itself so the
    /// stored value survives changes to the preset list.
    private static let presets: [(name: String, host: String)] = [
        ("Apple (time.apple.com)", "time.apple.com"),
        ("NIST (time.nist.gov)", "time.nist.gov"),
        ("NTP Pool (pool.ntp.org)", "pool.ntp.org"),
    ]

    private var isCustom: Bool { !Self.presets.contains { $0.host == ntpServer } }
    private var activeHost: String {
        isCustom ? ntpCustomHost.trimmingCharacters(in: .whitespaces) : ntpServer
    }

    var body: some View {
        Form {
            Section("Frequency Correction") {
                HStack {
                    Text("Clock error")
                    Spacer()
                    TextField("ppm", value: Binding(
                        get: { session.frequencyPPM },
                        set: { session.setFrequencyPPM($0) }
                    ), format: .number.precision(.fractionLength(0...2)))
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
                    Text("ppm").foregroundStyle(.secondary)
                }
                Text("Corrects the radio's oscillator error; applies to all tuning immediately and persists across launches. To set it manually, tune a reference carrier (WWV at 10 MHz) and adjust until it is centered — positive values when a known carrier appears below its true frequency.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Auto Calibration") {
                Button {
                    Task { await session.runAutoCalibration() }
                } label: {
                    if session.autoCalRunning {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Calibrating…")
                        }
                    } else {
                        Text("Auto Calibrate on WWV")
                    }
                }
                .disabled(!session.isConnected || session.autoCalRunning)
                if !session.autoCalStatus.isEmpty {
                    Text(session.autoCalStatus)
                        .font(.caption)
                }
                Text("Measures the WWV atomic-clock carrier (trying 10, 15, 5, then 20 MHz), computes the clock error, and applies the correction — about 10 seconds, then your frequency is restored. Requires a connected radio and WWV propagation; accuracy is best at the 48 kHz sample rate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("NTP Calibration (no RF)") {
                Picker("NTP server", selection: $ntpServer) {
                    ForEach(Self.presets, id: \.host) { preset in
                        Text(preset.name).tag(preset.host)
                    }
                    Text("Custom…").tag("custom")
                }
                if isCustom {
                    HStack {
                        Text("Host or IP")
                        Spacer()
                        TextField("192.168.1.10", text: $ntpCustomHost)
                            .frame(width: 200)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                    }
                }
                if session.ntpCalRunning {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Measuring…")
                        Spacer()
                        Button("Cancel") { session.cancelNTPCalibration() }
                    }
                } else {
                    Button("Calibrate via NTP (~15 min)") {
                        session.startNTPCalibration(host: activeHost)
                    }
                    .disabled(!session.isConnected || activeHost.isEmpty || session.autoCalRunning)
                }
                if !session.ntpCalStatus.isEmpty {
                    Text(session.ntpCalStatus)
                        .font(.caption)
                }
                Text("Needs no receivable signal: counts the radio's samples against NTP time for 15 minutes and computes the clock error from the rate difference. Keep the radio connected and avoid changing the sample rate or slice count during the run (tuning and operating are fine). A LAN NTP server gives the best accuracy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Configures amplifier band data (open-collector outputs) and provides a
/// calibration tool to map raw OC values to the band the amplifier reports.
struct BandDataSettingsView: View {
    @Environment(RadioSession.self) private var session
    @State private var testValue: Double = 0

    var body: some View {
        Form {
            Section("Amplifier Band Data") {
                Toggle("Send band data on band change", isOn: Binding(
                    get: { session.bandData.enabled },
                    set: { session.bandData.setEnabled($0) }
                ))
                Text("Drives the radio's open-collector outputs so an amplifier follows the band. Verify the codes match your amp before enabling and transmitting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Calibrate (no RF)") {
                Text("Connect the radio, then step this value and watch which band your amplifier reports. Setting OC outputs does not transmit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper(value: $testValue, in: 0...127) {
                    Text("Test output: \(Int(testValue)) — \(pinList(UInt8(testValue)))")
                        .monospacedDigit()
                }
                .onChange(of: testValue) { _, newValue in
                    session.setOpenCollector(UInt8(newValue))
                }
            }

            Section("Per-Band Values") {
                ForEach(Band.all) { band in
                    Stepper(value: Binding(
                        get: { Double(session.bandData.value(for: band.id)) },
                        set: { session.bandData.setValue(UInt8($0), for: band.id) }
                    ), in: 0...127) {
                        Text("\(band.name): \(session.bandData.value(for: band.id))")
                            .monospacedDigit()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Lists which OC pins (1–7) are active for a value.
    private func pinList(_ value: UInt8) -> String {
        let pins = (0..<7).filter { value & (1 << $0) != 0 }.map { "OC\($0 + 1)" }
        return pins.isEmpty ? "no pins" : pins.joined(separator: "+")
    }
}

/// Chooses which CoreAudio input device feeds the transmitter's microphone path.
struct AudioSettingsView: View {
    @Environment(RadioSession.self) private var session
    @State private var inputs: [AudioDevice] = []
    @State private var outputs: [AudioDevice] = []

    var body: some View {
        Form {
            Section("Microphone (TX)") {
                Picker("Input Device", selection: Binding(
                    get: { session.selectedMicUID },
                    set: { session.setMicDevice($0) }
                )) {
                    Text("System Default").tag(String?.none)
                    ForEach(inputs) { device in
                        Text(device.name).tag(Optional(device.id))
                    }
                }
                Text("This device's audio is sent on SSB/AM/FM voice transmit. A change takes effect the next time you key up.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Receiver Audio (RX)") {
                Picker("Output Device", selection: Binding(
                    get: { session.selectedOutputUID },
                    set: { session.setOutputDevice($0) }
                )) {
                    Text("System Default").tag(String?.none)
                    ForEach(outputs) { device in
                        Text(device.name).tag(Optional(device.id))
                    }
                }
                Text("Where received audio plays. A change takes effect immediately while connected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Refresh Devices") { refresh() }
        }
        .formStyle(.grouped)
        .onAppear { refresh() }
    }

    private func refresh() {
        inputs = AudioDevices.inputDevices()
        outputs = AudioDevices.outputDevices()
    }
}

/// Lists keyboard-shortcut bindings and provides the Add (capture → assign) flow.
struct ShortcutsSettingsView: View {
    @Environment(ShortcutStore.self) private var store

    @State private var capture = KeyCaptureController()
    @State private var isRecording = false
    @State private var capturedCombo: KeyCombo?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Keyboard Shortcuts")
                .font(.headline)
            Text("Press Add, then press the key combination you want, then choose the function to assign it to.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                if store.bindings.isEmpty {
                    Text("No shortcuts yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.bindings) { binding in
                    HStack {
                        Text(binding.combo.display)
                            .font(.body.monospaced())
                            .frame(minWidth: 80, alignment: .leading)
                        Text(ShortcutCommand.name(for: binding.commandID))
                        Spacer()
                        Button(role: .destructive) {
                            store.remove(binding)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(binding.combo.display) \(ShortcutCommand.name(for: binding.commandID))")
                    }
                }
            }

            Button {
                startRecording()
            } label: {
                Label("Add", systemImage: "plus")
            }
        }
        .padding()
        // Recording prompt.
        .sheet(isPresented: $isRecording) {
            VStack(spacing: 16) {
                Image(systemName: "keyboard")
                    .font(.largeTitle)
                Text("Press a key combination")
                    .font(.headline)
                Text("It will be assigned in the next step.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Cancel") {
                    capture.cancel()
                    isRecording = false
                }
            }
            .padding(30)
            .frame(minWidth: 280)
        }
        // Assignment step.
        .sheet(item: $capturedCombo) { combo in
            CommandPicker(combo: combo) { commandID in
                store.add(combo: combo, commandID: commandID)
                capturedCombo = nil
            } onCancel: {
                capturedCombo = nil
            }
        }
    }

    private func startRecording() {
        isRecording = true
        capture.start { combo in
            isRecording = false
            capturedCombo = combo
        }
    }
}

/// A grouped list of assignable functions shown after a combo is captured.
private struct CommandPicker: View {
    let combo: KeyCombo
    let onAssign: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Assign \(combo.display) to:")
                .font(.headline)
            List {
                ForEach(ShortcutCommand.categories, id: \.self) { category in
                    Section(category) {
                        ForEach(ShortcutCommand.all.filter { $0.category == category }) { command in
                            Button(command.name) { onAssign(command.id) }
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
            }
        }
        .padding()
        .frame(width: 380, height: 460)
    }
}

// Allow KeyCombo to drive `.sheet(item:)`.
extension KeyCombo: Identifiable {
    var id: String { "\(keyCode)-\(modifiers)" }
}
