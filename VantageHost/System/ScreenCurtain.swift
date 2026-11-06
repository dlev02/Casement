import AppKit
import Synchronization
import SwiftUI
import VantageCore
import os

/// The windows the picture must leave out, read wherever a capture's filter is built.
nonisolated enum CurtainWindows {
    private static let ids = Mutex<[CGWindowID]>([])
    static var current: [CGWindowID] { ids.withLock { $0 } }
    static func set(_ new: [CGWindowID]) { ids.withLock { $0 = new } }
}

/// Curtain: this Mac's panels go black and its own keyboard and mouse stop working, while the
/// picture a device receives stays the real desktop. ScreenCaptureKit leaves the black windows
/// out by window ID, and input arrives from the host at the session level, past a HID tap that
/// drops everything physical. One curtain per Mac, up while any device wants it.
///
/// It only ever comes down onto something safe. A device turning it off lifts it (that person
/// asked to see the screen); otherwise, once the last device has been gone for `reconnectGrace`,
/// the Mac locks first. ⌃⌥⌘L at the keyboard locks and lifts it for someone who is really there.
/// If the host dies, `CurtainGuard` locks the Mac.
@MainActor
final class ScreenCurtain {
    static let shared = ScreenCurtain()
    typealias Holder = ObjectIdentifier

    /// A dropped connection usually comes back within seconds (an iPad switching apps, a network
    /// change), so the Mac waits this long before it locks.
    static let reconnectGrace: Duration = .seconds(60)

    /// Capture filters need rebuilding: the curtain's windows came or went.
    var onWindowsChanged: () -> Void = {}

    private let log = Logger(subsystem: "com.benjaminlevinson.vantage.host", category: "curtain")
    private var holders: [Holder: @Sendable (CurtainStatus) -> Void] = [:]
    private var windows: [NSWindow] = []
    private var blocker: InputBlocker?
    private var guardProcess: Process?
    private var graceTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?

    var isUp: Bool { !windows.isEmpty }

    /// Returns why it couldn't be raised, or nil. Lowering never fails.
    func set(_ wanted: Bool, for holder: Holder, notify: @escaping @Sendable (CurtainStatus) -> Void) -> String? {
        guard wanted else {
            holders[holder] = nil
            if holders.isEmpty { lift() }
            return nil
        }
        graceTask?.cancel()
        graceTask = nil
        if !isUp, let problem = raise() { return problem }
        holders[holder] = notify
        return nil
    }

    /// A new session joins a curtain still up in its grace period, and can lower it.
    func adopt(_ holder: Holder, notify: @escaping @Sendable (CurtainStatus) -> Void) -> Bool {
        guard isUp else { return false }
        graceTask?.cancel()
        graceTask = nil
        holders[holder] = notify
        return true
    }

    func sessionEnded(_ holder: Holder) {
        guard holders.removeValue(forKey: holder) != nil, holders.isEmpty, isUp else { return }
        graceTask?.cancel()
        graceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.reconnectGrace)
            guard !Task.isCancelled else { return }
            self?.log.info("no device came back; locking this Mac and lifting the curtain")
            self?.lockThenLift()
        }
    }

    /// The host is quitting: nothing may be left showing the desktop.
    func hostWillQuit() {
        guard isUp else { return }
        HostCommandRunner.lockScreen()
        Thread.sleep(forTimeInterval: 0.5) // the lock screen is up before the windows go
        lift()
    }

    /// Someone at the keyboard pressed ⌃⌥⌘L.
    fileprivate func localEscape() {
        guard isUp else { return }
        log.info("⌃⌥⌘L at this Mac: locking and lifting the curtain")
        lockThenLift()
    }

    private func lockThenLift() {
        graceTask?.cancel()
        graceTask = nil
        let notifiers = holders.values
        holders.removeAll()
        HostCommandRunner.lockScreen()
        Task {
            try? await Task.sleep(for: .seconds(1)) // the lock screen is up before the windows go
            if holders.isEmpty { lift() } // a device that just asked for it keeps it, over the lock screen
            for notify in notifiers { notify(CurtainStatus(isUp: false)) }
        }
    }

    private func raise() -> String? {
        guard let blocker = InputBlocker(onEscape: { Task { @MainActor in ScreenCurtain.shared.localEscape() } }) else {
            log.error("couldn't install the input tap (Accessibility)")
            return "Casement Host needs Accessibility permission to keep this Mac's keyboard and mouse out."
        }
        self.blocker = blocker
        guardProcess = CurtainGuard.start()
        buildWindows()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in ScreenCurtain.shared.buildWindows() }
        }
        log.info("curtain up on \(self.windows.count) display(s)")
        return nil
    }

    private func lift() {
        guard isUp else { return }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        windows.forEach { $0.orderOut(nil) }
        windows = []
        CurtainWindows.set([])
        blocker?.stop()
        blocker = nil
        guardProcess?.terminate()
        guardProcess = nil
        onWindowsChanged()
        log.info("curtain down")
    }

    private func buildWindows() {
        let old = windows
        windows = NSScreen.screens.map(Self.window(for:))
        old.forEach { $0.orderOut(nil) } // the new ones are up first, so nothing shows in between
        CurtainWindows.set(windows.map { CGWindowID($0.windowNumber) })
        onWindowsChanged()
    }

    private static func window(for screen: NSScreen) -> NSWindow {
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = true // the host's own clicks go through to what's underneath
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: CurtainContent())
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        return window
    }
}

private struct CurtainContent: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill").font(.system(size: 28))
            Text("This Mac is in use remotely").font(.title3)
            Text("To use it here, press ⌃⌥⌘L and sign in").font(.callout)
        }
        .foregroundStyle(.white.opacity(0.45))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
    }
}

/// Drops physical input while the curtain is up, on a thread of its own so a busy main thread
/// never makes the system time the tap out. Physical events reach the HID tap first; the host
/// posts at the session tap, after it, so its own input never passes through here (and carries
/// `injectedEventMarker` in any case).
nonisolated private final class InputBlocker: @unchecked Sendable {
    private var tap: CFMachPort?
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    fileprivate let onEscape: @Sendable () -> Void

    init?(onEscape: @escaping @Sendable () -> Void) {
        self.onEscape = onEscape
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask.max, callback: inputBlockerCallback, userInfo: context) else { return nil }
        self.tap = tap
        let started = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            started.signal()
            CFRunLoopRun()
        }
        thread.name = "vantage.curtain.input"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread
        started.wait()
    }

    /// Physical input works again from here. Not a `deinit`: the thread keeps this object alive
    /// until its run loop stops, so a `deinit` would never come and input would stay blocked.
    func stop() {
        guard let tap else { return }
        self.tap = nil
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        if let runLoop { CFRunLoopStop(runLoop) }
    }

    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }
}

nonisolated private func inputBlockerCallback(_: CGEventTapProxy, type: CGEventType, event: CGEvent, info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let info else { return Unmanaged.passUnretained(event) }
    let blocker = Unmanaged<InputBlocker>.fromOpaque(info).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        blocker.reenable()
        return Unmanaged.passUnretained(event)
    }
    if event.getIntegerValueField(.eventSourceUserData) == VantageProtocol.injectedEventMarker {
        return Unmanaged.passUnretained(event)
    }
    if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 0x25, // L
       event.flags.isSuperset(of: [.maskControl, .maskAlternate, .maskCommand]) {
        blocker.onEscape()
    }
    return nil
}

/// A second copy of the host that does one thing: if the host dies with the curtain up, its
/// windows and input tap die with it and the desktop would show, so this locks the Mac instead.
/// The host stops it when the curtain comes down normally.
nonisolated enum CurtainGuard {
    private static let flag = "--curtain-guard"

    /// Doesn't return when this process is the guard.
    static func runIfAsked() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: flag), index + 1 < args.count, let host = pid_t(args[index + 1]) else { return }
        let source = DispatchSource.makeProcessSource(identifier: host, eventMask: .exit, queue: .main)
        source.setEventHandler {
            HostCommandRunner.lockScreen()
            exit(0)
        }
        source.resume()
        if kill(host, 0) != 0 {
            HostCommandRunner.lockScreen()
            exit(0)
        }
        dispatchMain()
    }

    static func start() -> Process? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = [flag, String(getpid())]
        do {
            try process.run()
            return process
        } catch {
            Logger(subsystem: "com.benjaminlevinson.vantage.host", category: "curtain").error("couldn't start the guard: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
