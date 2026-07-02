import SwiftUI

/// One ±12 dB EQ band row (shared by the TX and RX equalizers).
private struct EQSliderRow: View {
    let label: String
    let value: Int
    let onChange: (Int) -> Void

    var body: some View {
        HStack {
            Text(label).frame(width: 60, alignment: .leading)
            Slider(value: Binding(
                get: { Double(value) },
                set: { onChange(Int($0.rounded())) }
            ), in: -12...12, step: 1)
            Text("\(value > 0 ? "+" : "")\(value) dB")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

/// RX 3-band graphic equalizer.
struct RXEqualizerSectionView: View {
    @Bindable var session: RadioSession

    var body: some View {
        Toggle("RX Equalizer", isOn: Binding(
            get: { session.rxEQ },
            set: { session.setRXEQ($0) }
        ))
        if session.rxEQ {
            EQSliderRow(label: "Preamp", value: session.rxEQPreamp) { session.setRXEQPreamp($0) }
            EQSliderRow(label: "Low", value: session.rxEQLow) { session.setRXEQLow($0) }
            EQSliderRow(label: "Mid", value: session.rxEQMid) { session.setRXEQMid($0) }
            EQSliderRow(label: "High", value: session.rxEQHigh) { session.setRXEQHigh($0) }
        }
    }
}

/// TX passband (low/high cut), the 3-band transmit equalizer, and processing presets.
struct TXAudioSectionView: View {
    @Bindable var session: RadioSession

    var body: some View {
        HStack {
            Text("TX Low")
            Slider(value: Binding(
                get: { session.txLowCut },
                set: { session.setTXLowCut($0) }
            ), in: 0...1000, step: 10)
            Text("\(Int(session.txLowCut)) Hz")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        HStack {
            Text("TX High")
            Slider(value: Binding(
                get: { session.txHighCut },
                set: { session.setTXHighCut($0) }
            ), in: 2000...4000, step: 50)
            Text("\(Int(session.txHighCut)) Hz")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        Text("Narrow (e.g. 100–2800 Hz) for punch and DX; wider for ESSB ragchew audio.")
            .font(.caption)
            .foregroundStyle(.secondary)
        Toggle("TX Equalizer", isOn: Binding(
            get: { session.txEQ },
            set: { session.setTXEQ($0) }
        ))
        if session.txEQ {
            EQSliderRow(label: "Preamp", value: session.txEQPreamp) { session.setTXEQPreamp($0) }
            EQSliderRow(label: "Low", value: session.txEQLow) { session.setTXEQLow($0) }
            EQSliderRow(label: "Mid", value: session.txEQMid) { session.setTXEQMid($0) }
            EQSliderRow(label: "High", value: session.txEQHigh) { session.setTXEQHigh($0) }
        }
        Picker("Processing", selection: Binding(
            get: { session.txProcessing },
            set: { session.setTXProcessing($0) }
        )) {
            ForEach(TXProcessing.allCases) { profile in
                Text(profile.rawValue).tag(profile)
            }
        }
        Text("Off: clean. Normal: light compression. DX: heavier compression for talk power. DX+: adds CESSB for maximum average power.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
