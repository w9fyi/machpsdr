import Foundation
import CWDSP

/// Demodulation modes supported by the WDSP receiver, with their WDSP RXA codes.
nonisolated enum RadioMode: String, CaseIterable, Sendable, Identifiable {
    case lsb = "LSB"
    case usb = "USB"
    case cwl = "CW-L"
    case cwu = "CW-U"
    case am = "AM"
    case sam = "SAM"
    case fm = "FM"
    case digl = "DIGL"
    case digu = "DIGU"

    var id: String { rawValue }

    /// WDSP RXA mode code.
    var wdspCode: Int32 {
        switch self {
        case .lsb: return 0
        case .usb: return 1
        case .cwl: return 3
        case .cwu: return 4
        case .fm:  return 5
        case .am:  return 6
        case .digu: return 7
        case .digl: return 9
        case .sam: return 10
        }
    }

    var isCW: Bool { self == .cwl || self == .cwu }

    /// Which filter controls the UI should present for this mode.
    enum FilterStyle { case cw, lowHigh, bandwidth }
    var filterStyle: FilterStyle {
        switch self {
        case .cwu, .cwl: return .cw
        case .am, .sam, .fm: return .bandwidth
        default: return .lowHigh
        }
    }

    /// Computes the WDSP passband (signed Hz) from the active filter parameters.
    /// SSB/DIGI use `low`/`high` audio edges; AM/SAM/FM are symmetric ±`high`;
    /// CW centers a `width` window on the sidetone pitch.
    func passband(cwPitch: Double, width: Double, low: Double, high: Double) -> (low: Double, high: Double) {
        switch self {
        case .usb, .digu: return (low, high)
        case .lsb, .digl: return (-high, -low)
        case .am, .sam, .fm: return (-high, high)
        case .cwu: return (cwPitch - width / 2, cwPitch + width / 2)
        case .cwl: return (-cwPitch - width / 2, -cwPitch + width / 2)
        }
    }

    // CW width (centered on pitch).
    var defaultWidth: Double { 250 }
    var widthRange: ClosedRange<Double> { 50...1000 }

    // Low/high cut edges (audio Hz) for non-CW modes.
    var defaultLow: Double {
        switch self {
        case .usb, .lsb, .digu, .digl: return 150
        default: return 0
        }
    }
    var defaultHigh: Double {
        switch self {
        case .usb, .lsb, .digu, .digl: return 2850
        case .am, .sam: return 4800
        case .fm: return 8000
        default: return 2850
        }
    }
    var lowCutRange: ClosedRange<Double> { 0...1500 }
    var highCutRange: ClosedRange<Double> {
        switch self {
        case .am, .sam, .fm: return 2000...10000
        default: return 800...4000
        }
    }

    /// Frequency shift so a zero-beat CW carrier lands at the sidetone pitch; nil for non-CW.
    func shift(cwPitch: Double) -> Double? {
        switch self {
        case .cwu: return cwPitch
        case .cwl: return -cwPitch
        default:   return nil
        }
    }
}

/// Wraps a WDSP RXA receiver channel: feeds it complex baseband I/Q and writes the
/// demodulated audio into the shared ring buffer. Full Thetis-grade DSP path.
///
/// Runs on the network/DSP thread; `nonisolated` under MainActor-default isolation.
nonisolated final class WDSPRadio: @unchecked Sendable {
    static let channelID: Int32 = 0
    static let bufferSize = 1024
    static let audioRate = 48_000

    private let ring: AudioRingBuffer
    private var isOpen = false

    private var inBuffer: [Double]
    private var outBuffer: [Double]
    private var fill = 0
    private var audioScratch: [Float]

    private var volume: Double = 0.4
    private var agcMode: Int32 = 3       // 0 off, 1 long, 2 slow, 3 medium, 4 fast
    private var agcTop: Double = 90.0    // AGC-T: maximum gain in dB
    private var mode: RadioMode = .usb
    private var cwPitch: Double = 600
    private var filterWidth: Double = 250    // CW
    private var filterLow: Double = 150      // SSB/DIGI low cut
    private var filterHigh: Double = 2850    // SSB/DIGI high cut / symmetric bandwidth

    // Noise reduction (RXA): EMNR spectral subtraction, ANR (LMS), ANF (auto-notch).
    private var emnrOn = false
    private var emnrGainMethod: Int32 = 2    // 0 linear, 1 log, 2 gamma (WDSP default)
    private var emnrNPEMethod: Int32 = 0     // noise-power estimator: 0 OSMS, 1 MMSE
    private var emnrArtifact = true          // artifact (musical-noise) elimination
    private var anrOn = false
    private var anrTaps: Int32 = 64          // ANR LMS filter length (strength)
    private var anfOn = false

    // Front-end noise blankers (EXT): ANB (NB) and NOB (NB2). Run on the complex I/Q
    // before demodulation. `nbID` indexes WDSP's external-blanker tables.
    private let nbID: Int32 = 0
    private var nbOn = false
    private var nbThreshold: Double = 3.0
    private var nb2On = false
    private var nb2Mode: Int32 = 0           // 0 zero, 1 sample-hold, 2 mean-hold, 3 hold-sample, 4 interpolate
    private var nb2Threshold: Double = 3.0

    init(ring: AudioRingBuffer) {
        self.ring = ring
        inBuffer = [Double](repeating: 0, count: WDSPRadio.bufferSize * 2)
        outBuffer = [Double](repeating: 0, count: WDSPRadio.bufferSize * 2)
        audioScratch = [Float](repeating: 0, count: WDSPRadio.bufferSize)
    }

    func open(mode: RadioMode) {
        guard !isOpen else { return }
        OpenChannel(Self.channelID,
                    Int32(Self.bufferSize),
                    Int32(Self.bufferSize * 2),
                    Int32(Self.audioRate),
                    Int32(Self.audioRate),
                    Int32(Self.audioRate),
                    0, 0,
                    0.010, 0.025, 0.000, 0.010, 0)
        // Front-end noise blankers (ANB + NOB), created with the channel. Gentle
        // timing defaults; `threshold` (× running-average magnitude) is the main knob.
        create_anbEXT(nbID, 0, Int32(Self.bufferSize), Double(Self.audioRate),
                      0.0001, 0.0001, 0.0001, 0.005, nbThreshold)
        create_nobEXT(nbID, 0, nb2Mode, Int32(Self.bufferSize), Double(Self.audioRate),
                      0.0001, 0.0001, 0.0001, 0.005, nb2Threshold)
        applyAGC()
        SetRXAPanelGain1(Self.channelID, volume)
        self.mode = mode
        resetFilterDefaults()
        isOpen = true
        applyMode()
        applyNoiseReduction()
        applyNoiseBlanker()
        _ = SetChannelState(Self.channelID, 1, 0)
    }

    func close() {
        guard isOpen else { return }
        _ = SetChannelState(Self.channelID, 0, 1)
        CloseChannel(Self.channelID)
        destroy_anbEXT(nbID)
        destroy_nobEXT(nbID)
        isOpen = false
        fill = 0
    }

    func setMode(_ newMode: RadioMode) {
        mode = newMode
        resetFilterDefaults()                // reset filter params to the mode's defaults
        if isOpen { applyMode() }
    }

    func setFilterWidth(_ width: Double) {
        filterWidth = width
        if isOpen { applyMode() }
    }

    func setLowCut(_ hz: Double) {
        filterLow = hz
        if isOpen { applyMode() }
    }

    func setHighCut(_ hz: Double) {
        filterHigh = hz
        if isOpen { applyMode() }
    }

    private func resetFilterDefaults() {
        filterWidth = mode.defaultWidth
        filterLow = mode.defaultLow
        filterHigh = mode.defaultHigh
    }

    func setCWPitch(_ hz: Double) {
        cwPitch = hz
        if isOpen && mode.isCW { applyMode() }
    }

    func setVolume(_ v: Float) {
        volume = Double(max(0, min(1, v)))
        if isOpen { SetRXAPanelGain1(Self.channelID, volume) }
    }

    /// AGC time-constant profile: 0 off, 1 long, 2 slow, 3 medium, 4 fast.
    func setAGCMode(_ mode: Int) {
        agcMode = Int32(mode)
        if isOpen { SetRXAAGCMode(Self.channelID, agcMode) }
    }

    /// AGC-T: the maximum gain (dB) the AGC applies — effectively the threshold knob.
    func setAGCTop(_ db: Double) {
        agcTop = db
        if isOpen { SetRXAAGCTop(Self.channelID, db) }
    }

    private func applyAGC() {
        SetRXAAGCMode(Self.channelID, agcMode)
        SetRXAAGCTop(Self.channelID, agcTop)
    }

    /// EMNR spectral-subtraction noise reduction (on/off).
    func setSpectralNR(_ on: Bool) {
        emnrOn = on
        if isOpen { SetRXAEMNRRun(Self.channelID, on ? 1 : 0) }
    }

    /// EMNR gain computation method: 0 = linear, 1 = log, 2 = gamma.
    func setSpectralNRGainMethod(_ method: Int) {
        emnrGainMethod = Int32(method)
        if isOpen { SetRXAEMNRgainMethod(Self.channelID, emnrGainMethod) }
    }

    /// EMNR noise-power estimator: 0 = OSMS (minimum statistics), 1 = MMSE.
    func setSpectralNRNPEMethod(_ method: Int) {
        emnrNPEMethod = Int32(method)
        if isOpen { SetRXAEMNRnpeMethod(Self.channelID, emnrNPEMethod) }
    }

    /// EMNR artifact (musical-noise) reduction post-filter.
    func setSpectralNRArtifactReduction(_ on: Bool) {
        emnrArtifact = on
        if isOpen { SetRXAEMNRaeRun(Self.channelID, on ? 1 : 0) }
    }

    /// ANR: LMS (least-mean-squares) broadband noise reduction.
    func setANR(_ on: Bool) {
        anrOn = on
        if isOpen { SetRXAANRRun(Self.channelID, on ? 1 : 0) }
    }

    /// ANR strength via LMS filter length (more taps = deeper reduction, more distortion).
    func setANRStrength(_ taps: Int) {
        anrTaps = Int32(max(16, min(128, taps)))
        if isOpen { SetRXAANRVals(Self.channelID, anrTaps, 16, 0.0001, 0.1) }
    }

    /// ANF: automatic notch filter (removes steady carriers/heterodynes).
    func setANF(_ on: Bool) {
        anfOn = on
        if isOpen { SetRXAANFRun(Self.channelID, on ? 1 : 0) }
    }

    /// Noise Blanker (ANB): blanks impulse/static bursts on the front-end I/Q.
    func setNoiseBlanker(_ on: Bool) {
        nbOn = on
        if isOpen { SetEXTANBRun(nbID, on ? 1 : 0) }
    }

    /// NB threshold as a multiple of the running-average magnitude (lower = more aggressive).
    func setNoiseBlankerThreshold(_ threshold: Double) {
        nbThreshold = threshold
        if isOpen { SetEXTANBThreshold(nbID, threshold) }
    }

    /// Noise Blanker 2 (NOB): second-generation blanker with selectable fill mode.
    func setNoiseBlanker2(_ on: Bool) {
        nb2On = on
        if isOpen { SetEXTNOBRun(nbID, on ? 1 : 0) }
    }

    /// NB2 fill mode: 0 zero, 1 sample-hold, 2 mean-hold, 3 hold-sample, 4 interpolate.
    func setNoiseBlanker2Mode(_ mode: Int) {
        nb2Mode = Int32(mode)
        if isOpen { SetEXTNOBMode(nbID, nb2Mode) }
    }

    func setNoiseBlanker2Threshold(_ threshold: Double) {
        nb2Threshold = threshold
        if isOpen { SetEXTNOBThreshold(nbID, threshold) }
    }

    /// Re-applies blanker state after the EXT instances are (re)created on open.
    private func applyNoiseBlanker() {
        SetEXTANBThreshold(nbID, nbThreshold)
        SetEXTANBRun(nbID, nbOn ? 1 : 0)
        SetEXTNOBMode(nbID, nb2Mode)
        SetEXTNOBThreshold(nbID, nb2Threshold)
        SetEXTNOBRun(nbID, nb2On ? 1 : 0)
    }

    /// Re-applies all noise-reduction state to the freshly opened channel.
    private func applyNoiseReduction() {
        SetRXAEMNRgainMethod(Self.channelID, emnrGainMethod)
        SetRXAEMNRnpeMethod(Self.channelID, emnrNPEMethod)
        SetRXAEMNRaeRun(Self.channelID, emnrArtifact ? 1 : 0)
        SetRXAEMNRRun(Self.channelID, emnrOn ? 1 : 0)
        SetRXAANRVals(Self.channelID, anrTaps, 16, 0.0001, 0.1)
        SetRXAANRRun(Self.channelID, anrOn ? 1 : 0)
        SetRXAANFRun(Self.channelID, anfOn ? 1 : 0)
    }

    /// Applies the current mode, passband width, and CW shift to the WDSP channel.
    private func applyMode() {
        SetRXAMode(Self.channelID, mode.wdspCode)
        let pb = mode.passband(cwPitch: cwPitch, width: filterWidth, low: filterLow, high: filterHigh)
        RXASetPassband(Self.channelID, pb.low, pb.high)
        if let shift = mode.shift(cwPitch: cwPitch) {
            SetRXAShiftFreq(Self.channelID, shift)
            SetRXAShiftRun(Self.channelID, 1)
        } else {
            SetRXAShiftRun(Self.channelID, 0)
        }
    }

    /// Feeds interleaved Float I/Q at `inputRate`; decimates to 48 kHz and runs WDSP a
    /// buffer at a time, writing demodulated audio to the ring.
    func process(iq: [Float], inputRate: Int) {
        guard isOpen else { return }
        let decimation = max(1, inputRate / Self.audioRate)
        let complexCount = iq.count / 2
        var index = 0
        while index + decimation <= complexCount {
            var sumI: Float = 0
            var sumQ: Float = 0
            for _ in 0..<decimation {
                sumI += iq[index * 2]
                sumQ += iq[index * 2 + 1]
                index += 1
            }
            let scale = 1.0 / Double(decimation)
            // The ANAN's I/Q matches WDSP's convention directly — feed unmodified.
            inBuffer[fill * 2] = Double(sumI) * scale
            inBuffer[fill * 2 + 1] = Double(sumQ) * scale
            fill += 1

            if fill == Self.bufferSize {
                // Front-end impulse/static blanking on the complex I/Q (in place).
                if nbOn {
                    inBuffer.withUnsafeMutableBufferPointer { p in
                        xanbEXT(nbID, p.baseAddress, p.baseAddress)
                    }
                }
                if nb2On {
                    inBuffer.withUnsafeMutableBufferPointer { p in
                        xnobEXT(nbID, p.baseAddress, p.baseAddress)
                    }
                }
                var error: Int32 = 0
                fexchange0(Self.channelID, &inBuffer, &outBuffer, &error)
                for k in 0..<Self.bufferSize {
                    audioScratch[k] = Float(outBuffer[k * 2])
                }
                ring.write(audioScratch)
                fill = 0
            }
        }
    }
}
