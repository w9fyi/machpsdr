import SwiftUI

/// Live stream health rows: packet rate, sequence gaps, ADC overflow, PTT, and
/// a signal-level meter derived from the latest status update.
struct LiveStatusSectionView: View {
    @Bindable var session: RadioSession

    var body: some View {
        let update = session.lastUpdate
        LabeledContent("Packet Rate", value: update.map { "\($0.packetsPerSecond) /s" } ?? "—")
        LabeledContent("Sequence Gaps", value: update.map { "\($0.sequenceGaps)" } ?? "—")
        LabeledContent("ADC Overflow") {
            Image(systemName: (update?.status.adcOverflow ?? false) ? "exclamationmark.triangle.fill" : "checkmark.circle")
                .foregroundStyle((update?.status.adcOverflow ?? false) ? .red : .green)
        }
        LabeledContent("PTT") {
            Image(systemName: (update?.status.ptt ?? false) ? "mic.fill" : "mic.slash")
                .foregroundStyle((update?.status.ptt ?? false) ? .red : .secondary)
        }
        SignalMeterView(rms: update?.signalRMS ?? 0)
    }
}

/// Signal level in dBFS with a linear progress bar over the -120…0 dBFS range.
private struct SignalMeterView: View {
    let rms: Float

    var body: some View {
        let dbfs = rms > 0 ? 20 * log10(rms) : -120
        let fraction = max(0, min(1, (Double(dbfs) + 120) / 120))
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Signal Level")
                Spacer()
                Text(String(format: "%.0f dBFS", dbfs)).foregroundStyle(.secondary).monospacedDigit()
            }
            ProgressView(value: fraction)
        }
    }
}
