import Foundation

/// How the app names the device it runs on in user-facing text ("this iPad", "this Mac"). The
/// remote computer is always "the Mac"; on the Mac client both are Macs, so the local one is
/// "this Mac".
nonisolated enum LocalDevice {
    #if os(macOS)
    static let noun = "Mac"
    static let symbol = "desktopcomputer"
    static let settingsApp = "System Settings"
    /// How a control is pressed here, for sentences like "Click anywhere to wake it".
    static let tap = "click"
    #else
    static let noun = "iPad"
    static let symbol = "ipad.landscape"
    static let settingsApp = "Settings"
    static let tap = "tap"
    #endif

    /// "this iPad" / "this Mac".
    static var this: String { "this \(noun)" }
}
