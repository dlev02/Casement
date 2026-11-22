import Foundation
import LocalAuthentication

/// Face ID, Touch ID or Optic ID (or the device passcode) before a saved password is typed on a
/// computer: the key button, Unlock and Approve in a session, and Log In from the list. On
/// unless turned off (Settings → Privacy & Security), wherever the device can check who's holding
/// it; a device with no passcode has nothing to ask with, and types straight away.
enum PasswordConfirmation {
    static let settingKey = "vantage.confirmPasswordTyping"

    enum Outcome: Equatable {
        case confirmed
        /// Cancelled, or the person chose not to: nothing to say.
        case cancelled
        case failed(String)
    }

    static var isRequired: Bool { UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true }

    /// A prompt will appear before typing.
    static var willAsk: Bool {
        guard isRequired else { return false }
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    /// "Face ID", "Touch ID" or "Optic ID"; nil where only the passcode (or nothing) can be asked.
    static let biometryName: String? = {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { return nil }
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return nil
        }
    }()

    /// Asks, unless it's off or the device can't; `reason` shows under Touch ID and the passcode.
    static func confirm(_ reason: String) async -> Outcome {
        #if DEBUG
        if ClientOptions.skipsPasswordConfirmation { return .confirmed }
        #endif
        guard isRequired else { return .confirmed }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return .confirmed }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) ? .confirmed : .cancelled
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .appCancel, .systemCancel, .userFallback: return .cancelled
            default: return .failed(error.localizedDescription)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
