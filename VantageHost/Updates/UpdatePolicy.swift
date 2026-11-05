import Foundation

/// What might be going on while an update waits to install (`UpdatePolicy`).
nonisolated struct UpdateActivity: Equatable, Sendable {
    /// Sessions and file channels open now.
    var connections = 0
    /// Files waiting, moving or paused.
    var activeTransfers = 0
    /// A pairing code is up: someone is about to connect.
    var showingPairingCode = false
    /// The menu, Settings or the setup window is on screen.
    var windowOpen = false

    /// Nothing above is going on right now, however briefly.
    var isClear: Bool { connections == 0 && activeTransfers == 0 && !showingPairingCode && !windowOpen }
}

/// When to check and when an unattended install may restart the host. The same rules as the
/// Windows host's `UpdatePolicy`.
nonisolated enum UpdatePolicy {
    /// How often the background check runs.
    static let checkInterval: TimeInterval = 24 * 60 * 60
    /// The first check waits this long after launch, so logging in isn't slowed by it.
    static let firstCheckDelay: TimeInterval = 2 * 60
    /// A failed check is tried again after this long, not at the next day's check.
    static let retryAfterFailure: TimeInterval = 60 * 60
    /// A device that just dropped is usually reconnecting (a network change, a sleeping iPad), so
    /// an install waits for this much quiet rather than taking the host away as it comes back.
    static let quietBeforeInstall: TimeInterval = 5 * 60

    /// Whether a background check is due. Install Updates Automatically off means no background
    /// network at all. A last check in the future (the clock moved) counts as due.
    static func shouldCheck(automatic: Bool, sinceLaunch: TimeInterval, lastCheck: Date?, now: Date) -> Bool {
        guard automatic, sinceLaunch >= firstCheckDelay else { return false }
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= checkInterval || lastCheck > now
    }

    /// Whether a ready update may restart the host unasked.
    static func mayInstallUnattended(automatic: Bool, activity: UpdateActivity, quietFor: TimeInterval) -> Bool {
        automatic && activity.isClear && quietFor >= quietBeforeInstall
    }

    /// Whether this copy can swap itself for a new one without asking for a password. A copy that
    /// can't (translocated, on a disk image, in a folder this user can't write to) is sent to the
    /// download page instead.
    static func canReplaceItself(bundlePath: String, parentIsWritable: Bool, bundleIsWritable: Bool, volumeIsReadOnly: Bool) -> Bool {
        !bundlePath.contains("/AppTranslocation/") && !volumeIsReadOnly && parentIsWritable && bundleIsWritable
    }
}
