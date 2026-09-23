import CryptoKit
import Foundation
import Synchronization

/// Tokens that let a second connection join an authenticated session (the file channel).
///
/// The host issues one per authenticated connection and returns it in `AuthResult.sessionToken`.
/// A new connection whose first message is `attachMedia{token}` is bound to the owner only if the
/// token matches (compared in constant time), comes from the same peer address as the connection
/// it was issued on, and hasn't expired. Every token works once: a match is removed whether or
/// not the peer check passes. `revoke(owner:)` drops an owner's token when its session ends.
public final class AttachTokenRegistry<Owner: AnyObject & Sendable>: Sendable {
    private struct Entry: Sendable {
        var token: Data
        var peer: String
        var owner: Owner
        var expires: ContinuousClock.Instant
    }

    public static var tokenLength: Int { 32 }
    private let lifetime: Duration
    private let entries = Mutex<[Entry]>([])

    public init(lifetime: Duration = .seconds(60)) {
        self.lifetime = lifetime
    }

    /// A fresh random token for `owner`, usable once from `peer` (the host part of the address).
    public func issue(for owner: Owner, peer: String, now: ContinuousClock.Instant = .now) -> Data {
        let token = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let entry = Entry(token: token, peer: peer, owner: owner, expires: now + lifetime)
        entries.withLock { list in
            list.removeAll { $0.owner === owner || $0.expires <= now }
            list.append(entry)
        }
        return token
    }

    /// The owner `token` was issued to, if it is live and `peer` is where it was issued to.
    public func claim(_ token: Data, peer: String, now: ContinuousClock.Instant = .now) -> Owner? {
        entries.withLock { list in
            var match: Int?
            // Compare against every entry, all the way through, so timing says nothing.
            for (index, entry) in list.enumerated() where VantageCore.constantTimeEquals(entry.token, token) {
                match = index
            }
            defer { list.removeAll { $0.expires <= now } }
            guard let match else { return nil }
            let entry = list.remove(at: match)
            guard entry.peer == peer, entry.expires > now else { return nil }
            return entry.owner
        }
    }

    public func revoke(owner: Owner) {
        entries.withLock { $0.removeAll { $0.owner === owner } }
    }

    public var count: Int { entries.withLock { $0.count } }

    /// Equal lengths and bytes, without stopping at the first difference.
    public static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        VantageCore.constantTimeEquals(a, b)
    }
}

/// Equal lengths and bytes, without stopping at the first difference.
func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    var difference: UInt8 = 0
    for (x, y) in zip(a, b) { difference |= x ^ y }
    return difference == 0
}
