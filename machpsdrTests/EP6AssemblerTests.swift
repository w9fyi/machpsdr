import Testing
import Foundation
@testable import machpsdr

/// Tests for the byte-stream EP6 reassembler. The ANAN-10E restarts its stream at
/// arbitrary byte offsets after STOP/START (observed live: sync at 322/834, then
/// 200/712), so the assembler must decode USB frames wherever the sync word lands
/// and carry partial frames across datagram boundaries.
@Suite struct EP6AssemblerTests {

    private let usbFrameSize = HPSDRProtocol1.usbFrameSize   // 512
    private let payloadSize = 1024                            // two frames per datagram

    /// One valid 512-byte USB frame (1 receiver): sync + C0–C4 header, then
    /// 63 groups of (I: 3, Q: 3, mic: 2) with every I sample set to `iValue`.
    private func makeUSBFrame(iValue: UInt8) -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: usbFrameSize)
        frame[0] = 0x7F; frame[1] = 0x7F; frame[2] = 0x7F
        var p = HPSDRProtocol1.usbHeaderSize
        while p + 8 <= usbFrameSize {
            frame[p + 2] = iValue   // low byte of the 24-bit I sample
            p += 8
        }
        return frame
    }

    /// Wraps 1024 stream bytes in a Metis EP6 datagram header.
    private func makeDatagram(sequence: UInt32, payload: ArraySlice<UInt8>) -> [UInt8] {
        var data: [UInt8] = [0xEF, 0xFE, 0x01, 0x06,
                             UInt8((sequence >> 24) & 0xFF), UInt8((sequence >> 16) & 0xFF),
                             UInt8((sequence >> 8) & 0xFF), UInt8(sequence & 0xFF)]
        data.append(contentsOf: payload)
        return data
    }

    /// A continuous stream of `count` frames with I = 1, 2, 3, … per frame.
    private func makeStream(frames count: Int) -> [UInt8] {
        var stream: [UInt8] = []
        for n in 1...count { stream.append(contentsOf: makeUSBFrame(iValue: UInt8(n))) }
        return stream
    }

    @Test func alignedStreamDecodesEveryFrame() {
        let assembler = EP6Assembler()
        let stream = makeStream(frames: 6)
        for (i, start) in stride(from: 0, to: stream.count, by: payloadSize).enumerated() {
            let datagram = makeDatagram(sequence: UInt32(i),
                                        payload: stream[start..<start + payloadSize])
            let out = assembler.feed(datagram, length: datagram.count, receiverCount: 1)
            #expect(out != nil)
            // Two complete frames per datagram, 63 groups × 2 floats each.
            #expect(out?.receivers[0].count == 252)
        }
        #expect(assembler.resyncs == 0)
    }

    @Test func shiftedStreamLocksOnSyncAndDecodes() {
        // Simulate the observed misframe: the radio starts packetizing 314 bytes
        // into a frame, so datagram offsets are 322/834 instead of 8/520.
        let shift = 314
        let assembler = EP6Assembler()
        let stream = makeStream(frames: 9)
        let shifted = Array(stream[shift...])

        var totalFloats = 0
        var decodedIValues: Set<Float> = []
        var seq: UInt32 = 0
        var start = 0
        while start + payloadSize <= shifted.count {
            let datagram = makeDatagram(sequence: seq,
                                        payload: shifted[start..<start + payloadSize])
            let out = assembler.feed(datagram, length: datagram.count, receiverCount: 1)
            #expect(out != nil)
            if let samples = out?.receivers[0] {
                totalFloats += samples.count
                // Every group's I sample is the frame's marker value.
                for k in stride(from: 0, to: samples.count, by: 2) {
                    decodedIValues.insert(samples[k] * 8_388_608.0)
                }
            }
            seq += 1
            start += payloadSize
        }
        // 4 datagrams cover shifted bytes 0..<4096: the partial first frame is
        // skipped, frames 2…8 complete within them (frame 9's tail is cut off).
        #expect(totalFloats == 7 * 126)
        #expect(decodedIValues == Set((2...8).map { Float($0) }))
        #expect(assembler.resyncs == 1)   // one hunt to lock, then contiguous
    }

    @Test func sequenceGapDropsPartialAndRelocks() {
        let assembler = EP6Assembler()
        let stream = makeStream(frames: 8)

        // First datagram aligned: decodes frames 1 and 2.
        let d0 = makeDatagram(sequence: 0, payload: stream[0..<payloadSize])
        let out0 = assembler.feed(d0, length: d0.count, receiverCount: 1)
        #expect(out0?.gap == false)
        #expect(out0?.receivers[0].count == 252)

        // Jump the sequence (lost datagrams): the assembler must flag the gap and
        // still decode the new, aligned payload in full.
        let d5 = makeDatagram(sequence: 5, payload: stream[2048..<2048 + payloadSize])
        let out5 = assembler.feed(d5, length: d5.count, receiverCount: 1)
        #expect(out5?.gap == true)
        #expect(out5?.receivers[0].count == 252)
    }

    @Test func junkStreamDecodesNothingWithoutCrashing() {
        let assembler = EP6Assembler()
        let junk = [UInt8](repeating: 0x55, count: payloadSize)
        let datagram = makeDatagram(sequence: 0, payload: junk[...])
        let out = assembler.feed(datagram, length: datagram.count, receiverCount: 1)
        #expect(out != nil)
        #expect(out?.receivers[0].isEmpty == true)
        #expect(assembler.resyncs > 0)
    }

    @Test func rejectsNonEP6Datagrams() {
        let assembler = EP6Assembler()
        var bad = makeDatagram(sequence: 0, payload: makeStream(frames: 2)[0..<payloadSize])
        bad[3] = 0x02   // wrong endpoint
        #expect(assembler.feed(bad, length: bad.count, receiverCount: 1) == nil)
    }

    @Test func twoReceiverInterleaveMatchesParseEP6() {
        // Aligned two-receiver decode must agree with the fixed-offset parser.
        var frame = [UInt8](repeating: 0, count: usbFrameSize)
        frame[0] = 0x7F; frame[1] = 0x7F; frame[2] = 0x7F
        var p = HPSDRProtocol1.usbHeaderSize
        while p + 14 <= usbFrameSize {
            frame[p + 2] = 1    // rx0 I low byte
            frame[p + 8] = 2    // rx1 I low byte
            p += 14
        }
        var payload = frame
        payload.append(contentsOf: frame)
        let datagram = makeDatagram(sequence: 7, payload: payload[...])

        let assembler = EP6Assembler()
        let out = assembler.feed(datagram, length: datagram.count, receiverCount: 2)
        let reference = HPSDRFrame.parseEP6(datagram, receiverCount: 2)
        #expect(out?.receivers[0] == reference?.receivers[0])
        #expect(out?.receivers[1] == reference?.receivers[1])
        #expect(out?.sequence == 7)
    }
}
