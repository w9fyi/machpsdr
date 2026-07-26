import Testing
import Foundation
import CWDSP
import FT8Kit

/// WDSP channel lifecycle inside the sandboxed test host.
///
/// These run in the app process, so the App Sandbox applies — the environment
/// that exposed the launch crash after the WDSP 2.00 upgrade: named POSIX
/// semaphores (sem_open) fail under the sandbox, WDSP 2.00's persistent
/// flushChannel worker then never blocks, and it flushes the channel while
/// create_rxa is still populating it (SIGSEGV in flush_bpsnba).
/// The linux_port shim now uses in-process pthread semaphores.
@Suite(.serialized) struct WDSPChannelTests {

    /// Open → run → exchange audio → stop → close, twice, on an RXA channel.
    /// Pre-fix this crashed inside OpenChannel under the sandbox.
    @Test func rxaChannelLifecycle() {
        let channel: Int32 = 30    // clear of app channels (slices 2+, TX 1)
        let size = 1024
        for _ in 0..<2 {
            OpenChannel(channel, Int32(size), Int32(size * 2),
                        48_000, 48_000, 48_000, 0, 0,
                        0.010, 0.025, 0.000, 0.010, 0)
            SetRXAMode(channel, 1)                    // USB
            SetRXABandpassFreqs(channel, 150, 2850)
            #expect(SetChannelState(channel, 1, 0) == 0)

            var input = [Double](repeating: 0, count: size * 2)
            var output = [Double](repeating: 0, count: size * 2)
            var error: Int32 = 0
            for i in 0..<input.count { input[i] = 1e-3 * Double(i % 97) }
            // Pace exchanges like the radio does (1024 samples @ 48 kHz ≈ 21 ms)
            // so the channel's DSP worker thread can keep up; a tight loop
            // legitimately starves the output side (-2). The final exchange
            // being clean proves the worker is processing — i.e., the shim's
            // semaphores actually signal.
            for _ in 0..<8 {
                error = 0
                fexchange0(channel, &input, &output, &error)
                Thread.sleep(forTimeInterval: 0.021)
            }
            #expect(error == 0, "fexchange0 still starved after priming: \(error)")

            _ = SetChannelState(channel, 0, 1)
            CloseChannel(channel)
        }
    }

    /// End-to-end FT8 receive through WDSP: a synthesized FT8 signal fed to an
    /// RXA channel configured exactly like the app's DIGU slice (mode, passband,
    /// AGC, panel gain) must come out decodable. Guards the whole
    /// fexchange0 → left-lane → 12 kHz decimation → ft8_lib chain against
    /// regressions from WDSP upstream syncs.
    @Test func ft8DecodesThroughRXAChannel() throws {
        let channel: Int32 = 32
        let size = 1024
        OpenChannel(channel, Int32(size), Int32(size * 2),
                    48_000, 48_000, 48_000, 0, 0,
                    0.010, 0.025, 0.000, 0.010, 0)
        SetRXAAGCMode(channel, 3)
        SetRXAAGCTop(channel, 90)
        SetRXAPanelGain1(channel, 1.0)   // app pins this; volume is applied post-tap
        SetRXAMode(channel, 7)                     // DIGU, as FT8Controller tunes
        RXASetPassband(channel, 100, 3_100)
        #expect(SetChannelState(channel, 1, 0) == 0)
        defer {
            _ = SetChannelState(channel, 0, 1)
            CloseChannel(channel)
        }

        // 0.5 s lead-in silence + the ~12.6 s transmission + slot tail.
        var audio = [Float](repeating: 0, count: 24_000)
        audio += try FT8Codec.waveform(for: "CQ W9FYI EN52", mode: .ft8,
                                       audioFrequency: 1_500,
                                       sampleRate: 48_000, amplitude: 0.5)
        audio += [Float](repeating: 0, count: 48_000)

        // Feed as I with Q = 0 (a real signal): the DIGU passband keeps only
        // the positive-frequency half, i.e. the original audio.
        let monitor = FT8Monitor(mode: .ft8)
        var input = [Double](repeating: 0, count: size * 2)
        var output = [Double](repeating: 0, count: size * 2)
        var error: Int32 = 0
        var mono12 = [Float]()
        mono12.reserveCapacity(size / 4)
        var decSum: Float = 0
        var decFill = 0
        var sumSquares = 0.0

        var offset = 0
        while offset + size <= audio.count, !monitor.isFull {
            for i in 0..<size {
                input[i * 2] = Double(audio[offset + i])
                input[i * 2 + 1] = 0
            }
            error = 0
            fexchange0(channel, &input, &output, &error)
            // Pace like the radio (1024 @ 48 kHz ≈ 21 ms) so the channel's DSP
            // worker keeps up; see rxaChannelLifecycle.
            Thread.sleep(forTimeInterval: 0.015)

            mono12.removeAll(keepingCapacity: true)
            for i in 0..<size {
                let sample = Float(output[i * 2])   // left lane, like WDSPRadio
                sumSquares += Double(sample * sample)
                decSum += sample
                decFill += 1
                if decFill == 4 {
                    mono12.append(decSum * 0.25)
                    decSum = 0
                    decFill = 0
                }
            }
            monitor.feed(mono12)
            offset += size
        }
        #expect(error == 0, "fexchange0 error on final block: \(error)")

        let rms = (sumSquares / Double(offset)).squareRoot()
        let decodes = monitor.decode()
        #expect(decodes.contains { $0.text == "CQ W9FYI EN52" },
                "no decode (output RMS \(rms), \(decodes.count) decodes: \(decodes.map(\.text)))")
    }

    /// Sample-rate change uses 2.00's flushflag handshake with the
    /// flushChannel worker; a dead semaphore would hang or crash here.
    @Test func dspSampleRateChangeHandshake() {
        let channel: Int32 = 31
        let size = 1024
        OpenChannel(channel, Int32(size), Int32(size * 2),
                    48_000, 48_000, 48_000, 0, 0,
                    0.010, 0.025, 0.000, 0.010, 0)
        SetRXAMode(channel, 1)
        _ = SetChannelState(channel, 1, 0)
        SetDSPSamplerate(channel, 96_000)
        SetDSPSamplerate(channel, 48_000)
        _ = SetChannelState(channel, 0, 1)
        CloseChannel(channel)
    }
}
