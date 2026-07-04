import Foundation

/// Pure encoding/decoding logic for openHPSDR Protocol 1 ("old protocol").
///
/// The host and radio exchange 1032-byte UDP frames on port 1024:
///   - Metis header (8 bytes): `0xEF 0xFE`, packet type `0x01`, endpoint, 32-bit sequence.
///   - Two 512-byte USB sub-frames, each: `0x7F 0x7F 0x7F` sync, 5 command bytes (C0–C4),
///     then 504 bytes of sample data.
///
/// Endpoint `0x02` (EP2) is host → radio (commands + TX I/Q).
/// Endpoint `0x06` (EP6) is radio → host (RX I/Q + mic + status).
///
/// All members are `nonisolated` so the networking layer can use them off the main actor.
nonisolated enum HPSDRProtocol1 {
    static let dataPort: UInt16 = 1024
    static let frameSize = 1032
    static let usbFrameSize = 512
    static let usbHeaderSize = 8          // 3 sync + 5 command bytes
    static let sync: UInt8 = 0x7F

    static let metisMagic0: UInt8 = 0xEF
    static let metisMagic1: UInt8 = 0xFE
    static let packetTypeData: UInt8 = 0x01
    static let endpointToRadio: UInt8 = 0x02   // EP2
    static let endpointFromRadio: UInt8 = 0x06 // EP6

    /// Sample rates selectable via the configuration command (C0 = 0x00, C1 bits 0–1).
    enum SampleRate: UInt8, CaseIterable {
        case rate48k = 0
        case rate96k = 1
        case rate192k = 2
        case rate384k = 3

        var hertz: Int {
            switch self {
            case .rate48k: return 48_000
            case .rate96k: return 96_000
            case .rate192k: return 192_000
            case .rate384k: return 384_000
            }
        }
    }

    // MARK: - Metis start / stop (64-byte command to radio:1024)

    /// Tells the radio to begin streaming. `iq` enables EP6 I/Q data; `wideband` enables EP4 raw ADC.
    static func startCommand(iq: Bool = true, wideband: Bool = false) -> [UInt8] {
        var packet = [UInt8](repeating: 0, count: 64)
        packet[0] = metisMagic0
        packet[1] = metisMagic1
        packet[2] = 0x04
        var flags: UInt8 = 0
        if iq { flags |= 0x01 }
        if wideband { flags |= 0x02 }
        packet[3] = flags
        return packet
    }

    /// Tells the radio to stop streaming.
    static func stopCommand() -> [UInt8] {
        var packet = [UInt8](repeating: 0, count: 64)
        packet[0] = metisMagic0
        packet[1] = metisMagic1
        packet[2] = 0x04
        packet[3] = 0x00
        return packet
    }

    // MARK: - 24-bit signed sample decoding

    /// Sign-extends a big-endian 24-bit two's-complement sample to Int32.
    static func sample24(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8) -> Int32 {
        var value = (Int32(b0) << 16) | (Int32(b1) << 8) | Int32(b2)
        if value & 0x0080_0000 != 0 {
            value |= Int32(bitPattern: 0xFF00_0000) // sign extend
        }
        return value
    }
}

/// Desired radio settings that get encoded into the outgoing C0–C4 command bytes.
nonisolated struct RadioSettings {
    var sampleRate: HPSDRProtocol1.SampleRate = .rate48k
    var receiverCount: Int = 1
    /// NCO frequency in Hz for each receiver.
    var receiverFrequencies: [UInt32] = [7_074_000]
    var transmitFrequency: UInt32 = 7_074_000
    var mox: Bool = false
    /// TX drive level, 0–255 (PA output scales with this).
    var drive: UInt8 = 0
    /// 7-bit open-collector output pattern (J16/accessory port) for amp band data.
    var openCollector: UInt8 = 0
    /// RX ADC step attenuator, 0–31 dB (0 = max gain / "preamp"). Sent in the 0x14 command.
    var rxAttenuator: UInt8 = 0
    /// HL2 only: AD9866 LNA gain in dB, −12…+48 (extended-mode 0x14 command).
    /// +19 dB matches the legacy "0 dB attenuation" level, so it is the parity default.
    var rxLNAGain: Int = 19
    /// Radio clock error in ppm (positive = radio's TCXO runs high). NCO frequencies
    /// are pre-divided by (1 + ppm/1e6) so the radio lands on the displayed frequency.
    var frequencyCalibrationPPM: Double = 0
    /// True when driving a Hermes Lite 2, whose gateware repurposes parts of the
    /// protocol: the OC bits select the N2ADR filter board's LPF (derived from the
    /// TX frequency, ignoring `openCollector`), and the drive command must set the
    /// PA-enable bit (0x09 word bit 19) or the onboard 5 W amplifier stays off and
    /// nothing reaches the ANT connector on transmit.
    var hermesLite: Bool = false

    /// Number of distinct command "slots" cycled through round-robin:
    /// slot 0 = configuration, slot 1 = TX frequency, slot 2 = drive/mic,
    /// slot 3 = RX attenuator, slots 4… = each RX frequency.
    var commandSlotCount: Int { 4 + receiverCount }

    /// Produces the five command bytes (C0–C4) for a given round-robin slot.
    func commandBytes(slot: Int) -> (UInt8, UInt8, UInt8, UInt8, UInt8) {
        let moxBit: UInt8 = mox ? 0x01 : 0x00
        switch slot {
        case 0:
            // Configuration: C0 = 0x00, C1 = sample-rate bits.
            // C4: bit 2 (0x04) = duplex — always set, matching piHPSDR/Thetis; the ANAN
            // needs this for correct multi-receiver framing (without it, requesting a
            // second receiver corrupts the USB-frame sync). Bits 5:3 = (receivers − 1).
            // C2 bits 1–7 = the 7 open-collector outputs (amp band data, etc.).
            let c4 = 0x04 | UInt8((max(receiverCount, 1) - 1) << 3)
            // On the HL2 the OC bits go verbatim to the N2ADR filter board, so they
            // must carry the LPF selection for the operating frequency, not the
            // user's amplifier band-data pattern.
            let oc = hermesLite ? HL2FilterBoard.code(forHz: transmitFrequency)
                                : openCollector
            let c2 = (oc & 0x7F) << 1
            return (0x00 | moxBit, sampleRate.rawValue, c2, 0x00, c4)
        case 1:
            // TX NCO frequency: C0 = 0x02, C1–C4 = 32-bit Hz big-endian.
            return Self.frequencyCommand(c0: 0x02 | moxBit, hz: calibrated(transmitFrequency))
        case 2:
            // Drive level / mic: C0 = 0x12, C1 = TX drive (0–255).
            // HL2: C2 bit 3 (word bit 19) enables the onboard PA — required for
            // any transmit power to reach the ANT connector.
            return (0x12 | moxBit, drive, hermesLite ? 0x08 : 0x00, 0x00, 0x00)
        case 3:
            // RX ADC step attenuator: C0 = 0x14, C4 = enable (0x20) | attenuation (0–31 dB).
            // 0 dB = maximum sensitivity ("preamp"); higher values attenuate the front end.
            // HL2: bit 6 selects the extended AD9866 gain mode, C4 [5:0] = gain + 12,
            // giving the full −12…+48 dB LNA range instead of the legacy attenuator.
            if hermesLite {
                let gain = UInt8(clamping: max(0, min(60, rxLNAGain + 12)))
                return (0x14 | moxBit, 0x00, 0x00, 0x00, 0x40 | gain)
            }
            return (0x14 | moxBit, 0x00, 0x00, 0x00, 0x20 | (rxAttenuator & 0x1F))
        default:
            // RX NCO frequency: C0 = 0x04 + receiverIndex*2.
            let rx = slot - 4
            let c0 = UInt8(0x04 + rx * 2) | moxBit
            let hz = rx < receiverFrequencies.count ? receiverFrequencies[rx] : (receiverFrequencies.first ?? 0)
            return Self.frequencyCommand(c0: c0, hz: calibrated(hz))
        }
    }

    /// Applies the ppm clock correction to an NCO frequency: the radio scales every
    /// NCO by its actual/nominal clock ratio, so dividing here makes it land on the
    /// displayed frequency. Display values elsewhere (spectrum centers, band and
    /// filter selection) stay in true Hz.
    private func calibrated(_ hz: UInt32) -> UInt32 {
        guard frequencyCalibrationPPM != 0 else { return hz }
        return UInt32((Double(hz) / (1 + frequencyCalibrationPPM / 1_000_000)).rounded())
    }

    private static func frequencyCommand(c0: UInt8, hz: UInt32) -> (UInt8, UInt8, UInt8, UInt8, UInt8) {
        (c0,
         UInt8((hz >> 24) & 0xFF),
         UInt8((hz >> 16) & 0xFF),
         UInt8((hz >> 8) & 0xFF),
         UInt8(hz & 0xFF))
    }
}

/// Filter selection for the N2ADR filter board inside a Hermes Lite 2. Unlike the
/// ANAN boards, the HL2 gateware does no frequency-based filter switching: the seven
/// "open collector" bits of the config command (C&C 0x00, C2 bits [7:1]) are
/// forwarded verbatim to the filter board and directly select its filters — bits 0–5
/// one LPF each (160 / 80 / 60-40 / 30-20 / 17-15 / 12-10 m), bit 6 = 3 MHz receive
/// high-pass (used on every band except 160 m). The host must derive these bits from
/// the TX frequency; sending anything else (e.g. an amplifier band-data pattern)
/// engages the wrong LPF, which silences RX on any band above that filter's cutoff.
/// With no LPF bit set the board passes the signal unfiltered.
nonisolated enum HL2FilterBoard {
    static func code(forHz hz: UInt32) -> UInt8 {
        let hpf: UInt8 = 0x40
        switch hz {
        case ..<2_500_000: return 0x01           // 160 m LPF, broadcast HPF out
        case ..<4_800_000: return 0x02 | hpf     // 80 m
        case ..<8_000_000: return 0x04 | hpf     // 60/40 m
        case ..<15_000_000: return 0x08 | hpf    // 30/20 m
        case ..<22_000_000: return 0x10 | hpf    // 17/15 m
        case ..<32_000_000: return 0x20 | hpf    // 12/10 m
        default: return hpf                      // above 10 m: unfiltered pass-through
        }
    }
}

/// C&C encoding for the N2ADR IO board that plugs into a Hermes Lite 2. The board's
/// Pico listens at I2C address 0x1D on the HL2's second I2C bus, reachable from the
/// host as C&C memory address 0x3D. The SDR host programs the 5-byte TX frequency
/// (Hz) into registers 0–4 so the board's firmware can band-follow an amplifier
/// (e.g. the m0hpf_spe firmware emits Yaesu FT-2000-style CAT at 19200 baud for the
/// SPE Expert). Writes are fire-and-forget (no RQST/ACK bit), matching piHPSDR:
/// a write with no board installed is a harmless I2C NAK.
nonisolated enum HL2IOBoard {
    /// Registers 0–4 hold the TX frequency, MSB (byte 4) first.
    static let regTxFreqByte4: UInt8 = 0
    /// Writing 1 resets all Pico registers to zero (recommended at connect).
    static let regControl: UInt8 = 5

    /// One register write as EP2 command bytes: C0 = I2C-bus-2 address (0x3D) plus
    /// the MOX bit, C1 = 0x06 write cookie, C2 = stop bit | Pico I2C address,
    /// C3 = register, C4 = value.
    static func writeCommand(register: UInt8, value: UInt8,
                             mox: Bool) -> (UInt8, UInt8, UInt8, UInt8, UInt8) {
        ((0x3D << 1) | (mox ? 0x01 : 0x00), 0x06, 0x80 | 0x1D, register, value)
    }

    /// The register writes programming the TX frequency. Byte 0 (LSB, register 4)
    /// must go last: that write makes the Pico latch the whole 5-byte value.
    static func frequencyWrites(hz: UInt32) -> [(register: UInt8, value: UInt8)] {
        [(0, 0),   // frequency byte 4: always 0 for a 32-bit Hz value
         (1, UInt8((hz >> 24) & 0xFF)),
         (2, UInt8((hz >> 16) & 0xFF)),
         (3, UInt8((hz >> 8) & 0xFF)),
         (4, UInt8(hz & 0xFF))]
    }
}

/// Status reported by the radio in the C0–C4 bytes of received EP6 frames.
nonisolated struct RadioStreamStatus: Equatable {
    var ptt = false
    var dash = false
    var dot = false
    var adcOverflow = false
    /// Raw version/status bytes from status block 0 (C2–C4); interpretation refined against hardware.
    var versionC2: UInt8 = 0
    var versionC3: UInt8 = 0
    var versionC4: UInt8 = 0
}

/// Builds outgoing EP2 frames (host → radio) and parses incoming EP6 frames (radio → host).
nonisolated enum HPSDRFrame {
    /// Builds a 1032-byte EP2 frame carrying two command slots. When `txIQ` is
    /// supplied (126 interleaved I/Q Float samples), it is packed as transmit data;
    /// otherwise the sample area is zero (RX-only).
    static func buildEP2(sequence: UInt32,
                         settings: RadioSettings,
                         slot1: Int,
                         slot2: Int,
                         txIQ: [Float]? = nil,
                         command2: (UInt8, UInt8, UInt8, UInt8, UInt8)? = nil) -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: HPSDRProtocol1.frameSize)
        buildEP2(into: &frame, sequence: sequence, settings: settings,
                 slot1: slot1, slot2: slot2, txIQ: txIQ, command2: command2)
        return frame
    }

    /// In-place variant: rewrites `frame` (which must be `frameSize` bytes). The send
    /// loop reuses one frame buffer so no allocation happens per outgoing packet.
    /// A non-nil `command2` carries raw C0–C4 bytes in the second USB sub-frame in
    /// place of `slot2` (used for out-of-rotation commands like IO-board I2C writes;
    /// the skipped slot comes around again on the next rotation cycle).
    static func buildEP2(into frame: inout [UInt8],
                         sequence: UInt32,
                         settings: RadioSettings,
                         slot1: Int,
                         slot2: Int,
                         txIQ: [Float]? = nil,
                         command2: (UInt8, UInt8, UInt8, UInt8, UInt8)? = nil) {
        precondition(frame.count == HPSDRProtocol1.frameSize)
        frame.withUnsafeMutableBytes { _ = memset($0.baseAddress, 0, $0.count) }
        frame[0] = HPSDRProtocol1.metisMagic0
        frame[1] = HPSDRProtocol1.metisMagic1
        frame[2] = HPSDRProtocol1.packetTypeData
        frame[3] = HPSDRProtocol1.endpointToRadio
        frame[4] = UInt8((sequence >> 24) & 0xFF)
        frame[5] = UInt8((sequence >> 16) & 0xFF)
        frame[6] = UInt8((sequence >> 8) & 0xFF)
        frame[7] = UInt8(sequence & 0xFF)
        // 63 samples per USB frame.
        writeUSBFrame(into: &frame, at: 8, command: settings.commandBytes(slot: slot1),
                      txIQ: txIQ, sampleStart: 0)
        writeUSBFrame(into: &frame, at: 520, command: command2 ?? settings.commandBytes(slot: slot2),
                      txIQ: txIQ, sampleStart: 63)
    }

    /// Each TX sample is 8 bytes: L(2) R(2) I(2) Q(2), 16-bit signed big-endian.
    /// L/R are left zero; I/Q come from `txIQ` (interleaved Floats in [-1, 1]).
    private static func writeUSBFrame(into frame: inout [UInt8],
                                      at offset: Int,
                                      command: (UInt8, UInt8, UInt8, UInt8, UInt8),
                                      txIQ: [Float]?,
                                      sampleStart: Int) {
        frame[offset] = HPSDRProtocol1.sync
        frame[offset + 1] = HPSDRProtocol1.sync
        frame[offset + 2] = HPSDRProtocol1.sync
        frame[offset + 3] = command.0
        frame[offset + 4] = command.1
        frame[offset + 5] = command.2
        frame[offset + 6] = command.3
        frame[offset + 7] = command.4

        guard let txIQ else { return } // RX-only: leave samples zero
        for s in 0..<63 {
            let iqIndex = (sampleStart + s) * 2
            guard iqIndex + 1 < txIQ.count else { break }
            let i = int16Sample(txIQ[iqIndex])
            let q = int16Sample(txIQ[iqIndex + 1])
            let base = offset + 8 + s * 8
            // L and R audio = 0 (bytes base..base+3 already zero)
            frame[base + 4] = UInt8(truncatingIfNeeded: i >> 8)
            frame[base + 5] = UInt8(truncatingIfNeeded: i)
            frame[base + 6] = UInt8(truncatingIfNeeded: q >> 8)
            frame[base + 7] = UInt8(truncatingIfNeeded: q)
        }
    }

    private static func int16Sample(_ value: Float) -> Int16 {
        let clamped = max(-1, min(1, value))
        return Int16(clamped * 32767)
    }

    /// The result of parsing one EP6 packet: the latest status and the decoded I/Q
    /// samples for every active receiver.
    struct EP6Result {
        var sequence: UInt32
        var status: RadioStreamStatus
        /// Interleaved I/Q per receiver: `receivers[rx] == [i0, q0, i1, q1, …]`,
        /// normalized Floats in [-1, 1). One inner array per active DDC.
        var receivers: [[Float]]
        /// Convenience accessor for receiver 0 (empty if there are none).
        var samples: [Float] { receivers.first ?? [] }
    }

    /// Parses a received EP6 packet. Returns nil if the header/sync is invalid.
    /// Decodes all `receiverCount` receivers from each interleaved sample group.
    /// `length` bounds how much of `data` is valid (a reused receive buffer is
    /// usually larger than the datagram); nil means all of it.
    static func parseEP6(_ data: [UInt8], length: Int? = nil, receiverCount: Int) -> EP6Result? {
        let count = min(length ?? data.count, data.count)
        guard count >= HPSDRProtocol1.frameSize else { return nil }
        return data.withUnsafeBufferPointer { buf -> EP6Result? in
            guard let d = buf.baseAddress,
                  d[0] == HPSDRProtocol1.metisMagic0,
                  d[1] == HPSDRProtocol1.metisMagic1,
                  d[3] == HPSDRProtocol1.endpointFromRadio else {
                return nil
            }
            let sequence = (UInt32(d[4]) << 24) | (UInt32(d[5]) << 16)
                | (UInt32(d[6]) << 8) | UInt32(d[7])

            var status = RadioStreamStatus()
            let rxCount = max(receiverCount, 1)
            // Each I/Q sample group is (3 bytes I + 3 bytes Q) per receiver, then 2 bytes mic.
            let bytesPerGroup = 6 * rxCount + 2
            let sampleAreaSize = HPSDRProtocol1.usbFrameSize - HPSDRProtocol1.usbHeaderSize
            let groupCount = sampleAreaSize / bytesPerGroup
            var receivers = [[Float]](repeating: [], count: rxCount)
            for rx in 0..<rxCount { receivers[rx].reserveCapacity(groupCount * 4) }
            let scale: Float = 1.0 / 8_388_608.0 // 2^23

            for usbOffset in [8, 520] {
                guard d[usbOffset] == HPSDRProtocol1.sync,
                      d[usbOffset + 1] == HPSDRProtocol1.sync,
                      d[usbOffset + 2] == HPSDRProtocol1.sync else {
                    continue
                }
                let c0 = d[usbOffset + 3]
                status.ptt = c0 & 0x01 != 0
                status.dash = c0 & 0x02 != 0
                status.dot = c0 & 0x04 != 0
                let statusBlock = (c0 >> 3) & 0x1F
                if statusBlock == 0 {
                    status.adcOverflow = d[usbOffset + 4] & 0x01 != 0
                    status.versionC2 = d[usbOffset + 5]
                    status.versionC3 = d[usbOffset + 6]
                    status.versionC4 = d[usbOffset + 7]
                }

                // Decode every receiver's I/Q from each interleaved group. Within a group,
                // receiver rx occupies bytes [rx*6 ..< rx*6+6] (I: 3, Q: 3); mic trails.
                let sampleBase = usbOffset + HPSDRProtocol1.usbHeaderSize
                for group in 0..<groupCount {
                    let groupBase = sampleBase + group * bytesPerGroup
                    for rx in 0..<rxCount {
                        let p = groupBase + rx * 6
                        let i = HPSDRProtocol1.sample24(d[p], d[p + 1], d[p + 2])
                        let q = HPSDRProtocol1.sample24(d[p + 3], d[p + 4], d[p + 5])
                        // Raw I/Q (no conjugation here) so the panadapter shows the correct
                        // orientation. WDSP gets a conjugated copy in WDSPRadio.
                        receivers[rx].append(Float(i) * scale)
                        receivers[rx].append(Float(q) * scale)
                    }
                }
            }
            return EP6Result(sequence: sequence, status: status, receivers: receivers)
        }
    }
}

/// Reassembles the EP6 sample stream across datagram boundaries.
///
/// `HPSDRFrame.parseEP6` assumes the two 512-byte USB frames sit at offsets 8 and
/// 520 of every datagram. The ANAN-10E violates that after any STOP/START: its
/// FIFO restarts packetizing mid-frame, so the frames land at a constant but
/// arbitrary shift (observed live: sync at 322/834, then 200/712 after slice-count
/// rebuilds) and fixed-offset parsing decodes nothing — permanent silence. The
/// frames themselves stay intact and contiguous (offsets always 512 apart), so the
/// robust decode is: strip each datagram's 8-byte Metis header, append the payload
/// to a persistent byte stream, and decode every complete 512-byte USB frame
/// wherever the 7F 7F 7F sync word lands, hunting for sync again after any junk.
///
/// Single-threaded (the radio I/O thread); `reset()` on socket swaps.
nonisolated final class EP6Assembler {
    /// Decoded output for one fed datagram (zero, one, or many USB frames may
    /// complete). `receivers` layout matches `HPSDRFrame.EP6Result`.
    struct Output {
        var sequence: UInt32
        /// True when the Metis sequence number skipped — bytes were lost, so the
        /// pending partial frame was discarded and the decoder re-locks on sync.
        var gap = false
        var status = RadioStreamStatus()
        var receivers: [[Float]]
        var samples: [Float] { receivers.first ?? [] }
    }

    private var buffer: [UInt8]
    private var fill = 0
    private var expectedSequence: UInt32?
    /// Cumulative count of sync-hunt events (stream came up shifted or lost bytes).
    private(set) var resyncs = 0

    init() {
        // Steady state holds < one frame of remainder plus one datagram's payload.
        buffer = [UInt8](repeating: 0, count: 4096)
    }

    func reset() {
        fill = 0
        expectedSequence = nil
    }

    /// Feeds one received datagram. Returns nil if it is not an EP6 data packet.
    func feed(_ data: [UInt8], length: Int, receiverCount: Int) -> Output? {
        guard length > 8, length <= data.count,
              data[0] == HPSDRProtocol1.metisMagic0,
              data[1] == HPSDRProtocol1.metisMagic1,
              data[3] == HPSDRProtocol1.endpointFromRadio else {
            return nil
        }
        let sequence = (UInt32(data[4]) << 24) | (UInt32(data[5]) << 16)
            | (UInt32(data[6]) << 8) | UInt32(data[7])

        let rxCount = max(receiverCount, 1)
        var out = Output(sequence: sequence,
                         receivers: [[Float]](repeating: [], count: rxCount))
        if let expected = expectedSequence, sequence != expected {
            // Lost datagram(s): the byte offsets shifted, so the partial frame is
            // unusable. Drop it; the sync hunt below re-locks on the next frame.
            out.gap = true
            fill = 0
        }
        expectedSequence = sequence &+ 1

        // Append the payload; an (impossible in practice) overflow drops history.
        let payloadCount = length - 8
        if fill + payloadCount > buffer.count { fill = 0 }
        buffer.withUnsafeMutableBufferPointer { dst in
            data.withUnsafeBufferPointer { src in
                (dst.baseAddress! + fill).update(from: src.baseAddress! + 8,
                                                 count: payloadCount)
            }
        }
        fill += payloadCount

        // Decode every complete USB frame, hunting for sync where needed.
        let frameSize = HPSDRProtocol1.usbFrameSize
        var pos = 0
        buffer.withUnsafeBufferPointer { buf in
            let d = buf.baseAddress!
            while fill - pos >= frameSize {
                if d[pos] == HPSDRProtocol1.sync,
                   d[pos + 1] == HPSDRProtocol1.sync,
                   d[pos + 2] == HPSDRProtocol1.sync {
                    Self.decodeUSBFrame(d + pos, rxCount: rxCount, into: &out)
                    pos += frameSize
                    continue
                }
                // Junk (or a shifted stream start): hunt for the next sync word.
                resyncs += 1
                var found = -1
                var i = pos + 1
                while i <= fill - 3 {
                    if d[i] == HPSDRProtocol1.sync, d[i + 1] == HPSDRProtocol1.sync,
                       d[i + 2] == HPSDRProtocol1.sync {
                        found = i
                        break
                    }
                    i += 1
                }
                if found < 0 {
                    // No sync in view: keep only the last 2 bytes (a possibly
                    // split sync word) and wait for more data.
                    pos = max(pos, fill - 2)
                    break
                }
                pos = found
            }
        }

        // Compact the remainder to the front.
        if pos > 0 {
            buffer.withUnsafeMutableBufferPointer { buf in
                let d = buf.baseAddress!
                memmove(d, d + pos, fill - pos)
            }
            fill -= pos
        }
        return out
    }

    /// Decodes one 512-byte USB frame (sync + C0–C4 + interleaved sample groups),
    /// identical to the fixed-offset logic in `HPSDRFrame.parseEP6`.
    private static func decodeUSBFrame(_ d: UnsafePointer<UInt8>, rxCount: Int,
                                       into out: inout Output) {
        let c0 = d[3]
        out.status.ptt = c0 & 0x01 != 0
        out.status.dash = c0 & 0x02 != 0
        out.status.dot = c0 & 0x04 != 0
        let statusBlock = (c0 >> 3) & 0x1F
        if statusBlock == 0 {
            out.status.adcOverflow = d[4] & 0x01 != 0
            out.status.versionC2 = d[5]
            out.status.versionC3 = d[6]
            out.status.versionC4 = d[7]
        }

        let bytesPerGroup = 6 * rxCount + 2
        let sampleAreaSize = HPSDRProtocol1.usbFrameSize - HPSDRProtocol1.usbHeaderSize
        let groupCount = sampleAreaSize / bytesPerGroup
        let scale: Float = 1.0 / 8_388_608.0 // 2^23
        for rx in 0..<rxCount { out.receivers[rx].reserveCapacity(groupCount * 2) }
        for group in 0..<groupCount {
            let groupBase = HPSDRProtocol1.usbHeaderSize + group * bytesPerGroup
            for rx in 0..<rxCount {
                let p = groupBase + rx * 6
                let i = HPSDRProtocol1.sample24(d[p], d[p + 1], d[p + 2])
                let q = HPSDRProtocol1.sample24(d[p + 3], d[p + 4], d[p + 5])
                out.receivers[rx].append(Float(i) * scale)
                out.receivers[rx].append(Float(q) * scale)
            }
        }
    }
}
