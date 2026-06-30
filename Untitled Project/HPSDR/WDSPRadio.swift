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
    private var mode: RadioMode = .usb
    private var cwPitch: Double = 600
    private var filterWidth: Double = 250    // CW
    private var filterLow: Double = 150      // SSB/DIGI low cut
    private var filterHigh: Double = 2850    // SSB/DIGI high cut / symmetric bandwidth

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
        SetRXAAGCMode(Self.channelID, 3)      // medium AGC
        SetRXAAGCTop(Self.channelID, 90.0)
        SetRXAPanelGain1(Self.channelID, volume)
        self.mode = mode
        resetFilterDefaults()
        isOpen = true
        applyMode()
        _ = SetChannelState(Self.channelID, 1, 0)
    }

    func close() {
        guard isOpen else { return }
        _ = SetChannelState(Self.channelID, 0, 1)
        CloseChannel(Self.channelID)
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

    func setNoiseReduction(_ on: Bool) {
        guard isOpen else { return }
        SetRXAEMNRRun(Self.channelID, on ? 1 : 0)
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
