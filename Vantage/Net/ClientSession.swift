import Foundation
import Network
import Observation
import VantageCore
import os

/// Drives a client connection: TCP connect over Tailscale, Ed25519 handshake/pairing, then the
/// bidirectional message loop. Publishes connection state and hands decoded messages to observers.
@MainActor
@Observable
final class ClientSession {
    enum State: Equatable {
        case idle
        case connecting
        case pairingRequired
        case authenticating
        case connected
        case reconnecting
        case failed(String)
    }

    private let log = Logger(subsystem: "com.benjaminlevinson.vantage", category: "client")
    private let identity: DeviceIdentity
    private let deviceName: String
    private let deviceModel: String

    private(set) var state: State = .idle
    private(set) var displays: [DisplayInfo] = []
    private(set) var capabilities: HostCapabilities?
    private(set) var activeConfig: StreamConfig?
    private(set) var hostName: String = ""
    private(set) var peerTailnetName: String?
    private(set) var lastRTTMillis: Double = 0
    private(set) var hostStatus: HostStatus?

    private var channel: MessageChannel?
    private var device: SavedDevice?
    private var pairingCode: String?
    private var reconnectAttempts = 0
    private var explicitlyDisconnected = false

    /// Called with each decoded video message (config/frame) so the renderer can consume it.
    var onVideo: ((Message) -> Void)?
    var onCursor: ((CursorPosition) -> Void)?
    var onClipboard: ((ClipboardPayload) -> Void)?

    init() {
        let keychain = KeychainStore(service: "com.benjaminlevinson.vantage.client")
        self.identity = (try? keychain.loadOrCreateIdentity()) ?? DeviceIdentity()
        #if canImport(UIKit)
        self.deviceName = UIDevice.current.name
        self.deviceModel = ClientSession.hardwareModel()
        #else
        self.deviceName = Host.current().localizedName ?? "iPad"
        self.deviceModel = "iPad"
        #endif
    }

    var fingerprint: String { identity.fingerprint }

    func connect(to device: SavedDevice, viewport: Viewport, pairingCode: String? = nil) {
        self.device = device
        self.pairingCode = pairingCode
        explicitlyDisconnected = false
        reconnectAttempts = 0
        Task { await self.openConnection(viewport: viewport) }
    }

    /// Retries immediately (e.g. when the app returns to the foreground after a failure).
    func retryNow() {
        guard case .failed = state, device != nil else { return }
        reconnectAttempts = 0
        explicitlyDisconnected = false
        Task { await self.openConnection(viewport: currentViewport()) }
    }

    func disconnect() {
        explicitlyDisconnected = true
        Task { await self.channel?.close(); await MainActor.run { self.state = .idle } }
    }

    // MARK: Sending

    func send(_ message: Message) {
        channel?.sendDetached(message)
    }

    func selectDisplay(_ selection: DisplaySelection, targetFPS: Int, quality: QualityPreset) {
        let codec = device?.preferredCodec
        send(.selectDisplay(SelectDisplay(selection: selection, targetFPS: targetFPS, quality: quality, preferredCodec: codec)))
    }

    func sendFeedback(_ feedback: QualityFeedback) {
        send(.qualityFeedback(feedback))
    }

    func ping() {
        send(.ping(Ping(sentAtNanos: DispatchTime.now().uptimeNanoseconds)))
    }

    // MARK: Connection lifecycle

    private func openConnection(viewport: Viewport) async {
        guard let device else { return }
        state = reconnectAttempts == 0 ? .connecting : .reconnecting
        let host = NWEndpoint.Host(device.host)
        guard let port = NWEndpoint.Port(rawValue: device.port) else {
            state = .failed("Invalid port"); return
        }
        let connection = NWConnection(host: host, port: port, using: VantageNetwork.tcpParameters())
        let channel = MessageChannel(connection: connection, label: "vantage.client.session")
        self.channel = channel
        do {
            try await channel.start()
            try await handshake(channel: channel, viewport: viewport)
            reconnectAttempts = 0
            await messageLoop(channel: channel)
        } catch let error as ProtocolErrorMessage {
            state = .failed(error.message)
        } catch {
            log.error("connection error: \(error.localizedDescription)")
            await handleDrop(viewport: viewport)
        }
    }

    private func handshake(channel: MessageChannel, viewport: Viewport) async throws {
        let hello = Hello(clientName: deviceName, deviceModel: deviceModel, appVersion: "1.0",
                          clientPublicKey: identity.publicKeyData, supportedCodecs: [.hevc, .h264],
                          maxDecodeWidth: 4096, maxDecodeHeight: 2304, viewport: viewport)
        try await channel.send(.hello(hello))

        guard case let .challenge(challenge)? = try await channel.receive() else { throw ClientHandshakeError.badHandshake }
        hostName = challenge.hostName
        peerTailnetName = challenge.peerTailnetName
        state = .authenticating

        let signature = try identity.sign(AuthTranscript.bytes(nonce: challenge.nonce, hostPublicKey: challenge.hostPublicKey, clientPublicKey: identity.publicKeyData))
        let auth = Authenticate(signature: signature, pairingCode: challenge.isPaired ? nil : pairingCode)
        try await channel.send(.authenticate(auth))

        guard case let .authResult(result)? = try await channel.receive() else { throw ClientHandshakeError.badHandshake }
        switch result.status {
        case .ok:
            displays = result.displays ?? []
            capabilities = result.capabilities
            state = .connected
        case .pairingRequired, .badPairingCode:
            state = .pairingRequired
            throw ProtocolErrorMessage(code: result.status.rawValue, message: result.message ?? "Pairing required")
        default:
            throw ProtocolErrorMessage(code: result.status.rawValue, message: result.message ?? "Authentication failed")
        }
    }

    private func messageLoop(channel: MessageChannel) async {
        do {
            while let message = try await channel.receive() {
                route(message)
            }
            // Stream ended without error.
            if !explicitlyDisconnected { await handleDrop(viewport: currentViewport()) }
        } catch {
            if !explicitlyDisconnected { await handleDrop(viewport: currentViewport()) }
        }
    }

    private func route(_ message: Message) {
        switch message {
        case .videoConfig, .videoFrame:
            onVideo?(message)
        case .cursorPosition(let position):
            onCursor?(position)
        case .clipboard(let payload):
            onClipboard?(payload)
        case .streamConfig(let config):
            activeConfig = config
        case .hostStatus(let status):
            hostStatus = status
        case .displayList(let list):
            displays = list.displays
        case .pong(let pong):
            let now = DispatchTime.now().uptimeNanoseconds
            lastRTTMillis = Double(now &- pong.echoNanos) / 1_000_000
        case .disconnect:
            explicitlyDisconnected = true
            state = .idle
        default:
            break
        }
    }

    private func handleDrop(viewport: Viewport) async {
        guard !explicitlyDisconnected else { return }
        reconnectAttempts += 1
        // Keep trying for roughly ten minutes so a Mac restart or a Tailscale blip recovers on its own.
        guard reconnectAttempts <= 40 else {
            state = .failed("Lost connection")
            return
        }
        state = .reconnecting
        let delay = min(pow(1.6, Double(reconnectAttempts)), 15)
        try? await Task.sleep(for: .seconds(delay))
        guard !explicitlyDisconnected else { return }
        await openConnection(viewport: viewport)
    }

    private func currentViewport() -> Viewport {
        activeConfig.map { Viewport(widthPoints: Double($0.display.pointWidth), heightPoints: Double($0.display.pointHeight), scale: $0.display.scale) }
            ?? Viewport(widthPoints: 1210, heightPoints: 834, scale: 2)
    }

    #if canImport(UIKit)
    private static func hardwareModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.reduce(into: "") { result, element in
            if let value = element.value as? Int8, value != 0 {
                result.append(Character(UnicodeScalar(UInt8(value))))
            }
        }
    }
    #endif
}

#if canImport(UIKit)
import UIKit
#endif

enum ClientHandshakeError: Error {
    case badHandshake
}
