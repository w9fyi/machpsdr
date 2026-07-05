import Foundation

/// A message received in one slot, with the SNR we measured for the sender.
public struct FT8RxMessage: Sendable, Equatable {
    public let parsed: FT8ParsedMessage
    public let snr: Int

    public init(parsed: FT8ParsedMessage, snr: Int) {
        self.parsed = parsed
        self.snr = snr
    }
}

/// Completed-contact summary produced when a QSO reaches its end.
public struct FT8QSORecord: Sendable, Equatable {
    public let dxCall: String
    public let dxGrid: String?
    /// Report we sent them (their signal as heard by us), dB.
    public let reportSent: Int?
    /// Report they sent us, dB.
    public let reportReceived: Int?
}

/// WSJT-X-style FT8/FT4 QSO state machine. Pure logic — no timers, no radio:
/// the controller feeds it decoded messages once per receive slot and
/// transmits whatever text it returns.
///
/// Standard sequence (as the answering station):
///   CQ DX1 → [us] DX1 W9FYI EN52 → DX1: W9FYI DX1 -07 → [us] DX1 W9FYI R-12
///   → DX1: W9FYI DX1 RR73 → [us] DX1 W9FYI 73 (optional) → done
///
/// The engine follows whichever ending style the other station uses
/// (RR73 vs RRR→73) and uses `preferRR73` for its own endings.
public final class FT8QSOEngine {

    public struct Config: Sendable {
        public var myCall: String
        public var myGrid: String
        /// End QSOs with RR73 (true) or RRR + separate 73 (false).
        public var preferRR73: Bool
        /// Send a courtesy 73 after receiving RR73.
        public var send73AfterRR73: Bool
        /// Consecutive unanswered transmissions before giving up on a QSO.
        public var maxRetries: Int
        /// DXpedition hound behavior: caller is a fox running split streams.
        public var houndMode: Bool

        public init(myCall: String, myGrid: String, preferRR73: Bool = true,
                    send73AfterRR73: Bool = true, maxRetries: Int = 4,
                    houndMode: Bool = false) {
            self.myCall = myCall.uppercased()
            self.myGrid = String(myGrid.uppercased().prefix(4))
            self.preferRR73 = preferRR73
            self.send73AfterRR73 = send73AfterRR73
            self.maxRetries = maxRetries
            self.houndMode = houndMode
        }
    }

    public enum Phase: Equatable, Sendable {
        case idle
        /// Repeating CQ, waiting for replies.
        case callingCQ
        /// Sent Tx1 (grid), waiting for their report.
        case sentReply
        /// Sent Tx2 (report), waiting for their roger-report.
        case sentReport
        /// Sent Tx3 (R+report), waiting for RRR/RR73.
        case sentRogerReport
        /// Sent Tx4 (RR73 or RRR), waiting for their 73 (if any).
        case sentSignoff
        /// Sent final 73.
        case sent73
    }

    /// What the controller should do after a receive slot.
    public enum Action: Equatable, Sendable {
        /// Transmit this text in our next transmit slot.
        case transmit(String)
        /// Transmit this text; the QSO is now complete (log it).
        case transmitAndLog(String, FT8QSORecord)
        /// QSO complete, nothing more to send.
        case logAndStop(FT8QSORecord)
        /// Stop transmitting (gave up, or halted).
        case stop
        /// No change; keep listening (and repeat CQ if calling CQ).
        case none
    }

    public private(set) var config: Config
    public private(set) var phase: Phase = .idle
    public private(set) var dxCall: String?
    public private(set) var dxGrid: String?
    public private(set) var reportSent: Int?
    public private(set) var reportReceived: Int?
    public private(set) var cqModifier: String?
    /// The text we are currently repeating each transmit slot.
    public private(set) var currentTxText: String?
    private var retryCount = 0

    public init(config: Config) {
        self.config = config
    }

    public func updateConfig(_ newConfig: Config) {
        config = newConfig
    }

    // MARK: - User/controller actions

    /// Begin calling CQ ("CQ W9FYI EN52", optionally "CQ DX W9FYI EN52").
    /// Returns the text to transmit each TX slot until answered.
    @discardableResult
    public func startCQ(modifier: String? = nil) -> String {
        resetQSO()
        cqModifier = modifier?.uppercased()
        phase = .callingCQ
        let mod = cqModifier.map { "\($0) " } ?? ""
        currentTxText = "CQ \(mod)\(config.myCall) \(config.myGrid)"
        return currentTxText!
    }

    /// Answer a station's CQ (or call a station directly) with our grid (Tx1).
    @discardableResult
    public func callStation(call: String, grid: String? = nil) -> String {
        resetQSO()
        dxCall = call.uppercased()
        dxGrid = grid?.uppercased()
        phase = .sentReply
        currentTxText = "\(dxCall!) \(config.myCall) \(config.myGrid)"
        return currentTxText!
    }

    /// Accept a reply to our CQ (chosen by the user or the auto-answer
    /// policy) and respond with a signal report (Tx2).
    @discardableResult
    public func acceptReply(from call: String, message: FT8RxMessage) -> String {
        dxCall = call.uppercased()
        dxGrid = message.parsed.grid
        reportSent = message.snr
        if case .report(let theirReport) = message.parsed.kind {
            // They skipped the grid and sent a report immediately: roger it.
            reportReceived = theirReport
            phase = .sentRogerReport
            currentTxText = "\(dxCall!) \(config.myCall) R\(FT8ParsedMessage.formatReport(message.snr))"
        } else {
            phase = .sentReport
            currentTxText = "\(dxCall!) \(config.myCall) \(FT8ParsedMessage.formatReport(message.snr))"
        }
        retryCount = 0
        return currentTxText!
    }

    /// Halt the current QSO/CQ without logging.
    public func abort() {
        resetQSO()
    }

    // MARK: - Slot processing

    /// Feed all messages decoded in a receive slot. Returns the action for
    /// the next transmit slot. While calling CQ the engine does not pick a
    /// replier itself — use `repliesToMyCQ(in:)` + `acceptReply(from:message:)`.
    public func processRxSlot(_ messages: [FT8RxMessage]) -> Action {
        switch phase {
        case .idle:
            return .none

        case .callingCQ:
            // Controller selects among replies; we just keep CQing.
            return .transmit(currentTxText ?? startCQ(modifier: cqModifier))

        case .sentReply, .sentReport, .sentRogerReport, .sentSignoff, .sent73:
            guard let dx = dxCall else { return .stop }
            let relevant = messages.filter {
                $0.parsed.isAddressed(to: config.myCall) && $0.parsed.from == dx
            }
            guard let msg = pickMostAdvanced(relevant) else {
                return retryOrGiveUp()
            }
            retryCount = 0
            return handle(msg)
        }
    }

    /// Messages in a slot that answer our CQ (directed to us while we CQ).
    public func repliesToMyCQ(in messages: [FT8RxMessage]) -> [FT8RxMessage] {
        guard phase == .callingCQ else { return [] }
        return messages.filter { $0.parsed.isAddressed(to: config.myCall) }
    }

    // MARK: - Internals

    private func handle(_ msg: FT8RxMessage) -> Action {
        switch (phase, msg.parsed.kind) {

        // ---- We answered a CQ with our grid, awaiting their report ----
        case (.sentReply, .report(let theirReport)):
            reportReceived = theirReport
            reportSent = msg.snr
            phase = .sentRogerReport
            currentTxText = "\(dxCall!) \(config.myCall) R\(FT8ParsedMessage.formatReport(msg.snr))"
            return .transmit(currentTxText!)

        case (.sentReply, .gridReply(let g)):
            // Both sides sent grids (they answered our directed call): send report.
            dxGrid = g
            reportSent = msg.snr
            phase = .sentReport
            currentTxText = "\(dxCall!) \(config.myCall) \(FT8ParsedMessage.formatReport(msg.snr))"
            return .transmit(currentTxText!)

        case (.sentReply, .rogerReport(let theirReport)):
            // They jumped ahead; roger with signoff.
            reportReceived = theirReport
            return sendSignoff()

        // ---- We sent a report (Tx2), awaiting R+report ----
        case (.sentReport, .rogerReport(let theirReport)):
            reportReceived = theirReport
            return sendSignoff()

        case (.sentReport, .gridReply):
            // They didn't hear our report; repeat it.
            return .transmit(currentTxText ?? "")

        case (.sentReport, .report(let theirReport)):
            // Rare crossed sequence: treat as roger.
            reportReceived = theirReport
            return sendSignoff()

        // ---- We sent R+report (Tx3), awaiting RRR / RR73 ----
        case (.sentRogerReport, .rr73), (.sentRogerReport, .rrr):
            let record = makeRecord()
            if config.send73AfterRR73 {
                phase = .sent73
                currentTxText = "\(dxCall!) \(config.myCall) 73"
                return .transmitAndLog(currentTxText!, record)
            }
            phase = .idle
            return .logAndStop(record)

        case (.sentRogerReport, .seventyThree):
            return .logAndStop(finishQSO())

        case (.sentRogerReport, .report):
            // They missed our R-report; repeat it.
            return .transmit(currentTxText ?? "")

        // ---- We sent RR73/RRR (Tx4) ----
        case (.sentSignoff, .seventyThree):
            return .logAndStop(finishQSO())

        case (.sentSignoff, .rogerReport):
            // They missed our signoff; repeat it.
            return .transmit(currentTxText ?? "")

        case (.sentSignoff, .rr73), (.sentSignoff, .rrr):
            return .logAndStop(finishQSO())

        // ---- We sent the final 73 ----
        case (.sent73, _):
            phase = .idle
            return .stop

        default:
            return retryOrGiveUp()
        }
    }

    /// Prefer the message that advances the QSO furthest (e.g. if we decode
    /// both a stale grid reply and a roger-report in one slot).
    private func pickMostAdvanced(_ messages: [FT8RxMessage]) -> FT8RxMessage? {
        func rank(_ m: FT8RxMessage) -> Int {
            switch m.parsed.kind {
            case .seventyThree: return 6
            case .rr73: return 5
            case .rrr: return 4
            case .rogerReport: return 3
            case .report: return 2
            case .gridReply: return 1
            default: return 0
            }
        }
        return messages.max { rank($0) < rank($1) }
    }

    private func sendSignoff() -> Action {
        // Hounds working a fox never send RRR (the fox expects RR73 flow and
        // ends the QSO itself); for normal QSOs use the configured style.
        let useRR73 = config.preferRR73 || config.houndMode
        phase = .sentSignoff
        currentTxText = "\(dxCall!) \(config.myCall) \(useRR73 ? "RR73" : "RRR")"
        if useRR73 {
            // RR73 is a complete QSO from our side: log now, keep sending
            // RR73 until they acknowledge or retries run out.
            return .transmitAndLog(currentTxText!, makeRecord())
        }
        return .transmit(currentTxText!)
    }

    private func retryOrGiveUp() -> Action {
        retryCount += 1
        if retryCount > config.maxRetries {
            let wasSignoff = (phase == .sentSignoff || phase == .sent73)
            let record = makeRecord()
            resetQSO()
            // A QSO that reached signoff is complete even without their 73.
            return wasSignoff ? .logAndStop(record) : .stop
        }
        return .transmit(currentTxText ?? "")
    }

    private func makeRecord() -> FT8QSORecord {
        FT8QSORecord(dxCall: dxCall ?? "", dxGrid: dxGrid,
                     reportSent: reportSent, reportReceived: reportReceived)
    }

    private func finishQSO() -> FT8QSORecord {
        let record = makeRecord()
        resetQSO()
        return record
    }

    private func resetQSO() {
        phase = .idle
        dxCall = nil
        dxGrid = nil
        reportSent = nil
        reportReceived = nil
        cqModifier = nil
        currentTxText = nil
        retryCount = 0
    }
}
