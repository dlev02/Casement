import Foundation

/// How the app names the device it runs on in user-facing text ("this iPad", "this iPhone",
/// "this Mac"). The remote computer is always "the Mac"; on the Mac client both are Macs, so the
/// local one is "this Mac".
nonisolated enum LocalDevice {
    #if os(macOS)
    static let noun = "Mac"
    static let symbol = "desktopcomputer"
    static let settingsApp = "System Settings"
    /// How a control is pressed here, for sentences like "Click anywhere to wake it".
    static let tap = "click"
    #elseif os(visionOS)
    static let noun = "Apple Vision Pro"
    static let symbol = "visionpro"
    static let settingsApp = "Settings"
    static let tap = "tap"
    #else
    static let noun = isPhone ? "iPhone" : "iPad"
    static let symbol = isPhone ? "iphone" : "ipad.landscape"
    static let settingsApp = "Settings"
    static let tap = "tap"

    /// Read from the model identifier ("iPhone18,2"; the simulator names the one it pretends to
    /// be) rather than `UIDevice`, which is main-actor only.
    private static let isPhone: Bool = {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated.hasPrefix("iPhone")
        }
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return false }
        var machine = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &machine, &size, nil, 0) == 0 else { return false }
        return String(cString: machine).hasPrefix("iPhone")
    }()
    #endif

    /// "this iPad" / "this iPhone" / "this Mac".
    static var this: String { "this \(noun)" }
}
