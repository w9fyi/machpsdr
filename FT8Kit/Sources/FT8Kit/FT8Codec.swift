import CFT8
import Foundation

public enum FT8CodecError: Error, Equatable {
    /// The message text could not be packed into a 77-bit payload.
    case invalidMessage(code: Int)
    case synthesisFailed
}

/// Message encoding and GFSK waveform synthesis for FT8/FT4.
///
/// The underlying C library keeps a global callsign hash table (used to
/// round-trip nonstandard calls like <PJ4/K1ABC>), so all CFT8 calls are
/// serialized through `FT8Codec.lock`.
public enum FT8Codec {
    static let lock = NSLock()

    /// Pack a message text ("CQ W9FYI EN52", "K1ABC W9FYI -07", ...) and
    /// return the on-air tone sequence (0...7 for FT8, 0...3 for FT4).
    public static func tones(for text: String, mode: FTxProtocolMode) throws -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }

        var msg = ftx_message_t()
        let rc = text.withCString { ftx_message_encode(&msg, cft8_hash_interface(), $0) }
        guard rc == FTX_MESSAGE_RC_OK else {
            throw FT8CodecError.invalidMessage(code: Int(rc.rawValue))
        }

        var tones = [UInt8](repeating: 0, count: mode.toneCount)
        withUnsafeBytes(of: msg.payload) { payload in
            let p = payload.bindMemory(to: UInt8.self).baseAddress!
            switch mode {
            case .ft8: ft8_encode(p, &tones)
            case .ft4: ft4_encode(p, &tones)
            }
        }
        return tones
    }

    /// Synthesize the GFSK-shaped audio waveform for a tone sequence.
    /// - Parameters:
    ///   - audioFrequency: audio offset of tone 0 in Hz (e.g. 1500)
    ///   - sampleRate: output sample rate in Hz
    ///   - amplitude: linear peak amplitude (0...1)
    /// - Returns: `toneCount * round(sampleRate * symbolPeriod)` samples.
    public static func synthesize(tones: [UInt8], mode: FTxProtocolMode,
                                  audioFrequency: Double, sampleRate: Int,
                                  amplitude: Float = 0.9) throws -> [Float] {
        let samplesPerSymbol = Int((Double(sampleRate) * mode.symbolPeriod).rounded())
        var signal = [Float](repeating: 0, count: tones.count * samplesPerSymbol)
        let status = signal.withUnsafeMutableBufferPointer { buf in
            tones.withUnsafeBufferPointer { t in
                synth_gfsk(t.baseAddress!, Int32(tones.count), Float(audioFrequency),
                           mode.symbolBT, Float(mode.symbolPeriod), Int32(sampleRate),
                           buf.baseAddress!)
            }
        }
        guard status == 0 else { throw FT8CodecError.synthesisFailed }
        if amplitude != 1.0 {
            for i in signal.indices { signal[i] *= amplitude }
        }
        return signal
    }

    /// Convenience: pack + synthesize in one step.
    public static func waveform(for text: String, mode: FTxProtocolMode,
                                audioFrequency: Double, sampleRate: Int,
                                amplitude: Float = 0.9) throws -> [Float] {
        let t = try tones(for: text, mode: mode)
        return try synthesize(tones: t, mode: mode, audioFrequency: audioFrequency,
                              sampleRate: sampleRate, amplitude: amplitude)
    }

    /// True if `text` can be packed into a valid FT8/FT4 payload.
    public static func canEncode(_ text: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var msg = ftx_message_t()
        return text.withCString { ftx_message_encode(&msg, nil, $0) } == FTX_MESSAGE_RC_OK
    }
}
