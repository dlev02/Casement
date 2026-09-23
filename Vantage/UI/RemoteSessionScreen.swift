import SwiftUI
import VantageCore

/// Full-screen remote session: shows the video, hosts input capture, overlays the control strip
/// and connection status, and runs the periodic feedback/ping loop.
struct RemoteSessionScreen: View {
    let device: SavedDevice
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(DeviceStore.self) private var store

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
    #if canImport(UIKit)
    @State private var dictation = DictationController()
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
            #endif

            if !isLive {
                connectionOverlay
                    .transition(.opacity)
            }

            VStack {
                if let status = session.hostStatus, status.isScreenLocked || status.isSecureInputActive {
                    HostStatusBanner(status: status)
                        .padding(.top, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let screenSharingTyping {
                    ScreenSharingTypingBadge(state: screenSharingTyping)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
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
                #if DEBUG && canImport(UIKit)
                if let fixture = ClientOptions.dictationFixture { dictation.showFixture(fixture) }
                if let phrase = ClientOptions.dictationSpeech, !dictation.isActive {
                    dictation.speakForTesting(phrase, route: dictationRoute)
                }
                #endif
            } else {
                hasVideo = false
                video.resetFirstFrame()
                #if canImport(UIKit)
                dictation.connectionLost()
                #endif
            }
        }
        .onChange(of: session.activeConfig) { _, config in
            if let config {
                input.displayPointSize = CGSize(width: config.display.pointWidth, height: config.display.pointHeight)
            }
        }
        .onChange(of: touchMode) { _, newValue in input.mode = newValue }
        .onChange(of: toolbarCollapsed) { _, value in UserDefaults.standard.set(value, forKey: "vantage.toolbarCollapsed") }
        .onChange(of: toolbarDock) { _, value in UserDefaults.standard.set(value.rawValue, forKey: "vantage.toolbarDock") }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                #if canImport(UIKit)
                if dictation.isListening { dictation.stop(then: .review) }
                #endif
                showKeyboard = false
                stickyModifiers = []
                session.suspendForBackground()
            } else if phase == .active { session.retryNow() }
        }
        .overlay(alignment: .top) { hiddenKeyboardField }
        .animation(.smooth(duration: 0.3), value: screenSharingTyping)
        .sheet(item: $passwordPrompt) { prompt in
            PasswordPromptSheet(prompt: prompt, password: $newPassword, username: $newUsername) { saved in
                passwordPrompt = nil
                defer { newPassword = ""; newUsername = "" }
                guard saved else { return }
                if prompt == .missing { DeviceSecrets.setPassword(newPassword, for: device) }
                if !newUsername.isEmpty { DeviceSecrets.setUsername(newUsername, for: device) }
                sendPassword()
            }
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
            onSendClipboard: {
                #if canImport(UIKit)
                let payload = ClipboardSync.currentPayload()
                if !payload.isEmpty { session.send(.clipboard(payload)) }
                #endif
            },
            onSendPassword: sendPassword,
            onHostCommand: { session.send(.hostCommand(HostCommandMessage(command: $0))) },
            onDisconnect: disconnect,
            isDictating: isDictationListening,
            onDictation: handleDictationPress,
            tapGuard: stripTapGuard
        )
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

    private var isDictationActive: Bool {
        #if canImport(UIKit)
        dictation.isActive
        #else
        false
        #endif
    }

    private var isDictationListening: Bool {
        #if canImport(UIKit)
        dictation.isListening
        #else
        false
        #endif
    }

    /// Mac (MacWhisper) when the host advertised it and Settings allows it; otherwise the iPad.
    private var dictationRoute: DictationRoute {
        DictationRoute.resolve(preference: dictationEngine, hostEngines: session.dictationEngines)
    }

    @ViewBuilder private var dictationPanel: some View {
        #if canImport(UIKit)
        if dictation.isActive {
            DictationPanel(dictation: dictation,
                           isTypingBlocked: session.hostStatus?.isSecureInputActive == true,
                           onCopy: { UIPasteboard.general.string = $0 })
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: toolbarDock.isTop ? .top : .bottom)))
        }
        #endif
    }

    private func handleDictationPress(_ press: DictationPress) {
        #if canImport(UIKit)
        stickyModifiers = []
        switch press {
        case .began: dictation.pressBegan(route: dictationRoute)
        case .ended(let held): dictation.pressEnded(held: held)
        case .toggle: dictation.toggle(route: dictationRoute)
        case .cancelled: dictation.pressCancelled()
        }
        #endif
    }

    private static let toolbarSpace = "toolbarArea"
    /// The top inset keeps drags below iPadOS window-management gestures.
    private static let toolbarInsets = EdgeInsets(top: 44, leading: 12, bottom: 12, trailing: 12)

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
        if showKeyboard {
            RemoteKeyboardField(isPresented: $showKeyboard, onText: typeFromSoftwareKeyboard, onKey: { keyCode in
                input.tapChord(keyCode: keyCode, modifiers: stickyModifiers)
                stickyModifiers = []
            })
            .frame(width: 1, height: 1)
            .opacity(0.01)
        }
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

        session.onVideo = { message in video.consume(message) }
        session.onClipboard = { payload in
            #if canImport(UIKit)
            ClipboardSync.apply(payload)
            #endif
        }
        video.onNeedsKeyframe = {
            Task { @MainActor in session.send(.requestKeyframe) }
        }
        video.onFirstFrame = {
            Task { @MainActor in hasVideo = true }
        }
        input.send = { message in session.send(message) }
        #if canImport(UIKit)
        dictation.send = { message in session.send(message) }
        dictation.deliver = { text, pressReturn in
            input.typeText(text)
            if pressReturn { input.tapChord(keyCode: 0x24, modifiers: []) }
        }
        session.onDictationResult = { result in dictation.handle(result) }
        #endif
        input.mode = touchMode
        input.naturalScroll = device.naturalScroll
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

    private func disconnect() {
        teardown()
        dismiss()
    }

    private func teardown() {
        feedbackTask?.cancel()
        feedbackTask = nil
        session.disconnect()
    }

    private func currentViewport() -> Viewport {
        Viewport(widthPoints: Double(viewportSize.width), heightPoints: Double(viewportSize.height), scale: Double(displayScale))
    }
}

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
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if prompt == .missing {
                        SecureField("Mac Password", text: $password)
                            .textContentType(.password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } footer: {
                    Text(prompt == .missing
                         ? "Vantage keeps these in the Keychain and types the password when you tap the key button. The account name is optional; with it, the key button also works in password fields and on the lock screen."
                         : "Your short account name or full name, as shown in System Settings → Users & Groups. Screen Sharing must be on for this account (System Settings → General → Sharing).")
                }
            }
            .navigationTitle(prompt == .missing ? "Save Password" : "Mac Account")
            .navigationBarTitleDisplayMode(.inline)
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
