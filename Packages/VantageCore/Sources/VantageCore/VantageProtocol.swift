/// Protocol-level constants shared by the host and client.
public enum VantageProtocol {
    /// Wire protocol version. Bump on incompatible changes.
    public static let version: UInt16 = 2
    /// Default TCP port the host listens on (tailnet-only).
    public static let defaultPort: UInt16 = 47_820
    /// The host stamps every event it posts with this in `CGEventField.eventSourceUserData`
    /// ("VANTAGE1"). A client running on the same Mac as the host drops events that carry it, so
    /// its own input coming back from the host is never sent again in a loop.
    public static let injectedEventMarker: Int64 = 0x5641_4E54_4147_4531
}
