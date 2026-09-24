import AppKit
import Carbon.HIToolbox
import Foundation
import VantageCore

/// Tracks whether the Mac's screen is locked, whether Secure Event Input is active (a password
/// field is focused), and whether the display is asleep, so the host can tell the client when
/// typing will be silently dropped or there's no picture to show.
nonisolated final class LockMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "vantage.lockmonitor")
    private var timer: DispatchSourceTimer?
    private var tokens: [any NSObjectProtocol] = []
    private var workspaceTokens: [any NSObjectProtocol] = []
    private var locked = false
    private var lastSecure = false
    private var lastAsleep = false
    var onChange: (@Sendable (HostStatus) -> Void)?

    func start() {
        queue.sync {
            lastSecure = IsSecureEventInputEnabled()
            lastAsleep = DisplayPower.isAsleep()
        }
        let center = DistributedNotificationCenter.default()
        tokens.append(center.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: nil) { [weak self] _ in
            self?.set(locked: true)
        })
        tokens.append(center.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: nil) { [weak self] _ in
            self?.set(locked: false)
        })
        // Display sleep has notifications; the poll below also catches a change they miss.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification] {
            workspaceTokens.append(workspace.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.queue.async { self?.emit() }
            })
        }
        // Poll secure-input state (no notification exists for it).
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.emit() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        let center = DistributedNotificationCenter.default()
        tokens.forEach { center.removeObserver($0) }
        tokens.removeAll()
        workspaceTokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceTokens.removeAll()
    }

    func currentStatus() -> HostStatus {
        queue.sync { status(secure: IsSecureEventInputEnabled(), asleep: DisplayPower.isAsleep()) }
    }

    /// Checks again now (after a sleep or wake command) instead of waiting for the next tick.
    func refresh() {
        queue.async { self.emit() }
    }

    private func status(secure: Bool, asleep: Bool) -> HostStatus {
        var message: String?
        if locked { message = "The Mac is locked" }
        else if secure { message = "A secure text field is focused; typing is blocked" }
        return HostStatus(isScreenLocked: locked, isSecureInputActive: secure, inputPath: .native, message: message,
                          isDisplayAsleep: asleep)
    }

    private func emit() {
        let secure = IsSecureEventInputEnabled()
        let asleep = DisplayPower.isAsleep()
        guard secure != lastSecure || asleep != lastAsleep else { return }
        lastSecure = secure
        lastAsleep = asleep
        onChange?(status(secure: secure, asleep: asleep))
    }

    private func set(locked: Bool) {
        queue.async {
            guard self.locked != locked else { return }
            self.locked = locked
            self.lastSecure = IsSecureEventInputEnabled()
            self.lastAsleep = DisplayPower.isAsleep()
            self.onChange?(self.status(secure: self.lastSecure, asleep: self.lastAsleep))
        }
    }
}
