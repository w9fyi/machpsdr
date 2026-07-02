import Foundation
import Accelerate

/// Thread-safe holder for the most recent power spectrum, written by the DSP
/// thread and read by the UI render loop.
nonisolated final class SpectrumBuffer: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var data: [Float] = []
    private var center: UInt32 = 0
    private var span: Int = 0
    private var generation: UInt64 = 0

    func update(_ newData: [Float], centerHz: UInt32, spanHz: Int) {
        os_unfair_lock_lock(&lock)
        data = newData
        center = centerHz
        span = spanHz
        generation &+= 1
        os_unfair_lock_unlock(&lock)
    }

    /// Latest spectrum in display order (low → high frequency), or nil if none yet.
    /// `centerHz` is the frequency at the middle bin; `spanHz` is the total width.
    /// `generation` increments on every update — pollers compare it to skip frames
    /// that haven't changed instead of redrawing identical data.
    func latest() -> (data: [Float], centerHz: UInt32, spanHz: Int, generation: UInt64)? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return data.isEmpty ? nil : (data, center, span, generation)
    }
}

/// Computes a windowed power spectrum (in dB) from complex baseband I/Q using a
/// complex DFT, then exponentially averages successive frames for a stable display.
/// Output is in display order: index 0 = center − span/2, last = center + span/2.
///
/// `nonisolated` so it runs on the network/DSP thread under MainActor-default isolation.
nonisolated final class SpectrumAnalyzer: @unchecked Sendable {
    let fftSize: Int
    let buffer: SpectrumBuffer

    private let setup: vDSP_DFT_Setup?
    private var window: [Float]

    // Accumulation of incoming complex samples until a full FFT frame is ready.
    private var accI: [Float]
    private var accQ: [Float]
    private var fill = 0

    // Preallocated scratch (avoids per-frame allocation / aliasing).
    private var winI: [Float]
    private var winQ: [Float]
    private var outR: [Float]
    private var outI: [Float]
    private var p1: [Float]
    private var p2: [Float]
    private var power: [Float]
    private var averaged: [Float]

    private let averaging: Float = 0.5   // 0 = no smoothing, →1 = very smooth

    init(buffer: SpectrumBuffer, fftSize: Int = 2048) {
        self.buffer = buffer
        self.fftSize = fftSize
        self.setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(fftSize), .FORWARD)
        if self.setup == nil {
            NSLog("SpectrumAnalyzer: vDSP DFT setup failed for size \(fftSize); spectrum disabled.")
        }
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        accI = [Float](repeating: 0, count: fftSize)
        accQ = [Float](repeating: 0, count: fftSize)
        winI = [Float](repeating: 0, count: fftSize)
        winQ = [Float](repeating: 0, count: fftSize)
        outR = [Float](repeating: 0, count: fftSize)
        outI = [Float](repeating: 0, count: fftSize)
        p1 = [Float](repeating: 0, count: fftSize)
        p2 = [Float](repeating: 0, count: fftSize)
        power = [Float](repeating: 0, count: fftSize)
        averaged = [Float](repeating: -120, count: fftSize)
    }

    deinit { if let setup { vDSP_DFT_DestroySetup(setup) } }

    /// Feeds interleaved I/Q (i0,q0,i1,q1,…). Produces spectra as frames fill.
    func ingest(_ iq: [Float], centerHz: UInt32, spanHz: Int) {
        let complexCount = iq.count / 2
        var index = 0
        while index < complexCount {
            let take = min(fftSize - fill, complexCount - index)
            for k in 0..<take {
                accI[fill + k] = iq[(index + k) * 2]
                accQ[fill + k] = iq[(index + k) * 2 + 1]
            }
            fill += take
            index += take
            if fill == fftSize {
                computeSpectrum(centerHz: centerHz, spanHz: spanHz)
                fill = 0
            }
        }
    }

    private func computeSpectrum(centerHz: UInt32, spanHz: Int) {
        guard let setup else { return }
        let n = vDSP_Length(fftSize)
        // Window the I and Q.
        vDSP_vmul(accI, 1, window, 1, &winI, 1, n)
        vDSP_vmul(accQ, 1, window, 1, &winQ, 1, n)
        // Complex forward DFT.
        vDSP_DFT_Execute(setup, winI, winQ, &outR, &outI)
        // Power = Re² + Im².
        vDSP_vsq(outR, 1, &p1, 1, n)
        vDSP_vsq(outI, 1, &p2, 1, n)
        vDSP_vadd(p1, 1, p2, 1, &power, 1, n)

        // Convert to dB, fftshift to display order, and exponentially average —
        // all vectorized (a scalar log10f per bin dominated this function).
        let half = fftSize / 2
        var normScale: Float = 1.0 / Float(fftSize * fftSize)
        var floorValue: Float = 1e-12
        vDSP_vsmsa(power, 1, &normScale, &floorValue, &p1, 1, n)   // p1 = power*scale + floor
        var reference: Float = 1
        vDSP_vdbcon(p1, 1, &reference, &p1, 1, n, 0)               // p1 = 10·log10(p1)
        // fftshift (DC to center): display[0..<half] = p1[half...], display[half...] = p1[0..<half].
        p1.withUnsafeBufferPointer { src in
            p2.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress!.update(from: src.baseAddress! + half, count: half)
                (dst.baseAddress! + half).update(from: src.baseAddress!, count: half)
            }
        }
        var alpha = averaging
        var beta = 1 - averaging
        vDSP_vsmul(averaged, 1, &alpha, &averaged, 1, n)           // averaged *= alpha
        vDSP_vsma(p2, 1, &beta, averaged, 1, &averaged, 1, n)      // averaged += shifted*(1-alpha)
        buffer.update(averaged, centerHz: centerHz, spanHz: spanHz)
    }
}
