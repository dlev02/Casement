import AppKit
import Carbon.HIToolbox
import Foundation
import VantageCore

/// Tracks whether the Mac's screen is locked and whether Secure Event Input is active (a password
/// field is focused), so the host can tell the client when typing will be silently dropped.
nonisolated final class LockMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "vantage.lockmonitor")
    private var timer: DispatchSourceTimer?
    private var tokens: [any NSObjectProtocol] = []
    private var locked = false
    var onChange: (@Sendable (HostStatus) -> Void)?

    func start() {
        let center = DistributedNotificationCenter.default()
        tokens.append(center.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: nil) { [weak self] _ in
            self?.set(locked: true)
        })
        tokens.append(center.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: nil) { [weak self] _ in
            self?.set(locked: false)
        })
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
    }

    func currentStatus() -> HostStatus {
        let secure = IsSecureEventInputEnabled()
        var message: String?
        if locked { message = "The Mac is locked" }
        else if secure { message = "A secure text field is focused; typing is blocked" }
        return HostStatus(isScreenLocked: locked, isSecureInputActive: secure, inputPath: .native, message: message)
    }

    private var lastSecure = false
    private func emit() {
        let secure = IsSecureEventInputEnabled()
        if secure != lastSecure {
            lastSecure = secure
            onChange?(currentStatus())
        }
    }

    private func set(locked: Bool) {
        queue.async {
            guard self.locked != locked else { return }
            self.locked = locked
            self.onChange?(self.currentStatus())
        }
    }
}
