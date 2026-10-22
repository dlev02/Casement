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
    /// What the host runs: from the challenge as soon as it arrives, then from its capabilities.
    /// Nil from older hosts, which are all Macs.
    private(set) var hostPlatform: HostPlatform?
    private(set) var lastRTTMillis: Double = 0
    private(set) var hostStatus: HostStatus?

    private var channel: MessageChannel?
    private var device: SavedDevice?
    private var pairingCode: String?
    /// Reconnects since the last healthy connection. A connection is healthy once the host
    /// answers the stream request (status, stream config, or video) or it has lasted a while, not
    /// merely once the handshake passes: an older host whose display is asleep accepts, then
    /// drops every stream request, and resetting at the handshake retried it every 1.6 s forever.
    private(set) var reconnectAttempts = 0
    /// Wait before reconnect attempt `n` (tests shorten it).
    var reconnectDelay: (Int) -> Duration = { attempt in .seconds(min(pow(1.6, Double(attempt)), 15)) }
    private var connectionTask: Task<Void, Never>?
    private var connectionID = UUID()
    private var viewport = Viewport(widthPoints: 1210, heightPoints: 834, scale: 2)

    /// Called with each decoded video message (config/frame) so the renderer can consume it.
    var onVideo: ((Message) -> Void)?
    /// Where the host's pointer is and whether it shows (hosts with `cursorShapes` only).
    var onCursor: ((CursorPosition) -> Void)?
    /// The host's pointer for this view to draw itself, so it moves with the mouse at once instead
    /// of a video frame later; nil when the host draws it into the video (every Mac, older PCs).
    /// Reset to nil at each sign-in; a host with `cursorShapes` sends one when the stream starts.
    var onCursorShape: ((CursorShape?) -> Void)?
    var onClipboard: ((ClipboardPayload) -> Void)?
    var onDictationResult: ((DictationResult) -> Void)?
    /// Mac audio (`audioConfig`, then `audioPacket`s) for the player. Only flows after
    /// `setMacAudio(true)` on a host that offers audio.
    var onAudio: ((Message) -> Void)?

    /// Host transcription engines; nil for hosts that predate dictation (never send them its kinds).
    var dictationEngines: [DictationEngineID]? { capabilities?.dictationEngines }
    /// The host can stream its audio. False for hosts that predate it: never send them `audioRequest`.
    var hostOffersAudio: Bool { capabilities?.audio == true }
    /// Whether this session wants the Mac's audio. Survives reconnects: every new connection asks
    /// again once the host has said it can.
    private(set) var wantsMacAudio = false

    /// This Mac's files and the channel that moves them. The session screen hands over the Mac's
    /// shared one (`FileTransferCenter`, see `useFileLink`) so transfers carry on after it closes;
    /// until then, and in tests, it's one of the session's own.
    private(set) var fileLink: FileLink
    /// Files to and from the Mac.
    var files: FileTransferController { fileLink.files }
    /// The host can take a file channel. False for hosts that predate file transfer.
    var hostOffersFiles: Bool { capabilities?.fileTransfer == true }

    init(identity: DeviceIdentity? = nil, files: FileTransferController? = nil) {
        let keychain = KeychainStore(service: "com.benjaminlevinson.vantage.client")
        let identity = identity ?? (try? keychain.loadOrCreateIdentity()) ?? DeviceIdentity()
        self.identity = identity
        self.deviceName = ClientSession.localDeviceName
        self.deviceModel = ClientSession.hardwareModel()
        self.fileLink = FileLink(files: files ?? FileTransferController(), identity: identity,
                                 clientName: deviceName, clientModel: deviceModel)
        adopt(fileLink)
    }

    /// Moves files to `link` (the Mac's shared one) before connecting.
    func useFileLink(_ link: FileLink) {
        guard link !== fileLink else { return }
        fileLink.screenDidEnd()
        fileLink = link
        adopt(link)
    }

    private func adopt(_ link: FileLink) {
        // An older Mac's file channel dropping mid-session takes the session with it, so both
        // come back together.
        link.onLegacyChannelLost = { [weak self] in
            guard let channel = self?.channel else { return }
            Task { await channel.close() }
        }
    }

    /// What the Mac shows for this device ("iPad" on iOS, which hides the user's device name;
    /// the computer name from Sharing settings on a Mac).
    static var localDeviceName: String {
        #if canImport(UIKit)
        UIDevice.current.name
        #elseif os(macOS)
        MacComputer.name
        #else
        "iPad"
        #endif
    }

    var fingerprint: String { identity.fingerprint }

    func connect(to device: SavedDevice, viewport: Viewport, pairingCode: String? = nil) {
        disconnect()
        pairingError = nil
        self.device = device
        fileLink.update(device)
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
        fileLink.screenDidEnd() // files keep moving on a Mac that allows it
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

    /// Turns the Mac's audio on or off for this session (and every reconnect). Sends nothing to a
    /// host that doesn't offer audio.
    func setMacAudio(_ enabled: Bool) {
        let changed = wantsMacAudio != enabled
        wantsMacAudio = enabled
        guard changed || enabled, state == .connected, hostOffersAudio else { return }
        send(.audioRequest(AudioRequest(enabled: enabled)))
    }

    /// The Mac says its display is asleep (hosts that predate this never say so).
    var isDisplayAsleep: Bool { state == .connected && hostStatus?.isDisplayAsleep == true }

    /// The Mac's display is awake but the host has had no picture of it for a few seconds.
    var isScreenUnavailable: Bool {
        state == .connected && hostStatus?.isScreenUnavailable == true && hostStatus?.isDisplayAsleep != true
    }

    /// Asks the Mac to turn its display on (and, while the picture is missing, to try capture
    /// again). Any input would wake it too; this is the explicit button.
    func wakeDisplay() {
        send(.hostCommand(HostCommandMessage(command: .wakeDisplay)))
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
            var connectedAt: ContinuousClock.Instant?
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
                let (authenticated, fileToken) = try await handshake(channel: channel, viewport: viewport, id: id)
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
                if wantsMacAudio, hostOffersAudio {
                    try await channel.send(.audioRequest(AudioRequest(enabled: true)))
                }
                state = .connected
                connectedAt = .now
                fileLink.screenDidConnect(token: fileToken, capabilities: capabilities, host: device.host, port: port)
                // No video for a while (the Mac's display asleep, a static screen) is normal:
                // only the connection itself ending brings a reconnect.
                while let message = try await channel.receive() {
                    guard connectionID == id, !Task.isCancelled else { break }
                    if case .disconnect = message {
                        await channel.close()
                        self.channel = nil
                        fileLink.screenDidEnd()
                        state = .failed("The Mac ended the session.")
                        return
                    }
                    if reconnectAttempts > 0, Self.answersStream(message) { reconnectAttempts = 0 }
                    route(message)
                }
            } catch let error as ProtocolErrorMessage {
                timeout.cancel()
                await channel.close()
                guard connectionID == id, !Task.isCancelled else { return }
                self.channel = nil
                fileLink.screenDidEnd()
                state = .failed(error.message)
                return
            } catch {
                log.error("connection error: \(error.localizedDescription)")
            }
            timeout.cancel()
            await channel.close()
            guard connectionID == id, !Task.isCancelled else { return }
            self.channel = nil
            fileLink.screenDidDrop() // an older Mac's file channel goes too; files wait for the next one
            if let connectedAt, ContinuousClock.now - connectedAt > .seconds(10) { reconnectAttempts = 0 }
            reconnectAttempts += 1
            guard reconnectAttempts <= 40 else {
                fileLink.screenDidEnd()
                state = .failed("Couldn’t reach the Mac. Check that Casement Host and Tailscale are running on both devices.")
                return
            }
            state = .reconnecting
            do { try await Task.sleep(for: reconnectDelay(reconnectAttempts)) }
            catch { return }
        }
    }

    /// Returns whether the session is authenticated, and the host's file channel token if it gave one.
    private func handshake(channel: MessageChannel, viewport: Viewport, id: UUID) async throws -> (Bool, Data?) {
        let hello = Hello(clientName: deviceName, deviceModel: deviceModel, appVersion: "1.0",
                          clientPublicKey: identity.publicKeyData, supportedCodecs: [.hevc, .h264],
                          maxDecodeWidth: 4096, maxDecodeHeight: 2304, viewport: viewport,
                          features: ClientFeatures(dictation: true, macAudio: true, fileTransfer: true, localCursor: true))
        try await channel.send(.hello(hello))

        guard case let .challenge(challenge)? = try await channel.receive() else { throw ClientHandshakeError.badHandshake }
        guard connectionID == id, !Task.isCancelled else { throw CancellationError() }
        hostName = challenge.hostName
        peerTailnetName = challenge.peerTailnetName
        hostPlatform = challenge.hostPlatform
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
            if let platform = result.capabilities?.platform { hostPlatform = platform }
            onCursorShape?(nil) // until the host sends the pointer it leaves out of the video
            return (true, result.sessionToken)
        case .pairingRequired, .badPairingCode:
            pairingError = result.status == .badPairingCode
                ? "Incorrect pairing code. Check the code in Casement Host on your Mac and try again."
                : nil
            state = .pairingRequired
            return (false, nil)
        default:
            throw ProtocolErrorMessage(code: result.status.rawValue, message: result.message ?? "Authentication failed")
        }
    }

    /// The host took the stream request: it said how it's doing or started sending.
    private static func answersStream(_ message: Message) -> Bool {
        switch message {
        case .hostStatus, .streamConfig, .videoConfig, .videoFrame: true
        default: false
        }
    }

    private func route(_ message: Message) {
        switch message {
        case .videoConfig, .videoFrame:
            onVideo?(message)
        case .cursorPosition(let position):
            onCursor?(position)
        case .cursorShape(let shape):
            onCursorShape?(shape)
        case .clipboard(let payload):
            onClipboard?(payload)
        case .streamConfig(let config):
            activeConfig = config
        case .hostStatus(let status):
            hostStatus = status
        case .dictationResult(let result):
            onDictationResult?(result)
        case .audioConfig, .audioPacket:
            onAudio?(message)
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
    static func hardwareModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.reduce(into: "") { result, element in
            if let value = element.value as? Int8, value != 0 {
                result.append(Character(UnicodeScalar(UInt8(value))))
            }
        }
    }
    #elseif os(macOS)
    /// The Mac's model identifier ("Mac15,6"); `uname` only says "arm64" there.
    static func hardwareModel() -> String { MacComputer.model }
    #else
    static func hardwareModel() -> String { "iPad" }
    #endif
}

#if canImport(UIKit)
import UIKit
#endif

#if os(macOS)
import SystemConfiguration

/// This Mac's name and model, read once. `Host.current().localizedName` can wait on DNS, so it
/// never runs on the main actor; the computer name comes from configd instead.
nonisolated enum MacComputer {
    static let name: String = {
        let name = SCDynamicStoreCopyComputerName(nil, nil) as String?
        return name.flatMap { $0.isEmpty ? nil : $0 } ?? "Mac"
    }()

    static let model: String = {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else { return "Mac" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "Mac" }
        let model = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return model.isEmpty ? "Mac" : model
    }()
}
#endif

enum ClientHandshakeError: Error {
    case badHandshake
}
