import SwiftUI

/// Hold-to-talk button. Press state is tracked with `@GestureState`, which the gesture
/// system owns and resets automatically — so frequent parent re-renders (the live status
/// stream updates ~10×/sec) can't spuriously fire a release and un-key the transmitter.
private struct PTTButton: View {
    let isKeyed: Bool
    let onPressChange: (Bool) -> Void
    @GestureState private var pressing = false

    var body: some View {
        Text("Transmit")
            .fontWeight(.medium)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(isKeyed ? Color.red : Color.secondary.opacity(0.2),
                        in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(isKeyed ? .white : .primary)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($pressing) { _, state, _ in state = true }
            )
            .onChange(of: pressing) { _, now in onPressChange(now) }
            .accessibilityLabel("Transmit, push to talk")
            .accessibilityAddTraits(.isButton)
    }
}

/// Transmit section rows: PTT, tune carrier, drive, and mic gain.
struct TransmitSectionView: View {
    @Bindable var session: RadioSession

    var body: some View {
        HStack {
            // Push-to-talk: held down to transmit, released to receive.
            PTTButton(isKeyed: session.isTransmitting) { session.setPTT($0) }
            Toggle("Tune", isOn: Binding(
                get: { session.isTuning },
                set: { session.setTune($0) }
            ))
            .toggleStyle(.button)
            .tint(.red)
        }
        Text("Hold Transmit (or your assigned PTT shortcut) to talk; release to receive.")
            .font(.caption)
            .foregroundStyle(.secondary)
        HStack {
            Text("Drive")
            Slider(value: Binding(
                get: { session.driveLevel },
                set: { session.setDrive($0) }
            ), in: 0...100, step: 1)
            Text("\(Int(session.driveLevel)) %")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        HStack {
            Text("Mic Gain")
            Slider(value: Binding(
                get: { session.micGain },
                set: { session.setMicGain($0) }
            ), in: 0...4, step: 0.1)
            Text(String(format: "%.1f×", session.micGain))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        if session.isTransmitting || session.isTuning {
            Label("Transmitting", systemImage: "dot.radiowaves.left.and.right")
                .foregroundStyle(.red)
        }

        Divider()

        Toggle("PureSignal", isOn: Binding(
            get: { session.puresignal },
            set: { session.setPureSignal($0) }
        ))
        .help("Adaptive predistortion: uses the radio's TX feedback receivers to linearize the transmitted signal. Needs 192 kHz and \(session.psRequiredSlices) active slices.")
        if session.puresignal {
            HStack {
                Button("Single Cal") { session.pureSignalSingleCal() }
                    .disabled(!session.isTransmitting)
                    .help("Run one calibration while transmitting voice or two-tone. Single Cal (not continuous) avoids the 10E's feedback-crosstalk artifact.")
                Spacer()
                Text("Cal: \(RadioSession.psStateName(session.lastUpdate?.psState ?? -1))")
                    .monospacedDigit()
                    .foregroundStyle((session.lastUpdate?.psState ?? -1) == 8 ? .green : .secondary)
            }
        }
        if !session.psStatusMessage.isEmpty {
            Text(session.psStatusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
