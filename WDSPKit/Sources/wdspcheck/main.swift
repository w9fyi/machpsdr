import CWDSP

// Smoke test: open a real WDSP receiver channel, configure it, run it, tear it
// down. Exercises FFTW planning and the macOS named-semaphore path at runtime.
print("Opening WDSP RXA channel…")
OpenChannel(0, 1024, 2048, 48000, 48000, 48000, 0, 0, 0.010, 0.025, 0.000, 0.010, 0)
SetRXAMode(0, 1)                       // 1 = USB
SetRXABandpassFreqs(0, 150, 2850)      // SSB passband
_ = SetChannelState(0, 1, 0)           // run
print("Channel running. Tearing down…")
_ = SetChannelState(0, 0, 1)
CloseChannel(0)
print("WDSP OK on macOS")
