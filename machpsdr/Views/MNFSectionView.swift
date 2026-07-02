import SwiftUI

/// Manual notch filters (MNF): user-placed notches at absolute RF frequencies that
/// track as you tune. Add one at the current VFO, toggle or delete each, and enable
/// the whole set with the master switch.
struct MNFSectionView: View {
    @Bindable var session: RadioSession

    var body: some View {
        Toggle("Manual Notch (MNF)", isOn: Binding(
            get: { session.manualNotchOn },
            set: { session.setManualNotchRun($0) }
        ))
        .accessibilityHint("Master enable for all manual notch filters.")

        Button {
            session.addManualNotchAtCurrentFrequency()
        } label: {
            Label("Add Notch at \(freqText(Double(session.frequencyHz)))", systemImage: "plus.circle")
        }
        .accessibilityHint("Places a 200 hertz wide notch at the current tuned frequency and enables manual notch.")

        if session.manualNotches.isEmpty {
            Text("No manual notches. Add one at the current frequency to null out a carrier or tuner birdie.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(session.manualNotches) { notch in
                HStack {
                    Toggle(isOn: Binding(
                        get: { notch.active },
                        set: { session.setManualNotchActive(id: notch.id, active: $0) }
                    )) {
                        Text("\(freqText(notch.frequencyHz)) · \(Int(notch.widthHz)) Hz")
                    }
                    .accessibilityLabel("Notch at \(freqText(notch.frequencyHz)), \(Int(notch.widthHz)) hertz wide")
                    Spacer()
                    Button(role: .destructive) {
                        session.removeManualNotch(id: notch.id)
                    } label: {
                        Label("Delete", systemImage: "trash").labelStyle(.iconOnly)
                    }
                    .accessibilityLabel("Delete notch at \(freqText(notch.frequencyHz))")
                }
            }
        }
    }

    private func freqText(_ hz: Double) -> String {
        String(format: "%.3f MHz", hz / 1_000_000)
    }
}
