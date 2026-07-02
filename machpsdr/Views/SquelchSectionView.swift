import SwiftUI

/// Receiver squelch: mutes audio until the signal exceeds a threshold. AM/SAM use
/// WDSP's amplitude squelch (AMSQ); FM uses FMSQ. SSB/CW have no squelch in this
/// build (WDSP's SSQL voice squelch is not vendored).
struct SquelchSectionView: View {
    @Bindable var session: RadioSession

    /// Whether the current mode is one the squelch actually gates.
    private var appliesToCurrentMode: Bool {
        switch session.mode {
        case .am, .sam, .fm: return true
        default: return false
        }
    }

    var body: some View {
        Toggle("Squelch", isOn: Binding(
            get: { session.squelch },
            set: { session.setSquelch($0) }
        ))
        .accessibilityHint("Mutes received audio until the signal rises above the squelch level. Applies to AM, SAM, and FM.")

        if session.squelch {
            HStack {
                Text("Squelch Level")
                Slider(value: Binding(
                    get: { session.squelchLevel },
                    set: { session.setSquelchLevel($0) }
                ), in: 0...100, step: 1)
                .accessibilityLabel("Squelch level")
                .accessibilityValue("\(Int(session.squelchLevel)) percent")
                Text("\(Int(session.squelchLevel))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if !appliesToCurrentMode {
                Text("Squelch affects AM, SAM, and FM. The current mode (\(session.mode.rawValue)) is unaffected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
