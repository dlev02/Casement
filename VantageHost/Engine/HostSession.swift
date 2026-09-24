import AppKit
import CoreGraphics
import Foundation
import Network
import VantageCore
import os

/// One authenticated client session: authenticates the peer, negotiates a display, then runs the
/// capture → encode → send pipeline and applies incoming input, clipboard, and commands.
///
/// A files-only session (`ClientFeatures.filesOnly`) stops after authenticating: it hands out a
/// file channel token and answers pings, and never touches displays, capture, input, audio, the
/// clipboard, the lock monitor, or power assertions, whatever the client sends.
actor HostSession {
    enum State: Equatable { case handshaking, streaming, filesOnly, closed }

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
    /// The client's key fingerprint: which iPad this is across connections.
    private var clientKey = ""
    /// Tells the controller a file channel is up (for the menu, notifications, and sending).
    private let onFileChannel: @Sendable (HostFileChannel) -> Void
    // Display sleep: the session outlives it. Capture stops while the display is off (SCK lists
    // no displays then) and comes back on wake; input while asleep wakes it.
    /// What the client last asked to stream, which capture returns to after a sleep or a failure.
    private var wantedSelection: SelectDisplay?
    private var streamStarting = false
    private var pendingStart: SelectDisplay?
    private var captureStartedAt: ContinuousClock.Instant?
    // Awake but no picture: since when, why, the retry schedule, and whether the client knows.
    private var captureLostAt: ContinuousClock.Instant?
    private var captureLossReason = ""
    private var nextRecoveryAttempt = ContinuousClock.now
    private var recoveryDelay: Duration = .milliseconds(500)
    private var recoveryTask: Task<Void, Never>?
    private var screenUnavailable = false
    /// `--capture-fails-for` (DEBUG): capture fails until then.
    private var captureFailsUntil: ContinuousClock.Instant?
    private var monitoring = false
    private var displayAsleep = false
    /// When this session put the display to sleep; input in the next moment doesn't wake it.
    private var sleptAt: ContinuousClock.Instant?

    init(channel: MessageChannel, identity: DeviceIdentity, trust: TrustStore, peerDescription: String, peerHost: String,
         attachTokens: AttachTokenRegistry<HostSession>, onFileChannel: @escaping @Sendable (HostFileChannel) -> Void,
         onEnded: @escaping @Sendable (HostSession) -> Void) {
        self.channel = channel
        self.identity = identity
        self.trust = trust
        self.peerDescription = peerDescription
        self.peerHost = peerHost
        self.attachTokens = attachTokens
        self.onFileChannel = onFileChannel
        self.onEnded = onEnded
    }

    /// Runs the session on a started channel whose first message, `hello`, the controller has
    /// already read (it reads one message to tell sessions from file channels).
    func run(hello: Hello) async {
        do {
            log.info("channel ready; handshaking")
            if try await handshake(hello) {
                if state == .filesOnly { try await filesOnlyLoop() } else { try await receiveLoop() }
            }
        } catch {
            log.error("session error: \(error.localizedDescription, privacy: .public)")
        }
        await teardown()
    }

    // MARK: Handshake

    private func handshake(_ hello: Hello) async throws -> Bool {
        guard hello.protocolVersion == VantageProtocol.version else {
            try await channel.send(.authResult(AuthResult(status: .versionMismatch, message: "Protocol \(VantageProtocol.version) required")))
            throw SessionError.versionMismatch
        }

        let nonce = AuthTranscript.randomNonce()
        let isPaired = trust.isTrusted(hello.clientPublicKey)
        let lightweight = hello.isReadinessProbe == true || hello.features?.filesOnly == true
        let challenge = Challenge(hostName: Host.current().localizedName ?? "Mac", hostVersion: "1.0", hostPublicKey: identity.publicKeyData, nonce: nonce, isPaired: isPaired, peerTailnetName: lightweight ? nil : TailscaleCLI.whois(addr: peerDescription))
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

        if hello.features?.filesOnly == true {
            // Files need no Screen Recording grant and no display: just the file channel's ticket.
            guard hello.features?.fileTransfer == true else {
                try await channel.send(.authResult(AuthResult(status: .denied, message: "Nothing to do on this connection.")))
                throw SessionError.authFailed
            }
            clientTakesFiles = true
            clientName = hello.clientName
            clientKey = DeviceIdentity.fingerprint(of: hello.clientPublicKey)
            let token = attachTokens.issue(for: self, peer: peerHost)
            let capabilities = HostCapabilities(codecs: [], canManageVirtualDisplay: false, clipboard: false, maxFPS: 0,
                                                fileTransfer: true, filesOnlySessions: true)
            try await channel.send(.authResult(AuthResult(status: .ok, sessionToken: token, capabilities: capabilities)))
            state = .filesOnly
            log.info("files-only session for \(hello.clientName)")
            return true
        }

        if !HostOptions.shared.syntheticCapture, !ScreenCapture.preflightPermission() {
            try await channel.send(.authResult(AuthResult(status: .denied,
                message: "On the Mac, grant Screen Recording to Vantage Host in System Settings → Privacy & Security, then reopen Vantage Host and retry.")))
            throw SessionError.authFailed
        }
        // A sleeping display lists no displays at all, so wake it before looking.
        if DisplayPower.isAsleep() { await wakeDisplayForStreaming() }
        let displays = try await DisplayEnumerator.availableDisplays()
        // Dictation kinds are new, so they're advertised only to a client that said it knows them.
        if hello.features?.dictation == true { dictationEngines = await HostTranscriber.availableEngines() }
        clientTakesAudio = hello.features?.macAudio == true
        clientTakesFiles = hello.features?.fileTransfer == true
        clientName = hello.clientName
        clientKey = DeviceIdentity.fingerprint(of: hello.clientPublicKey)
        // The file channel's ticket in: single use, from this address only, gone with the session.
        let token = clientTakesFiles ? attachTokens.issue(for: self, peer: peerHost) : nil
        // Audio rides on the Screen Recording grant checked above (synthetic mode sends a chime),
        // so a session that got this far can always offer it.
        let capabilities = HostCapabilities(codecs: [.hevc, .h264], canManageVirtualDisplay: VirtualDisplayManager().isAvailable, clipboard: true, maxFPS: 60,
                                            dictationEngines: hello.features?.dictation == true ? dictationEngines : nil,
                                            audio: true, fileTransfer: clientTakesFiles ? true : nil,
                                            filesOnlySessions: clientTakesFiles ? true : nil)
        try await channel.send(.authResult(AuthResult(status: .ok, sessionToken: token, displays: displays, capabilities: capabilities)))
        state = .streaming
        log.info("client authenticated: \(hello.clientName)")
        return true
    }

    // MARK: Message loop

    private func receiveLoop() async throws {
        while let message = try await channel.receive() {
            switch message {
            case .selectDisplay(let select):
                await selectDisplay(select)
            case .pointerEvent(let event):
                if admitsInput(isRelease: event.action == .up) { injector?.handle(event) }
            case .scrollEvent(let event):
                if admitsInput(isRelease: false) { injector?.handle(event) }
            case .keyEvent(let event):
                if admitsInput(isRelease: !event.isDown) { injector?.handle(event) }
            case .textInput(let input):
                if admitsInput(isRelease: false) { injector?.typeText(input.text) }
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
            case .dictationControl(let control):
                handleDictation(control)
            case .micAudio(let audio):
                if dictationClips.append(audio) == .truncated {
                    log.error("dictation clip reached the length cap; dropping later audio")
                }
            case .audioRequest(let request):
                guard clientTakesAudio else { break } // never send audio kinds to a client that didn't ask for them
                if request.enabled { await startAudio() } else { await stopAudio() }
            case .disconnect:
                return
            default:
                break
            }
        }
    }

    /// A files-only session's primary connection: it only keeps the session (and its token) alive.
    /// Anything that would touch the screen, input, audio, or clipboard is ignored.
    private func filesOnlyLoop() async throws {
        var ignored = 0
        while let message = try await channel.receive() {
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
    private func startStreaming(_ select: SelectDisplay) async throws {
        let startedAt = MonotonicClock.nanos()
        defer { log.info("stream setup took \((MonotonicClock.nanos() - startedAt) / 1_000_000) ms") }
        await stopCapture()
        // The pretend display fails the way ScreenCaptureKit does while the screen is off.
        if DisplayPower.fake.isEnabled, DisplayPower.fake.isAsleep { throw CaptureError.displayNotFound }
        if let captureFailsUntil, ContinuousClock.now < captureFailsUntil { throw CaptureError.displayNotFound }
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
            if all.isEmpty { log.error("ScreenCaptureKit lists no displays (main \(mainID), asleep \(DisplayPower.isAsleep()))") }
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
        // The injector (and whatever keys it holds) survives capture restarts.
        if !HostOptions.shared.syntheticCapture {
            if let injector { injector.updateDisplayFrame(frame) } else { injector = InputInjector(displayFrame: frame) }
        }
        #if DEBUG
        InputEventLog.startIfRequested()
        #endif

        let capture: any FrameSource = HostOptions.shared.syntheticCapture
            ? SyntheticFrameSource(pixelWidth: chosen.pixelWidth, pixelHeight: chosen.pixelHeight, fps: startFPS)
            : ScreenCapture(displayID: chosen.id, pixelWidth: chosen.pixelWidth, pixelHeight: chosen.pixelHeight, fps: startFPS)
        let captureID = ObjectIdentifier(capture)
        try await capture.start(onFrame: { [weak self] frame in
            guard let self else { return }
            Task { await self.ingest(frame) }
        }, onStop: { [weak self] error in
            guard let self else { return }
            let reason = error.map { Self.describe($0) } ?? "stopped"
            Task { await self.captureStopped(captureID, reason: reason) }
        })
        self.capture = capture
        captureStartedAt = .now

        clipboard.stop()
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
        needsKeyframe = true
        log.info("streaming display \(chosen.id) at \(chosen.pixelWidth)x\(chosen.pixelHeight) (\(chosen.isVirtual ? "virtual" : chosen.isMain ? "main" : "secondary"), origin \(Int(chosen.originX)),\(Int(chosen.originY)))")
    }

    private func ingest(_ frame: CapturedFrame) {
        if captureLostAt != nil { captureRecovered() }
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
        // The pretend display (`--display-asleep`) sleeps and wakes on a synthetic host too.
        let controlsDisplay = !HostOptions.shared.syntheticCapture || DisplayPower.fake.isEnabled
        switch command {
        case .sleepDisplay where controlsDisplay:
            sleptAt = .now
            HostCommandRunner.sleepDisplay()
            lockMonitor.refresh()
            return
        case .wakeDisplay:
            if controlsDisplay {
                sleptAt = nil
                power.wakeDisplay(reason: "Wake command")
                lockMonitor.refresh()
            }
            await retryCaptureNow() // Wake doubles as Retry while the picture is missing
            return
        default:
            break
        }
        guard !HostOptions.shared.syntheticCapture else { return }
        switch command {
        case .lockScreen: HostCommandRunner.lockScreen()
        case .sleepDisplay, .wakeDisplay: break
        case .releaseAllInput: injector?.releaseAll()
        case .refreshDisplays:
            if let displays = try? await DisplayEnumerator.availableDisplays() {
                channel.sendDetached(.displayList(DisplayList(displays: displays)))
            }
        case .restoreDisplays:
            VirtualDisplayManager().disconnect()
        }
    }

    // MARK: Dictation

    private func handleDictation(_ control: DictationControl) {
        guard !dictationEngines.isEmpty else { return } // Never advertised, so never answer.
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
                do {
                    let output = try await HostTranscriber.live().transcribe(samples: clip.samples, requested: clip.engine, language: clip.language)
                    result = DictationResult(id: control.id, text: output.text, engine: output.engine)
                    log.debug("dictation result: \(output.text, privacy: .private)")
                } catch {
                    result = DictationResult(id: control.id, text: "", error: (error as? HostTranscriber.Failure)?.message ?? "Transcription failed on the Mac.")
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
        let synthetic = HostOptions.shared.syntheticCapture
        let source: any AudioSource = synthetic ? SyntheticAudioSource() : AudioCapture()
        audioSource = source
        audioEncoder = encoder
        do {
            try await channel.send(.audioConfig(encoder.config))
            try await source.start(onBlock: { encoder.encode($0) }, onStop: { [weak self] reason in
                guard let self else { return }
                Task { await self.audioStopped(source, reason: reason) }
            })
        } catch {
            let reason = AudioCapture.message(for: error)
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
        log.info("audio started (\(synthetic ? "synthetic chime" : "ScreenCaptureKit", privacy: .public)) in \((self.audioStartedAt - started) / 1_000_000, privacy: .public) ms")
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
        let store = HostFileStore.current
        let engine = FileTransferEngine(channel: fileChannel, role: .host, configuration: store.configuration)
        fileEngine = engine
        log.info("file channel attached; receiving into \(store.directory.path(percentEncoded: false), privacy: .public)")
        let host = peerHost, fallback = clientName
        Task { await engine.run() }
        // The tailnet knows the device's real name; the app only gets "iPad" from iOS.
        let name = await Task.detached { TailscaleCLI.deviceName(host: host) }.value ?? fallback
        onFileChannel(HostFileChannel(session: self, engine: engine, clientName: name, clientKey: clientKey,
                                      receiveDirectory: store.directory, isFilesOnly: state == .filesOnly))
    }

    private func handleViewportChange(_ viewport: Viewport) async {
        // Geometry is immutable for the life of a connection; a viewport change forces a keyframe.
        needsKeyframe = true
    }

    // MARK: Display sleep and capture restarts

    /// The client asked for a stream. Wakes a sleeping display first; if capture still can't
    /// start, the session stays up, the client hears why (`HostStatus.isDisplayAsleep`), and
    /// capture comes back on its own. Ending the session here made the client reconnect in a loop.
    private func selectDisplay(_ select: SelectDisplay) async {
        wantedSelection = select
        if captureFailsUntil == nil, let seconds = HostOptions.shared.captureFailsForSeconds {
            captureFailsUntil = .now + .seconds(seconds)
            log.info("--capture-fails-for: capture fails for \(seconds, privacy: .public) s")
        }
        startMonitoring()
        if DisplayPower.isAsleep() { await wakeDisplayForStreaming() }
        if await startStream(select) == false { captureUnavailable() }
    }

    /// Lock, secure input, display sleep, plus whether the picture is missing while awake.
    private func currentStatus() -> HostStatus {
        var status = lockMonitor.currentStatus()
        status.isScreenUnavailable = screenUnavailable && status.isDisplayAsleep != true
        return status
    }

    /// Session-long pieces, set up with the first stream and kept through capture restarts.
    private func startMonitoring() {
        guard !monitoring else { return }
        monitoring = true
        power.begin()
        lockMonitor.onChange = { [weak self] _ in
            guard let self else { return }
            Task { await self.hostStatusChanged() }
        }
        lockMonitor.start()
        let status = currentStatus()
        displayAsleep = status.isDisplayAsleep == true
        channel.sendDetached(.hostStatus(status))
    }

    /// Lock, secure input, or display sleep changed: tell the client, and bring capture back
    /// when the display wakes.
    private func hostStatusChanged() async {
        guard state == .streaming else { return }
        let status = currentStatus() // the latest, whatever order the notices came in
        channel.sendDetached(.hostStatus(status))
        let asleep = status.isDisplayAsleep == true
        guard asleep != displayAsleep else {
            // Capture waiting on something else (a lock screen lists no displays either): try
            // again now that the Mac changed, rather than at the next backoff step.
            if !asleep, capture == nil, wantedSelection != nil, !streamStarting { await restartStream(reason: "Mac state changed") }
            return
        }
        displayAsleep = asleep
        if asleep {
            log.info("display went to sleep; the session stays up")
            // The asleep state explains the missing picture; the clock restarts on wake.
            captureLostAt = nil
            screenUnavailable = false
            // ScreenCaptureKit stops its stream by itself; the pretend display does the same.
            if DisplayPower.fake.isEnabled, let capture { await captureStopped(ObjectIdentifier(capture), reason: "display asleep") }
        } else {
            log.info("display woke")
            sleptAt = nil
            needsKeyframe = true
            if capture == nil { await restartStream(reason: "display woke") }
        }
    }

    /// Input while the display is asleep wakes it (at most once a second) rather than reaching
    /// a screen nobody can see; releases still go through so nothing stays held. Input in the
    /// moment after Sleep Display (the hand that chose it) doesn't count.
    private func admitsInput(isRelease: Bool) -> Bool {
        guard displayAsleep else { return true }
        if isRelease { return true }
        if let sleptAt, ContinuousClock.now - sleptAt < .seconds(2) { return false }
        if power.wakeDisplay(reason: "input while asleep", minimumInterval: .seconds(1)) { lockMonitor.refresh() }
        return false
    }

    /// Wakes the display and waits (up to ~3 s) for ScreenCaptureKit to list it again.
    private func wakeDisplayForStreaming() async {
        power.wakeDisplay(reason: "client connected")
        let started = ContinuousClock.now
        while ContinuousClock.now - started < .seconds(3) {
            if !DisplayPower.isAsleep() {
                if HostOptions.shared.syntheticCapture { break }
                if let displays = try? await DisplayEnumerator.shareableDisplays(), !displays.isEmpty { break }
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        log.info("display \(DisplayPower.isAsleep() ? "still asleep" : "awake", privacy: .public) after \((ContinuousClock.now - started).formatted(.units(allowed: [.milliseconds])), privacy: .public)")
    }

    /// Starts or restarts the stream, one at a time. Nil means another start was running; it
    /// takes this request over once it's done.
    private func startStream(_ select: SelectDisplay) async -> Bool? {
        if streamStarting {
            pendingStart = select
            return nil
        }
        streamStarting = true
        defer { streamStarting = false }
        var next: SelectDisplay? = select
        var started = false
        while let current = next {
            pendingStart = nil
            do {
                try await startStreaming(current)
                started = true
            } catch {
                started = false
                captureLossReason = Self.describe(error)
                log.error("capture didn't start: \(self.captureLossReason, privacy: .public)\(DisplayPower.isAsleep() ? " (display asleep)" : "", privacy: .public)")
            }
            next = pendingStart
        }
        return started
    }

    // MARK: Awake but no picture

    /// Capture is down while the client waits. A sleeping display comes back through the wake
    /// notice; anything else gets a watchdog: retries with backoff (0.5 s doubling to 5 s) for as
    /// long as the session lasts, tells the client after 3 s (`HostStatus.isScreenUnavailable`,
    /// so it never shows a frozen frame without saying why), and wakes a panel that's still off.
    private func captureUnavailable() {
        guard state == .streaming, wantedSelection != nil, capture == nil else { return }
        channel.sendDetached(.hostStatus(currentStatus()))
        guard !DisplayPower.isAsleep() else { return }
        if captureLostAt == nil {
            captureLostAt = .now
            recoveryDelay = .milliseconds(500)
            nextRecoveryAttempt = .now + recoveryDelay
        }
        guard recoveryTask == nil else { return }
        recoveryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self, await self.recoveryTick() else { return }
            }
        }
    }

    /// One watchdog tick; false once there's nothing left to recover.
    private func recoveryTick() async -> Bool {
        guard state == .streaming, wantedSelection != nil, let lostAt = captureLostAt, !DisplayPower.isAsleep() else {
            recoveryTask = nil
            return false
        }
        let now = ContinuousClock.now
        let seconds = Int((now - lostAt).components.seconds)
        if seconds >= 3, !screenUnavailable {
            screenUnavailable = true
            log.error("capture unavailable for \(seconds, privacy: .public) s: \(self.captureLossReason, privacy: .public); telling the client")
            channel.sendDetached(.hostStatus(currentStatus()))
        }
        // A capture that started but never sent a frame counts as failed after 5 s.
        if let capture, let captureStartedAt, now - captureStartedAt > .seconds(5) {
            captureLossReason = "capture started but sent no frames"
            await captureStopped(ObjectIdentifier(capture), reason: captureLossReason)
        }
        guard capture == nil, !streamStarting, now >= nextRecoveryAttempt else { return true }
        let panel = DisplayPower.panelDescription()
        log.error("capture unavailable for \(seconds, privacy: .public) s: \(self.captureLossReason, privacy: .public); \(panel.text, privacy: .public); trying again")
        if panel.isOff {
            power.wakeDisplay(reason: "capture unavailable, display still off", minimumInterval: .seconds(2))
        }
        await restartStream(reason: "capture unavailable for \(seconds) s")
        recoveryDelay = min(recoveryDelay * 2, .seconds(5))
        nextRecoveryAttempt = .now + recoveryDelay
        return true
    }

    /// Frames are flowing again: clear the unavailable state at once.
    private func captureRecovered() {
        guard let lostAt = captureLostAt else { return }
        captureLostAt = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        log.info("capture back after \((ContinuousClock.now - lostAt).formatted(.units(allowed: [.seconds, .milliseconds])), privacy: .public)")
        if screenUnavailable {
            screenUnavailable = false
            channel.sendDetached(.hostStatus(currentStatus()))
        }
    }

    /// The client's Wake/Retry while the picture is missing: try again now, from a short backoff.
    private func retryCaptureNow() async {
        guard captureLostAt != nil, capture == nil else { return }
        recoveryDelay = .milliseconds(500)
        nextRecoveryAttempt = .now + recoveryDelay
        log.info("capture retry asked for by the client")
        if !streamStarting { await restartStream(reason: "client asked to retry") }
    }

    /// ScreenCaptureKit stopped the stream by itself: the display went to sleep (it then lists
    /// no displays: "Failed to find any displays or windows to capture") or changed. The
    /// session, input, and power state carry on; only capture waits.
    private func captureStopped(_ id: ObjectIdentifier, reason: String) async {
        guard let capture, ObjectIdentifier(capture) == id else { return }
        self.capture = nil
        pendingPixelBuffer = nil
        needsKeyframe = true
        await capture.stop()
        log.info("capture stopped (\(reason, privacy: .public)); display \(DisplayPower.isAsleep() ? "asleep" : "awake", privacy: .public)")
        lockMonitor.refresh()
        captureUnavailable()
    }

    /// The controller saw the displays wake or change: rebuild capture so it follows.
    func restartCapture() async {
        guard state == .streaming, wantedSelection != nil, !DisplayPower.isAsleep() else { return }
        // The wake notice just restarted it; don't do it twice.
        if capture != nil, let captureStartedAt, ContinuousClock.now - captureStartedAt < .seconds(2) { return }
        await restartStream(reason: "displays changed")
    }

    /// Brings capture back on the display it was on, or the client's original choice if that
    /// display is gone; failing both, retries later.
    private func restartStream(reason: String) async {
        // A wake arrives as two notices (the controller's and the status monitor's); the start
        // already under way covers both.
        guard state == .streaming, let wanted = wantedSelection, !streamStarting else { return }
        log.info("restarting capture: \(reason, privacy: .public)")
        needsKeyframe = true
        var targets: [SelectDisplay] = []
        // Synthetic displays are made to the viewport, so only the original request rebuilds one.
        if let displayInfo, !HostOptions.shared.syntheticCapture {
            targets.append(SelectDisplay(selection: .display(displayInfo.id), targetFPS: wanted.targetFPS, quality: wanted.quality,
                                         preferredCodec: encoder?.currentCodec ?? wanted.preferredCodec))
        }
        targets.append(wanted)
        for target in targets {
            switch await startStream(target) {
            case true?, nil: return
            case false?: continue
            }
        }
        captureUnavailable()
    }

    /// Stops capture and encoding only; input, power, and status monitoring stay.
    private func stopCapture() async {
        await capture?.stop()
        capture = nil
        encoder?.stop()
        encoder = nil
        pendingPixelBuffer = nil
        encodesInFlight = 0
    }

    private func stopStreaming() async {
        recoveryTask?.cancel()
        recoveryTask = nil
        await stopCapture()
        injector?.releaseAll()
        injector = nil
        clipboard.stop()
        lockMonitor.stop()
        power.end()
    }

    nonisolated private static func describe(_ error: any Error) -> String {
        let error = error as NSError
        return "\(error.domain) \(error.code): \(error.localizedDescription)"
    }

    private func teardown() async {
        guard state != .closed else { return }
        let wasFilesOnly = state == .filesOnly
        state = .closed
        attachTokens.revoke(owner: self)
        // The file channel, if any, carries on without the session (see `attachFileChannel`); a
        // files-only session never started anything else.
        if !wasFilesOnly {
            dictationClips.removeAll()
            await stopAudio()
            await stopStreaming()
        }
        await channel.close()
        onEnded(self)
    }

    private func bitrateForPixels(_ pixels: Int, fps: Int) -> Int {
        // ~0.08 bits/pixel/frame baseline for crisp screen content.
        let bits = Double(pixels) * Double(fps) * 0.08
        return Int(min(60_000, max(4_000, bits / 1000)))
    }
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
}
