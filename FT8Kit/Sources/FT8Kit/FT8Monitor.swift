import CFT8
import Foundation

/// One decoded FT8/FT4 message from a receive slot.
public struct FT8Decode: Sendable, Equatable {
    /// Decoded message text, e.g. "CQ W9FYI EN52".
    public let text: String
    /// Approximate signal-to-noise ratio in dB (WSJT-X style, rough estimate).
    public let snr: Int
    /// Signal start time relative to the slot start, seconds.
    public let timeOffset: Double
    /// Audio frequency offset of the signal in Hz.
    public let audioFrequency: Double
    /// Costas sync score (higher = stronger sync).
    public let score: Int

    public init(text: String, snr: Int, timeOffset: Double, audioFrequency: Double, score: Int) {
        self.text = text
        self.snr = snr
        self.timeOffset = timeOffset
        self.audioFrequency = audioFrequency
        self.score = score
    }
}

/// Streaming FT8/FT4 receiver: feed it mono audio at `sampleRate` for one
/// slot, then call `decode()`. Not thread-safe; confine each instance to a
/// single thread (the shared C callsign hash table is protected internally).
public final class FT8Monitor {
    public let mode: FTxProtocolMode
    public let sampleRate: Int

    private var mon = monitor_t()
    private var pending: [Float] = []
    private var pendingStart = 0
    private(set) public var samplesFed = 0

    /// Samples per FSK symbol at this sample rate.
    public var blockSize: Int { Int(mon.block_size) }
    /// True once a full slot of audio has been analyzed.
    public var isFull: Bool { mon.wf.num_blocks >= mon.wf.max_blocks }

    public init(mode: FTxProtocolMode, sampleRate: Int = 12_000,
                minFrequency: Float = 100, maxFrequency: Float = 3_100) {
        self.mode = mode
        self.sampleRate = sampleRate
        var cfg = monitor_config_t(
            f_min: minFrequency,
            f_max: maxFrequency,
            sample_rate: Int32(sampleRate),
            time_osr: 2,
            freq_osr: 2,
            protocol: mode.cProtocol
        )
        monitor_init(&mon, &cfg)
        pending.reserveCapacity(4 * blockSize)
    }

    deinit {
        monitor_free(&mon)
    }

    /// Feed a chunk of mono audio samples; complete symbol blocks are
    /// analyzed immediately, the remainder is buffered.
    public func feed(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { feed($0) }
    }

    public func feed(_ samples: UnsafeBufferPointer<Float>) {
        guard !isFull, samples.count > 0 else { return }
        pending.append(contentsOf: samples)
        samplesFed += samples.count
        let block = blockSize
        while pending.count - pendingStart >= block, !isFull {
            pending.withUnsafeBufferPointer { buf in
                monitor_process(&mon, buf.baseAddress! + pendingStart)
            }
            pendingStart += block
        }
        if pendingStart > 0 {
            pending.removeFirst(pendingStart)
            pendingStart = 0
        }
    }

    /// Decode everything heard so far in this slot. Typically called once,
    /// at (or just before) the end of the slot.
    public func decode(maxCandidates: Int = 140, minScore: Int = 10,
                       ldpcIterations: Int = 25) -> [FT8Decode] {
        var candidates = [ftx_candidate_t](repeating: ftx_candidate_t(), count: maxCandidates)
        let numCandidates = Int(ftx_find_candidates(&mon.wf, Int32(maxCandidates),
                                                    &candidates, Int32(minScore)))
        var results: [FT8Decode] = []
        var seenPayloads = Set<Data>()

        FT8Codec.lock.lock()
        defer { FT8Codec.lock.unlock() }

        for idx in 0..<numCandidates {
            let cand = candidates[idx]
            var message = ftx_message_t()
            var status = ftx_decode_status_t()
            let ok = withUnsafePointer(to: cand) { candPtr in
                ftx_decode_candidate(&mon.wf, candPtr, Int32(ldpcIterations), &message, &status)
            }
            guard ok else { continue }

            let payload = withUnsafeBytes(of: message.payload) { Data($0) }
            guard seenPayloads.insert(payload).inserted else { continue }

            var text = [CChar](repeating: 0, count: Int(FTX_MAX_MESSAGE_LENGTH))
            var offsets = ftx_message_offsets_t()
            let rc = ftx_message_decode(&message, cft8_hash_interface(), &text, &offsets)
            guard rc == FTX_MESSAGE_RC_OK else { continue }

            let freqHz = Double(mon.min_bin + Int32(cand.freq_offset)) + Double(cand.freq_sub) / Double(mon.wf.freq_osr)
            let timeSec = (Double(cand.time_offset) + Double(cand.time_sub) / Double(mon.wf.time_osr)) * Double(mon.symbol_period)

            results.append(FT8Decode(
                text: String(cString: text),
                // Rough SNR estimate from the sync score (upstream marks
                // proper SNR estimation as TODO); calibrated so typical
                // just-decodable signals report around -20 dB.
                snr: Int((Double(cand.score) * 0.5 - 24).rounded()),
                timeOffset: timeSec,
                audioFrequency: freqHz / Double(mon.symbol_period),
                score: Int(cand.score)
            ))
        }

        cft8_hashtable_cleanup(10)
        return results
    }

    /// Clear analysis state to start a new slot.
    public func reset() {
        monitor_reset(&mon)
        pending.removeAll(keepingCapacity: true)
        pendingStart = 0
        samplesFed = 0
    }
}
