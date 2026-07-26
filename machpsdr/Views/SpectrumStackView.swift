import SwiftUI

/// Stacked per-slice panadapter/waterfall displays. Clicking a display tunes
/// that slice's receiver (the main VFO for Slice A, the slice VFO otherwise).
struct SpectrumStackView: View {
    @Bindable var session: RadioSession

    var body: some View {
        VStack(spacing: 2) {
            ForEach(session.sliceIndices, id: \.self) { idx in
                if idx < session.sliceSpectra.count {
                    SpectrumView(spectrum: session.sliceSpectra[idx]) { hz in
                        session.setFocusedSlice(idx)
                        session.setFrequency(hz, forSlice: idx)
                    }
                    .frame(minHeight: session.activeSliceCount > 1 ? 150 : 260)
                    .overlay(alignment: .topLeading) {
                        Text(RadioSession.sliceName(for: idx))
                            .font(.caption2.bold().monospacedDigit())
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(session.focusedSliceIndex == idx ? .green : .cyan)
                            .padding(4)
                    }
                }
            }
        }
    }
}
