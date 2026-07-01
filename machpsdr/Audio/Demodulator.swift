import Foundation

/// A minimal native demodulator: complex baseband I/Q in, real mono audio out at 48 kHz.
///
/// This is the interim DSP for Phase 3a — it gets audio flowing so we can hear the radio.
/// Phase 3b replaces it with WDSP for full Thetis-parity processing (better filters, NR, NB, AGC).
///
/// Modes:
///   - AM:  envelope detection (|I+jQ|) with a DC blocker.
///   - USB/LSB: phasing method — audio = delayed_I ∓ hilbert(Q).
///
/// Higher radio sample rates are boxcar-decimated to 48 kHz before demodulation.
nonisolated final class Demodulator: @unchecked Sendable {
    enum Mode: String, CaseIterable, Sendable {
        case am = "AM"
        case usb = "USB"
        case lsb = "LSB"
    }

    static let audioRate = 48_000

    // Settings shared with the network thread (single reader here, UI writer).
    private var lock = os_unfair_lock()
    private var mode: Mode = .am
    private var volume: Float = 0.5

    // Hilbert FIR (odd length) for the phasing SSB demodulator.
    private let hilbertTaps: [Float]
    private let hilbertLength: Int
    private let groupDelay: Int
    private var qHistory: [Float]   // circular history of Q for the FIR
    private var iHistory: [Float]   // matching delay line for I
    private var histIndex = 0

    // AM DC-blocker state.
    private var dcPrevInput: Float = 0
    private var dcPrevOutput: Float = 0

    // Block AGC state.
    private var agcGain: Float = 1.0

    init() {
        let n = 63
        hilbertLength = n
        groupDelay = (n - 1) / 2
        let mid = (n - 1) / 2
        var taps = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let k = i - mid
            if k % 2 != 0 {
                // Ideal Hilbert response 2/(πk), Hamming-windowed.
                let ideal = 2.0 / (Double.pi * Double(k))
                let window = 0.54 - 0.46 * cos(2.0 * Double.pi * Double(i) / Double(n - 1))
                taps[i] = Float(ideal * window)
            }
        }
        hilbertTaps = taps
        qHistory = [Float](repeating: 0, count: n)
        iHistory = [Float](repeating: 0, count: n)
    }

    func setMode(_ newMode: Mode) {
        os_unfair_lock_lock(&lock); mode = newMode; os_unfair_lock_unlock(&lock)
    }

    func setVolume(_ newVolume: Float) {
        os_unfair_lock_lock(&lock); volume = max(0, min(1, newVolume)); os_unfair_lock_unlock(&lock)
    }

    private func snapshot() -> (Mode, Float) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return (mode, volume)
    }

    /// Demodulates one block of interleaved I/Q (i0,q0,i1,q1,…) at `inputRate`.
    /// Returns mono audio samples at 48 kHz.
    func process(iq: [Float], inputRate: Int) -> [Float] {
        let decimation = max(1, inputRate / Demodulator.audioRate)
        let complexCount = iq.count / 2
        let outputCount = complexCount / decimation
        guard outputCount > 0 else { return [] }

        let (mode, volume) = snapshot()
        var output = [Float](repeating: 0, count: outputCount)

        var sampleIndex = 0
        for outIndex in 0..<outputCount {
            // Boxcar-decimate `decimation` complex samples to one 48 kHz sample.
            var sumI: Float = 0
            var sumQ: Float = 0
            for _ in 0..<decimation {
                sumI += iq[sampleIndex * 2]
                sumQ += iq[sampleIndex * 2 + 1]
                sampleIndex += 1
            }
            let scale = 1.0 / Float(decimation)
            let i = sumI * scale
            let q = sumQ * scale

            switch mode {
            case .am:
                let envelope = (i * i + q * q).squareRoot()
                // One-pole DC blocker: y[n] = x[n] − x[n−1] + 0.995·y[n−1]
                let y = envelope - dcPrevInput + 0.995 * dcPrevOutput
                dcPrevInput = envelope
                dcPrevOutput = y
                output[outIndex] = y
            case .usb, .lsb:
                // Push new samples into the circular histories.
                qHistory[histIndex] = q
                iHistory[histIndex] = i
                // Hilbert FIR over Q history.
                var hilbertQ: Float = 0
                var idx = histIndex
                for tap in 0..<hilbertLength {
                    hilbertQ += hilbertTaps[tap] * qHistory[idx]
                    idx -= 1
                    if idx < 0 { idx = hilbertLength - 1 }
                }
                // I delayed by the FIR group delay to align with hilbert(Q).
                var delayIdx = histIndex - groupDelay
                if delayIdx < 0 { delayIdx += hilbertLength }
                let delayedI = iHistory[delayIdx]
                output[outIndex] = (mode == .usb) ? (delayedI - hilbertQ) : (delayedI + hilbertQ)

                histIndex += 1
                if histIndex >= hilbertLength { histIndex = 0 }
            }
        }

        applyAGCAndVolume(&output, volume: volume)
        return output
    }

    /// Normalizes the block toward a target level with smoothing, then applies
    /// volume and a soft limiter.
    private func applyAGCAndVolume(_ samples: inout [Float], volume: Float) {
        var energy: Float = 0
        for s in samples { energy += s * s }
        let rms = (energy / Float(samples.count)).squareRoot()

        let target: Float = 0.2
        if rms > 1e-6 {
            let desired = target / rms
            // Smooth gain changes; clamp to a sane range.
            agcGain = agcGain * 0.9 + desired * 0.1
            agcGain = max(0.0, min(agcGain, 5_000))
        }

        let gain = agcGain * volume
        for k in 0..<samples.count {
            var s = samples[k] * gain
            if s > 1 { s = 1 } else if s < -1 { s = -1 }
            samples[k] = s
        }
    }
}
