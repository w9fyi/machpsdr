import SwiftUI

/// MIDI tuning controls: detected sources, enable toggle, tuning step, and a
/// rolling monitor of recent messages.
struct MIDISectionView: View {
    @Bindable var session: RadioSession

    var body: some View {
        if session.midi.sourceNames.isEmpty {
            Label("No MIDI device detected", systemImage: "pianokeys")
                .foregroundStyle(.secondary)
        } else {
            ForEach(session.midi.sourceNames, id: \.self) { name in
                Label(name, systemImage: "pianokeys")
            }
        }
        Toggle("Tune with MIDI knob", isOn: $session.midiTuningEnabled)
        Picker("Tuning Step", selection: $session.midiTuningStepHz) {
            Text("10 Hz").tag(10)
            Text("100 Hz").tag(100)
            Text("1 kHz").tag(1000)
        }
        Button("Rescan MIDI") { session.midi.rescan() }
        // Always-visible monitor — a DisclosureGroup was not operable via VoiceOver.
        Text("Monitor (recent MIDI)")
            .font(.caption)
            .foregroundStyle(.secondary)
        if session.midi.log.isEmpty {
            Text("Turn the knob or press a button to see messages.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(session.midi.log.suffix(6)) { entry in
                Text(entry.text).font(.caption.monospaced())
            }
        }
    }
}
