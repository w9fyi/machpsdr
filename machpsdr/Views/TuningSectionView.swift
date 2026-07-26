import SwiftUI

/// Tuning section rows: focused-slice frequency entry, sample rate, mode, filters,
/// volume/mute, and MIDI tuning step. The frequency field keeps a local `@State`
/// edit buffer synced from the model, so live re-renders can't clobber typing.
struct TuningSectionView: View {
    @Bindable var session: RadioSession

    /// Frequency shown in the text field, in MHz.
    @State private var frequencyMHz: Double = 7.1

    private var focusedSlice: Int { session.focusedSliceIndex }

    var body: some View {
        HStack {
            Text("Frequency")
            Spacer()
            Text(RadioSession.sliceName(for: focusedSlice))
                .foregroundStyle(.secondary)
            TextField("MHz", value: $frequencyMHz, format: .number.precision(.fractionLength(6)))
                .frame(width: 120)
                .multilineTextAlignment(.trailing)
                .onSubmit {
                    session.setFrequency(UInt32((frequencyMHz * 1_000_000).rounded()), forSlice: focusedSlice)
                }
            Text("MHz").foregroundStyle(.secondary)
        }
        .onChange(of: session.frequency(forSlice: focusedSlice)) { _, newValue in
            frequencyMHz = Double(newValue) / 1_000_000
        }
        .onChange(of: focusedSlice) { _, _ in syncFrequencyField() }
        .onAppear { syncFrequencyField() }

        Picker("Sample Rate", selection: Binding(
            get: { session.sampleRate },
            set: { session.setSampleRate($0) }
        )) {
            ForEach(HPSDRProtocol1.SampleRate.allCases, id: \.self) { rate in
                Text("\(rate.hertz / 1000) kHz").tag(rate)
            }
        }
        // Default (pop-up menu) picker style avoids the VoiceOver focus trap
        // that the segmented style caused in the mode selector.
        Picker("Mode", selection: Binding(
            get: { session.mode(forSlice: focusedSlice) },
            set: { session.setMode($0, forSlice: focusedSlice) }
        )) {
            ForEach(RadioMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        if focusedSlice == 0 {
            RXFilterControlsView(session: session)
        } else {
            Text("Slice filters follow the receiver mode; full RX filter shaping is available on Slice A.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        HStack {
            Button {
                if focusedSlice == 0 { session.setMute(!session.muted) }
            } label: {
                Image(systemName: session.muted && focusedSlice == 0 ? "speaker.slash.fill" : "speaker.fill")
                    .foregroundStyle(session.muted && focusedSlice == 0 ? .red : .primary)
            }
            .buttonStyle(.borderless)
            .disabled(focusedSlice != 0)
            .accessibilityLabel(session.muted ? "Unmute" : "Mute")
            Slider(value: Binding(
                get: { Double(session.volume(forSlice: focusedSlice)) },
                set: { session.setVolume(Float($0), forSlice: focusedSlice) }
            ), in: 0...1)
            Image(systemName: "speaker.wave.3.fill")
        }
        MIDITuningStepSectionView(session: session)
    }

    private func syncFrequencyField() {
        frequencyMHz = Double(session.frequency(forSlice: focusedSlice)) / 1_000_000
    }
}

/// Mode-appropriate RX filter controls for the main receiver.
struct RXFilterControlsView: View {
    @Bindable var session: RadioSession

    var body: some View {
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
