import Testing
import Foundation
@testable import machpsdr

/// Tests for the NTP-calibration building blocks that don't need a network or
/// a radio: the sample-clock continuity counter.
@Suite struct NTPCalibrationTests {

    @Test func counterAccumulatesSamples() {
        let clock = SampleClockCounter()
        clock.count(63, rateHz: 48_000, gap: false)
        clock.count(63, rateHz: 48_000, gap: false)
        let snap = clock.snapshot
        #expect(snap.samples == 126)
        #expect(snap.rateHz == 48_000)
    }

    @Test func gapAndRateChangeBreakContinuity() {
        let clock = SampleClockCounter()
        clock.count(63, rateHz: 48_000, gap: false)
        let d0 = clock.snapshot.discontinuities
        clock.count(63, rateHz: 48_000, gap: true)          // lost datagram
        #expect(clock.snapshot.discontinuities == d0 + 1)
        clock.count(63, rateHz: 96_000, gap: false)         // rate change
        #expect(clock.snapshot.discontinuities == d0 + 2)
        clock.markDiscontinuity()                           // socket rebuild
        #expect(clock.snapshot.discontinuities == d0 + 3)
        // Samples still accumulate across breaks; windows spanning them are
        // invalidated by the discontinuity count, not by resetting the total.
        #expect(clock.snapshot.samples == 189)
    }

    @Test func steadyStreamStaysContinuous() {
        let clock = SampleClockCounter()
        clock.count(63, rateHz: 48_000, gap: false)
        let d0 = clock.snapshot.discontinuities
        for _ in 0..<1000 { clock.count(63, rateHz: 48_000, gap: false) }
        #expect(clock.snapshot.discontinuities == d0)
    }
}
