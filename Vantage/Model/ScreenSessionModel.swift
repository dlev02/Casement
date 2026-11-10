import Accessibility
import Foundation
import Observation
import VantageCore

/// What a screen session reads and records about its saved computer. `DeviceStore` is the app's;
/// tests use one in memory.
protocol ScreenSessionStore: AnyObject {
    /// The saved computer as it is now (edits and what the host said arrive here).
    func savedDevice(_ id: UUID) -> SavedDevice?
    func markConnected(_ device: SavedDevice)
    func recordPlatform(_ platform: HostPlatform, for id: UUID)
    func recordHostKey(_ key: Data, for id: UUID)
    func setPlayMacAudio(_ on: Bool, for id: UUID)
    func setCurtain(_ on: Bool, for id: UUID)
}

/// Why there's no live picture, if the computer has said.
nonisolated enum ScreenNote: Equatable, Sendable {
    /// The Mac's display is asleep.
    case asleep
    /// The display is awake, but the host has had no picture for a few seconds; it keeps trying.
    case unavailable
}

/// A value shown for a while that then clears itself; a new value restarts the clock.
@MainActor @Observable
final class TimedNotice<Value> {
    private(set) var value: Value?
    @ObservationIgnored private var timer: Task<Void, Never>?

    func show(_ value: Value, for duration: Duration) {
        self.value = value
        timer?.cancel()
        timer = Task { [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            self?.value = nil
        }
    }

    func clear() {
        timer?.cancel()
        timer = nil
        value = nil
    }
}

/// One screen session with a saved computer: the connection, the picture, input, dictation and
/// the computer's sound, wired together once; the computer's saved choices (sound, Curtain,
/// scrolling, keys, control strip); what happens when the connection comes and goes; the notices
/// that clear themselves; and every action the session screen, the control strip, the session
/// menu, the Mac menu bar and toolbar offer. `RemoteSessionScreen` lays it out.
///
/// `start(viewport:)` connects and `stop()` lets go; `end()` is Disconnect, which the screen
/// answers by closing (`isEnded`). Files belong to the computer (`FileLink`), so they keep moving
/// after `stop()` on a current host.
@MainActor @Observable
final class ScreenSessionModel {
    enum Phase: Equatable { case idle, running, stopped }

    /// The saved computer as it was opened. `savedDevice` follows edits made meanwhile.
    let device: SavedDevice
    private let store: any ScreenSessionStore
    private let fileLink: FileLink?
    let session: ClientSession
    let video: VideoStreamController
    let input = InputController()
    let dictation = DictationController()
    let macAudio = MacAudioPlayer()

    private(set) var phase: Phase = .idle
    /// Disconnect was chosen (or confirmed): the screen closes.
    private(set) var isEnded = false
    /// The first frame of the current connection has been shown.
    private(set) var hasPicture = false
    /// Modifiers latched on the control strip, sent with the next key.
    var stickyModifiers: KeyModifiers = []
    /// The control strip is hidden (the pencil, the Mac's View menu).
    var areControlsHidden = false
    /// Files are being dragged over the picture.
    var isDropTargeted = ClientOptions.dropHintFixture

    // What the actions open.
    var passwordPrompt: PasswordPrompt?
    var isPickingFiles = false
    var isShowingTransfers = false
    var isEditingControls = false
    /// "Files are still transferring. Disconnect anyway?" (an older host would stop them).
    var isConfirmingDisconnect = false

    // Notices.
    /// The file just received, for the notice at the top.
    let receivedNotice = TimedNotice<FileTransferController.Transfer>()
    /// Why the computer's sound stopped or couldn't start (also a refused Curtain).
    let macAudioNotice = TimedNotice<String>()
    private let wakeRequest = TimedNotice<Bool>()
    private(set) var screenSharingTyping: ScreenSharingTypingState?
    var screenSharingError: String?
    /// VoiceOver is on, so notices stay long enough to reach their buttons.
    var usesVoiceOver = false

    // Settings that apply to every session, read from the defaults and refreshed when they change.
    private(set) var trackpadSensitivity = 1.5
    private(set) var keyboardMode = SoftwareKeyboardMode.unicode
    private(set) var dictationEngine = DictationEnginePreference.mac
    private(set) var defaultStripLayout = ControlStripLayout.platformStandard
    var touchMode = InputController.TouchMode.trackpad {
        didSet {
            guard touchMode != oldValue else { return }
            input.mode = touchMode
            UserDefaults.standard.set(touchMode.rawValue, forKey: Self.touchModeKey)
        }
    }
    #if os(macOS)
    /// "Send keyboard shortcuts to the Mac" (Settings, the Session menu, the toolbar).
    var capturesShortcuts = true {
        didSet {
            guard capturesShortcuts != oldValue else { return }
            UserDefaults.standard.set(capturesShortcuts, forKey: MacKeyboardSettings.captureShortcutsKey)
        }
    }
    /// Watch without sending the pointer or keys. On by default when the Mac is this one.
    var isViewOnly = false
    /// The session's Mac is the one this app runs on (see `ThisMac`).
    private(set) var viewsThisMac = false
    private var checkedThisMac = false
    #endif

    /// `-VantageMacAudio` (DEBUG) until the user flips the toggle.
    private var macAudioOverride = ClientOptions.macAudio
    private var viewport: Viewport
    private var viewportDebounce: Task<Void, Never>?
    private var feedbackTask: Task<Void, Never>?
    private var screenSharingTask: Task<Void, Never>?
    private var watchers: [Task<Void, Never>] = []
    private var defaultsObserver: (any NSObjectProtocol)?
    private var queuedTestFile = false

    static let touchModeKey = "vantage.touchMode"
    static let trackpadSensitivityKey = "vantage.trackpadSensitivity"
    static let keyboardModeKey = "vantage.softwareKeyboardMode"
    static let dictationEngineKey = "vantage.dictationEngine"

    /// `fileLink`: the computer's shared link (`FileTransferCenter`), so files keep moving after
    /// the screen closes; nil keeps the session's own (tests).
    init(device: SavedDevice, store: any ScreenSessionStore, fileLink: FileLink? = nil,
         session: ClientSession = ClientSession(), viewport: Viewport = Viewport(widthPoints: 1210, heightPoints: 834, scale: 2)) {
        self.device = device
        self.store = store
        self.fileLink = fileLink
        self.session = session
        self.viewport = viewport
        video = VideoStreamController()
        readPreferences()
        wire()
    }

    // MARK: The computer

    /// The saved computer as it is now (edits and what the host said arrive through the store).
    var savedDevice: SavedDevice { store.savedDevice(device.id) ?? device }
    /// What the host runs: what it said in this session, else what the saved computer remembers.
    var hostPlatform: HostPlatform { session.hostPlatform ?? savedDevice.platform }
    /// "Mac" or "PC", for everything the session says about the computer.
    var host: HostNoun { HostNoun(hostPlatform) }
    /// "⌘ acts as Ctrl" for a PC; nothing for a Mac.
    var keyRemap: KeyRemap { KeyRemap.forHost(hostPlatform, commandSendsControl: savedDevice.commandSendsControl) }
    /// This computer's saved Natural Scrolling (an edit mid-session applies).
    var naturalScroll: Bool { savedDevice.naturalScroll }
    /// This computer's own control strip if it has one, else the default, less what this device
    /// or the host can't use. Edits made mid-session (or synced in) show up straight away.
    var stripItems: [StripItem] {
        (savedDevice.controlStrip ?? defaultStripLayout).visibleItems(excluding: StripItem.unavailable(on: hostPlatform))
    }

    // MARK: Connection

    var isConnected: Bool { session.state == .connected }
    var isLive: Bool { isConnected && hasPicture }
    /// Why there's no live picture, if the computer has said.
    var screenNote: ScreenNote? {
        if session.isDisplayAsleep { return .asleep }
        if session.isScreenUnavailable { return .unavailable }
        return nil
    }
    /// Wake was tapped and the display hasn't come on yet (clears itself after a while so the
    /// button works again if the computer didn't answer).
    var isWakeRequested: Bool { wakeRequest.value != nil }

    /// Connects, and keeps the collaborators in step with the connection from here on.
    func start(viewport: Viewport) {
        guard phase == .idle else { return }
        phase = .running
        self.viewport = viewport
        if let fileLink { session.useFileLink(fileLink) }
        session.files.onReceived = { [weak self] transfer in self?.showReceived(transfer) }
        #if DEBUG
        if let millis = ClientOptions.slowFilesMillis { session.files.chunkDelayForTesting = .milliseconds(millis) }
        #endif
        applySavedChoices()
        input.mode = touchMode
        input.naturalScroll = naturalScroll
        input.trackpadSensitivity = trackpadSensitivity
        input.keyRemap = keyRemap
        watchDefaults()
        startWatching()
        connect(pairingCode: ClientOptions.pairingCode)
        startFeedbackLoop()
    }

    /// Lets go of the connection and everything the session was doing. The computer's transfers
    /// outlive this screen; they just stop being reported here.
    func stop() {
        guard phase == .running else { return }
        phase = .stopped
        // Before the watchers go: a clip being prepared, recorded or transcribed is dropped (and
        // the computer told, while the connection is still up), so the mic never opens afterwards.
        dictation.cancel()
        feedbackTask?.cancel()
        feedbackTask = nil
        viewportDebounce?.cancel()
        screenSharingTask?.cancel()
        screenSharingTask = nil
        for watcher in watchers { watcher.cancel() }
        watchers = []
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = nil
        receivedNotice.clear()
        macAudioNotice.clear()
        wakeRequest.clear()
        macAudio.setWanted(false)
        session.files.onReceived = nil
        session.disconnect()
    }

    /// Disconnect from the strip, the menu, or the overlay. Files keep moving without the screen
    /// on a current host (the device list shows them). Only an older host, which would stop
    /// them, gets the one confirmation Disconnect ever asks for.
    func disconnect() {
        if disconnectWouldStopFiles { isConfirmingDisconnect = true } else { end() }
    }

    /// Ending the screen session would cut files still moving (an older host keeps no file
    /// channel without the screen).
    var disconnectWouldStopFiles: Bool {
        session.files.hasActiveTransfers && session.fileLink.macKeepsFiles == false
    }

    /// Disconnects for good: the screen closes.
    func end() {
        stop()
        isEnded = true
    }

    /// Retry after a failure: the same wiring, with the saved choices as they are now (a refused
    /// Curtain cleared its choice; sound or Curtain may have changed while the session was down).
    func retry() {
        applySavedChoices()
        connect(pairingCode: ClientOptions.pairingCode)
    }

    /// The saved computer's sound and Curtain choices, applied to the player and the connection.
    private func applySavedChoices() {
        macAudio.setWanted(wantsMacAudio)
        session.setMacAudio(wantsMacAudio)
        session.setCurtain(wantsCurtain)
    }

    func submitPairingCode(_ code: String) { connect(pairingCode: code) }

    private func connect(pairingCode: String?) {
        session.connect(to: device, viewport: viewport, pairingCode: pairingCode)
    }

    /// The app left the screen (background, the Mac going to sleep): let go of the connection
    /// and anything held, keeping the intent to come back.
    func suspend() {
        if dictation.isListening { dictation.stop(then: .review) }
        stickyModifiers = []
        session.suspendForBackground()
    }

    /// The app is back: pick up where the connection left off.
    func resume() { session.retryNow() }

    /// The session view changed size (a fold, a rotation, a resize). Once it has settled, the
    /// host is asked to fit the new shape, so a live resize asks once, not per frame.
    func viewportChanged(_ viewport: Viewport) {
        guard viewport != self.viewport else { return }
        self.viewport = viewport
        viewportDebounce?.cancel()
        viewportDebounce = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard let self else { return }
            session.updateViewport(viewport)
        }
    }

    /// Wake/Retry, or a tap on the computer's screen while there's no live picture.
    func wakeDisplay() {
        guard !isWakeRequested else { return }
        session.wakeDisplay()
        wakeRequest.show(true, for: .seconds(6))
    }

    // MARK: Actions

    func sendHostCommand(_ command: HostCommand) {
        session.send(.hostCommand(HostCommandMessage(command: command)))
    }

    /// A chord from the control strip, the keyboard or the Mac's menus.
    func tapChord(keyCode: UInt16, modifiers: KeyModifiers) {
        input.tapChord(keyCode: keyCode, modifiers: modifiers)
    }

    func sendShortcut(_ shortcut: HostShortcut) {
        input.tapChord(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers)
    }

    /// Send Clipboard: whatever is on the clipboard here, now.
    func sendClipboard() {
        let payload = ClipboardSync.currentPayload()
        if !payload.isEmpty { session.send(.clipboard(payload)) }
    }

    #if os(macOS)
    /// Just before a paste chord goes to the computer: something copied here since the last sync
    /// goes over first, so the paste there has it (the host writes it before it posts the key).
    func pasteThroughClipboard() {
        if let payload = ClipboardSync.changedPayload() { session.send(.clipboard(payload)) }
    }
    #endif

    /// A key typed on the software keyboard (iPad): Unicode text is the default. Keystrokes mode,
    /// or any held ⌘/⌥/⌃, sends real key presses so shortcuts like ⌘C work from it.
    func typeFromSoftwareKeyboard(_ text: String) {
        if keyboardMode == .keystrokes || !stickyModifiers.isEmpty {
            input.typeCharacters(text, modifiers: stickyModifiers)
            stickyModifiers = []
        } else {
            input.typeText(text)
        }
    }

    /// A key from the software keyboard's accessory (Return, arrows): with the latched modifiers.
    func tapKeyWithStickyModifiers(_ keyCode: UInt16) {
        input.tapChord(keyCode: keyCode, modifiers: stickyModifiers)
        stickyModifiers = []
    }

    // MARK: Type Password

    /// Types the saved password for this Mac and presses Return, through Screen Sharing when the
    /// Mac blocks ordinary typing, or asks for what's missing (`TypePasswordDecision`).
    func typePassword() {
        let decision = TypePasswordDecision.decide(host: host, password: DeviceSecrets.password(for: device),
                                                   hasAccountName: DeviceSecrets.username(for: device) != nil,
                                                   status: session.hostStatus)
        switch decision {
        case .nothing:
            break
        case .ask(let prompt):
            passwordPrompt = prompt
        case .type(let password):
            stickyModifiers = []
            input.typeCharacters(password)
            input.tapChord(keyCode: 0x24, modifiers: []) // Return
        case .screenSharing:
            typeThroughScreenSharing()
        }
    }

    /// The password sheet was saved: keeps what it gave (a password, an account name, or both)
    /// and types.
    func savePasswordAndType(password: String?, accountName: String?) {
        passwordPrompt = nil
        if let password, !password.isEmpty { DeviceSecrets.setPassword(password, for: device) }
        if let accountName, !accountName.isEmpty { DeviceSecrets.setUsername(accountName, for: device) }
        typePassword()
    }

    private func typeThroughScreenSharing() {
        guard screenSharingTyping != .typing else { return }
        stickyModifiers = []
        screenSharingTyping = .typing
        screenSharingTask = Task { [weak self, device] in
            do {
                try await ScreenSharingPassword.type(for: device)
                guard let self, !Task.isCancelled else { return }
                screenSharingTyping = .sent
                try? await Task.sleep(for: .seconds(1.6))
                guard !Task.isCancelled else { return }
                if screenSharingTyping == .sent { screenSharingTyping = nil }
            } catch {
                guard let self, !Task.isCancelled else { return }
                screenSharingTyping = nil
                screenSharingError = ScreenSharingPassword.message(for: error)
            }
        }
    }

    // MARK: Files

    /// The computer takes files (the file channel comes up on demand).
    var canSendFiles: Bool { isConnected && session.hostOffersFiles }

    var sendFileAction: SendFileAction {
        let active = session.files.transfers.filter { $0.state == .active }
        let progress: Double? = active.isEmpty ? nil
            : Double(active.reduce(0) { $0 + $1.bytesDone }) / Double(max(1, active.reduce(0) { $0 + $1.byteCount }))
        return SendFileAction(
            unavailableReason: isConnected && !session.hostOffersFiles
                ? "\(device.name)'s Casement Host can't receive files. Update Casement Host on \(host.the)." : nil,
            progress: progress,
            hasTransfers: session.files.hasTransfers,
            onSend: { [weak self] in self?.isPickingFiles = true },
            onShowTransfers: { [weak self] in self?.isShowingTransfers = true })
    }

    /// Shows "Received …" for a few seconds (long enough to reach its buttons with VoiceOver)
    /// and says it aloud, since the notice appears without focus moving to it. A run of several
    /// files is announced once, by the capsule, when it ends.
    private func showReceived(_ transfer: FileTransferController.Transfer) {
        receivedNotice.show(transfer, for: .seconds(usesVoiceOver ? 15 : 6))
        if session.files.summary.count <= 1 {
            AccessibilityNotification.Announcement("Received \(transfer.name) from \(device.name)").post()
        }
    }

    // MARK: Sound and Curtain

    /// This computer's saved choice (from the store, so it follows edits and iCloud), unless a
    /// debug launch flag says otherwise.
    var wantsMacAudio: Bool { macAudioOverride ?? savedDevice.playMacAudio ?? false }

    var macAudioFailed: Bool {
        if case .unavailable = macAudio.status { return true }
        return false
    }

    var isMacAudioOn: Bool { wantsMacAudio && !macAudioFailed }
    var isMacAudioAvailable: Bool { isConnected && session.hostOffersAudio }

    var macAudioToggle: MacAudioToggle {
        MacAudioToggle(
            isOn: isMacAudioOn,
            unavailableReason: isConnected && !session.hostOffersAudio
                ? "\(device.name)'s Casement Host can't send sound. Update Casement Host on \(host.the)." : nil,
            onToggle: { [weak self] in self?.toggleMacAudio() })
    }

    /// Off → on, on → off, and a failed stream → try again (the choice itself stays on).
    func toggleMacAudio() {
        let on = macAudioFailed ? true : !wantsMacAudio
        macAudioOverride = nil
        store.setPlayMacAudio(on, for: device.id)
        macAudioNotice.clear()
        if on, macAudioFailed { macAudio.setWanted(false) } // start over
        macAudio.setWanted(on)
        session.setMacAudio(on)
    }

    var wantsCurtain: Bool { savedDevice.curtain ?? false }
    /// Once the host has answered, it says; a local lock at the computer lowers it.
    var isCurtainOn: Bool { session.curtainStatus?.isUp ?? wantsCurtain }
    var isCurtainAvailable: Bool { isConnected && session.hostOffersCurtain }

    var curtainToggle: CurtainToggle {
        CurtainToggle(
            isOn: isCurtainOn,
            unavailableReason: isConnected && !session.hostOffersCurtain
                ? "\(device.name)'s Casement Host can't do this. Update Casement Host on \(host.the)." : nil,
            onToggle: { [weak self] in self?.toggleCurtain() })
    }

    func toggleCurtain() {
        let on = !isCurtainOn
        store.setCurtain(on, for: device.id)
        session.setCurtain(on)
    }

    // MARK: Dictation

    /// The computer (MacWhisper, Parakeet) when the host advertised it and Settings allows it;
    /// otherwise this device.
    var dictationRoute: DictationRoute {
        DictationRoute.resolve(preference: dictationEngine, hostEngines: session.dictationEngines)
    }

    func dictationPressed(_ press: DictationPress) {
        stickyModifiers = []
        switch press {
        case .began: dictation.pressBegan(route: dictationRoute)
        case .ended(let held): dictation.pressEnded(held: held)
        case .toggle: dictation.toggle(route: dictationRoute)
        case .cancelled: dictation.pressCancelled()
        }
    }

    // MARK: Wiring

    /// Connects the collaborators to each other, once. Closures hold the collaborators or a weak
    /// self, never a cycle.
    private func wire() {
        session.onVideo = { [video] message in video.consume(message) }
        session.onClipboard = { payload in ClipboardSync.apply(payload) }
        session.onCursorShape = { [input] shape in input.setCursorShape(shape) }
        session.onCursor = { [input] position in input.setCursorVisible(position.isVisible) }
        session.onDictationResult = { [dictation] result in dictation.handle(result) }
        session.onAudio = { [macAudio] message in macAudio.handle(message) }
        video.onNeedsKeyframe = { [weak self] in
            Task { @MainActor in self?.session.send(.requestKeyframe) }
        }
        video.onFirstFrame = { [weak self] in
            Task { @MainActor in self?.hasPicture = true }
        }
        input.send = { [weak self] message in self?.session.send(message) }
        dictation.send = { [weak self] message in self?.session.send(message) }
        dictation.deliver = { [input] text, pressReturn in
            input.typeText(text)
            if pressReturn { input.tapChord(keyCode: 0x24, modifiers: []) }
        }
        dictation.onMicrophoneActive = { [macAudio] active in macAudio.setMicrophoneActive(active) }
    }

    /// Reacts to what changes while the session runs, the way the screen's `onChange` used to.
    private func startWatching() {
        watch({ $0.session.state }, same: { $0 == $1 }) { model, state in model.connectionStateChanged(state) }
        watch({ $0.session.activeConfig }) { model, config in
            if let config {
                model.input.displayPointSize = CGSize(width: config.display.pointWidth, height: config.display.pointHeight)
            }
        }
        watch({ $0.session.curtainStatus }) { model, status in
            // A refused Curtain clears the saved choice, and says why.
            if let reason = status?.unavailable {
                model.store.setCurtain(false, for: model.device.id)
                model.showMacAudioNotice(reason)
            }
        }
        watch({ $0.macAudio.status }, same: { $0 == $1 }) { model, status in
            if case .unavailable(let reason) = status { model.showMacAudioNotice(reason) }
        }
        watch({ $0.screenNote }) { model, note in
            model.wakeRequest.clear()
            switch note {
            case .asleep?: AccessibilityNotification.Announcement("\(model.host.thePossessiveCapitalized) display is asleep").post()
            case .unavailable?: AccessibilityNotification.Announcement("Waiting for \(model.host.thePossessive) screen").post()
            case nil: break
            }
        }
        watch({ $0.keyRemap }) { model, remap in model.input.keyRemap = remap }
        watch({ $0.naturalScroll }) { model, natural in model.input.naturalScroll = natural }
        // Files opened in Casement from other apps join this session's queue once approved.
        watch({ _ in SharedFileInbox.shared.pending.count }, initial: true) { model, count in
            guard count > 0 else { return }
            for copy in SharedFileInbox.shared.take() { model.session.files.sendOutboxCopy(copy) }
        }
        #if DEBUG
        watch({ $0.session.files.isConnected }) { model, connected in
            if connected, !model.queuedTestFile, let bytes = ClientOptions.sendTestFileBytes {
                model.queuedTestFile = true
                model.session.files.queueTestFile(bytes: bytes)
            }
        }
        #endif
    }

    /// Runs `react` whenever what `read` observes changes to a different value (and first with
    /// the current value when `initial`), until `stop()`.
    private func watch<Value: Equatable & Sendable>(_ read: @escaping @MainActor (ScreenSessionModel) -> Value, initial: Bool = false,
                                                     _ react: @escaping @MainActor (ScreenSessionModel, Value) -> Void) {
        watch(read, initial: initial, same: { $0 == $1 }, react)
    }

    /// The same for a value whose `==` is main-actor isolated (an enum nested in a main-actor class).
    private func watch<Value: Sendable>(_ read: @escaping @MainActor (ScreenSessionModel) -> Value, initial: Bool = false,
                                         same: @escaping @MainActor (Value, Value) -> Bool,
                                         _ react: @escaping @MainActor (ScreenSessionModel, Value) -> Void) {
        watchers.append(Task { [weak self] in
            guard let self else { return }
            var previous: Value?
            for await value in Observations({ read(self) }) {
                guard !Task.isCancelled else { return }
                if let previous, same(previous, value) { continue }
                let first = previous == nil
                previous = value
                if first, !initial { continue }
                react(self, value)
            }
        })
    }

    private func connectionStateChanged(_ state: ClientSession.State) {
        if state == .connected {
            store.markConnected(device)
            // Hosts before the platform field are all Macs.
            store.recordPlatform(session.hostPlatform ?? .macOS, for: device.id)
            if let key = session.hostPublicKey { store.recordHostKey(key, for: device.id) }
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
            announce(state)
            hasPicture = false
            video.resetFirstFrame()
            dictation.connectionLost()
            macAudio.connectionLost()
        }
    }

    /// Says what the overlay now shows, since it appears without VoiceOver's focus moving to it.
    private func announce(_ state: ClientSession.State) {
        let text: String? = switch state {
        case .reconnecting: "Reconnecting to \(device.name)"
        case .pairingRequired: "Enter the pairing code shown on \(host.the)"
        case .failed(let message): message
        default: nil
        }
        if let text { AccessibilityNotification.Announcement(text).post() }
    }

    private func showMacAudioNotice(_ message: String) {
        macAudioNotice.show(message, for: .seconds(5))
    }

    /// Every 250 ms while connected: a ping, and how the picture is doing, for the host's
    /// adaptive bitrate.
    private func startFeedbackLoop() {
        feedbackTask?.cancel()
        feedbackTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, session.state == .connected else { continue }
                session.ping()
                let feedback = video.snapshotStats(windowSeconds: 0.25, rttMillis: session.lastRTTMillis)
                session.sendFeedback(feedback)
            }
        }
    }

    // MARK: Settings

    /// What the defaults said last time, so only a key that has changed since is applied: a
    /// key pinned in the argument domain (UI tests, screenshots) outranks every write, and
    /// re-reading it must not undo a toggle made here.
    private var readDefaults = ReadDefaults()
    private struct ReadDefaults {
        var touchMode: InputController.TouchMode?
        var trackpadSensitivity: Double?
        var keyboardMode: SoftwareKeyboardMode?
        var dictationEngine: DictationEnginePreference?
        var defaultStripLayout: ControlStripLayout?
        var capturesShortcuts: Bool?
    }

    private func readPreferences() {
        let defaults = UserDefaults.standard
        let touch = defaults.string(forKey: Self.touchModeKey).flatMap(InputController.TouchMode.init(rawValue:)) ?? .trackpad
        if touch != readDefaults.touchMode {
            readDefaults.touchMode = touch
            if touch != touchMode { touchMode = touch }
        }
        let sensitivity = defaults.object(forKey: Self.trackpadSensitivityKey) as? Double ?? 1.5
        if sensitivity != readDefaults.trackpadSensitivity {
            readDefaults.trackpadSensitivity = sensitivity
            trackpadSensitivity = sensitivity
            input.trackpadSensitivity = sensitivity
        }
        let keyboard = defaults.string(forKey: Self.keyboardModeKey).flatMap(SoftwareKeyboardMode.init(rawValue:)) ?? .unicode
        if keyboard != readDefaults.keyboardMode {
            readDefaults.keyboardMode = keyboard
            keyboardMode = keyboard
        }
        let engine = defaults.string(forKey: Self.dictationEngineKey).flatMap(DictationEnginePreference.init(rawValue:)) ?? .mac
        if engine != readDefaults.dictationEngine {
            readDefaults.dictationEngine = engine
            dictationEngine = engine
        }
        let layout = defaults.string(forKey: ControlStripLayout.defaultsKey).flatMap(ControlStripLayout.init(rawValue:)) ?? .platformStandard
        if layout != readDefaults.defaultStripLayout {
            readDefaults.defaultStripLayout = layout
            defaultStripLayout = layout
        }
        #if os(macOS)
        let captures = defaults.object(forKey: MacKeyboardSettings.captureShortcutsKey) == nil
            ? true : defaults.bool(forKey: MacKeyboardSettings.captureShortcutsKey)
        if captures != readDefaults.capturesShortcuts {
            readDefaults.capturesShortcuts = captures
            if captures != capturesShortcuts { capturesShortcuts = captures }
        }
        #endif
    }

    /// Settings changed elsewhere (Settings → Controls, the Mac's Settings window) apply mid-session.
    private func watchDefaults() {
        guard defaultsObserver == nil else { return }
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.readPreferences() }
        }
    }

    #if os(macOS)
    /// The first time the session connects: is its Mac this one? Then it starts in View Only,
    /// since every move and key would come straight back through the host
    /// (`-VantageAllowSelfControl 1` treats it as another Mac: input on, no banner, for tests and
    /// screenshots).
    private func checkForThisMac() {
        viewsThisMac = !MacSessionOptions.allowSelfControl && ThisMac.isHost(address: device.host, hostName: session.hostName)
        guard !checkedThisMac else { return }
        checkedThisMac = true
        if viewsThisMac { isViewOnly = true }
    }
    #endif
}
