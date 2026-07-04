import SwiftUI

/// AGC time-constant profile, the AGC-T (max-gain) knob, and the RX front-end
/// step attenuator (0 dB = max gain / preamp).
struct AGCSectionView: View {
    @Bindable var session: RadioSession

    var body: some View {
        Picker("AGC", selection: Binding(
            get: { session.agcMode },
            set: { session.setAGCMode($0) }
        )) {
            Text("Off").tag(0)
            Text("Long").tag(1)
            Text("Slow").tag(2)
            Text("Medium").tag(3)
            Text("Fast").tag(4)
        }
        HStack {
            Text("AGC-T")
            Slider(value: Binding(
                get: { session.agcThreshold },
                set: { session.setAGCThreshold($0) }
            ), in: -20...120, step: 1)
            Text("\(Int(session.agcThreshold)) dB")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        if session.isHermesLite {
            HStack {
                Text("RX Gain")
                Slider(value: Binding(
                    get: { Double(session.rxLNAGain) },
                    set: { session.setRXLNAGain(Int($0)) }
                ), in: -12...48, step: 1)
                Text("\(session.rxLNAGain) dB")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Text("Hermes Lite LNA gain: raise toward +48 dB for quiet high bands, lower toward −12 dB to tame strong signals or noise on the low bands. +19 dB is a good starting point.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            HStack {
                Text("RX Atten")
                Slider(value: Binding(
                    get: { Double(session.rxAttenuator) },
                    set: { session.setRXAttenuator(Int($0)) }
                ), in: 0...31, step: 1)
                Text("\(session.rxAttenuator) dB")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Text("RX Atten 0 dB = maximum gain (preamp) for quiet bands like 20 m; raise it to tame strong signals or noise on the low bands.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
