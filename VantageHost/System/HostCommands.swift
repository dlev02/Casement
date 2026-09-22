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

    static func sleepDisplay() {
        // Public path: put the display to sleep.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["displaysleepnow"]
        try? task.run()
    }
}
