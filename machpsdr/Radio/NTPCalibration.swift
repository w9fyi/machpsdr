import Foundation
import Darwin

/// Cumulative count of decoded RX samples, written by the radio I/O thread and
/// sampled by the NTP calibrator. The radio's sample clock and NCO clock derive
/// from the same oscillator, so comparing the sample count against true (NTP)
/// elapsed time measures the oscillator's ppm error without any RF reference.
/// `discontinuities` increments whenever the count stops being continuous —
/// a sequence gap, a sample-rate change, or a socket rebuild — which invalidates
/// any measurement window spanning it.
nonisolated final class SampleClockCounter: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var samples: UInt64 = 0
    private var rateHz = 0
    private var discontinuities: UInt64 = 0

    /// Adds decoded complex samples for RX0. Call from the I/O thread only.
    func count(_ complexSamples: Int, rateHz rate: Int, gap: Bool) {
        os_unfair_lock_lock(&lock)
        if gap || rate != rateHz {
            discontinuities &+= 1
            rateHz = rate
        }
        samples &+= UInt64(complexSamples)
        os_unfair_lock_unlock(&lock)
    }

    /// Marks a break in continuity (socket swap / stream restart).
    func markDiscontinuity() {
        os_unfair_lock_lock(&lock)
        discontinuities &+= 1
        os_unfair_lock_unlock(&lock)
    }

    var snapshot: (samples: UInt64, rateHz: Int, discontinuities: UInt64) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return (samples, rateHz, discontinuities)
    }
}

/// Minimal SNTP (RFC 4330) client used by NTP frequency calibration. Queries are
/// blocking BSD-socket calls, so run them off the main actor (see `mapping`).
nonisolated enum SNTP {
    /// One server exchange reduced to a point mapping between the host's
    /// monotonic clock and NTP time, tagged with the effective round-trip time.
    struct Reading: Sendable {
        let monotonic: Double   // host CLOCK_UPTIME_RAW seconds at path midpoint
        let ntpTime: Double     // server (T2+T3)/2, seconds since the NTP epoch
        let rtt: Double
    }

    static func monotonicNow() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9
    }

    /// A robust (monotonic → NTP time) anchor from a burst of queries: keeps the
    /// lowest-RTT half and takes the median. Returns nil if the server can't be
    /// reached or answers fewer than 3 times.
    static func mapping(host: String, queries: Int = 8) async -> (monotonic: Double, ntp: Double)? {
        let readings = await Task.detached(priority: .utility) { () -> [Reading] in
            var collected: [Reading] = []
            for _ in 0..<queries {
                if let r = query(host: host) { collected.append(r) }
                usleep(250_000)   // pace the burst; public pools dislike hammering
            }
            return collected
        }.value
        guard readings.count >= 3 else { return nil }
        let best = readings.sorted { $0.rtt < $1.rtt }.prefix(max(3, readings.count / 2))
        // Project every reading's NTP time to a common monotonic reference point;
        // the median rejects outliers from asymmetric network delay.
        let reference = best.first!.monotonic
        let projected = best.map { $0.ntpTime + (reference - $0.monotonic) }.sorted()
        return (reference, projected[projected.count / 2])
    }

    /// One blocking SNTP exchange. Returns nil on any failure (resolution,
    /// timeout, malformed or kiss-of-death reply).
    static func query(host: String, timeoutSeconds: Double = 1.5) -> Reading? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "123", &hints, &res) == 0, let info = res else { return nil }
        defer { freeaddrinfo(res) }
        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeoutSeconds),
                         tv_usec: Int32((timeoutSeconds.truncatingRemainder(dividingBy: 1)) * 1e6))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 else { return nil }

        var packet = [UInt8](repeating: 0, count: 48)
        packet[0] = 0x23   // LI=0, VN=4, Mode=3 (client)
        let t1 = monotonicNow()
        guard packet.withUnsafeBytes({ send(fd, $0.baseAddress, 48, 0) }) == 48 else { return nil }
        var reply = [UInt8](repeating: 0, count: 48)
        let received = reply.withUnsafeMutableBytes { recv(fd, $0.baseAddress, 48, 0) }
        let t4 = monotonicNow()
        guard received == 48,
              reply[0] & 0x07 == 4,   // mode: server
              reply[1] != 0 else {    // stratum 0 = kiss-of-death
            return nil
        }
        let t2 = ntpTimestamp(reply, at: 32)   // server receive
        let t3 = ntpTimestamp(reply, at: 40)   // server transmit
        guard t3 > 0, t3 >= t2 else { return nil }
        let rtt = max(0, (t4 - t1) - (t3 - t2))
        return Reading(monotonic: (t1 + t4) / 2, ntpTime: (t2 + t3) / 2, rtt: rtt)
    }

    /// Decodes a 64-bit NTP timestamp (32.32 fixed point, big-endian) to seconds.
    private static func ntpTimestamp(_ bytes: [UInt8], at offset: Int) -> Double {
        let seconds = (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
        let fraction = (UInt32(bytes[offset + 4]) << 24) | (UInt32(bytes[offset + 5]) << 16)
            | (UInt32(bytes[offset + 6]) << 8) | UInt32(bytes[offset + 7])
        return Double(seconds) + Double(fraction) / 4_294_967_296.0
    }
}
