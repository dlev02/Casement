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
        case suspended
        case failed(String)
    }

    private let log = Logger(subsystem: "com.benjaminlevinson.vantage", category: "client")
    private let identity: DeviceIdentity
    private let deviceName: String
    private let deviceModel: String

    private(set) var state: State = .idle
    private(set) var pairingError: String?
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
    private var connectionTask: Task<Void, Never>?
    private var connectionID = UUID()
    private var viewport = Viewport(widthPoints: 1210, heightPoints: 834, scale: 2)

    /// Called with each decoded video message (config/frame) so the renderer can consume it.
    var onVideo: ((Message) -> Void)?
    var onCursor: ((CursorPosition) -> Void)?
    var onClipboard: ((ClipboardPayload) -> Void)?
    var onDictationResult: ((DictationResult) -> Void)?

    /// Host transcription engines; nil for hosts that predate dictation (never send them its kinds).
    var dictationEngines: [DictationEngineID]? { capabilities?.dictationEngines }

    init(identity: DeviceIdentity? = nil) {
        let keychain = KeychainStore(service: "com.benjaminlevinson.vantage.client")
        self.identity = identity ?? (try? keychain.loadOrCreateIdentity()) ?? DeviceIdentity()
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
        disconnect()
        pairingError = nil
        self.device = device
        do {
            let address = try ConnectionAddress(host: device.host, port: String(device.port))
            self.device?.host = address.host
            self.device?.port = address.port
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        self.viewport = viewport
        self.pairingCode = pairingCode
        reconnectAttempts = 0
        let id = connectionID
        state = .connecting
        connectionTask = Task { await self.runConnection(id: id) }
    }

    /// Retries immediately when returning to the foreground after a failure.
    func retryNow() {
        guard let device else { return }
        switch state {
        case .failed, .suspended, .reconnecting:
            connect(to: device, viewport: viewport, pairingCode: pairingCode)
        default: break
        }
    }

    /// Release capture and held input while backgrounded; preserve the user's session intent.
    func suspendForBackground() {
        switch state {
        case .connecting, .authenticating, .connected, .reconnecting:
            disconnect()
            state = .suspended
        default: break // Keep a pairing prompt or explicit error intact.
        }
    }

    func disconnect() {
        connectionID = UUID()
        connectionTask?.cancel()
        connectionTask = nil
        let oldChannel = channel
        channel = nil
        state = .idle
        activeConfig = nil
        hostStatus = nil
        Task { await oldChannel?.close() }
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

    private func runConnection(id: UUID) async {
        guard let device else { return }
        while !Task.isCancelled, connectionID == id {
            state = reconnectAttempts == 0 ? .connecting : .reconnecting
            activeConfig = nil
            hostStatus = nil
            guard let port = NWEndpoint.Port(rawValue: device.port) else {
                state = .failed("Invalid port")
                return
            }
            let connection = NWConnection(host: NWEndpoint.Host(device.host), port: port,
                                          using: VantageNetwork.tcpParameters())
            let channel = MessageChannel(connection: connection, label: "vantage.client.session")
            self.channel = channel
            // Also bound the handshake: an accepted socket need not send a challenge.
            let timeout = Task {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                await channel.close()
            }
            do {
                try await channel.start()
                guard connectionID == id, !Task.isCancelled else {
                    timeout.cancel(); await channel.close(); return
                }
                let authenticated = try await handshake(channel: channel, viewport: viewport, id: id)
                timeout.cancel()
                guard connectionID == id, !Task.isCancelled else {
                    await channel.close(); return
                }
                guard authenticated else {
                    await channel.close()
                    self.channel = nil
                    return // Leave the pairing prompt visible until the user submits a code.
                }
                // Every new connection needs its own stream request, including reconnects.
                try await channel.send(.selectDisplay(SelectDisplay(selection: .fitViewport(viewport),
                    targetFPS: 60, quality: .auto, preferredCodec: device.preferredCodec,
                    useVirtualDisplay: device.useVirtualDisplay == true)))
                state = .connected
                reconnectAttempts = 0
                while let message = try await channel.receive() {
                    guard connectionID == id, !Task.isCancelled else { break }
                    if case .disconnect = message {
                        await channel.close()
                        self.channel = nil
                        state = .failed("The Mac ended the session.")
                        return
                    }
                    route(message)
                }
            } catch let error as ProtocolErrorMessage {
                timeout.cancel()
                await channel.close()
                guard connectionID == id, !Task.isCancelled else { return }
                self.channel = nil
                state = .failed(error.message)
                return
            } catch {
                log.error("connection error: \(error.localizedDescription)")
            }
            timeout.cancel()
            await channel.close()
            guard connectionID == id, !Task.isCancelled else { return }
            self.channel = nil
            reconnectAttempts += 1
            guard reconnectAttempts <= 40 else {
                state = .failed("Couldn’t reach the Mac. Check that Vantage Host and Tailscale are running on both devices.")
                return
            }
            state = .reconnecting
            do { try await Task.sleep(for: .seconds(min(pow(1.6, Double(reconnectAttempts)), 15))) }
            catch { return }
        }
    }

    private func handshake(channel: MessageChannel, viewport: Viewport, id: UUID) async throws -> Bool {
        let hello = Hello(clientName: deviceName, deviceModel: deviceModel, appVersion: "1.0",
                          clientPublicKey: identity.publicKeyData, supportedCodecs: [.hevc, .h264],
                          maxDecodeWidth: 4096, maxDecodeHeight: 2304, viewport: viewport,
                          features: ClientFeatures(dictation: true))
        try await channel.send(.hello(hello))

        guard case let .challenge(challenge)? = try await channel.receive() else { throw ClientHandshakeError.badHandshake }
        guard connectionID == id, !Task.isCancelled else { throw CancellationError() }
        hostName = challenge.hostName
        peerTailnetName = challenge.peerTailnetName
        state = .authenticating

        let signature = try identity.sign(AuthTranscript.bytes(nonce: challenge.nonce, hostPublicKey: challenge.hostPublicKey, clientPublicKey: identity.publicKeyData))
        let auth = Authenticate(signature: signature, pairingCode: challenge.isPaired ? nil : pairingCode)
        try await channel.send(.authenticate(auth))

        guard case let .authResult(result)? = try await channel.receive() else { throw ClientHandshakeError.badHandshake }
        guard connectionID == id, !Task.isCancelled else { throw CancellationError() }
        switch result.status {
        case .ok:
            displays = result.displays ?? []
            capabilities = result.capabilities
            return true
        case .pairingRequired, .badPairingCode:
            pairingError = result.status == .badPairingCode
                ? "Incorrect pairing code. Check the code in Vantage Host on your Mac and try again."
                : nil
            state = .pairingRequired
            return false
        default:
            throw ProtocolErrorMessage(code: result.status.rawValue, message: result.message ?? "Authentication failed")
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
        case .dictationResult(let result):
            onDictationResult?(result)
        case .displayList(let list):
            displays = list.displays
        case .pong(let pong):
            let now = DispatchTime.now().uptimeNanoseconds
            lastRTTMillis = Double(now &- pong.echoNanos) / 1_000_000
        default:
            break
        }
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
