import Foundation
import Network
import Observation
import VantageCore
import os

/// Computers advertising Casement Host on the local network (`_casement._tcp`), by the
/// fingerprint of their key, so a saved computer is found again whatever its name or address is
/// today. Runs only while Settings → Local Network is on (browsing raises iOS's Local Network
/// prompt the first time). A fingerprint is only a hint: the handshake still has to prove the
/// key the device paired with, or the connection goes over Tailscale instead.
@MainActor
@Observable
final class LocalDiscovery {
    static let shared = LocalDiscovery()
    /// Settings → Local Network. Off by default.
    static let enabledKey = "vantage.localNetwork"

    private let log = Logger(subsystem: "com.benjaminlevinson.vantage", category: "discovery")
    private var browser: NWBrowser?
    /// Service endpoints by host key fingerprint, as advertised right now.
    private(set) var endpoints: [String: NWEndpoint] = [:]

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// Starts or stops browsing to match the setting (and whether the app is in front).
    func update(active: Bool) {
        let wanted = active && Self.isEnabled
        if wanted, browser == nil { start() } else if !wanted, browser != nil { stop() }
    }

    /// The local service for the computer whose key is `hostPublicKey`, if it's advertising.
    func endpoint(forHostKey hostPublicKey: Data) -> NWEndpoint? {
        guard browser != nil else { return nil }
        return endpoints[DeviceIdentity.fingerprint(of: hostPublicKey)]
    }

    private func start() {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: VantageNetwork.bonjourServiceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = Self.endpoints(in: results)
            Task { @MainActor in self?.endpoints = found }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                Task { @MainActor in self?.log.error("local discovery failed: \(error.localizedDescription, privacy: .public)") }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
        log.info("looking for computers on the local network")
    }

    private func stop() {
        browser?.cancel()
        browser = nil
        endpoints = [:]
    }

    nonisolated private static func endpoints(in results: Set<NWBrowser.Result>) -> [String: NWEndpoint] {
        var found: [String: NWEndpoint] = [:]
        for result in results {
            guard case .bonjour(let txt) = result.metadata, let fingerprint = txt[VantageNetwork.bonjourFingerprintKey],
                  txt[VantageNetwork.bonjourProtocolKey] == String(VantageProtocol.version) else { continue }
            found[fingerprint] = result.endpoint
        }
        return found
    }
}

/// One way to reach a saved computer, in the order to try them.
struct HostRoute: Sendable, CustomStringConvertible {
    let endpoint: NWEndpoint
    /// The local network or a cable: nothing but Casement's own encryption protects it, so the
    /// host must answer the key share (`ClientHandshake.requiresEncryption`).
    let isLocal: Bool
    /// Offer a key share: any route but one inside Tailscale (an older host ignores it).
    let offersEncryption: Bool

    var description: String { isLocal ? "local network" : "tailnet" }

    /// The computer's local service when it's advertising there under the key this device paired
    /// with, then its saved address. A computer this device hasn't connected to yet (no key on
    /// record) is only ever reached at its saved address: first pairing happens over Tailscale.
    static func candidates(for device: SavedDevice, port: NWEndpoint.Port, discovery: LocalDiscovery = .shared) -> [HostRoute] {
        var routes: [HostRoute] = []
        if let key = device.hostPublicKey, let local = discovery.endpoint(forHostKey: key) {
            routes.append(HostRoute(endpoint: local, isLocal: true, offersEncryption: true))
        }
        routes.append(saved(host: device.host, port: port))
        return routes
    }

    /// The saved address: local (and so required to be encrypted) when it's a private or
    /// link-local address; a Tailscale address or name goes as it always has.
    static func saved(host: String, port: NWEndpoint.Port) -> HostRoute {
        let name = NWEndpoint.Host(host)
        let local = VantageNetwork.isLocalNetworkAddress(name)
        return HostRoute(endpoint: .hostPort(host: name, port: port), isLocal: local, offersEncryption: !VantageNetwork.isTailscaleAddress(name))
    }

    /// How long a route gets to answer before the next is tried: a local service that went away
    /// a moment ago shouldn't hold up the Tailscale route for long.
    var connectTimeout: Duration { isLocal ? .seconds(4) : .seconds(15) }
}
