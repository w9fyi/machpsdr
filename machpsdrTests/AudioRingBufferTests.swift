import Testing
import Foundation
@testable import machpsdr

/// Tests for the single-producer / single-consumer float ring buffer:
/// underrun zero-fill, overrun dropping the oldest samples, and the
/// allocation-free pointer write overload used by the mic tap.
@Suite struct AudioRingBufferTests {

    /// Reads `count` samples into a Swift array via the pointer `read` API.
    private func read(_ ring: AudioRingBuffer, count: Int) -> (real: Int, samples: [Float]) {
        var out = [Float](repeating: .nan, count: count)
        let real = out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: count) }
        return (real, out)
    }

    @Test func writeThenReadRoundTrips() {
        let ring = AudioRingBuffer(capacity: 16)
        ring.write([1, 2, 3, 4])
        let (real, samples) = read(ring, count: 4)
        #expect(real == 4)
        #expect(samples == [1, 2, 3, 4])
    }

    @Test func underrunZeroFills() {
        let ring = AudioRingBuffer(capacity: 16)
        // Nothing written: a read must return 0 real samples and zero-fill.
        let (real, samples) = read(ring, count: 8)
        #expect(real == 0)
        #expect(samples == [Float](repeating: 0, count: 8))
    }

    @Test func partialReadZeroFillsShortfall() {
        let ring = AudioRingBuffer(capacity: 16)
        ring.write([5, 6])
        let (real, samples) = read(ring, count: 5)
        #expect(real == 2)                     // only 2 real samples were available
        #expect(samples == [5, 6, 0, 0, 0])    // remainder zero-filled
    }

    @Test func overrunDropsOldest() {
        let ring = AudioRingBuffer(capacity: 4)
        // Writing 6 into a capacity-4 ring should retain only the newest 4.
        ring.write([1, 2, 3, 4, 5, 6])
        let (real, samples) = read(ring, count: 4)
        #expect(real == 4)
        #expect(samples == [3, 4, 5, 6])       // 1 and 2 were dropped
    }

    @Test func pointerWriteOverload() {
        let ring = AudioRingBuffer(capacity: 16)
        let input: [Float] = [10, 20, 30]
        input.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: $0.count) }
        let (real, samples) = read(ring, count: 3)
        #expect(real == 3)
        #expect(samples == [10, 20, 30])
    }

    @Test func emptyWriteIsNoop() {
        let ring = AudioRingBuffer(capacity: 16)
        ring.write([])
        #expect(read(ring, count: 1).real == 0)
    }

    @Test func clearDiscardsBuffered() {
        let ring = AudioRingBuffer(capacity: 16)
        ring.write([1, 2, 3])
        ring.clear()
        let (real, samples) = read(ring, count: 3)
        #expect(real == 0)
        #expect(samples == [0, 0, 0])
    }

    @Test func wrapAroundPreservesOrder() {
        // Exercise index wrap: write past capacity in two passes, draining between.
        let ring = AudioRingBuffer(capacity: 4)
        ring.write([1, 2, 3])
        _ = read(ring, count: 2)          // consume 1,2 -> readIndex advances
        ring.write([4, 5, 6])             // wraps writeIndex around
        let (real, samples) = read(ring, count: 4)
        #expect(real == 4)
        #expect(samples == [3, 4, 5, 6])
    }
}
