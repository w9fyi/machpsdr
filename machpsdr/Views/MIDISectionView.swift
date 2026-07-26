import SwiftUI

/// Compact MIDI tuning control that stays in the main radio panel.
struct MIDITuningStepSectionView: View {
    @Bindable var session: RadioSession

    var body: some View {
        Toggle("Tune with MIDI knob", isOn: Binding(
            get: { session.midiTuningEnabled },
            set: { session.setMIDITuningEnabled($0) }
        ))
        Picker("Tuning Step", selection: Binding(
            get: { session.midiTuningStepHz },
            set: { session.setMIDITuningStepHz($0) }
        )) {
            Text("10 Hz").tag(10)
            Text("100 Hz").tag(100)
            Text("1 kHz").tag(1000)
        }
    }
}

/// MIDI device, monitor, and learn controls for the Settings window.
struct MIDISettingsView: View {
    @Environment(RadioSession.self) private var session
    @State private var tuningCCValue: Double = 100

    var body: some View {
        Form {
            Section("Sources") {
                if session.midi.sourceNames.isEmpty {
                    Label("No MIDI device detected", systemImage: "pianokeys")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(session.midi.sourceNames, id: \.self) { name in
                        Label(name, systemImage: "pianokeys")
                    }
                }
                Button("Rescan MIDI") { session.midi.rescan() }
            }

            Section("Tuning Control") {
                Stepper(value: $tuningCCValue, in: 0...127, step: 1) {
                    Text("Control Change: #\(Int(tuningCCValue))")
                        .monospacedDigit()
                }
                .onChange(of: tuningCCValue) { _, value in
                    session.midi.setTuningCC(UInt8(clamping: Int(value.rounded())))
                }

                Button("Learn from Last CC") {
                    session.midi.learnTuningCCFromLastMessage()
                    tuningCCValue = Double(session.midi.tuningCC)
                }
                .disabled(session.midi.lastControlChange == nil)

                if let last = session.midi.lastControlChange {
                    Text("Last CC: channel \(last.channel), #\(last.number)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Monitor") {
                if session.midi.log.isEmpty {
                    Text("Turn a knob or press a button to see messages.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(session.midi.log.suffix(8)) { entry in
                        Text(entry.text).font(.caption.monospaced())
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { tuningCCValue = Double(session.midi.tuningCC) }
    }
}
