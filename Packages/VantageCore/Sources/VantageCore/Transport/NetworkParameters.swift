import Foundation
import Network

public enum VantageNetwork {
    /// TCP parameters tuned for an interactive stream inside a WireGuard tunnel
    /// (MTU 1280): no Nagle, aggressive keepalive for fast dead-peer detection.
    public static func tcpParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 8
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.serviceClass = .interactiveVideo
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false
        return parameters
    }

    /// The session's file channel: the same TCP tuning, but marked as bulk background traffic so
    /// the stack (and any DSCP-aware hop) favours the main stream's video and input over it.
    public static func bulkParameters() -> NWParameters {
        let parameters = tcpParameters()
        parameters.serviceClass = .background
        return parameters
    }

    /// Tailscale's IPv4 range (CGNAT 100.64.0.0/10).
    public static func isTailscaleIPv4(_ address: IPv4Address) -> Bool {
        let bytes = address.rawValue
        guard bytes.count == 4 else { return false }
        return bytes[0] == 100 && (bytes[1] & 0xC0) == 0x40
    }

    /// Tailscale's IPv6 ULA range (fd7a:115c:a1e0::/48).
    public static func isTailscaleIPv6(_ address: IPv6Address) -> Bool {
        let bytes = address.rawValue
        guard bytes.count == 16 else { return false }
        return bytes[0] == 0xFD && bytes[1] == 0x7A && bytes[2] == 0x11 && bytes[3] == 0x5C && bytes[4] == 0xA1 && bytes[5] == 0xE0
    }

    /// Loopback (127.0.0.1 / ::1), used for same-machine sessions and local testing.
    public static func isLoopback(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let a): return a == .loopback
        case .ipv6(let a): return a == .loopback
        case .name(let n, _): return n == "localhost" || n == "127.0.0.1" || n == "::1"
        @unknown default: return false
        }
    }

    /// A peer the host may accept: on the tailnet, or loopback (same machine).
    public static func isAcceptablePeer(_ host: NWEndpoint.Host) -> Bool {
        isTailscaleAddress(host) || isLoopback(host)
    }

    public static func isTailscaleAddress(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let address):
            return isTailscaleIPv4(address)
        case .ipv6(let address):
            return isTailscaleIPv6(address)
        case .name(let name, _):
            if let v4 = IPv4Address(name) { return isTailscaleIPv4(v4) }
            if let v6 = IPv6Address(name) { return isTailscaleIPv6(v6) }
            return name.hasSuffix(".ts.net") || name.hasSuffix(".ts.net.")
        @unknown default:
            return false
        }
    }

    /// Enumerates local interface addresses that fall inside Tailscale's ranges.
    public static func localTailscaleAddresses() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard let sa = current.pointee.ifa_addr else { continue }
            let family = Int32(sa.pointee.sa_family)
            if family == AF_INET {
                var addr = sockaddr_in()
                memcpy(&addr, sa, MemoryLayout<sockaddr_in>.size)
                let raw = withUnsafeBytes(of: &addr.sin_addr) { Data($0) }
                if let v4 = IPv4Address(raw), isTailscaleIPv4(v4) {
                    addresses.append(v4.debugDescription)
                }
            } else if family == AF_INET6 {
                var addr = sockaddr_in6()
                memcpy(&addr, sa, MemoryLayout<sockaddr_in6>.size)
                let raw = withUnsafeBytes(of: &addr.sin6_addr) { Data($0) }
                if let v6 = IPv6Address(raw), isTailscaleIPv6(v6) {
                    addresses.append(v6.debugDescription)
                }
            }
        }
        return addresses
    }
}
