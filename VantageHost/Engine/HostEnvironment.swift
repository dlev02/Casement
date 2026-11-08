import CoreGraphics
import Foundation
import VantageCore

/// Everything platform-specific a `HostSession` needs, chosen once by the composition root
/// (`HostController`): the real Mac behind `MacHostEnvironment`, or the stand-ins in
/// `SyntheticHostEnvironment` for tests and screenshots. The session never reads `HostOptions`
/// or a platform singleton itself, so the same session code runs over loopback in a SwiftPM
/// test. The Windows host's `HostEnvironment` has the same shape.
nonisolated struct HostEnvironment: Sendable {
    /// `Challenge.hostName`: this computer's name as a person knows it.
    var hostName: String
    /// `Challenge.hostPlatform` and `HostCapabilities.platform`.
    var platform: HostPlatform
    /// Displays, display fitting, and frames.
    var screen: any HostScreen
    /// Whether the grants a screen session needs are in place (always true on a synthetic host).
    var screenRecordingGranted: @Sendable () -> Bool
    var accessibilityGranted: @Sendable () -> Bool
    /// One per session: keep-awake, display sleep and wake, lock.
    var makePower: @Sendable () -> any HostPowerControl
    /// One per session: lock, secure input and display sleep, as `HostStatus`.
    var makeStatusMonitor: @Sendable () -> any HostStatusMonitor
    /// One per session, for the display being streamed; nil when the host can't inject input
    /// (synthetic), and then input is counted but goes nowhere.
    var makeInputSink: (@Sendable (_ displayFrame: CGRect) -> any InputSink)?
    /// One per session; nil when the host has no clipboard to share (synthetic): long text is
    /// then typed rather than pasted, and `clipboard` messages are ignored.
    var makeClipboard: (@Sendable () -> any HostClipboard)?
    /// The computer's sound, for a client that asks (`audioRequest`).
    var audio: any HostAudio
    /// The curtain; nil when the host has no desktop to cover (synthetic), and then a request is
    /// only answered.
    var curtain: (any HostCurtain)?
    /// Dictation engines; nil advertises none.
    var dictation: (any DictationService)?
    /// Tailscale names for peers; nil leaves `peerTailnetName` out and keeps the device's own name.
    var peers: (any PeerDirectory)?
    /// Where files from the device land, read when a file channel attaches (Settings can change it).
    var fileDestination: @Sendable () -> FileDestination
    /// DEBUG `--capture-fails-for`: each session's capture fails this long from its first stream request.
    var captureFailsFor: Duration?
    /// The session's clock: `now` for its timers, and `sleep` for its waits.
    var clock: any HostClock
}

/// Displays and the frames captured from them.
nonisolated protocol HostScreen: Sendable {
    /// Displays a device may choose from (the `authResult` list, `refreshDisplays`).
    func displays() async throws -> [DisplayInfo]
    /// The display a stream request lands on: an existing one by id, or the one fitted to the
    /// device's viewport (a virtual display when asked for and available, else the main display).
    /// Throws `CaptureError.displayNotFound` when there is nothing to capture (display asleep).
    func resolve(_ select: SelectDisplay) async throws -> DisplayInfo
    /// A frame source for that display at that rate. `excludingClientOnThisComputer` leaves the
    /// device's own app out of the picture (a client connected to the Mac it runs on).
    func makeCapture(for display: DisplayInfo, fps: Int, excludingClientOnThisComputer: Bool) -> any FrameSource
    /// Whether a display chosen by id can be asked for again after a capture restart: real
    /// displays persist; a synthetic display is made to each request's viewport.
    var canRestartByDisplayID: Bool { get }
    /// `HostCapabilities.canManageVirtualDisplay`.
    var canManageVirtualDisplay: Bool { get }
    /// `restoreDisplays`: disconnect a virtual display this host provisioned.
    func restoreDisplays() async
}

/// Keep-awake, display sleep and wake, and the lock screen, for one session.
nonisolated protocol HostPowerControl: Sendable {
    /// Holds the display awake while the session lasts.
    func keepAwake()
    func releaseKeepAwake()
    /// Turns the display on; `minimumInterval` limits how often input may do so. False when the
    /// interval hasn't passed.
    @discardableResult
    func wakeDisplay(reason: String, minimumInterval: Duration) -> Bool
    func sleepDisplay()
    func lockScreen()
    var isDisplayAsleep: Bool { get }
    /// Whether any panel is lit at all, with a description for the log.
    var panel: (isOff: Bool, text: String) { get }
}

/// Lock, secure input and display sleep, as the client hears them.
nonisolated protocol HostStatusMonitor: AnyObject, Sendable {
    var onChange: (@Sendable (HostStatus) -> Void)? { get set }
    func start()
    func stop()
    func currentStatus() -> HostStatus
    /// Checks again now (after a sleep or wake command) instead of waiting for the next tick.
    func refresh()
}

/// Where a session's input goes.
nonisolated protocol InputSink: AnyObject, Sendable {
    func updateDisplayFrame(_ frame: CGRect)
    func handle(_ event: PointerEvent)
    func handle(_ event: ScrollEvent)
    func handle(_ event: KeyEvent)
    func typeText(_ text: String)
    func pressPaste()
    func releaseAll()
}

/// The computer's pasteboard, both ways.
nonisolated protocol HostClipboard: AnyObject, Sendable {
    var onLocalChange: (@Sendable (ClipboardPayload) -> Void)? { get set }
    func start()
    func stop()
    func currentPayload() -> ClipboardPayload
    /// Applies the device's clipboard; returns once the pasteboard holds it.
    func apply(_ payload: ClipboardPayload) async
    /// Pastes long text through the pasteboard and puts the old contents back afterwards.
    func paste(_ text: String, pressPaste: @escaping @Sendable () -> Void) async
}

/// The computer's sound.
nonisolated protocol HostAudio: Sendable {
    func makeSource() -> any AudioSource
    /// What to tell the device when the source fails to start.
    func message(for error: any Error) -> String
}

/// The curtain: the computer's panels go black and its own input stops while a device wants it.
nonisolated protocol HostCurtain: Sendable {
    /// Joins a curtain still up from a session that just ended; true when there was one.
    func adopt(_ holder: ObjectIdentifier, notify: @escaping @Sendable (CurtainStatus) -> Void) async -> Bool
    /// Raises or lowers it for this holder. Returns why it couldn't go up, or nil.
    /// `fromThisComputer`: the device is a client running on this same computer.
    func set(_ wanted: Bool, for holder: ObjectIdentifier, fromThisComputer: Bool,
             notify: @escaping @Sendable (CurtainStatus) -> Void) async -> String?
    func sessionEnded(_ holder: ObjectIdentifier) async
}

/// Dictation on the computer.
nonisolated protocol DictationService: Sendable {
    /// Engines this computer can run right now, best first.
    func availableEngines() async -> [DictationEngineID]
    func transcribe(samples: Data, requested: DictationEngineID?, language: String?) async -> DictationOutcome
}

nonisolated enum DictationOutcome: Sendable {
    case text(String, engine: DictationEngineID)
    /// A message for the person dictating.
    case failed(String)
}

/// Names for tailnet peers.
nonisolated protocol PeerDirectory: Sendable {
    /// The tailnet user behind a peer address, for `Challenge.peerTailnetName`.
    func userName(ofPeer address: String) -> String?
    /// The device's own name on the tailnet, where iOS reports "iPad".
    func deviceName(ofPeer host: String) -> String?
}

/// Where a file channel saves what arrives, and how.
nonisolated struct FileDestination: Sendable {
    var directory: URL
    var configuration: FileTransferConfiguration
}

/// Paired devices and the pairing code, as the handshake uses them (`TrustStore` on a real host).
nonisolated protocol HostTrust: AnyObject, Sendable {
    func isTrusted(_ publicKey: Data) -> Bool
    func consumePairingCode(_ code: String) -> PairingCheck
    func trust(_ publicKey: Data, name: String, model: String?)
    func name(ofFingerprint fingerprint: String) -> String?
    /// Swaps a generic "iPad" for the device's tailnet name; a name someone chose stays.
    func adoptTailnetName(_ name: String, fingerprint: String)
}

nonisolated enum PairingCheck: Sendable { case accepted, incorrect, unavailable }

/// The session's clock, so tests can run its timers without waiting.
nonisolated protocol HostClock: Sendable {
    var now: ContinuousClock.Instant { get }
    func sleep(for duration: Duration) async throws
}

nonisolated struct SystemHostClock: HostClock {
    var now: ContinuousClock.Instant { .now }
    func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}
