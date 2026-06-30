import Foundation
import CoreGraphics

/// Maintains a scrolling waterfall bitmap. Each pushed spectrum becomes the new
/// top row; older rows scroll downward. dB values map through a color gradient.
///
/// CPU-based for simplicity and low risk; can be moved to Metal later if needed.
nonisolated final class WaterfallRenderer {
    let width: Int
    let height: Int
    private var pixels: [UInt32]            // 0xFFRRGGBB per pixel, row 0 = newest
    private let palette: [UInt32]           // 256-entry color map
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
        | CGImageAlphaInfo.noneSkipFirst.rawValue

    init(width: Int = 640, height: Int = 280) {
        self.width = width
        self.height = height
        self.pixels = [UInt32](repeating: 0xFF00_0000, count: width * height)
        self.palette = WaterfallRenderer.buildPalette()
    }

    /// Scrolls down one row, writes `data` (mapped through [minDb, maxDb]) as the
    /// new top row, and returns a CGImage of the current waterfall.
    func push(_ data: [Float], minDb: Float, maxDb: Float) -> CGImage? {
        guard !data.isEmpty else { return makeImage() }
        let range = max(maxDb - minDb, 0.0001)

        pixels.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            // Scroll existing rows down by one.
            memmove(base + width, base, (height - 1) * width * MemoryLayout<UInt32>.size)
            // Write the new top row, resampling the spectrum to the pixel width.
            for x in 0..<width {
                let srcIndex = data.count == width
                    ? x
                    : min(data.count - 1, Int(Float(x) / Float(width) * Float(data.count)))
                let normalized = max(0, min(1, (data[srcIndex] - minDb) / range))
                base[x] = palette[Int(normalized * 255)]
            }
        }
        return makeImage()
    }

    private func makeImage() -> CGImage? {
        pixels.withUnsafeMutableBytes { raw -> CGImage? in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { return nil }
            return context.makeImage()
        }
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
