#if os(macOS)
import Foundation
import SystemConfiguration
import VantageCore

/// Is the Mac a session connects to the one it runs on? Then the pointer and keys it sends come
/// straight back through the host (the host's events are stamped, so they aren't sent again,
/// but the pointer still fights the one moving it), and the picture shows itself.
enum ThisMac {
    /// A loopback or one of this Mac's own tailnet addresses, or the host said this Mac's name.
    static func isHost(address: String, hostName: String?) -> Bool {
        let address = address.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if ["localhost", "127.0.0.1", "::1"].contains(address) || address.hasPrefix("127.") { return true }
        if VantageNetwork.localTailscaleAddresses().contains(where: { $0.lowercased() == address }) { return true }
        if let hostName, !hostName.isEmpty, let computerName, hostName == computerName { return true }
        return false
    }

    /// This Mac's name in Sharing settings (what Vantage Host reports as its own).
    static let computerName: String? = SCDynamicStoreCopyComputerName(nil, nil) as String?
}

/// Launch arguments for the Mac client's session (DEBUG only).
enum MacSessionOptions {
    /// `-VantageAllowSelfControl 1`: a session with this same Mac starts with input on anyway.
    static var allowSelfControl: Bool { flag("-VantageAllowSelfControl") }
    /// `-VantageKeyProbe 1`: the keys sent, as `session.keyProbe`'s value.
    static var keyProbe: Bool { flag("-VantageKeyProbe") }

    private static func flag(_ name: String) -> Bool {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return false }
        return arguments[index + 1] == "1"
        #else
        false
        #endif
    }
}
#endif
