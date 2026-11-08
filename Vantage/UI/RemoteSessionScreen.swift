import SwiftUI
import UniformTypeIdentifiers
import VantageCore
#if os(macOS)
import AppKit
#endif

/// Full-screen remote session: makes the screen session's model once, then lays it out
/// (`RemoteSessionLayout`). The model is made when the screen appears rather than in `init`, so
/// a parent re-rendering never makes a second connection or Keychain identity.
struct RemoteSessionScreen: View {
    let device: SavedDevice
    @Environment(DeviceStore.self) private var store
    @State private var model: ScreenSessionModel?

    var body: some View {
        if let model {
            RemoteSessionLayout(model: model)
        } else {
            placeholder.onAppear {
                // Takes this computer's shared `FileLink`, so files keep moving after the screen closes.
                model = ScreenSessionModel(device: device, store: store, fileLink: FileTransferCenter.shared.link(for: device))
            }
        }
    }

    @ViewBuilder private var placeholder: some View {
        #if os(visionOS)
        Color.clear
        #else
        Color.black.ignoresSafeArea()
        #endif
    }
}

/// The screen session laid out: the picture, input capture, the control strip and dictation
/// panel, notices and the connection overlay, all reading one `ScreenSessionModel`.
struct RemoteSessionLayout: View {
    @Bindable var model: ScreenSessionModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(DeviceStore.self) private var store

    @State private var showKeyboard = false
    /// The whole screen, under the safe area.
    @State private var screenSize = CGSize(width: 1210, height: 834)
    @State private var screenInsets = EdgeInsets()
    /// An iPhone Duo set up like a laptop: the picture above the fold, keyboard and trackpad below.
    @State private var foldedLikeALaptop: TabletopLayout?
    @AppStorage(TabletopDeckMode.enabledKey) private var tabletopEnabled = true
    private var tabletop: TabletopLayout? { tabletopEnabled ? foldedLikeALaptop : nil }
    @Environment(\.displayScale) private var displayScale
    /// The strip's collapsed state and corner: seeded from the defaults and written back on
    /// change, not `@AppStorage`. UI tests and screenshot launches pin these keys in the
    /// argument domain (`-vantage.toolbarDock bottomLeft`), which outranks every write, so an
    /// `@AppStorage` strip could never move or collapse during such a launch.
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
    @AppStorage("vantage.pencilSqueeze") private var pencilSqueeze = PencilAction.collapseControls
    @AppStorage("vantage.pencilDoubleTap") private var pencilDoubleTap = PencilAction.rightClick
    #if os(macOS)
    @AppStorage(MacKeyboardSettings.swapCommandControlKey) private var swapsCommandAndControl = false
    @State private var windowShape = SessionWindowShape()
    #if DEBUG
    @State private var keyProbe = KeyProbe()
    #endif
    #endif

    var session: ClientSession { model.session }
    var device: SavedDevice { model.device }
    #if os(macOS)
    // For the Mac layout in `RemoteSessionScreen+macOS.swift`; the stored properties stay private so `@State` defers.
    var macSwapsCommandAndControl: Bool { swapsCommandAndControl }
    #if DEBUG
    var macKeyProbe: KeyProbe { keyProbe }
    #endif
    #endif
    /// "Mac" or "PC", for everything the session says about the computer.
    var host: HostNoun { model.host }
    /// What the host fits its picture to: the screen, or the half above the fold in tabletop (so a
    /// virtual display takes that shape and fills it).
    private var viewportSize: CGSize { tabletop?.picture.size ?? screenSize }
    #if os(visionOS)
    /// The Mac display's width over its height (16:10 until the host says which display).
    private var visionPictureAspect: CGFloat {
        session.activeConfig.map { CGFloat($0.display.pointWidth) / CGFloat(max($0.display.pointHeight, 1)) } ?? 16 / 10
    }
    #endif
    /// What VoiceOver calls the picture of the host's screen.
    var screenLabel: String { "Screen of \(device.name)" }

    var body: some View {
        ZStack {
            #if os(iOS)
            Color.black.ignoresSafeArea()
                .onGeometryChange(for: TabletopLayout?.self) { proxy in
                    if #available(iOS 27.1, *) { TabletopLayout(proxy) } else { nil }
                } action: { layout in
                    withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .smooth(duration: 0.4)) { foldedLikeALaptop = layout }
                }
            #elseif !os(visionOS) // the window's glass frames the picture there
            Color.black.ignoresSafeArea()
            #endif

            #if canImport(UIKit)
            if model.isConnected {
                RemoteSessionRepresentable(input: model.input, video: model.video, stickyModifiers: model.stickyModifiers,
                                           screenLabel: screenLabel, pencilSqueeze: pencilSqueeze, pencilDoubleTap: pencilDoubleTap,
                                           onPencilAction: performPencilAction)
                    #if os(visionOS)
                    // Exactly the Mac's shape, so a window that's a little off never shows black
                    // bars (see `VisionSessionPicture`).
                    .background(.black)
                    .aspectRatio(visionPictureAspect, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: VisionSessionPicture.cornerRadius, style: .continuous))
                    #else
                    // The half above the fold in tabletop; nil sizes fill the screen as always.
                    .frame(width: tabletop?.picture.width, height: tabletop?.picture.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea()
                    #endif
            }
            #elseif os(macOS)
            if model.isConnected {
                macSessionSurface
            }
            #endif

            if let screenNote = model.screenNote {
                MacScreenNote(kind: screenNote, host: host, isWaking: model.isWakeRequested, hasPicture: model.hasPicture,
                              onWake: model.wakeDisplay)
                    .padding(.bottom, belowPicture)
                    .transition(.opacity)
            } else if !model.isLive {
                connectionOverlay
                    .transition(.opacity)
            }

            VStack {
                #if os(macOS)
                if model.viewsThisMac && model.isConnected {
                    ThisMacBanner(isViewOnly: model.isViewOnly)
                        .padding(.top, 12)
                        .transition(bannerTransition)
                }
                #endif
                // A sleeping Mac also reports its lock screen; the asleep note says enough.
                if let status = session.hostStatus, !session.isDisplayAsleep, status.isScreenLocked || status.isSecureInputActive {
                    HostStatusBanner(status: status, host: host)
                        .padding(.top, 12)
                        .transition(bannerTransition)
                }
                if let screenSharingTyping = model.screenSharingTyping {
                    ScreenSharingTypingBadge(state: screenSharingTyping)
                        .padding(.top, 8)
                        .transition(bannerTransition)
                }
                if let macAudioNotice = model.macAudioNotice.value {
                    MacAudioNotice(message: macAudioNotice)
                        .padding(.top, 8)
                        .transition(bannerTransition)
                }
                if model.isDropTargeted && model.canSendFiles {
                    DropToSendHint(macName: device.name)
                        .padding(.top, 12)
                        .transition(noticeTransition)
                }
                if let receivedNotice = model.receivedNotice.value {
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
            .padding(.bottom, belowPicture)
            #if os(visionOS)
            // The control strip is an ornament under the window; the dictation panel floats over
            // the bottom of the Mac, just above it.
            if model.isConnected {
                dictationPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(24)
                    .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.4, bounce: 0.15), value: model.dictation.isActive)
            }
            #else
            #if os(iOS)
            if model.isConnected, let tabletop {
                tabletopDeck(tabletop)
            }
            #endif
            if model.isConnected && tabletop == nil && (!model.areControlsHidden || model.dictation.isActive) {
                floatingControls
            }
            #endif
        }
        .animation(.smooth(duration: 0.35), value: model.isLive)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .smooth(duration: 0.35), value: model.screenNote)
        #if os(visionOS)
        // Keep the window bar: it's how the session window is moved and closed.
        .ornament(visibility: model.isConnected ? .visible : .hidden,
                  attachmentAnchor: .scene(.bottom), contentAlignment: .top) {
            controlStrip
                .padding(.top, 20)
        }
        .background {
            WindowAspectMatcher(displaySize: session.activeConfig.map {
                CGSize(width: $0.display.pointWidth, height: $0.display.pointHeight)
            })
        }
        // The window is plain; glass backs it only while there's no picture to show.
        .glassBackgroundEffect(in: .rect(cornerRadius: VisionSessionPicture.cornerRadius, style: .continuous),
                               displayMode: model.isLive ? .never : .always)
        #elseif os(macOS)
        .background {
            WindowAspectMatcher(displaySize: session.activeConfig.map {
                CGSize(width: $0.display.pointWidth, height: $0.display.pointHeight)
            }, shape: windowShape)
        }
        .navigationTitle(device.name)
        .navigationSubtitle(windowSubtitle)
        .toolbar { macToolbar }
        .focusedSceneValue(\.screenSession, model)
        .focusedSceneValue(\.sessionWindowShape, windowShape)
        .animation(.smooth(duration: 0.3), value: model.viewsThisMac && model.isConnected)
        // The Mac client isn't suspended in the background (its windows stay on screen); it lets
        // go when the Mac sleeps and picks up again when it wakes.
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in
            model.suspend()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            model.resume()
        }
        #else
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        #endif
        // The picture fills the whole screen, under the safe area, so the viewport the host
        // fits to is that size too (an iPhone Duo's side bar and camera make the insets uneven).
        .onGeometryChange(for: EdgeInsets.self) { proxy in
            #if os(iOS)
            proxy.safeAreaInsets
            #else
            EdgeInsets()
            #endif
        } action: { screenInsets = $0 }
        .onGeometryChange(for: CGSize.self) { proxy in
            #if os(iOS)
            let insets = proxy.safeAreaInsets
            return CGSize(width: proxy.size.width + insets.leading + insets.trailing,
                          height: proxy.size.height + insets.top + insets.bottom)
            #else
            return proxy.size
            #endif
        } action: { screenSize = $0 }
        // A fold, rotation, or resize: the model asks the host once it has settled.
        .onChange(of: viewportSize) { _, _ in model.viewportChanged(currentViewport()) }
        .onChange(of: toolbarCollapsed) { _, value in UserDefaults.standard.set(value, forKey: "vantage.toolbarCollapsed") }
        .onChange(of: toolbarDock) { _, value in UserDefaults.standard.set(value.rawValue, forKey: "vantage.toolbarDock") }
        .onChange(of: voiceOverEnabled, initial: true) { _, on in model.usesVoiceOver = on }
        .onChange(of: model.isEnded) { _, ended in if ended { dismiss() } }
        .onChange(of: scenePhase) { _, phase in
            #if !os(macOS)
            if phase == .background {
                showKeyboard = false
                model.suspend()
                return
            }
            #endif
            if phase == .active { model.resume() }
        }
        .overlay(alignment: .top) { hiddenKeyboardField }
        #if DEBUG
        .overlay(alignment: .bottomTrailing) { macAudioStatsProbe }
        #endif
        #if DEBUG && os(macOS)
        .overlay(alignment: .bottomLeading) { keyProbeElement }
        #endif
        .modifier(SessionHaptics(state: session.state, pairingError: session.pairingError, dock: toolbarDock,
                                 dictationPhase: model.dictation.phase, screenSharingTyping: model.screenSharingTyping,
                                 screenSharingError: model.screenSharingError))
        .animation(.smooth(duration: 0.3), value: model.screenSharingTyping)
        .animation(.smooth(duration: 0.3), value: model.macAudioNotice.value)
        // Hints and notices: in quickly with ease-out, out a little faster.
        .animation(.easeOut(duration: model.isDropTargeted ? 0.2 : 0.15), value: model.isDropTargeted && model.canSendFiles)
        .animation(.easeOut(duration: model.receivedNotice.value == nil ? 0.18 : 0.25), value: model.receivedNotice.value?.id)
        .onDrop(of: [.item], delegate: FileDropDelegate(isEnabled: model.canSendFiles, isTargeted: $model.isDropTargeted,
                                                        files: { session.files }))
        .fileImporter(isPresented: $model.isPickingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { session.files.send(urls, securityScoped: true) }
        }
        .sheet(isPresented: $model.isShowingTransfers) {
            NavigationStack {
                TransfersView(files: session.files, macName: device.name, host: host, canSend: model.canSendFiles)
            }
            #if os(macOS)
            .frame(minWidth: 460, idealWidth: 520, minHeight: 360, idealHeight: 480)
            #endif
            .appLockCurtain()
        }
        .alert("Files are still transferring. Disconnect anyway?", isPresented: $model.isConfirmingDisconnect) {
            Button("Disconnect", role: .destructive) { model.end() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(device.name)'s Casement Host stops transfers when the screen closes. They'll pick up where they stopped next time you connect.")
        }
        #if os(iOS)
        // On iPhone and iPad the session asks about files opened in Casement, naming its
        // computer (on visionOS and the Mac the device list asks).
        .modifier(SharedFileConfirmation(destination: device.name, isActive: true, onSend: {}))
        #endif
        .sheet(item: $model.passwordPrompt) { prompt in
            PasswordPromptSheet(prompt: prompt, onCancel: { model.passwordPrompt = nil }) { password, accountName in
                model.savePasswordAndType(password: password, accountName: accountName)
            }
            .appLockCurtain()
        }
        .sheet(isPresented: $model.isEditingControls) {
            NavigationStack {
                MacControlStripEditor(deviceID: device.id)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { model.isEditingControls = false }
                        }
                    }
            }
            #if os(macOS)
            .frame(minWidth: 460, idealWidth: 520, minHeight: 520, idealHeight: 640)
            #endif
            .environment(store)
            .appLockCurtain()
        }
        .alert("Couldn't Type the Password", isPresented: Binding(get: { model.screenSharingError != nil },
                                                                set: { if !$0 { model.screenSharingError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.screenSharingError ?? "")
        }
        .task { model.start(viewport: currentViewport()) }
        .onDisappear { model.stop() }
    }

    // MARK: Control strip

    private var controlStrip: some View {
        ControlStrip(
            isCollapsed: $toolbarCollapsed,
            dock: $toolbarDock,
            stickyModifiers: $model.stickyModifiers,
            touchMode: $model.touchMode,
            onKey: { keyCode, modifiers in model.tapChord(keyCode: keyCode, modifiers: modifiers) },
            onShowKeyboard: { showKeyboard.toggle() },
            onSendClipboard: { model.sendClipboard() },
            onSendPassword: { model.typePassword() },
            onHostCommand: { model.sendHostCommand($0) },
            onDisconnect: { model.disconnect() },
            isDictating: model.dictation.isListening,
            onDictation: { model.dictationPressed($0) },
            tapGuard: stripTapGuard,
            items: model.stripItems,
            onCustomize: { model.isEditingControls = true },
            macAudio: model.macAudioToggle,
            curtain: model.curtainToggle,
            files: model.sendFileAction,
            host: model.hostPlatform
        )
    }

    #if !os(visionOS)
    /// The strip in its corner, draggable between corners, with the dictation panel stacked on
    /// its inner side so it stays in the corner the user chose and keeps the middle of the
    /// computer's screen visible.
    private var floatingControls: some View {
        GeometryReader { geometry in
            VStack(alignment: toolbarAlignment.horizontal, spacing: 12) {
                if !toolbarDock.isTop { dictationPanel }
                if !model.areControlsHidden {
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
            .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.4, bounce: 0.15), value: model.dictation.isActive)
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

    // MARK: Files

    /// Files moving with the computer, shown by themselves (tap for Transfers).
    private var transferCapsule: some View {
        TransferCapsule(files: session.files, macName: device.name) { model.isShowingTransfers = true }
            .padding(.horizontal, 16)
    }

    /// The capsule sits on the edge away from the control strip, so they never meet.
    private var capsuleOnTop: Bool {
        #if os(visionOS)
        true // the strip is an ornament under the window
        #else
        !toolbarDock.isTop || model.areControlsHidden || tabletop != nil
        #endif
    }

    /// How far the bottom of the safe area sits below the picture: the deck's share in tabletop,
    /// so banners and notes stay on the half that stands up.
    private var belowPicture: CGFloat {
        guard let tabletop else { return 0 }
        return max(0, screenSize.height - screenInsets.bottom - tabletop.picture.maxY)
    }

    #if os(iOS)
    /// Tabletop: the strip, keyboard and trackpad on the half on the desk, and dictation's panel
    /// over the bottom of the picture, where it can be read.
    private func tabletopDeck(_ layout: TabletopLayout) -> some View {
        ZStack(alignment: .topLeading) {
            dictationPanel
                .frame(maxWidth: 520)
                .frame(width: layout.picture.width, height: layout.picture.height, alignment: .bottom)
                .padding(.bottom, 12)
                .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.4, bounce: 0.15), value: model.dictation.isActive)
            TabletopDeck(input: model.input, stickyModifiers: $model.stickyModifiers, host: model.hostPlatform,
                         onKey: { keyCode, modifiers in model.tapChord(keyCode: keyCode, modifiers: modifiers) }) {
                if !model.areControlsHidden { controlStrip }
            }
            // The container already stops above the home indicator.
            .padding(EdgeInsets(top: 0, leading: max(16, screenInsets.leading), bottom: 12,
                                trailing: max(16, screenInsets.trailing)))
            .frame(width: layout.deck.width, height: layout.deck.height)
            .offset(y: layout.deck.minY)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .transition(.opacity)
    }
    #endif

    /// Banners slide down from the top, or just fade with Reduce Motion.
    private var bannerTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
    }

    private var noticeTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: .top)).combined(with: .offset(y: -6))
    }

    #if DEBUG
    /// For UI tests launched with `-VantageMacAudio`: the player's numbers as an invisible
    /// accessibility element (`session.macAudioStats`), refreshed every second.
    @ViewBuilder private var macAudioStatsProbe: some View {
        if ClientOptions.macAudio != nil {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let stats = model.macAudio.stats
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityIdentifier("session.macAudioStats")
                    .accessibilityLabel("playing \(model.macAudio.status == .playing ? 1 : 0) pushed \(String(stats.framesPushed)) played \(String(stats.framesPlayed)) depth \(Int(stats.milliseconds(stats.depthFrames))) latency \(Int(stats.milliseconds(stats.smoothedDepthFrames))) target \(Int(stats.milliseconds(stats.targetFrames))) underruns \(stats.underruns) skips \(stats.skips) trims \(stats.startTrims)")
            }
            .allowsHitTesting(false)
        }
    }
    #endif

    // MARK: Connection overlay

    private var connectionOverlay: some View {
        VStack(spacing: 16) {
            switch session.state {
            case .connecting, .authenticating, .connected:
                overlayProgress
                Text(model.isConnected ? "Starting screen capture…" : "Connecting to \(device.name)…")
                    .contentTransition(.opacity)
            case .reconnecting, .suspended:
                overlayProgress
                Text("Reconnecting…")
            case .pairingRequired:
                PairingPrompt(host: host, errorMessage: session.pairingError) { code in
                    model.submitPairingCode(code)
                }
            case .failed(let message):
                VStack(spacing: 12) {
                    Image(systemName: "wifi.exclamationmark").font(.largeTitle)
                        .accessibilityHidden(true)
                    Text(message).multilineTextAlignment(.center)
                    Button("Retry") { model.retry() }.buttonStyle(.onCardProminent)
                    Button("Close") { model.disconnect() }.buttonStyle(.onCard)
                }
            default:
                EmptyView()
            }
            if case .failed = session.state {} else {
                Button("Close") { model.disconnect() }.buttonStyle(.onCard)
            }
        }
        .padding(32)
        .frame(maxWidth: 420)
        #if os(macOS)
        // Dark glass over the black picture area, like `MacScreenNote`. Set for this card only:
        // `preferredColorScheme` from in here would also darken the window's toolbar.
        .platformGlass(in: .rect(cornerRadius: 24))
        .environment(\.colorScheme, .dark)
        #else
        .foregroundStyle(.white)
        .background(.black.opacity(0.8), in: .rect(cornerRadius: 24))
        .preferredColorScheme(.dark)
        #endif
    }

    private var overlayProgress: some View {
        ProgressView()
            .controlSize(.large)
            #if !os(macOS)
            .tint(.white)
            #endif
    }

    // MARK: Dictation

    @ViewBuilder private var dictationPanel: some View {
        if model.dictation.isActive {
            DictationPanel(dictation: model.dictation,
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

    // MARK: Keyboard and Pencil

    @ViewBuilder
    private var hiddenKeyboardField: some View {
        #if canImport(UIKit)
        if showKeyboard {
            RemoteKeyboardField(isPresented: $showKeyboard, onText: { model.typeFromSoftwareKeyboard($0) },
                                onKey: { model.tapKeyWithStickyModifiers($0) })
            .frame(width: 1, height: 1)
            .opacity(0.01)
        }
        #endif
    }

    /// Runs the Pencil action that needs the session's own state rather than the pointer.
    private func performPencilAction(_ action: PencilAction) {
        let animation: Animation? = reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.4, bounce: 0.2)
        switch action {
        case .collapseControls:
            withAnimation(animation) {
                if model.areControlsHidden { model.areControlsHidden = false } else { toolbarCollapsed.toggle() }
            }
        case .hideControls:
            withAnimation(animation) { model.areControlsHidden.toggle() }
        case .showKeyboard:
            showKeyboard.toggle()
        case .none, .rightClick, .middleClick:
            break // handled where the pointer is
        }
    }

    private func currentViewport() -> Viewport {
        Viewport(widthPoints: Double(viewportSize.width), heightPoints: Double(viewportSize.height), scale: Double(displayScale))
    }
}

#if canImport(UIKit)
import UIKit
#endif
