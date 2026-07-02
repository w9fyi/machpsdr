import SwiftUI

/// Extra transmit processing that sits in the WDSP TXA chain alongside the EQ and
/// compressor: phase rotator, slow leveler, and the CFC multi-band compressor.
struct TXProcessingSectionView: View {
    @Bindable var session: RadioSession

    var body: some View {
        Toggle("Phase Rotator", isOn: Binding(
            get: { session.phaseRotator },
            set: { session.setPhaseRotator($0) }
        ))
        .accessibilityHint("Evens out voice waveform asymmetry for more average power.")

        Toggle("Leveler", isOn: Binding(
            get: { session.leveler },
            set: { session.setLeveler($0) }
        ))
        .accessibilityHint("Slow automatic gain leveling ahead of the compressor.")
        if session.leveler {
            HStack {
                Text("Leveler Max")
                Slider(value: Binding(
                    get: { session.levelerTop },
                    set: { session.setLevelerTop($0) }
                ), in: 0...20, step: 1)
                .accessibilityLabel("Leveler maximum gain")
                .accessibilityValue("\(Int(session.levelerTop)) decibels")
                Text("\(Int(session.levelerTop)) dB")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }

        Toggle("CFC Compressor", isOn: Binding(
            get: { session.cfc },
            set: { session.setCFC($0) }
        ))
        .accessibilityHint("Continuous frequency compressor: multi-band speech compression.")
        if session.cfc {
            HStack {
                Text("Pre-Comp")
                Slider(value: Binding(
                    get: { session.cfcPrecomp },
                    set: { session.setCFCPrecomp($0) }
                ), in: 0...10, step: 1)
                .accessibilityLabel("CFC pre-compression")
                .accessibilityValue("\(Int(session.cfcPrecomp)) decibels")
                Text("\(Int(session.cfcPrecomp)) dB")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Toggle("CFC Post-EQ", isOn: Binding(
                get: { session.cfcEQ },
                set: { session.setCFCEQ($0) }
            ))
        }
    }
}
