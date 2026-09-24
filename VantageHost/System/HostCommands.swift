import CoreGraphics
import Foundation
import os

/// Executes privileged host commands (lock screen, display sleep/wake).
nonisolated enum HostCommandRunner {
    private static let log = Logger(subsystem: "com.benjaminlevinson.vantage.host", category: "commands")

    /// Locks the Mac immediately via the private but stable login.framework entry point.
    static func lockScreen() {
        typealias LockFn = @convention(c) () -> Int32
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW) else {
            log.error("could not open login.framework")
            return
        }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "SACLockScreenImmediate") else {
            log.error("SACLockScreenImmediate not found")
            return
        }
        let lock = unsafeBitCast(symbol, to: LockFn.self)
        _ = lock()
    }

    /// Puts the display to sleep (`pmset displaysleepnow`). The session stays up: capture stops
    /// while the display is off and comes back when something wakes it.
    static func sleepDisplay() {
        DisplayPower.sleepNow()
    }
}
