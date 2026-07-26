# machpsdr ↔ Thetis Feature Parity Checklist

Target: feature parity with Thetis 2.10.3.15 (ramdor/Thetis — archived May 2026, so this
target is frozen), scoped to what an ANAN-10E can actually do, with first-class macOS
accessibility as the differentiator.

Legend: ✅ implemented in machpsdr · ⬜ to do · ➖ not applicable to the ANAN-10E
`[WDSP]` = DSP already compiled in WDSPKit, needs Swift wrapper + UI only.
`[FW]` = depends on radio firmware/protocol support.

## 1. RX DSP

- ✅ NR (ANR/LMS) — strength exposed; leakage/taps/delay/gain fine-controls ⬜ `[WDSP]`
- ✅ NR2 (EMNR) — gain method, NPE method, artifact reduction; ⬜ pre/post-AGC position
- ⬜ NR3 (RNNoise) — needs vendored rnnoise lib (not in WDSP)
- ⬜ NR4 (libspecbleach) — needs vendored lib (not in WDSP)
- ✅ ANF auto-notch
- ✅ NB (ANB) with threshold
- ✅ NB2 (NOB) with 5 fill modes + threshold
- ✅ SNB spectral noise blanker (SNBA)
- ✅ AGC modes + AGC-T; ⬜ Custom mode (slope/attack/decay/hang), on-panadapter AGC lines
- ✅ Variable filters (width / low-high per mode); ⬜ Var1/Var2 memories, drag filter edges
- ✅ APF CW peaking filter (on/off + bandwidth, peaks at CW pitch); WDSP SPCW —
  was already compiled and chained in RXA, just needed exposing. ⬜ design/gain UI
- ✅ MNF manual notch filters — add/remove/toggle at absolute RF, frequency-tracking,
  persisted across launches
- ✅ Squelch — AM/SAM level squelch (AMSQ) + FM squelch (FMSQ), mode-aware, with a
  0–100 level; ⬜ SSB voice squelch (SSQL is not in the vendored WDSP build)
- ✅ RX EQ (3-band); ⬜ parametric 5/10/18-band with Q
- ➖ Diversity reception (10E has a single ADC)
- ✅ Binaural (BIN) rendering — Slice A, interleaved-stereo ring into the mixer
  (live verify pending)
- ✅ AM/SAM sideband select (Both/LSB/USB, `SetRXAAMDSBMode`) — Sideband picker
  appears with the AM/SAM bandwidth filter (live verify pending)
- ✅ Per-slice stereo pan

## 2. TX

WDSP TX chain (parity spec): phase rotator → mic meter → DEXP → pre-EQ → Leveler →
CFC (+post-EQ) → bandpass → COMP → aux bandpass → CESSB.

- ✅ COMP compressor (via presets); ⬜ direct gain control UI
- ✅ CESSB (DX+ preset)
- ✅ CFC continuous frequency compressor (on/off, pre-comp, post-EQ; uses WDSP's
  default band profile); ⬜ per-band gain editing UI
- ✅ TX EQ (3-band); ⬜ parametric bands, pre/post-CFC position
- ⬜ DEXP downward expander / noise gate `[WDSP: dexp]`
- ⬜ VOX (threshold/delay driving PTT)
- ⬜ Mic boost +20 dB toggle
- ✅ TX filter low/high (sideband-aware)
- ⬜ TX monitor (MON — hear own processed audio)
- ⬜ Transmit profiles (named, per-mode auto-switch, import/export)
- ✅ Leveler (on/off + max-gain ceiling) `[WDSP]`
- ✅ Phase rotator (on/off) `[WDSP]`
- ⬜ Voice keyer / wave playback + macros
- ✅ PureSignal (Single Cal) — implemented per piHPSDR's P1 mapping for the
  10E/100B: RX1 = RF sampler, RX2 = TX DAC feedback (HL2: RX3/RX4), both NCOs
  follow TX frequency during MOX; feedback → WDSP `pscc`/calcc, iqc correction in
  TXA. Arm requires 192 kHz + 2 slices (10E). Single Cal only — continuous cal
  shows the known picket-fence artifact on 10E-class boards. On-air verify pending.
  Crosstalk path works on many (not all) bands; clean path is an external coupler
  (e.g. TAPR TR-Plus). ⬜ save/restore correction (PSSaveCorr), auto-attenuation

## 3. CW

- ✅ CW-U/CW-L modes, pitch, width; sidetone is radio-generated
- ⬜ Keyer parameters to firmware: iambic A/B, speed, weight, reverse paddles `[FW bits in P1 command stream]`
- ⬜ Semi break-in with delay
- ➖ QSK full break-in (Orion-class firmware only)
- ⬜ CWX keyboard CW + macros
- ⬜ Software sidetone option (low latency)

## 4. Display

- ✅ Panadapter + waterfall (per-slice, stacked); click-to-tune
- ⬜ More display modes: Panafall split, Spectrum line, Scope, Phase, Histogram
- ✅ Exponential averaging; ⬜ selectable averaging modes (time-window/recursive/log) +
  detector modes (Peak/Rosenfell/Average/Sample)
- ⬜ Zoom / pan over acquired bandwidth
- ⬜ CTUN (fixed panadapter, movable VFO)
- ⬜ dB grid labels, band-edge markers, TX passband overlay, DX spots
- ⬜ Wideband display (0–61 MHz bandscope, EP4). ✅ EP4 probe (Live Stream ▸
  Wideband Probe) counts arriving frames — whether the 10E's shrunken EP3C25
  firmware kept the bandscope is unverified; run the probe to find out
- ⬜ Waterfall palettes (custom gradients), auto floor, speed control
- ⬜ TX spectral display during MOX; pause/freeze
- ⬜ Metal rendering for high-FPS/zoom (current: CPU Canvas + CGImage)

## 5. Operating

- ✅ VFO A/B (A→B, A⇄B swap; VFO B field in Tuning); ⬜ lock, sync
- ✅ Split (TX on VFO B) — also over CAT (FT0/FT1, FB); live verify pending
- ✅ RIT / XIT (±2 kHz sliders; RIT shifts Slice A RX NCO, XIT shifts TX NCO;
  CAT RT/XT/RU/RD/RC + IF fields); live verify pending
- ✅ Band buttons (12 bands via shortcuts); ⬜ band-stack registers (multi-entry cycling)
- ⬜ Memory channels (list, groups, quick-save/restore)
- ⬜ Tune step list + mouse-wheel tuning + snap-to-step (have: MIDI step tuning)
- ✅ MultiRX: independent slices with pan (exceeds Thetis's sub-RX model in some
  ways; 2-RX P1 framing fix pending live test). Hardware ceiling: the original
  10E's EP3C25 gateware has only 2 DDCs (ANAN-10: 7, HL2: 4) — a 3rd slice will
  never decode on the 10E
- ✅ Modes: LSB/USB/CWL/CWU/AM/SAM/FM/DIGL/DIGU; ⬜ DSB/SPEC/DRM, FM repeater offsets/CTCSS
- ✅ Mute; ⬜ per-slice mute buttons
- ✅ Step attenuator 0–31 dB
- ➖ Alex antenna selection (10E: single antenna path)
- ⬜ Apollo filter/ATU control bits (10E-relevant if ATU fitted) `[FW]`
- ⬜ XVTR transverter definitions
- ⬜ Per-band persistence (drive, filters, last frequency)

## 6. Metering

- ✅ Signal level (dBFS RMS) + packet health; ⬜ calibrated S-meter in dBm (needs level cal)
- ⬜ RX meters: S-meter, Signal Avg, ADC dBFS
- ⬜ TX meters: Fwd Power, Mic, EQ, Leveler, comp gain, ALC `[WDSP TX meters exist unwired]`
- ⬜ Fwd/Ref power + SWR: 10E has minimal Apollo-style sensing — expect forward-power-only
  accuracy; calibrate against an external meter. Per-band cal constants live in Thetis
  `console.cs` (unresolved research item — check source when implementing).
- ⬜ SWR protection (drive reduction on high SWR)
- ⬜ Accessible meter announcements (VoiceOver live values) — our differentiator

## 7. Integration / Control

- ✅ CAT server — Kenwood TS-2000 emulation (ID 019) over TCP (default port 13013):
  FA/FB/MD/IF/TX/RX/PC/AG/SM + ID/PS/AI/FR/FT; live-verified from a LAN client
  (drives the SPE 2K-FA via a Raspberry Pi bridge). Split/RIT/XIT now real:
  FT0/FT1 keys split, FB sets VFO B, RT/XT/RU/RD/RC drive RIT/XIT, IF carries
  offset + flags. ⬜ ZZxx extended set, PTY virtual serial, AI auto-information push
- ✅ MIDI tuning knob; ⬜ general MIDI mapping (buttons/knobs/wheels → commands)
- ⬜ TCI server (WebSocket; spots, audio/IQ streaming) — modern loggers/SDR tools speak it
- ⬜ Virtual audio routing (VAC equivalent) — macOS: Core Audio aggregate/driver or
  direct audio bridge to digimode apps
- ⬜ N1MM+ spectrum UDP feed (:13064)
- ✅ OC band-data pins (J16) per band — drives the SPE 2K-FA (exceeds Thetis: we auto-follow)
- ✅ HL2 N2ADR IO board TX-frequency feed (I2C regs 0–4 via C&C 0x3D, piHPSDR-compatible) —
  the board's m0hpf_spe firmware emits Yaesu FT-2000 CAT at 19200 to the 2K-FA
  (amp CAT menu: YAESU [FTxxxx 2007+]); live-verified
- ➖ Alex control, Andromeda/Odin panels
- ⬜ FT8/FT4 native decode + PSK Reporter (Thetis itself lacks this — differentiator)
- ⬜ FreeDV native (codec2) + FreeDV Reporter (differentiator)
- ⬜ Client/server remote operation (piHPSDR has it; Thetis doesn't — future differentiator)

## 8. Setup / Calibration

- ⬜ S-meter/spectrum level calibration (dB offset)
- ✅ Frequency calibration (PPM) — Settings ▸ Calibration: manual ppm entry plus
  one-click WWV auto-cal (offset-tunes clear of the DC spike, sub-bin parabolic peak
  measurement with SNR gate, tries 10/15/5/20 MHz); persisted, applied to all NCOs at
  encode time (display stays in true Hz). ✅ NTP sample-clock cal (no RF): counts
  decoded samples against SNTP anchors over 15 min (server picker: Apple/NIST/pool/
  custom LAN host), gap-aware with auto-restart. HL2 also gets the native −12…+48 dB
  LNA gain control in place of the ANAN step attenuator
- ⬜ ADC dither / random toggles `[FW bits, Hermes ADC]`
- ⬜ PA gain calibration per band (drive→watts)
- ⬜ Display calibration (grid min/max, per-band waterfall levels)
- ✅ Sample rates 48/96/192/384 kHz; ⬜ DSP buffer/filter size and filter type
  (linear-phase vs low-latency) options
- ⬜ Settings export/import (config backup)

## 9. Accessibility (our reason to exist — Thetis has none of this)

- ⬜ VoiceOver labels/values/hints on every control
- ⬜ Adjustable-action sliders with spoken values and sensible increments
- ⬜ Accessible panadapter alternative (spoken spectrum peaks, keyboard tuning)
- ⬜ Meter value announcements (polite live regions, configurable cadence)
- ⬜ Full keyboard operability audit; Dynamic Type where applicable
- ✅ Foundations: labeled PTT/mute, VoiceOver-safe picker styles, always-visible MIDI monitor
