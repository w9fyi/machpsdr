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

    /// Number of distinct command "slots" cycled through round-robin:
    /// slot 0 = configuration, slot 1 = TX frequency, slot 2 = drive/mic,
    /// slots 3… = each RX frequency.
    var commandSlotCount: Int { 3 + receiverCount }

    /// Produces the five command bytes (C0–C4) for a given round-robin slot.
    func commandBytes(slot: Int) -> (UInt8, UInt8, UInt8, UInt8, UInt8) {
        let moxBit: UInt8 = mox ? 0x01 : 0x00
        switch slot {
        case 0:
            // Configuration: C0 = 0x00, C1 = sample-rate bits, C4 bits 3–5 = (receivers − 1).
            // C2 bits 1–7 = the 7 open-collector outputs (amp band data, etc.).
            let c4 = UInt8((max(receiverCount, 1) - 1) << 3)
            let c2 = (openCollector & 0x7F) << 1
            return (0x00 | moxBit, sampleRate.rawValue, c2, 0x00, c4)
        case 1:
            // TX NCO frequency: C0 = 0x02, C1–C4 = 32-bit Hz big-endian.
            return Self.frequencyCommand(c0: 0x02 | moxBit, hz: transmitFrequency)
        case 2:
            // Drive level / mic: C0 = 0x12, C1 = TX drive (0–255).
            return (0x12 | moxBit, drive, 0x00, 0x00, 0x00)
        default:
            // RX NCO frequency: C0 = 0x04 + receiverIndex*2.
            let rx = slot - 3
            let c0 = UInt8(0x04 + rx * 2) | moxBit
            let hz = rx < receiverFrequencies.count ? receiverFrequencies[rx] : (receiverFrequencies.first ?? 0)
            return Self.frequencyCommand(c0: c0, hz: hz)
        }
    }

    private static func frequencyCommand(c0: UInt8, hz: UInt32) -> (UInt8, UInt8, UInt8, UInt8, UInt8) {
        (c0,
         UInt8((hz >> 24) & 0xFF),
         UInt8((hz >> 16) & 0xFF),
         UInt8((hz >> 8) & 0xFF),
         UInt8(hz & 0xFF))
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
                         txIQ: [Float]? = nil) -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: HPSDRProtocol1.frameSize)
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
        writeUSBFrame(into: &frame, at: 520, command: settings.commandBytes(slot: slot2),
                      txIQ: txIQ, sampleStart: 63)
        return frame
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

    /// The result of parsing one EP6 packet: the latest status and the decoded RX0 I/Q samples.
    struct EP6Result {
        var sequence: UInt32
        var status: RadioStreamStatus
        /// Interleaved I/Q for receiver 0 (i0, q0, i1, q1, …) as normalized Floats in [-1, 1).
        var samples: [Float]
    }

    /// Parses a received EP6 packet. Returns nil if the header/sync is invalid.
    /// Currently decodes receiver 0 only (sufficient for single-RX bring-up).
    static func parseEP6(_ data: [UInt8], receiverCount: Int) -> EP6Result? {
        guard data.count >= HPSDRProtocol1.frameSize,
              data[0] == HPSDRProtocol1.metisMagic0,
              data[1] == HPSDRProtocol1.metisMagic1,
              data[3] == HPSDRProtocol1.endpointFromRadio else {
            return nil
        }
        let sequence = (UInt32(data[4]) << 24) | (UInt32(data[5]) << 16)
            | (UInt32(data[6]) << 8) | UInt32(data[7])

        var status = RadioStreamStatus()
        var samples: [Float] = []
        // Each I/Q sample group: 3 bytes I + 3 bytes Q per receiver, then 2 bytes mic.
        let bytesPerGroup = 6 * receiverCount + 2
        let scale: Float = 1.0 / 8_388_608.0 // 2^23

        for usbOffset in [8, 520] {
            guard data[usbOffset] == HPSDRProtocol1.sync,
                  data[usbOffset + 1] == HPSDRProtocol1.sync,
                  data[usbOffset + 2] == HPSDRProtocol1.sync else {
                continue
            }
            let c0 = data[usbOffset + 3]
            status.ptt = c0 & 0x01 != 0
            status.dash = c0 & 0x02 != 0
            status.dot = c0 & 0x04 != 0
            let statusBlock = (c0 >> 3) & 0x1F
            if statusBlock == 0 {
                status.adcOverflow = data[usbOffset + 4] & 0x01 != 0
                status.versionC2 = data[usbOffset + 5]
                status.versionC3 = data[usbOffset + 6]
                status.versionC4 = data[usbOffset + 7]
            }

            // Decode RX0 I/Q from the sample area.
            let sampleBase = usbOffset + HPSDRProtocol1.usbHeaderSize
            let sampleAreaSize = HPSDRProtocol1.usbFrameSize - HPSDRProtocol1.usbHeaderSize
            let groupCount = sampleAreaSize / bytesPerGroup
            for group in 0..<groupCount {
                let p = sampleBase + group * bytesPerGroup
                let i = HPSDRProtocol1.sample24(data[p], data[p + 1], data[p + 2])
                let q = HPSDRProtocol1.sample24(data[p + 3], data[p + 4], data[p + 5])
                // Raw I/Q (no conjugation here) so the panadapter shows the correct
                // orientation. WDSP gets a conjugated copy in WDSPRadio.
                samples.append(Float(i) * scale)
                samples.append(Float(q) * scale)
            }
        }
        return EP6Result(sequence: sequence, status: status, samples: samples)
    }
}
