import Foundation
import FT8Kit
import UserNotifications

/// One decoded message as shown in the FT8 activity table.
struct FT8DecodeEntry: Identifiable, Sendable {
    let id = UUID()
    let slotIndex: Int
    let slotStart: Date
    let decode: FT8Decode
    let parsed: FT8ParsedMessage
    /// Message is directed at our callsign.
    let addressedToMe: Bool
    /// Message tripped a callsign alert.
    let isAlert: Bool

    var utcTime: String {
        let f = DateFormatter()
        f.dateFormat = "HHmmss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: slotStart)
    }
}

/// A completed QSO with context, ready for the future logging integrations.
struct FT8LoggedQSO: Identifiable, Sendable {
    let id = UUID()
    let record: FT8QSORecord
    let date: Date
    let mode: FTxProtocolMode
    let dialFrequencyHz: UInt32
}

/// Orchestrates native FT8/FT4 operation: tunes the radio, runs the decode
/// worker, drives the QSO autosequencer, schedules transmissions on slot
/// boundaries, and raises callsign alerts.
@MainActor @Observable final class FT8Controller {

    enum DisplayFilter: String, CaseIterable, Identifiable {
        case all = "All traffic"
        case cqOnly = "CQ calls only"
        case toMe = "Calling me"
        var id: String { rawValue }
    }

    enum TxSlotPreference: String, CaseIterable, Identifiable {
        case auto = "Auto"
        case even = "Even (:00/:30)"
        case odd = "Odd (:15/:45)"
        var id: String { rawValue }
    }

    // MARK: - Configuration (persisted)

    private(set) var mode: FTxProtocolMode = .ft8
    private(set) var selectedBandID: String = "20m"
    var useCustomFrequency = false { didSet { persistSettings(); retuneIfRunning() } }
    var customFrequencyHz: UInt32 = 14_074_000 { didSet { persistSettings(); retuneIfRunning() } }
    /// TX audio offset within the passband, Hz.
    var txOffsetHz: Double = 1_500 { didSet { persistSettings() } }
    var autoSequence = true { didSet { persistSettings() } }
    /// Auto-answer stations replying to my CQ.
    var autoAnswerReplies = true { didSet { persistSettings() } }
    /// Automatically call CQing stations.
    var autoAnswerCQs = false { didSet { persistSettings() } }
    var answerPolicy = FT8AutoAnswerPolicy() { didSet { persistSettings() } }
    var preferRR73 = true { didSet { persistSettings(); syncEngineConfig() } }
    /// DXpedition hound mode (working split-frequency foxes).
    var houndMode = false { didSet { persistSettings(); syncEngineConfig() } }
    var txSlotPreference: TxSlotPreference = .auto { didSet { persistSettings() } }
    var displayFilter: DisplayFilter = .all
    var cqModifier: String = "" { didSet { persistSettings() } }

    // MARK: - Live state

    private(set) var isRunning = false
    private(set) var isTransmitting = false
    /// Transmissions enabled (the "Halt TX" switch).
    var txEnabled = true {
        didSet { if !txEnabled { haltTransmissions() } }
    }
    private(set) var decodes: [FT8DecodeEntry] = []
    private(set) var qsoLog: [FT8LoggedQSO] = []
    private(set) var statusText = "Stopped"
    private(set) var currentTxText: String?
    private(set) var lastSlotIndex = 0
    /// Stations currently calling us (for the "someone is calling you" banner).
    private(set) var incomingCallers: [FT8DecodeEntry] = []

    let station: StationConfigStore
    let alerts: FT8AlertStore

    var engine: FT8QSOEngine
    private let session: RadioSession
    private var worker: FT8SlotWorker?
    private var tapRing: AudioRingBuffer?
    private(set) var workedCalls: Set<String> = []

    /// Slot parity (slotIndex % 2) we transmit on; nil = not yet chosen.
    private var txParity: Int?
    private var pendingTxText: String?
    private var pendingWaveform: [Float]?
    private var txGeneration = 0
    private static let maxDecodesShown = 600
    /// Suppresses `persistSettings()` while `init` is loading saved values,
    /// so loading an earlier field can't clobber a later field's not-yet-read default.
    @ObservationIgnored private var isLoadingSettings = false

    var dialFrequencyHz: UInt32 {
        if useCustomFrequency { return customFrequencyHz }
        return FTxBandPlan.primaryChannel(bandID: selectedBandID, mode: mode)?.dialFrequencyHz
            ?? customFrequencyHz
    }

    var availableBandIDs: [String] {
        FTxBandPlan.channels(for: mode).filter(\.isPrimary).map(\.bandID)
    }

    var filteredDecodes: [FT8DecodeEntry] {
        switch displayFilter {
        case .all: return decodes
        case .cqOnly: return decodes.filter(\.parsed.isCQ)
        case .toMe: return decodes.filter(\.addressedToMe)
        }
    }

    init(session: RadioSession) {
        self.session = session
        self.station = StationConfigStore()
        self.alerts = FT8AlertStore()
        self.engine = FT8QSOEngine(config: .init(myCall: "", myGrid: ""))

        isLoadingSettings = true
        let d = UserDefaults.standard
        if let m = d.string(forKey: "ft8Mode"), let mode = FTxProtocolMode(rawValue: m) { self.mode = mode }
        if let b = d.string(forKey: "ft8BandID") { selectedBandID = b }
        useCustomFrequency = d.bool(forKey: "ft8UseCustomFreq")
        if d.object(forKey: "ft8CustomFreqHz") != nil {
            customFrequencyHz = UInt32(clamping: d.integer(forKey: "ft8CustomFreqHz"))
        }
        if d.object(forKey: "ft8TxOffsetHz") != nil { txOffsetHz = d.double(forKey: "ft8TxOffsetHz") }
        if d.object(forKey: "ft8AutoSequence") != nil { autoSequence = d.bool(forKey: "ft8AutoSequence") }
        if d.object(forKey: "ft8AutoAnswerReplies") != nil { autoAnswerReplies = d.bool(forKey: "ft8AutoAnswerReplies") }
        autoAnswerCQs = d.bool(forKey: "ft8AutoAnswerCQs")
        if d.object(forKey: "ft8PreferRR73") != nil { preferRR73 = d.bool(forKey: "ft8PreferRR73") }
        houndMode = d.bool(forKey: "ft8HoundMode")
        if let p = d.string(forKey: "ft8TxSlotPref"), let pref = TxSlotPreference(rawValue: p) { txSlotPreference = pref }
        cqModifier = d.string(forKey: "ft8CQModifier") ?? ""
        if let data = d.data(forKey: "ft8AnswerPolicy"),
           let policy = try? JSONDecoder().decode(FT8AutoAnswerPolicy.self, from: data) {
            answerPolicy = policy
        }
        isLoadingSettings = false
        syncEngineConfig()
    }

    // MARK: - Start / stop

    var canStart: Bool {
        session.isConnected && station.info.isReadyForFT8
    }

    /// Human-readable reason `start()` can't run right now, for display next to the Start button.
    /// `nil` means starting is allowed (or FT8 is already running).
    var startBlockedReason: String? {
        guard !isRunning else { return nil }
        if !station.info.isReadyForFT8 {
            return "Set your callsign and grid square in Settings ▸ Station first."
        }
        if !session.isConnected {
            return "Radio is not connected."
        }
        return nil
    }

    func setMode(_ newMode: FTxProtocolMode) {
        guard newMode != mode else { return }
        mode = newMode
        if FTxBandPlan.primaryChannel(bandID: selectedBandID, mode: newMode) == nil {
            selectedBandID = availableBandIDs.first ?? "20m"
        }
        persistSettings()
        if isRunning { restart() }
    }

    func setBand(_ bandID: String) {
        guard bandID != selectedBandID else { return }
        selectedBandID = bandID
        persistSettings()
        retuneIfRunning()
    }

    /// Tune the radio to the FT8/FT4 channel and start decoding.
    func start() {
        guard !isRunning, canStart else { return }
        isRunning = true
        decodes.removeAll()
        incomingCallers.removeAll()
        statusText = "Monitoring"
        tuneRadio()

        let ring = AudioRingBuffer(capacity: 96_000) // 2 s of headroom at 48 kHz
        tapRing = ring
        guard session.ft8SetAudioTap(ring) else {
            isRunning = false
            tapRing = nil
            statusText = "Radio disconnected before FT8 could start."
            return
        }

        let worker = FT8SlotWorker(
            mode: mode, ring: ring,
            onSlotStart: { [weak self] slot in
                Task { @MainActor in self?.slotDidStart(slot) }
            },
            onDecodes: { [weak self] slot, start, results in
                Task { @MainActor in self?.slotDidDecode(slot, slotStart: start, results: results) }
            })
        self.worker = worker
        worker.start()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        haltTransmissions()
        engine.abort()
        worker?.stop()
        worker = nil
        session.ft8SetAudioTap(nil)
        tapRing = nil
        statusText = "Stopped"
    }

    private func restart() {
        guard isRunning else { return }
        stop()
        start()
    }

    private func retuneIfRunning() {
        guard isRunning else { return }
        tuneRadio()
    }

    private func tuneRadio() {
        session.setFrequency(dialFrequencyHz)
        session.setMode(.digu)
        // FT8 activity spans ~200-3000 Hz of audio; open both passbands.
        session.setLowCut(100)
        session.setHighCut(3_100)
        session.ft8SetTXBandwidth(low: 100, high: 3_100)
    }

    private func syncEngineConfig() {
        engine.updateConfig(.init(myCall: station.info.callsign,
                                  myGrid: station.info.grid4,
                                  preferRR73: preferRR73,
                                  houndMode: houndMode))
    }

    // MARK: - User operating actions

    /// Start (or restart) calling CQ.
    func startCQ() {
        guard isRunning else { return }
        syncEngineConfig()
        let modifier = cqModifier.trimmingCharacters(in: .whitespaces)
        let text = engine.startCQ(modifier: modifier.isEmpty ? nil : modifier)
        txEnabled = true
        chooseTxParity(forNewActivityAfter: lastSlotIndex)
        schedule(text: text)
        statusText = "Calling CQ"
    }

    /// Work the station in a decode row (click-to-call).
    func respond(to entry: FT8DecodeEntry) {
        guard isRunning, let from = entry.parsed.from else { return }
        syncEngineConfig()
        txEnabled = true
        // Reply on the opposite parity of the slot we heard them in.
        txParity = (entry.slotIndex + 1) % 2
        let text: String
        if entry.addressedToMe {
            text = engine.acceptReply(from: from,
                                      message: FT8RxMessage(parsed: entry.parsed, snr: entry.decode.snr))
        } else {
            text = engine.callStation(call: from, grid: entry.parsed.grid)
        }
        schedule(text: text)
        statusText = "Calling \(from)"
    }

    /// Stop transmitting immediately and cancel the pending message.
    func haltTransmissions() {
        pendingTxText = nil
        pendingWaveform = nil
        currentTxText = nil
        txParity = nil
        wasCallingCQ = false
        txGeneration += 1
        if isTransmitting {
            isTransmitting = false
            session.ft8StopTransmit()
        }
        if engine.phase != .idle { statusText = "TX halted" }
        engine.abort()
    }

    // MARK: - Slot handling

    private func slotDidStart(_ slotIndex: Int) {
        lastSlotIndex = slotIndex
        guard isRunning else { return }
        guard txEnabled, let parity = txParity, slotIndex % 2 == parity,
              let waveform = pendingWaveform, let text = pendingTxText else { return }
        transmit(waveform: waveform, text: text)
    }

    private func slotDidDecode(_ slotIndex: Int, slotStart: Date, results: [FT8Decode]) {
        guard isRunning else { return }
        let myCall = station.info.callsign.uppercased()
        var newEntries: [FT8DecodeEntry] = []
        for decode in results {
            let parsed = FT8ParsedMessage.parse(decode.text)
            let toMe = !myCall.isEmpty && parsed.isAddressed(to: myCall)
            let alertHits = alerts.matches(parsed: parsed, currentBandID: selectedBandID)
            let entry = FT8DecodeEntry(slotIndex: slotIndex, slotStart: slotStart,
                                       decode: decode, parsed: parsed,
                                       addressedToMe: toMe, isAlert: !alertHits.isEmpty)
            newEntries.append(entry)
            if !alertHits.isEmpty { raiseAlertNotification(for: entry) }
        }
        decodes.append(contentsOf: newEntries)
        if decodes.count > Self.maxDecodesShown {
            decodes.removeFirst(decodes.count - Self.maxDecodesShown)
        }

        // Surface stations calling us (whether or not autosequence handles them).
        incomingCallers = newEntries.filter(\.addressedToMe)
        if let first = incomingCallers.first, engine.phase == .idle {
            raiseIncomingCallNotification(first)
        }

        // Our own TX slots carry no usable receive audio; don't advance the
        // sequencer on them.
        if let parity = txParity, slotIndex % 2 == parity { return }
        guard autoSequence else { return }
        runAutoSequence(slotIndex: slotIndex, entries: newEntries)
    }

    private func runAutoSequence(slotIndex: Int, entries: [FT8DecodeEntry]) {
        let rxMessages = entries.map { FT8RxMessage(parsed: $0.parsed, snr: $0.decode.snr) }

        switch engine.phase {
        case .idle:
            guard autoAnswerCQs, txEnabled else { return }
            let candidates = FT8AutoAnswer.cqCandidates(in: rxMessages)
            guard let pick = FT8AutoAnswer.select(from: candidates, policy: answerPolicy,
                                                  myGrid: station.info.grid4,
                                                  workedCalls: workedCalls) else { return }
            let text = engine.callStation(call: pick.call, grid: pick.grid)
            txParity = (slotIndex + 1) % 2
            schedule(text: text)
            statusText = "Auto-answering CQ from \(pick.call)"

        case .callingCQ:
            let replies = engine.repliesToMyCQ(in: rxMessages)
            if autoAnswerReplies, !replies.isEmpty {
                let candidates = FT8AutoAnswer.replyCandidates(in: replies)
                if let pick = FT8AutoAnswer.select(from: candidates, policy: answerPolicy,
                                                   myGrid: station.info.grid4,
                                                   workedCalls: workedCalls) {
                    let text = engine.acceptReply(from: pick.call, message: pick.message)
                    schedule(text: text)
                    statusText = "Working \(pick.call)"
                    return
                }
            }
            handle(action: engine.processRxSlot(rxMessages))

        default:
            handle(action: engine.processRxSlot(rxMessages))
        }
    }

    private func handle(action: FT8QSOEngine.Action) {
        switch action {
        case .transmit(let text):
            schedule(text: text)

        case .transmitAndLog(let text, let record):
            log(record)
            schedule(text: text)

        case .logAndStop(let record):
            log(record)
            finishActivity(status: "QSO with \(record.dxCall) complete", resumeCQ: true)

        case .stop:
            finishActivity(status: "Sequence ended", resumeCQ: false)

        case .none:
            break
        }
    }

    private func finishActivity(status: String, resumeCQ: Bool) {
        pendingTxText = nil
        pendingWaveform = nil
        txParity = nil
        statusText = status
        // Keep the frequency running: if the operator was calling CQ, go
        // straight back to CQ after a completed QSO.
        if resumeCQ, wasCallingCQ, txEnabled {
            startCQ()
        }
    }

    private var wasCallingCQ = false

    private func log(_ record: FT8QSORecord) {
        workedCalls.insert(record.dxCall.uppercased())
        qsoLog.append(FT8LoggedQSO(record: record, date: Date(), mode: mode,
                                   dialFrequencyHz: dialFrequencyHz))
    }

    // MARK: - Transmission

    private func schedule(text: String) {
        if engine.phase == .callingCQ { wasCallingCQ = true }
        guard txEnabled else { return }
        if pendingTxText != text || pendingWaveform == nil {
            do {
                var offset = txOffsetHz
                // Hounds must call foxes above 1000 Hz.
                if houndMode { offset = max(offset, 1_050) }
                var waveform = try FT8Codec.waveform(for: text, mode: mode,
                                                     audioFrequency: offset,
                                                     sampleRate: 48_000, amplitude: 0.6)
                // Standard 0.5 s delay from the slot boundary to first symbol.
                waveform.insert(contentsOf: [Float](repeating: 0,
                                                    count: Int(0.5 * 48_000)), at: 0)
                pendingWaveform = waveform
                pendingTxText = text
            } catch {
                statusText = "Cannot encode \"\(text)\""
                pendingTxText = nil
                pendingWaveform = nil
                return
            }
        }
        if txParity == nil { chooseTxParity(forNewActivityAfter: lastSlotIndex) }
    }

    private func chooseTxParity(forNewActivityAfter slotIndex: Int) {
        switch txSlotPreference {
        case .auto: txParity = (slotIndex + 1) % 2
        case .even: txParity = 0
        case .odd: txParity = 1
        }
    }

    private func transmit(waveform: [Float], text: String) {
        isTransmitting = true
        currentTxText = text
        txGeneration += 1
        let generation = txGeneration
        session.ft8StartTransmit(waveform)
        let duration = 0.5 + mode.transmitSeconds + 0.15
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard let self, self.txGeneration == generation else { return }
            self.isTransmitting = false
            self.currentTxText = nil
            self.session.ft8StopTransmit()
        }
    }

    // MARK: - Notifications

    private var notificationsAuthorized = false

    private func requestNotificationAuthorization() {
        guard !notificationsAuthorized else { return }
        notificationsAuthorized = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func raiseAlertNotification(for entry: FT8DecodeEntry) {
        requestNotificationAuthorization()
        let content = UNMutableNotificationContent()
        content.title = "Callsign alert"
        content.body = "\(entry.parsed.from ?? "?") heard on \(selectedBandID): \(entry.decode.text)"
        content.sound = .default
        let request = UNNotificationRequest(identifier: entry.id.uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func raiseIncomingCallNotification(_ entry: FT8DecodeEntry) {
        requestNotificationAuthorization()
        let content = UNMutableNotificationContent()
        content.title = "Station calling you"
        content.body = entry.decode.text
        content.sound = .default
        let request = UNNotificationRequest(identifier: "call-\(entry.id.uuidString)",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Persistence

    private func persistSettings() {
        guard !isLoadingSettings else { return }
        let d = UserDefaults.standard
        d.set(mode.rawValue, forKey: "ft8Mode")
        d.set(selectedBandID, forKey: "ft8BandID")
        d.set(useCustomFrequency, forKey: "ft8UseCustomFreq")
        d.set(Int(customFrequencyHz), forKey: "ft8CustomFreqHz")
        d.set(txOffsetHz, forKey: "ft8TxOffsetHz")
        d.set(autoSequence, forKey: "ft8AutoSequence")
        d.set(autoAnswerReplies, forKey: "ft8AutoAnswerReplies")
        d.set(autoAnswerCQs, forKey: "ft8AutoAnswerCQs")
        d.set(preferRR73, forKey: "ft8PreferRR73")
        d.set(houndMode, forKey: "ft8HoundMode")
        d.set(txSlotPreference.rawValue, forKey: "ft8TxSlotPref")
        d.set(cqModifier, forKey: "ft8CQModifier")
        if let data = try? JSONEncoder().encode(answerPolicy) {
            d.set(data, forKey: "ft8AnswerPolicy")
        }
    }
}
