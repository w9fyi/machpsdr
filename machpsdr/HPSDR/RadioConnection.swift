import Foundation
import Darwin

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

/// Thread-safe holder for the live socket file descriptor. The actor sets it on
/// start/stop; the I/O thread reads it every iteration so the socket can be swapped
/// out from under the run loop (the mid-stream socket rebuild on slice-count change).
private nonisolated final class SocketBox: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var value: Int32 = -1
    var current: Int32 {
        get { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return value }
        set { os_unfair_lock_lock(&lock); value = newValue; os_unfair_lock_unlock(&lock) }
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
    private var audioInput: AudioInput?
    /// Input device UID for mic capture (nil = system default). Applied on key-down.
    private var micDeviceUID: String?

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
        self.updates = AsyncStream { continuation = $0 }
        self.updateContinuation = continuation
    }

    /// Current settings (frequency, sample rate, …).
    var settings: RadioSettings { settingsBox.current }

    /// Brings up a fresh UDP socket to the radio from a known-clean state: connect,
    /// STOP, drain any in-flight/stale datagrams, then START so the USB sync word is
    /// realigned to offset 8. Returns the connected fd, or nil on socket/connect failure.
    ///
    /// A *brand-new* socket is the only reliable way to make the ANAN re-frame — a
    /// STOP/START on an already-streaming socket leaves the stream misaligned (the sync
    /// word drifts off offset 8 and decode fails for every receiver). This is shared by
    /// the initial connect and the mid-stream rebuild on slice-count change.
    private static func openStreamSocket(ip: String) -> Int32? {
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

        var drainTimeout = timeval(tv_sec: 0, tv_usec: 50_000)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &drainTimeout, socklen_t(MemoryLayout<timeval>.size))
        let stopPacket = HPSDRProtocol1.stopCommand()
        _ = stopPacket.withUnsafeBytes { send(socketFD, $0.baseAddress, $0.count, 0) }
        usleep(100_000)   // 100 ms for the radio to halt its stream
        var drain = [UInt8](repeating: 0, count: 2048)
        let drainDeadline = Date().addingTimeInterval(0.4)
        while Date() < drainDeadline {
            let n = drain.withUnsafeMutableBytes { recv(socketFD, $0.baseAddress, $0.count, 0) }
            if n <= 0 { break }   // socket empty (recv timed out) → pipe is clear
        }

        var rcvTimeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &rcvTimeout, socklen_t(MemoryLayout<timeval>.size))

        // Send Metis START (I/Q streaming).
        let startPacket = HPSDRProtocol1.startCommand(iq: true)
        _ = startPacket.withUnsafeBytes { send(socketFD, $0.baseAddress, $0.count, 0) }
        return socketFD
    }

    /// Opens the socket, sends Metis start, and begins the stream loop.
    func start() throws {
        guard fd < 0 else { return } // already started

        guard let socketFD = Self.openStreamSocket(ip: radio.ipAddress) else {
            throw DiscoveryError.socketCreationFailed(errno)
        }

        self.fd = socketFD
        running.set(true)

        // Open the active slices' WDSP receiver channels and the transmitter.
        for i in 0..<activeSliceCount { engines[i].wdsp.open(mode: currentMode) }
        wdspTx.open(mode: currentMode)

        // Start the audio mixer over the active slices. If it fails, streaming still
        // proceeds (silent).
        let mix = SliceAudioMixer(deviceUID: audioOutputUID)
        for i in 0..<activeSliceCount {
            mix.setSlice(i, ring: engines[i].ring, pan: engines[i].pan, enabled: true)
        }
        try? mix.start()
        self.mixer = mix

        // Launch the combined send/receive loop on a dedicated thread.
        let box = settingsBox
        let flag = running
        let continuation = updateContinuation
        let sliceEngines = engines
        let txEngine = wdspTx
        let txState = transmit
        let micBuffer = micRing
        dspCommands.clear()   // drop anything queued while disconnected
        let commands = dspCommands
        let socket = socketBox
        let thread = Thread {
            RadioConnection.runLoop(socket: socket, settings: box, running: flag,
                                    updates: continuation, engines: sliceEngines,
                                    wdspTx: txEngine, transmit: txState,
                                    micRing: micBuffer, commands: commands)
        }
        thread.name = "RadioConnection.IO"
        thread.stackSize = 512 * 1024
        self.worker = thread
        thread.start()
    }

    /// Sends Metis stop, tears down the loop, and closes the socket.
    func stop() {
        guard fd >= 0 else { return }
        running.set(false)
        let stopPacket = HPSDRProtocol1.stopCommand()
        _ = stopPacket.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        close(fd)
        fd = -1
        worker = nil
        for engine in engines { engine.wdsp.close() }
        wdspTx.close()
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
    private func dsp(_ command: @escaping @Sendable () -> Void) {
        guard fd >= 0 else { return }
        dspCommands.enqueue(command)
    }

    /// Enqueues a WDSP RX operation for a specific slice's channel.
    private func runOnSlice(_ index: Int, _ op: @escaping @Sendable (WDSPRadio) -> Void) {
        guard engines.indices.contains(index) else { return }
        let engines = self.engines
        dsp { op(engines[index].wdsp) }
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
            engines[slice].ring.clear()
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

    /// RX 3-band graphic EQ.
    func setRXEQ(on: Bool, slice: Int = 0) { runOnSlice(slice) { $0.setEQ(on: on) } }
    func setRXEQGains(preamp: Int, low: Int, mid: Int, high: Int, slice: Int = 0) {
        runOnSlice(slice) { $0.setEQGains(preamp: preamp, low: low, mid: mid, high: high) }
    }

    /// Sets the 7-bit open-collector output pattern (amp band data). Applied on the
    /// next config command frame (a few ms).
    func setOpenCollector(_ value: UInt8) {
        var s = settingsBox.current
        s.openCollector = value
        settingsBox.current = s
    }

    /// Sets a slice's CW sidetone pitch (Hz).
    func setCWPitch(_ hz: Double, slice: Int = 0) { runOnSlice(slice) { $0.setCWPitch(hz) } }

    /// Sets a slice's CW filter width in Hz.
    func setFilterWidth(_ width: Double, slice: Int = 0) { runOnSlice(slice) { $0.setFilterWidth(width) } }

    /// Sets a slice's SSB/DIGI low-cut edge (Hz).
    func setLowCut(_ hz: Double, slice: Int = 0) { runOnSlice(slice) { $0.setLowCut(hz) } }

    /// Sets a slice's high-cut / bandwidth edge (Hz).
    func setHighCut(_ hz: Double, slice: Int = 0) { runOnSlice(slice) { $0.setHighCut(hz) } }

    /// Sets a slice's audio volume (0…1).
    func setVolume(_ volume: Float, slice: Int = 0) { runOnSlice(slice) { $0.setVolume(volume) } }

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
        try? mix.start()
        mixer = mix
    }

    /// AGC time-constant profile (0 off … 4 fast).
    func setAGCMode(_ mode: Int, slice: Int = 0) { runOnSlice(slice) { $0.setAGCMode(mode) } }
    /// AGC-T: maximum AGC gain in dB.
    func setAGCTop(_ db: Double, slice: Int = 0) { runOnSlice(slice) { $0.setAGCTop(db) } }

    /// RX ADC step attenuator (0–31 dB; 0 = max gain). Applied on the next command frame.
    func setRXAttenuator(_ db: UInt8) {
        var s = settingsBox.current
        s.rxAttenuator = db
        settingsBox.current = s
    }

    /// Noise reduction controls (RXA DSP), per slice. Applied live; restored on reconnect.
    func setSpectralNR(_ on: Bool, slice: Int = 0) { runOnSlice(slice) { $0.setSpectralNR(on) } }
    func setSpectralNRGainMethod(_ method: Int, slice: Int = 0) { runOnSlice(slice) { $0.setSpectralNRGainMethod(method) } }
    func setSpectralNRNPEMethod(_ method: Int, slice: Int = 0) { runOnSlice(slice) { $0.setSpectralNRNPEMethod(method) } }
    func setSpectralNRArtifactReduction(_ on: Bool, slice: Int = 0) { runOnSlice(slice) { $0.setSpectralNRArtifactReduction(on) } }
    func setANR(_ on: Bool, slice: Int = 0) { runOnSlice(slice) { $0.setANR(on) } }
    func setANRStrength(_ taps: Int, slice: Int = 0) { runOnSlice(slice) { $0.setANRStrength(taps) } }
    func setANF(_ on: Bool, slice: Int = 0) { runOnSlice(slice) { $0.setANF(on) } }
    func setNoiseBlanker(_ on: Bool, slice: Int = 0) { runOnSlice(slice) { $0.setNoiseBlanker(on) } }
    func setNoiseBlankerThreshold(_ threshold: Double, slice: Int = 0) { runOnSlice(slice) { $0.setNoiseBlankerThreshold(threshold) } }
    func setNoiseBlanker2(_ on: Bool, slice: Int = 0) { runOnSlice(slice) { $0.setNoiseBlanker2(on) } }
    func setNoiseBlanker2Mode(_ mode: Int, slice: Int = 0) { runOnSlice(slice) { $0.setNoiseBlanker2Mode(mode) } }
    func setNoiseBlanker2Threshold(_ threshold: Double, slice: Int = 0) { runOnSlice(slice) { $0.setNoiseBlanker2Threshold(threshold) } }

    /// Tunes receiver `index` to `hz`. Applied on the next outgoing EP2 frame.
    func setFrequency(_ hz: UInt32, receiver index: Int = 0) {
        var s = settingsBox.current
        while s.receiverFrequencies.count <= index { s.receiverFrequencies.append(hz) }
        s.receiverFrequencies[index] = hz
        if index == 0 { s.transmitFrequency = hz }
        settingsBox.current = s
        if engines.indices.contains(index) { engines[index].ring.clear() }
    }

    /// Changes the number of active receive slices (1…maxSlices, clamped to what the
    /// hardware/protocol supports). Opens/closes DSP channels and updates the mixer live.
    func setActiveSliceCount(_ count: Int) {
        let n = max(1, min(Self.maxSlices, count))
        var s = settingsBox.current
        s.receiverCount = n
        while s.receiverFrequencies.count < n {
            s.receiverFrequencies.append(s.receiverFrequencies.last ?? 7_100_000)
        }
        settingsBox.current = s

        let previous = activeSliceCount
        activeSliceCount = n
        NSLog("Slices: \(previous) -> \(n) (streaming: \(fd >= 0))")
        guard fd >= 0 else { return }   // not streaming: start() opens the right count

        // Open/close the WDSP channels on the DSP thread (see `dsp`). The mixer is
        // independently locked, so its (de)registration is safe to enqueue alongside.
        // Existing slices' WDSP channels are left untouched, so their mode/filter/AGC/NR
        // settings survive the change — only the added/removed channels are (un)opened.
        let engines = self.engines
        let mixer = self.mixer
        let mode = currentMode
        let ip = radio.ipAddress
        let socket = socketBox
        dsp {
            // Adjust the per-slice WDSP channels for the new count.
            if n > previous {
                for i in previous..<n {
                    engines[i].wdsp.open(mode: mode)
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
            // word drifts off offset 8 and decode dies for EVERY receiver. A STOP/START on
            // the existing socket does NOT fix it — only a brand-new socket makes the radio
            // re-frame (verified: a fresh connect at N receivers works, an in-place restart
            // does not). So swap in a fresh socket here. settingsBox.receiverCount is already
            // updated, so the config frames sent right after START carry the new count and
            // the radio frames the new layout aligned from a clean boundary — exactly like a
            // fresh connect. Runs on the I/O thread; the run loop reads the new fd from the
            // box on its next iteration.
            let old = socket.current
            let stop = HPSDRProtocol1.stopCommand()
            _ = stop.withUnsafeBytes { send(old, $0.baseAddress, $0.count, 0) }
            close(old)
            if let newFD = RadioConnection.openStreamSocket(ip: ip) {
                socket.current = newFD
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
                                commands: DSPCommandQueue) {
        var seqOut: UInt32 = 0
        var slotCounter = 0

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
        var lastSeqIn: UInt32 = 0
        var haveLastSeq = false
        var lastStatus = RadioStreamStatus()
        // Diagnostics: per-second decoded sample counts per slice (healthy ≈ 96000/s each).
        var dbgRx0Samples = 0
        var dbgRx1Samples = 0
        var dbgRxCount = 0
        var dbgFlushCount = 0
        var dbgGaps = 0
        var dbgReceived = 0
        var dbgHdr = "?"
        var dbgSync = "?"

        while running.get() {
            // Apply any queued WDSP operations (channel open/close, DSP control changes)
            // here — on this thread — so they never run concurrently with fexchange0.
            // A command may swap the socket (mid-stream rebuild), so read fd afterward.
            for command in commands.drain() { command() }
            let fd = socket.current

            let settingsSnapshot = settings.current
            let transmitting = transmit.transmitting
            let tuning = transmit.tune

            // Receive one EP6 datagram (blocks up to the socket timeout).
            var buffer = [UInt8](repeating: 0, count: 2048)
            let received = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if received > 522 {
                dbgReceived = Int(received)
                dbgHdr = String(format: "%02X %02X %02X %02X", buffer[0], buffer[1], buffer[2], buffer[3])
                // Scan the whole datagram for the 7F 7F 7F USB sync word and report
                // every offset it appears at (should be 8 and 520 in a standard frame).
                var offsets: [Int] = []
                var i = 0
                let limit = Int(received) - 2
                while i < limit {
                    if buffer[i] == 0x7F && buffer[i + 1] == 0x7F && buffer[i + 2] == 0x7F {
                        offsets.append(i)
                        if offsets.count >= 6 { break }
                    }
                    i += 1
                }
                dbgSync = offsets.isEmpty ? "NONE" : offsets.map(String.init).joined(separator: ",")
            }
            if received > 0,
               let result = HPSDRFrame.parseEP6(Array(buffer.prefix(Int(received))),
                                                receiverCount: settingsSnapshot.receiverCount) {
                packetsInInterval += 1
                if haveLastSeq && result.sequence != lastSeqIn &+ 1 { gapsInInterval += 1 }
                lastSeqIn = result.sequence
                haveLastSeq = true
                lastStatus = result.status
                // While transmitting, skip the receive DSP so the send loop keeps full rate.
                if !transmitting {
                    let span = settingsSnapshot.sampleRate.hertz
                    let rxCount = min(result.receivers.count, engines.count)
                    for rx in 0..<rxCount {
                        let iq = result.receivers[rx]
                        engines[rx].wdsp.process(iq: iq, inputRate: span)
                        let centerHz = rx < settingsSnapshot.receiverFrequencies.count
                            ? settingsSnapshot.receiverFrequencies[rx] : 0
                        engines[rx].analyzer.ingest(iq, centerHz: centerHz, spanHz: span)
                    }
                    // RMS from slice 0 drives the summary signal meter.
                    let s0 = result.samples
                    var k = 0
                    while k < s0.count { rmsAccum += Double(s0[k]) * Double(s0[k]); k += 1 }
                    sampleCount += s0.count
                    dbgRxCount = rxCount
                    dbgRx0Samples += s0.count
                    if rxCount > 1 { dbgRx1Samples += result.receivers[1].count }
                }
            }

            // Send one EP2 for every EP6 cycle so the radio's TX FIFO stays fed at the
            // full sample rate — otherwise the transmit carrier pulses instead of being steady.
            var sendSettings = settingsSnapshot
            sendSettings.mox = transmitting
            sendSettings.drive = transmitting ? transmit.drive : 0
            let slots = sendSettings.commandSlotCount

            let ep2: [UInt8]
            if transmitting && tuning {
                // Steady tune carrier: phase-continuous complex sinusoid.
                let amp: Float = 0.6
                for s in 0..<126 {
                    tuneFrame[s * 2] = amp * Float(cos(tunePhase))
                    tuneFrame[s * 2 + 1] = amp * Float(sin(tunePhase))
                    tunePhase += tuneDelta
                    if tunePhase > 2 * Double.pi { tunePhase -= 2 * Double.pi }
                }
                ep2 = HPSDRFrame.buildEP2(sequence: seqOut, settings: sendSettings,
                                          slot1: slotCounter % slots, slot2: (slotCounter + 1) % slots,
                                          txIQ: tuneFrame)
            } else if transmitting {
                // Voice transmit: feed microphone audio through WDSP TXA. Guard the
                // refill on `running` and on an empty block so a teardown that closes
                // the TXA channel mid-transmit can't spin this loop forever.
                while running.get(), txBuffer.count - txPos < 252 {
                    var mic = txSilence
                    _ = mic.withUnsafeMutableBufferPointer {
                        micRing.read(into: $0.baseAddress!, count: WDSPTransmit.bufferSize)
                    }
                    let block = wdspTx.processBlock(mic: mic)
                    if block.isEmpty { break }
                    txBuffer.append(contentsOf: block)
                }
                let frameIQ: [Float]
                if txBuffer.count - txPos >= 252 {
                    frameIQ = Array(txBuffer[txPos ..< txPos + 252])
                    txPos += 252
                    if txPos > 8192 { txBuffer.removeFirst(txPos); txPos = 0 }
                } else {
                    // Channel closed during teardown: send a silent frame, never slice past the end.
                    frameIQ = [Float](repeating: 0, count: 252)
                }
                ep2 = HPSDRFrame.buildEP2(sequence: seqOut, settings: sendSettings,
                                          slot1: slotCounter % slots, slot2: (slotCounter + 1) % slots,
                                          txIQ: frameIQ)
            } else {
                if txPos != 0 || !txBuffer.isEmpty { txBuffer.removeAll(keepingCapacity: true); txPos = 0 }
                ep2 = HPSDRFrame.buildEP2(sequence: seqOut, settings: sendSettings,
                                          slot1: slotCounter % slots, slot2: (slotCounter + 1) % slots)
            }
            slotCounter += 2
            seqOut &+= 1
            _ = ep2.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }

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
                if dbgFlushCount >= 10 {   // ~1×/sec
                    NSLog("DSP: rxCount=\(dbgRxCount) packetRate=\(pps)/s gaps=\(dbgGaps)/s rx0decoded=\(dbgRx0Samples)/s rx1decoded=\(dbgRx1Samples)/s recv=\(dbgReceived) hdr=[\(dbgHdr)] sync=[\(dbgSync)]")
                    dbgFlushCount = 0
                    dbgGaps = 0
                    dbgRx0Samples = 0
                    dbgRx1Samples = 0
                }
                intervalStart = Date()
                packetsInInterval = 0
                gapsInInterval = 0
                rmsAccum = 0
                sampleCount = 0
            }
        }
    }
}

/// A thread-safe FIFO of WDSP operations queued by the actor and executed on the DSP
/// thread. Ensures all WDSP calls are serialized (WDSP is not thread-safe on macOS).
private nonisolated final class DSPCommandQueue: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var commands: [@Sendable () -> Void] = []

    func enqueue(_ command: @escaping @Sendable () -> Void) {
        os_unfair_lock_lock(&lock)
        commands.append(command)
        os_unfair_lock_unlock(&lock)
    }

    /// Atomically removes and returns all queued commands.
    func drain() -> [@Sendable () -> Void] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let pending = commands
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
    private var _drive: UInt8 = 0
    var transmitting: Bool {
        get { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return _transmitting }
        set { os_unfair_lock_lock(&lock); _transmitting = newValue; os_unfair_lock_unlock(&lock) }
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
