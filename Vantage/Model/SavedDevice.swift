import Foundation
import Network
import VantageCore

/// Accepts a plain host or pasted host:port without treating the port as part of a DNS name.
struct ConnectionAddress: Equatable {
    let host: String
    let port: UInt16

    init(host input: String, port portInput: String) throws {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace || "/?#@%".contains($0) }) else {
            throw AddressError.invalidHost
        }
        var host = text
        var port = portInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("[") {
            guard let end = text.firstIndex(of: "]") else { throw AddressError.invalidHost }
            host = String(text[text.index(after: text.startIndex)..<end])
            guard IPv6Address(host) != nil else { throw AddressError.invalidHost }
            let suffix = text[text.index(after: end)...]
            if !suffix.isEmpty {
                guard suffix.hasPrefix(":") else { throw AddressError.invalidHost }
                port = String(suffix.dropFirst())
            }
        } else if text.filter({ $0 == ":" }).count == 1 {
            let parts = text.split(separator: ":", omittingEmptySubsequences: false)
            host = String(parts[0])
            port = String(parts[1])
        } else if text.contains(":") {
            guard IPv6Address(text) != nil else { throw AddressError.invalidHost }
        }
        guard !host.isEmpty, !host.contains("["), !host.contains("]") else { throw AddressError.invalidHost }
        guard !port.isEmpty, port.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = UInt16(port), number > 0 else { throw AddressError.invalidPort }
        self.host = host
        self.port = number
    }

    enum AddressError: LocalizedError {
        case invalidHost, invalidPort
        var errorDescription: String? {
            switch self {
            case .invalidHost: "Enter a Tailscale IP or MagicDNS name, optionally followed by :port."
            case .invalidPort: "Enter a port between 1 and 65535. Porthole normally uses 47820."
            }
        }
    }
}

/// A host the user can connect to. Discovered via Tailscale or entered manually.
struct SavedDevice: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    /// MagicDNS name or Tailscale IP.
    var host: String
    var port: UInt16
    var os: String
    var lastConnected: Date?
    var connectionCount: Int
    var preferredCodec: VideoCodec?
    var naturalScroll: Bool
    /// Ask the Mac for a BetterDisplay virtual display sized to this device. Optional so devices
    /// saved by earlier builds still decode; nil means off.
    var useVirtualDisplay: Bool?
    /// When this entry last changed, so two devices syncing through iCloud can agree on the
    /// newer copy. Optional so devices saved by earlier builds still decode.
    var updatedAt: Date?
    /// The Mac's address on its home network (e.g. 192.168.1.20). At the login window Tailscale
    /// isn't running on the Mac yet, so logging in with Screen Sharing has to go through a Tailscale
    /// subnet router to this address instead. Optional so devices saved by earlier builds decode.
    var homeAddress: String?
    /// This Mac's own session controls. Nil uses the default from Settings → Controls. Optional
    /// so devices saved by earlier builds decode; syncs with the rest of the entry.
    var controlStrip: ControlStripLayout?
    /// Play this Mac's sound on this device when a session starts (the strip's Mac Audio
    /// toggle). Optional so devices saved by earlier builds decode; nil means off.
    var playMacAudio: Bool?
    /// On a PC, the keyboard's ⌘ presses Ctrl (and Control the Windows key), so ⌘C copies as it
    /// does on a Mac (`KeyRemap`). Nil means on for a PC; a Mac ignores it. Optional so devices
    /// saved by earlier builds decode.
    var commandSendsControl: Bool?

    /// What the device runs, from `os` (recorded from the host itself once it has answered).
    var platform: HostPlatform { HostPlatform(savedOS: os) }
    /// "Mac" or "PC" for this device.
    var hostNoun: HostNoun { HostNoun(platform) }
    /// The keyboard remapping this device's sessions use.
    var keyRemap: KeyRemap { KeyRemap.forHost(platform, commandSendsControl: commandSendsControl) }

    init(id: UUID = UUID(), name: String, host: String, port: UInt16 = VantageProtocol.defaultPort, os: String = "macOS", lastConnected: Date? = nil, connectionCount: Int = 0, preferredCodec: VideoCodec? = nil, naturalScroll: Bool = true, useVirtualDisplay: Bool? = nil, updatedAt: Date? = nil, homeAddress: String? = nil, controlStrip: ControlStripLayout? = nil, playMacAudio: Bool? = nil, commandSendsControl: Bool? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.os = os
        self.lastConnected = lastConnected
        self.connectionCount = connectionCount
        self.preferredCodec = preferredCodec
        self.naturalScroll = naturalScroll
        self.useVirtualDisplay = useVirtualDisplay
        self.updatedAt = updatedAt
        self.homeAddress = homeAddress
        self.controlStrip = controlStrip
        self.playMacAudio = playMacAudio
        self.commandSendsControl = commandSendsControl
    }
}

enum DeviceSort: String, CaseIterable, Identifiable {
    case name, lastConnected, connectionCount
    var id: String { rawValue }
    var label: String {
        switch self {
        case .name: "Name"
        case .lastConnected: "Last Connected"
        case .connectionCount: "Most Used"
        }
    }
    var symbol: String {
        switch self {
        case .name: "textformat"
        case .lastConnected: "clock"
        case .connectionCount: "chart.bar"
        }
    }
}
