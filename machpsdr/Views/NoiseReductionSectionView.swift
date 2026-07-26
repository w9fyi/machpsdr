import SwiftUI

/// Receiver noise-reduction controls: EMNR spectral subtraction (with mode and
/// artifact reduction), ANR (LMS), ANF auto-notch, and the two noise blankers.
struct NoiseReductionSectionView: View {
    @Bindable var session: RadioSession

    var body: some View {
        Toggle("Spectral NR (NR2)", isOn: Binding(
            get: { session.spectralNR },
            set: { session.setSpectralNR($0) }
        ))
        if session.spectralNR {
            Picker("NR2 Mode", selection: Binding(
                get: { session.spectralNRGainMethod },
                set: { session.setSpectralNRGainMethod($0) }
            )) {
                Text("Linear").tag(0)
                Text("Log").tag(1)
                Text("Gamma").tag(2)
                Text("Trained").tag(3)
            }
            Picker("Noise Estimate", selection: Binding(
                get: { session.spectralNRNPEMethod },
                set: { session.setSpectralNRNPEMethod($0) }
            )) {
                Text("OSMS").tag(0)
                Text("MMSE").tag(1)
                Text("NSTAT").tag(2)
            }
            Toggle("Reduce Artifacts", isOn: Binding(
                get: { session.spectralNRArtifact },
                set: { session.setSpectralNRArtifact($0) }
            ))
            Toggle("Psychoacoustic Post", isOn: Binding(
                get: { session.spectralNRPost },
                set: { session.setSpectralNRPost($0) }
            ))
            .accessibilityHint("Masks residual musical noise under shaped comfort noise.")
            if session.spectralNRPost {
                HStack {
                    Text("Post Strength")
                    Slider(value: Binding(
                        get: { session.spectralNRPostFactor },
                        set: { session.setSpectralNRPostFactor($0) }
                    ), in: 0...0.5, step: 0.01)
                    .accessibilityLabel("Psychoacoustic post-processing strength")
                    .accessibilityValue(String(format: "%.2f", session.spectralNRPostFactor))
                    Text(String(format: "%.2f", session.spectralNRPostFactor))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        Toggle("LMS NR (NR)", isOn: Binding(
            get: { session.lmsNR },
            set: { session.setLMSNR($0) }
        ))
        if session.lmsNR {
            HStack {
                Text("NR Strength")
                Slider(value: Binding(
                    get: { Double(session.lmsNRStrength) },
                    set: { session.setLMSNRStrength(Int($0)) }
                ), in: 16...128, step: 8)
                Text("\(session.lmsNRStrength)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        Toggle("Auto-Notch (ANF)", isOn: Binding(
            get: { session.autoNotch },
            set: { session.setAutoNotch($0) }
        ))
        Toggle("NR3 (RNNoise)", isOn: Binding(
            get: { session.nr3 },
            set: { session.setNR3($0) }
        ))
        .accessibilityHint("Neural denoiser trained on HF ham-radio noise.")
        Toggle("Spectral NB (SNB)", isOn: Binding(
            get: { session.snb },
            set: { session.setSNB($0) }
        ))
        .accessibilityHint("Reduces broadband spectral and impulse noise.")
        Toggle("APF (CW Peak)", isOn: Binding(
            get: { session.apf },
            set: { session.setAPF($0) }
        ))
        .accessibilityHint("Audio peaking filter for CW: peaks a narrow band at the CW pitch.")
        if session.apf {
            HStack {
                Text("APF Bandwidth")
                Slider(value: Binding(
                    get: { session.apfBandwidth },
                    set: { session.setAPFBandwidth($0) }
                ), in: 30...500, step: 10)
                .accessibilityLabel("APF bandwidth")
                .accessibilityValue("\(Int(session.apfBandwidth)) hertz")
                Text("\(Int(session.apfBandwidth)) Hz")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        Toggle("Noise Blanker (NB)", isOn: Binding(
            get: { session.noiseBlanker },
            set: { session.setNoiseBlanker($0) }
        ))
        if session.noiseBlanker {
            HStack {
                Text("NB Threshold")
                Slider(value: Binding(
                    get: { session.noiseBlankerThreshold },
                    set: { session.setNoiseBlankerThreshold($0) }
                ), in: 1.5...10, step: 0.1)
                Text(String(format: "%.1f×", session.noiseBlankerThreshold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        Toggle("Noise Blanker 2 (NB2)", isOn: Binding(
            get: { session.noiseBlanker2 },
            set: { session.setNoiseBlanker2($0) }
        ))
        if session.noiseBlanker2 {
            Picker("NB2 Fill", selection: Binding(
                get: { session.noiseBlanker2Mode },
                set: { session.setNoiseBlanker2Mode($0) }
            )) {
                Text("Zero").tag(0)
                Text("Sample-Hold").tag(1)
                Text("Mean-Hold").tag(2)
                Text("Hold-Sample").tag(3)
                Text("Interpolate").tag(4)
            }
            HStack {
                Text("NB2 Threshold")
                Slider(value: Binding(
                    get: { session.noiseBlanker2Threshold },
                    set: { session.setNoiseBlanker2Threshold($0) }
                ), in: 1.5...10, step: 0.1)
                Text(String(format: "%.1f×", session.noiseBlanker2Threshold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}
