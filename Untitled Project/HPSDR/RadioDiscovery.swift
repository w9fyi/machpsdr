import Foundation
import Darwin

/// Errors that can occur while discovering radios.
enum DiscoveryError: LocalizedError {
    case socketCreationFailed(Int32)
    case broadcastOptionFailed(Int32)
    case bindFailed(Int32)
    case sendFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .socketCreationFailed(let e): return "Could not create UDP socket (errno \(e))."
        case .broadcastOptionFailed(let e): return "Could not enable broadcast on socket (errno \(e))."
        case .bindFailed(let e): return "Could not bind discovery socket (errno \(e))."
        case .sendFailed(let e): return "Could not send discovery broadcast (errno \(e))."
        }
    }
}

/// Discovers ANAN / HPSDR radios on the local network using openHPSDR Protocol 1.
///
/// Protocol 1 discovery: broadcast a 63-byte packet beginning `0xEF 0xFE 0x02`
/// (rest zero) to UDP port 1024. Each radio replies with a packet whose byte 2 is
/// the status, bytes 3–8 the MAC address, byte 9 the firmware version, and byte 10
/// the board/device ID.
///
/// macOS rejects `sendto` to the global broadcast address 255.255.255.255 with
/// EADDRNOTAVAIL, so we enumerate the host's IPv4 interfaces and send to each
/// interface's subnet-directed broadcast address instead.
actor RadioDiscovery {
    static let discoveryPort: UInt16 = 1024
    private static let globalBroadcast: in_addr_t = 0xFFFF_FFFF // 255.255.255.255
    private static let anyAddress: in_addr_t = 0x0000_0000      // INADDR_ANY

    /// Broadcasts a discovery request and collects replies for `timeout` seconds.
    /// Performs blocking socket I/O on a background thread.
    func discover(timeout: TimeInterval = 2.0) async throws -> [DiscoveredRadio] {
        try await withCheckedThrowingContinuation { continuation in
            // Blocking BSD-socket work runs off the cooperative thread pool.
            Thread.detachNewThread {
                do {
                    let radios = try RadioDiscovery.performDiscovery(timeout: timeout)
                    continuation.resume(returning: radios)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func performDiscovery(timeout: TimeInterval) throws -> [DiscoveredRadio] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw DiscoveryError.socketCreationFailed(errno) }
        defer { close(fd) }

        var enable: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &enable,
                         socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw DiscoveryError.broadcastOptionFailed(errno)
        }
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enable,
                   socklen_t(MemoryLayout<Int32>.size))

        // Bind to an ephemeral local port so the radios' replies land back here.
        var localAddr = sockaddr_in()
        localAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        localAddr.sin_family = sa_family_t(AF_INET)
        localAddr.sin_addr.s_addr = anyAddress
        localAddr.sin_port = 0
        let bindResult = withUnsafePointer(to: &localAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw DiscoveryError.bindFailed(errno) }

        // Bound the time each recvfrom blocks so we can stop near the deadline.
        var rcvTimeout = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &rcvTimeout,
                   socklen_t(MemoryLayout<timeval>.size))

        // Discovery request: 0xEF 0xFE 0x02 followed by zeros, 63 bytes total.
        var packet = [UInt8](repeating: 0, count: 63)
        packet[0] = 0xEF
        packet[1] = 0xFE
        packet[2] = 0x02

        // Send to every interface's subnet broadcast; fall back to global broadcast.
        var destinations = subnetBroadcastAddresses()
        if destinations.isEmpty { destinations = [globalBroadcast] }

        var lastSendError: Int32 = 0
        var anySent = false
        for broadcast in destinations {
            var destAddr = sockaddr_in()
            destAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            destAddr.sin_family = sa_family_t(AF_INET)
            destAddr.sin_addr.s_addr = broadcast
            destAddr.sin_port = discoveryPort.bigEndian

            let sent = packet.withUnsafeBytes { raw in
                withUnsafePointer(to: &destAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, raw.baseAddress, raw.count, 0, $0,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if sent == packet.count {
                anySent = true
            } else {
                lastSendError = errno
            }
        }
        guard anySent else { throw DiscoveryError.sendFailed(lastSendError) }

        // Collect unique replies until the deadline passes.
        var radios: [DiscoveredRadio] = []
        var seenMACs = Set<String>()
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            var buffer = [UInt8](repeating: 0, count: 1032)
            var fromAddr = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let received = buffer.withUnsafeMutableBytes { raw in
                withUnsafeMutablePointer(to: &fromAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, raw.baseAddress, raw.count, 0, $0, &fromLen)
                    }
                }
            }
            // A negative result is a timeout (EAGAIN) or error; loop again until the deadline.
            guard received > 0 else { continue }

            if let radio = DiscoveredRadio(reply: buffer, from: fromAddr),
               seenMACs.insert(radio.macAddress).inserted {
                radios.append(radio)
            }
        }
        return radios
    }

    /// Computes the subnet-directed broadcast address for each up, non-loopback,
    /// broadcast-capable IPv4 interface (address | ~netmask).
    private static func subnetBroadcastAddresses() -> [in_addr_t] {
        var result: [in_addr_t] = []
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0 else { return result }
        defer { freeifaddrs(ifaddrPtr) }

        var cursor = ifaddrPtr
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard let addr = current.pointee.ifa_addr,
                  addr.pointee.sa_family == sa_family_t(AF_INET),
                  (flags & IFF_UP) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  (flags & IFF_BROADCAST) != 0 else {
                continue
            }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee.sin_addr.s_addr
            }
            var broadcast = globalBroadcast
            if let netmask = current.pointee.ifa_netmask {
                let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee.sin_addr.s_addr
                }
                broadcast = ip | ~mask
            }
            if !result.contains(broadcast) {
                result.append(broadcast)
            }
        }
        return result
    }
}
