import SwiftUI

/// Tuning section rows: frequency entry, sample rate, mode, mode-appropriate
/// filter controls, and volume/mute. The frequency field keeps a local `@State`
/// edit buffer synced from the model, so live re-renders can't clobber typing.
struct TuningSectionView: View {
    @Bindable var session: RadioSession

    /// Frequency shown in the text field, in MHz.
    @State private var frequencyMHz: Double = 7.1

    var body: some View {
        HStack {
            Text("Frequency")
            Spacer()
            TextField("MHz", value: $frequencyMHz, format: .number.precision(.fractionLength(6)))
                .frame(width: 120)
                .multilineTextAlignment(.trailing)
                .onSubmit { session.setFrequency(UInt32((frequencyMHz * 1_000_000).rounded())) }
            Text("MHz").foregroundStyle(.secondary)
        }
        // Keep the frequency field in sync with MIDI/click tuning.
        .onChange(of: session.frequencyHz) { _, newValue in
            frequencyMHz = Double(newValue) / 1_000_000
        }
        .onAppear { frequencyMHz = Double(session.frequencyHz) / 1_000_000 }
        Picker("Sample Rate", selection: Binding(
            get: { session.sampleRate },
            set: { session.setSampleRate($0) }
        )) {
            ForEach(HPSDRProtocol1.SampleRate.allCases, id: \.self) { rate in
                Text("\(rate.hertz / 1000) kHz").tag(rate)
            }
        }
        // Default (pop-up menu) picker style — avoids the VoiceOver focus trap
        // that the segmented style caused in the mode selector.
        Picker("Mode", selection: Binding(
            get: { session.mode },
            set: { session.setMode($0) }
        )) {
            ForEach(RadioMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        filterControls
        HStack {
            Button {
                session.setMute(!session.muted)
            } label: {
                Image(systemName: session.muted ? "speaker.slash.fill" : "speaker.fill")
                    .foregroundStyle(session.muted ? .red : .primary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(session.muted ? "Unmute" : "Mute")
            Slider(value: Binding(
                get: { Double(session.volume) },
                set: { session.setVolume(Float($0)) }
            ), in: 0...1)
            Image(systemName: "speaker.wave.3.fill")
        }
    }

    /// Mode-appropriate filter controls: CW pitch+width, SSB/DIGI low+high cut,
    /// or a single bandwidth for AM/SAM/FM.
    @ViewBuilder
    private var filterControls: some View {
        switch session.mode.filterStyle {
        case .cw:
            labeledSlider("CW Pitch", value: session.cwPitch, range: 300...1000) { session.setCWPitch($0) }
            labeledSlider("Width", value: session.filterWidth, range: session.mode.widthRange) { session.setFilterWidth($0) }
        case .lowHigh:
            labeledSlider("Low Cut", value: session.filterLow, range: session.mode.lowCutRange) { session.setLowCut($0) }
            labeledSlider("High Cut", value: session.filterHigh, range: session.mode.highCutRange) { session.setHighCut($0) }
        case .bandwidth:
            labeledSlider("Bandwidth", value: session.filterHigh, range: session.mode.highCutRange) { session.setHighCut($0) }
        }
    }

    private func labeledSlider(_ label: String,
                               value: Double,
                               range: ClosedRange<Double>,
                               onChange: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(label)
            Slider(value: Binding(get: { value }, set: { onChange($0) }), in: range, step: 10)
            Text("\(Int(value)) Hz").monospacedDigit().foregroundStyle(.secondary)
        }
    }
}
