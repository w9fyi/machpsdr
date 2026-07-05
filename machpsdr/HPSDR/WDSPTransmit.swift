import Foundation
import Accelerate
import CWDSP

/// Wraps a WDSP TXA transmit channel: turns microphone audio (or a built-in tune
/// tone) into transmit I/Q for the radio. SSB only for now.
///
/// Runs on the network/DSP thread; `nonisolated` under MainActor-default isolation.
nonisolated final class WDSPTransmit: @unchecked Sendable {
    static let channelID: Int32 = 1     // TXA (RXA uses 0)
    static let bufferSize = 1024
    static let rate = 48_000

    private var isOpen = false
    private var mode: RadioMode = .usb
    private var micGain: Double = 1.0

    // TX audio shaping: SSB passband edges (audio Hz) and a 3-band graphic EQ.
    private var txLow: Double = 100
    private var txHigh: Double = 2800
    private var eqOn = false
    private var eqGains: [Int32] = [0, 0, 0, 0]   // [preamp, low, mid, high] in dB
    private var cessbOn = false                    // CESSB overshoot control (W9GR)

    // Additional TX processing (WDSP TXA chain).
    private var phaseRotatorOn = false             // PHROT: voice-asymmetry rotator
    private var levelerOn = false                  // slow gain leveler ahead of COMP
    private var levelerTop: Double = 15            // leveler ceiling (max gain), dB
    private var cfcOn = false                      // CFC multi-band compressor
    private var cfcPrecomp: Double = 0             // CFC pre-compression, dB
    private var cfcEqOn = false                    // CFC post-equalizer

    private var inBuffer: [Double]      // interleaved (mic, 0)
    private var outBuffer: [Double]     // interleaved TX I/Q
    private var iqScratch: [Float]

    init() {
        inBuffer = [Double](repeating: 0, count: WDSPTransmit.bufferSize * 2)
        outBuffer = [Double](repeating: 0, count: WDSPTransmit.bufferSize * 2)
        iqScratch = [Float](repeating: 0, count: WDSPTransmit.bufferSize * 2)
    }

    func open(mode: RadioMode) {
        guard !isOpen else { return }
        OpenChannel(Self.channelID,
                    Int32(Self.bufferSize),
                    Int32(Self.bufferSize * 2),
                    Int32(Self.rate),
                    Int32(Self.rate),
                    Int32(Self.rate),
                    1,          // type 1 = TXA
                    0,          // start stopped
                    0.010, 0.025, 0.000, 0.010, 0)
        self.mode = mode
        applyMode()
        SetTXACompressorGain(Self.channelID, 3.0)
        SetTXACompressorRun(Self.channelID, 0)   // speech processor off by default
        applyEQ()
        SetTXAosctrlRun(Self.channelID, cessbOn ? 1 : 0)
        applyExtraProcessing()
        _ = SetChannelState(Self.channelID, 1, 0)
        isOpen = true
    }

    func close() {
        guard isOpen else { return }
        SetTXAPreGenRun(Self.channelID, 0)
        _ = SetChannelState(Self.channelID, 0, 1)
        CloseChannel(Self.channelID)
        isOpen = false
    }

    func setMode(_ newMode: RadioMode) {
        mode = newMode
        if isOpen { applyMode() }
    }

    func setMicGain(_ gain: Double) { micGain = max(0, gain) }

    /// Sets the SSB transmit passband edges (audio Hz). Applied immediately when open.
    func setTXBandwidth(low: Double, high: Double) {
        txLow = low
        txHigh = high
        if isOpen {
            let pb = txPassband()
            SetTXABandpassFreqs(Self.channelID, pb.low, pb.high)
            SetTXABandpassRun(Self.channelID, 1)
        }
    }

    /// Enables/disables the TX 3-band graphic equalizer.
    func setEQ(on: Bool) {
        eqOn = on
        if isOpen { SetTXAEQRun(Self.channelID, on ? 1 : 0) }
    }

    /// Sets TX EQ gains in dB: overall preamp plus low/mid/high bands.
    func setEQGains(preamp: Int, low: Int, mid: Int, high: Int) {
        eqGains = [Int32(preamp), Int32(low), Int32(mid), Int32(high)]
        if isOpen { SetTXAGrphEQ(Self.channelID, &eqGains) }
    }

    /// Pushes the current EQ gains and run state to the open channel.
    private func applyEQ() {
        SetTXAGrphEQ(Self.channelID, &eqGains)
        SetTXAEQRun(Self.channelID, eqOn ? 1 : 0)
    }

    /// Enables/disables CESSB (Controlled Envelope SSB) overshoot control, which tames
    /// SSB envelope peaks so you can run more average power for the same PEP.
    func setCESSB(_ on: Bool) {
        cessbOn = on
        if isOpen { SetTXAosctrlRun(Self.channelID, on ? 1 : 0) }
    }

    /// Phase rotator (PHROT): reshapes voice waveform asymmetry for higher average power.
    func setPhaseRotator(_ on: Bool) {
        phaseRotatorOn = on
        if isOpen { SetTXAPHROTRun(Self.channelID, on ? 1 : 0) }
    }

    /// Leveler: slow AGC-like gain leveling ahead of the compressor.
    func setLeveler(_ on: Bool) {
        levelerOn = on
        if isOpen { SetTXALevelerSt(Self.channelID, on ? 1 : 0) }
    }

    /// Leveler ceiling: the maximum gain (dB) the leveler will apply.
    func setLevelerTop(_ db: Double) {
        levelerTop = db
        if isOpen { SetTXALevelerTop(Self.channelID, db) }
    }

    /// CFC: continuous frequency compressor (multi-band). Uses WDSP's default band
    /// profile; per-band gain editing is a later enhancement.
    func setCFC(_ on: Bool) {
        cfcOn = on
        if isOpen { SetTXACFCOMPRun(Self.channelID, on ? 1 : 0) }
    }

    /// CFC pre-compression gain (dB) applied before the multi-band stage.
    func setCFCPrecomp(_ db: Double) {
        cfcPrecomp = db
        if isOpen { SetTXACFCOMPPrecomp(Self.channelID, db) }
    }

    /// CFC post-equalizer on/off.
    func setCFCEQ(_ on: Bool) {
        cfcEqOn = on
        if isOpen { SetTXACFCOMPPeqRun(Self.channelID, on ? 1 : 0) }
    }

    /// Applies phase-rotator, leveler, and CFC state to the freshly opened channel.
    private func applyExtraProcessing() {
        SetTXAPHROTCorner(Self.channelID, 200)
        SetTXAPHROTNstages(Self.channelID, 8)
        SetTXAPHROTRun(Self.channelID, phaseRotatorOn ? 1 : 0)
        SetTXALevelerTop(Self.channelID, levelerTop)
        SetTXALevelerSt(Self.channelID, levelerOn ? 1 : 0)
        SetTXACFCOMPPrecomp(Self.channelID, cfcPrecomp)
        SetTXACFCOMPPeqRun(Self.channelID, cfcEqOn ? 1 : 0)
        SetTXACFCOMPRun(Self.channelID, cfcOn ? 1 : 0)
    }

    /// Enables/disables the WDSP speech processor (compressor) with a gain in dB.
    func setSpeechProcessor(_ on: Bool, gain: Double) {
        guard isOpen else { return }
        SetTXACompressorGain(Self.channelID, gain)
        SetTXACompressorRun(Self.channelID, on ? 1 : 0)
    }

    /// Starts the built-in single-tone generator (for tuning amps/tuners).
    func startTone(frequency: Double = 1000, magnitude: Double = 0.5) {
        guard isOpen else { return }
        SetTXAPreGenMode(Self.channelID, 0)            // 0 = single tone
        SetTXAPreGenToneFreq(Self.channelID, frequency)
        SetTXAPreGenToneMag(Self.channelID, magnitude)
        SetTXAPreGenRun(Self.channelID, 1)
    }

    func stopTone() {
        guard isOpen else { return }
        SetTXAPreGenRun(Self.channelID, 0)
    }

    private func applyMode() {
        SetTXAMode(Self.channelID, mode.wdspCode)
        let pb = txPassband()
        SetTXABandpassFreqs(Self.channelID, pb.low, pb.high)
        SetTXABandpassRun(Self.channelID, 1)
    }

    /// Signed TX passband edges for the current sideband: USB/DIGU is a positive
    /// passband, LSB/DIGL negative, and AM/SAM/FM symmetric — matching the RX
    /// convention in `RadioMode.passband`. (The old code hardcoded the negative/LSB
    /// form, which put USB audio on the wrong side of the filter and zeroed USB output.)
    private func txPassband() -> (low: Double, high: Double) {
        switch mode {
        case .usb, .digu: return (txLow, txHigh)
        case .lsb, .digl: return (-txHigh, -txLow)
        default:          return (-txHigh, txHigh)
        }
    }

    /// Processes exactly `bufferSize` mono mic samples (pad with zeros for tune)
    /// into interleaved TX I/Q Floats. Returns an empty array if not open.
    /// `gainOverride` replaces the user's mic gain (digital modes render audio
    /// at its final level).
    func processBlock(mic: [Float], gainOverride: Double? = nil) -> [Float] {
        guard isOpen else { return [] }
        // Real lane (stride 2) gets the mic with gain; the imaginary lane is zeroed at
        // init and never written, so it stays zero.
        let n = min(mic.count, Self.bufferSize)
        var gain = gainOverride ?? micGain
        if n > 0 {
            vDSP_vspdp(mic, 1, &inBuffer, 2, vDSP_Length(n))
            vDSP_vsmulD(inBuffer, 2, &gain, &inBuffer, 2, vDSP_Length(n))
        }
        if n < Self.bufferSize {
            inBuffer.withUnsafeMutableBufferPointer { p in
                vDSP_vclrD(p.baseAddress! + n * 2, 2, vDSP_Length(Self.bufferSize - n))
            }
        }
        var error: Int32 = 0
        fexchange0(Self.channelID, &inBuffer, &outBuffer, &error)
        vDSP_vdpsp(outBuffer, 1, &iqScratch, 1, vDSP_Length(Self.bufferSize * 2))
        return iqScratch
    }

    /// Reads a TXA meter value (e.g. ALC, output power).
    func meter(_ type: Int32) -> Double {
        guard isOpen else { return 0 }
        return GetTXAMeter(Self.channelID, type)
    }
}
