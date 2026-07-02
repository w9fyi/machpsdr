import SwiftUI

/// A compact VFO row for one extra receive slice. The frequency uses a local `@State`
/// edit buffer that only syncs from the model on an explicit change — so the ~10×/sec
/// live-status re-renders can't clobber in-progress typing (the bug where a typed
/// slice frequency reverted to the slice's previous value).
private struct SliceRowView: View {
    let slice: SliceInfo
    @Bindable var session: RadioSession
    @State private var mhz: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("RX\(slice.id + 1)").font(.headline).foregroundStyle(.cyan)
            HStack {
                Text("Freq")
                TextField("MHz", value: $mhz, format: .number.precision(.fractionLength(6)))
                    .frame(width: 110)
                    .multilineTextAlignment(.trailing)
                    .onSubmit {
                        session.setSliceFrequency(slice.id, UInt32(max(0, (mhz * 1_000_000).rounded())))
                    }
                Text("MHz").foregroundStyle(.secondary)
            }
            Picker("Mode", selection: Binding(
                get: { slice.mode },
                set: { session.setSliceMode(slice.id, $0) }
            )) {
                ForEach(RadioMode.allCases) { m in Text(m.rawValue).tag(m) }
            }
            HStack {
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { Double(slice.volume) },
                    set: { session.setSliceVolume(slice.id, Float($0)) }
                ), in: 0...1)
            }
            HStack {
                Text("Pan")
                Slider(value: Binding(
                    get: { Double(slice.pan) },
                    set: { session.setSlicePan(slice.id, Float($0)) }
                ), in: -1...1, step: 0.05)
                Text(panLabel)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
        .padding(.vertical, 4)
        .onAppear { mhz = Double(slice.frequencyHz) / 1_000_000 }
        .onChange(of: slice.frequencyHz) { _, v in mhz = Double(v) / 1_000_000 }
    }

    /// "C" for center, "L##"/"R##" for a percentage toward that side.
    private var panLabel: String {
        if abs(slice.pan) < 0.05 { return "C" }
        let pct = Int((abs(slice.pan) * 100).rounded())
        return slice.pan < 0 ? "L\(pct)" : "R\(pct)"
    }
}

/// Multi-receiver controls: a stepper for the number of slices, plus a compact
/// VFO (frequency, mode, volume, pan) for each extra slice beyond the main RX1.
struct SlicesSectionView: View {
    @Bindable var session: RadioSession

    var body: some View {
        Stepper("Slices: \(session.activeSliceCount)",
                onIncrement: { session.addSlice() },
                onDecrement: { session.removeSlice() })
        Text("RX1 (above) is the main receiver with full controls. Extra slices are independent receivers sharing the antenna — give each its own frequency and pan it left/right in the stereo mix.")
            .font(.caption)
            .foregroundStyle(.secondary)
        ForEach(session.extraSlices) { slice in
            SliceRowView(slice: slice, session: session)
        }
    }
}
