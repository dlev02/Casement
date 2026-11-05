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

    /// A Mac with a saved account name and password. A PC has neither Screen Sharing nor a
    /// saved password.
    static func canLogIn(_ device: SavedDevice) -> Bool {
        device.platform != .windows
            && DeviceSecrets.password(for: device) != nil && DeviceSecrets.username(for: device) != nil
    }

    /// The Mac didn't answer at its Tailscale address, and it has a home-network address to try.
    /// Thrown instead of trying it: the home address is a plain LAN address, so away from home
    /// whatever answers there would receive the password. The person decides.
    struct HomeAddressAvailable: Error {
        let address: String
    }

    /// Types the password at the Mac's login or lock screen without a Vantage session, at its
    /// Tailscale address. While the Mac sits at the login window its Tailscale isn't running yet,
    /// so only the home-network address answers (through a Tailscale subnet router): when that
    /// address is saved, an unreachable Mac throws `HomeAddressAvailable`, and the caller asks
    /// before calling again with `atHomeAddress: true`.
    static func logIn(to device: SavedDevice, atHomeAddress: Bool = false) async throws {
        guard let password = DeviceSecrets.password(for: device),
              let username = DeviceSecrets.username(for: device)
        else { throw ScreenSharingTyper.TypeError.authenticationFailed("missing credentials") }
        let home = homeAddress(of: device)
        if atHomeAddress {
            guard let home else { throw ScreenSharingTyper.TypeError.unreachable("no home address") }
            try await ScreenSharingTyper.type(password, pressReturn: true, host: home,
                                              username: username, password: password, timeout: .seconds(10))
            return
        }
        do {
            try await ScreenSharingTyper.type(password, pressReturn: true, host: device.host,
                                              username: username, password: password, timeout: .seconds(10))
        } catch let error as ScreenSharingTyper.TypeError {
            // Only an unreachable Mac is worth trying elsewhere; a rejected password isn't.
            switch error {
            case .unreachable, .timedOut, .notScreenSharing:
                if let home { throw HomeAddressAvailable(address: home) }
                throw error
            default: throw error
            }
        }
    }

    /// The saved home-network address, when it's one worth trying besides the Tailscale address.
    static func homeAddress(of device: SavedDevice) -> String? {
        let home = device.homeAddress?.trimmingCharacters(in: .whitespaces) ?? ""
        return home.isEmpty || home == device.host ? nil : home
    }

    static func message(for error: any Error) -> String {
        guard let error = error as? ScreenSharingTyper.TypeError else {
            return "Screen Sharing couldn't type the password: \(error.localizedDescription)"
        }
        switch error {
        case .unreachable, .notScreenSharing:
            return "Couldn't reach Screen Sharing on the Mac. There, turn on Screen Sharing in System Settings → General → Sharing and allow your account. At the login window the Mac is only reachable at its home network address, through a Tailscale subnet router."
        case .unsupportedAuthentication:
            return "Screen Sharing on the Mac isn't set up to accept an account name and password. In System Settings → General → Sharing → Screen Sharing, allow access for your account."
        case .authenticationFailed:
            return "The Mac didn't accept the saved account name or password. Check both in its settings in Casement (Edit)."
        case .timedOut:
            return "Screen Sharing on the Mac didn't answer in time. Try again in a moment."
        case .protocolError(let detail):
            return "Screen Sharing answered in a way Casement didn't expect (\(detail))."
        }
    }
}
