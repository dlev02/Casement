import AppKit
import Foundation
import Network
import Observation
import VantageCore
import os

/// Top-level host runtime: owns the identity, trust store, listener, and active sessions.
/// Observable so the menu bar UI can reflect live status.
@MainActor
@Observable
final class HostController {
    enum Status: Equatable {
        case idle
        case listening
        case connected(clientCount: Int)
        case error(String)
    }

    private let log = Logger(subsystem: "com.benjaminlevinson.vantage.host", category: "controller")
    private let identity: DeviceIdentity
    let trust = TrustStore()
    private let listener = TailscaleListener()
    private var sessions: [HostSession] = []
    let loginItem = LoginItem()
    private var displayObservers: [any NSObjectProtocol] = []

    private(set) var status: Status = .idle
    private(set) var tailscaleRunning = false
    private(set) var tailscaleSelfName: String = ""
    private(set) var hasScreenPermission = false
    private(set) var hasInputPermission = false
    private(set) var trustedClients: [TrustStore.TrustedClient] = []
    private(set) var readiness: Readiness.Report?
    var pairingCode: String?

    var fingerprint: String { identity.fingerprint }

    init() {
        let keychain = KeychainStore(service: "com.benjaminlevinson.vantage.host")
        self.identity = (try? keychain.loadOrCreateIdentity()) ?? DeviceIdentity()
        trust.onChange = { [weak self] in
            Task { @MainActor in self?.refreshTrusted() }
        }
        refreshTrusted()
        refreshPermissions()
        refreshTailscale()
        refreshReadiness()
    }

    func start() {
        refreshPermissions()
        refreshTailscale()
        observeDisplayChanges()
        listener.onAccept = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.onStateChange = { [weak self] state in
            Task { @MainActor in self?.handleListenerState(state) }
        }
        do {
            try listener.start()
            status = .listening
        } catch {
            status = .error(error.localizedDescription)
            log.error("listener failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        listener.stop()
        sessions.removeAll()
        status = .idle
    }

    func refreshReadiness() {
        Task.detached {
            let report = Readiness.probe()
            await MainActor.run { self.readiness = report }
        }
    }

    /// Display wake / reconfiguration: rebuild capture on every active session.
    private func observeDisplayChanges() {
        guard displayObservers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        displayObservers.append(workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.restartSessions() }
        })
        displayObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.restartSessions() }
        })
    }

    private func restartSessions() {
        for session in sessions {
            Task { await session.restartCapture() }
        }
    }

    func generatePairingCode() {
        pairingCode = trust.newPairingCode()
    }

    func requestScreenPermission() {
        ScreenCapture.requestPermission()
        refreshPermissions()
    }

    func requestInputPermission() {
        InputInjector.requestPermission()
        refreshPermissions()
    }

    func revoke(_ fingerprint: String) {
        trust.revoke(fingerprint: fingerprint)
    }

    func openTailscaleAdmin() {
        NSWorkspace.shared.open(TailscaleCLI.adminConsoleURL)
    }

    private func accept(_ connection: NWConnection) {
        let peer = Self.describe(connection.endpoint)
        let channel = MessageChannel(connection: connection, label: "vantage.host.session")
        let session = HostSession(channel: channel, identity: identity, trust: trust, peerDescription: peer) { [weak self] ended in
            Task { @MainActor in self?.remove(ended) }
        }
        sessions.append(session)
        status = .connected(clientCount: sessions.count)
        log.info("session created for \(peer, privacy: .public)")
        Task { await session.run() }
    }

    private func remove(_ session: HostSession) {
        sessions.removeAll { $0 === session }
        status = sessions.isEmpty ? .listening : .connected(clientCount: sessions.count)
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .failed(let error):
            status = .error(error.localizedDescription)
            log.error("listener failed: \(error.localizedDescription, privacy: .public); retrying in 3s")
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                self.listener.stop()
                try? self.listener.start()
            }
        case .ready: if sessions.isEmpty { status = .listening }
        default: break
        }
    }

    private func refreshTrusted() {
        trustedClients = trust.trustedClients()
    }

    private func refreshPermissions() {
        hasScreenPermission = ScreenCapture.preflightPermission()
        hasInputPermission = InputInjector.hasPermission()
    }

    private func refreshTailscale() {
        Task.detached {
            let running = TailscaleCLI.isRunning()
            let name = (try? TailscaleCLI.status())?.selfNode?.dnsName ?? ""
            await MainActor.run {
                self.tailscaleRunning = running
                self.tailscaleSelfName = name.hasSuffix(".") ? String(name.dropLast()) : name
            }
        }
    }

    private static func describe(_ endpoint: NWEndpoint) -> String {
        if case let .hostPort(host, port) = endpoint {
            return "\(host):\(port)"
        }
        return String(describing: endpoint)
    }
}
