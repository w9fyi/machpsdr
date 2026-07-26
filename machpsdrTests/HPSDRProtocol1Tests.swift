import Testing
import Foundation
@testable import machpsdr

/// Tests for the pure Protocol 1 encode/decode logic: 24-bit sample sign
/// extension, the C0–C4 command bytes, EP2 frame layout, and EP6 parsing
/// (including the two-receiver interleave).
@Suite struct HPSDRProtocol1Tests {

    // MARK: - sample24 sign extension

    @Test func sample24Zero() {
        #expect(HPSDRProtocol1.sample24(0x00, 0x00, 0x00) == 0)
    }

    @Test func sample24SmallPositive() {
        #expect(HPSDRProtocol1.sample24(0x00, 0x00, 0x01) == 1)
        #expect(HPSDRProtocol1.sample24(0x00, 0x00, 0xFF) == 255)
        #expect(HPSDRProtocol1.sample24(0x00, 0x01, 0x00) == 256)
    }

    @Test func sample24MaxPositive() {
        // 0x7FFFFF is the largest positive 24-bit two's-complement value.
        #expect(HPSDRProtocol1.sample24(0x7F, 0xFF, 0xFF) == 8_388_607)
    }

    @Test func sample24NegativeOne() {
        // 0xFFFFFF == -1 after sign extension.
        #expect(HPSDRProtocol1.sample24(0xFF, 0xFF, 0xFF) == -1)
        #expect(HPSDRProtocol1.sample24(0xFF, 0xFF, 0xFE) == -2)
    }

    @Test func sample24MostNegative() {
        // 0x800000 is the most negative 24-bit value: -2^23.
        #expect(HPSDRProtocol1.sample24(0x80, 0x00, 0x00) == -8_388_608)
    }

    // MARK: - RadioSettings.commandBytes

    @Test func configSlotDefaults() {
        let s = RadioSettings()   // 48 kHz, 1 receiver, no OC, mox off
        let c = s.commandBytes(slot: 0)
        #expect(c.0 == 0x00)                 // C0 config, mox clear
        #expect(c.1 == 0x00)                 // C1 sample rate 48k
        #expect(c.2 == 0x00)                 // C2 open collector (none)
        #expect(c.3 == 0x00)
        #expect(c.4 == 0x04)                 // C4 duplex bit set, 0 extra receivers
    }

    @Test func configSlotDuplexBitAlwaysSet() {
        // The duplex bit (0x04) must be present regardless of receiver count.
        for count in 1...4 {
            var s = RadioSettings()
            s.receiverCount = count
            let c4 = s.commandBytes(slot: 0).4
            #expect(c4 & 0x04 != 0, "duplex bit missing for \(count) receivers")
        }
    }

    @Test func configSlotReceiverCountBits() {
        // Bits 5:3 of C4 encode (receivers − 1).
        let expected: [Int: UInt8] = [1: 0x04, 2: 0x0C, 3: 0x14, 4: 0x1C]
        for (count, want) in expected {
            var s = RadioSettings()
            s.receiverCount = count
            #expect(s.commandBytes(slot: 0).4 == want, "wrong C4 for \(count) receivers")
        }
    }

    @Test func configSlotSampleRate() {
        var s = RadioSettings()
        s.sampleRate = .rate192k
        #expect(s.commandBytes(slot: 0).1 == 2)   // 192k rawValue
        s.sampleRate = .rate384k
        #expect(s.commandBytes(slot: 0).1 == 3)
    }

    @Test func configSlotOpenCollector() {
        var s = RadioSettings()
        s.openCollector = 0x7F                    // all 7 OC lines high
        #expect(s.commandBytes(slot: 0).2 == 0xFE) // 7-bit pattern shifted left 1
    }

    @Test func moxBitSetInConfigSlot() {
        var s = RadioSettings()
        s.mox = true
        #expect(s.commandBytes(slot: 0).0 == 0x01)
    }

    @Test func txFrequencySlotBigEndian() {
        var s = RadioSettings()
        s.transmitFrequency = 0x1234_5678
        let c = s.commandBytes(slot: 1)
        #expect(c.0 == 0x02)   // TX NCO command
        #expect(c.1 == 0x12)
        #expect(c.2 == 0x34)
        #expect(c.3 == 0x56)
        #expect(c.4 == 0x78)
    }

    @Test func driveSlot() {
        var s = RadioSettings()
        s.drive = 200
        let c = s.commandBytes(slot: 2)
        #expect(c.0 == 0x12)
        #expect(c.1 == 200)
    }

    @Test func attenuatorSlot() {
        var s = RadioSettings()
        s.rxAttenuator = 10
        let c = s.commandBytes(slot: 3)
        #expect(c.0 == 0x14)
        #expect(c.4 == 0x2A)   // enable bit 0x20 | 10 dB
        s.rxAttenuator = 31
        #expect(s.commandBytes(slot: 3).4 == 0x3F)
    }

    @Test func receiverFrequencySlots() {
        var s = RadioSettings()
        s.receiverCount = 2
        s.receiverFrequencies = [0x1122_3344, 0x5566_7788]
        let rx0 = s.commandBytes(slot: 4)
        #expect(rx0.0 == 0x04)
        #expect(rx0.1 == 0x11 && rx0.2 == 0x22 && rx0.3 == 0x33 && rx0.4 == 0x44)
        let rx1 = s.commandBytes(slot: 5)
        #expect(rx1.0 == 0x06)   // 0x04 + rx*2
        #expect(rx1.1 == 0x55 && rx1.2 == 0x66 && rx1.3 == 0x77 && rx1.4 == 0x88)
    }

    @Test func pureSignalRetunesFeedbackReceiversOnlyDuringMox() {
        var s = RadioSettings()
        s.receiverCount = 2
        s.receiverFrequencies = [0x1122_3344, 0x5566_7788]
        s.transmitFrequency = 0x0072_5000
        s.puresignal = true
        s.psRxFeedback = 0
        s.psTxFeedback = 1

        // Receiving: both NCOs stay on their own frequencies.
        var rx0 = s.commandBytes(slot: 4)
        #expect(rx0.1 == 0x11 && rx0.2 == 0x22 && rx0.3 == 0x33 && rx0.4 == 0x44)

        // Transmitting: both feedback receivers follow the TX frequency.
        s.mox = true
        rx0 = s.commandBytes(slot: 4)
        let rx1 = s.commandBytes(slot: 5)
        #expect(rx0.1 == 0x00 && rx0.2 == 0x72 && rx0.3 == 0x50 && rx0.4 == 0x00)
        #expect(rx1.1 == 0x00 && rx1.2 == 0x72 && rx1.3 == 0x50 && rx1.4 == 0x00)

        // PS disarmed: MOX alone must not retune any receiver.
        s.puresignal = false
        rx0 = s.commandBytes(slot: 4)
        #expect(rx0.1 == 0x11 && rx0.2 == 0x22 && rx0.3 == 0x33 && rx0.4 == 0x44)
    }

    @Test func commandSlotCountTracksReceivers() {
        var s = RadioSettings()
        s.receiverCount = 3
        #expect(s.commandSlotCount == 7)   // 4 fixed + 3 RX
    }

    // MARK: - buildEP2 header / sync layout

    @Test func ep2HeaderAndSyncLayout() {
        let s = RadioSettings()
        let frame = HPSDRFrame.buildEP2(sequence: 0x0A0B_0C0D, settings: s, slot1: 0, slot2: 1)

        #expect(frame.count == HPSDRProtocol1.frameSize)   // 1032
        #expect(frame[0] == 0xEF && frame[1] == 0xFE)      // Metis magic
        #expect(frame[2] == 0x01)                          // packet type = data
        #expect(frame[3] == 0x02)                          // EP2 (to radio)
        // 32-bit big-endian sequence.
        #expect(frame[4] == 0x0A && frame[5] == 0x0B && frame[6] == 0x0C && frame[7] == 0x0D)

        // First USB sub-frame at offset 8: 3 sync bytes then C0–C4 for slot1.
        #expect(frame[8] == 0x7F && frame[9] == 0x7F && frame[10] == 0x7F)
        let c1 = s.commandBytes(slot: 0)
        #expect(frame[11] == c1.0 && frame[12] == c1.1 && frame[13] == c1.2
                && frame[14] == c1.3 && frame[15] == c1.4)

        // Second USB sub-frame at offset 520.
        #expect(frame[520] == 0x7F && frame[521] == 0x7F && frame[522] == 0x7F)
        let c2 = s.commandBytes(slot: 1)
        #expect(frame[523] == c2.0 && frame[524] == c2.1 && frame[525] == c2.2
                && frame[526] == c2.3 && frame[527] == c2.4)
    }

    @Test func ep2RxOnlyLeavesSampleAreaZero() {
        let frame = HPSDRFrame.buildEP2(sequence: 0, settings: RadioSettings(),
                                        slot1: 0, slot2: 1, txIQ: nil)
        // First sample slot begins at offset 16; RX-only must leave it zeroed.
        for i in 16..<24 { #expect(frame[i] == 0) }
    }

    @Test func ep2PacksTXIQBigEndian() {
        // 126 I/Q pairs fill both USB sub-frames (63 each).
        var iq = [Float](repeating: 0, count: 252)
        iq[0] = 1.0;  iq[1] = -1.0            // frame 1, sample 0
        iq[126] = 1.0; iq[127] = -1.0         // frame 2, sample 0 (pair index 63)

        let frame = HPSDRFrame.buildEP2(sequence: 0, settings: RadioSettings(),
                                        slot1: 0, slot2: 1, txIQ: iq)

        // Frame 1 sample 0: base = 8 + 8 = 16. L/R zero, then I(2) Q(2).
        #expect(frame[16] == 0 && frame[17] == 0 && frame[18] == 0 && frame[19] == 0)
        #expect(frame[20] == 0x7F && frame[21] == 0xFF)   // I = +1.0 -> 32767
        #expect(frame[22] == 0x80 && frame[23] == 0x01)   // Q = -1.0 -> -32767

        // Frame 2 sample 0: base = 520 + 8 = 528.
        #expect(frame[532] == 0x7F && frame[533] == 0xFF)
        #expect(frame[534] == 0x80 && frame[535] == 0x01)
    }

    // MARK: - HL2 N2ADR filter board selection

    @Test func hl2FilterBoardSelectsLPFPerBand() {
        // Bits 0–5 = LPF for 160 / 80 / 60-40 / 30-20 / 17-15 / 12-10 m;
        // bit 6 (0x40) = 3 MHz RX high-pass, on for every band except 160 m.
        #expect(HL2FilterBoard.code(forHz: 1_840_000) == 0x01)          // 160 m, HPF out
        #expect(HL2FilterBoard.code(forHz: 3_573_000) == 0x42)          // 80 m
        #expect(HL2FilterBoard.code(forHz: 5_357_000) == 0x44)          // 60 m
        #expect(HL2FilterBoard.code(forHz: 7_074_000) == 0x44)          // 40 m
        #expect(HL2FilterBoard.code(forHz: 10_136_000) == 0x48)         // 30 m
        #expect(HL2FilterBoard.code(forHz: 14_074_000) == 0x48)         // 20 m
        #expect(HL2FilterBoard.code(forHz: 18_100_000) == 0x50)         // 17 m
        #expect(HL2FilterBoard.code(forHz: 21_074_000) == 0x50)         // 15 m
        #expect(HL2FilterBoard.code(forHz: 24_915_000) == 0x60)         // 12 m
        #expect(HL2FilterBoard.code(forHz: 28_074_000) == 0x60)         // 10 m
        #expect(HL2FilterBoard.code(forHz: 50_313_000) == 0x40)         // 6 m: bypass
    }

    @Test func hl2ConfigSlotCarriesFilterCodeNotOCPattern() {
        var s = RadioSettings()
        s.hermesLite = true
        s.transmitFrequency = 14_074_000
        s.openCollector = 0x33   // amp band-data pattern: must be ignored on HL2
        // 20 m filter code 0x48 shifted into C2 bits [7:1].
        #expect(s.commandBytes(slot: 0).2 == 0x48 << 1)
        s.hermesLite = false
        #expect(s.commandBytes(slot: 0).2 == 0x33 << 1)   // ANAN: user pattern
    }

    @Test func hl2GainSlotUsesExtendedLNAMode() {
        var s = RadioSettings()
        s.rxAttenuator = 10          // must be ignored on HL2
        s.hermesLite = true
        s.rxLNAGain = 48
        #expect(s.commandBytes(slot: 3).4 == 0x40 | 60)   // +48 dB → code 60
        s.rxLNAGain = -12
        #expect(s.commandBytes(slot: 3).4 == 0x40)        // −12 dB → code 0
        s.rxLNAGain = 19
        #expect(s.commandBytes(slot: 3).4 == 0x40 | 31)   // parity default
        s.hermesLite = false
        #expect(s.commandBytes(slot: 3).4 == 0x20 | 10)   // ANAN: legacy attenuator
    }

    // MARK: - Frequency calibration (ppm)

    @Test func frequencyCalibrationScalesNCO() {
        var s = RadioSettings()
        s.transmitFrequency = 14_074_000
        s.receiverFrequencies = [14_074_000]
        s.frequencyCalibrationPPM = 10   // radio clock 10 ppm high → send lower NCO
        // 14074000 / (1 + 1e-5) ≈ 14073859.26 → 14073859 = 0xD6C007
        let tx = s.commandBytes(slot: 1)
        let sent = (UInt32(tx.1) << 24) | (UInt32(tx.2) << 16) | (UInt32(tx.3) << 8) | UInt32(tx.4)
        #expect(sent == 14_073_859)
        // RX slot gets the same correction.
        let rx = s.commandBytes(slot: 4)
        let sentRx = (UInt32(rx.1) << 24) | (UInt32(rx.2) << 16) | (UInt32(rx.3) << 8) | UInt32(rx.4)
        #expect(sentRx == 14_073_859)
    }

    @Test func frequencyCalibrationZeroIsExact() {
        var s = RadioSettings()
        s.transmitFrequency = 14_074_000
        let tx = s.commandBytes(slot: 1)
        let sent = (UInt32(tx.1) << 24) | (UInt32(tx.2) << 16) | (UInt32(tx.3) << 8) | UInt32(tx.4)
        #expect(sent == 14_074_000)
    }

    @Test func hl2DriveSlotSetsPAEnable() {
        var s = RadioSettings()
        s.drive = 128
        #expect(s.commandBytes(slot: 2).2 == 0x00)   // ANAN: no PA bit
        s.hermesLite = true
        let c = s.commandBytes(slot: 2)
        #expect(c.0 == 0x12)
        #expect(c.1 == 128)
        #expect(c.2 == 0x08)   // word bit 19: onboard PA on
    }

    // MARK: - HL2 IO board I2C writes

    @Test func ioBoardWriteCommandBytes() {
        // I2C bus 2 (C&C addr 0x3D << 1), write cookie, stop bit | Pico addr 0x1D.
        let c = HL2IOBoard.writeCommand(register: 5, value: 1, mox: false)
        #expect(c.0 == 0x7A)
        #expect(c.1 == 0x06)
        #expect(c.2 == 0x9D)
        #expect(c.3 == 5)
        #expect(c.4 == 1)
    }

    @Test func ioBoardWriteCommandCarriesMoxBit() {
        #expect(HL2IOBoard.writeCommand(register: 0, value: 0, mox: true).0 == 0x7B)
    }

    @Test func ioBoardFrequencyWritesBigEndianByte0Last() {
        // 14,074,000 Hz = 0x00D6C090; registers 0 (MSB) … 4 (LSB), LSB last
        // because writing register 4 is what latches the value in the Pico.
        let writes = HL2IOBoard.frequencyWrites(hz: 14_074_000)
        #expect(writes.map(\.register) == [0, 1, 2, 3, 4])
        #expect(writes.map(\.value) == [0x00, 0x00, 0xD6, 0xC0, 0x90])
    }

    @Test func ep2Command2OverridesSlot2Only() {
        let s = RadioSettings()
        let io = HL2IOBoard.writeCommand(register: 4, value: 0x90, mox: false)
        let frame = HPSDRFrame.buildEP2(sequence: 0, settings: s, slot1: 0, slot2: 1,
                                        command2: io)
        // Slot 1 (offset 8) still carries the rotation's config command.
        let c1 = s.commandBytes(slot: 0)
        #expect(frame[11] == c1.0 && frame[12] == c1.1 && frame[13] == c1.2
                && frame[14] == c1.3 && frame[15] == c1.4)
        // Slot 2 (offset 520) carries the raw I2C write instead of slot index 1.
        #expect(frame[523] == 0x7A && frame[524] == 0x06 && frame[525] == 0x9D
                && frame[526] == 4 && frame[527] == 0x90)
    }

    // MARK: - parseEP6

    /// Builds a valid 1032-byte EP6 frame. `fill` populates the sample area per
    /// USB sub-frame given its byte offset.
    private func makeEP6(sequence: UInt32,
                         c0First: UInt8, c0Second: UInt8,
                         adc: UInt8 = 0, versionC2: UInt8 = 0,
                         versionC3: UInt8 = 0, versionC4: UInt8 = 0,
                         fill: (_ data: inout [UInt8], _ usbOffset: Int) -> Void) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: HPSDRProtocol1.frameSize)
        data[0] = 0xEF; data[1] = 0xFE; data[2] = 0x01; data[3] = 0x06
        data[4] = UInt8((sequence >> 24) & 0xFF)
        data[5] = UInt8((sequence >> 16) & 0xFF)
        data[6] = UInt8((sequence >> 8) & 0xFF)
        data[7] = UInt8(sequence & 0xFF)
        for (usbOffset, c0) in [(8, c0First), (520, c0Second)] {
            data[usbOffset] = 0x7F; data[usbOffset + 1] = 0x7F; data[usbOffset + 2] = 0x7F
            data[usbOffset + 3] = c0
            data[usbOffset + 4] = adc          // status block 0: bit 0 = ADC overflow
            data[usbOffset + 5] = versionC2
            data[usbOffset + 6] = versionC3
            data[usbOffset + 7] = versionC4
            fill(&data, usbOffset)
        }
        return data
    }

    @Test func parseEP6RejectsBadHeader() {
        var data = [UInt8](repeating: 0, count: HPSDRProtocol1.frameSize)
        data[0] = 0x00; data[1] = 0xFE; data[3] = 0x06
        #expect(HPSDRFrame.parseEP6(data, receiverCount: 1) == nil)

        data[0] = 0xEF; data[3] = 0x02   // wrong endpoint (EP2)
        #expect(HPSDRFrame.parseEP6(data, receiverCount: 1) == nil)
    }

    @Test func parseEP6RejectsShortData() {
        let data = [UInt8](repeating: 0, count: 100)
        #expect(HPSDRFrame.parseEP6(data, receiverCount: 1) == nil)
    }

    @Test func parseEP6SingleReceiverSampleCount() {
        // 1 RX -> 8 bytes/group -> 63 groups/USB frame -> 126 pairs -> 252 floats.
        let data = makeEP6(sequence: 0x1234, c0First: 0, c0Second: 0) { _, _ in }
        let result = HPSDRFrame.parseEP6(data, receiverCount: 1)
        #expect(result != nil)
        #expect(result?.sequence == 0x1234)
        #expect(result?.receivers.count == 1)
        #expect(result?.receivers[0].count == 252)
    }

    @Test func parseEP6RoundTripsSample() {
        let scale: Float = 1.0 / 8_388_608.0
        // Place I=+1, Q=-1 in group 0 of the first USB frame.
        let data = makeEP6(sequence: 0, c0First: 0, c0Second: 0) { d, usbOffset in
            let base = usbOffset + HPSDRProtocol1.usbHeaderSize   // first group
            d[base + 0] = 0x00; d[base + 1] = 0x00; d[base + 2] = 0x01   // I = 1
            d[base + 3] = 0xFF; d[base + 4] = 0xFF; d[base + 5] = 0xFF   // Q = -1
        }
        let result = HPSDRFrame.parseEP6(data, receiverCount: 1)
        #expect(result?.receivers[0][0] == Float(1) * scale)
        #expect(result?.receivers[0][1] == Float(-1) * scale)
    }

    @Test func parseEP6StatusBits() {
        // c0 low bits carry PTT/dash/dot; status block 0 carries ADC overflow + version.
        let data = makeEP6(sequence: 0, c0First: 0x07, c0Second: 0x07,
                           adc: 0x01, versionC2: 0x99, versionC3: 0xAA, versionC4: 0xBB) { _, _ in }
        let status = HPSDRFrame.parseEP6(data, receiverCount: 1)?.status
        #expect(status?.ptt == true)
        #expect(status?.dash == true)
        #expect(status?.dot == true)
        #expect(status?.adcOverflow == true)
        #expect(status?.versionC2 == 0x99)
        #expect(status?.versionC3 == 0xAA)
        #expect(status?.versionC4 == 0xBB)
    }

    @Test func parseEP6TwoReceiverInterleave() {
        let scale: Float = 1.0 / 8_388_608.0
        // 2 RX -> 14 bytes/group -> 36 groups/USB frame -> 72 pairs -> 144 floats each.
        let data = makeEP6(sequence: 0, c0First: 0, c0Second: 0) { d, usbOffset in
            let groupBase = usbOffset + HPSDRProtocol1.usbHeaderSize
            // rx0 occupies bytes 0..5, rx1 occupies bytes 6..11 within the group.
            d[groupBase + 2] = 0x01                      // rx0 I = 1
            d[groupBase + 6 + 2] = 0x02                  // rx1 I = 2
        }
        let result = HPSDRFrame.parseEP6(data, receiverCount: 2)
        #expect(result?.receivers.count == 2)
        #expect(result?.receivers[0].count == 144)
        #expect(result?.receivers[1].count == 144)
        #expect(result?.receivers[0][0] == Float(1) * scale)
        #expect(result?.receivers[1][0] == Float(2) * scale)
    }
}
