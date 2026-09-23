import AppKit
import CoreGraphics
import Foundation
import Network
import VantageCore
import os

/// One authenticated client session: authenticates the peer, negotiates a display, then runs the
/// capture → encode → send pipeline and applies incoming input, clipboard, and commands.
actor HostSession {
    enum State: Equatable { case handshaking, streaming, closed }

    private let log = Logger(subsystem: "com.benjaminlevinson.vantage.host", category: "session")
    private let channel: MessageChannel
    private let identity: DeviceIdentity
    private let trust: TrustStore
    private let peerDescription: String
    private let onEnded: @Sendable (HostSession) -> Void

    private var state: State = .handshaking
    private var capture: (any FrameSource)?
    private var encoder: VideoEncoder?
    private var injector: InputInjector?
    private var adaptive = AdaptiveController()
    private let power = PowerManager()
    private let clipboard = ClipboardBridge()
    private let lockMonitor = LockMonitor()
    private var displayInfo: DisplayInfo?
    private var pendingPixelBuffer: CVPixelBuffer?
    private var encodesInFlight = 0
    private var needsKeyframe = true
    private var framesSent: UInt64 = 0

    init(channel: MessageChannel, identity: DeviceIdentity, trust: TrustStore, peerDescription: String, onEnded: @escaping @Sendable (HostSession) -> Void) {
        self.channel = channel
        self.identity = identity
        self.trust = trust
        self.peerDescription = peerDescription
        self.onEnded = onEnded
    }

    func run() async {
        do {
            log.info("session starting channel")
            try await channel.start()
            log.info("channel ready; handshaking")
            if try await handshake() { try await receiveLoop() }
        } catch {
            log.error("session error: \(error.localizedDescription, privacy: .public)")
        }
        await teardown()
    }

    // MARK: Handshake

    private func handshake() async throws -> Bool {
        guard case let .hello(hello)? = try await channel.receive() else { throw SessionError.badHandshake }
        guard hello.protocolVersion == VantageProtocol.version else {
            try await channel.send(.authResult(AuthResult(status: .versionMismatch, message: "Protocol \(VantageProtocol.version) required")))
            throw SessionError.versionMismatch
        }

        let nonce = AuthTranscript.randomNonce()
        let isPaired = trust.isTrusted(hello.clientPublicKey)
        let challenge = Challenge(hostName: Host.current().localizedName ?? "Mac", hostVersion: "1.0", hostPublicKey: identity.publicKeyData, nonce: nonce, isPaired: isPaired, peerTailnetName: hello.isReadinessProbe == true ? nil : TailscaleCLI.whois(addr: peerDescription))
        try await channel.send(.challenge(challenge))

        guard case let .authenticate(auth)? = try await channel.receive() else { throw SessionError.badHandshake }
        let signatureValid = AuthTranscript.verify(signature: auth.signature, nonce: nonce, hostPublicKey: identity.publicKeyData, clientPublicKey: hello.clientPublicKey)
        guard signatureValid else {
            try await channel.send(.authResult(AuthResult(status: .badSignature)))
            throw SessionError.authFailed
        }
        if !isPaired {
            guard let code = auth.pairingCode else {
                try await channel.send(.authResult(AuthResult(status: .pairingRequired, message: "Enter the pairing code shown on the Mac")))
                return false
            }
            switch trust.consumePairingCode(code) {
            case .accepted:
                break
            case .incorrect:
                // Slow down guessing; the code is also burned after a few misses.
                try? await Task.sleep(for: .seconds(1))
                try await channel.send(.authResult(AuthResult(status: .badPairingCode, message: "Incorrect pairing code. Try the code shown on the Mac.")))
                return false
            case .unavailable:
                try? await Task.sleep(for: .seconds(1))
                try await channel.send(.authResult(AuthResult(status: .badPairingCode, message: "That pairing code has expired. On the Mac, choose Show pairing code and enter the new one.")))
                return false
            }
            trust.trust(hello.clientPublicKey, name: hello.clientName)
        }

        if hello.isReadinessProbe == true {
            let synthetic = HostOptions.shared.syntheticCapture
            try await channel.send(.authResult(AuthResult(status: .ok,
                readiness: HostReadiness(screenRecordingGranted: synthetic || ScreenCapture.preflightPermission(),
                                         accessibilityGranted: synthetic || InputInjector.hasPermission()))))
            return false // Never enumerate displays, start capture, or access the clipboard for a probe.
        }

        if !HostOptions.shared.syntheticCapture, !ScreenCapture.preflightPermission() {
            try await channel.send(.authResult(AuthResult(status: .denied,
                message: "On the Mac, grant Screen Recording to Vantage Host in System Settings → Privacy & Security, then reopen Vantage Host and retry.")))
            throw SessionError.authFailed
        }
        let displays = try await DisplayEnumerator.availableDisplays()
        let capabilities = HostCapabilities(codecs: [.hevc, .h264], canManageVirtualDisplay: VirtualDisplayManager().isAvailable, clipboard: true, maxFPS: 60)
        try await channel.send(.authResult(AuthResult(status: .ok, sessionToken: nil, displays: displays, capabilities: capabilities)))
        state = .streaming
        log.info("client authenticated: \(hello.clientName)")
        return true
    }

    // MARK: Message loop

    private func receiveLoop() async throws {
        while let message = try await channel.receive() {
            switch message {
            case .selectDisplay(let select):
                try await startStreaming(select)
            case .pointerEvent(let event):
                injector?.handle(event)
            case .scrollEvent(let event):
                injector?.handle(event)
            case .keyEvent(let event):
                injector?.handle(event)
            case .textInput(let input):
                injector?.typeText(input.text)
            case .clipboard(let payload):
                if !HostOptions.shared.syntheticCapture { clipboard.apply(payload) }
            case .qualityFeedback(let feedback):
                if let newBitrate = adaptive.apply(feedback: feedback) {
                    encoder?.setBitrate(kbps: newBitrate)
                }
            case .requestKeyframe:
                needsKeyframe = true
            case .hostCommand(let command):
                await handle(command.command)
            case .viewportChanged(let change):
                await handleViewportChange(change.viewport)
            case .ping(let ping):
                channel.sendDetached(.pong(Pong(echoNanos: ping.sentAtNanos)))
            case .disconnect:
                return
            default:
                break
            }
        }
    }

    // MARK: Streaming

    private func startStreaming(_ select: SelectDisplay) async throws {
        let startedAt = MonotonicClock.nanos()
        defer { log.info("stream setup took \((MonotonicClock.nanos() - startedAt) / 1_000_000) ms") }
        await stopStreaming()
        let chosen: DisplayInfo
        if HostOptions.shared.syntheticCapture {
            switch select.selection {
            case .fitViewport(let viewport):
                chosen = DisplayEnumerator.syntheticDisplay(pointWidth: max(640, Int(viewport.widthPoints)), pointHeight: max(480, Int(viewport.heightPoints)))
            case .display:
                chosen = DisplayEnumerator.syntheticDisplay()
            }
        } else {
            let all = try await DisplayEnumerator.shareableDisplays()
            let mainID = CGMainDisplayID()
            switch select.selection {
            case .display(let id):
                guard let match = all.first(where: { $0.info.id == id }) else { throw CaptureError.displayNotFound }
                chosen = match.info
            case .fitViewport(let viewport):
                // Only provision a virtual display when the client asked for one. The default
                // path must never wait on BetterDisplay: it costs the whole connect time.
                var virtualMatch: DisplayInfo?
                if select.useVirtualDisplay == true {
                    // A display that already matches the viewport (for example a BetterDisplay
                    // screen the user set up by hand) is used as-is; only otherwise ask the CLI.
                    let wantedWidth = viewport.pixelWidth / 2, wantedHeight = viewport.pixelHeight / 2
                    if let existing = all.first(where: { !$0.info.isBuiltIn && $0.info.pointWidth == wantedWidth && $0.info.pointHeight == wantedHeight }) {
                        virtualMatch = existing.info
                        log.info("using existing display \(existing.info.id) that already matches the viewport")
                    }
                    let vdm = VirtualDisplayManager()
                    if virtualMatch != nil {
                        // Nothing to provision.
                    } else if vdm.isAvailable {
                        let started = MonotonicClock.nanos()
                        if let virtualID = try? await vdm.provision(pointWidth: viewport.pixelWidth / 2, pointHeight: viewport.pixelHeight / 2),
                           let match = try? await DisplayEnumerator.shareableDisplays().first(where: { $0.info.id == virtualID }) {
                            virtualMatch = match.info
                        } else {
                            log.error("virtual display unavailable after \((MonotonicClock.nanos() - started) / 1_000_000) ms; using the main display")
                        }
                    } else {
                        log.info("virtual display requested but BetterDisplay CLI is not installed; using the main display")
                    }
                }
                if let virtualMatch {
                    chosen = virtualMatch
                } else if let match = all.first(where: { $0.info.id == mainID }) ?? all.first {
                    chosen = match.info
                } else {
                    throw CaptureError.displayNotFound
                }
            }
        }
        displayInfo = chosen

        let codec: VideoCodec = select.preferredCodec ?? .hevc
        let startFPS = min(select.targetFPS, 60)
        adaptive = AdaptiveController(startBitrateKbps: bitrateForPixels(chosen.pixelWidth * chosen.pixelHeight, fps: startFPS))

        let encoder = VideoEncoder(configuration: .init(codec: codec, width: chosen.pixelWidth, height: chosen.pixelHeight, fps: startFPS, bitrateKbps: adaptive.bitrateKbps, maxQP: adaptive.maxQP))
        try encoder.start { [weak self] output in
            guard let self else { return }
            Task { await self.emit(output) }
        }
        self.encoder = encoder

        let frame = CGRect(x: chosen.originX, y: chosen.originY, width: Double(chosen.pointWidth), height: Double(chosen.pointHeight))
        if !HostOptions.shared.syntheticCapture { injector = InputInjector(displayFrame: frame) }

        let capture: any FrameSource = HostOptions.shared.syntheticCapture
            ? SyntheticFrameSource(pixelWidth: chosen.pixelWidth, pixelHeight: chosen.pixelHeight, fps: startFPS)
            : ScreenCapture(displayID: chosen.id, pixelWidth: chosen.pixelWidth, pixelHeight: chosen.pixelHeight, fps: startFPS)
        try await capture.start(onFrame: { [weak self] frame in
            guard let self else { return }
            Task { await self.ingest(frame) }
        }, onStop: { [weak self] _ in
            guard let self else { return }
            Task { await self.requestRestart() }
        })
        self.capture = capture

        power.begin()
        power.declareUserActivity()
        clipboard.onLocalChange = { [weak self] payload in
            guard let self else { return }
            Task { await self.sendClipboard(payload) }
        }
        if !HostOptions.shared.syntheticCapture {
            clipboard.start()
            let initial = clipboard.currentPayload()
            if !initial.isEmpty { channel.sendDetached(.clipboard(initial)) }
        }

        try await channel.send(.streamConfig(StreamConfig(display: chosen, codec: codec, fps: startFPS, bitrateKbps: adaptive.bitrateKbps)))
        lockMonitor.onChange = { [channel] status in channel.sendDetached(.hostStatus(status)) }
        lockMonitor.start()
        channel.sendDetached(.hostStatus(lockMonitor.currentStatus()))
        needsKeyframe = true
        log.info("streaming display \(chosen.id) at \(chosen.pixelWidth)x\(chosen.pixelHeight) (\(chosen.isVirtual ? "virtual" : chosen.isMain ? "main" : "secondary"), origin \(Int(chosen.originX)),\(Int(chosen.originY)))")
    }

    private func ingest(_ frame: CapturedFrame) {
        let (_, fps) = adaptive.observe(dirtyRatio: frame.dirtyRatio)
        capture?.updateFPS(fps)
        encoder?.setExpectedFrameRate(fps)

        // Idle suppression: skip encoding a static frame (but always honor a pending keyframe).
        if frame.dirtyRatio <= 0.0001 && !needsKeyframe && framesSent > 0 { return }
        guard encodesInFlight < 1 else {
            pendingPixelBuffer = frame.pixelBuffer
            return
        }
        encodesInFlight += 1
        let force = needsKeyframe
        needsKeyframe = false
        encoder?.encode(frame.pixelBuffer, ptsNanos: frame.displayNanos, forceKeyframe: force)
    }

    private func emit(_ output: VideoEncoder.Output) {
        encodesInFlight = max(0, encodesInFlight - 1)
        if let config = output.config {
            channel.sendDetached(.videoConfig(config))
        }
        channel.sendDetached(.videoFrame(output.frame))
        framesSent &+= 1
        if let pending = pendingPixelBuffer {
            pendingPixelBuffer = nil
            encodesInFlight += 1
            encoder?.encode(pending, ptsNanos: MonotonicClock.nanos(), forceKeyframe: false)
        }
    }

    private func sendClipboard(_ payload: ClipboardPayload) {
        channel.sendDetached(.clipboard(payload))
    }

    private func handle(_ command: HostCommand) async {
        guard !HostOptions.shared.syntheticCapture else { return }
        switch command {
        case .lockScreen: HostCommandRunner.lockScreen()
        case .sleepDisplay: HostCommandRunner.sleepDisplay()
        case .wakeDisplay: power.declareUserActivity()
        case .releaseAllInput: injector?.releaseAll()
        case .refreshDisplays:
            if let displays = try? await DisplayEnumerator.availableDisplays() {
                channel.sendDetached(.displayList(DisplayList(displays: displays)))
            }
        case .restoreDisplays:
            VirtualDisplayManager().disconnect()
        }
    }

    private func handleViewportChange(_ viewport: Viewport) async {
        // Geometry is immutable for the life of a connection; a viewport change forces a keyframe.
        needsKeyframe = true
    }

    /// Rebuilds capture after display sleep/wake or a display reconfiguration.
    func restartCapture() async {
        await requestRestart()
    }

    private func requestRestart() async {
        // Capture stopped (display sleep/reconfigure). Rebuild on next selectDisplay or force keyframe.
        needsKeyframe = true
        if let info = displayInfo {
            let select = SelectDisplay(selection: .display(info.id), targetFPS: 60, quality: .auto, preferredCodec: encoder?.currentCodec)
            try? await startStreaming(select)
        }
    }

    private func stopStreaming() async {
        await capture?.stop()
        capture = nil
        encoder?.stop()
        encoder = nil
        injector?.releaseAll()
        injector = nil
        clipboard.stop()
        lockMonitor.stop()
        power.end()
        pendingPixelBuffer = nil
        encodesInFlight = 0
    }

    private func teardown() async {
        guard state != .closed else { return }
        state = .closed
        await stopStreaming()
        await channel.close()
        onEnded(self)
    }

    private func bitrateForPixels(_ pixels: Int, fps: Int) -> Int {
        // ~0.08 bits/pixel/frame baseline for crisp screen content.
        let bits = Double(pixels) * Double(fps) * 0.08
        return Int(min(60_000, max(4_000, bits / 1000)))
    }
}

enum SessionError: Error {
    case badHandshake
    case versionMismatch
    case authFailed
    case pairingRequired
}
