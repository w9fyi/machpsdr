import Foundation
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
    func processBlock(mic: [Float]) -> [Float] {
        guard isOpen else { return [] }
        for k in 0..<Self.bufferSize {
            let sample = k < mic.count ? Double(mic[k]) * micGain : 0
            inBuffer[k * 2] = sample
            inBuffer[k * 2 + 1] = 0
        }
        var error: Int32 = 0
        fexchange0(Self.channelID, &inBuffer, &outBuffer, &error)
        for k in 0..<(Self.bufferSize * 2) {
            iqScratch[k] = Float(outBuffer[k])
        }
        return iqScratch
    }

    /// Reads a TXA meter value (e.g. ALC, output power).
    func meter(_ type: Int32) -> Double {
        guard isOpen else { return 0 }
        return GetTXAMeter(Self.channelID, type)
    }
}
