import LocalAuthentication
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Gates the app behind biometric authentication when enabled.
@MainActor
@Observable
final class AppLock {
    #if os(visionOS) || os(macOS)
    /// visionOS and Mac sessions live in their own windows and share the list's lock.
    static let shared = AppLock()
    #endif

    var isLocked: Bool
    var errorMessage: String?
    private var isAuthenticating = false
    #if os(macOS)
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    #endif

    init() {
        isLocked = UserDefaults.standard.bool(forKey: Self.settingKey)
        #if os(macOS)
        watchThisMac()
        #endif
    }

    /// Settings → Privacy & Security → Require Face ID / Touch ID.
    static let settingKey = "vantage.requireBiometrics"

    func authenticate() {
        guard isLocked, !isAuthenticating else { return }
        errorMessage = nil
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            errorMessage = "Device authentication is unavailable. Set up a device passcode or biometrics, then try again."
            return
        }
        isAuthenticating = true
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Casement") { success, _ in
            Task { @MainActor in
                self.isAuthenticating = false
                self.isLocked = !success
            }
        }
    }

    func lockIfNeeded() {
        if UserDefaults.standard.bool(forKey: Self.settingKey) {
            isLocked = true
        }
    }

    #if os(macOS)
    /// A Mac app is rarely "in the background" the way an iPad app is: windows sit behind others
    /// all day. So the Mac locks when the Mac itself does — its screen locks, its displays sleep,
    /// or it goes to sleep — and asks again when you're back and Vantage is in front. Sessions stay
    /// connected behind the lock.
    private func watchThisMac() {
        let lock: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.lockIfNeeded() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers = [
            DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main, using: lock),
            workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main, using: lock),
            workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: lock),
            workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main, using: lock),
            // Back at the Mac: ask straight away if Vantage is the app in front, otherwise when it
            // comes forward.
            DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in if NSApp.isActive { self?.authenticate() } }
            },
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.authenticate() }
            },
        ]
    }
    #endif
}

/// What covers Vantage while it's locked.
struct LockOverlay: View {
    let errorMessage: String?
    let onUnlock: () -> Void
    var body: some View {
        ZStack {
            // Opaque, not a material: whatever sits under the lock must not show through.
            Rectangle().fill(.background).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock.fill").font(.largeTitle)
                Text("Casement is locked").font(.headline)
                if let errorMessage {
                    Text(errorMessage).font(.callout).multilineTextAlignment(.center).padding(.horizontal)
                }
                Button("Unlock", action: onUnlock)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        #if os(macOS)
        // Swallows clicks and scrolls meant for whatever is underneath, a session included.
        .contentShape(.rect)
        .onTapGesture {}
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal) // nothing behind the lock is reachable
        .accessibilityIdentifier("appLock")
    }
}

extension View {
    /// On the Mac, covers this window (or sheet) while Vantage is locked. The views stay alive
    /// underneath, so sessions stay connected and a half-filled sheet keeps what was typed;
    /// swapping the view out instead would disconnect them. Elsewhere nothing: iOS raises a
    /// window of its own over everything, and visionOS swaps the view.
    @ViewBuilder func appLockCurtain() -> some View {
        #if os(macOS)
        modifier(MacLockCurtain())
        #else
        self
        #endif
    }
}

#if os(macOS)
private struct MacLockCurtain: ViewModifier {
    private let lock = AppLock.shared

    func body(content: Content) -> some View {
        content
            // The lock covers the window; VoiceOver mustn't read what's under it either.
            .accessibilityHidden(lock.isLocked)
            .overlay {
                if lock.isLocked {
                    LockOverlay(errorMessage: lock.errorMessage) { lock.authenticate() }
                }
            }
    }
}
#endif
