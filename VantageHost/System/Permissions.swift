import AppKit

/// The two privacy permissions the host needs, where System Settings keeps each one, and what to
/// say when macOS still says no after the user turned the switch on.
///
/// Both are checked live (`CGPreflightScreenCaptureAccess`, `AXIsProcessTrusted`) every time the
/// controller refreshes; nothing is cached from launch.
///
/// A switch that looks on but doesn't count is almost always a stale entry: macOS keys the grant
/// to the code signature, so an earlier copy of the app with the same bundle id (a Debug build, a
/// different team) leaves a row named Casement Host whose switch belongs to that other signature.
/// Removing the row with − and adding the app again with + (or allowing it again) records the
/// running copy. The app never runs `tccutil` itself.
enum HostPermission {
    case screenRecording
    case accessibility

    /// System Settings › Privacy & Security, on this permission's list.
    var settingsURL: URL {
        switch self {
        case .screenRecording: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        case .accessibility: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        }
    }

    func openSettings() {
        NSWorkspace.shared.open(settingsURL)
    }

    /// Shown once the user has asked for a permission and macOS still reports it missing.
    static let staleEntryHelp = "If Casement Host is already on in the list, remove it with the − button and add it again."
    /// The same, short enough for a menu row.
    static let staleEntryHelpShort = "Already on? Remove it with − and add it again."
}
