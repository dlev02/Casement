import CoreGraphics
import Foundation
import IOKit.pwr_mgt
import IOKit.ps
import os

/// Holds a display-sleep-prevention assertion while a client session is active, and wakes the
/// display when the client needs it: at connect, on the Wake command, and on input while it's
/// asleep. Thread-safe: the session actor and the input path both call in.
nonisolated final class PowerManager: @unchecked Sendable {
    private let log = Logger(subsystem: "com.benjaminlevinson.vantage.host", category: "power")
    private let lock = NSLock()
    private var assertionID: IOPMAssertionID = 0
    private var active = false
    /// The one user-activity assertion this session re-declares. IOPMLib.h asks callers to pass
    /// the returned id back each time; a fresh id per call leaked an assertion every time.
    private var activityID: IOPMAssertionID = 0
    private var lastWake: ContinuousClock.Instant?

    func begin(reason: String = "Casement remote session active") {
        lock.lock(); defer { lock.unlock() }
        guard !active else { return }
        var id: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        if status == kIOReturnSuccess {
            assertionID = id
            active = true
            log.info("display-sleep assertion held")
        } else {
            log.error("failed to create power assertion: \(status)")
        }
    }

    /// Turns the display on (a no-op when it's already on) by declaring user activity, as a
    /// key press on the Mac would. `minimumInterval` limits how often input can do this: the
    /// call is an IPC to powerd, and once a second is plenty.
    @discardableResult
    func wakeDisplay(reason: String, minimumInterval: Duration = .zero) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = ContinuousClock.now
        if minimumInterval > .zero, let lastWake, now - lastWake < minimumInterval { return false }
        lastWake = now
        if DisplayPower.fake.isEnabled {
            DisplayPower.fake.wake()
        } else {
            // Local and Remote both light a sleeping display on macOS 27 (checked with
            // `pmset displaysleepnow`); Local is what a key press on the Mac itself declares.
            let status = IOPMAssertionDeclareUserActivity("Casement remote input" as CFString, kIOPMUserActiveLocal, &activityID)
            if status != kIOReturnSuccess { log.error("declaring user activity failed: \(status)") }
        }
        log.info("waking the display (\(reason, privacy: .public))")
        return true
    }

    func end() {
        lock.lock(); defer { lock.unlock() }
        if activityID != 0 {
            IOPMAssertionRelease(activityID)
            activityID = 0
        }
        guard active else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        active = false
        log.info("display-sleep assertion released")
    }

    /// True when the Mac is running on AC power (informs "stay available while plugged in").
    static func isOnACPower() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return true
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  let state = description[kIOPSPowerSourceStateKey] as? String else { continue }
            if state == kIOPSACPowerValue { return true }
        }
        return false
    }
}

/// Whether the Mac's display is asleep. While it is, ScreenCaptureKit lists no displays and any
/// running stream stops ("Failed to find any displays or windows to capture"), so capture can
/// only come back after a wake.
nonisolated enum DisplayPower {
    static func isAsleep() -> Bool {
        if fake.isEnabled { return fake.isAsleep }
        return CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    /// Whether any panel is actually lit: CGDisplayIsAsleep plus the active display list (empty
    /// while every display is off). IOKit has no display power state to read on Apple silicon
    /// (IODisplayWrangler carries no power properties there), so these are the signals.
    static func panelDescription() -> (isOff: Bool, text: String) {
        if fake.isEnabled { return (fake.isAsleep, fake.isAsleep ? "pretend display asleep" : "pretend display on") }
        var active: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &active)
        let asleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
        return (asleep || active == 0, "main display \(asleep ? "asleep" : "on"), \(active) active")
    }

    /// `pmset displaysleepnow`, like the Mac's own "Sleep display" (or the pretend display).
    static func sleepNow() {
        if fake.isEnabled {
            fake.sleep()
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["displaysleepnow"]
        try? task.run()
    }

    /// DEBUG `--display-asleep`: a pretend display that starts asleep, for synthetic hosts and
    /// tests. Sleep and wake flip it the way they would a real one.
    static let fake = FakeDisplay(enabled: HostOptions.shared.fakeDisplaySleep)

    final class FakeDisplay: @unchecked Sendable {
        let isEnabled: Bool
        private let lock = NSLock()
        private var asleep: Bool

        init(enabled: Bool) {
            isEnabled = enabled
            asleep = enabled
        }

        var isAsleep: Bool { lock.withLock { asleep } }
        func sleep() { lock.withLock { asleep = true } }
        func wake() { lock.withLock { asleep = false } }
    }
}
