import VantageCore

/// What to call the computer a session controls: "Mac" or "PC". Every user-facing string that
/// names the host goes through one of these, so a Windows host never reads as a Mac.
///
/// Built from what the host said it runs (`ClientSession.hostPlatform`, the availability probe)
/// or, before any connection, from the saved device (`SavedDevice.platform`). Nil and unknown
/// platforms read as a Mac: hosts older than the platform field are all Macs.
nonisolated struct HostNoun: Hashable, Sendable {
    let platform: HostPlatform

    init(_ platform: HostPlatform?) {
        self.platform = platform ?? .macOS
    }

    static let mac = HostNoun(.macOS)
    static let pc = HostNoun(.windows)

    var isWindows: Bool { platform == .windows }

    /// "Mac" / "PC".
    var name: String { isWindows ? "PC" : "Mac" }
    /// "the Mac" / "the PC".
    var the: String { "the \(name)" }
    /// "The Mac" / "The PC", to start a sentence.
    var theCapitalized: String { "The \(name)" }
    /// "the Mac's" / "the PC's".
    var thePossessive: String { "the \(name)'s" }
    /// "The Mac's" / "The PC's".
    var thePossessiveCapitalized: String { "The \(name)'s" }
    /// "Macs" / "PCs".
    var plural: String { "\(name)s" }

    /// What Casement Host calls the button that shows a pairing code: "Pair a Device" in the
    /// Mac's menu bar menu, "Show Pairing Code" in the PC's tray menu.
    var pairingCommand: String { isWindows ? "Show Pairing Code" : "Pair a Device" }
    /// Where to find it, to follow "On ⟨name⟩, ": "click the Casement Host icon in the menu bar and choose
    /// “Pair a Device.”"
    var pairingInstruction: String {
        isWindows
            ? "click the Casement Host icon near the clock on the taskbar and choose “\(pairingCommand).”"
            : "click the Casement Host icon in the menu bar and choose “\(pairingCommand).”"
    }

    /// The SF Symbol for the host in lists and menus.
    var symbol: String { isWindows ? "pc" : "macbook" }
}

extension HostPlatform {
    /// A saved device's `os` string ("macOS", "Windows", or whatever Tailscale said) as a
    /// platform. Anything that isn't Windows is treated as a Mac.
    init(savedOS os: String) {
        self = os.lowercased().contains("windows") ? .windows : .macOS
    }

    /// What `SavedDevice.os` records for this platform.
    var savedOS: String {
        switch self {
        case .windows: "Windows"
        case .macOS: "macOS"
        default: rawValue
        }
    }
}
