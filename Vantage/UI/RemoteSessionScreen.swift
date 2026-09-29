import SwiftUI
import UniformTypeIdentifiers
import VantageCore
import os
#if os(macOS)
import AppKit
#endif

/// Full-screen remote session: shows the video, hosts input capture, overlays the control strip
/// and connection status, and runs the periodic feedback/ping loop.
struct RemoteSessionScreen: View {
    let device: SavedDevice
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(DeviceStore.self) private var store

    /// Takes this Mac's shared `FileLink` in `startSession`, so files keep moving after it closes.
    @State private var session = ClientSession()
    @State private var video = VideoStreamController()
    @State private var input = InputController()
    @State private var stickyModifiers: KeyModifiers = []
    @State private var showKeyboard = false
    @State private var hasVideo = false
    @State private var viewportSize = CGSize(width: 1210, height: 834)
    @Environment(\.displayScale) private var displayScale
    @AppStorage("vantage.trackpadSensitivity") private var trackpadSensitivity = 1.5
    @AppStorage("vantage.touchMode") private var touchMode = InputController.TouchMode.trackpad
    @AppStorage("vantage.softwareKeyboardMode") private var keyboardMode = SoftwareKeyboardMode.unicode
    @State private var toolbarCollapsed = UserDefaults.standard.bool(forKey: "vantage.toolbarCollapsed")
    @State private var toolbarDock = ToolbarDock(rawValue: UserDefaults.standard.string(forKey: "vantage.toolbarDock") ?? "") ?? .bottomLeft
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    /// Where the finger has dragged the strip from its corner. Plain state rather than
    /// `@GestureState`, so the release can animate it back in the same transaction that moves
    /// the corner and the strip travels one path instead of two competing springs.
    @State private var toolbarOffset = CGSize.zero
    /// The strip's resting frame in `toolbarSpace`, measured whenever it isn't being dragged.
    @State private var toolbarFrame = CGRect.zero
    @GestureState private var isDraggingToolbar = false
    @State private var stripTapGuard = StripTapGuard()
    @State private var feedbackTask: Task<Void, Never>?
    @State private var passwordPrompt: PasswordPrompt?
    @State private var newPassword = ""
    @State private var newUsername = ""
    @State private var screenSharingTyping: ScreenSharingTypingState?
    @State private var screenSharingError: String?
    @State private var controlsHidden = false
    @AppStorage("vantage.pencilSqueeze") private var pencilSqueeze = PencilAction.collapseControls
    @AppStorage("vantage.pencilDoubleTap") private var pencilDoubleTap = PencilAction.rightClick
    @AppStorage("vantage.dictationEngine") private var dictationEngine = DictationEnginePreference.mac
    @AppStorage(ControlStripLayout.defaultsKey) private var defaultStripLayout = ControlStripLayout.platformStandard
    @State private var showStripEditor = false
    @State private var dictation = DictationController()
    @State private var macAudio = MacAudioPlayer()
    /// `-VantageMacAudio` (DEBUG) until the user flips the toggle.
    @State private var macAudioOverride = ClientOptions.macAudio
    /// A brief note when Mac audio stopped or couldn't start.
    @State private var macAudioNotice: String?
    @State private var macAudioNoticeTask: Task<Void, Never>?
    // File transfer
    @State private var showFileImporter = false
    @State private var showTransfers = false
    @State private var showDisconnectGuard = false
    /// The file just received, for the notice at the top; clears itself.
    @State private var receivedNotice: FileTransferController.Transfer?
    @State private var receivedNoticeTask: Task<Void, Never>?
    /// Files are being dragged over the Mac's screen.
    @State private var isDropTargeted = ClientOptions.dropHintFixture
    @State private var queuedTestFile = false
    /// Wake was tapped and the Mac's display hasn't come on yet (clears itself after a while so
    /// the button works again if the Mac didn't answer).
    @State private var wakeRequested = false
    @State private var wakeTask: Task<Void, Never>?
    #if os(macOS)
    /// "Send keyboard shortcuts to the Mac" (Settings, the Session menu, the toolbar).
    @AppStorage(MacKeyboardSettings.captureShortcutsKey) private var capturesShortcuts = true
    @AppStorage(MacKeyboardSettings.swapCommandControlKey) private var swapsCommandAndControl = false
    /// Watch without sending the pointer or keys. On by default when the Mac is this one.
    @State private var isViewOnly = false
    /// The session's Mac is the one this app runs on (see `ThisMac`).
    @State private var viewsThisMac = false
    @State private var checkedThisMac = false
    @State private var windowShape = SessionWindowShape()
    #if DEBUG
    @State private var keyProbe = KeyProbe()
    #endif
    #endif

    private var isLive: Bool { session.state == .connected && hasVideo }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            #if canImport(UIKit)
            if session.state == .connected {
                RemoteSessionRepresentable(input: input, video: video, stickyModifiers: stickyModifiers,
                                           pencilSqueeze: pencilSqueeze, pencilDoubleTap: pencilDoubleTap,
                                           onPencilAction: performPencilAction)
                    .ignoresSafeArea()
            }
            #elseif os(macOS)
            if session.state == .connected {
                macSessionSurface
            }
            #endif

            if let screenNote {
                MacScreenNote(kind: screenNote, isWaking: wakeRequested, hasPicture: hasVideo, onWake: wakeDisplay)
                    .transition(.opacity)
            } else if !isLive {
                connectionOverlay
                    .transition(.opacity)
            }

            VStack {
                #if os(macOS)
                if viewsThisMac && session.state == .connected {
                    ThisMacBanner(isViewOnly: isViewOnly)
                        .padding(.top, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                #endif
                // A sleeping Mac also reports its lock screen; the asleep note says enough.
                if let status = session.hostStatus, !session.isDisplayAsleep, status.isScreenLocked || status.isSecureInputActive {
                    HostStatusBanner(status: status)
                        .padding(.top, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let screenSharingTyping {
                    ScreenSharingTypingBadge(state: screenSharingTyping)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let macAudioNotice {
                    MacAudioNotice(message: macAudioNotice)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if isDropTargeted && canSendFiles {
                    DropToSendHint(macName: device.name)
                        .padding(.top, 12)
                        .transition(noticeTransition)
                }
                if let receivedNotice {
                    ReceivedFileNotice(transfer: receivedNotice)
                        .padding(.top, 8)
                        .padding(.horizontal, 16)
                        .transition(noticeTransition)
                }
                if capsuleOnTop {
                    transferCapsule
                        .padding(.top, 12)
                }
                Spacer()
                if !capsuleOnTop {
                    transferCapsule
                        .padding(.bottom, 16)
                }
            }
            #if os(visionOS)
            // The control strip is an ornament under the window; the dictation panel floats over
            // the bottom of the Mac, just above it.
            if session.state == .connected {
                dictationPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(24)
                    .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.4, bounce: 0.15), value: isDictationActive)
            }
            #else
            if session.state == .connected && (!controlsHidden || isDictationActive) {
                GeometryReader { geometry in
                    // The dictation panel stacks on the strip's inner side, so it stays in the
                    // corner the user chose and keeps the middle of the Mac visible.
                    VStack(alignment: toolbarAlignment.horizontal, spacing: 12) {
                        if !toolbarDock.isTop { dictationPanel }
                        if !controlsHidden {
                            controlStrip
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.toolbarSpace)) } action: { frame in
                                    if toolbarOffset == .zero { toolbarFrame = frame }
                                }
                                .offset(toolbarOffset)
                                .simultaneousGesture(DragGesture(minimumDistance: 12, coordinateSpace: .named(Self.toolbarSpace))
                                    .updating($isDraggingToolbar) { _, dragging, _ in dragging = true }
                                    .onChanged { value in
                                        stripTapGuard.dragMoved()
                                        toolbarOffset = ToolbarPlacement(area: toolbarArea(in: geometry.size), frame: toolbarFrame)
                                            .constrained(value.translation)
                                    }
                                    .onEnded { value in
                                        settleToolbar(translation: value.translation,
                                                      predicted: value.predictedEndTranslation, in: geometry.size)
                                    })
                        }
                        if toolbarDock.isTop { dictationPanel }
                    }
                    .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.4, bounce: 0.15), value: isDictationActive)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: toolbarAlignment)
                    .padding(Self.toolbarInsets)
                    // A drag the system cancels (a notification, a system gesture) never ends, so
                    // settle from wherever the strip was left.
                    .onChange(of: isDraggingToolbar) { _, dragging in
                        if !dragging && toolbarOffset != .zero {
                            settleToolbar(translation: toolbarOffset, predicted: toolbarOffset, in: geometry.size)
                        }
                    }
                }
                .coordinateSpace(.named(Self.toolbarSpace))
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
            #endif
        }
        .animation(.smooth(duration: 0.35), value: isLive)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .smooth(duration: 0.35), value: screenNote)
        .onChange(of: screenNote) { _, note in
            wakeTask?.cancel()
            wakeRequested = false
            switch note {
            case .asleep?: AccessibilityNotification.Announcement("The Mac's display is asleep").post()
            case .unavailable?: AccessibilityNotification.Announcement("Waiting for the Mac's screen").post()
            case nil: break
            }
        }
        #if os(visionOS)
        // Keep the window bar: it's how the session window is moved and closed.
        .ornament(visibility: session.state == .connected ? .visible : .hidden,
                  attachmentAnchor: .scene(.bottom), contentAlignment: .top) {
            controlStrip
                .padding(.top, 20)
        }
        .background {
            WindowAspectMatcher(displaySize: session.activeConfig.map {
                CGSize(width: $0.display.pointWidth, height: $0.display.pointHeight)
            })
        }
        #elseif os(macOS)
        .background {
            WindowAspectMatcher(displaySize: session.activeConfig.map {
                CGSize(width: $0.display.pointWidth, height: $0.display.pointHeight)
            }, shape: windowShape)
        }
        .navigationTitle(device.name)
        .navigationSubtitle(windowSubtitle)
        .toolbar { macToolbar }
        .focusedSceneValue(\.sessionCommands, sessionCommands)
        .animation(.smooth(duration: 0.3), value: viewsThisMac && session.state == .connected)
        // The Mac client isn't suspended in the background (its windows stay on screen); it lets
        // go when the Mac sleeps and picks up again when it wakes.
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in
            if dictation.isListening { dictation.stop(then: .review) }
            stickyModifiers = []
            session.suspendForBackground()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            session.retryNow()
        }
        #else
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        #endif
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewportSize = $0 }
        .onChange(of: session.state) { _, state in
            if state == .connected {
                store.markConnected(device)
                if session.dictationEngines?.contains(.parakeet) == true {
                    // Lets Settings → Controls offer Parakeet once any Mac has advertised it.
                    UserDefaults.standard.set(true, forKey: DictationEnginePreference.macOffersParakeetKey)
                }
                #if os(macOS)
                checkForThisMac()
                #endif
                #if DEBUG
                if let fixture = ClientOptions.dictationFixture { dictation.showFixture(fixture) }
                if let phrase = ClientOptions.dictationSpeech, !dictation.isActive {
                    dictation.speakForTesting(phrase, route: dictationRoute)
                }
                #endif
            } else {
                hasVideo = false
                video.resetFirstFrame()
                dictation.connectionLost()
                macAudio.connectionLost()
            }
        }
        .onChange(of: session.activeConfig) { _, config in
            if let config {
                input.displayPointSize = CGSize(width: config.display.pointWidth, height: config.display.pointHeight)
            }
        }
        .onChange(of: touchMode) { _, newValue in input.mode = newValue }
        .onChange(of: trackpadSensitivity) { _, newValue in input.trackpadSensitivity = newValue }
        .onChange(of: naturalScroll) { _, newValue in input.naturalScroll = newValue }
        .onChange(of: toolbarCollapsed) { _, value in UserDefaults.standard.set(value, forKey: "vantage.toolbarCollapsed") }
        .onChange(of: toolbarDock) { _, value in UserDefaults.standard.set(value.rawValue, forKey: "vantage.toolbarDock") }
        .onChange(of: scenePhase) { _, phase in
            #if !os(macOS)
            if phase == .background {
                if dictation.isListening { dictation.stop(then: .review) }
                showKeyboard = false
                stickyModifiers = []
                session.suspendForBackground()
                return
            }
            #endif
            if phase == .active { session.retryNow() }
        }
        .overlay(alignment: .top) { hiddenKeyboardField }
        #if DEBUG
        .overlay(alignment: .bottomTrailing) { macAudioStatsProbe }
        #endif
        #if DEBUG && os(macOS)
        .overlay(alignment: .bottomLeading) { keyProbeElement }
        #endif
        .modifier(SessionHaptics(state: session.state, pairingError: session.pairingError, dock: toolbarDock,
                                 dictationPhase: dictationPhase, screenSharingTyping: screenSharingTyping,
                                 screenSharingError: screenSharingError))
        .animation(.smooth(duration: 0.3), value: screenSharingTyping)
        .animation(.smooth(duration: 0.3), value: macAudioNotice)
        // Hints and notices: in quickly with ease-out, out a little faster.
        .animation(.easeOut(duration: isDropTargeted ? 0.2 : 0.15), value: isDropTargeted && canSendFiles)
        .animation(.easeOut(duration: receivedNotice == nil ? 0.18 : 0.25), value: receivedNotice?.id)
        .onDrop(of: [.item], delegate: FileDropDelegate(isEnabled: canSendFiles, isTargeted: $isDropTargeted,
                                                        files: { session.files }))
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { session.files.send(urls, securityScoped: true) }
        }
        .sheet(isPresented: $showTransfers) {
            NavigationStack {
                TransfersView(files: session.files, macName: device.name, canSend: canSendFiles)
            }
            .appLockCurtain()
        }
        .alert("Files are still transferring. Disconnect anyway?", isPresented: $showDisconnectGuard) {
            Button("Disconnect", role: .destructive) { endSession() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This Mac's Vantage Host stops transfers when the screen closes. They'll pick up where they stopped next time you connect.")
        }
        // Files opened in Vantage from other apps join this session's queue.
        .onChange(of: SharedFileInbox.shared.pending.count, initial: true) { _, count in
            guard count > 0 else { return }
            for copy in SharedFileInbox.shared.take() { session.files.sendOutboxCopy(copy) }
        }
        #if DEBUG
        .onChange(of: session.files.isConnected) { _, connected in
            if connected, !queuedTestFile, let bytes = ClientOptions.sendTestFileBytes {
                queuedTestFile = true
                session.files.queueTestFile(bytes: bytes)
            }
        }
        #endif
        .onChange(of: macAudio.status) { _, status in
            if case .unavailable(let reason) = status { showMacAudioNotice(reason) }
        }
        .sheet(item: $passwordPrompt) { prompt in
            PasswordPromptSheet(prompt: prompt, password: $newPassword, username: $newUsername) { saved in
                passwordPrompt = nil
                defer { newPassword = ""; newUsername = "" }
                guard saved else { return }
                if prompt == .missing { DeviceSecrets.setPassword(newPassword, for: device) }
                if !newUsername.isEmpty { DeviceSecrets.setUsername(newUsername, for: device) }
                sendPassword()
            }
            .appLockCurtain()
        }
        .sheet(isPresented: $showStripEditor) {
            NavigationStack {
                MacControlStripEditor(deviceID: device.id)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showStripEditor = false }
                        }
                    }
            }
            .environment(store)
            .appLockCurtain()
        }
        .alert("Couldn't Type the Password", isPresented: Binding(get: { screenSharingError != nil },
                                                                set: { if !$0 { screenSharingError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(screenSharingError ?? "")
        }
        .task { await startSession() }
        .onDisappear { teardown() }
    }

    private var controlStrip: some View {
        ControlStrip(
            isCollapsed: $toolbarCollapsed,
            dock: $toolbarDock,
            stickyModifiers: $stickyModifiers,
            touchMode: $touchMode,
            onKey: { keyCode, modifiers in input.tapChord(keyCode: keyCode, modifiers: modifiers) },
            onShowKeyboard: { showKeyboard.toggle() },
            onSendClipboard: sendClipboard,
            onSendPassword: sendPassword,
            onHostCommand: { session.send(.hostCommand(HostCommandMessage(command: $0))) },
            onDisconnect: disconnect,
            isDictating: isDictationListening,
            onDictation: handleDictationPress,
            tapGuard: stripTapGuard,
            items: stripItems,
            onCustomize: { showStripEditor = true },
            macAudio: macAudioToggle,
            files: sendFileAction
        )
    }

    // MARK: Files

    /// The Mac takes files (the file channel comes up on demand).
    private var canSendFiles: Bool { session.state == .connected && session.hostOffersFiles }

    private var sendFileAction: SendFileAction {
        let active = session.files.transfers.filter { $0.state == .active }
        let progress: Double? = active.isEmpty ? nil
            : Double(active.reduce(0) { $0 + $1.bytesDone }) / Double(max(1, active.reduce(0) { $0 + $1.byteCount }))
        return SendFileAction(
            unavailableReason: session.state == .connected && !session.hostOffersFiles
                ? "This Mac's Vantage Host can't receive files. Update Vantage Host on the Mac." : nil,
            progress: progress,
            hasTransfers: session.files.hasTransfers,
            onSend: { showFileImporter = true },
            onShowTransfers: { showTransfers = true })
    }

    /// Files moving with the Mac, shown by themselves (tap for Transfers).
    private var transferCapsule: some View {
        TransferCapsule(files: session.files, macName: device.name) { showTransfers = true }
            .padding(.horizontal, 16)
    }

    /// The capsule sits on the edge away from the control strip, so they never meet.
    private var capsuleOnTop: Bool {
        #if os(visionOS)
        true // the strip is an ornament under the window
        #else
        !toolbarDock.isTop || controlsHidden
        #endif
    }

    private var noticeTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: .top)).combined(with: .offset(y: -6))
    }

    /// Shows "Received …" for a few seconds (long enough to reach its buttons with VoiceOver)
    /// and says it aloud, since the notice appears without focus moving to it. A run of several
    /// files is announced once, by the capsule, when it ends.
    private func showReceived(_ transfer: FileTransferController.Transfer) {
        receivedNotice = transfer
        if session.files.summary.count <= 1 {
            AccessibilityNotification.Announcement("Received \(transfer.name) from \(device.name)").post()
        }
        receivedNoticeTask?.cancel()
        receivedNoticeTask = Task {
            do { try await Task.sleep(for: .seconds(voiceOverEnabled ? 15 : 6)) } catch { return }
            receivedNotice = nil
        }
    }

    // MARK: Display sleep

    /// Why there's no live picture, if the Mac has said.
    private var screenNote: MacScreenNote.Kind? {
        if session.isDisplayAsleep { return .asleep }
        if session.isScreenUnavailable { return .unavailable }
        return nil
    }

    /// Wake/Retry, or a tap on the Mac's screen while there's no live picture.
    private func wakeDisplay() {
        guard !wakeRequested else { return }
        session.wakeDisplay()
        wakeRequested = true
        wakeTask?.cancel()
        wakeTask = Task {
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            wakeRequested = false
        }
    }

    // MARK: Mac audio

    /// This Mac's saved choice (from the store, so it follows edits and iCloud), unless a debug
    /// launch flag says otherwise.
    private var wantsMacAudio: Bool {
        macAudioOverride ?? store.devices.first { $0.id == device.id }?.playMacAudio ?? device.playMacAudio ?? false
    }

    private var macAudioFailed: Bool {
        if case .unavailable = macAudio.status { return true }
        return false
    }

    private var macAudioToggle: MacAudioToggle {
        MacAudioToggle(
            isOn: wantsMacAudio && !macAudioFailed,
            unavailableReason: session.state == .connected && !session.hostOffersAudio
                ? "This Mac's Vantage Host can't send sound. Update Vantage Host on the Mac." : nil,
            onToggle: toggleMacAudio)
    }

    /// Off → on, on → off, and a failed stream → try again (the choice itself stays on).
    private func toggleMacAudio() {
        let on = macAudioFailed ? true : !wantsMacAudio
        macAudioOverride = nil
        store.setPlayMacAudio(on, for: device.id)
        macAudioNotice = nil
        if on, macAudioFailed { macAudio.setWanted(false) } // start over
        macAudio.setWanted(on)
        session.setMacAudio(on)
    }

    #if DEBUG
    /// For UI tests launched with `-VantageMacAudio`: the player's numbers as an invisible
    /// accessibility element (`session.macAudioStats`), refreshed every second.
    @ViewBuilder private var macAudioStatsProbe: some View {
        if ClientOptions.macAudio != nil {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let stats = macAudio.stats
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityIdentifier("session.macAudioStats")
                    .accessibilityLabel("playing \(macAudio.status == .playing ? 1 : 0) pushed \(String(stats.framesPushed)) played \(String(stats.framesPlayed)) depth \(Int(stats.milliseconds(stats.depthFrames))) latency \(Int(stats.milliseconds(stats.smoothedDepthFrames))) target \(Int(stats.milliseconds(stats.targetFrames))) underruns \(stats.underruns) skips \(stats.skips) trims \(stats.startTrims)")
            }
            .allowsHitTesting(false)
        }
    }
    #endif

    private func showMacAudioNotice(_ message: String) {
        macAudioNotice = message
        macAudioNoticeTask?.cancel()
        macAudioNoticeTask = Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            macAudioNotice = nil
        }
    }

    /// This Mac's own layout if it has one, else the default, less what this device can't use
    /// (the Mac client has no on-screen keyboard). Read from the store rather than `device` so
    /// edits made mid-session (or synced in) show up straight away.
    private var stripItems: [StripItem] {
        (store.devices.first { $0.id == device.id }?.controlStrip ?? defaultStripLayout).visibleItems()
    }

    private var connectionOverlay: some View {
        VStack(spacing: 16) {
            switch session.state {
            case .connecting, .authenticating, .connected:
                ProgressView().controlSize(.large).tint(.white)
                Text(session.state == .connected ? "Starting screen capture…" : "Connecting to \(device.name)…")
                    .foregroundStyle(.white)
                    .contentTransition(.opacity)
            case .reconnecting, .suspended:
                ProgressView().controlSize(.large).tint(.white)
                Text("Reconnecting…").foregroundStyle(.white)
            case .pairingRequired:
                PairingPrompt(errorMessage: session.pairingError) { code in
                    session.connect(to: device, viewport: currentViewport(), pairingCode: code)
                }
            case .failed(let message):
                VStack(spacing: 12) {
                    Image(systemName: "wifi.exclamationmark").font(.largeTitle).foregroundStyle(.white)
                    Text(message).foregroundStyle(.white).multilineTextAlignment(.center)
                    Button("Retry") { Task { await startSession() } }.buttonStyle(.glassProminent)
                    Button("Close") { disconnect() }.buttonStyle(.glass)
                }
            default:
                EmptyView()
            }
            if case .failed = session.state {} else {
                Button("Close", action: disconnect).buttonStyle(.glass)
            }
        }
        .padding(32)
        .frame(maxWidth: 420)
        .background(.black.opacity(0.8), in: .rect(cornerRadius: 24))
        .preferredColorScheme(.dark)
    }

    // MARK: Dictation

    private var isDictationActive: Bool { dictation.isActive }

    private var dictationPhase: DictationController.Phase? { dictation.phase }

    private var isDictationListening: Bool { dictation.isListening }

    /// Mac (MacWhisper) when the host advertised it and Settings allows it; otherwise the iPad.
    private var dictationRoute: DictationRoute {
        DictationRoute.resolve(preference: dictationEngine, hostEngines: session.dictationEngines)
    }

    @ViewBuilder private var dictationPanel: some View {
        if dictation.isActive {
            DictationPanel(dictation: dictation,
                           isTypingBlocked: session.hostStatus?.isSecureInputActive == true,
                           onCopy: Self.copyToClipboard)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: toolbarDock.isTop ? .top : .bottom)))
        }
    }

    private static func copyToClipboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    private func handleDictationPress(_ press: DictationPress) {
        stickyModifiers = []
        switch press {
        case .began: dictation.pressBegan(route: dictationRoute)
        case .ended(let held): dictation.pressEnded(held: held)
        case .toggle: dictation.toggle(route: dictationRoute)
        case .cancelled: dictation.pressCancelled()
        }
    }

    nonisolated private static let toolbarSpace = "toolbarArea"
    #if os(macOS)
    private static let toolbarInsets = EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
    #else
    /// The top inset keeps drags below iPadOS window-management gestures.
    private static let toolbarInsets = EdgeInsets(top: 44, leading: 12, bottom: 12, trailing: 12)
    #endif

    private func toolbarArea(in size: CGSize) -> CGRect {
        CGRect(x: Self.toolbarInsets.leading, y: Self.toolbarInsets.top,
               width: size.width - Self.toolbarInsets.leading - Self.toolbarInsets.trailing,
               height: size.height - Self.toolbarInsets.top - Self.toolbarInsets.bottom)
    }

    /// Picks the corner from where the throw would carry the strip, then glides there in one
    /// spring that starts from wherever the finger left it.
    private func settleToolbar(translation: CGSize, predicted: CGSize, in size: CGSize) {
        stripTapGuard.dragEnded()
        let placement = ToolbarPlacement(area: toolbarArea(in: size), frame: toolbarFrame)
        let corner = placement.corner(translation: translation, predicted: predicted)
        withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.45, bounce: 0.12)) {
            toolbarDock = corner
            toolbarOffset = .zero
        }
    }

    private var toolbarAlignment: Alignment {
        switch toolbarDock {
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
        }
    }

    @ViewBuilder
    private var hiddenKeyboardField: some View {
        #if canImport(UIKit)
        if showKeyboard {
            RemoteKeyboardField(isPresented: $showKeyboard, onText: typeFromSoftwareKeyboard, onKey: { keyCode in
                input.tapChord(keyCode: keyCode, modifiers: stickyModifiers)
                stickyModifiers = []
            })
            .frame(width: 1, height: 1)
            .opacity(0.01)
        }
        #endif
    }

    /// Unicode text is the default. Keystrokes mode, or any held ⌘/⌥/⌃, sends real key presses so
    /// shortcuts like ⌘C work from the software keyboard.
    private func typeFromSoftwareKeyboard(_ text: String) {
        if keyboardMode == .keystrokes || !stickyModifiers.isEmpty {
            input.typeCharacters(text, modifiers: stickyModifiers)
            stickyModifiers = []
        } else {
            input.typeText(text)
        }
    }

    /// Runs the Pencil action that needs the session's own state rather than the pointer.
    private func performPencilAction(_ action: PencilAction) {
        let animation: Animation? = reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.4, bounce: 0.2)
        switch action {
        case .collapseControls:
            withAnimation(animation) {
                if controlsHidden { controlsHidden = false } else { toolbarCollapsed.toggle() }
            }
        case .hideControls:
            withAnimation(animation) { controlsHidden.toggle() }
        case .showKeyboard:
            showKeyboard.toggle()
        case .none, .rightClick, .middleClick:
            break // handled where the pointer is
        }
    }

    /// Types the saved password for this Mac and presses Return. macOS drops Vantage Host's
    /// keystrokes while a password field, auth dialog, or the lock screen holds Secure Event Input,
    /// so those go through the Mac's own Screen Sharing server instead (it needs the account name).
    private func sendPassword() {
        guard let password = DeviceSecrets.password(for: device) else {
            passwordPrompt = .missing
            return
        }
        let blocked = session.hostStatus.map { $0.isSecureInputActive || $0.isScreenLocked } ?? false
        guard blocked else {
            typePassword(password)
            return
        }
        guard DeviceSecrets.username(for: device) != nil else {
            passwordPrompt = .needsAccount
            return
        }
        typeThroughScreenSharing()
    }

    private func typeThroughScreenSharing() {
        guard screenSharingTyping != .typing else { return }
        stickyModifiers = []
        screenSharingTyping = .typing
        Task {
            do {
                try await ScreenSharingPassword.type(for: device)
                screenSharingTyping = .sent
                try? await Task.sleep(for: .seconds(1.6))
                if screenSharingTyping == .sent { screenSharingTyping = nil }
            } catch {
                screenSharingTyping = nil
                screenSharingError = ScreenSharingPassword.message(for: error)
            }
        }
    }

    private func typePassword(_ password: String) {
        stickyModifiers = []
        input.typeCharacters(password)
        input.tapChord(keyCode: 0x24, modifiers: []) // Return
    }

    private func startSession() async {
        session.useFileLink(FileTransferCenter.shared.link(for: device))
        session.onVideo = { message in video.consume(message) }
        session.files.onReceived = { transfer in showReceived(transfer) }
        #if DEBUG
        if let millis = ClientOptions.slowFilesMillis { session.files.chunkDelayForTesting = .milliseconds(millis) }
        #endif
        session.onClipboard = { payload in ClipboardSync.apply(payload) }
        video.onNeedsKeyframe = {
            Task { @MainActor in session.send(.requestKeyframe) }
        }
        video.onFirstFrame = {
            Task { @MainActor in hasVideo = true }
        }
        input.send = { message in session.send(message) }
        dictation.send = { message in session.send(message) }
        dictation.deliver = { text, pressReturn in
            input.typeText(text)
            if pressReturn { input.tapChord(keyCode: 0x24, modifiers: []) }
        }
        session.onDictationResult = { result in dictation.handle(result) }
        session.onAudio = { message in macAudio.handle(message) }
        dictation.onMicrophoneActive = { active in macAudio.setMicrophoneActive(active) }
        macAudio.setWanted(wantsMacAudio)
        session.setMacAudio(wantsMacAudio)
        input.mode = touchMode
        input.naturalScroll = naturalScroll
        input.trackpadSensitivity = trackpadSensitivity

        session.connect(to: device, viewport: currentViewport(), pairingCode: ClientOptions.pairingCode)
        startFeedbackLoop()
    }

    private func startFeedbackLoop() {
        feedbackTask?.cancel()
        feedbackTask = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard session.state == .connected else { continue }
                session.ping()
                let feedback = video.snapshotStats(windowSeconds: 0.25, rttMillis: session.lastRTTMillis)
                session.sendFeedback(feedback)
            }
        }
    }

    /// Disconnect from the strip, the menu, or the overlay. Files keep moving without the screen
    /// on a current Mac (the device list shows them). Only an older Mac, which would stop them,
    /// gets the one confirmation Disconnect ever asks for.
    private func disconnect() {
        if session.files.hasActiveTransfers, session.fileLink.macKeepsFiles == false {
            showDisconnectGuard = true
        } else {
            endSession()
        }
    }

    private func endSession() {
        teardown()
        dismiss()
    }

    private func teardown() {
        feedbackTask?.cancel()
        feedbackTask = nil
        macAudioNoticeTask?.cancel()
        receivedNoticeTask?.cancel()
        wakeTask?.cancel()
        macAudio.setWanted(false)
        // The Mac's transfers outlive this screen; stop reporting them here.
        session.files.onReceived = nil
        session.disconnect()
    }

    private func currentViewport() -> Viewport {
        Viewport(widthPoints: Double(viewportSize.width), heightPoints: Double(viewportSize.height), scale: Double(displayScale))
    }

    /// This Mac's saved Natural Scrolling (from the store, so an edit mid-session applies).
    private var naturalScroll: Bool {
        store.devices.first { $0.id == device.id }?.naturalScroll ?? device.naturalScroll
    }

    /// Send Clipboard: whatever is on the clipboard here, now.
    private func sendClipboard() {
        let payload = ClipboardSync.currentPayload()
        if !payload.isEmpty { session.send(.clipboard(payload)) }
    }
}

#if os(macOS)
// MARK: - Mac client

extension RemoteSessionScreen {
    /// Pointer and keys go to the Mac.
    private var sendsInput: Bool {
        session.state == .connected && !isViewOnly && !AppLock.shared.isLocked
    }

    @ViewBuilder var macSessionSurface: some View {
        #if DEBUG
        RemoteSessionNSRepresentable(input: input, video: video, sendsInput: sendsInput,
                                     capturesShortcuts: capturesShortcuts, swapsCommandAndControl: swapsCommandAndControl,
                                     stickyModifiers: stickyModifiers, onPaste: pasteThroughClipboard,
                                     keyProbe: MacSessionOptions.keyProbe ? keyProbe : nil)
        #else
        RemoteSessionNSRepresentable(input: input, video: video, sendsInput: sendsInput,
                                     capturesShortcuts: capturesShortcuts, swapsCommandAndControl: swapsCommandAndControl,
                                     stickyModifiers: stickyModifiers, onPaste: pasteThroughClipboard)
        #endif
    }

    /// ⌘V on the Mac: something copied here since the last sync goes over first, so the paste
    /// on the Mac has it (the host writes it before it posts the key).
    private func pasteThroughClipboard() {
        if let payload = ClipboardSync.changedPayload() { session.send(.clipboard(payload)) }
    }

    /// The first time the session connects: is its Mac this one? Then it starts in View Only,
    /// since every move and key would come straight back through the host
    /// (`-VantageAllowSelfControl 1` keeps input on for tests).
    func checkForThisMac() {
        viewsThisMac = ThisMac.isHost(address: device.host, hostName: session.hostName)
        guard !checkedThisMac else { return }
        checkedThisMac = true
        if viewsThisMac && !MacSessionOptions.allowSelfControl { isViewOnly = true }
    }

    var windowSubtitle: String {
        switch session.state {
        case .connected:
            var parts: [String] = []
            if let display = session.activeConfig?.display {
                parts.append("\(Int(display.pointWidth)) × \(Int(display.pointHeight))")
            }
            if isViewOnly { parts.append("View Only") }
            return parts.joined(separator: " · ")
        case .connecting, .authenticating: return "Connecting…"
        case .reconnecting, .suspended: return "Reconnecting…"
        case .pairingRequired: return "Pairing"
        case .failed: return "Not connected"
        default: return ""
        }
    }

    @ToolbarContentBuilder var macToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $isViewOnly) {
                Label("View Only", systemImage: "eye")
            }
            .help("Watch the Mac without sending the pointer or keys")
            .accessibilityIdentifier("session.mac.viewOnly")
            Toggle(isOn: $capturesShortcuts) {
                Label("Send Keyboard Shortcuts", systemImage: "command")
            }
            .help(capturesShortcuts ? "⌘Q, ⌘W and other shortcuts go to the Mac. ⌃⌥⌘ shortcuts stay with Vantage."
                                    : "⌘Q, ⌘W, ⌘H, ⌘M and ⌘, act on Vantage")
            .accessibilityIdentifier("session.mac.captureShortcuts")
            Menu {
                ForEach(MacShortcut.sessionMenu) { shortcut in
                    Button { input.tapChord(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) } label: {
                        Label(shortcut.label, systemImage: shortcut.symbol)
                    }
                }
                Divider()
                Button { sendHostCommand(.sleepDisplay) } label: { Label("Sleep Display", systemImage: "moon") }
                Button { sendHostCommand(.lockScreen) } label: { Label("Lock Mac", systemImage: "lock") }
            } label: {
                Label("Mac", systemImage: "macbook")
            }
            .help("Mac shortcuts")
            .disabled(session.state != .connected)
            Button { showFileImporter = true } label: {
                Label("Send File", systemImage: StripItem.sendFile.symbol)
            }
            .help("Send files to \(device.name)'s Downloads folder")
            .disabled(!canSendFiles)
            Button(action: disconnect) {
                Label("Disconnect", systemImage: "xmark.circle")
            }
            .help("Disconnect from \(device.name)")
            .accessibilityIdentifier("session.toolbar.disconnect")
        }
    }

    private func sendHostCommand(_ command: HostCommand) {
        session.send(.hostCommand(HostCommandMessage(command: command)))
    }

    /// What the menu bar's Session, View and Mac menus act on while this window is focused.
    var sessionCommands: SessionCommands {
        SessionCommands(
            macName: device.name,
            isConnected: session.state == .connected,
            capturesShortcuts: capturesShortcuts,
            toggleShortcutCapture: { capturesShortcuts.toggle() },
            isViewOnly: isViewOnly,
            toggleViewOnly: { isViewOnly.toggle() },
            macAudioOn: wantsMacAudio && !macAudioFailed,
            macAudioAvailable: session.state == .connected && session.hostOffersAudio,
            toggleMacAudio: toggleMacAudio,
            canSendFiles: canSendFiles,
            sendFile: { showFileImporter = true },
            showTransfers: { showTransfers = true },
            sendClipboard: sendClipboard,
            typePassword: sendPassword,
            sendShortcut: { input.tapChord(keyCode: $0.keyCode, modifiers: $0.modifiers) },
            hostCommand: sendHostCommand,
            wake: wakeDisplay,
            isDictating: isDictationListening,
            toggleDictation: { handleDictationPress(.toggle) },
            controlsHidden: controlsHidden,
            toggleControls: { withAnimation(.smooth(duration: 0.3)) { controlsHidden.toggle() } },
            actualSize: windowShape.actualSize,
            toggleFullScreen: windowShape.toggleFullScreen,
            customizeControls: { showStripEditor = true },
            disconnect: disconnect)
    }

    #if DEBUG
    /// `-VantageKeyProbe 1`: the keys sent lately, as `session.keyProbe`'s label.
    @ViewBuilder var keyProbeElement: some View {
        if MacSessionOptions.keyProbe {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityIdentifier("session.keyProbe")
                // A label, not a value: macOS doesn't report a plain element's value to UI tests.
                .accessibilityLabel(keyProbe.value)
                .allowsHitTesting(false)
        }
    }
    #endif
}

/// The session's Mac is the one Vantage runs on: say so, since the picture shows itself and the
/// pointer comes straight back.
private struct ThisMacBanner: View {
    let isViewOnly: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
            VStack(alignment: .leading, spacing: 2) {
                Text("You're viewing this Mac from itself").font(.callout.weight(.semibold))
                Text(isViewOnly ? "View Only is on, so the pointer and keys stay here."
                                : "The pointer and keys go to this same Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .platformGlass(in: .capsule)
        .frame(maxWidth: 520)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("session.thisMacBanner")
    }
}
#endif

#if canImport(UIKit)
import UIKit
#endif

/// Explains why input may be ignored: the Mac is locked or a secure field has focus.
struct HostStatusBanner: View {
    let status: HostStatus

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: status.isScreenLocked ? "lock.fill" : "key.fill")
            Text(status.message ?? (status.isScreenLocked ? "The Mac is locked" : "Typing is blocked by a secure field"))
                .font(.callout)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .platformGlass(in: .capsule)
        .frame(maxWidth: 520)
    }
}

/// The session's haptics (see `Haptic`): the strip landing in a corner, dictation's microphone
/// opening and closing, a dropped or restored connection, and outcomes you'd otherwise have to
/// look for. Pointer and touch gestures buzz from `RemoteInteractionView`.
private struct SessionHaptics: ViewModifier {
    let state: ClientSession.State
    let pairingError: String?
    let dock: ToolbarDock
    let dictationPhase: DictationController.Phase?
    let screenSharingTyping: ScreenSharingTypingState?
    let screenSharingError: String?
    @State private var connection = ConnectionHaptics()

    func body(content: Content) -> some View {
        content
            .haptic(.snap, trigger: dock)
            .haptic(trigger: dictationPhase, Self.dictation)
            .haptic(trigger: pairingError, Self.failure)
            .haptic(trigger: screenSharingTyping, Self.typed)
            .haptic(trigger: screenSharingError, Self.failure)
            .onChange(of: state) { old, new in
                if let haptic = connection.haptic(from: old, to: new) { Haptics.play(haptic) }
            }
            #if DEBUG
            .overlay(alignment: .bottomLeading) {
                if ClientOptions.hapticProbe {
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        Color.clear
                            .frame(width: 1, height: 1)
                            .accessibilityElement()
                            .accessibilityIdentifier("session.hapticProbe")
                            .accessibilityValue(Haptics.played.map { "\($0)" }.joined(separator: " "))
                    }
                    .allowsHitTesting(false)
                }
            }
            #endif
    }

    private static func dictation(_ old: DictationController.Phase?, _ new: DictationController.Phase?) -> Haptic? {
        guard let old, let new else { return nil }
        return DictationController.Phase.haptic(from: old, to: new)
    }

    /// An error message appeared: a rejected pairing code, a password Screen Sharing couldn't type.
    private static func failure(_ old: String?, _ new: String?) -> Haptic? { new == nil ? nil : .error }

    private static func typed(_ old: ScreenSharingTypingState?, _ new: ScreenSharingTypingState?) -> Haptic? {
        new == .sent ? .success : nil
    }
}

/// Why the Mac's sound stopped or didn't start; clears itself after a few seconds.
private struct MacAudioNotice: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.slash")
            Text(message)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .platformGlass(in: .capsule)
        .frame(maxWidth: 520)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("session.macAudioNotice")
    }
}

/// Progress of a password typed through the Mac's Screen Sharing server.
enum ScreenSharingTypingState: Equatable {
    case typing, sent
}

private struct ScreenSharingTypingBadge: View {
    let state: ScreenSharingTypingState

    var body: some View {
        HStack(spacing: 8) {
            if state == .typing {
                ProgressView().controlSize(.small)
                Text("Typing password with Screen Sharing…")
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Password sent")
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .platformGlass(in: .capsule)
        .accessibilityElement(children: .combine)
    }
}

/// Why the key button couldn't just type the password.
enum PasswordPrompt: String, Identifiable {
    /// No password saved for this Mac yet — offer to save one without leaving the session.
    case missing
    /// macOS is blocking ordinary keystrokes; Screen Sharing can type it but needs the account name.
    case needsAccount
    var id: String { rawValue }
}

/// Saves a Mac's password (and the account name Screen Sharing needs) mid-session.
private struct PasswordPromptSheet: View {
    let prompt: PasswordPrompt
    @Binding var password: String
    @Binding var username: String
    /// Called with true to save and type, false to just close.
    let onFinish: (Bool) -> Void

    private var canSave: Bool {
        switch prompt {
        case .missing: !password.isEmpty
        case .needsAccount: !username.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if prompt == .needsAccount {
                    Section {
                        Label("macOS is blocking ordinary typing", systemImage: "lock.shield")
                            .font(.headline)
                    } footer: {
                        Text("A password field, an authentication dialog, or the lock screen has focus, so macOS ignores keystrokes from apps. Vantage can type the password through the Mac's own Screen Sharing instead. It signs in with your Mac account, so it needs the account name that goes with this password.")
                    }
                }
                Section {
                    TextField("Account name", text: $username)
                        .textContentType(.username)
                        #if !os(macOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                    if prompt == .missing {
                        SecureField("Mac Password", text: $password)
                            .textContentType(.password)
                            #if !os(macOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                    }
                } footer: {
                    Text(prompt == .missing
                         ? "Vantage keeps these in the Keychain and types the password when you tap the key button. The account name is optional; with it, the key button also works in password fields and on the lock screen."
                         : "Your short account name or full name, as shown in System Settings → Users & Groups. Screen Sharing must be on for this account (System Settings → General → Sharing).")
                }
            }
            .navigationTitle(prompt == .missing ? "Save Password" : "Mac Account")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onFinish(false) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save & Type") { onFinish(true) }
                        .disabled(!canSave)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
