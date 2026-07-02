import Foundation
import CoreGraphics

/// Maintains a scrolling waterfall bitmap as a circular row buffer: each push writes
/// only the ONE new row (the old memmove scrolled the entire ~700 KB bitmap per frame)
/// and `topRow` marks where the newest row lives. The view restores display order by
/// drawing the image as two stacked slices. A persistent CGContext backs the pixel
/// memory, so `makeImage()` is the single per-frame copy.
///
/// CPU-based for simplicity and low risk; can be moved to Metal later if needed.
nonisolated final class WaterfallRenderer {
    let width: Int
    let height: Int

    /// One rendered waterfall frame. `image` rows are in storage order; display row
    /// `r` (0 = newest) is storage row `(topRow + r) % height`.
    struct Frame {
        let image: CGImage
        let topRow: Int
    }

    private let pixels: UnsafeMutablePointer<UInt32>   // 0xFFRRGGBB, circular by row
    private var topRow = 0
    private let palette: [UInt32]           // 256-entry color map
    private let context: CGContext?

    init(width: Int = 640, height: Int = 280) {
        self.width = width
        self.height = height
        self.pixels = .allocate(capacity: width * height)
        self.pixels.initialize(repeating: 0xFF00_0000, count: width * height)
        self.palette = WaterfallRenderer.buildPalette()
        self.context = CGContext(
            data: pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                | CGImageAlphaInfo.noneSkipFirst.rawValue
        )
    }

    deinit {
        pixels.deallocate()
    }

    /// Writes `data` (mapped through [minDb, maxDb]) as the new top row and returns
    /// the current waterfall frame.
    func push(_ data: [Float], minDb: Float, maxDb: Float) -> Frame? {
        guard !data.isEmpty else { return makeFrame() }
        let range = max(maxDb - minDb, 0.0001)

        topRow = (topRow + height - 1) % height
        let row = pixels + topRow * width
        data.withUnsafeBufferPointer { src in
            // Resample the spectrum to the pixel width through the palette.
            for x in 0..<width {
                let srcIndex = data.count == width
                    ? x
                    : min(data.count - 1, Int(Float(x) / Float(width) * Float(data.count)))
                let normalized = max(0, min(1, (src[srcIndex] - minDb) / range))
                row[x] = palette[Int(normalized * 255)]
            }
        }
        return makeFrame()
    }

    private func makeFrame() -> Frame? {
        guard let image = context?.makeImage() else { return nil }
        return Frame(image: image, topRow: topRow)
    }

    /// Classic SDR waterfall gradient: black → blue → cyan → green → yellow → red → white.
    private static func buildPalette() -> [UInt32] {
        // Control points (position 0…1, R, G, B).
        let stops: [(Float, Float, Float, Float)] = [
            (0.00, 0, 0, 0),
            (0.20, 0, 0, 0.5),
            (0.40, 0, 0.6, 0.8),
            (0.60, 0, 0.8, 0),
            (0.75, 0.9, 0.9, 0),
            (0.90, 0.9, 0, 0),
            (1.00, 1, 1, 1)
        ]
        var palette = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            let t = Float(i) / 255
            var lower = stops[0]
            var upper = stops[stops.count - 1]
            for s in 0..<(stops.count - 1) where t >= stops[s].0 && t <= stops[s + 1].0 {
                lower = stops[s]
                upper = stops[s + 1]
                break
            }
            let segment = max(upper.0 - lower.0, 0.0001)
            let f = (t - lower.0) / segment
            let r = UInt32((lower.1 + (upper.1 - lower.1) * f) * 255)
            let g = UInt32((lower.2 + (upper.2 - lower.2) * f) * 255)
            let b = UInt32((lower.3 + (upper.3 - lower.3) * f) * 255)
            palette[i] = 0xFF00_0000 | (r << 16) | (g << 8) | b
        }
        return palette
    }
}
