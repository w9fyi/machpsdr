import SwiftUI

/// One +/-12 dB EQ band row (shared by the TX and RX equalizers).
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

private enum FilterTarget: String, CaseIterable, Identifiable {
    case tx = "TX"
    case rx = "RX"

    var id: String { rawValue }
}

/// Popover content for RX/TX passband controls.
struct FilterSettingsPanelView: View {
    @Bindable var session: RadioSession
    @State private var target: FilterTarget = .tx

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Filter", selection: $target) {
                ForEach(FilterTarget.allCases) { target in
                    Text(target.rawValue).tag(target)
                }
            }
            .pickerStyle(.radioGroup)

            Divider()

            switch target {
            case .tx:
                txFilterControls
            case .rx:
                if session.focusedSliceIndex == 0 {
                    RXFilterControlsView(session: session)
                } else {
                    Text("Slice filters follow the receiver mode; full RX filter shaping is available on Slice A.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .frame(width: 360)
    }

    private var txFilterControls: some View {
        VStack(alignment: .leading, spacing: 10) {
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
            Text("Narrow for punch and DX; wider for ESSB ragchew audio.")
                .font(.caption)
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

/// TX equalizer and processing presets.
struct TXAudioSectionView: View {
    @Bindable var session: RadioSession

    var body: some View {
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
