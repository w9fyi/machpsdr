import XCTest
@testable import FT8Kit

final class MessageParserTests: XCTestCase {
    func testParseCQ() {
        let p = FT8ParsedMessage.parse("CQ W9FYI EN52")
        XCTAssertEqual(p.kind, .cq(modifier: nil, call: "W9FYI", grid: "EN52"))
        XCTAssertTrue(p.isCQ)
        XCTAssertEqual(p.from, "W9FYI")
    }

    func testParseCQWithModifier() {
        let p = FT8ParsedMessage.parse("CQ DX JA1ABC PM95")
        XCTAssertEqual(p.kind, .cq(modifier: "DX", call: "JA1ABC", grid: "PM95"))
    }

    func testParseCQWithoutGrid() {
        let p = FT8ParsedMessage.parse("CQ W9FYI")
        XCTAssertEqual(p.kind, .cq(modifier: nil, call: "W9FYI", grid: nil))
    }

    func testParseGridReply() {
        let p = FT8ParsedMessage.parse("K1ABC W9FYI EN52")
        XCTAssertEqual(p.to, "K1ABC")
        XCTAssertEqual(p.from, "W9FYI")
        XCTAssertEqual(p.kind, .gridReply(grid: "EN52"))
        XCTAssertTrue(p.isAddressed(to: "K1ABC"))
        XCTAssertFalse(p.isAddressed(to: "W9FYI"))
    }

    func testParseReports() {
        XCTAssertEqual(FT8ParsedMessage.parse("K1ABC W9FYI -07").kind, .report(snr: -7))
        XCTAssertEqual(FT8ParsedMessage.parse("K1ABC W9FYI +05").kind, .report(snr: 5))
        XCTAssertEqual(FT8ParsedMessage.parse("K1ABC W9FYI R-15").kind, .rogerReport(snr: -15))
        XCTAssertEqual(FT8ParsedMessage.parse("K1ABC W9FYI R+03").kind, .rogerReport(snr: 3))
    }

    func testParseEndings() {
        XCTAssertEqual(FT8ParsedMessage.parse("K1ABC W9FYI RRR").kind, .rrr)
        XCTAssertEqual(FT8ParsedMessage.parse("K1ABC W9FYI RR73").kind, .rr73)
        XCTAssertEqual(FT8ParsedMessage.parse("K1ABC W9FYI 73").kind, .seventyThree)
    }

    func testParseHashedCallsign() {
        let p = FT8ParsedMessage.parse("<PJ4/K1ABC> W9FYI RR73")
        XCTAssertEqual(p.to, "PJ4/K1ABC")
        XCTAssertEqual(p.kind, .rr73)
    }

    func testFreeTextIsOther() {
        XCTAssertEqual(FT8ParsedMessage.parse("HELLO WORLD").kind, .other)
    }

    func testRR73IsNotAGrid() {
        // RR73 has the shape of a grid square; must parse as an ending token.
        XCTAssertFalse(FT8ParsedMessage.looksLikeGrid("RR73"))
        XCTAssertTrue(FT8ParsedMessage.looksLikeGrid("EN52"))
        XCTAssertFalse(FT8ParsedMessage.looksLikeGrid("XA99")) // X > R
    }

    func testFormatReport() {
        XCTAssertEqual(FT8ParsedMessage.formatReport(-7), "-07")
        XCTAssertEqual(FT8ParsedMessage.formatReport(5), "+05")
        XCTAssertEqual(FT8ParsedMessage.formatReport(-31), "-30")
        XCTAssertEqual(FT8ParsedMessage.formatReport(15), "+15")
    }
}

final class QSOEngineTests: XCTestCase {
    private func engine(preferRR73: Bool = true, send73: Bool = true) -> FT8QSOEngine {
        FT8QSOEngine(config: .init(myCall: "W9FYI", myGrid: "EN52",
                                   preferRR73: preferRR73, send73AfterRR73: send73))
    }

    private func rx(_ text: String, snr: Int = -10) -> FT8RxMessage {
        FT8RxMessage(parsed: FT8ParsedMessage.parse(text), snr: snr)
    }

    // Full QSO where we answer someone's CQ and they end with RR73.
    func testAnsweringCQFullSequenceRR73Ending() {
        let e = engine()
        let tx1 = e.callStation(call: "K1ABC", grid: "FN42")
        XCTAssertEqual(tx1, "K1ABC W9FYI EN52")
        XCTAssertEqual(e.phase, .sentReply)

        // They send us a report; we measured them at -12.
        let a1 = e.processRxSlot([rx("W9FYI K1ABC -07", snr: -12)])
        XCTAssertEqual(a1, .transmit("K1ABC W9FYI R-12"))
        XCTAssertEqual(e.phase, .sentRogerReport)

        // They send RR73 → we log and send courtesy 73.
        let a2 = e.processRxSlot([rx("W9FYI K1ABC RR73")])
        guard case .transmitAndLog(let text, let record) = a2 else {
            return XCTFail("expected transmitAndLog, got \(a2)")
        }
        XCTAssertEqual(text, "K1ABC W9FYI 73")
        XCTAssertEqual(record.dxCall, "K1ABC")
        XCTAssertEqual(record.reportReceived, -7)
        XCTAssertEqual(record.reportSent, -12)
        XCTAssertEqual(record.dxGrid, "FN42")
    }

    // Full QSO where we call CQ and end with RRR → their 73.
    func testCallingCQFullSequenceRRREnding() {
        let e = engine(preferRR73: false)
        XCTAssertEqual(e.startCQ(), "CQ W9FYI EN52")
        XCTAssertEqual(e.phase, .callingCQ)

        // A reply arrives; controller picks it.
        let slot = [rx("W9FYI K1ABC FN42", snr: -3)]
        let replies = e.repliesToMyCQ(in: slot)
        XCTAssertEqual(replies.count, 1)
        let tx2 = e.acceptReply(from: "K1ABC", message: replies[0])
        XCTAssertEqual(tx2, "K1ABC W9FYI -03")
        XCTAssertEqual(e.phase, .sentReport)

        // They roger our report.
        let a1 = e.processRxSlot([rx("W9FYI K1ABC R-08")])
        XCTAssertEqual(a1, .transmit("K1ABC W9FYI RRR"))
        XCTAssertEqual(e.phase, .sentSignoff)

        // They send 73 → complete.
        let a2 = e.processRxSlot([rx("W9FYI K1ABC 73")])
        guard case .logAndStop(let record) = a2 else {
            return XCTFail("expected logAndStop, got \(a2)")
        }
        XCTAssertEqual(record.reportReceived, -8)
        XCTAssertEqual(record.reportSent, -3)
        XCTAssertEqual(e.phase, .idle)
    }

    func testCQCallerUsesRR73WhenPreferred() {
        let e = engine(preferRR73: true)
        e.startCQ()
        let replies = e.repliesToMyCQ(in: [rx("W9FYI K1ABC FN42", snr: -3)])
        _ = e.acceptReply(from: "K1ABC", message: replies[0])
        let a = e.processRxSlot([rx("W9FYI K1ABC R-08")])
        guard case .transmitAndLog(let text, _) = a else {
            return XCTFail("RR73 should log immediately, got \(a)")
        }
        XCTAssertEqual(text, "K1ABC W9FYI RR73")
    }

    func testReplyWithDirectReportSkipsGrid() {
        // Station answers our CQ with a report straight away (common contest style).
        let e = engine()
        e.startCQ()
        let replies = e.repliesToMyCQ(in: [rx("W9FYI K1ABC -05", snr: -9)])
        let tx = e.acceptReply(from: "K1ABC", message: replies[0])
        XCTAssertEqual(tx, "K1ABC W9FYI R-09")
        XCTAssertEqual(e.phase, .sentRogerReport)
    }

    func testRetryRepeatsLastTransmission() {
        let e = engine()
        e.callStation(call: "K1ABC")
        // Nothing relevant decoded: repeat Tx1.
        XCTAssertEqual(e.processRxSlot([rx("CQ N0XYZ EM48")]), .transmit("K1ABC W9FYI EN52"))
        XCTAssertEqual(e.processRxSlot([]), .transmit("K1ABC W9FYI EN52"))
    }

    func testGivesUpAfterMaxRetries() {
        let e = FT8QSOEngine(config: .init(myCall: "W9FYI", myGrid: "EN52", maxRetries: 2))
        e.callStation(call: "K1ABC")
        XCTAssertEqual(e.processRxSlot([]), .transmit("K1ABC W9FYI EN52"))
        XCTAssertEqual(e.processRxSlot([]), .transmit("K1ABC W9FYI EN52"))
        XCTAssertEqual(e.processRxSlot([]), .stop)
        XCTAssertEqual(e.phase, .idle)
    }

    func testCQKeepsRepeatingWithoutRetryLimit() {
        let e = FT8QSOEngine(config: .init(myCall: "W9FYI", myGrid: "EN52", maxRetries: 1))
        e.startCQ()
        for _ in 0..<10 {
            XCTAssertEqual(e.processRxSlot([]), .transmit("CQ W9FYI EN52"))
        }
    }

    func testIgnoresMessagesForOtherStations() {
        let e = engine()
        e.callStation(call: "K1ABC")
        // K1ABC works someone else: that's not addressed to us → retry.
        let a = e.processRxSlot([rx("N0XYZ K1ABC -10")])
        XCTAssertEqual(a, .transmit("K1ABC W9FYI EN52"))
    }

    func testTheirRepeatedReportRepeatsOurRoger() {
        let e = engine()
        e.callStation(call: "K1ABC")
        _ = e.processRxSlot([rx("W9FYI K1ABC -07", snr: -12)])
        // They didn't hear us and repeat the report; we repeat the roger.
        let a = e.processRxSlot([rx("W9FYI K1ABC -07", snr: -12)])
        XCTAssertEqual(a, .transmit("K1ABC W9FYI R-12"))
    }

    func testSignoffTimeoutStillLogs() {
        let e = FT8QSOEngine(config: .init(myCall: "W9FYI", myGrid: "EN52",
                                           preferRR73: false, maxRetries: 1))
        e.callStation(call: "K1ABC")
        _ = e.processRxSlot([rx("W9FYI K1ABC -07", snr: -12)])   // → R-12
        _ = e.processRxSlot([rx("W9FYI K1ABC RRR")])              // hmm: RRR while we are in sentRogerReport
        // We sent 73 already (send73AfterRR73), QSO done — covered elsewhere.
        // Here exercise signoff retry timeout instead:
        let e2 = FT8QSOEngine(config: .init(myCall: "W9FYI", myGrid: "EN52",
                                            preferRR73: false, maxRetries: 1))
        e2.startCQ()
        let replies = e2.repliesToMyCQ(in: [rx("W9FYI K1ABC FN42", snr: -3)])
        _ = e2.acceptReply(from: "K1ABC", message: replies[0])
        _ = e2.processRxSlot([rx("W9FYI K1ABC R-08")])            // we send RRR
        XCTAssertEqual(e2.phase, .sentSignoff)
        _ = e2.processRxSlot([])                                   // retry RRR
        let final = e2.processRxSlot([])                           // give up
        guard case .logAndStop(let record) = final else {
            return XCTFail("QSO that reached signoff should still log, got \(final)")
        }
        XCTAssertEqual(record.dxCall, "K1ABC")
    }

    func testHoundModeAlwaysEndsRR73() {
        let e = FT8QSOEngine(config: .init(myCall: "W9FYI", myGrid: "EN52",
                                           preferRR73: false, houndMode: true))
        e.callStation(call: "K1ABC")
        let a = e.processRxSlot([rx("W9FYI K1ABC -07", snr: -12)])
        XCTAssertEqual(a, .transmit("K1ABC W9FYI R-12"))
        // Fox confirms with RR73; hound never sends RRR anywhere in sequence.
        let a2 = e.processRxSlot([rx("W9FYI K1ABC RR73")])
        guard case .transmitAndLog = a2 else { return XCTFail("got \(a2)") }
    }

    func testGeneratedTextsAreEncodable() throws {
        // Every text the engine can produce must pack into a real FT8 payload.
        let e = engine()
        var texts = [e.startCQ(), e.startCQ(modifier: "DX")]
        texts.append(e.callStation(call: "K1ABC", grid: "FN42"))
        if case .transmit(let t) = e.processRxSlot([rx("W9FYI K1ABC -07", snr: -12)]) {
            texts.append(t)
        }
        if case .transmitAndLog(let t, _) = e.processRxSlot([rx("W9FYI K1ABC RR73")]) {
            texts.append(t)
        }
        for text in texts {
            XCTAssertTrue(FT8Codec.canEncode(text), "not encodable: \(text)")
        }
    }
}

final class AutoAnswerTests: XCTestCase {
    private func candidate(_ call: String, grid: String?, snr: Int) -> FT8AnswerCandidate {
        let text = grid.map { "CQ \(call) \($0)" } ?? "CQ \(call)"
        return FT8AnswerCandidate(call: call, grid: grid, snr: snr,
                                  message: FT8RxMessage(parsed: .parse(text), snr: snr))
    }

    // From EN52 (Illinois): FN42 (Boston) ≈ 1370 km, PM95 (Japan) ≈ 10000 km.
    private let boston = "FN42"
    private let tokyo = "PM95"

    func testLoudestFirst() {
        let pick = FT8AutoAnswer.select(
            from: [candidate("K1ABC", grid: boston, snr: -15),
                   candidate("JA1XYZ", grid: tokyo, snr: -3)],
            policy: .init(order: .loudestFirst), myGrid: "EN52", workedCalls: [])
        XCTAssertEqual(pick?.call, "JA1XYZ")
    }

    func testClosestFirst() {
        let pick = FT8AutoAnswer.select(
            from: [candidate("K1ABC", grid: boston, snr: -15),
                   candidate("JA1XYZ", grid: tokyo, snr: -3)],
            policy: .init(order: .closestFirst), myGrid: "EN52", workedCalls: [])
        XCTAssertEqual(pick?.call, "K1ABC")
    }

    func testFurthestFirst() {
        let pick = FT8AutoAnswer.select(
            from: [candidate("K1ABC", grid: boston, snr: -15),
                   candidate("JA1XYZ", grid: tokyo, snr: -3)],
            policy: .init(order: .furthestFirst), myGrid: "EN52", workedCalls: [])
        XCTAssertEqual(pick?.call, "JA1XYZ")
    }

    func testContinentFilter() {
        let pick = FT8AutoAnswer.select(
            from: [candidate("K1ABC", grid: boston, snr: -1),
                   candidate("DL1XX", grid: "JO62", snr: -20)],
            policy: .init(order: .loudestFirst, continents: [.europe]),
            myGrid: "EN52", workedCalls: [])
        XCTAssertEqual(pick?.call, "DL1XX")
    }

    func testSkipWorked() {
        let pick = FT8AutoAnswer.select(
            from: [candidate("K1ABC", grid: boston, snr: -1),
                   candidate("N0XYZ", grid: "EM48", snr: -20)],
            policy: .init(order: .loudestFirst, skipWorked: true),
            myGrid: "EN52", workedCalls: ["K1ABC"])
        XCTAssertEqual(pick?.call, "N0XYZ")
    }

    func testCQCandidateExtraction() {
        let msgs = [
            FT8RxMessage(parsed: .parse("CQ K1ABC FN42"), snr: -5),
            FT8RxMessage(parsed: .parse("N0XYZ W5DEF -10"), snr: -8),  // not a CQ
        ]
        let c = FT8AutoAnswer.cqCandidates(in: msgs)
        XCTAssertEqual(c.map(\.call), ["K1ABC"])
    }
}

final class MaidenheadTests: XCTestCase {
    func testValidation() {
        XCTAssertTrue(Maidenhead.isValid("EN52"))
        XCTAssertTrue(Maidenhead.isValid("EN52xa"))
        XCTAssertFalse(Maidenhead.isValid("E52"))
        XCTAssertFalse(Maidenhead.isValid("52EN"))
        XCTAssertFalse(Maidenhead.isValid("ZZ99"))  // Z > R in field position
    }

    func testKnownCoordinates() throws {
        let c = try XCTUnwrap(Maidenhead.coordinates(of: "EN52"))
        // EN52 center: 42.5°N (41-43), -88°W (-90..-86 → center -89... )
        XCTAssertEqual(c.latitude, 42.5, accuracy: 0.51)
        XCTAssertEqual(c.longitude, -89, accuracy: 1.01)
    }

    func testDistanceChicagoToBoston() throws {
        // EN61 (Chicago) to FN42 (Boston) ≈ 1370 km
        let d = try XCTUnwrap(Maidenhead.distanceKm(from: "EN61", to: "FN42"))
        XCTAssertEqual(d, 1370, accuracy: 120)
    }

    func testDistanceIsSymmetricAndZeroForSame() throws {
        let ab = try XCTUnwrap(Maidenhead.distanceKm(from: "EN52", to: "PM95"))
        let ba = try XCTUnwrap(Maidenhead.distanceKm(from: "PM95", to: "EN52"))
        XCTAssertEqual(ab, ba, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(Maidenhead.distanceKm(from: "EN52", to: "EN52")), 0, accuracy: 0.001)
    }

    func testBearingEastward() throws {
        // From Chicago to Boston is roughly east (≈ 80-100°)
        let b = try XCTUnwrap(Maidenhead.bearingDegrees(from: "EN61", to: "FN42"))
        XCTAssertGreaterThan(b, 60)
        XCTAssertLessThan(b, 120)
    }
}

final class DXCCTests: XCTestCase {
    func testCommonPrefixes() {
        XCTAssertEqual(DXCCLookup.entity(for: "W9FYI")?.name, "United States")
        XCTAssertEqual(DXCCLookup.continent(for: "K1ABC"), .northAmerica)
        XCTAssertEqual(DXCCLookup.continent(for: "JA1XYZ"), .asia)
        XCTAssertEqual(DXCCLookup.continent(for: "DL1ABC"), .europe)
        XCTAssertEqual(DXCCLookup.continent(for: "VK2DEF"), .oceania)
        XCTAssertEqual(DXCCLookup.continent(for: "ZS6AA"), .africa)
        XCTAssertEqual(DXCCLookup.continent(for: "LU1AA"), .southAmerica)
    }

    func testLongestPrefixWins() {
        // KH6 = Hawaii (Oceania) even though K = USA
        XCTAssertEqual(DXCCLookup.entity(for: "KH6ABC")?.name, "Hawaii")
        XCTAssertEqual(DXCCLookup.continent(for: "KH6ABC"), .oceania)
        // EA8 = Canary Islands (Africa) even though EA = Spain
        XCTAssertEqual(DXCCLookup.continent(for: "EA8XX"), .africa)
    }

    func testPortablePrefix() {
        // PJ4/K1ABC → Bonaire, not USA
        XCTAssertEqual(DXCCLookup.entity(for: "PJ4/K1ABC")?.name, "Bonaire")
        // K1ABC/P → USA
        XCTAssertEqual(DXCCLookup.entity(for: "K1ABC/P")?.name, "United States")
    }

    func testUnknownPrefixReturnsNil() {
        XCTAssertNil(DXCCLookup.entity(for: "1X1XX"))
    }
}

final class BandPlanTests: XCTestCase {
    func testPrimaryFT8Channels() {
        XCTAssertEqual(FTxBandPlan.primaryChannel(bandID: "20m", mode: .ft8)?.dialFrequencyHz, 14_074_000)
        XCTAssertEqual(FTxBandPlan.primaryChannel(bandID: "40m", mode: .ft8)?.dialFrequencyHz, 7_074_000)
        XCTAssertEqual(FTxBandPlan.primaryChannel(bandID: "20m", mode: .ft4)?.dialFrequencyHz, 14_080_000)
    }

    func testEveryBandHasOnePrimaryPerMode() {
        for mode in FTxProtocolMode.allCases {
            let byBand = Dictionary(grouping: FTxBandPlan.channels(for: mode).filter(\.isPrimary), by: \.bandID)
            for (band, chans) in byBand {
                XCTAssertEqual(chans.count, 1, "band \(band) mode \(mode)")
            }
        }
    }
}

final class AlertTests: XCTestCase {
    func testMatchesSenderAndAddressee() {
        let alert = CallsignAlert(callsign: "K1ABC")
        XCTAssertTrue(alert.matches(parsed: .parse("CQ K1ABC FN42"), currentBandID: "20m"))
        XCTAssertTrue(alert.matches(parsed: .parse("K1ABC W9FYI -07"), currentBandID: "20m"))
        XCTAssertFalse(alert.matches(parsed: .parse("CQ N0XYZ EM48"), currentBandID: "20m"))
    }

    func testBandRestriction() {
        let alert = CallsignAlert(callsign: "K1ABC", bandID: "40m")
        XCTAssertTrue(alert.matches(parsed: .parse("CQ K1ABC FN42"), currentBandID: "40m"))
        XCTAssertFalse(alert.matches(parsed: .parse("CQ K1ABC FN42"), currentBandID: "20m"))
    }

    func testDisabledAlertNeverMatches() {
        let alert = CallsignAlert(callsign: "K1ABC", enabled: false)
        XCTAssertFalse(alert.matches(parsed: .parse("CQ K1ABC FN42"), currentBandID: nil))
    }
}
