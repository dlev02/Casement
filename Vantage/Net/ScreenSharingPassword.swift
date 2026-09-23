import Foundation
import VantageCore

/// Types a Mac's saved password through the Mac's own Screen Sharing server.
///
/// Vantage Host types with CGEvent, which macOS drops while a password field, an authentication
/// dialog, or the lock screen holds Secure Event Input. Apple's screensharingd is exempt, so for
/// those moments the iPad signs in to it directly over Tailscale (port 5900) with the saved account
/// name and password, sends the keystrokes, and disconnects. It works even when Vantage Host isn't
/// running, as long as Screen Sharing or Remote Management is on for that account.
enum ScreenSharingPassword {
    static func type(for device: SavedDevice) async throws {
        guard let password = DeviceSecrets.password(for: device),
              let username = DeviceSecrets.username(for: device)
        else { throw ScreenSharingTyper.TypeError.authenticationFailed("missing credentials") }
        try await ScreenSharingTyper.type(password, pressReturn: true, host: device.host,
                                          username: username, password: password)
    }

    static func canLogIn(_ device: SavedDevice) -> Bool {
        DeviceSecrets.password(for: device) != nil && DeviceSecrets.username(for: device) != nil
    }

    /// Types the password at the Mac's login or lock screen without a Vantage session. Tries the
    /// Tailscale address first, then the home-network address, which is the only one that answers
    /// while the Mac sits at the login window (its Tailscale starts only after someone logs in).
    static func logIn(to device: SavedDevice) async throws {
        guard let password = DeviceSecrets.password(for: device),
              let username = DeviceSecrets.username(for: device)
        else { throw ScreenSharingTyper.TypeError.authenticationFailed("missing credentials") }
        let home = device.homeAddress?.trimmingCharacters(in: .whitespaces) ?? ""
        let addresses = [device.host] + (home.isEmpty || home == device.host ? [] : [home])
        var lastError: any Error = ScreenSharingTyper.TypeError.unreachable("no address")
        for address in addresses {
            do {
                try await ScreenSharingTyper.type(password, pressReturn: true, host: address,
                                                  username: username, password: password, timeout: .seconds(10))
                return
            } catch let error as ScreenSharingTyper.TypeError {
                lastError = error
                // Only an unreachable address is worth retrying elsewhere; a rejected password isn't.
                switch error {
                case .unreachable, .timedOut, .notScreenSharing: continue
                default: throw error
                }
            }
        }
        throw lastError
    }

    static func message(for error: any Error) -> String {
        guard let error = error as? ScreenSharingTyper.TypeError else {
            return "Screen Sharing couldn't type the password: \(error.localizedDescription)"
        }
        switch error {
        case .unreachable, .notScreenSharing:
            return "Couldn't reach Screen Sharing on this Mac. On the Mac, turn on Screen Sharing in System Settings → General → Sharing and allow your account. At the login window the Mac is only reachable at its home network address, through a Tailscale subnet router."
        case .unsupportedAuthentication:
            return "Screen Sharing on this Mac isn't set up to accept an account name and password. In System Settings → General → Sharing → Screen Sharing, allow access for your account."
        case .authenticationFailed:
            return "The Mac didn't accept the saved account name or password. Check both in this Mac's settings in Vantage."
        case .timedOut:
            return "Screen Sharing on the Mac didn't answer in time. Try again in a moment."
        case .protocolError(let detail):
            return "Screen Sharing answered in a way Vantage didn't expect (\(detail))."
        }
    }
}
