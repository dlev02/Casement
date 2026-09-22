import LocalAuthentication
import SwiftUI

/// Gates the app behind biometric authentication when enabled.
@MainActor
@Observable
final class AppLock {
    var isLocked: Bool
    var errorMessage: String?
    private var isAuthenticating = false

    init() {
        isLocked = UserDefaults.standard.bool(forKey: "vantage.requireBiometrics")
    }

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
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Vantage") { success, _ in
            Task { @MainActor in
                self.isAuthenticating = false
                self.isLocked = !success
            }
        }
    }

    func lockIfNeeded() {
        if UserDefaults.standard.bool(forKey: "vantage.requireBiometrics") {
            isLocked = true
        }
    }
}
