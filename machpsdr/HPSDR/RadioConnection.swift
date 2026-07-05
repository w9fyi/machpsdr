import Foundation
import Accelerate
import Darwin

/// Gates the 1 Hz `MIX:`/`DSP:` stream-diagnostics logs (rate/gap/sync counters).
/// Off by default; enable for live stream debugging with the launch argument
/// `-dspDiagnostics YES` or `defaults write <bundle-id> dspDiagnostics -bool YES`.
/// Rare event and error logs (slice open/close, socket rebuild, slow commands)
/// are always on.
nonisolated enum DSPDiagnostics {
    static let enabled = UserDefaults.standard.bool(forKey: "dspDiagnostics")
}

/// A throttled snapshot of the live stream, delivered to UI/consumers ~10×/second.
nonisolated struct StreamUpdate: Sendable {
    var status: RadioStreamStatus
    var packetsPerSecond: Int
    var sequenceGaps: Int
    /// RMS magnitude of the RX0 I/Q over the interval, in [0, 1].
    var signalRMS: Float
}

/// Thread-safe holder for the mutable radio settings shared between the actor
/// (which mutates them on tuning) and the background I/O thread (which reads them).
private nonisolated final class SettingsBox: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var value: RadioSettings
    init(_ value: RadioSettings) { self.value = value }
    var current: RadioSettings {
        get { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return value }
        set { os_unfair_lock_lock(&lock); value = newValue; os_unfair_lock_unlock(&lock) }
    }
}

/// Thread-safe holder for the live socket file descriptor plus the EP2 sequence
/// number the run loop should continue from (the socket bring-up sends priming EP2
/// frames, so the loop must not restart the sequence — the radio would see it go
/// backward). The I/O thread reads it every iteration so the socket can be swapped
/// out from under the run loop (the mid-stream socket rebuild on slice-count change).
private nonisolated final class SocketBox: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var fd: Int32 = -1
    private var seq: UInt32 = 0
    var current: Int32 {
        get { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return fd }
        set { os_unfair_lock_lock(&lock); fd = newValue; os_unfair_lock_unlock(&lock) }
    }
    /// Atomically installs a new socket and the EP2 sequence to continue from.
    func swap(fd newFD: Int32, nextSeq: UInt32) {
        os_unfair_lock_lock(&lock)
        fd = newFD
        seq = nextSeq
        os_unfair_lock_unlock(&lock)
    }
    var snapshot: (fd: Int32, nextSeq: UInt32) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return (fd, seq)
    }
}

/// Owns the live openHPSDR Protocol 1 connection to one radio: opens the socket,
/// sends the Metis start/stop, and runs the combined send-EP2 / receive-EP6 loop on a
/// background thread. Decoded status is delivered via the `updates` AsyncStream.
actor RadioConnection {
    let radio: DiscoveredRadio

    /// Live socket fd, backed by a thread-safe box so the run loop reads it each
    /// iteration and the DSP thread can swap the socket during a mid-stream rebuild.
    private let socketBox = SocketBox()
    private var fd: Int32 {
        get { socketBox.current }
        set { socketBox.current = newValue }
    }
    private let settingsBox: SettingsBox
    private var worker: Thread?
    private let running = RunningFlag()

    // WDSP is NOT thread-safe on macOS (its semaphores/critical sections don't work),
    // so every WDSP call (open/close a channel, mode/filter/AGC/NR changes) must run on
    // the single DSP thread. The actor enqueues these here; the run loop drains and
    // executes them between exchanges. Calling WDSP from the actor concurrently with the
    // DSP thread's fexchange0 wedges the whole loop (killed all audio on slice add/remove).
    private let dspCommands = DSPCommandQueue()

    /// Maximum number of receive slices the app supports. The radio streams fewer:
    /// the ANAN-10E gateware supports up to 4 DDCs and the Protocol-1 receiver-count
    /// field maxes at 8, so the on-air count is clamped in `setActiveSliceCount`.
    static let maxSlices = 10

    // Experiments from the add-slice investigation, OFF until verified live — with
    // both off, the bring-up and EP2 cadence match the last-known-good behavior
    // (plain STOP→drain→START on a fresh socket, one EP2 per run-loop iteration).
    //
    /// Prime config while stopped + double-start before the final START. Risk: it
    /// reprograms the layout on a RUNNING stream and then relies on a same-socket
    /// STOP/START to realign — previously observed NOT to realign on this gateware,
    /// which leaves the radio's actual rate/layout disagreeing with `settings` and
    /// produces exactly the "garbled, whole-spectrum" audio (wrong decimation factor).
    private static let experimentalPrimedBringUp = false

    /// The radio consumes EP2 at its fixed 48 kHz TX/C&C clock: 48000/126 samples ≈
    /// 381 frames/s, one frame every 2.625 ms — independent of the RX stream rate.
    private static let ep2PeriodNs: UInt64 = 126 * 1_000_000_000 / 48_000

    /// Silence cushion (samples @ 48 kHz) primed into a slice's audio ring at start
    /// and whenever it is reset (retune, mode change, slice add). 100 ms of latency
    /// buys immunity to producer/consumer scheduling jitter — see
    /// `AudioRingBuffer.reset(primingSilence:)` for why an empty ring stays choppy.
    private static let audioPrimeSamples = 4_800

    // Receive path: one DSP + spectrum chain per slice. Engines and spectra are
    // pre-allocated for maxSlices; only the first `activeSliceCount` are opened,
    // decoded, and mixed. `SliceAudioMixer` sums each slice's audio (with pan) into
    // one output device on the CoreAudio render thread.
    private let engines: [SliceEngine]
    private var mixer: SliceAudioMixer?
    private var activeSliceCount: Int
    /// Output device UID for received audio (nil = system default).
    private var audioOutputUID: String?
    private var currentMode: RadioMode = .usb

    // Transmit path: WDSP TXA turns mic/tone into TX I/Q that the send loop packs
    // into EP2 frames (with MOX + drive) while `transmit.transmitting` is true.
    private let wdspTx = WDSPTransmit()
    private let transmit = TransmitBox()
    private let micRing = AudioRingBuffer()
    // Digital-mode (FT8/FT4) TX audio: the whole transmission is pre-rendered and
    // loaded at key-down, so the ring must hold a full FT8 waveform (12.64 s @ 48 kHz).
    private let digitalTXRing = AudioRingBuffer(capacity: 768_000)
    private var audioInput: AudioInput?
    /// Input device UID for mic capture (nil = system default). Applied on key-down.
    private var micDeviceUID: String?

    /// Cumulative decoded-sample counter for NTP frequency calibration. `let` +
    /// Sendable so the session reads it synchronously off-actor.
    let sampleClock = SampleClockCounter()

    /// Per-slice power spectra for the panadapters. `let` + Sendable so the UI reads
    /// them synchronously off-actor. Index by slice number.
    let spectra: [SpectrumBuffer]
    /// Back-compat accessor for the primary (slice 0) spectrum.
    nonisolated var spectrum: SpectrumBuffer { spectra[0] }

    private var updateContinuation: AsyncStream<StreamUpdate>.Continuation?
    /// Throttled stream of decoded status/metrics. Consume this to drive the UI.
    let updates: AsyncStream<StreamUpdate>

    init(radio: DiscoveredRadio, settings: RadioSettings = RadioSettings()) {
        self.radio = radio
        self.settingsBox = SettingsBox(settings)
        var spectra: [SpectrumBuffer] = []
        var engines: [SliceEngine] = []
        for i in 0..<Self.maxSlices {
            let buffer = SpectrumBuffer()
            spectra.append(buffer)
            engines.append(SliceEngine(index: i, spectrum: buffer))
        }
        self.spectra = spectra
        self.engines = engines
        self.activeSliceCount = max(1, min(Self.maxSlices, settings.receiverCount))
        var continuation: AsyncStream<StreamUpdate>.Continuation!
        // Only the latest snapshot matters; never let updates queue up behind a
        // stalled consumer.
        self.updates = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
        self.updateContinuation = continuation
    }

    /// Current settings (frequency, sample rate, …).
    var settings: RadioSettings { settingsBox.current }

    /// Brings up a fresh UDP socket to the radio from a known-clean state: connect,
    /// STOP, drain any in-flight/stale datagrams, program the full configuration via
    /// EP2 frames *while stopped*, then START so the stream begins already laid out
    /// for `settings` with the USB sync word aligned at offset 8.
    ///
    /// Priming before START is essential (piHPSDR/Thetis do the same): changing the
    /// receiver count/rate on a *running* stream shifts the sample layout mid-frame
    /// and the sync word drifts off offset 8 permanently (observed live: sync at
    /// 110/622, zero decode, until the next aligned restart). Returns the connected
    /// Returns the connected fd and the EP2 sequence number the send loop should
    /// continue from (the priming frames consumed 0..<nextSeq), or nil on
    /// socket/connect failure. Shared by the initial connect and the mid-stream
    /// rebuild on slice-count change.
    private static func openStreamSocket(ip: String,
                                         settings: RadioSettings) -> (fd: Int32, nextSeq: UInt32)? {
        let socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFD >= 0 else { return nil }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = HPSDRProtocol1.dataPort.bigEndian
        inet_pton(AF_INET, ip, &addr.sin_addr)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { close(socketFD); return nil }

        // A deep kernel receive buffer (~2.5 s of EP6 at 48 kHz, ~0.6 s at 192 kHz)
        // rides out I/O-thread stalls — e.g. a burst of queued WDSP commands from a
        // slider drag — as latency instead of dropped packets and audio gaps.
        var rcvBufBytes: Int32 = 1_048_576
        setsockopt(socketFD, SOL_SOCKET, SO_RCVBUF, &rcvBufBytes, socklen_t(MemoryLayout<Int32>.size))

        var drainTimeout = timeval(tv_sec: 0, tv_usec: 50_000)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &drainTimeout, socklen_t(MemoryLayout<timeval>.size))
        let stopPacket = HPSDRProtocol1.stopCommand()
        let startPacket = HPSDRProtocol1.startCommand(iq: true)
        var drain = [UInt8](repeating: 0, count: 2048)
        func sendStop() { _ = stopPacket.withUnsafeBytes { send(socketFD, $0.baseAddress, $0.count, 0) } }
        func sendStart() { _ = startPacket.withUnsafeBytes { send(socketFD, $0.baseAddress, $0.count, 0) } }
        func drainUntilQuiet() {
            let deadline = Date().addingTimeInterval(0.4)
            while Date() < deadline {
                let n = drain.withUnsafeMutableBytes { recv(socketFD, $0.baseAddress, $0.count, 0) }
                if n <= 0 { break }   // socket empty (recv timed out) → pipe is clear
            }
        }

        // From a known-clean state: stop whatever stream is running and flush it.
        sendStop()
        usleep(100_000)   // 100 ms for the radio to halt its stream
        drainUntilQuiet()

        var primeSeq: UInt32 = 0
        if Self.experimentalPrimedBringUp {
            // Prime the FPGA while stopped, the way piHPSDR's restart does: pair the
            // config slot (receiver count + rate + duplex) with every other slot,
            // 20 ms apart (config, TX freq, drive, attenuator, all RX freqs).
            var frame = [UInt8](repeating: 0, count: HPSDRProtocol1.frameSize)
            let slots = settings.commandSlotCount
            for other in 1..<slots {
                HPSDRFrame.buildEP2(into: &frame, sequence: primeSeq, settings: settings,
                                    slot1: 0, slot2: other)
                _ = frame.withUnsafeBytes { send(socketFD, $0.baseAddress, $0.count, 0) }
                primeSeq &+= 1
                usleep(20_000)
            }

            // Double-start: this gateware honors C&C reliably only on a RUNNING stream
            // (live tuning works, but a receiver count primed while stopped never took —
            // the stream stayed at the old layout's packet rate). So START, program the
            // config on the running stream while discarding its old-layout frames, then
            // STOP and START once more so the radio latches the new receiver count/rate
            // into a cleanly aligned stream from the first frame.
            sendStart()
            for i in 0..<24 {
                _ = drain.withUnsafeMutableBytes { recv(socketFD, $0.baseAddress, $0.count, 0) }
                HPSDRFrame.buildEP2(into: &frame, sequence: primeSeq, settings: settings,
                                    slot1: 0, slot2: 1 + i % (slots - 1))
                _ = frame.withUnsafeBytes { send(socketFD, $0.baseAddress, $0.count, 0) }
                primeSeq &+= 1
                usleep(3_000)
            }
            sendStop()
            usleep(100_000)
            drainUntilQuiet()
        }

        var rcvTimeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &rcvTimeout, socklen_t(MemoryLayout<timeval>.size))

        // Final START: the stream begins in the requested layout.
        sendStart()
        return (socketFD, primeSeq)
    }

    /// Opens the socket, sends Metis start, and begins the stream loop.
    func start() throws {
        guard fd < 0, worker == nil else { return } // already started

        // `activeSliceCount` is authoritative for a fresh start (a mid-stream slice
        // change applies receiverCount inside its rebuild command, which is dropped
        // if the user disconnects first).
        var s = settingsBox.current
        s.receiverCount = activeSliceCount
        s.hermesLite = radio.board == .hermesLite
        settingsBox.current = s

        guard let stream = Self.openStreamSocket(ip: radio.ipAddress,
                                                 settings: settingsBox.current) else {
            throw DiscoveryError.socketCreationFailed(errno)
        }

        socketBox.swap(fd: stream.fd, nextSeq: stream.nextSeq)
        running.set(true)

        // Open the active slices' WDSP receiver channels and the transmitter.
        for i in 0..<activeSliceCount { engines[i].wdsp.open(mode: currentMode) }
        wdspTx.open(mode: currentMode)

        // Start the audio mixer over the active slices. If it fails, streaming still
        // proceeds (silent). Rings are primed so playback starts with a jitter
        // cushion instead of racing the first WDSP blocks.
        let mix = SliceAudioMixer(deviceUID: audioOutputUID)
        for i in 0..<activeSliceCount {
            engines[i].ring.reset(primingSilence: Self.audioPrimeSamples)
            mix.setSlice(i, ring: engines[i].ring, pan: engines[i].pan, enabled: true)
        }
        do {
            try mix.start()
        } catch {
            NSLog("RadioConnection: audio mixer failed to start (\(error)); streaming continues silently.")
        }
        self.mixer = mix

        // Launch the combined send/receive loop on a dedicated thread.
        let box = settingsBox
        let flag = running
        let continuation = updateContinuation
        let sliceEngines = engines
        let txEngine = wdspTx
        let txState = transmit
        let micBuffer = micRing
        let digitalBuffer = digitalTXRing
        dspCommands.clear()   // drop anything queued while disconnected
        let commands = dspCommands
        let socket = socketBox
        let clock = sampleClock
        // Hermes Lite 2 only: select the N2ADR filter board's LPF from the TX
        // frequency (the HL2 gateware does no filter selection of its own) and keep
        // the N2ADR IO board (if fitted) fed with the TX frequency so its firmware
        // can band-follow an amplifier over its DB9 serial.
        let hermesLite = radio.board == .hermesLite
        let thread = Thread {
            RadioConnection.runLoop(socket: socket, settings: box, running: flag,
                                    updates: continuation, engines: sliceEngines,
                                    wdspTx: txEngine, transmit: txState,
                                    micRing: micBuffer, digitalRing: digitalBuffer,
                                    commands: commands,
                                    hermesLite: hermesLite, sampleClock: clock)
        }
        thread.name = "RadioConnection.IO"
        thread.stackSize = 512 * 1024
        self.worker = thread
        thread.start()
    }

    /// Tears down the loop. The I/O thread owns the socket and the WDSP channels: on
    /// its way out it sends the Metis STOP, closes the fd, and closes the channels.
    /// Closing them here would race an in-flight recv/fexchange0 on the I/O thread —
    /// exactly the WDSP concurrency wedge the DSP command queue exists to prevent.
    func stop() {
        guard running.get() || fd >= 0 else { return }
        running.set(false)
        // Wait for the loop to exit (bounded: one recv timeout + one command batch).
        if let worker {
            let deadline = Date().addingTimeInterval(2)
            while !worker.isFinished && Date() < deadline { usleep(10_000) }
        }
        worker = nil
        fd = -1
        audioInput?.stop()
        audioInput = nil
        micRing.clear()
        mixer?.stop()
        mixer = nil
        for engine in engines { engine.ring.clear() }
        updateContinuation?.finish()
    }

    /// Enqueues a WDSP operation to run on the DSP thread (WDSP is not thread-safe on
    /// macOS). No-op when not streaming — the session re-applies settings on connect.
    /// Gated on `running` (not the fd) so commands still work while the socket is
    /// down after a failed mid-stream rebuild — that's how a retry gets in.
    private func dsp(key: String? = nil, _ command: @escaping @Sendable () -> Void) {
        guard running.get() else { return }
        dspCommands.enqueue(key: key, command)
    }

    /// Enqueues a WDSP RX operation for a specific slice's channel. Pass `key` for
    /// slider-driven setters so a drag coalesces to the latest value (see
    /// `DSPCommandQueue.enqueue`); the key is namespaced per slice automatically.
    private func runOnSlice(_ index: Int, key: String? = nil,
                            _ op: @escaping @Sendable (WDSPRadio) -> Void) {
        guard engines.indices.contains(index) else { return }
        let engines = self.engines
        dsp(key: key.map { "\($0).\(index)" }) { op(engines[index].wdsp) }
    }

    /// Sets a slice's demodulation mode. Slice 0 also sets the matching transmit mode.
    func setMode(_ mode: RadioMode, slice: Int = 0) {
        guard engines.indices.contains(slice) else { return }
        if slice == 0 { currentMode = mode }
        let engines = self.engines
        let tx = wdspTx
        dsp {
            if slice == 0 { tx.setMode(mode) }
            engines[slice].wdsp.setMode(mode)
            engines[slice].ring.reset(primingSilence: RadioConnection.audioPrimeSamples)
        }
    }

    /// Keys/unkeys the transmitter. On key-down this starts mic capture and feeds it
    /// through WDSP TXA; on key-up it stops the mic.
    func setTransmit(_ on: Bool) {
        if on {
            // Keying voice cancels any tune carrier and starts mic capture (which
            // triggers the permission prompt on first use).
            transmit.tune = false
            micRing.clear()
            let input = AudioInput(ring: micRing, deviceUID: micDeviceUID)
            do {
                try input.start()
                audioInput = input
            } catch {
                // Mic unavailable (e.g. permission not yet granted on first key-up).
                // Transmit still keys; audio stays silent until the mic comes up.
                NSLog("AudioInput failed to start: \(error.localizedDescription)")
            }
            transmit.transmitting = true
        } else {
            audioInput?.stop()
            audioInput = nil
            // Un-keying PTT must not cancel an active tune carrier.
            if !transmit.tune { transmit.transmitting = false }
        }
    }

    /// Starts/stops a steady tune carrier (synthesized directly for a glitch-free tone)
    /// for tuning amplifiers / antenna tuners.
    func setTune(_ on: Bool) {
        transmit.tune = on
        transmit.transmitting = on
    }

    /// Attaches (or detaches, with nil) a secondary ring that receives the
    /// slice's demodulated 48 kHz mono audio — the FT8/FT4 decoder tap.
    func setAudioTap(_ ring: AudioRingBuffer?, slice: Int = 0) {
        guard engines.indices.contains(slice) else { return }
        let engines = self.engines
        dsp { engines[slice].wdsp.tapRing = ring }
    }

    /// Keys the transmitter with a pre-rendered digital-mode waveform (48 kHz
    /// mono audio, e.g. FT8 GFSK tones). The mic is not opened; the waveform
    /// plays once and the caller un-keys via `stopDigitalTransmit()`.
    func startDigitalTransmit(samples: [Float]) {
        transmit.tune = false
        digitalTXRing.clear()
        digitalTXRing.write(samples)
        transmit.digital = true
        transmit.transmitting = true
    }

    /// Un-keys a digital-mode transmission and drops any unplayed samples.
    func stopDigitalTransmit() {
        transmit.digital = false
        if !transmit.tune { transmit.transmitting = false }
        digitalTXRing.clear()
    }

    /// Sets the TX drive level (0–255).
    func setDrive(_ level: UInt8) {
        transmit.drive = level
    }

    /// Sets microphone gain (linear, applied to mic audio before WDSP).
    func setMicGain(_ gain: Double) {
        let tx = wdspTx
        dsp { tx.setMicGain(gain) }
    }

    /// Selects the macOS input device (by UID) for mic capture; nil = system default.
    /// Takes effect on the next key-down.
    func setInputDevice(uid: String?) {
        micDeviceUID = uid
    }

    /// Enables/disables the WDSP speech processor (compressor) with a dB gain.
    func setSpeechProcessor(_ on: Bool, gain: Double) {
        let tx = wdspTx
        dsp { tx.setSpeechProcessor(on, gain: gain) }
    }

    /// TX audio shaping: passband edges and 3-band graphic EQ.
    func setTXBandwidth(low: Double, high: Double) { let tx = wdspTx; dsp { tx.setTXBandwidth(low: low, high: high) } }
    func setTXEQ(on: Bool) { let tx = wdspTx; dsp { tx.setEQ(on: on) } }
    func setTXEQGains(preamp: Int, low: Int, mid: Int, high: Int) {
        let tx = wdspTx
        dsp { tx.setEQGains(preamp: preamp, low: low, mid: mid, high: high) }
    }
    /// CESSB (Controlled Envelope SSB) overshoot control.
    func setCESSB(_ on: Bool) { let tx = wdspTx; dsp { tx.setCESSB(on) } }

    /// Additional TX processing: phase rotator, leveler, and CFC multi-band compressor.
    func setPhaseRotator(_ on: Bool) { let tx = wdspTx; dsp { tx.setPhaseRotator(on) } }
    func setLeveler(_ on: Bool) { let tx = wdspTx; dsp { tx.setLeveler(on) } }
    func setLevelerTop(_ db: Double) { let tx = wdspTx; dsp { tx.setLevelerTop(db) } }
    func setCFC(_ on: Bool) { let tx = wdspTx; dsp { tx.setCFC(on) } }
    func setCFCPrecomp(_ db: Double) { let tx = wdspTx; dsp { tx.setCFCPrecomp(db) } }
    func setCFCEQ(_ on: Bool) { let tx = wdspTx; dsp { tx.setCFCEQ(on) } }

    /// RX 3-band graphic EQ.
    func setRXEQ(on: Bool, slice: Int = 0) { runOnSlice(slice) { $0.setEQ(on: on) } }
    func setRXEQGains(preamp: Int, low: Int, mid: Int, high: Int, slice: Int = 0) {
        runOnSlice(slice, key: "eqGains") { $0.setEQGains(preamp: preamp, low: low, mid: mid, high: high) }
    }

    /// Sets the 7-bit open-collector output pattern (amp band data). Applied on the
    /// next config command frame (a few ms).
    func setOpenCollector(_ value: UInt8) {
        var s = settingsBox.current
        s.openCollector = value
        settingsBox.current = s
    }

    /// Sets a slice's CW sidetone pitch (Hz).
    func setCWPitch(_ hz: Double, slice: Int = 0) { runOnSlice(slice, key: "cwPitch") { $0.setCWPitch(hz) } }

    /// Sets a slice's CW filter width in Hz.
    func setFilterWidth(_ width: Double, slice: Int = 0) { runOnSlice(slice, key: "filterWidth") { $0.setFilterWidth(width) } }

    /// Sets a slice's SSB/DIGI low-cut edge (Hz).
    func setLowCut(_ hz: Double, slice: Int = 0) { runOnSlice(slice, key: "lowCut") { $0.setLowCut(hz) } }

    /// Sets a slice's high-cut / bandwidth edge (Hz).
    func setHighCut(_ hz: Double, slice: Int = 0) { runOnSlice(slice, key: "highCut") { $0.setHighCut(hz) } }

    /// Sets a slice's audio volume (0…1).
    func setVolume(_ volume: Float, slice: Int = 0) { runOnSlice(slice, key: "volume") { $0.setVolume(volume) } }

    /// Sets a slice's stereo pan (−1 = hard left, 0 = center, +1 = hard right).
    func setPan(_ pan: Float, slice: Int = 0) {
        guard engines.indices.contains(slice) else { return }
        engines[slice].pan = pan
        mixer?.setPan(slice, pan: pan)
    }

    /// Selects the macOS output device (by UID) for received audio; nil = system default.
    /// Re-routes immediately if currently streaming; otherwise applied when the mixer starts.
    func setOutputDevice(uid: String?) {
        audioOutputUID = uid
        guard mixer != nil else { return }
        mixer?.stop()
        let mix = SliceAudioMixer(deviceUID: uid)
        for i in 0..<activeSliceCount {
            mix.setSlice(i, ring: engines[i].ring, pan: engines[i].pan, enabled: true)
        }
        do {
            try mix.start()
        } catch {
            NSLog("RadioConnection: audio mixer failed to restart on device change (\(error)); audio muted.")
        }
        mixer = mix
    }

    /// AGC time-constant profile (0 off … 4 fast).
    func setAGCMode(_ mode: Int, slice: Int = 0) { runOnSlice(slice) { $0.setAGCMode(mode) } }
    /// AGC-T: maximum AGC gain in dB.
    func setAGCTop(_ db: Double, slice: Int = 0) { runOnSlice(slice, key: "agcTop") { $0.setAGCTop(db) } }

    /// RX ADC step attenuator (0–31 dB; 0 = max gain). Applied on the next command frame.
    func setRXAttenuator(_ db: UInt8) {
        var s = settingsBox.current
        s.rxAttenuator = db
        settingsBox.current = s
    }

    /// HL2 LNA gain (−12…+48 dB). Applied on the next command frame.
    func setRXLNAGain(_ db: Int) {
        var s = settingsBox.current
        s.rxLNAGain = db
        settingsBox.current = s
    }

    /// Radio clock error in ppm; NCO frequencies are corrected on the next command
    /// frames, so adjusting this live re-centers a reference carrier immediately.
    func setFrequencyCalibration(ppm: Double) {
        var s = settingsBox.current
        s.frequencyCalibrationPPM = ppm
        settingsBox.current = s
    }

    /// Noise reduction controls (RXA DSP), per slice. Applied live; restored on reconnect.
    func setSpectralNR(_ on: Bool, slice: Int = 0) { runOnSlice(slice) { $0.setSpectralNR(on) } }
    func setSpectralNRGainMethod(_ method: Int, slice: Int = 0) { runOnSlice(slice) { $0.setSpectralNRGainMethod(method) } }
    func setSpectralNRNPEMethod(_ method: Int, slice: Int = 0) { runOnSlice(slice) { $0.setSpectralNRNPEMethod(method) } }
    func setSpectralNRArtifactReduction(_ on: Bool, slice: Int = 0) { runOnSlice(slice) { $0.setSpectralNRArtifactReduction(on) } }
    func setANR(_ on: Bool, slice: Int = 0) { runOnSlice(slice) { $0.setANR(on) } }
    func setANRStrength(_ taps: Int, slice: Int = 0) { runOnSlice(slice, key: "anrTaps") { $0.setANRStrength(taps) } }
    func setANF(_ on: Bool, slice: Int = 0) { runOnSlice(slice) { $0.setANF(on) } }
    func setNoiseBlanker(_ on: Bool, slice: Int = 0) { runOnSlice(slice) { $0.setNoiseBlanker(on) } }
    func setNoiseBlankerThreshold(_ threshold: Double, slice: Int = 0) { runOnSlice(slice, key: "nbThresh") { $0.setNoiseBlankerThreshold(threshold) } }
    func setNoiseBlanker2(_ on: Bool, slice: Int = 0) { runOnSlice(slice) { $0.setNoiseBlanker2(on) } }
    func setNoiseBlanker2Mode(_ mode: Int, slice: Int = 0) { runOnSlice(slice) { $0.setNoiseBlanker2Mode(mode) } }
    func setNoiseBlanker2Threshold(_ threshold: Double, slice: Int = 0) { runOnSlice(slice, key: "nb2Thresh") { $0.setNoiseBlanker2Threshold(threshold) } }

    /// Squelch (AM/SAM level squelch via AMSQ, FM via FMSQ), per slice.
    func setSquelch(_ on: Bool, slice: Int = 0) { runOnSlice(slice) { $0.setSquelch(on) } }
    func setSquelchLevel(_ level: Double, slice: Int = 0) { runOnSlice(slice, key: "sqlLevel") { $0.setSquelchLevel(level) } }

    /// SNB spectral noise blanker, per slice.
    func setSNB(_ on: Bool, slice: Int = 0) { runOnSlice(slice) { $0.setSNB(on) } }

    /// Manual notch filters (MNF), per slice. Notches carry absolute RF center + width.
    func setManualNotches(_ notches: [(freq: Double, width: Double, active: Bool)], slice: Int = 0) {
        runOnSlice(slice, key: "notches") { $0.setManualNotches(notches) }
    }
    func setManualNotchRun(_ on: Bool, slice: Int = 0) { runOnSlice(slice) { $0.setManualNotchRun(on) } }
    func setTuneFrequency(_ hz: Double, slice: Int = 0) { runOnSlice(slice, key: "tuneFreq") { $0.setTuneFrequency(hz) } }

    /// APF CW audio peaking filter, per slice.
    func setAPF(_ on: Bool, slice: Int = 0) { runOnSlice(slice) { $0.setAPF(on) } }
    func setAPFBandwidth(_ bw: Double, slice: Int = 0) { runOnSlice(slice, key: "apfBW") { $0.setAPFBandwidth(bw) } }

    /// Tunes receiver `index` to `hz`. Applied on the next outgoing EP2 frame.
    func setFrequency(_ hz: UInt32, receiver index: Int = 0) {
        var s = settingsBox.current
        while s.receiverFrequencies.count <= index { s.receiverFrequencies.append(hz) }
        s.receiverFrequencies[index] = hz
        if index == 0 { s.transmitFrequency = hz }
        settingsBox.current = s
        // The audio ring is deliberately NOT reset here: it holds ≤0.5 s, so a retune
        // just plays a brief tail of the old frequency and flows into the new one —
        // continuous audio while a MIDI knob spins (a per-tick reset silenced tuning).
        // Keep the slice's manual-notch database anchored to the new VFO frequency
        // so notches track their absolute RF targets as you tune.
        runOnSlice(index, key: "tuneFreq") { $0.setTuneFrequency(Double(hz)) }
    }

    /// Changes the number of active receive slices (1…maxSlices, clamped to what the
    /// hardware/protocol supports). Opens/closes DSP channels and updates the mixer live.
    func setActiveSliceCount(_ count: Int) {
        let n = max(1, min(Self.maxSlices, count))
        var s = settingsBox.current
        while s.receiverFrequencies.count < n {
            s.receiverFrequencies.append(s.receiverFrequencies.last ?? 7_100_000)
        }
        // While streaming, the receiver count is applied inside the rebuild command,
        // atomically with the socket swap: the count must NEVER change in the EP2
        // frames sent on a running stream — the radio re-lays-out its samples
        // mid-frame and the USB sync drifts off offset 8 (permanent misframe).
        if !running.get() { s.receiverCount = n }
        settingsBox.current = s

        let previous = activeSliceCount
        activeSliceCount = n
        NSLog("Slices: \(previous) -> \(n) (streaming: \(running.get()))")
        guard running.get() else { return }   // not streaming: start() opens the right count

        // Open/close the WDSP channels on the DSP thread (see `dsp`). The mixer is
        // independently locked, so its (de)registration is safe to enqueue alongside.
        // Existing slices' WDSP channels are left untouched, so their mode/filter/AGC/NR
        // settings survive the change — only the added/removed channels are (un)opened.
        let engines = self.engines
        let mixer = self.mixer
        let mode = currentMode
        let ip = radio.ipAddress
        let socket = socketBox
        let box = settingsBox
        dsp {
            // Adjust the per-slice WDSP channels for the new count.
            if n > previous {
                for i in previous..<n {
                    engines[i].wdsp.open(mode: mode)
                    engines[i].ring.reset(primingSilence: RadioConnection.audioPrimeSamples)
                    mixer?.setSlice(i, ring: engines[i].ring, pan: engines[i].pan, enabled: true)
                    NSLog("DSP: opened slice \(i) (ch \(2 + i))")
                }
            } else if n < previous {
                for i in n..<previous {
                    mixer?.removeSlice(i)
                    engines[i].wdsp.close()
                    engines[i].ring.clear()
                    NSLog("DSP: closed slice \(i)")
                }
            }
            // The ANAN misframes when the receiver count changes mid-stream: the USB sync
            // word drifts off offset 8 and decode dies for EVERY receiver (observed live:
            // sync at 110/622). So the sequence here is: stop the old stream, close its
            // socket, THEN flip receiverCount in the settings box (the old socket never
            // carries the new count), and bring up a fresh socket that programs the new
            // layout via EP2 while stopped before START — the stream begins aligned.
            // Runs on the I/O thread; the run loop reads the new fd on its next iteration.
            let old = socket.current
            if old >= 0 {
                let stop = HPSDRProtocol1.stopCommand()
                _ = stop.withUnsafeBytes { send(old, $0.baseAddress, $0.count, 0) }
                close(old)
            }
            var s2 = box.current
            s2.receiverCount = n
            box.current = s2
            if let stream = RadioConnection.openStreamSocket(ip: ip, settings: box.current) {
                socket.swap(fd: stream.fd, nextSeq: stream.nextSeq)
                NSLog("DSP: rebuilt socket for \(n) receiver(s)")
            } else {
                socket.current = -1
                NSLog("DSP: socket rebuild FAILED for \(n) receiver(s)")
            }
        }
    }

    /// Changes the sample rate. Applied on the next outgoing EP2 frame.
    func setSampleRate(_ rate: HPSDRProtocol1.SampleRate) {
        var s = settingsBox.current
        s.sampleRate = rate
        settingsBox.current = s
    }

    // MARK: - Background I/O loop (runs off the actor)

    private static func runLoop(socket: SocketBox,
                                settings: SettingsBox,
                                running: RunningFlag,
                                updates: AsyncStream<StreamUpdate>.Continuation?,
                                engines: [SliceEngine],
                                wdspTx: WDSPTransmit,
                                transmit: TransmitBox,
                                micRing: AudioRingBuffer,
                                digitalRing: AudioRingBuffer,
                                commands: DSPCommandQueue,
                                hermesLite: Bool,
                                sampleClock: SampleClockCounter) {
        var seqOut: UInt32 = 0
        var slotCounter = 0

        // N2ADR IO board frequency feed (HL2 only): pending one-byte I2C register
        // writes, drained one per EP2 frame in the second command slot. `ioSentHz`
        // is the last frequency queued (0 = never — triggers the register reset +
        // first burst). Bursts are throttled to one per 0.5 s and refreshed every
        // 10 s: the writes carry no ACK, so a lost datagram or a board power cycle
        // heals on the next refresh (re-writing an unchanged frequency is a no-op
        // for the board's amplifier CAT output).
        var ioPending: [(register: UInt8, value: UInt8)] = []
        var ioSentHz: UInt32 = 0
        var ioNextBurstNs: UInt64 = 0
        var ioRefreshNs: UInt64 = 0
        // Next send of the HL2 TX-buffer config (addr 0x17, PTT hang + latency).
        var txConfigNextNs: UInt64 = 0

        // TX I/Q buffering: WDSP produces 1024-sample blocks; each EP2 frame needs 126.
        var txBuffer = [Float]()
        var txPos = 0
        let txSilence = [Float](repeating: 0, count: WDSPTransmit.bufferSize)

        // Tune carrier oscillator (synthesized directly for a steady, glitch-free tone).
        var tunePhase = 0.0
        let tuneDelta = 2.0 * Double.pi * 600.0 / Double(WDSPTransmit.rate)
        var tuneFrame = [Float](repeating: 0, count: 252)

        // Per-interval accumulators (flushed ~10×/sec).
        var intervalStart = Date()
        var packetsInInterval = 0
        var gapsInInterval = 0
        var rmsAccum: Double = 0
        var sampleCount = 0
        var lastStatus = RadioStreamStatus()
        // Byte-stream reassembler: decodes USB frames wherever the sync word lands,
        // because the 10E restarts its stream at arbitrary offsets (see EP6Assembler).
        let assembler = EP6Assembler()
        // Diagnostics: per-second decoded sample counts per slice (healthy ≈ 96000/s each).
        var dbgRx0Samples = 0
        var dbgRx1Samples = 0
        var dbgRxCount = 0
        var dbgFlushCount = 0
        var dbgGaps = 0
        var dbgReceived = 0
        // Stall attribution: worst single command-drain and packet-process time (ms)
        // plus commands executed, per log interval. A multi-second audio cutout shows
        // up here as a huge maxDrain (slow WDSP setter) or maxProc (slow DSP path).
        var dbgCmdCount = 0
        var dbgMaxDrainMs = 0.0
        var dbgMaxProcMs = 0.0

        // Reused per-iteration buffers — the steady-state loop must not allocate.
        var buffer = [UInt8](repeating: 0, count: 2048)
        var ep2Frame = [UInt8](repeating: 0, count: HPSDRProtocol1.frameSize)
        var frameIQ = [Float](repeating: 0, count: 252)
        var lastFD: Int32 = -2
        var nextEP2SendNs = DispatchTime.now().uptimeNanoseconds
        var ep2SentInInterval = 0
        var dbgEP2Sent = 0

        while running.get() {
            // Apply any queued WDSP operations (channel open/close, DSP control changes)
            // here — on this thread — so they never run concurrently with fexchange0.
            // A command may swap the socket (mid-stream rebuild), so read fd afterward.
            let pending = commands.drain()
            if !pending.isEmpty {
                let tDrain0 = DispatchTime.now().uptimeNanoseconds
                for entry in pending {
                    let tCmd0 = DispatchTime.now().uptimeNanoseconds
                    entry.run()
                    let cmdMs = Double(DispatchTime.now().uptimeNanoseconds &- tCmd0) / 1e6
                    if cmdMs > 100 {
                        NSLog("DSP: slow command '\(entry.key ?? "unkeyed")' took \(String(format: "%.0f", cmdMs))ms")
                    }
                }
                dbgCmdCount += pending.count
                let drainMs = Double(DispatchTime.now().uptimeNanoseconds &- tDrain0) / 1e6
                if drainMs > dbgMaxDrainMs { dbgMaxDrainMs = drainMs }
            }
            let (fd, nextSeq) = socket.snapshot
            if fd < 0 {
                // Mid-stream socket rebuild failed. Idle (still draining commands so a
                // later slice-count change can retry) instead of spinning on recv(EBADF).
                usleep(200_000)
                continue
            }
            if fd != lastFD {
                // Fresh socket (initial start or mid-stream rebuild): the EP6 sequence
                // restarts, and EP2 continues from where the priming frames left off.
                assembler.reset()
                seqOut = nextSeq
                nextEP2SendNs = DispatchTime.now().uptimeNanoseconds
                lastFD = fd
                ioPending.removeAll()
                ioSentHz = 0
                ioNextBurstNs = 0
                txConfigNextNs = 0
                sampleClock.markDiscontinuity()
            }

            let settingsSnapshot = settings.current
            let transmitting = transmit.transmitting
            let tuning = transmit.tune

            // Receive one EP6 datagram (blocks up to the socket timeout).
            let received = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if received > 522 { dbgReceived = Int(received) }
            let tProc0 = DispatchTime.now().uptimeNanoseconds
            if received > 0,
               let result = assembler.feed(buffer, length: Int(received),
                                           receiverCount: settingsSnapshot.receiverCount) {
                packetsInInterval += 1
                if result.gap { gapsInInterval += 1 }
                // Sample-clock bookkeeping for NTP calibration: count every decoded
                // RX0 sample (even while transmitting, when DSP below is skipped).
                sampleClock.count(result.samples.count / 2,
                                  rateHz: settingsSnapshot.sampleRate.hertz,
                                  gap: result.gap)
                // Empty samples = no USB frame completed this datagram (assembler is
                // mid-frame or hunting for sync); status would be default-empty then.
                if !result.samples.isEmpty { lastStatus = result.status }
                // While transmitting, skip the receive DSP so the send loop keeps full rate.
                if !transmitting {
                    let span = settingsSnapshot.sampleRate.hertz
                    let rxCount = min(result.receivers.count, engines.count)
                    for rx in 0..<rxCount {
                        let iq = result.receivers[rx]
                        guard !iq.isEmpty else { continue }
                        engines[rx].wdsp.process(iq: iq, inputRate: span)
                        let centerHz = rx < settingsSnapshot.receiverFrequencies.count
                            ? settingsSnapshot.receiverFrequencies[rx] : 0
                        engines[rx].analyzer.ingest(iq, centerHz: centerHz, spanHz: span)
                    }
                    // RMS from slice 0 drives the summary signal meter.
                    let s0 = result.samples
                    if !s0.isEmpty {
                        var sumsq: Float = 0
                        vDSP_svesq(s0, 1, &sumsq, vDSP_Length(s0.count))
                        rmsAccum += Double(sumsq)
                        sampleCount += s0.count
                    }
                    dbgRxCount = rxCount
                    dbgRx0Samples += s0.count
                    if rxCount > 1 { dbgRx1Samples += result.receivers[1].count }
                }
            }
            let procMs = Double(DispatchTime.now().uptimeNanoseconds &- tProc0) / 1e6
            if procMs > dbgMaxProcMs { dbgMaxProcMs = procMs }

            // EP2 pacing: the radio consumes EP2 at the fixed 48 kHz TX/C&C clock
            // (~381 frames/s) regardless of the RX rate. Pace by the WALL CLOCK, not
            // by counting received packets: when the radio's actual stream rate
            // disagrees with `settings` (e.g. stale 192 kHz config held from a prior
            // session while the app assumes 48 kHz), packet-counted pacing overfeeds
            // 4×, the flooded FIFO stops honoring C&C, and the radio can never
            // converge to the requested config — observed live as garbled ring-
            // shredded audio plus dead tuning. Clock-paced EP2 always lands at the
            // rate the radio can absorb, so the config latches within ~a second.
            let nowNs = DispatchTime.now().uptimeNanoseconds
            if nowNs >= nextEP2SendNs {
                // Advance by exact frame periods to hold 381/s long-term; after a
                // stall (recv timeout, dsp-command burst) resync instead of bursting
                // a catch-up flood.
                nextEP2SendNs &+= Self.ep2PeriodNs
                if nowNs > nextEP2SendNs &+ 4 &* Self.ep2PeriodNs {
                    nextEP2SendNs = nowNs &+ Self.ep2PeriodNs
                }
                ep2SentInInterval += 1
                var sendSettings = settingsSnapshot
                sendSettings.mox = transmitting
                sendSettings.drive = transmitting ? transmit.drive : 0
                let slots = sendSettings.commandSlotCount

                // IO board: queue a register burst when the TX frequency changed
                // (or on the periodic refresh), then ride one write per frame in
                // the second command slot. A full burst is 6 frames ≈ 16 ms.
                var ioCommand: (UInt8, UInt8, UInt8, UInt8, UInt8)? = nil
                if hermesLite {
                    if ioPending.isEmpty, nowNs >= ioNextBurstNs,
                       sendSettings.transmitFrequency != ioSentHz || nowNs >= ioRefreshNs {
                        if ioSentHz == 0 { ioPending.append((HL2IOBoard.regControl, 1)) }
                        ioPending.append(contentsOf: HL2IOBoard.frequencyWrites(hz: sendSettings.transmitFrequency))
                        ioSentHz = sendSettings.transmitFrequency
                        ioNextBurstNs = nowNs &+ 500_000_000
                        ioRefreshNs = nowNs &+ 10_000_000_000
                    }
                    if !ioPending.isEmpty {
                        let write = ioPending.removeFirst()
                        ioCommand = HL2IOBoard.writeCommand(register: write.register,
                                                            value: write.value,
                                                            mox: transmitting)
                    } else if nowNs >= txConfigNextNs {
                        // HL2 TX buffering (addr 0x17): 20 ms PTT hang, 40 ms TX
                        // buffer latency — the values piHPSDR uses. Refreshed every
                        // second; a static config register, so re-sends are no-ops.
                        ioCommand = (0x2E | (transmitting ? 0x01 : 0x00), 0x00, 0x00, 20, 40)
                        txConfigNextNs = nowNs &+ 1_000_000_000
                    }
                }

                if transmitting && tuning {
                    // Steady tune carrier: phase-continuous complex sinusoid.
                    let amp: Float = 0.6
                    for s in 0..<126 {
                        tuneFrame[s * 2] = amp * Float(cos(tunePhase))
                        tuneFrame[s * 2 + 1] = amp * Float(sin(tunePhase))
                        tunePhase += tuneDelta
                        if tunePhase > 2 * Double.pi { tunePhase -= 2 * Double.pi }
                    }
                    HPSDRFrame.buildEP2(into: &ep2Frame, sequence: seqOut, settings: sendSettings,
                                        slot1: slotCounter % slots, slot2: (slotCounter + 1) % slots,
                                        txIQ: tuneFrame, command2: ioCommand)
                } else if transmitting {
                    // Voice/digital transmit: feed mic (or pre-rendered digital-mode)
                    // audio through WDSP TXA. Guard the refill on `running` and on an
                    // empty block so a teardown that closes the TXA channel
                    // mid-transmit can't spin this loop forever.
                    let digitalTX = transmit.digital
                    while running.get(), txBuffer.count - txPos < 252 {
                        var mic = txSilence
                        _ = mic.withUnsafeMutableBufferPointer {
                            (digitalTX ? digitalRing : micRing)
                                .read(into: $0.baseAddress!, count: WDSPTransmit.bufferSize)
                        }
                        // Digital audio is rendered at its final level; mic gain
                        // must not shape it.
                        let block = wdspTx.processBlock(mic: mic, gainOverride: digitalTX ? 1.0 : nil)
                        if block.isEmpty { break }
                        txBuffer.append(contentsOf: block)
                    }
                    if txBuffer.count - txPos >= 252 {
                        frameIQ.withUnsafeMutableBufferPointer { dst in
                            txBuffer.withUnsafeBufferPointer { src in
                                dst.baseAddress!.update(from: src.baseAddress! + txPos, count: 252)
                            }
                        }
                        txPos += 252
                        if txPos > 8192 { txBuffer.removeFirst(txPos); txPos = 0 }
                    } else {
                        // Channel closed during teardown: send a silent frame, never slice past the end.
                        frameIQ.withUnsafeMutableBufferPointer {
                            vDSP_vclr($0.baseAddress!, 1, vDSP_Length($0.count))
                        }
                    }
                    HPSDRFrame.buildEP2(into: &ep2Frame, sequence: seqOut, settings: sendSettings,
                                        slot1: slotCounter % slots, slot2: (slotCounter + 1) % slots,
                                        txIQ: frameIQ, command2: ioCommand)
                } else {
                    if txPos != 0 || !txBuffer.isEmpty { txBuffer.removeAll(keepingCapacity: true); txPos = 0 }
                    HPSDRFrame.buildEP2(into: &ep2Frame, sequence: seqOut, settings: sendSettings,
                                        slot1: slotCounter % slots, slot2: (slotCounter + 1) % slots,
                                        command2: ioCommand)
                }
                slotCounter += 2
                seqOut &+= 1
                _ = ep2Frame.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
            }

            // Flush a throttled update roughly every 100 ms.
            let elapsed = Date().timeIntervalSince(intervalStart)
            if elapsed >= 0.1 {
                let rms = sampleCount > 0 ? Float((rmsAccum / Double(sampleCount)).squareRoot()) : 0
                let pps = Int(Double(packetsInInterval) / elapsed)
                updates?.yield(StreamUpdate(status: lastStatus,
                                            packetsPerSecond: pps,
                                            sequenceGaps: gapsInInterval,
                                            signalRMS: rms))
                dbgFlushCount += 1
                dbgGaps += gapsInInterval
                dbgEP2Sent += ep2SentInInterval
                ep2SentInInterval = 0
                if dbgFlushCount >= 10 {   // ~1×/sec
                    if DSPDiagnostics.enabled {
                        // Header/sync diagnostics on the most recent datagram — computed
                        // only here (1×/sec), never in the per-packet path.
                        var hdr = "?"
                        var sync = "NONE"
                        if dbgReceived > 522 {
                            hdr = String(format: "%02X %02X %02X %02X",
                                         buffer[0], buffer[1], buffer[2], buffer[3])
                            // Scan for the 7F 7F 7F USB sync word and report every offset
                            // (should be 8 and 520 in a standard frame).
                            var offsets: [Int] = []
                            var i = 0
                            let limit = dbgReceived - 2
                            while i < limit {
                                if buffer[i] == 0x7F && buffer[i + 1] == 0x7F && buffer[i + 2] == 0x7F {
                                    offsets.append(i)
                                    if offsets.count >= 6 { break }
                                }
                                i += 1
                            }
                            if !offsets.isEmpty { sync = offsets.map(String.init).joined(separator: ",") }
                        }
                        let drainStr = String(format: "%.1f", dbgMaxDrainMs)
                        let procStr = String(format: "%.1f", dbgMaxProcMs)
                        NSLog("DSP: rxCount=\(dbgRxCount) packetRate=\(pps)/s gaps=\(dbgGaps)/s ep2=\(dbgEP2Sent)/s rx0decoded=\(dbgRx0Samples)/s rx1decoded=\(dbgRx1Samples)/s cmds=\(dbgCmdCount)/s maxDrain=\(drainStr)ms maxProc=\(procStr)ms resyncs=\(assembler.resyncs) recv=\(dbgReceived) hdr=[\(hdr)] sync=[\(sync)]")
                    }
                    dbgFlushCount = 0
                    dbgGaps = 0
                    dbgEP2Sent = 0
                    dbgRx0Samples = 0
                    dbgRx1Samples = 0
                    dbgCmdCount = 0
                    dbgMaxDrainMs = 0
                    dbgMaxProcMs = 0
                }
                intervalStart = Date()
                packetsInInterval = 0
                gapsInInterval = 0
                rmsAccum = 0
                sampleCount = 0
            }
        }

        // Teardown on this thread: it is the sole owner of the socket, and the WDSP
        // channels must close here so the close can never race an in-flight fexchange0.
        let finalFD = socket.current
        if finalFD >= 0 {
            let stopPacket = HPSDRProtocol1.stopCommand()
            _ = stopPacket.withUnsafeBytes { send(finalFD, $0.baseAddress, $0.count, 0) }
            close(finalFD)
        }
        socket.current = -1
        for engine in engines { engine.wdsp.close() }
        wdspTx.close()
    }
}

/// A thread-safe FIFO of WDSP operations queued by the actor and executed on the DSP
/// thread. Ensures all WDSP calls are serialized (WDSP is not thread-safe on macOS).
private nonisolated final class DSPCommandQueue: @unchecked Sendable {
    private struct Entry {
        let key: String?
        let run: @Sendable () -> Void
    }

    private var lock = os_unfair_lock()
    private var commands: [Entry] = []

    /// Enqueues a command. A non-nil `key` coalesces: if a command with the same key
    /// is already pending, it is REPLACED in place (keeping queue order) instead of
    /// appended — a slider drag collapses to one pending command carrying the latest
    /// value, rather than hundreds executed back-to-back on the DSP thread.
    func enqueue(key: String? = nil, _ command: @escaping @Sendable () -> Void) {
        os_unfair_lock_lock(&lock)
        if let key, let existing = commands.firstIndex(where: { $0.key == key }) {
            commands[existing] = Entry(key: key, run: command)
        } else {
            commands.append(Entry(key: key, run: command))
        }
        os_unfair_lock_unlock(&lock)
    }

    /// Atomically removes and returns all queued commands with their coalescing
    /// keys (the run loop logs the key of any command that runs slow).
    func drain() -> [(key: String?, run: @Sendable () -> Void)] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let pending = commands.map { (key: $0.key, run: $0.run) }
        commands.removeAll(keepingCapacity: true)
        return pending
    }

    func clear() {
        os_unfair_lock_lock(&lock)
        commands.removeAll(keepingCapacity: true)
        os_unfair_lock_unlock(&lock)
    }
}

/// One receive slice's full DSP + spectrum chain: a WDSP RXA channel writing mono
/// audio into `ring`, and a vDSP analyzer feeding the slice's panadapter `spectrum`.
/// Channel/blanker ids are offset per slice so WDSP instances don't collide
/// (TXA uses channel 1; slice i uses channel 2+i, blanker id i).
private nonisolated final class SliceEngine: @unchecked Sendable {
    let wdsp: WDSPRadio
    let ring: AudioRingBuffer
    let analyzer: SpectrumAnalyzer
    let spectrum: SpectrumBuffer
    /// Stereo pan for the mixer: −1 = hard left, 0 = center, +1 = hard right.
    var pan: Float = 0

    init(index: Int, spectrum: SpectrumBuffer) {
        self.spectrum = spectrum
        self.ring = AudioRingBuffer()
        self.analyzer = SpectrumAnalyzer(buffer: spectrum)
        self.wdsp = WDSPRadio(ring: ring, channelID: Int32(2 + index), nbID: Int32(index))
    }
}

/// Thread-safe transmit state shared between the actor (PTT/tune/drive control)
/// and the I/O thread (which packs TX I/Q and sets MOX/drive).
private nonisolated final class TransmitBox: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var _transmitting = false
    private var _tune = false
    private var _digital = false
    private var _drive: UInt8 = 0
    var transmitting: Bool {
        get { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return _transmitting }
        set { os_unfair_lock_lock(&lock); _transmitting = newValue; os_unfair_lock_unlock(&lock) }
    }
    /// True while TX audio comes from the digital-mode ring instead of the mic.
    var digital: Bool {
        get { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return _digital }
        set { os_unfair_lock_lock(&lock); _digital = newValue; os_unfair_lock_unlock(&lock) }
    }
    var tune: Bool {
        get { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return _tune }
        set { os_unfair_lock_lock(&lock); _tune = newValue; os_unfair_lock_unlock(&lock) }
    }
    var drive: UInt8 {
        get { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return _drive }
        set { os_unfair_lock_lock(&lock); _drive = newValue; os_unfair_lock_unlock(&lock) }
    }
}

/// A tiny thread-safe boolean used to signal the I/O thread to stop.
private nonisolated final class RunningFlag: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var value = false
    func set(_ v: Bool) { os_unfair_lock_lock(&lock); value = v; os_unfair_lock_unlock(&lock) }
    func get() -> Bool { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return value }
}
