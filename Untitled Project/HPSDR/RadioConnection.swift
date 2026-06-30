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

/// Owns the live openHPSDR Protocol 1 connection to one radio: opens the socket,
/// sends the Metis start/stop, and runs the combined send-EP2 / receive-EP6 loop on a
/// background thread. Decoded status is delivered via the `updates` AsyncStream.
actor RadioConnection {
    let radio: DiscoveredRadio

    private var fd: Int32 = -1
    private let settingsBox: SettingsBox
    private var worker: Thread?
    private let running = RunningFlag()

    // Audio path: the network thread demodulates I/Q into `audioRing`,
    // which `audioOutput` drains on the CoreAudio render thread.
    private let audioRing = AudioRingBuffer()
    private var audioOutput: AudioOutput?
    /// Output device UID for received audio (nil = system default).
    private var audioOutputUID: String?
    private let wdsp: WDSPRadio
    private var currentMode: RadioMode = .usb

    // Transmit path: WDSP TXA turns mic/tone into TX I/Q that the send loop packs
    // into EP2 frames (with MOX + drive) while `transmit.transmitting` is true.
    private let wdspTx = WDSPTransmit()
    private let transmit = TransmitBox()
    private let micRing = AudioRingBuffer()
    private var audioInput: AudioInput?
    /// Input device UID for mic capture (nil = system default). Applied on key-down.
    private var micDeviceUID: String?

    /// Latest power spectrum for the panadapter/waterfall. `let` + Sendable, so the
    /// UI can read it synchronously without hopping onto the actor.
    let spectrum = SpectrumBuffer()
    private let analyzer: SpectrumAnalyzer

    private var updateContinuation: AsyncStream<StreamUpdate>.Continuation?
    /// Throttled stream of decoded status/metrics. Consume this to drive the UI.
    let updates: AsyncStream<StreamUpdate>

    init(radio: DiscoveredRadio, settings: RadioSettings = RadioSettings()) {
        self.radio = radio
        self.settingsBox = SettingsBox(settings)
        self.analyzer = SpectrumAnalyzer(buffer: spectrum)
        self.wdsp = WDSPRadio(ring: audioRing)
        var continuation: AsyncStream<StreamUpdate>.Continuation!
        self.updates = AsyncStream { continuation = $0 }
        self.updateContinuation = continuation
    }

    /// Current settings (frequency, sample rate, …).
    var settings: RadioSettings { settingsBox.current }

    /// Opens the socket, sends Metis start, and begins the stream loop.
    func start() throws {
        guard fd < 0 else { return } // already started

        let socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFD >= 0 else { throw DiscoveryError.socketCreationFailed(errno) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = HPSDRProtocol1.dataPort.bigEndian
        inet_pton(AF_INET, radio.ipAddress, &addr.sin_addr)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            let e = errno; close(socketFD); throw DiscoveryError.bindFailed(e)
        }
        var rcvTimeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &rcvTimeout, socklen_t(MemoryLayout<timeval>.size))

        // Send Metis START (I/Q streaming).
        let startPacket = HPSDRProtocol1.startCommand(iq: true)
        _ = startPacket.withUnsafeBytes { send(socketFD, $0.baseAddress, $0.count, 0) }

        self.fd = socketFD
        running.set(true)

        // Start audio output. If it fails, streaming still proceeds (silent).
        let output = AudioOutput(ring: audioRing, deviceUID: audioOutputUID)
        try? output.start()
        self.audioOutput = output

        // Open the WDSP receiver and transmitter channels with the current mode.
        wdsp.open(mode: currentMode)
        wdspTx.open(mode: currentMode)

        // Launch the combined send/receive loop on a dedicated thread.
        let box = settingsBox
        let flag = running
        let continuation = updateContinuation
        let engine = wdsp
        let spectrumAnalyzer = analyzer
        let txEngine = wdspTx
        let txState = transmit
        let micBuffer = micRing
        let thread = Thread {
            RadioConnection.runLoop(fd: socketFD, settings: box, running: flag,
                                    updates: continuation, wdsp: engine,
                                    analyzer: spectrumAnalyzer, wdspTx: txEngine, transmit: txState,
                                    micRing: micBuffer)
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
        wdsp.close()
        wdspTx.close()
        audioInput?.stop()
        audioInput = nil
        micRing.clear()
        audioOutput?.stop()
        audioOutput = nil
        audioRing.clear()
        updateContinuation?.finish()
    }

    /// Sets the demodulation mode (and the matching transmit mode).
    func setMode(_ mode: RadioMode) {
        currentMode = mode
        wdsp.setMode(mode)
        wdspTx.setMode(mode)
        audioRing.clear()
    }

    /// Keys/unkeys the transmitter. On key-down this starts mic capture and feeds it
    /// through WDSP TXA; on key-up it stops the mic.
    func setTransmit(_ on: Bool) {
        transmit.tune = false
        if on {
            // Start mic capture only while keyed (triggers the permission prompt on
            // first use; avoids touching the mic during receive).
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
        } else {
            audioInput?.stop()
            audioInput = nil
        }
        transmit.transmitting = on
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
        wdspTx.setMicGain(gain)
    }

    /// Selects the macOS input device (by UID) for mic capture; nil = system default.
    /// Takes effect on the next key-down.
    func setInputDevice(uid: String?) {
        micDeviceUID = uid
    }

    /// Enables/disables the WDSP speech processor (compressor) with a dB gain.
    func setSpeechProcessor(_ on: Bool, gain: Double) {
        wdspTx.setSpeechProcessor(on, gain: gain)
    }

    /// Sets the 7-bit open-collector output pattern (amp band data). Applied on the
    /// next config command frame (a few ms).
    func setOpenCollector(_ value: UInt8) {
        var s = settingsBox.current
        s.openCollector = value
        settingsBox.current = s
    }

    /// Sets the CW sidetone pitch (Hz).
    func setCWPitch(_ hz: Double) {
        wdsp.setCWPitch(hz)
    }

    /// Sets the CW filter width in Hz.
    func setFilterWidth(_ width: Double) {
        wdsp.setFilterWidth(width)
    }

    /// Sets the SSB/DIGI low-cut edge (Hz).
    func setLowCut(_ hz: Double) {
        wdsp.setLowCut(hz)
    }

    /// Sets the high-cut / bandwidth edge (Hz).
    func setHighCut(_ hz: Double) {
        wdsp.setHighCut(hz)
    }

    /// Sets the audio output volume (0…1).
    func setVolume(_ volume: Float) {
        wdsp.setVolume(volume)
    }

    /// Selects the macOS output device (by UID) for received audio; nil = system default.
    /// Re-routes immediately if currently streaming; otherwise applied when output starts.
    func setOutputDevice(uid: String?) {
        audioOutputUID = uid
        if audioOutput != nil {
            audioOutput?.stop()
            let output = AudioOutput(ring: audioRing, deviceUID: uid)
            try? output.start()
            audioOutput = output
        }
    }

    /// AGC time-constant profile (0 off … 4 fast).
    func setAGCMode(_ mode: Int) { wdsp.setAGCMode(mode) }
    /// AGC-T: maximum AGC gain in dB.
    func setAGCTop(_ db: Double) { wdsp.setAGCTop(db) }

    /// RX ADC step attenuator (0–31 dB; 0 = max gain). Applied on the next command frame.
    func setRXAttenuator(_ db: UInt8) {
        var s = settingsBox.current
        s.rxAttenuator = db
        settingsBox.current = s
    }

    /// Noise reduction controls (RXA DSP). Applied live; restored on reconnect by RadioSession.
    func setSpectralNR(_ on: Bool) { wdsp.setSpectralNR(on) }
    func setSpectralNRGainMethod(_ method: Int) { wdsp.setSpectralNRGainMethod(method) }
    func setSpectralNRNPEMethod(_ method: Int) { wdsp.setSpectralNRNPEMethod(method) }
    func setSpectralNRArtifactReduction(_ on: Bool) { wdsp.setSpectralNRArtifactReduction(on) }
    func setANR(_ on: Bool) { wdsp.setANR(on) }
    func setANRStrength(_ taps: Int) { wdsp.setANRStrength(taps) }
    func setANF(_ on: Bool) { wdsp.setANF(on) }
    func setNoiseBlanker(_ on: Bool) { wdsp.setNoiseBlanker(on) }
    func setNoiseBlankerThreshold(_ threshold: Double) { wdsp.setNoiseBlankerThreshold(threshold) }
    func setNoiseBlanker2(_ on: Bool) { wdsp.setNoiseBlanker2(on) }
    func setNoiseBlanker2Mode(_ mode: Int) { wdsp.setNoiseBlanker2Mode(mode) }
    func setNoiseBlanker2Threshold(_ threshold: Double) { wdsp.setNoiseBlanker2Threshold(threshold) }

    /// Tunes receiver `index` to `hz`. Applied on the next outgoing EP2 frame.
    func setFrequency(_ hz: UInt32, receiver index: Int = 0) {
        var s = settingsBox.current
        while s.receiverFrequencies.count <= index { s.receiverFrequencies.append(hz) }
        s.receiverFrequencies[index] = hz
        if index == 0 { s.transmitFrequency = hz }
        settingsBox.current = s
        audioRing.clear()
    }

    /// Changes the sample rate. Applied on the next outgoing EP2 frame.
    func setSampleRate(_ rate: HPSDRProtocol1.SampleRate) {
        var s = settingsBox.current
        s.sampleRate = rate
        settingsBox.current = s
    }

    // MARK: - Background I/O loop (runs off the actor)

    private static func runLoop(fd: Int32,
                                settings: SettingsBox,
                                running: RunningFlag,
                                updates: AsyncStream<StreamUpdate>.Continuation?,
                                wdsp: WDSPRadio,
                                analyzer: SpectrumAnalyzer,
                                wdspTx: WDSPTransmit,
                                transmit: TransmitBox,
                                micRing: AudioRingBuffer) {
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

        while running.get() {
            let settingsSnapshot = settings.current
            let transmitting = transmit.transmitting
            let tuning = transmit.tune

            // Receive one EP6 datagram (blocks up to the socket timeout).
            var buffer = [UInt8](repeating: 0, count: 2048)
            let received = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
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
                    var k = 0
                    while k < result.samples.count {
                        rmsAccum += Double(result.samples[k]) * Double(result.samples[k])
                        k += 1
                    }
                    sampleCount += result.samples.count
                    wdsp.process(iq: result.samples, inputRate: settingsSnapshot.sampleRate.hertz)
                    let centerHz = settingsSnapshot.receiverFrequencies.first ?? 0
                    analyzer.ingest(result.samples, centerHz: centerHz,
                                    spanHz: settingsSnapshot.sampleRate.hertz)
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
                intervalStart = Date()
                packetsInInterval = 0
                gapsInInterval = 0
                rmsAccum = 0
                sampleCount = 0
            }
        }
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
