import LocalAuthentication
import SwiftUI

/// Gates the app behind biometric authentication when enabled.
@MainActor
@Observable
final class AppLock {
    var isLocked: Bool
    private let enabled: Bool

    init() {
        enabled = UserDefaults.standard.bool(forKey: "vantage.requireBiometrics")
        isLocked = enabled
    }

    func authenticate() {
        guard isLocked else { return }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            isLocked = false
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Vantage") { success, _ in
            Task { @MainActor in self.isLocked = !success }
        }
    }

    func lockIfNeeded() {
        if UserDefaults.standard.bool(forKey: "vantage.requireBiometrics") {
            isLocked = true
        }
    }
}
