import CoreGraphics
import Darwin
import Foundation
import ImageIO
import VantageCore
import os

/// The stand-ins a synthetic host (`--synthetic-capture`) runs on: a pretend display that sleeps
/// and wakes on command, a rendered test pattern (or `--synthetic-image`), a chime for sound, no
/// input, clipboard, curtain, dictation or tailnet, an identity in a key file of its own rather
/// than the Keychain, and nothing that touches the real Mac's displays, keyboard or permissions.
/// Tests build one with a fake clock and a temp folder.
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

    /// Where a synthetic host keeps what is its own (its identity), beside the real host's folder
    /// but never in it: `~/Library/Application Support/Vantage Host/Synthetic`.
    static var stateDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        return support.appending(path: "Vantage Host/Synthetic", directoryHint: .isDirectory)
    }

    /// The synthetic host's identity: a key file private to the user (0600) in `stateDirectory`,
    /// never the login Keychain, so an unsigned build raises no Keychain prompt (and can't hang
    /// on one), and the same key on every launch, so a device that saved this host keeps matching
    /// it. Several synthetic hosts launched together (the UI tests start a few) take turns through
    /// a lock file beside it, and the key is written to a temporary file and linked into place, so
    /// they all come up with the one identity and no launch overwrites another's. An existing file
    /// is checked before it is trusted: a regular file of the user's, 32 bytes, mode 0600 (a mode
    /// that drifted is put back; anything else is replaced, and the log says which). A file that
    /// can't be read or written means a fresh identity for this launch.
    static func loadOrCreateIdentity(in directory: URL = stateDirectory) -> DeviceIdentity {
        let log = Logger(subsystem: "com.benjaminlevinson.vantage.host", category: "controller")
        let file = directory.appending(path: "device-identity")
        let path = file.path(percentEncoded: false)
        do {
            // The folder is the user's alone (0700) before the key is written into it (0600).
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            log.error("couldn't make the synthetic host's folder \(directory.path(percentEncoded: false), privacy: .public): \(error.localizedDescription, privacy: .public); using a new identity this launch")
            return DeviceIdentity()
        }
        // One launch at a time from here: the lock is released with the descriptor.
        let lock = open(directory.appending(path: "device-identity.lock").path(percentEncoded: false), O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        if lock < 0 || flock(lock, LOCK_EX) != 0 {
            log.error("couldn't take the synthetic identity lock (errno \(errno, privacy: .public)); going on without it")
        }
        defer { if lock >= 0 { close(lock) } }
        if let identity = existingIdentity(at: path, log: log) { return identity }
        let identity = DeviceIdentity()
        do {
            if let winner = try keep(identity, at: path, in: directory) {
                log.info("synthetic identity \(winner.fingerprint, privacy: .public) was written by another launch meanwhile; using it")
                return winner
            }
            log.info("synthetic identity \(identity.fingerprint, privacy: .public) written to \(path, privacy: .public)")
        } catch {
            log.error("couldn't keep the synthetic identity at \(path, privacy: .public): \(error.localizedDescription, privacy: .public); using a new one this launch")
        }
        return identity
    }

    /// The identity in an existing key file that passes its checks, after a drifted mode is put
    /// back. Nil when there is none, or when the file is replaced because it isn't a regular file
    /// of this user's with a key's length, or doesn't decode.
    private static func existingIdentity(at path: String, log: Logger) -> DeviceIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let problem: String?
        if info.st_mode & S_IFMT != S_IFREG {
            problem = "not a regular file"
        } else if info.st_uid != getuid() {
            problem = "owned by uid \(info.st_uid)"
        } else if info.st_size != Self.identityLength {
            problem = "\(info.st_size) bytes, not \(Self.identityLength)"
        } else {
            problem = nil
        }
        if let problem {
            log.error("synthetic identity file \(path, privacy: .public) is \(problem, privacy: .public); replacing it")
            unlink(path)
            return nil
        }
        if info.st_mode & 0o777 != 0o600 {
            if chmod(path, 0o600) == 0 {
                log.error("synthetic identity file \(path, privacy: .public) had mode \(String(info.st_mode & 0o777, radix: 8), privacy: .public); set back to 600")
            } else {
                log.error("synthetic identity file \(path, privacy: .public) has mode \(String(info.st_mode & 0o777, radix: 8), privacy: .public) and chmod failed (errno \(errno, privacy: .public)); replacing it")
                unlink(path)
                return nil
            }
        }
        guard let raw = FileManager.default.contents(atPath: path), let identity = try? DeviceIdentity(rawRepresentation: raw) else {
            log.error("synthetic identity file \(path, privacy: .public) doesn't hold a key; replacing it")
            unlink(path)
            return nil
        }
        return identity
    }

    /// A Curve25519 private key's raw bytes.
    private static let identityLength: off_t = 32

    /// The identity in a key file that needs no repair: a regular file of this user's, mode 600,
    /// a key's length, that decodes. Nothing is changed.
    private static func soundIdentity(at path: String) -> DeviceIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o777 == 0o600, info.st_size == identityLength,
              let raw = FileManager.default.contents(atPath: path) else { return nil }
        return try? DeviceIdentity(rawRepresentation: raw)
    }

    /// Writes the key to a private temporary file and links it into place, so the key file is
    /// never seen half-written and never overwrites one another launch got there with first; in
    /// that case this returns the winner's identity instead.
    private static func keep(_ identity: DeviceIdentity, at path: String, in directory: URL) throws -> DeviceIdentity? {
        let temp = directory.appending(path: "device-identity.\(getpid()).tmp").path(percentEncoded: false)
        unlink(temp) // a launch that died mid-write
        let fd = open(temp, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO) }
        defer { unlink(temp) }
        let written: Bool = identity.rawRepresentation.withUnsafeBytes { bytes in
            Darwin.write(fd, bytes.baseAddress, bytes.count) == bytes.count && fsync(fd) == 0
        }
        let writeErrno = errno
        close(fd)
        guard written else { throw POSIXError(POSIXError.Code(rawValue: writeErrno) ?? .EIO) }
        guard link(temp, path) == 0 else {
            let linkErrno = errno
            // Another launch got there first, or a file that failed its checks couldn't be removed:
            // only a file that passes them as it stands is a winner.
            if linkErrno == EEXIST, let winner = soundIdentity(at: path) { return winner }
            throw POSIXError(POSIXError.Code(rawValue: linkErrno) ?? .EIO)
        }
        return nil
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
