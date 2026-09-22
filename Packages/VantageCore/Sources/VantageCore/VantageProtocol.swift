/// Protocol-level constants shared by the host and client.
public enum VantageProtocol {
    /// Wire protocol version. Bump on incompatible changes.
    public static let version: UInt16 = 2
    /// Default TCP port the host listens on (tailnet-only).
    public static let defaultPort: UInt16 = 47_820
}
