import Testing
@testable import machpsdr

/// A stand-in radio recording what the CAT processor reads and writes.
@MainActor
private final class MockRadio: CATRadioControl {
    var frequencyHz: UInt32 = 7_074_000
    var mode: RadioMode = .usb
    var isTransmitting = false
    var driveLevel: Double = 10
    var volume: Float = 0.5
    var signalRMS: Float = 0
    func setFrequency(_ hz: UInt32) { frequencyHz = hz }
    func setMode(_ newMode: RadioMode) { mode = newMode }
    func setPTT(_ on: Bool) { isTransmitting = on }
    func setDrive(_ percent: Double) { driveLevel = percent }
    func setVolume(_ newVolume: Float) { volume = newVolume }
}

@Suite @MainActor struct CATCommandProcessorTests {
    private let radio = MockRadio()
    private var cat: CATCommandProcessor { CATCommandProcessor(radio: radio) }

    @Test func identifiesAsTS2000() {
        #expect(cat.handle("ID") == "ID019;")
    }

    @Test func faReadIsZeroPaddedTo11Digits() {
        #expect(cat.handle("FA") == "FA00007074000;")
    }

    @Test func faSetTunesTheRadioAndReturnsNothing() {
        #expect(cat.handle("FA00014074000") == "")
        #expect(radio.frequencyHz == 14_074_000)
    }

    @Test func faSetRejectsGarbage() {
        #expect(cat.handle("FA14.074") == "?;")
        #expect(radio.frequencyHz == 7_074_000)
    }

    @Test func modeReadUsesKenwoodDigits() {
        radio.mode = .lsb
        #expect(cat.handle("MD") == "MD1;")
        radio.mode = .digu
        #expect(cat.handle("MD") == "MD9;")
    }

    @Test func samReportsAsAM() {
        radio.mode = .sam
        #expect(cat.handle("MD") == "MD5;")
    }

    @Test func modeSetRoundTripsEveryDigit() {
        for (digit, mode): (String, RadioMode) in
            [("1", .lsb), ("2", .usb), ("3", .cwu), ("4", .fm),
             ("5", .am), ("6", .digl), ("7", .cwl), ("9", .digu)] {
            #expect(cat.handle("MD\(digit)") == "")
            #expect(radio.mode == mode)
        }
    }

    @Test func unknownModeDigitIsRejected() {
        #expect(cat.handle("MD8") == "?;")
    }

    @Test func txAndRxKeyThePTT() {
        #expect(cat.handle("TX") == "")
        #expect(radio.isTransmitting)
        #expect(cat.handle("RX") == "")
        #expect(!radio.isTransmitting)
    }

    @Test func ifStatusIs38CharactersWithFreqTXAndMode() {
        radio.frequencyHz = 14_074_000
        radio.mode = .usb
        radio.isTransmitting = true
        let reply = cat.handle("IF")
        #expect(reply.count == 38)
        #expect(reply.hasPrefix("IF00014074000"))
        #expect(reply.hasSuffix(";"))
        let chars = Array(reply)
        #expect(chars[28] == "1")   // P8 RX/TX
        #expect(chars[29] == "2")   // P9 mode = USB
    }

    @Test func vfoBIsAShadowRegister() {
        let processor = cat   // keep one instance so the shadow persists
        #expect(processor.handle("FB") == "FB00007074000;")   // defaults to VFO A
        #expect(processor.handle("FB00014074000") == "")
        #expect(processor.handle("FB") == "FB00014074000;")
        #expect(radio.frequencyHz == 7_074_000)               // radio untouched
    }

    @Test func drivePowerReadAndWrite() {
        #expect(cat.handle("PC") == "PC010;")
        #expect(cat.handle("PC050") == "")
        #expect(radio.driveLevel == 50)
        #expect(cat.handle("PC101") == "?;")
    }

    @Test func afGainReadAndWrite() {
        #expect(cat.handle("AG0") == "AG0128;")
        #expect(cat.handle("AG0255") == "")
        #expect(radio.volume == 1.0)
    }

    @Test func sMeterScalesWithSignal() {
        radio.signalRMS = 0
        #expect(cat.handle("SM0") == "SM00000;")
        radio.signalRMS = 1.0   // 0 dBFS pegs the meter
        #expect(cat.handle("SM0") == "SM00030;")
    }

    @Test func unknownCommandAnswersQuestionMark() {
        #expect(cat.handle("ZZXX") == "?;")
        #expect(cat.handle("Q") == "?;")
    }

    @Test func statusCommandsAnswerFixedValues() {
        #expect(cat.handle("PS") == "PS1;")
        #expect(cat.handle("AI") == "AI0;")
        #expect(cat.handle("FR") == "FR0;")
        #expect(cat.handle("FT") == "FT0;")
    }
}
