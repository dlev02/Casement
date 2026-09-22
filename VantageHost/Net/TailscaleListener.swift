import Foundation
import Network
import VantageCore
import os

/// Accepts inbound Vantage sessions, but only from peers inside Tailscale's CGNAT/ULA ranges.
/// Binds on all interfaces and validates the peer address at accept time (defence in depth even
/// though ACLs should already restrict the port to the tailnet).
nonisolated final class TailscaleListener: @unchecked Sendable {
    private let log = Logger(subsystem: "com.benjaminlevinson.vantage.host", category: "listener")
    private let port: UInt16
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "vantage.listener")
    var onAccept: ((NWConnection) -> Void)?
    var onStateChange: ((NWListener.State) -> Void)?

    init(port: UInt16 = VantageProtocol.defaultPort) {
        self.port = port
    }

    func start() throws {
        let parameters = VantageNetwork.tcpParameters()
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener.stateUpdateHandler = { [weak self] state in
            self?.onStateChange?(state)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.evaluate(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
        log.info("listening on port \(self.port)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func evaluate(_ connection: NWConnection) {
        // For an inbound connection, `endpoint` is the remote peer and is known before start.
        log.info("inbound connection from \(String(describing: connection.endpoint), privacy: .public)")
        guard isTailnetPeer(connection.endpoint) else {
            log.error("rejecting non-tailnet connection: \(String(describing: connection.endpoint), privacy: .public)")
            connection.cancel()
            return
        }
        log.info("accepting tailnet connection")
        onAccept?(connection)
    }

    private func isTailnetPeer(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        return VantageNetwork.isAcceptablePeer(host)
    }
}
