import SwiftUI

/// Combined panadapter (top) and scrolling waterfall (bottom) driven by the live
/// spectrum. Click or drag anywhere to tune the receiver to that frequency.
struct SpectrumView: View {
    let spectrum: SpectrumBuffer
    /// Called with the tapped frequency in Hz.
    var onTune: (UInt32) -> Void

    @State private var renderer = WaterfallRenderer()
    @State private var snapshot: Snapshot?

    // Display range in dBFS. Most of the noise floor sits low; signals poke up.
    private let minDb: Float = -130
    private let maxDb: Float = -30

    struct Snapshot {
        var data: [Float]
        var centerHz: UInt32
        var spanHz: Int
        var image: CGImage?
    }

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                guard let snap = snapshot else { return }
                let panHeight = size.height * 0.4

                drawGrid(context, size: size, panHeight: panHeight)
                drawPanadapter(context,
                               size: CGSize(width: size.width, height: panHeight),
                               data: snap.data)

                if let image = snap.image {
                    context.draw(Image(decorative: image, scale: 1),
                                 in: CGRect(x: 0, y: panHeight,
                                            width: size.width, height: size.height - panHeight))
                }

                // Center (tuned) marker.
                var marker = Path()
                marker.move(to: CGPoint(x: size.width / 2, y: 0))
                marker.addLine(to: CGPoint(x: size.width / 2, y: size.height))
                context.stroke(marker, with: .color(.red.opacity(0.7)), lineWidth: 1)
            }
            .background(.black)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        guard let snap = snapshot, geo.size.width > 0 else { return }
                        let fraction = max(0, min(1, value.location.x / geo.size.width))
                        let offset = (Double(fraction) - 0.5) * Double(snap.spanHz)
                        let frequency = max(0, Double(snap.centerHz) + offset)
                        onTune(UInt32(frequency))
                    }
            )
            .overlay(alignment: .topLeading) { frequencyLabels }
        }
        .task {
            // Poll the latest spectrum ~30×/sec, push to the waterfall, and refresh.
            while !Task.isCancelled {
                if let (data, center, span) = spectrum.latest() {
                    let image = renderer.push(data, minDb: minDb, maxDb: maxDb)
                    snapshot = Snapshot(data: data, centerHz: center, spanHz: span, image: image)
                }
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    @ViewBuilder
    private var frequencyLabels: some View {
        if let snap = snapshot {
            HStack {
                Text(frequencyText(snap.centerHz, offset: -snap.spanHz / 2))
                Spacer()
                Text(frequencyText(snap.centerHz, offset: 0))
                Spacer()
                Text(frequencyText(snap.centerHz, offset: snap.spanHz / 2))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 4)
        }
    }

    private func frequencyText(_ center: UInt32, offset: Int) -> String {
        let hz = Double(center) + Double(offset)
        return String(format: "%.3f", hz / 1_000_000)
    }

    private func drawGrid(_ context: GraphicsContext, size: CGSize, panHeight: CGFloat) {
        let gridColor = Color.white.opacity(0.08)
        for i in 1..<5 {
            let y = panHeight * CGFloat(i) / 5
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(line, with: .color(gridColor), lineWidth: 1)
        }
    }

    private func drawPanadapter(_ context: GraphicsContext, size: CGSize, data: [Float]) {
        guard data.count > 1, size.width > 1 else { return }
        let range = max(maxDb - minDb, 0.0001)
        var path = Path()
        let pixels = Int(size.width)
        for x in 0..<pixels {
            let srcIndex = min(data.count - 1, Int(Float(x) / Float(pixels) * Float(data.count)))
            let normalized = max(0, min(1, (data[srcIndex] - minDb) / range))
            let point = CGPoint(x: CGFloat(x), y: size.height * CGFloat(1 - normalized))
            if x == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        context.stroke(path, with: .color(.green), lineWidth: 1)
    }
}
