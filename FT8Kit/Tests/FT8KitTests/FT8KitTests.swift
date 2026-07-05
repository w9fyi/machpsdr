import XCTest
@testable import FT8Kit

final class FT8KitTests: XCTestCase {

    // MARK: - Encoding

    func testStandardCQProducesCorrectToneCount() throws {
        let tones = try FT8Codec.tones(for: "CQ W9FYI EN52", mode: .ft8)
        XCTAssertEqual(tones.count, 79)
        XCTAssertTrue(tones.allSatisfy { $0 < 8 })
    }

    func testFT4ToneCount() throws {
        let tones = try FT8Codec.tones(for: "CQ W9FYI EN52", mode: .ft4)
        XCTAssertEqual(tones.count, 105)
        XCTAssertTrue(tones.allSatisfy { $0 < 4 })
    }

    func testInvalidMessageThrows() {
        XCTAssertThrowsError(try FT8Codec.tones(for: "THIS IS MUCH TOO LONG TO BE A VALID FT8 MESSAGE", mode: .ft8))
    }

    func testCanEncodeStandardMessages() {
        XCTAssertTrue(FT8Codec.canEncode("CQ W9FYI EN52"))
        XCTAssertTrue(FT8Codec.canEncode("K1ABC W9FYI -07"))
        XCTAssertTrue(FT8Codec.canEncode("K1ABC W9FYI R-15"))
        XCTAssertTrue(FT8Codec.canEncode("K1ABC W9FYI RR73"))
        XCTAssertTrue(FT8Codec.canEncode("CQ DX W9FYI EN52"))
    }

    // MARK: - Synthesis

    func testWaveformLengthAndAmplitude() throws {
        let signal = try FT8Codec.waveform(for: "CQ W9FYI EN52", mode: .ft8,
                                           audioFrequency: 1500, sampleRate: 12_000)
        XCTAssertEqual(signal.count, 79 * 1920) // 12.64 s at 12 kHz
        let peak = signal.map { abs($0) }.max() ?? 0
        XCTAssertLessThanOrEqual(peak, 0.91)
        XCTAssertGreaterThan(peak, 0.85)
    }

    // MARK: - Round trip: synthesize → monitor → decode

    private func slotAudio(messages: [(text: String, freq: Double, amp: Float)],
                           mode: FTxProtocolMode, sampleRate: Int = 12_000,
                           startOffset: Double = 0.5) throws -> [Float] {
        var slot = [Float](repeating: 0, count: Int(mode.slotSeconds * Double(sampleRate)))
        let start = Int(startOffset * Double(sampleRate))
        for m in messages {
            let wave = try FT8Codec.waveform(for: m.text, mode: mode,
                                             audioFrequency: m.freq,
                                             sampleRate: sampleRate, amplitude: m.amp)
            for i in 0..<wave.count where start + i < slot.count {
                slot[start + i] += wave[i]
            }
        }
        return slot
    }

    func testFT8RoundTripSingleMessage() throws {
        let audio = try slotAudio(messages: [("CQ W9FYI EN52", 1500, 0.5)], mode: .ft8)
        let monitor = FT8Monitor(mode: .ft8)
        monitor.feed(audio)
        let decodes = monitor.decode()
        XCTAssertEqual(decodes.count, 1)
        let d = try XCTUnwrap(decodes.first)
        XCTAssertEqual(d.text, "CQ W9FYI EN52")
        XCTAssertEqual(d.audioFrequency, 1500, accuracy: 4)
        XCTAssertEqual(d.timeOffset, 0.5, accuracy: 0.2)
    }

    func testFT8RoundTripMultipleSignals() throws {
        let audio = try slotAudio(messages: [
            ("CQ W9FYI EN52", 800, 0.4),
            ("K1ABC W9FYI -07", 1650, 0.3),
            ("W9FYI K1ABC RR73", 2400, 0.35),
        ], mode: .ft8)
        let monitor = FT8Monitor(mode: .ft8)
        monitor.feed(audio)
        let texts = Set(monitor.decode().map(\.text))
        XCTAssertTrue(texts.contains("CQ W9FYI EN52"))
        XCTAssertTrue(texts.contains("K1ABC W9FYI -07"))
        XCTAssertTrue(texts.contains("W9FYI K1ABC RR73"))
    }

    func testFT4RoundTrip() throws {
        let audio = try slotAudio(messages: [("CQ W9FYI EN52", 1200, 0.5)], mode: .ft4)
        let monitor = FT8Monitor(mode: .ft4)
        monitor.feed(audio)
        let decodes = monitor.decode()
        XCTAssertEqual(decodes.first?.text, "CQ W9FYI EN52")
    }

    func testChunkedFeedMatchesWholeSlot() throws {
        // Feeding in arbitrary-size chunks (as the radio will) must decode too.
        let audio = try slotAudio(messages: [("K1ABC W9FYI R-15", 1000, 0.4)], mode: .ft8)
        let monitor = FT8Monitor(mode: .ft8)
        var i = 0
        var chunk = 313 // deliberately not a divisor of the block size
        while i < audio.count {
            let n = min(chunk, audio.count - i)
            monitor.feed(Array(audio[i..<i+n]))
            i += n
            chunk = (chunk * 7) % 1024 + 64
        }
        XCTAssertEqual(monitor.decode().first?.text, "K1ABC W9FYI R-15")
    }

    func testResetAllowsNewSlot() throws {
        let monitor = FT8Monitor(mode: .ft8)
        monitor.feed(try slotAudio(messages: [("CQ W9FYI EN52", 1500, 0.5)], mode: .ft8))
        XCTAssertFalse(monitor.decode().isEmpty)
        monitor.reset()
        XCTAssertEqual(monitor.samplesFed, 0)
        monitor.feed(try slotAudio(messages: [("CQ K1ABC FN42", 900, 0.5)], mode: .ft8))
        XCTAssertEqual(monitor.decode().first?.text, "CQ K1ABC FN42")
    }

    func testNoiseOnlyProducesNoDecodes() {
        var rng = SystemRandomNumberGenerator()
        let noise = (0..<180_000).map { _ in Float.random(in: -0.1...0.1, using: &rng) }
        let monitor = FT8Monitor(mode: .ft8)
        monitor.feed(noise)
        XCTAssertTrue(monitor.decode().isEmpty)
    }
}
