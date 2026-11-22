import Foundation
import Network
import VantageCore
import os

/// Accepts inbound Casement sessions: always from peers inside Tailscale's CGNAT/ULA ranges, and,
/// while Local Network Connections is on, from private and link-local addresses too (the home
/// network, a cable), which it then advertises over Bonjour as `_casement._tcp` with this Mac's
/// key fingerprint so a device finds it whatever its name or address. Binds on all interfaces and
/// validates the peer address at accept time (defence in depth even though ACLs should already
/// restrict the port to the tailnet). What a local peer may do is `SessionAdmission`'s to decide.
nonisolated final class TailscaleListener: @unchecked Sendable {
    /// What the Bonjour advertisement says, while local connections are on.
    struct LocalAdvertisement: Equatable {
        var fingerprint: String
        var platform: HostPlatform
    }

    private let log = Logger(subsystem: "com.benjaminlevinson.vantage.host", category: "listener")
    private let port: UInt16
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "vantage.listener")
    /// Set before `start`; nil keeps the listener on the tailnet only.
    var localAdvertisement: LocalAdvertisement?
    var onAccept: ((NWConnection, PeerReach) -> Void)?
    var onStateChange: ((NWListener.State) -> Void)?

    init(port: UInt16 = VantageProtocol.defaultPort) {
        self.port = port
    }

    func start() throws {
        let parameters = VantageNetwork.tcpParameters()
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        if let advertisement = localAdvertisement {
            // The service's name is the Mac's own (Sharing settings); the TXT record is what a
            // device matches on.
            let txt = NWTXTRecord([VantageNetwork.bonjourFingerprintKey: advertisement.fingerprint,
                                   VantageNetwork.bonjourProtocolKey: String(VantageProtocol.version),
                                   VantageNetwork.bonjourPlatformKey: advertisement.platform.rawValue])
            listener.service = NWListener.Service(type: VantageNetwork.bonjourServiceType, txtRecord: txt)
        }
        let acceptsLocal = localAdvertisement != nil
        listener.stateUpdateHandler = { [weak self] state in
            self?.onStateChange?(state)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.evaluate(connection, acceptsLocal: acceptsLocal)
        }
        listener.start(queue: queue)
        self.listener = listener
        log.info("listening on port \(self.port)\(acceptsLocal ? " (tailnet and local network)" : "", privacy: .public)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func evaluate(_ connection: NWConnection, acceptsLocal: Bool) {
        // For an inbound connection, `endpoint` is the remote peer and is known before start.
        log.info("inbound connection from \(String(describing: connection.endpoint), privacy: .public)")
        guard let reach = Self.reach(of: connection.endpoint, acceptsLocal: acceptsLocal) else {
            log.error("rejecting connection from outside the tailnet: \(String(describing: connection.endpoint), privacy: .public)")
            connection.cancel()
            return
        }
        log.info("accepting \(String(describing: reach), privacy: .public) connection")
        onAccept?(connection, reach)
    }

    static func reach(of endpoint: NWEndpoint, acceptsLocal: Bool) -> PeerReach? {
        guard case let .hostPort(host, _) = endpoint, let reach = PeerReach.classify(host) else { return nil }
        switch reach {
        case .tailnet: return .tailnet
        case .localNetwork: return acceptsLocal ? .localNetwork : nil
        case .loopback:
            #if DEBUG
            return .loopback
            #else
            // Release builds never take loopback: a local process must not be able to reach the
            // pairing prompt that way.
            return nil
            #endif
        }
    }
}
