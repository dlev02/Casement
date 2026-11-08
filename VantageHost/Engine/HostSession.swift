import CoreGraphics
import CoreVideo
import Foundation
import Synchronization
import VantageCore
import os

/// One authenticated client session: authenticates the peer, negotiates a display, then runs the
/// capture → encode → send pipeline and applies incoming input, clipboard, and commands.
///
/// Everything platform-specific comes through its `HostEnvironment` (real Mac or synthetic), so
/// the session never reads launch options or a singleton and can run over loopback in a test.
///
/// A files-only session (`ClientFeatures.filesOnly`) stops after authenticating: it hands out a
/// file channel token and answers pings, and never touches displays, capture, input, audio, the
/// clipboard, the lock monitor, or power assertions, whatever the client sends.
actor HostSession {
    enum State: Equatable { case handshaking, streaming, filesOnly, closed }

    private let log = Logger(subsystem: "com.benjaminlevinson.vantage.host", category: "session")
    private let channel: MessageChannel
    private let identity: DeviceIdentity
    private let trust: any HostTrust
    private let env: HostEnvironment
    private let peerDescription: String
    private let onEnded: @Sendable (HostSession) -> Void

    private var state: State = .handshaking
    private var capture: (any FrameSource)?
    private var encoder: VideoEncoder?
    /// Bumped by every `stopCapture`; frame and encoder callbacks carry the epoch they were made
    /// in, so a late one from a stopped capture or encoder can't touch its replacement's state.
    private var captureEpoch: UInt64 = 0
    private var injector: (any InputSink)?
    private var adaptive = AdaptiveController()
    private let power: any HostPowerControl
    private var clipboard: (any HostClipboard)?
    private let lockMonitor: any HostStatusMonitor
    /// What the device wants streamed and how the picture is kept coming: events in, decisions
    /// out (`dispatch`), executed here.
    private var lifecycle: CaptureLifecycle
    /// Runs the lifecycle's 250 ms ticks while it wants them (`syncTicker`).
    private var ticker: Task<Void, Never>?
    private var pendingPixelBuffer: CVPixelBuffer?
    private var encodesInFlight = 0
    /// When the encode in flight was handed over; past `encodeLimit` it counts as lost.
    private var encodeStartedAt: ContinuousClock.Instant?
    private var needsKeyframe = true
    private var framesSent: UInt64 = 0
    /// The frame rate capture and the encoder were last told; they hear only changes.
    private var currentFPS = 0
    /// Dictation audio waiting for `commit`. Only filled for clients that asked for dictation.
    private var dictationClips = DictationClipStore()
    private var dictationEngines: [DictationEngineID] = []
    /// The client said it understands `audioConfig`/`audioPacket`; audio kinds go to no one else.
    private var clientTakesAudio = false
    private var audioSource: (any AudioSource)?
    private var audioEncoder: AudioEncoder?
    private var audioStartedAt: UInt64 = 0
    /// The client said it can open a file channel; only then is a token issued.
    private var clientTakesFiles = false
    private let attachTokens: AttachTokenRegistry<HostSession>
    /// The address the session came from; the file channel must come from the same one.
    let peerHost: String
    private var fileEngine: FileTransferEngine?
    private var clientName = "iPad"
    /// The client's hardware model from its hello ("iPad16,6", "Mac16,1"): a Mac client keeps
    /// received files in Downloads, an iPad in Files.
    private var clientModel = ""
    /// The client's key fingerprint: which iPad this is across connections.
    private var clientKey = ""
    /// Tells the controller a file channel is up (for the menu, notifications, and sending).
    private let onFileChannel: @Sendable (HostFileChannel) -> Void
    /// Tells the controller who is watching once a screen session is authenticated (for the menu).
    private let onStreaming: @Sendable (HostSession, _ name: String, _ model: String, _ key: String) -> Void
    /// Tells the controller the handshake is over, so it stops counting this session as pending.
    private let onAuthenticated: @Sendable (HostSession) -> Void
    /// `--capture-fails-for` (DEBUG): capture fails until then.
    private var captureFailsUntil: ContinuousClock.Instant?

    init(channel: MessageChannel, identity: DeviceIdentity, trust: any HostTrust, environment: HostEnvironment,
         peerDescription: String, peerHost: String,
         attachTokens: AttachTokenRegistry<HostSession>, onFileChannel: @escaping @Sendable (HostFileChannel) -> Void,
         onStreaming: @escaping @Sendable (HostSession, String, String, String) -> Void = { _, _, _, _ in },
         onAuthenticated: @escaping @Sendable (HostSession) -> Void = { _ in },
         onEnded: @escaping @Sendable (HostSession) -> Void) {
        self.channel = channel
        self.onAuthenticated = onAuthenticated
        self.identity = identity
        self.trust = trust
        self.env = environment
        self.power = environment.makePower()
        self.lockMonitor = environment.makeStatusMonitor()
        self.lifecycle = CaptureLifecycle(restartsByDisplayID: environment.screen.canRestartByDisplayID)
        self.peerDescription = peerDescription
        self.peerHost = peerHost
        self.attachTokens = attachTokens
        self.onFileChannel = onFileChannel
        self.onStreaming = onStreaming
        self.onEnded = onEnded
    }

    private var now: ContinuousClock.Instant { env.clock.now }

    /// Runs the session on a started channel whose first message, `hello`, the controller has
    /// already read (it reads one message to tell sessions from file channels).
    func run(hello: Hello) async {
        // A peer that says hello and then nothing (or never signs in) would otherwise hold a
        // session, and its buffers, open for as long as it liked; the whole handshake gets one limit.
        let deadline = Task { [channel, clock = env.clock] in
            do { try await clock.sleep(for: Self.handshakeLimit) } catch { return }
            await channel.close()
        }
        do {
            log.info("channel ready; handshaking")
            let authenticated = try await handshake(hello)
            deadline.cancel()
            if authenticated {
                onAuthenticated(self)
                if state == .filesOnly { try await filesOnlyLoop() } else { try await receiveLoop() }
            }
        } catch {
            deadline.cancel()
            log.error("session error: \(error.localizedDescription, privacy: .public)")
        }
        await teardown()
    }

    /// How long a connection has from its `hello` to a successful `authResult`.
    static let handshakeLimit: Duration = .seconds(15)

    // MARK: Handshake

    private func handshake(_ hello: Hello) async throws -> Bool {
        guard hello.protocolVersion == VantageProtocol.version else {
            try await channel.send(.authResult(AuthResult(status: .versionMismatch, message: "Protocol \(VantageProtocol.version) required")))
            throw SessionError.versionMismatch
        }

        let nonce = AuthTranscript.randomNonce()
        let isPaired = trust.isTrusted(hello.clientPublicKey)
        let lightweight = hello.isReadinessProbe == true || hello.features?.filesOnly == true
        // A client that sent a nonce wants proof this challenge comes from the holder of the host
        // key, and signs the transcript that binds both nonces and the connection's purpose. One
        // that didn't (an older Casement) signs the older transcript; the host still takes that.
        let clientNonce = hello.clientNonce.flatMap { $0.count == AuthTranscript.nonceLength ? $0 : nil }
        let hostSignature = try clientNonce.map { clientNonce in
            try identity.sign(AuthTranscript.hostBytes(clientNonce: clientNonce, hostNonce: nonce, hostPublicKey: identity.publicKeyData,
                                                       clientPublicKey: hello.clientPublicKey))
        }
        let challenge = Challenge(hostName: env.hostName, hostVersion: "1.0", hostPublicKey: identity.publicKeyData, nonce: nonce, isPaired: isPaired,
                                  peerTailnetName: lightweight ? nil : env.peers?.userName(ofPeer: peerDescription),
                                  hostPlatform: env.platform, hostSignature: hostSignature)
        try await channel.send(.challenge(challenge))

        guard case let .authenticate(auth)? = try await channel.receive() else { throw SessionError.badHandshake }
        let signatureValid = if let clientNonce {
            AuthTranscript.verifyClient(signature: auth.signature, clientNonce: clientNonce, hostNonce: nonce, hostPublicKey: identity.publicKeyData,
                                        clientPublicKey: hello.clientPublicKey, purpose: AuthPurpose(hello: hello))
        } else {
            AuthTranscript.verify(signature: auth.signature, nonce: nonce, hostPublicKey: identity.publicKeyData, clientPublicKey: hello.clientPublicKey)
        }
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
                try? await env.clock.sleep(for: .seconds(1))
                try await channel.send(.authResult(AuthResult(status: .badPairingCode, message: "Incorrect pairing code. Try the code shown on the Mac.")))
                return false
            case .unavailable:
                try? await env.clock.sleep(for: .seconds(1))
                try await channel.send(.authResult(AuthResult(status: .badPairingCode, message: "That pairing code has expired. On the Mac, choose Show Pairing Code and enter the new one.")))
                return false
            }
            trust.trust(hello.clientPublicKey, name: hello.clientName, model: hello.deviceModel)
        }
        if !lightweight { nameFromTailnet(DeviceIdentity.fingerprint(of: hello.clientPublicKey)) }

        if hello.isReadinessProbe == true {
            try await channel.send(.authResult(AuthResult(status: .ok,
                readiness: HostReadiness(screenRecordingGranted: env.screenRecordingGranted(),
                                         accessibilityGranted: env.accessibilityGranted()))))
            return false // Never enumerate displays, start capture, or access the clipboard for a probe.
        }

        if hello.features?.filesOnly == true {
            // Files need no Screen Recording grant and no display: just the file channel's ticket.
            guard hello.features?.fileTransfer == true else {
                try await channel.send(.authResult(AuthResult(status: .denied, message: "Nothing to do on this connection.")))
                throw SessionError.authFailed
            }
            clientTakesFiles = true
            clientName = hello.clientName
            clientModel = hello.deviceModel
            clientKey = DeviceIdentity.fingerprint(of: hello.clientPublicKey)
            let token = attachTokens.issue(for: self, peer: peerHost)
            let capabilities = HostCapabilities(codecs: [], canManageVirtualDisplay: false, clipboard: false, maxFPS: 0,
                                                fileTransfer: true, filesOnlySessions: true, platform: env.platform)
            try await channel.send(.authResult(AuthResult(status: .ok, sessionToken: token, capabilities: capabilities)))
            state = .filesOnly
            log.info("files-only session for \(hello.clientName)")
            return true
        }

        if !env.screenRecordingGranted() {
            try await channel.send(.authResult(AuthResult(status: .denied,
                message: "On the Mac, grant Screen Recording to Casement Host in System Settings → Privacy & Security, then reopen Casement Host and retry.")))
            throw SessionError.authFailed
        }
        // A sleeping display lists no displays at all, so wake it before looking.
        if power.isDisplayAsleep { await wakeDisplayForStreaming() }
        let displays = try await env.screen.displays()
        // Dictation kinds are new, so they're advertised only to a client that said it knows them.
        if hello.features?.dictation == true, let dictation = env.dictation { dictationEngines = await dictation.availableEngines() }
        clientTakesAudio = hello.features?.macAudio == true
        clientTakesFiles = hello.features?.fileTransfer == true
        clientName = hello.clientName
        clientModel = hello.deviceModel
        clientKey = DeviceIdentity.fingerprint(of: hello.clientPublicKey)
        // The file channel's ticket in: single use, from this address only, gone with the session.
        let token = clientTakesFiles ? attachTokens.issue(for: self, peer: peerHost) : nil
        // Audio rides on the Screen Recording grant checked above (synthetic mode sends a chime),
        // so a session that got this far can always offer it.
        let capabilities = HostCapabilities(codecs: [.hevc, .h264], canManageVirtualDisplay: env.screen.canManageVirtualDisplay, clipboard: true, maxFPS: 60,
                                            dictationEngines: hello.features?.dictation == true ? dictationEngines : nil,
                                            audio: true, fileTransfer: clientTakesFiles ? true : nil,
                                            filesOnlySessions: clientTakesFiles ? true : nil, platform: env.platform,
                                            curtain: true)
        try await channel.send(.authResult(AuthResult(status: .ok, sessionToken: token, displays: displays, capabilities: capabilities)))
        state = .streaming
        onStreaming(self, trust.name(ofFingerprint: clientKey) ?? hello.clientName, hello.deviceModel, clientKey)
        log.info("client authenticated: \(hello.clientName)")
        if hello.features?.curtain == true, let curtain = env.curtain {
            let channel = self.channel
            let adopted = await curtain.adopt(ObjectIdentifier(self)) { status in
                channel.sendDetached(.curtainStatus(status))
            }
            guard state == .streaming else { // removed while adopting
                if adopted { await curtain.sessionEnded(ObjectIdentifier(self)) }
                return false
            }
            if adopted { channel.sendDetached(.curtainStatus(CurtainStatus(isUp: true))) }
        }
        return true
    }

    // MARK: Message loop

    /// Every message is handled only while the session is streaming: a teardown from elsewhere
    /// (the device was removed) closes the channel first, and anything this loop was in the middle
    /// of awaiting checks the state again before it acts.
    private func receiveLoop() async throws {
        while state == .streaming, let message = try await channel.receive() {
            guard state == .streaming else { return }
            switch message {
            case .selectDisplay(let select):
                if captureFailsUntil == nil, let failsFor = env.captureFailsFor {
                    captureFailsUntil = now + failsFor
                    log.info("--capture-fails-for: capture fails for \(failsFor.components.seconds, privacy: .public) s")
                }
                await dispatch(.selectionRequested(select))
            case .pointerEvent(let event):
                adaptive.noteInput()
                if admitsInput(isRelease: event.action == .up) { injector?.handle(event) }
            case .scrollEvent(let event):
                adaptive.noteInput()
                if admitsInput(isRelease: false) { injector?.handle(event) }
            case .keyEvent(let event):
                adaptive.noteInput()
                if admitsInput(isRelease: !event.isDown) { injector?.handle(event) }
            case .textInput(let input):
                guard admitsInput(isRelease: false), let injector else { break }
                // More than one key event's worth (a dictation, a paste from the iPad) is pasted:
                // Chromium and Electron apps drop keys from a fast burst of typed text.
                if input.text.utf16.count > 16, let clipboard {
                    await clipboard.paste(input.text) { injector.pressPaste() }
                } else {
                    injector.typeText(input.text)
                }
            case .clipboard(let payload):
                // Awaited, so a ⌘V the client sends right behind its clipboard pastes this one.
                if let clipboard { await clipboard.apply(payload) }
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
            case .dictationControl(let control):
                handleDictation(control)
            case .micAudio(let audio):
                if dictationClips.append(audio) == .truncated {
                    log.error("dictation clip reached the length cap; dropping later audio")
                }
            case .audioRequest(let request):
                guard clientTakesAudio else { break } // never send audio kinds to a client that didn't ask for them
                if request.enabled { await startAudio() } else { await stopAudio() }
            case .curtainRequest(let request):
                await handleCurtain(request.enabled)
            case .disconnect:
                return
            default:
                break
            }
        }
    }

    /// Raises or lowers the curtain and says how that went. A host with no curtain (synthetic)
    /// only pretends: there's no real desktop behind its picture.
    private func handleCurtain(_ enabled: Bool) async {
        var status = CurtainStatus(isUp: enabled)
        if let curtain = env.curtain {
            let channel = self.channel
            let problem = await curtain.set(enabled, for: ObjectIdentifier(self), fromThisComputer: isLoopbackPeer) { status in
                channel.sendDetached(.curtainStatus(status))
            }
            guard state == .streaming else {
                // The session ended while the curtain was going up: nobody's left to hold it.
                await curtain.sessionEnded(ObjectIdentifier(self))
                return
            }
            if let problem { status = CurtainStatus(isUp: false, unavailable: problem) }
        }
        guard state == .streaming else { return }
        log.info("curtain request \(enabled): up \(status.isUp)")
        channel.sendDetached(.curtainStatus(status))
    }

    /// The curtain's windows came or went: the capture's filter follows.
    func curtainWindowsChanged() async {
        await capture?.refreshFilter()
    }

    private var isLoopbackPeer: Bool { peerHost == "::1" || peerHost.hasPrefix("127.") }

    /// A files-only session's primary connection: it only keeps the session (and its token) alive.
    /// Anything that would touch the screen, input, audio, or clipboard is ignored.
    private func filesOnlyLoop() async throws {
        var ignored = 0
        while state == .filesOnly, let message = try await channel.receive() {
            switch message {
            case .ping(let ping):
                channel.sendDetached(.pong(Pong(echoNanos: ping.sentAtNanos)))
            case .disconnect:
                return
            default:
                ignored += 1
                if ignored == 1 { log.error("files-only session ignoring \(String(describing: message.kind), privacy: .public)") }
            }
        }
    }

    // MARK: Streaming

    /// Sets up capture and encoding for `select`. Throws when there's nothing to capture (the
    /// display is asleep: SCK lists none) or capture won't start; callers keep the session.
    @discardableResult
    private func startStreaming(_ select: SelectDisplay) async throws -> (display: DisplayInfo, codec: VideoCodec) {
        let startedAt = MonotonicClock.nanos()
        defer { log.info("stream setup took \((MonotonicClock.nanos() - startedAt) / 1_000_000) ms") }
        await stopCapture()
        guard state == .streaming else { throw SessionError.closed }
        if let captureFailsUntil, now < captureFailsUntil { throw CaptureError.displayNotFound }
        let chosen = try await env.screen.resolve(select)
        guard state == .streaming else { throw SessionError.closed } // ended while displays were listed

        let codec: VideoCodec = select.preferredCodec ?? .hevc
        let startFPS = min(select.targetFPS, 60)
        adaptive = AdaptiveController(startBitrateKbps: bitrateForPixels(chosen.pixelWidth * chosen.pixelHeight, fps: startFPS))

        let epoch = captureEpoch
        let encoder = VideoEncoder(configuration: .init(codec: codec, width: chosen.pixelWidth, height: chosen.pixelHeight, fps: startFPS, bitrateKbps: adaptive.bitrateKbps, maxQP: adaptive.maxQP))
        try encoder.start { [weak self] outcome in
            guard let self else { return }
            Task { await self.emit(outcome, epoch: epoch) }
        }
        self.encoder = encoder

        let frame = CGRect(x: chosen.originX, y: chosen.originY, width: Double(chosen.pointWidth), height: Double(chosen.pointHeight))
        // The injector (and whatever keys it holds) survives capture restarts.
        if let makeInputSink = env.makeInputSink {
            if let injector { injector.updateDisplayFrame(frame) } else { injector = makeInputSink(frame) }
        }

        let capture = env.screen.makeCapture(for: chosen, fps: startFPS, excludingClientOnThisComputer: isLoopbackPeer)
        let captureID = ObjectIdentifier(capture)
        // Known as the current capture before it starts, so a stop that fires while it's starting
        // (`captureStopped` checks the id) isn't lost.
        self.capture = capture
        do {
            try await capture.start(onFrame: { [weak self] frame in
                guard let self else { return }
                Task { await self.ingest(frame, epoch: epoch) }
            }, onStop: { [weak self] error in
                guard let self else { return }
                let reason = error.map { Self.describe($0) } ?? "stopped"
                Task { await self.captureStopped(captureID, reason: reason) }
            })
        } catch {
            if self.capture === capture { self.capture = nil }
            throw error
        }
        guard state == .streaming else { // ended while capture was starting: nothing may keep running
            await capture.stop()
            if self.capture === capture { self.capture = nil }
            encoder.stop()
            self.encoder = nil
            throw SessionError.closed
        }
        guard self.capture === capture else { throw CaptureError.stoppedWhileStarting }

        clipboard?.stop()
        if let makeClipboard = env.makeClipboard {
            let clipboard = self.clipboard ?? makeClipboard()
            clipboard.onLocalChange = { [weak self] payload in
                guard let self else { return }
                Task { await self.sendClipboard(payload) }
            }
            clipboard.start()
            self.clipboard = clipboard
            let initial = clipboard.currentPayload()
            if !initial.isEmpty { channel.sendDetached(.clipboard(initial)) }
        }

        try await channel.send(.streamConfig(StreamConfig(display: chosen, codec: codec, fps: startFPS, bitrateKbps: adaptive.bitrateKbps)))
        currentFPS = startFPS
        needsKeyframe = true
        log.info("streaming display \(chosen.id) at \(chosen.pixelWidth)x\(chosen.pixelHeight) (\(chosen.isVirtual ? "virtual" : chosen.isMain ? "main" : "secondary"), origin \(Int(chosen.originX)),\(Int(chosen.originY)))")
        return (chosen, codec)
    }

    private func ingest(_ frame: CapturedFrame, epoch: UInt64) {
        guard epoch == captureEpoch else { return } // a frame from a capture that was stopped
        let decisions = lifecycle.handle(.frameArrived, now: now)
        if !decisions.isEmpty { Task { await self.apply(decisions) } }
        if !lifecycle.wantsTicks { syncTicker() }
        let (_, fps) = adaptive.observe(dirtyRatio: frame.dirtyRatio)
        if fps != currentFPS {
            currentFPS = fps
            capture?.updateFPS(fps)
            encoder?.setExpectedFrameRate(fps)
        }

        // Idle suppression: skip encoding a static frame (but always honor a pending keyframe).
        if frame.dirtyRatio <= 0.0001 && !needsKeyframe && framesSent > 0 { return }
        // The encoder answers every frame, encoded or dropped; this is the net under that promise.
        if encodesInFlight > 0, let encodeStartedAt, now - encodeStartedAt > Self.encodeLimit {
            log.error("an encode has been in flight for over \(Self.encodeLimit.components.seconds, privacy: .public) s; giving up on it")
            encodesInFlight = 0
            needsKeyframe = true
        }
        guard encodesInFlight < 1 else {
            pendingPixelBuffer = frame.pixelBuffer
            return
        }
        encode(frame.pixelBuffer, ptsNanos: frame.displayNanos)
    }

    /// Longer than this with no word from the encoder means the frame is lost, whatever it says later.
    static let encodeLimit: Duration = .seconds(1)

    private func encode(_ pixelBuffer: CVPixelBuffer, ptsNanos: UInt64) {
        encodesInFlight += 1
        encodeStartedAt = now
        let force = needsKeyframe
        needsKeyframe = false
        encoder?.encode(pixelBuffer, ptsNanos: ptsNanos, forceKeyframe: force)
    }

    private func emit(_ outcome: VideoEncoder.Outcome, epoch: UInt64) {
        guard epoch == captureEpoch else { return } // a stopped encoder's late word
        encodesInFlight = max(0, encodesInFlight - 1)
        switch outcome {
        case .encoded(let output):
            if let config = output.config {
                channel.sendDetached(.videoConfig(config))
            }
            channel.sendDetached(.videoFrame(output.frame))
            framesSent &+= 1
        case .dropped:
            // The client's decoder has a hole now; the next frame fills it.
            needsKeyframe = true
        }
        if let pending = pendingPixelBuffer {
            pendingPixelBuffer = nil
            encode(pending, ptsNanos: MonotonicClock.nanos())
        }
    }

    private func sendClipboard(_ payload: ClipboardPayload) {
        channel.sendDetached(.clipboard(payload))
    }

    private func handle(_ command: HostCommand) async {
        switch command {
        case .sleepDisplay:
            await dispatch(.sleepRequested)
        case .wakeDisplay:
            await dispatch(.wakeRequested) // Wake doubles as Retry while the picture is missing
        case .lockScreen:
            power.lockScreen()
        case .releaseAllInput:
            injector?.releaseAll()
        case .refreshDisplays:
            if let displays = try? await env.screen.displays() {
                channel.sendDetached(.displayList(DisplayList(displays: displays)))
            }
        case .restoreDisplays:
            await env.screen.restoreDisplays()
        }
    }

    // MARK: Dictation

    private func handleDictation(_ control: DictationControl) {
        guard !dictationEngines.isEmpty, let dictation = env.dictation else { return } // Never advertised, so never answer.
        switch control.action {
        case .begin:
            dictationClips.begin(control)
        case .cancel:
            dictationClips.cancel(control.id)
        case .commit:
            guard let clip = dictationClips.commit(control.id) else {
                channel.sendDetached(.dictationResult(DictationResult(id: control.id, text: "", error: "The Mac didn't receive that recording. Try again.")))
                return
            }
            log.info("dictation clip committed: \(clip.samples.count, privacy: .public) bytes, \(clip.droppedPackets, privacy: .public) packets missing")
            // Transcription takes seconds; run it off the session so input keeps flowing.
            Task.detached { [channel, log] in
                let result: DictationResult
                switch await dictation.transcribe(samples: clip.samples, requested: clip.engine, language: clip.language) {
                case .text(let text, let engine):
                    result = DictationResult(id: control.id, text: text, engine: engine)
                    log.debug("dictation result: \(text, privacy: .private)")
                case .failed(let message):
                    result = DictationResult(id: control.id, text: "", error: message)
                }
                channel.sendDetached(.dictationResult(result))
            }
        }
    }

    // MARK: Mac audio

    /// Starts the audio stream: `audioConfig` first (awaited, so it is on the wire before any
    /// packet), then the source feeding the encoder, whose packets go out with `sendDetached`.
    /// Any failure answers with `audioConfig.unavailable` instead.
    private func startAudio() async {
        guard audioSource == nil else { return }
        let started = MonotonicClock.nanos()
        guard let encoder = AudioEncoder(onPacket: { [channel] packet in channel.sendDetached(.audioPacket(packet)) }) else {
            log.error("Opus encoder unavailable")
            channel.sendDetached(.audioConfig(.unavailable("This Mac couldn't set up its audio encoder.")))
            return
        }
        let source = env.audio.makeSource()
        audioSource = source
        audioEncoder = encoder
        do {
            try await channel.send(.audioConfig(encoder.config))
            try await source.start(onBlock: { encoder.encode($0) }, onStop: { [weak self] reason in
                guard let self else { return }
                Task { await self.audioStopped(source, reason: reason) }
            })
        } catch {
            let reason = env.audio.message(for: error)
            log.error("audio didn't start: \(error.localizedDescription, privacy: .public)")
            if audioSource === source {
                audioSource = nil
                audioEncoder = nil
                channel.sendDetached(.audioConfig(.unavailable(reason)))
            }
            await source.stop()
            return
        }
        guard audioSource === source else { // stopped while starting
            await source.stop()
            return
        }
        audioStartedAt = MonotonicClock.nanos()
        log.info("audio started in \((self.audioStartedAt - started) / 1_000_000, privacy: .public) ms")
    }

    private func stopAudio() async {
        guard let source = audioSource else { return }
        let packets = audioEncoder?.packetCount ?? 0
        audioSource = nil
        audioEncoder = nil
        await source.stop()
        log.info("audio stopped after \(packets, privacy: .public) packets")
    }

    /// Capture stopped on its own (SCK error): tell the client why.
    private func audioStopped(_ source: any AudioSource, reason: String) async {
        guard audioSource === source else { return }
        await stopAudio()
        channel.sendDetached(.audioConfig(.unavailable(reason)))
    }

    // MARK: Files

    /// A second connection presented this session's token: run file transfers on it. Anything
    /// but a live, file-capable session with no file channel yet closes it. Once attached, the
    /// channel belongs to the controller and outlives this session: the client closes it when its
    /// files are done.
    func attachFileChannel(_ fileChannel: MessageChannel) async {
        guard state == .streaming || state == .filesOnly, clientTakesFiles, fileEngine == nil else {
            log.error("refusing a file channel (session \(String(describing: self.state), privacy: .public), files \(self.clientTakesFiles, privacy: .public))")
            await fileChannel.close()
            return
        }
        let destination = env.fileDestination()
        var configuration = destination.configuration
        // A file cut off earlier keeps writing to its partial, even if Settings → Files moved the
        // receive folder since.
        configuration.partialDirectory = { ResumeFolders.shared.folder(for: $0) }
        let engine = FileTransferEngine(channel: fileChannel, role: .host, configuration: configuration)
        fileEngine = engine
        log.info("file channel attached; receiving into \(destination.directory.path(percentEncoded: false), privacy: .public)")
        let host = peerHost, fallback = clientName, peers = env.peers
        Task { await engine.run() }
        // The name it has under Paired Devices, unless that's still iOS's "iPad"; then the
        // tailnet's, which knows which iPad.
        let chosen = trust.name(ofFingerprint: clientKey).flatMap { Self.isGenericName($0) ? nil : $0 }
        let name: String
        if let chosen { name = chosen } else { name = await Task.detached { peers?.deviceName(ofPeer: host) }.value ?? fallback }
        onFileChannel(HostFileChannel(session: self, engine: engine, clientName: name, clientKey: clientKey,
                                      receiveDirectory: destination.directory, clientIsMac: clientModel.hasPrefix("Mac"),
                                      isFilesOnly: state == .filesOnly))
    }

    /// What iOS and visionOS call every device, now that apps can't read the name its owner gave it.
    nonisolated static func isGenericName(_ name: String) -> Bool {
        ["iPad", "iPhone", "iPod touch", "Apple Vision Pro"].contains(name)
    }

    /// iOS tells every app the device is "iPad", so two iPads would pair under one name; ask the
    /// tailnet which one this is, off the handshake path.
    private func nameFromTailnet(_ fingerprint: String) {
        guard let peers = env.peers, let current = trust.name(ofFingerprint: fingerprint), Self.isGenericName(current) else { return }
        let host = peerHost, trust = trust
        Task.detached {
            guard let name = peers.deviceName(ofPeer: host) else { return }
            trust.adoptTailnetName(name, fingerprint: fingerprint)
        }
    }

    private func handleViewportChange(_ viewport: Viewport) async {
        // Geometry is immutable for the life of a connection; a viewport change forces a keyframe.
        needsKeyframe = true
    }

    // MARK: Keeping the picture coming

    /// Hands the lifecycle an event and carries out what it decides.
    private func dispatch(_ event: CaptureLifecycle.Event) async {
        guard state == .streaming else { return }
        await apply(lifecycle.handle(event, now: now))
        syncTicker()
    }

    private func apply(_ decisions: [CaptureLifecycle.Decision]) async {
        for decision in decisions {
            guard state == .streaming else { return }
            switch decision {
            case .startCapture(let request):
                await execute(request)
            case .stopCapture(let reason):
                await stopCapture()
                needsKeyframe = true
                log.info("capture stopped (\(reason, privacy: .public)); display \(self.power.isDisplayAsleep ? "asleep" : "awake", privacy: .public)")
            case .sendStatus(let status):
                channel.sendDetached(.hostStatus(status))
            case .wakeDisplay(let reason):
                power.wakeDisplay(reason: reason, minimumInterval: .zero)
            case .sleepDisplay:
                power.sleepDisplay()
            case .refreshStatus:
                lockMonitor.refresh()
            case .beginMonitoring:
                // Session-long pieces, set up with the first stream and kept through capture restarts.
                power.keepAwake()
                lockMonitor.onChange = { [weak self] _ in
                    guard let self else { return }
                    Task { await self.hostStatusChanged() }
                }
                lockMonitor.start()
                await dispatch(.statusChanged(lockMonitor.currentStatus()))
            case .requestKeyframe:
                needsKeyframe = true
            case .note(let text):
                log.info("\(text, privacy: .public)")
            }
        }
    }

    /// One capture start: the targets in order until one comes up, then the lifecycle hears
    /// which display and codec it got, or that every target failed.
    private func execute(_ request: CaptureLifecycle.StartRequest) async {
        if request.wakesSleepingDisplay, power.isDisplayAsleep { await wakeDisplayForStreaming() }
        if request.wakesDarkPanel {
            let panel = power.panel
            log.error("\(request.reason, privacy: .public): \(panel.text, privacy: .public); trying again")
            if panel.isOff { power.wakeDisplay(reason: "capture unavailable, display still off", minimumInterval: .seconds(2)) }
        } else {
            log.info("starting capture: \(request.reason, privacy: .public)")
        }
        var failure = ""
        for target in request.targets {
            guard state == .streaming else { return }
            do {
                let started = try await startStreaming(target)
                await dispatch(.captureStarted(display: started.display, codec: started.codec))
                return
            } catch {
                failure = Self.describe(error)
                log.error("capture didn't start: \(failure, privacy: .public)\(self.power.isDisplayAsleep ? " (display asleep)" : "", privacy: .public)")
            }
        }
        await dispatch(.captureFailed(reason: failure))
    }

    /// Runs the lifecycle's ticks (every 250 ms) only while it has something to watch.
    private func syncTicker() {
        if lifecycle.wantsTicks {
            guard ticker == nil else { return }
            ticker = Task { [weak self, clock = env.clock] in
                while !Task.isCancelled {
                    try? await clock.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled, let self else { return }
                    await self.dispatch(.tick)
                }
            }
        } else {
            ticker?.cancel()
            ticker = nil
        }
    }

    /// Lock, secure input, or display sleep changed, as the monitor saw it.
    private func hostStatusChanged() async {
        await dispatch(.statusChanged(lockMonitor.currentStatus()))
    }

    /// Whether input may reach the screen: while the display is asleep it wakes it (at most once
    /// a second) instead, except releases, which still go through so nothing stays held.
    private func admitsInput(isRelease: Bool) -> Bool {
        switch lifecycle.admitsInput(isRelease: isRelease, now: now) {
        case .deliver: return true
        case .drop: return false
        case .wakeThenDrop:
            if power.wakeDisplay(reason: "input while asleep", minimumInterval: .seconds(1)) { lockMonitor.refresh() }
            return false
        }
    }

    /// Wakes the display and waits (up to ~3 s) for ScreenCaptureKit to list it again.
    private func wakeDisplayForStreaming() async {
        power.wakeDisplay(reason: "client connected", minimumInterval: .zero)
        let started = now
        while now - started < .seconds(3) {
            if !power.isDisplayAsleep, let displays = try? await env.screen.displays(), !displays.isEmpty { break }
            try? await env.clock.sleep(for: .milliseconds(150))
        }
        log.info("display \(self.power.isDisplayAsleep ? "still asleep" : "awake", privacy: .public) after \((self.now - started).formatted(.units(allowed: [.milliseconds])), privacy: .public)")
    }

    /// ScreenCaptureKit stopped the stream by itself: the display went to sleep (it then lists
    /// no displays: "Failed to find any displays or windows to capture") or changed. The
    /// session, input, and power state carry on; only capture waits.
    private func captureStopped(_ id: ObjectIdentifier, reason: String) async {
        guard let capture, ObjectIdentifier(capture) == id else { return }
        // The encoder goes too (a late result from it would be a frame of a stopped capture);
        // the restart makes a new one.
        await stopCapture()
        needsKeyframe = true
        log.info("capture stopped (\(reason, privacy: .public)); display \(self.power.isDisplayAsleep ? "asleep" : "awake", privacy: .public)")
        await dispatch(.captureStopped(reason: reason))
    }

    /// The controller saw the displays wake or change: rebuild capture so it follows.
    func restartCapture() async {
        await dispatch(.displaysChanged)
    }

    /// Stops capture and encoding only; input, power, and status monitoring stay.
    private func stopCapture() async {
        captureEpoch &+= 1
        await capture?.stop()
        capture = nil
        encoder?.stop()
        encoder = nil
        pendingPixelBuffer = nil
        encodesInFlight = 0
        encodeStartedAt = nil
    }

    private func stopStreaming() async {
        ticker?.cancel()
        ticker = nil
        await stopCapture()
        injector?.releaseAll()
        injector = nil
        clipboard?.stop()
        lockMonitor.stop()
        power.releaseKeepAwake()
    }

    nonisolated private static func describe(_ error: any Error) -> String {
        let error = error as NSError
        return "\(error.domain) \(error.code): \(error.localizedDescription)"
    }

    /// The device was just revoked: tell it why and end the session, screen or files-only.
    func endIfClient(_ key: String) async {
        guard clientKey == key, state != .closed else { return }
        try? await channel.send(.disconnect(DisconnectMessage(reason: "This device was removed from the Mac.")))
        await teardown()
    }

    private func teardown() async {
        guard state != .closed else { return }
        let wasFilesOnly = state == .filesOnly
        state = .closed
        attachTokens.revoke(owner: self)
        // The channel goes first, so a receive loop still running ends now and nothing it was
        // about to do (a curtain request, a display change, input) lands on a dead session.
        await channel.close()
        if let curtain = env.curtain {
            await curtain.sessionEnded(ObjectIdentifier(self))
        }
        // The file channel, if any, carries on without the session (see `attachFileChannel`); a
        // files-only session never started anything else.
        if !wasFilesOnly {
            dictationClips.removeAll()
            await stopAudio()
            await stopStreaming()
        }
        onEnded(self)
    }

    private func bitrateForPixels(_ pixels: Int, fps: Int) -> Int {
        // ~0.08 bits/pixel/frame baseline for crisp screen content.
        let bits = Double(pixels) * Double(fps) * 0.08
        return Int(min(60_000, max(4_000, bits / 1000)))
    }
}

/// Where each file cut off mid-receive left its partial, so whichever channel resumes it (a new
/// one, maybe after the receive folder changed) keeps writing to the same file. Set when a
/// receive pauses, cleared when it finishes, is cancelled, or expires.
nonisolated final class ResumeFolders: Sendable {
    static let shared = ResumeFolders()
    private let folders = Mutex<[UUID: URL]>([:])

    func folder(for id: UUID) -> URL? { folders.withLock { $0[id] } }
    func set(_ folder: URL?, for id: UUID) { folders.withLock { $0[id] = folder } }
}

/// A session's live file channel, as the controller and menu see it.
struct HostFileChannel: Sendable, Identifiable {
    let session: HostSession
    let engine: FileTransferEngine
    /// Who is on the other end ("Drew's iPad Pro").
    let clientName: String
    /// The iPad's key fingerprint, the same on every connection it makes.
    let clientKey: String
    /// Where its engine saves received files (the Settings choice when it attached).
    let receiveDirectory: URL
    /// A Mac client keeps what it receives in Downloads; an iPad in Files › Vantage.
    var clientIsMac = false
    /// Where the other end will find a file the Mac sends it, for the panel and the notification.
    var clientDestination: String { clientIsMac ? "Downloads" : "Files, in the Casement folder" }
    /// Opened by a files-only session (no screen), e.g. Send Files from the iPad's device list.
    var isFilesOnly = false
    /// The session that issued the token has ended; the channel carries on until the iPad closes
    /// it (or it sits idle for `HostController.detachedIdleLimit`).
    var sessionEnded = false
    var id: ObjectIdentifier { ObjectIdentifier(session) }
}

enum SessionError: Error {
    case badHandshake
    case versionMismatch
    case authFailed
    case pairingRequired
    /// The session ended (the device was removed, the connection closed) while something was starting.
    case closed
}
