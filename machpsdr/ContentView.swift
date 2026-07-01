import SwiftUI

@main struct MyApp: App {
    @State private var session = RadioSession()
    @State private var shortcuts = ShortcutStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(session)
                .environment(shortcuts)
        }
        .defaultSize(width: 760, height: 520)

        Settings {
            SettingsView()
                .environment(shortcuts)
                .environment(session)
        }
    }
}

/// Observable model that scans the local network for HPSDR radios.
@MainActor
@Observable
final class RadioBrowser {
    var radios: [DiscoveredRadio] = []
    var isScanning = false
    var errorMessage: String?

    private let discovery = RadioDiscovery()

    func scan() async {
        isScanning = true
        errorMessage = nil
        defer { isScanning = false }
        do {
            radios = try await discovery.discover()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Transmit audio processing presets. Higher tiers compress harder for more talk
/// power; DX+ also enables CESSB (controlled-envelope SSB) for maximum average power.
nonisolated enum TXProcessing: String, CaseIterable, Identifiable, Sendable {
    case off = "Off"
    case normal = "Normal"
    case dx = "DX"
    case dxPlus = "DX+"

    var id: String { rawValue }
    var compressorOn: Bool { self != .off }
    var compressorGain: Double {
        switch self {
        case .off:    return 0
        case .normal: return 3
        case .dx:     return 7
        case .dxPlus: return 10
        }
    }
    var usesCESSB: Bool { self == .dxPlus }
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
    // AGC + front-end gain
    var agcMode = 3                     // 0 off, 1 long, 2 slow, 3 medium, 4 fast
    var agcThreshold = 90.0             // AGC-T (max gain, dB)
    var rxAttenuator = 0                // RX ADC step attenuator, 0-31 dB (0 = preamp)
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

    let midi = MIDIManager()
    let bandData = BandDataStore()
    private var currentBandOC: UInt8 = 0
    private var lastBandID: String?

    init() {
        selectedMicUID = UserDefaults.standard.string(forKey: "selectedMicUID")
        selectedOutputUID = UserDefaults.standard.string(forKey: "selectedOutputUID")
        midi.onTuneStep = { [weak self] steps in
            guard let self, self.midiTuningEnabled else { return }
            self.tuneBy(steps: steps)
        }
        midi.start()
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
        settings.receiverFrequencies = [frequencyHz]
        settings.transmitFrequency = frequencyHz
        let conn = RadioConnection(radio: radio, settings: settings)
        connection = conn
        spectrumBuffer = conn.spectrum
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
        let conn = connection
        let level = driveByte
        Task { await conn?.setDrive(level) }
    }

    func setMicGain(_ gain: Double) {
        micGain = gain
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
        }
    }
}

struct ContentView: View {
    @Environment(RadioSession.self) private var session
    @Environment(ShortcutStore.self) private var shortcuts
    @State private var browser = RadioBrowser()
    @State private var selection: DiscoveredRadio.ID?
    @State private var keyMonitor = ShortcutKeyMonitor()

    var body: some View {
        NavigationSplitView {
            radioList
                .navigationTitle("Radios")
                .toolbar {
                    ToolbarItem {
                        Button {
                            Task { await browser.scan() }
                        } label: {
                            Label("Scan", systemImage: "antenna.radiowaves.left.and.right")
                        }
                        .disabled(browser.isScanning)
                    }
                }
        } detail: {
            detail
        }
        .task {
            await browser.scan()
        }
        .onAppear { keyMonitor.install(store: shortcuts, session: session) }
        .onDisappear { keyMonitor.remove() }
    }

    @ViewBuilder
    private var radioList: some View {
        List(selection: $selection) {
            if let errorMessage = browser.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            ForEach(browser.radios) { radio in
                VStack(alignment: .leading, spacing: 2) {
                    Text(radio.board.displayName)
                        .font(.headline)
                    Text(radio.ipAddress)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .tag(radio.id)
            }
        }
        .overlay {
            if browser.isScanning && browser.radios.isEmpty {
                ProgressView("Scanning…")
            } else if browser.radios.isEmpty {
                ContentUnavailableView(
                    "No radios found",
                    systemImage: "antenna.radiowaves.left.and.right.slash",
                    description: Text("Make sure your ANAN-10E is powered on and on the same network, then scan again.")
                )
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selection, let radio = browser.radios.first(where: { $0.id == selection }) {
            RadioDetailView(radio: radio, session: session)
        } else {
            ContentUnavailableView("Select a radio", systemImage: "dot.radiowaves.left.and.right")
        }
    }
}

/// Hold-to-talk button. Press state is tracked with `@GestureState`, which the gesture
/// system owns and resets automatically — so frequent parent re-renders (the live status
/// stream updates ~10×/sec) can't spuriously fire a release and un-key the transmitter.
private struct PTTButton: View {
    let isKeyed: Bool
    let onPressChange: (Bool) -> Void
    @GestureState private var pressing = false

    var body: some View {
        Text("Transmit")
            .fontWeight(.medium)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(isKeyed ? Color.red : Color.secondary.opacity(0.2),
                        in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(isKeyed ? .white : .primary)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($pressing) { _, state, _ in state = true }
            )
            .onChange(of: pressing) { _, now in onPressChange(now) }
            .accessibilityLabel("Transmit, push to talk")
            .accessibilityAddTraits(.isButton)
    }
}

/// Radio detail: connection controls, tuning, and a live status readout proving the I/Q stream.
struct RadioDetailView: View {
    let radio: DiscoveredRadio
    @Bindable var session: RadioSession

    /// Frequency shown in the text field, in MHz.
    @State private var frequencyMHz: Double = 7.1

    var body: some View {
        VStack(spacing: 0) {
            if session.isConnected, let spectrum = session.spectrumBuffer {
                SpectrumView(spectrum: spectrum) { hz in
                    session.setFrequency(hz)
                    frequencyMHz = Double(hz) / 1_000_000
                }
                .frame(minHeight: 260)
            }

            Form {
                Section("Radio") {
                    LabeledContent("Board", value: radio.board.displayName)
                    LabeledContent("IP Address", value: radio.ipAddress)
                    LabeledContent("MAC Address", value: radio.macAddress)
                    LabeledContent("Firmware", value: radio.firmwareVersion)
                }

                Section("Connection") {
                    connectionControls
                }

                Section("MIDI Tuning") {
                    midiControls
                }

                if session.isConnected {
                    Section("Tuning") {
                        tuningControls
                    }
                    Section("AGC & RF Gain") {
                        agcControls
                    }
                    Section("Noise Reduction") {
                        noiseReductionControls
                    }
                    Section("RX Equalizer") {
                        rxAudioControls
                    }
                    Section("Transmit") {
                        transmitControls
                    }
                    Section("TX Audio") {
                        txAudioControls
                    }
                    Section("Live Stream") {
                        liveStatus
                    }
                }
            }
            .formStyle(.grouped)
        }
        .navigationTitle(radio.board.displayName)
        .onChange(of: radio.id) { _, _ in
            session.disconnect()
        }
        // Keep the frequency field in sync with MIDI/click tuning.
        .onChange(of: session.frequencyHz) { _, newValue in
            frequencyMHz = Double(newValue) / 1_000_000
        }
        .onAppear { frequencyMHz = Double(session.frequencyHz) / 1_000_000 }
        .onDisappear { session.disconnect() }
    }

    /// Mode-appropriate filter controls: CW pitch+width, SSB/DIGI low+high cut,
    /// or a single bandwidth for AM/SAM/FM.
    @ViewBuilder
    private var transmitControls: some View {
        HStack {
            // Push-to-talk: held down to transmit, released to receive.
            PTTButton(isKeyed: session.isTransmitting) { session.setPTT($0) }
            Toggle("Tune", isOn: Binding(
                get: { session.isTuning },
                set: { session.setTune($0) }
            ))
            .toggleStyle(.button)
            .tint(.red)
        }
        Text("Hold Transmit (or your assigned PTT shortcut) to talk; release to receive.")
            .font(.caption)
            .foregroundStyle(.secondary)
        HStack {
            Text("Drive")
            Slider(value: Binding(
                get: { session.driveLevel },
                set: { session.setDrive($0) }
            ), in: 0...100, step: 1)
            Text("\(Int(session.driveLevel)) %")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        HStack {
            Text("Mic Gain")
            Slider(value: Binding(
                get: { session.micGain },
                set: { session.setMicGain($0) }
            ), in: 0...4, step: 0.1)
            Text(String(format: "%.1f×", session.micGain))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        if session.isTransmitting || session.isTuning {
            Label("Transmitting", systemImage: "dot.radiowaves.left.and.right")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var filterControls: some View {
        switch session.mode.filterStyle {
        case .cw:
            labeledSlider("CW Pitch", value: session.cwPitch, range: 300...1000) { session.setCWPitch($0) }
            labeledSlider("Width", value: session.filterWidth, range: session.mode.widthRange) { session.setFilterWidth($0) }
        case .lowHigh:
            labeledSlider("Low Cut", value: session.filterLow, range: session.mode.lowCutRange) { session.setLowCut($0) }
            labeledSlider("High Cut", value: session.filterHigh, range: session.mode.highCutRange) { session.setHighCut($0) }
        case .bandwidth:
            labeledSlider("Bandwidth", value: session.filterHigh, range: session.mode.highCutRange) { session.setHighCut($0) }
        }
    }

    private func labeledSlider(_ label: String,
                               value: Double,
                               range: ClosedRange<Double>,
                               onChange: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(label)
            Slider(value: Binding(get: { value }, set: { onChange($0) }), in: range, step: 10)
            Text("\(Int(value)) Hz").monospacedDigit().foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var midiControls: some View {
        if session.midi.sourceNames.isEmpty {
            Label("No MIDI device detected", systemImage: "pianokeys")
                .foregroundStyle(.secondary)
        } else {
            ForEach(session.midi.sourceNames, id: \.self) { name in
                Label(name, systemImage: "pianokeys")
            }
        }
        Toggle("Tune with MIDI knob", isOn: $session.midiTuningEnabled)
        Picker("Tuning Step", selection: $session.midiTuningStepHz) {
            Text("10 Hz").tag(10)
            Text("100 Hz").tag(100)
            Text("1 kHz").tag(1000)
        }
        Button("Rescan MIDI") { session.midi.rescan() }
        // Always-visible monitor — a DisclosureGroup was not operable via VoiceOver.
        Text("Monitor (recent MIDI)")
            .font(.caption)
            .foregroundStyle(.secondary)
        if session.midi.log.isEmpty {
            Text("Turn the knob or press a button to see messages.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(session.midi.log.suffix(6)) { entry in
                Text(entry.text).font(.caption.monospaced())
            }
        }
    }

    @ViewBuilder
    private var connectionControls: some View {
        switch session.state {
        case .disconnected:
            Button("Connect") { session.connect(to: radio) }
        case .connecting:
            HStack { ProgressView().controlSize(.small); Text("Connecting…") }
        case .streaming:
            Button("Disconnect", role: .destructive) { session.disconnect() }
        case .failed(let message):
            VStack(alignment: .leading) {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                Button("Retry") { session.connect(to: radio) }
            }
        }
    }

    @ViewBuilder
    private var tuningControls: some View {
        HStack {
            Text("Frequency")
            Spacer()
            TextField("MHz", value: $frequencyMHz, format: .number.precision(.fractionLength(6)))
                .frame(width: 120)
                .multilineTextAlignment(.trailing)
                .onSubmit { session.setFrequency(UInt32((frequencyMHz * 1_000_000).rounded())) }
            Text("MHz").foregroundStyle(.secondary)
        }
        Picker("Sample Rate", selection: Binding(
            get: { session.sampleRate },
            set: { session.setSampleRate($0) }
        )) {
            ForEach(HPSDRProtocol1.SampleRate.allCases, id: \.self) { rate in
                Text("\(rate.hertz / 1000) kHz").tag(rate)
            }
        }
        // Default (pop-up menu) picker style — avoids the VoiceOver focus trap
        // that the segmented style caused in the mode selector.
        Picker("Mode", selection: Binding(
            get: { session.mode },
            set: { session.setMode($0) }
        )) {
            ForEach(RadioMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        filterControls
        HStack {
            Button {
                session.setMute(!session.muted)
            } label: {
                Image(systemName: session.muted ? "speaker.slash.fill" : "speaker.fill")
                    .foregroundStyle(session.muted ? .red : .primary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(session.muted ? "Unmute" : "Mute")
            Slider(value: Binding(
                get: { Double(session.volume) },
                set: { session.setVolume(Float($0)) }
            ), in: 0...1)
            Image(systemName: "speaker.wave.3.fill")
        }
    }

    /// AGC time-constant profile, the AGC-T (max-gain) knob, and the RX front-end
    /// step attenuator (0 dB = max gain / preamp).
    @ViewBuilder
    private var agcControls: some View {
        Picker("AGC", selection: Binding(
            get: { session.agcMode },
            set: { session.setAGCMode($0) }
        )) {
            Text("Off").tag(0)
            Text("Long").tag(1)
            Text("Slow").tag(2)
            Text("Medium").tag(3)
            Text("Fast").tag(4)
        }
        HStack {
            Text("AGC-T")
            Slider(value: Binding(
                get: { session.agcThreshold },
                set: { session.setAGCThreshold($0) }
            ), in: -20...120, step: 1)
            Text("\(Int(session.agcThreshold)) dB")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        HStack {
            Text("RX Atten")
            Slider(value: Binding(
                get: { Double(session.rxAttenuator) },
                set: { session.setRXAttenuator(Int($0)) }
            ), in: 0...31, step: 1)
            Text("\(session.rxAttenuator) dB")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        Text("RX Atten 0 dB = maximum gain (preamp) for quiet bands like 20 m; raise it to tame strong signals or noise on the low bands.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// Receiver noise-reduction controls: EMNR spectral subtraction (with mode and
    /// artifact reduction), ANR (LMS), and ANF auto-notch.
    @ViewBuilder
    private var noiseReductionControls: some View {
        Toggle("Spectral NR (NR2)", isOn: Binding(
            get: { session.spectralNR },
            set: { session.setSpectralNR($0) }
        ))
        if session.spectralNR {
            Picker("NR2 Mode", selection: Binding(
                get: { session.spectralNRGainMethod },
                set: { session.setSpectralNRGainMethod($0) }
            )) {
                Text("Linear").tag(0)
                Text("Log").tag(1)
                Text("Gamma").tag(2)
            }
            Picker("Noise Estimate", selection: Binding(
                get: { session.spectralNRNPEMethod },
                set: { session.setSpectralNRNPEMethod($0) }
            )) {
                Text("OSMS").tag(0)
                Text("MMSE").tag(1)
            }
            Toggle("Reduce Artifacts", isOn: Binding(
                get: { session.spectralNRArtifact },
                set: { session.setSpectralNRArtifact($0) }
            ))
        }
        Toggle("LMS NR (NR)", isOn: Binding(
            get: { session.lmsNR },
            set: { session.setLMSNR($0) }
        ))
        if session.lmsNR {
            HStack {
                Text("NR Strength")
                Slider(value: Binding(
                    get: { Double(session.lmsNRStrength) },
                    set: { session.setLMSNRStrength(Int($0)) }
                ), in: 16...128, step: 8)
                Text("\(session.lmsNRStrength)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        Toggle("Auto-Notch (ANF)", isOn: Binding(
            get: { session.autoNotch },
            set: { session.setAutoNotch($0) }
        ))
        Toggle("Noise Blanker (NB)", isOn: Binding(
            get: { session.noiseBlanker },
            set: { session.setNoiseBlanker($0) }
        ))
        if session.noiseBlanker {
            HStack {
                Text("NB Threshold")
                Slider(value: Binding(
                    get: { session.noiseBlankerThreshold },
                    set: { session.setNoiseBlankerThreshold($0) }
                ), in: 1.5...10, step: 0.1)
                Text(String(format: "%.1f×", session.noiseBlankerThreshold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        Toggle("Noise Blanker 2 (NB2)", isOn: Binding(
            get: { session.noiseBlanker2 },
            set: { session.setNoiseBlanker2($0) }
        ))
        if session.noiseBlanker2 {
            Picker("NB2 Fill", selection: Binding(
                get: { session.noiseBlanker2Mode },
                set: { session.setNoiseBlanker2Mode($0) }
            )) {
                Text("Zero").tag(0)
                Text("Sample-Hold").tag(1)
                Text("Mean-Hold").tag(2)
                Text("Hold-Sample").tag(3)
                Text("Interpolate").tag(4)
            }
            HStack {
                Text("NB2 Threshold")
                Slider(value: Binding(
                    get: { session.noiseBlanker2Threshold },
                    set: { session.setNoiseBlanker2Threshold($0) }
                ), in: 1.5...10, step: 0.1)
                Text(String(format: "%.1f×", session.noiseBlanker2Threshold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// RX 3-band graphic equalizer.
    @ViewBuilder
    private var rxAudioControls: some View {
        Toggle("RX Equalizer", isOn: Binding(
            get: { session.rxEQ },
            set: { session.setRXEQ($0) }
        ))
        if session.rxEQ {
            eqSlider("Preamp", value: session.rxEQPreamp) { session.setRXEQPreamp($0) }
            eqSlider("Low", value: session.rxEQLow) { session.setRXEQLow($0) }
            eqSlider("Mid", value: session.rxEQMid) { session.setRXEQMid($0) }
            eqSlider("High", value: session.rxEQHigh) { session.setRXEQHigh($0) }
        }
    }

    /// TX passband (low/high cut) and the 3-band transmit equalizer.
    @ViewBuilder
    private var txAudioControls: some View {
        HStack {
            Text("TX Low")
            Slider(value: Binding(
                get: { session.txLowCut },
                set: { session.setTXLowCut($0) }
            ), in: 0...1000, step: 10)
            Text("\(Int(session.txLowCut)) Hz")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        HStack {
            Text("TX High")
            Slider(value: Binding(
                get: { session.txHighCut },
                set: { session.setTXHighCut($0) }
            ), in: 2000...4000, step: 50)
            Text("\(Int(session.txHighCut)) Hz")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        Text("Narrow (e.g. 100–2800 Hz) for punch and DX; wider for ESSB ragchew audio.")
            .font(.caption)
            .foregroundStyle(.secondary)
        Toggle("TX Equalizer", isOn: Binding(
            get: { session.txEQ },
            set: { session.setTXEQ($0) }
        ))
        if session.txEQ {
            eqSlider("Preamp", value: session.txEQPreamp) { session.setTXEQPreamp($0) }
            eqSlider("Low", value: session.txEQLow) { session.setTXEQLow($0) }
            eqSlider("Mid", value: session.txEQMid) { session.setTXEQMid($0) }
            eqSlider("High", value: session.txEQHigh) { session.setTXEQHigh($0) }
        }
        Picker("Processing", selection: Binding(
            get: { session.txProcessing },
            set: { session.setTXProcessing($0) }
        )) {
            ForEach(TXProcessing.allCases) { profile in
                Text(profile.rawValue).tag(profile)
            }
        }
        Text("Off: clean. Normal: light compression. DX: heavier compression for talk power. DX+: adds CESSB for maximum average power.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// One ±12 dB EQ band row (shared by TX and RX equalizers).
    private func eqSlider(_ label: String, value: Int, onChange: @escaping (Int) -> Void) -> some View {
        HStack {
            Text(label).frame(width: 60, alignment: .leading)
            Slider(value: Binding(
                get: { Double(value) },
                set: { onChange(Int($0.rounded())) }
            ), in: -12...12, step: 1)
            Text("\(value > 0 ? "+" : "")\(value) dB")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var liveStatus: some View {
        let update = session.lastUpdate
        LabeledContent("Packet Rate", value: update.map { "\($0.packetsPerSecond) /s" } ?? "—")
        LabeledContent("Sequence Gaps", value: update.map { "\($0.sequenceGaps)" } ?? "—")
        LabeledContent("ADC Overflow") {
            Image(systemName: (update?.status.adcOverflow ?? false) ? "exclamationmark.triangle.fill" : "checkmark.circle")
                .foregroundStyle((update?.status.adcOverflow ?? false) ? .red : .green)
        }
        LabeledContent("PTT") {
            Image(systemName: (update?.status.ptt ?? false) ? "mic.fill" : "mic.slash")
                .foregroundStyle((update?.status.ptt ?? false) ? .red : .secondary)
        }
        signalMeter(rms: update?.signalRMS ?? 0)
    }

    @ViewBuilder
    private func signalMeter(rms: Float) -> some View {
        let dbfs = rms > 0 ? 20 * log10(rms) : -120
        let fraction = max(0, min(1, (Double(dbfs) + 120) / 120))
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Signal Level")
                Spacer()
                Text(String(format: "%.0f dBFS", dbfs)).foregroundStyle(.secondary).monospacedDigit()
            }
            ProgressView(value: fraction)
        }
    }
}

#Preview {
    ContentView()
}
