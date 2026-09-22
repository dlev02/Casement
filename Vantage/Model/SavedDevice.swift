import Foundation
import VantageCore

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

    init(id: UUID = UUID(), name: String, host: String, port: UInt16 = VantageProtocol.defaultPort, os: String = "macOS", lastConnected: Date? = nil, connectionCount: Int = 0, preferredCodec: VideoCodec? = nil, naturalScroll: Bool = true) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.os = os
        self.lastConnected = lastConnected
        self.connectionCount = connectionCount
        self.preferredCodec = preferredCodec
        self.naturalScroll = naturalScroll
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
