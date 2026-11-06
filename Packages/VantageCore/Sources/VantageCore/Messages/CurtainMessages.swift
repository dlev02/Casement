import Foundation

// MARK: - Curtain
//
// Blacks out the computer's own screen and ignores its own keyboard and mouse while a client
// works, without changing the picture the client sees. The client sends `curtainRequest` only to
// a host whose `HostCapabilities.curtain` is true, and the host sends `curtainStatus` only to a
// client that has asked, so older peers never see these kinds.

/// Client → host: raise or lower the curtain for this session.
public struct CurtainRequest: Codable, Sendable, Equatable {
    public var enabled: Bool

    public init(enabled: Bool) {
        self.enabled = enabled
    }
}

/// Host → client: whether the curtain is up, after a request and whenever that changes (someone at
/// the computer locked it, which lowers the curtain).
public struct CurtainStatus: Codable, Sendable, Equatable {
    public var isUp: Bool
    /// When a request couldn't be met, why, for the user.
    public var unavailable: String?

    public init(isUp: Bool, unavailable: String? = nil) {
        self.isUp = isUp
        self.unavailable = unavailable
    }
}
