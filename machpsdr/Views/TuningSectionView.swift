import SwiftUI

/// Tuning section rows: focused-slice frequency entry, sample rate, mode,
/// volume/mute, and MIDI tuning step. The frequency field keeps a local `@State`
/// edit buffer synced from the model, so live re-renders can't clobber typing.
struct TuningSectionView: View {
    @Bindable var session: RadioSession

    /// Frequency shown in the text field, in MHz.
    @State private var frequencyMHz: Double = 7.1
    /// VFO B (split transmit) frequency field, in MHz.
    @State private var vfoBMHz: Double = 7.1

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

        HStack {
            Toggle("Split", isOn: Binding(
                get: { session.splitOn },
                set: { session.setSplit($0) }
            ))
            .help("Transmit on VFO B while receiving on the focused slice.")
            Spacer()
            Text("VFO B").foregroundStyle(.secondary)
            TextField("MHz", value: $vfoBMHz, format: .number.precision(.fractionLength(6)))
                .frame(width: 120)
                .multilineTextAlignment(.trailing)
                .onSubmit {
                    session.setVFOB(UInt32((vfoBMHz * 1_000_000).rounded()))
                }
            Text("MHz").foregroundStyle(.secondary)
            Button("A→B") { session.copyAToB() }
                .help("Copy the focused slice's frequency into VFO B")
            Button("A⇄B") { session.swapAB() }
                .help("Swap VFO A (Slice A) and VFO B")
        }
        .onChange(of: session.vfoBHz) { _, newValue in
            vfoBMHz = Double(newValue) / 1_000_000
        }
        .onAppear { vfoBMHz = Double(session.vfoBHz) / 1_000_000 }

        offsetRow("RIT", on: session.ritOn, offset: session.ritHz,
                  setOn: { session.setRIT($0) }, setOffset: { session.setRITOffset($0) })
        offsetRow("XIT", on: session.xitOn, offset: session.xitHz,
                  setOn: { session.setXIT($0) }, setOffset: { session.setXITOffset($0) })

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
        HStack {
            Button {
                if focusedSlice == 0 { session.setMute(!session.muted) }
            } label: {
                Image(systemName: session.muted && focusedSlice == 0 ? "speaker.slash.fill" : "speaker.fill")
                    .foregroundStyle(session.muted && focusedSlice == 0 ? .red : .primary)
            }
            .buttonStyle(.borderless)
            .disabled(focusedSlice != 0)
            .accessibilityLabel(session.muted && focusedSlice == 0 ? "Unmute" : "Mute")
            Slider(value: Binding(
                get: { Double(session.volume(forSlice: focusedSlice)) },
                set: { session.setVolume(Float($0), forSlice: focusedSlice) }
            ), in: 0...1)
            Image(systemName: "speaker.wave.3.fill")
        }
        Toggle("Binaural Audio", isOn: Binding(
            get: { session.binaural },
            set: { session.setBinaural($0) }
        ))
        .help("Spatial stereo rendering of Slice A — helps pull weak CW/SSB out of the noise by ear.")
        MIDITuningStepSectionView(session: session)
    }

    private func syncFrequencyField() {
        frequencyMHz = Double(session.frequency(forSlice: focusedSlice)) / 1_000_000
    }

    /// One RIT/XIT row: enable toggle, ±2 kHz slider, live value, and a clear button.
    private func offsetRow(_ label: String, on: Bool, offset: Int,
                           setOn: @escaping (Bool) -> Void,
                           setOffset: @escaping (Int) -> Void) -> some View {
        HStack {
            Toggle(label, isOn: Binding(get: { on }, set: { setOn($0) }))
            Slider(value: Binding(
                get: { Double(offset) },
                set: { setOffset(Int(($0 / 10).rounded()) * 10) }
            ), in: -2000...2000)
            .disabled(!on)
            Text("\(offset >= 0 ? "+" : "")\(offset) Hz")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .trailing)
            Button("Clear") { setOffset(0) }
                .buttonStyle(.borderless)
                .disabled(offset == 0)
                .accessibilityLabel("Clear \(label) offset")
        }
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
            if session.mode == .am || session.mode == .sam {
                Picker("Sideband", selection: Binding(
                    get: { session.amSideband },
                    set: { session.setAMSideband($0) }
                )) {
                    Text("Both").tag(0)
                    Text("LSB").tag(1)
                    Text("USB").tag(2)
                }
                .help("Demodulate one sideband only to dodge an adjacent-channel interferer.")
            }
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
