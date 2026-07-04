import SwiftUI

/// A manual notch filter entry: an absolute RF center frequency and width. Persisted
/// across launches; WDSP tracks each notch's audio-passband position as the VFO moves.
struct ManualNotch: Identifiable, Codable, Sendable, Equatable {
    var id: Int
    var frequencyHz: Double
    var widthHz: Double
    var active: Bool
}

/// Owns the live connection to a single radio and surfaces its state to the UI.
@MainActor
@Observable
final class RadioSession {
    enum State: Equatable {
        case disconnected
        case connecting
        case streaming
        case failed(String)
    }

    private(set) var state: State = .disconnected
    private(set) var lastUpdate: StreamUpdate?
    var frequencyHz: UInt32 = 7_100_000
    var sampleRate: HPSDRProtocol1.SampleRate = .rate48k
    var mode: RadioMode = .usb
    var volume: Float = 0.5
    var muted = false
    // Noise reduction (RXA DSP)
    var spectralNR = false              // EMNR spectral subtraction
    var spectralNRGainMethod = 2        // 0 linear, 1 log, 2 gamma
    var spectralNRNPEMethod = 0         // 0 OSMS, 1 MMSE
    var spectralNRArtifact = true       // EMNR artifact (musical-noise) reduction
    var lmsNR = false                   // ANR (LMS)
    var lmsNRStrength = 64              // ANR LMS filter taps (strength)
    var autoNotch = false               // ANF auto-notch
    // Front-end noise blankers (impulse/static)
    var noiseBlanker = false            // ANB
    var noiseBlankerThreshold = 3.0     // × running-average magnitude
    var noiseBlanker2 = false           // NOB
    var noiseBlanker2Mode = 0           // 0 zero, 1 sample-hold, 2 mean-hold, 3 hold-sample, 4 interpolate
    var noiseBlanker2Threshold = 3.0
    // Squelch (AM/SAM via AMSQ, FM via FMSQ; SSB/CW have no squelch in this WDSP build)
    var squelch = false
    var squelchLevel = 50.0             // 0…100 UI scale
    var snb = false                     // SNB spectral noise blanker
    var apf = false                     // APF CW audio peaking filter
    var apfBandwidth = 100.0            // APF peak bandwidth, Hz
    // MNF manual notches (persisted). `manualNotchOn` is the master enable.
    var manualNotchOn = false
    var manualNotches: [ManualNotch] = []
    private var nextNotchID = 0
    // TX processing (WDSP TXA chain)
    var phaseRotator = false            // PHROT
    var leveler = false                 // slow gain leveler
    var levelerTop = 15.0               // leveler ceiling, dB
    var cfc = false                     // CFC multi-band compressor
    var cfcPrecomp = 0.0                // CFC pre-compression, dB
    var cfcEQ = false                   // CFC post-equalizer
    // AGC + front-end gain
    var agcMode = 3                     // 0 off, 1 long, 2 slow, 3 medium, 4 fast
    var agcThreshold = 90.0             // AGC-T (max gain, dB)
    var rxAttenuator = 0                // RX ADC step attenuator, 0-31 dB (0 = preamp)
    var rxLNAGain = 19                  // HL2 LNA gain, -12…+48 dB (persisted)
    var frequencyPPM: Double = 0        // radio clock error, ppm (persisted)
    var cwPitch: Double = 600
    var filterWidth: Double = 250
    var filterLow: Double = 150
    var filterHigh: Double = 2850
    var midiTuningEnabled = false
    var midiTuningStepHz = 100
    var isTransmitting = false
    var isTuning = false
    var driveLevel: Double = 10   // percent; starts low for safety
    var micGain: Double = 1.0     // linear
    /// Selected mic input device UID (nil = macOS default input). Persisted.
    var selectedMicUID: String?
    /// Selected output device UID for received audio (nil = macOS default output). Persisted.
    var selectedOutputUID: String?
    var txProcessing: TXProcessing = .off
    // TX audio shaping
    var txLowCut = 100.0
    var txHighCut = 2800.0
    var txEQ = false
    var txEQPreamp = 0
    var txEQLow = 0
    var txEQMid = 0
    var txEQHigh = 0
    // RX equalizer
    var rxEQ = false
    var rxEQPreamp = 0
    var rxEQLow = 0
    var rxEQMid = 0
    var rxEQHigh = 0

    // Multi-receiver "slices". The main receiver (index 0) uses the properties above;
    // `extraSlices` are additional independent receivers (indices 1…) with their own
    // VFO and stereo pan. On-air count is clamped to hardware limits by the connection.
    static let maxSlices = RadioConnection.maxSlices
    var extraSlices: [SliceInfo] = []
    /// Per-slice spectra for the stacked panadapters (populated on connect).
    private(set) var sliceSpectra: [SpectrumBuffer] = []
    /// Total active receivers, including the main one.
    var activeSliceCount: Int { extraSlices.count + 1 }
    /// Indices (0…activeSliceCount-1) for iterating panadapters.
    var sliceIndices: Range<Int> { 0..<activeSliceCount }

    // CAT server (Kenwood TS-2000 emulation over TCP for WSJT-X/fldigi/loggers).
    // Enabled state and port are persisted.
    private(set) var catEnabled = false
    private(set) var catPort = 13013
    let catServer = CATServer()

    let midi = MIDIManager()
    let bandData = BandDataStore()
    private var currentBandOC: UInt8 = 0
    private var lastBandID: String?

    init() {
        let defaults = UserDefaults.standard
        selectedMicUID = defaults.string(forKey: "selectedMicUID")
        selectedOutputUID = defaults.string(forKey: "selectedOutputUID")
        // Restore transmit settings across app launches. Guard on object(forKey:)
        // so an absent key keeps the safe default rather than reading back 0.
        if defaults.object(forKey: "driveLevel") != nil {
            driveLevel = defaults.double(forKey: "driveLevel")
        }
        if defaults.object(forKey: "micGain") != nil {
            micGain = defaults.double(forKey: "micGain")
        }
        if let procRaw = defaults.string(forKey: "txProcessing"),
           let proc = TXProcessing(rawValue: procRaw) {
            txProcessing = proc
        }
        if defaults.object(forKey: "sampleRate") != nil,
           let rate = HPSDRProtocol1.SampleRate(rawValue: UInt8(clamping: defaults.integer(forKey: "sampleRate"))) {
            sampleRate = rate
        }
        if defaults.object(forKey: "rxLNAGain") != nil {
            rxLNAGain = max(-12, min(48, defaults.integer(forKey: "rxLNAGain")))
        }
        if defaults.object(forKey: "frequencyPPM") != nil {
            frequencyPPM = max(-100, min(100, defaults.double(forKey: "frequencyPPM")))
        }
        if let data = defaults.data(forKey: "manualNotches"),
           let saved = try? JSONDecoder().decode([ManualNotch].self, from: data) {
            manualNotches = saved
            nextNotchID = (saved.map(\.id).max() ?? -1) + 1
        }
        catEnabled = defaults.bool(forKey: "catEnabled")
        if defaults.object(forKey: "catPort") != nil {
            catPort = defaults.integer(forKey: "catPort")
        }
        midi.onTuneStep = { [weak self] steps in
            guard let self, self.midiTuningEnabled else { return }
            self.tuneBy(steps: steps)
        }
        midi.start()
        if catEnabled { catServer.start(port: UInt16(clamping: catPort), radio: self) }
    }

    // MARK: - CAT server

    func setCATEnabled(_ on: Bool) {
        catEnabled = on
        UserDefaults.standard.set(on, forKey: "catEnabled")
        if on {
            catServer.start(port: UInt16(clamping: catPort), radio: self)
        } else {
            catServer.stop()
        }
    }

    /// Sets the CAT TCP port (1–65535), persists it, and restarts the server if running.
    func setCATPort(_ port: Int) {
        let clamped = min(65535, max(1, port))
        catPort = clamped
        UserDefaults.standard.set(clamped, forKey: "catPort")
        if catEnabled { catServer.start(port: UInt16(clamping: clamped), radio: self) }
    }

    /// Adjusts the receiver frequency by `steps` tuning detents.
    func tuneBy(steps: Int) {
        let delta = steps * midiTuningStepHz
        let newFrequency = max(0, Int(frequencyHz) + delta)
        setFrequency(UInt32(newFrequency))
    }

    private var connection: RadioConnection?
    private var consumeTask: Task<Void, Never>?
    /// Live spectrum buffer for the panadapter/waterfall (nil when disconnected).
    private(set) var spectrumBuffer: SpectrumBuffer?
    /// Most recently connected radio, used by the connect/disconnect shortcut.
    private(set) var lastRadio: DiscoveredRadio?

    var isConnected: Bool { state == .streaming }

    func connect(to radio: DiscoveredRadio) {
        disconnect()
        lastRadio = radio
        state = .connecting
        var settings = RadioSettings()
        settings.sampleRate = sampleRate
        settings.receiverCount = activeSliceCount
        settings.receiverFrequencies = [frequencyHz] + extraSlices.map { $0.frequencyHz }
        settings.transmitFrequency = frequencyHz
        settings.rxLNAGain = rxLNAGain
        settings.frequencyCalibrationPPM = frequencyPPM
        let conn = RadioConnection(radio: radio, settings: settings)
        connection = conn
        spectrumBuffer = conn.spectrum
        sliceSpectra = conn.spectra
        let outUID = selectedOutputUID
        consumeTask = Task {
            await conn.setOutputDevice(uid: outUID)
            do {
                try await conn.start()
            } catch {
                self.state = .failed(error.localizedDescription)
                return
            }
            self.state = .streaming
            self.applyAudioSettings()
            for await update in await conn.updates {
                self.lastUpdate = update
            }
        }
    }

    func disconnect() {
        consumeTask?.cancel()
        consumeTask = nil
        let conn = connection
        connection = nil
        spectrumBuffer = nil
        sliceSpectra = []
        lastUpdate = nil
        isTransmitting = false
        isTuning = false
        state = .disconnected
        Task { await conn?.stop() }
    }

    func setFrequency(_ hz: UInt32) {
        frequencyHz = hz
        let conn = connection
        Task { await conn?.setFrequency(hz) }
        updateBandData(for: hz)
    }

    /// Auto-updates amp band data when the frequency crosses into a different band.
    private func updateBandData(for hz: UInt32) {
        guard bandData.enabled,
              let band = Band.band(for: hz),
              band.id != lastBandID else { return }
        lastBandID = band.id
        currentBandOC = bandData.value(for: band.id)
        setOpenCollector(currentBandOC)
    }

    func setSampleRate(_ rate: HPSDRProtocol1.SampleRate) {
        sampleRate = rate
        UserDefaults.standard.set(Int(rate.rawValue), forKey: "sampleRate")
        let conn = connection
        Task { await conn?.setSampleRate(rate) }
    }

    func setMode(_ newMode: RadioMode) {
        mode = newMode
        // Mirror WDSP's per-mode filter defaults so the sliders stay in sync.
        filterWidth = newMode.defaultWidth
        filterLow = newMode.defaultLow
        filterHigh = newMode.defaultHigh
        let conn = connection
        Task { await conn?.setMode(newMode) }
    }

    func setFilterWidth(_ width: Double) {
        filterWidth = width
        let conn = connection
        Task { await conn?.setFilterWidth(width) }
    }

    func setLowCut(_ hz: Double) {
        filterLow = hz
        let conn = connection
        Task { await conn?.setLowCut(hz) }
    }

    func setHighCut(_ hz: Double) {
        filterHigh = hz
        let conn = connection
        Task { await conn?.setHighCut(hz) }
    }

    func setCWPitch(_ hz: Double) {
        cwPitch = hz
        let conn = connection
        Task { await conn?.setCWPitch(hz) }
    }

    func setVolume(_ newVolume: Float) {
        volume = newVolume
        let conn = connection
        let effective = muted ? 0 : newVolume
        Task { await conn?.setVolume(effective) }
    }

    /// Mutes/unmutes received audio without disturbing the volume setting.
    func setMute(_ on: Bool) {
        muted = on
        let conn = connection
        let effective: Float = on ? 0 : volume
        Task { await conn?.setVolume(effective) }
    }

    func setSpectralNR(_ on: Bool) {
        spectralNR = on
        let conn = connection
        Task { await conn?.setSpectralNR(on) }
    }

    func setSpectralNRGainMethod(_ method: Int) {
        spectralNRGainMethod = method
        let conn = connection
        Task { await conn?.setSpectralNRGainMethod(method) }
    }

    func setSpectralNRNPEMethod(_ method: Int) {
        spectralNRNPEMethod = method
        let conn = connection
        Task { await conn?.setSpectralNRNPEMethod(method) }
    }

    func setSpectralNRArtifact(_ on: Bool) {
        spectralNRArtifact = on
        let conn = connection
        Task { await conn?.setSpectralNRArtifactReduction(on) }
    }

    func setLMSNR(_ on: Bool) {
        lmsNR = on
        let conn = connection
        Task { await conn?.setANR(on) }
    }

    func setLMSNRStrength(_ taps: Int) {
        lmsNRStrength = taps
        let conn = connection
        Task { await conn?.setANRStrength(taps) }
    }

    func setAutoNotch(_ on: Bool) {
        autoNotch = on
        let conn = connection
        Task { await conn?.setANF(on) }
    }

    func setNoiseBlanker(_ on: Bool) {
        noiseBlanker = on
        let conn = connection
        Task { await conn?.setNoiseBlanker(on) }
    }

    func setNoiseBlankerThreshold(_ threshold: Double) {
        noiseBlankerThreshold = threshold
        let conn = connection
        Task { await conn?.setNoiseBlankerThreshold(threshold) }
    }

    func setNoiseBlanker2(_ on: Bool) {
        noiseBlanker2 = on
        let conn = connection
        Task { await conn?.setNoiseBlanker2(on) }
    }

    func setNoiseBlanker2Mode(_ mode: Int) {
        noiseBlanker2Mode = mode
        let conn = connection
        Task { await conn?.setNoiseBlanker2Mode(mode) }
    }

    func setNoiseBlanker2Threshold(_ threshold: Double) {
        noiseBlanker2Threshold = threshold
        let conn = connection
        Task { await conn?.setNoiseBlanker2Threshold(threshold) }
    }

    func setSquelch(_ on: Bool) {
        squelch = on
        let conn = connection
        Task { await conn?.setSquelch(on) }
    }

    func setSquelchLevel(_ level: Double) {
        squelchLevel = level
        let conn = connection
        Task { await conn?.setSquelchLevel(level) }
    }

    func setSNB(_ on: Bool) {
        snb = on
        let conn = connection
        Task { await conn?.setSNB(on) }
    }

    func setAPF(_ on: Bool) {
        apf = on
        let conn = connection
        Task { await conn?.setAPF(on) }
    }

    func setAPFBandwidth(_ bw: Double) {
        apfBandwidth = bw
        let conn = connection
        Task { await conn?.setAPFBandwidth(bw) }
    }

    // MARK: - Manual notch filters (MNF)

    /// Maps the notch list to Sendable tuples and pushes it to the connection.
    private func pushManualNotches() {
        let conn = connection
        let notches = manualNotches.map { (freq: $0.frequencyHz, width: $0.widthHz, active: $0.active) }
        Task { await conn?.setManualNotches(notches) }
    }

    private func persistManualNotches() {
        if let data = try? JSONEncoder().encode(manualNotches) {
            UserDefaults.standard.set(data, forKey: "manualNotches")
        }
    }

    /// Adds a notch at the current VFO frequency (200 Hz wide) and enables MNF.
    func addManualNotchAtCurrentFrequency() {
        let notch = ManualNotch(id: nextNotchID, frequencyHz: Double(frequencyHz), widthHz: 200, active: true)
        nextNotchID += 1
        manualNotches.append(notch)
        if !manualNotchOn { setManualNotchRun(true) }
        persistManualNotches()
        pushManualNotches()
    }

    func removeManualNotch(id: Int) {
        manualNotches.removeAll { $0.id == id }
        persistManualNotches()
        pushManualNotches()
    }

    func setManualNotchActive(id: Int, active: Bool) {
        guard let k = manualNotches.firstIndex(where: { $0.id == id }) else { return }
        manualNotches[k].active = active
        persistManualNotches()
        pushManualNotches()
    }

    func setManualNotchRun(_ on: Bool) {
        manualNotchOn = on
        let conn = connection
        Task { await conn?.setManualNotchRun(on) }
    }

    // MARK: - TX processing

    func setPhaseRotator(_ on: Bool) {
        phaseRotator = on
        let conn = connection
        Task { await conn?.setPhaseRotator(on) }
    }

    func setLeveler(_ on: Bool) {
        leveler = on
        let conn = connection
        Task { await conn?.setLeveler(on) }
    }

    func setLevelerTop(_ db: Double) {
        levelerTop = db
        let conn = connection
        Task { await conn?.setLevelerTop(db) }
    }

    func setCFC(_ on: Bool) {
        cfc = on
        let conn = connection
        Task { await conn?.setCFC(on) }
    }

    func setCFCPrecomp(_ db: Double) {
        cfcPrecomp = db
        let conn = connection
        Task { await conn?.setCFCPrecomp(db) }
    }

    func setCFCEQ(_ on: Bool) {
        cfcEQ = on
        let conn = connection
        Task { await conn?.setCFCEQ(on) }
    }

    func setAGCMode(_ mode: Int) {
        agcMode = mode
        let conn = connection
        Task { await conn?.setAGCMode(mode) }
    }

    func setAGCThreshold(_ db: Double) {
        agcThreshold = db
        let conn = connection
        Task { await conn?.setAGCTop(db) }
    }

    func setRXAttenuator(_ db: Int) {
        rxAttenuator = db
        let conn = connection
        Task { await conn?.setRXAttenuator(UInt8(db)) }
    }

    /// True when the current/most recent radio is a Hermes Lite 2, which has an
    /// LNA gain control (−12…+48 dB) in place of the ANAN step attenuator.
    var isHermesLite: Bool { lastRadio?.board == .hermesLite }

    func setRXLNAGain(_ db: Int) {
        let clamped = max(-12, min(48, db))
        rxLNAGain = clamped
        UserDefaults.standard.set(clamped, forKey: "rxLNAGain")
        let conn = connection
        Task { await conn?.setRXLNAGain(clamped) }
    }

    /// Radio clock error in ppm. Takes effect immediately, so it can be adjusted
    /// live against a reference carrier (e.g. WWV) until it is centered.
    func setFrequencyPPM(_ ppm: Double) {
        let clamped = max(-100, min(100, ppm))
        frequencyPPM = clamped
        UserDefaults.standard.set(clamped, forKey: "frequencyPPM")
        let conn = connection
        Task { await conn?.setFrequencyCalibration(ppm: clamped) }
    }

    // MARK: - Automatic frequency calibration (WWV)

    private(set) var autoCalRunning = false
    private(set) var autoCalStatus = ""

    /// One-click calibration against WWV's atomic-clock carriers: tunes so the
    /// carrier sits 8 kHz above the panadapter center (clear of the DC spike),
    /// measures its offset from true over ~3 s of spectrum frames, converts to ppm,
    /// applies the correction, and restores the previous frequency. Tries 10, 15,
    /// 5, then 20 MHz until a carrier passes the SNR gate.
    func runAutoCalibration() async {
        guard !autoCalRunning else { return }
        guard isConnected, let spectrum = spectrumBuffer else {
            autoCalStatus = "Connect to a radio first."
            return
        }
        autoCalRunning = true
        let returnHz = frequencyHz
        defer {
            setFrequency(returnHz)
            autoCalRunning = false
        }

        for carrier in [10e6, 15e6, 5e6, 20e6] {
            autoCalStatus = "Measuring WWV \(Int(carrier / 1e6)) MHz…"
            let center = UInt32(carrier - 8_000)
            setFrequency(center)
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            guard let offset = await measureCarrierOffset(carrier: carrier, centerHz: center,
                                                          spectrum: spectrum) else { continue }
            // Measured with the current correction applied, so the offset is the
            // residual clock error: carrier below true = clock high = raise ppm.
            let residual = -offset / carrier * 1_000_000
            let total = ((frequencyPPM + residual) * 100).rounded() / 100
            setFrequencyPPM(total)
            autoCalStatus = String(format: "WWV %.0f MHz: carrier off %+.1f Hz → %+.2f ppm applied (total %+.2f ppm)",
                                   carrier / 1e6, offset, residual, total)
            return
        }
        autoCalStatus = "No usable WWV carrier (10/15/5/20 MHz). Try when propagation supports WWV, or calibrate manually."
    }

    /// Polls the spectrum for ~3 s and returns the median offset (Hz) of the
    /// strongest peak near `carrier` from its true frequency, or nil if the
    /// carrier never stands ≥12 dB above the surrounding noise.
    private func measureCarrierOffset(carrier: Double, centerHz: UInt32,
                                      spectrum: SpectrumBuffer) async -> Double? {
        var offsets: [Double] = []
        var lastGeneration: UInt64 = 0
        for _ in 0..<30 {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return nil }
            guard let frame = spectrum.latest(),
                  frame.generation != lastGeneration,
                  frame.centerHz == centerHz,
                  frame.data.count > 16 else { continue }
            lastGeneration = frame.generation
            let count = frame.data.count
            let binHz = Double(frame.spanHz) / Double(count)
            let expectedIndex = Double(count) / 2 + (carrier - Double(centerHz)) / binHz
            let halfWindow = max(300.0 / binHz, 4)
            let lo = max(1, Int(expectedIndex - halfWindow))
            let hi = min(count - 2, Int(expectedIndex + halfWindow))
            guard lo < hi else { continue }
            var peak = lo
            for i in lo...hi where frame.data[i] > frame.data[peak] { peak = i }
            let median = frame.data[lo...hi].sorted()[(hi - lo) / 2]
            guard frame.data[peak] - median >= 12 else { continue }
            // Parabolic interpolation over the peak's dB values for sub-bin accuracy.
            let y1 = Double(frame.data[peak - 1])
            let y2 = Double(frame.data[peak])
            let y3 = Double(frame.data[peak + 1])
            let denom = y1 - 2 * y2 + y3
            let delta = denom != 0 ? 0.5 * (y1 - y3) / denom : 0
            let peakHz = Double(centerHz) + (Double(peak) + delta - Double(count) / 2) * binHz
            offsets.append(peakHz - carrier)
        }
        // Require a solid majority of frames to have seen the carrier.
        guard offsets.count >= 10 else { return nil }
        return offsets.sorted()[offsets.count / 2]
    }

    private var driveByte: UInt8 { UInt8(max(0, min(255, driveLevel / 100 * 255))) }

    func setPTT(_ on: Bool) {
        isTransmitting = on
        if on { isTuning = false }
        let conn = connection
        Task { await conn?.setTransmit(on) }
    }

    func setTune(_ on: Bool) {
        isTuning = on
        if on { isTransmitting = false }
        let conn = connection
        Task { await conn?.setTune(on) }
    }

    func setDrive(_ percent: Double) {
        driveLevel = percent
        UserDefaults.standard.set(percent, forKey: "driveLevel")
        let conn = connection
        let level = driveByte
        Task { await conn?.setDrive(level) }
    }

    func setMicGain(_ gain: Double) {
        micGain = gain
        UserDefaults.standard.set(gain, forKey: "micGain")
        let conn = connection
        Task { await conn?.setMicGain(gain) }
    }

    /// Selects the mic input device by UID (nil = system default), persists it, and
    /// forwards to the connection. Takes effect on the next key-down.
    func setMicDevice(_ uid: String?) {
        selectedMicUID = uid
        UserDefaults.standard.set(uid, forKey: "selectedMicUID")
        let conn = connection
        Task { await conn?.setInputDevice(uid: uid) }
    }

    /// Selects the output device by UID (nil = system default), persists it, and
    /// forwards to the connection. Re-routes received audio immediately if streaming.
    func setOutputDevice(_ uid: String?) {
        selectedOutputUID = uid
        UserDefaults.standard.set(uid, forKey: "selectedOutputUID")
        let conn = connection
        Task { await conn?.setOutputDevice(uid: uid) }
    }

    /// Applies a transmit processing preset: compressor on/off + gain, and CESSB on DX+.
    func setTXProcessing(_ profile: TXProcessing) {
        txProcessing = profile
        UserDefaults.standard.set(profile.rawValue, forKey: "txProcessing")
        let conn = connection
        let on = profile.compressorOn
        let gain = profile.compressorGain
        let cessb = profile.usesCESSB
        Task {
            await conn?.setSpeechProcessor(on, gain: gain)
            await conn?.setCESSB(cessb)
        }
    }

    func setTXLowCut(_ hz: Double) {
        txLowCut = hz
        let conn = connection
        let low = txLowCut, high = txHighCut
        Task { await conn?.setTXBandwidth(low: low, high: high) }
    }

    func setTXHighCut(_ hz: Double) {
        txHighCut = hz
        let conn = connection
        let low = txLowCut, high = txHighCut
        Task { await conn?.setTXBandwidth(low: low, high: high) }
    }

    func setTXEQ(_ on: Bool) {
        txEQ = on
        let conn = connection
        Task { await conn?.setTXEQ(on: on) }
    }

    private func pushTXEQGains() {
        let conn = connection
        let p = txEQPreamp, l = txEQLow, m = txEQMid, h = txEQHigh
        Task { await conn?.setTXEQGains(preamp: p, low: l, mid: m, high: h) }
    }

    func setTXEQPreamp(_ v: Int) { txEQPreamp = v; pushTXEQGains() }
    func setTXEQLow(_ v: Int) { txEQLow = v; pushTXEQGains() }
    func setTXEQMid(_ v: Int) { txEQMid = v; pushTXEQGains() }
    func setTXEQHigh(_ v: Int) { txEQHigh = v; pushTXEQGains() }

    func setRXEQ(_ on: Bool) {
        rxEQ = on
        let conn = connection
        Task { await conn?.setRXEQ(on: on) }
    }

    private func pushRXEQGains() {
        let conn = connection
        let p = rxEQPreamp, l = rxEQLow, m = rxEQMid, h = rxEQHigh
        Task { await conn?.setRXEQGains(preamp: p, low: l, mid: m, high: h) }
    }

    func setRXEQPreamp(_ v: Int) { rxEQPreamp = v; pushRXEQGains() }
    func setRXEQLow(_ v: Int) { rxEQLow = v; pushRXEQGains() }
    func setRXEQMid(_ v: Int) { rxEQMid = v; pushRXEQGains() }
    func setRXEQHigh(_ v: Int) { rxEQHigh = v; pushRXEQGains() }

    /// Sends a raw open-collector pattern to the radio (live; used for amp band
    /// data and for calibration). No effect if not connected.
    func setOpenCollector(_ value: UInt8) {
        let conn = connection
        Task { await conn?.setOpenCollector(value) }
    }

    // MARK: - Receive slices (multiple receivers)

    /// Adds a receive slice (up to the app maximum), tuned to the current main VFO.
    func addSlice() {
        guard activeSliceCount < Self.maxSlices else { return }
        let index = activeSliceCount
        let info = SliceInfo(id: index, frequencyHz: frequencyHz, mode: mode, volume: 0.5, pan: 0)
        extraSlices.append(info)
        let conn = connection
        let n = activeSliceCount
        Task {
            await conn?.setActiveSliceCount(n)
            await conn?.setFrequency(info.frequencyHz, receiver: index)
            await conn?.setMode(info.mode, slice: index)
            await conn?.setVolume(info.volume, slice: index)
            await conn?.setPan(info.pan, slice: index)
        }
    }

    /// Removes the highest-numbered receive slice.
    func removeSlice() {
        guard !extraSlices.isEmpty else { return }
        extraSlices.removeLast()
        let conn = connection
        let n = activeSliceCount
        Task { await conn?.setActiveSliceCount(n) }
    }

    func setSliceFrequency(_ index: Int, _ hz: UInt32) {
        guard let k = extraSlices.firstIndex(where: { $0.id == index }) else { return }
        extraSlices[k].frequencyHz = hz
        let conn = connection
        Task { await conn?.setFrequency(hz, receiver: index) }
    }

    func setSliceMode(_ index: Int, _ newMode: RadioMode) {
        guard let k = extraSlices.firstIndex(where: { $0.id == index }) else { return }
        extraSlices[k].mode = newMode
        let conn = connection
        Task { await conn?.setMode(newMode, slice: index) }
    }

    func setSliceVolume(_ index: Int, _ v: Float) {
        guard let k = extraSlices.firstIndex(where: { $0.id == index }) else { return }
        extraSlices[k].volume = v
        let conn = connection
        Task { await conn?.setVolume(v, slice: index) }
    }

    func setSlicePan(_ index: Int, _ p: Float) {
        guard let k = extraSlices.firstIndex(where: { $0.id == index }) else { return }
        extraSlices[k].pan = p
        let conn = connection
        Task { await conn?.setPan(p, slice: index) }
    }

    /// Connects to the last radio if disconnected, or disconnects if connected.
    func toggleConnection() {
        if isConnected {
            disconnect()
        } else if let radio = lastRadio {
            connect(to: radio)
        }
    }

    /// Runs a keyboard-shortcut command by its id.
    func execute(commandID id: String) {
        if id.hasPrefix("band.") {
            let bandID = String(id.dropFirst("band.".count))
            if let band = Band.all.first(where: { $0.id == bandID }) {
                setMode(band.mode)
                setFrequency(band.frequencyHz)   // also updates amp band data
            }
        } else if id.hasPrefix("mode.") {
            let raw = String(id.dropFirst("mode.".count))
            if let newMode = RadioMode(rawValue: raw) { setMode(newMode) }
        } else {
            switch id {
            case "tune.up":         tuneBy(steps: 1)
            case "tune.down":       tuneBy(steps: -1)
            case "filter.narrower": adjustFilter(narrower: true)
            case "filter.wider":    adjustFilter(narrower: false)
            case "nr.toggle":       setSpectralNR(!spectralNR)
            case "audio.mute":      setMute(!muted)
            case "volume.up":       setVolume(min(1, volume + 0.05))
            case "volume.down":     setVolume(max(0, volume - 0.05))
            case "tx.ptt":          setPTT(!isTransmitting)
            case "tx.tune":         setTune(!isTuning)
            case "drive.up":        setDrive(min(100, driveLevel + 5))
            case "drive.down":      setDrive(max(0, driveLevel - 5))
            case "connection.toggle": toggleConnection()
            default: break
            }
        }
    }

    private func adjustFilter(narrower: Bool) {
        let sign: Double = narrower ? -1 : 1
        if mode.filterStyle == .cw {
            let range = mode.widthRange
            setFilterWidth(min(range.upperBound, max(range.lowerBound, filterWidth + sign * 50)))
        } else {
            let range = mode.highCutRange
            setHighCut(min(range.upperBound, max(range.lowerBound, filterHigh + sign * 100)))
        }
    }

    /// Pushes the current mode/volume/NR to a freshly-started connection.
    private func applyAudioSettings() {
        let conn = connection
        let m = mode
        let v = muted ? 0 : volume
        let snr = spectralNR
        let snrGain = spectralNRGainMethod
        let snrNPE = spectralNRNPEMethod
        let snrArt = spectralNRArtifact
        let anr = lmsNR
        let anrStrength = lmsNRStrength
        let anf = autoNotch
        let nb = noiseBlanker
        let nbThresh = noiseBlankerThreshold
        let nb2 = noiseBlanker2
        let nb2Mode = noiseBlanker2Mode
        let nb2Thresh = noiseBlanker2Threshold
        let sql = squelch
        let sqlLevel = squelchLevel
        let snbOn = snb
        let apfOn = apf
        let apfBW = apfBandwidth
        let notches = manualNotches.map { (freq: $0.frequencyHz, width: $0.widthHz, active: $0.active) }
        let notchRun = manualNotchOn
        let notchTuneFreq = Double(frequencyHz)
        let phrot = phaseRotator
        let lev = leveler
        let levTop = levelerTop
        let cfcOn = cfc
        let cfcPre = cfcPrecomp
        let cfcEqOn = cfcEQ
        let agc = agcMode
        let agcT = agcThreshold
        let atten = rxAttenuator
        let pitch = cwPitch
        let width = filterWidth
        let low = filterLow
        let high = filterHigh
        let drive = driveByte
        let mg = micGain
        let micUID = selectedMicUID
        let proc = txProcessing
        let txLo = txLowCut, txHi = txHighCut
        let txeqOn = txEQ
        let txeqP = txEQPreamp, txeqL = txEQLow, txeqM = txEQMid, txeqH = txEQHigh
        let rxeqOn = rxEQ
        let rxeqP = rxEQPreamp, rxeqL = rxEQLow, rxeqM = rxEQMid, rxeqH = rxEQHigh
        let extras = extraSlices
        // Detect the band for the current frequency so the amp is set on connect.
        var bandOC: UInt8?
        if bandData.enabled, let band = Band.band(for: frequencyHz) {
            lastBandID = band.id
            currentBandOC = bandData.value(for: band.id)
            bandOC = currentBandOC
        }
        Task {
            await conn?.setMode(m)
            await conn?.setVolume(v)
            await conn?.setSpectralNRGainMethod(snrGain)
            await conn?.setSpectralNRNPEMethod(snrNPE)
            await conn?.setSpectralNRArtifactReduction(snrArt)
            await conn?.setSpectralNR(snr)
            await conn?.setANRStrength(anrStrength)
            await conn?.setANR(anr)
            await conn?.setANF(anf)
            await conn?.setNoiseBlankerThreshold(nbThresh)
            await conn?.setNoiseBlanker(nb)
            await conn?.setNoiseBlanker2Mode(nb2Mode)
            await conn?.setNoiseBlanker2Threshold(nb2Thresh)
            await conn?.setNoiseBlanker2(nb2)
            await conn?.setSquelchLevel(sqlLevel)
            await conn?.setSquelch(sql)
            await conn?.setSNB(snbOn)
            await conn?.setAPFBandwidth(apfBW)
            await conn?.setAPF(apfOn)
            await conn?.setTuneFrequency(notchTuneFreq)
            await conn?.setManualNotches(notches)
            await conn?.setManualNotchRun(notchRun)
            await conn?.setPhaseRotator(phrot)
            await conn?.setLevelerTop(levTop)
            await conn?.setLeveler(lev)
            await conn?.setCFCPrecomp(cfcPre)
            await conn?.setCFCEQ(cfcEqOn)
            await conn?.setCFC(cfcOn)
            await conn?.setAGCMode(agc)
            await conn?.setAGCTop(agcT)
            await conn?.setRXAttenuator(UInt8(atten))
            await conn?.setCWPitch(pitch)
            await conn?.setFilterWidth(width)
            await conn?.setLowCut(low)
            await conn?.setHighCut(high)
            await conn?.setDrive(drive)
            await conn?.setMicGain(mg)
            await conn?.setInputDevice(uid: micUID)
            await conn?.setSpeechProcessor(proc.compressorOn, gain: proc.compressorGain)
            await conn?.setTXBandwidth(low: txLo, high: txHi)
            await conn?.setTXEQGains(preamp: txeqP, low: txeqL, mid: txeqM, high: txeqH)
            await conn?.setTXEQ(on: txeqOn)
            await conn?.setCESSB(proc.usesCESSB)
            await conn?.setRXEQGains(preamp: rxeqP, low: rxeqL, mid: rxeqM, high: rxeqH)
            await conn?.setRXEQ(on: rxeqOn)
            if let bandOC { await conn?.setOpenCollector(bandOC) }
            // Push each extra slice's VFO after the main receiver is configured.
            for slice in extras {
                await conn?.setMode(slice.mode, slice: slice.id)
                await conn?.setFrequency(slice.frequencyHz, receiver: slice.id)
                await conn?.setVolume(slice.volume, slice: slice.id)
                await conn?.setPan(slice.pan, slice: slice.id)
            }
        }
    }
}

// The CAT command surface. Everything but signalRMS is satisfied by existing members.
extension RadioSession: CATRadioControl {
    var signalRMS: Float { lastUpdate?.signalRMS ?? 0 }
}
