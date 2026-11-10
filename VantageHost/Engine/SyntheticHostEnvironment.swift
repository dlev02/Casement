import CoreGraphics
import Foundation
import ImageIO
import VantageCore

/// The stand-ins a synthetic host (`--synthetic-capture`) runs on: a pretend display that sleeps
/// and wakes on command, a rendered test pattern (or `--synthetic-image`), a chime for sound, no
/// input, clipboard, curtain, dictation or tailnet, and nothing that touches the real Mac's
/// displays, keyboard or permissions. Tests build one with a fake clock and a temp folder.
nonisolated enum SyntheticHostEnvironment {
    static func make(hostName: String = "Synthetic Mac", platform: HostPlatform = .macOS, display: FakeDisplay = FakeDisplay(),
                     picture: CGImage? = nil, fileDestination: @escaping @Sendable () -> FileDestination,
                     resumeFolder: @escaping @Sendable (UUID) -> URL? = { _ in nil },
                     captureFailsFor: Duration? = nil, clock: any HostClock = SystemHostClock()) -> HostEnvironment {
        HostEnvironment(hostName: hostName, platform: platform,
                        screen: SyntheticScreen(display: display, picture: picture),
                        screenRecordingGranted: { true }, accessibilityGranted: { true },
                        makePower: { SyntheticPower(display: display) },
                        makeStatusMonitor: { SyntheticStatusMonitor(display: display) },
                        makeInputSink: nil, makeClipboard: nil,
                        audio: SyntheticAudio(), curtain: nil, dictation: nil, peers: nil,
                        fileDestination: fileDestination, resumeFolder: resumeFolder, captureFailsFor: captureFailsFor, clock: clock)
    }

    /// A synthetic display sized to a 2x iPad by default.
    static func syntheticDisplay(pointWidth: Int = 1470, pointHeight: Int = 956) -> DisplayInfo {
        DisplayInfo(id: 1, name: "Vantage Synthetic Display",
                    pixelWidth: pointWidth * 2, pixelHeight: pointHeight * 2,
                    pointWidth: pointWidth, pointHeight: pointHeight, scale: 2,
                    originX: 0, originY: 0, isMain: true, isBuiltIn: false, isVirtual: true, refreshRate: 60)
    }

    /// `--synthetic-image`: the picture a synthetic host streams instead of its test pattern.
    static func loadPicture(atPath path: String?) -> CGImage? {
        guard let path, let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

/// The pretend display: starts asleep with `--display-asleep`, and sleeps and wakes on command the
/// way a real one does. Its capture stops when it sleeps, as ScreenCaptureKit's does.
nonisolated final class FakeDisplay: @unchecked Sendable {
    private let lock = NSLock()
    private var asleep: Bool
    private var observers: [UUID: @Sendable (Bool) -> Void] = [:]

    init(asleep: Bool = false) {
        self.asleep = asleep
    }

    var isAsleep: Bool { lock.withLock { asleep } }
    func sleep() { set(asleep: true) }
    func wake() { set(asleep: false) }

    /// Hears every change until the token is removed.
    func observe(_ body: @escaping @Sendable (_ asleep: Bool) -> Void) -> UUID {
        let token = UUID()
        lock.withLock { observers[token] = body }
        return token
    }

    func removeObserver(_ token: UUID) {
        lock.withLock { observers[token] = nil }
    }

    private func set(asleep: Bool) {
        let notify: [@Sendable (Bool) -> Void] = lock.withLock {
            guard self.asleep != asleep else { return [] }
            self.asleep = asleep
            return Array(observers.values)
        }
        for body in notify { body(asleep) }
    }
}

/// One synthetic display, made to each request's viewport (or the picture's size), that lists
/// nothing while asleep, like ScreenCaptureKit.
nonisolated struct SyntheticScreen: HostScreen {
    let display: FakeDisplay
    let picture: CGImage?

    var canRestartByDisplayID: Bool { false }
    var canManageVirtualDisplay: Bool { false }

    func displays() async throws -> [DisplayInfo] {
        if let picture {
            return [SyntheticHostEnvironment.syntheticDisplay(pointWidth: picture.width / 2, pointHeight: picture.height / 2)]
        }
        return [SyntheticHostEnvironment.syntheticDisplay()]
    }

    func resolve(_ select: SelectDisplay) async throws -> DisplayInfo {
        // The pretend display fails the way ScreenCaptureKit does while the screen is off.
        guard !display.isAsleep else { throw CaptureError.displayNotFound }
        switch select.selection {
        case .fitViewport(let viewport):
            if let picture {
                // A `--synthetic-image` display keeps the picture's shape, as a real Mac's display
                // does, so the client letterboxes or reshapes its window to it.
                return SyntheticHostEnvironment.syntheticDisplay(pointWidth: picture.width / 2, pointHeight: picture.height / 2)
            }
            return SyntheticHostEnvironment.syntheticDisplay(pointWidth: max(640, Int(viewport.widthPoints)), pointHeight: max(480, Int(viewport.heightPoints)))
        case .display:
            return SyntheticHostEnvironment.syntheticDisplay()
        }
    }

    func makeCapture(for display: DisplayInfo, fps: Int, excludingClientOnThisComputer: Bool) -> any FrameSource {
        SleepingFrameSource(source: SyntheticFrameSource(pixelWidth: display.pixelWidth, pixelHeight: display.pixelHeight, fps: fps, picture: picture),
                            display: self.display)
    }

    func restoreDisplays() async {}
}

/// A synthetic frame source that stops itself when the pretend display sleeps, as a real
/// ScreenCaptureKit stream does ("Failed to find any displays or windows to capture").
nonisolated final class SleepingFrameSource: FrameSource, @unchecked Sendable {
    private let source: SyntheticFrameSource
    private let display: FakeDisplay
    private var token: UUID?

    init(source: SyntheticFrameSource, display: FakeDisplay) {
        self.source = source
        self.display = display
    }

    var pixelWidth: Int { source.pixelWidth }
    var pixelHeight: Int { source.pixelHeight }

    func start(onFrame: @escaping @Sendable (CapturedFrame) -> Void, onStop: @escaping @Sendable ((any Error)?) -> Void) async throws {
        guard !display.isAsleep else { throw CaptureError.displayNotFound }
        try await source.start(onFrame: onFrame, onStop: onStop)
        token = display.observe { [weak self] asleep in
            guard asleep, let self else { return }
            Task {
                await self.stop()
                onStop(CaptureError.displayNotFound)
            }
        }
    }

    func updateFPS(_ fps: Int) { source.updateFPS(fps) }

    func refreshFilter() async {}

    func stop() async {
        if let token { display.removeObserver(token) }
        token = nil
        await source.stop()
    }
}

/// Keep-awake and lock do nothing; sleep and wake flip the pretend display.
nonisolated final class SyntheticPower: HostPowerControl, @unchecked Sendable {
    private let display: FakeDisplay
    private let lock = NSLock()
    private var lastWake: ContinuousClock.Instant?

    init(display: FakeDisplay) {
        self.display = display
    }

    func keepAwake() {}
    func releaseKeepAwake() {}

    @discardableResult
    func wakeDisplay(reason: String, minimumInterval: Duration) -> Bool {
        let now = ContinuousClock.now
        let allowed: Bool = lock.withLock {
            if minimumInterval > .zero, let lastWake, now - lastWake < minimumInterval { return false }
            lastWake = now
            return true
        }
        guard allowed else { return false }
        display.wake()
        return true
    }

    func sleepDisplay() { display.sleep() }
    func lockScreen() {}
    var isDisplayAsleep: Bool { display.isAsleep }
    var panel: (isOff: Bool, text: String) {
        let asleep = display.isAsleep
        return (asleep, asleep ? "pretend display asleep" : "pretend display on")
    }
}

/// Reports the pretend display's sleep state, never locked and never secure input. Changes
/// arrive from the display itself; `refresh` reports the current state.
nonisolated final class SyntheticStatusMonitor: HostStatusMonitor, @unchecked Sendable {
    private let display: FakeDisplay
    private let queue = DispatchQueue(label: "vantage.synthetic.status")
    private var token: UUID?
    private var lastAsleep: Bool
    var onChange: (@Sendable (HostStatus) -> Void)?

    init(display: FakeDisplay) {
        self.display = display
        lastAsleep = display.isAsleep
    }

    func start() {
        lastAsleep = display.isAsleep
        token = display.observe { [weak self] _ in self?.refresh() }
    }

    func stop() {
        if let token { display.removeObserver(token) }
        token = nil
    }

    func currentStatus() -> HostStatus {
        HostStatus(isScreenLocked: false, isSecureInputActive: false, inputPath: .native, isDisplayAsleep: display.isAsleep)
    }

    func refresh() {
        queue.async { [self] in
            let asleep = display.isAsleep
            guard asleep != lastAsleep else { return }
            lastAsleep = asleep
            onChange?(currentStatus())
        }
    }
}

nonisolated struct SyntheticAudio: HostAudio {
    func makeSource() -> any AudioSource { SyntheticAudioSource() }
    func message(for error: any Error) -> String { "The synthetic host's sound stopped: \(error.localizedDescription)" }
}
