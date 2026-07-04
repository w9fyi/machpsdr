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
/// Destination addresses matter more than the spec suggests:
/// - Metis-derived firmware (ANAN) answers subnet-directed broadcasts
///   (e.g. 192.168.1.255).
/// - The Hermes Lite 2 gateware ignores subnet-directed broadcasts; it only
///   answers packets addressed to 255.255.255.255 or to its own IP.
///
/// macOS rejects `sendto` to 255.255.255.255 with EADDRNOTAVAIL on a socket bound
/// to INADDR_ANY, but allows it once the socket is bound to a specific interface
/// address. So we open one socket per usable IPv4 interface, bind it to that
/// interface's address, and send the request to both 255.255.255.255 and the
/// interface's subnet-directed broadcast, then collect replies on all sockets.
actor RadioDiscovery {
    static let discoveryPort: UInt16 = 1024
    private static let globalBroadcast: in_addr_t = 0xFFFF_FFFF // 255.255.255.255
    private static let anyAddress: in_addr_t = 0x0000_0000      // INADDR_ANY

    /// An up, non-loopback, broadcast-capable IPv4 interface.
    private struct BroadcastInterface {
        let address: in_addr_t
        let subnetBroadcast: in_addr_t
    }

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
        var interfaces = broadcastInterfaces()
        if interfaces.isEmpty {
            // No interface info available; fall back to a wildcard-bound socket.
            interfaces = [BroadcastInterface(address: anyAddress, subnetBroadcast: globalBroadcast)]
        }

        // Discovery request: 0xEF 0xFE 0x02 followed by zeros, 63 bytes total.
        var packet = [UInt8](repeating: 0, count: 63)
        packet[0] = 0xEF
        packet[1] = 0xFE
        packet[2] = 0x02

        var fds: [Int32] = []
        defer { for fd in fds { close(fd) } }

        var lastSetupError = DiscoveryError.socketCreationFailed(0)
        var lastSendError: Int32 = 0
        var anySent = false

        for interface in interfaces {
            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else {
                lastSetupError = .socketCreationFailed(errno)
                continue
            }

            var enable: Int32 = 1
            guard setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &enable,
                             socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                lastSetupError = .broadcastOptionFailed(errno)
                close(fd)
                continue
            }
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enable,
                       socklen_t(MemoryLayout<Int32>.size))

            // Bind to the interface's own address on an ephemeral port. This both
            // makes sendto 255.255.255.255 legal on macOS and lands the radios'
            // replies back on this socket.
            var localAddr = sockaddr_in()
            localAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            localAddr.sin_family = sa_family_t(AF_INET)
            localAddr.sin_addr.s_addr = interface.address
            localAddr.sin_port = 0
            let bindResult = withUnsafePointer(to: &localAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0 else {
                lastSetupError = .bindFailed(errno)
                close(fd)
                continue
            }
            fds.append(fd)

            var destinations: [in_addr_t] = [globalBroadcast]
            if interface.subnetBroadcast != globalBroadcast {
                destinations.append(interface.subnetBroadcast)
            }
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
        }

        guard !fds.isEmpty else { throw lastSetupError }
        guard anySent else { throw DiscoveryError.sendFailed(lastSendError) }

        return collectReplies(on: fds, until: Date().addingTimeInterval(timeout))
    }

    /// Polls all discovery sockets until the deadline, deduplicating replies by MAC
    /// (a radio answers each broadcast it hears, so duplicates are expected).
    private static func collectReplies(on fds: [Int32], until deadline: Date) -> [DiscoveredRadio] {
        var radios: [DiscoveredRadio] = []
        var seenMACs = Set<String>()
        var pollFDs = fds.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }

        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            // Cap each wait so a poll error can't spin and a late start still ends on time.
            let waitMs = Int32(max(1, min(remaining * 1000, 250)))
            let ready = poll(&pollFDs, nfds_t(pollFDs.count), waitMs)
            guard ready > 0 else { continue }

            for i in pollFDs.indices where pollFDs[i].revents & Int16(POLLIN) != 0 {
                pollFDs[i].revents = 0
                var buffer = [UInt8](repeating: 0, count: 1032)
                var fromAddr = sockaddr_in()
                var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let received = buffer.withUnsafeMutableBytes { raw in
                    withUnsafeMutablePointer(to: &fromAddr) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            recvfrom(pollFDs[i].fd, raw.baseAddress, raw.count, 0, $0, &fromLen)
                        }
                    }
                }
                guard received > 0 else { continue }

                if let radio = DiscoveredRadio(reply: buffer, from: fromAddr),
                   seenMACs.insert(radio.macAddress).inserted {
                    radios.append(radio)
                }
            }
        }
        return radios
    }

    /// Enumerates up, non-loopback, broadcast-capable IPv4 interfaces with their
    /// subnet-directed broadcast address (address | ~netmask).
    private static func broadcastInterfaces() -> [BroadcastInterface] {
        var result: [BroadcastInterface] = []
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
            if !result.contains(where: { $0.address == ip }) {
                result.append(BroadcastInterface(address: ip, subnetBroadcast: broadcast))
            }
        }
        return result
    }
}
