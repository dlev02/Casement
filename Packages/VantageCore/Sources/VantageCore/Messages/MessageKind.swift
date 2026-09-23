/// Identifies the payload type of a frame. Values below 100 are JSON-encoded control
/// messages; values from 100 up are hand-packed binary hot-path messages.
public enum MessageKind: UInt8, Sendable, CaseIterable {
    // MARK: Handshake & authentication (JSON)
    case hello = 1
    case challenge = 2
    case authenticate = 3
    case authResult = 4

    // MARK: Session control (JSON)
    case displayList = 10
    case selectDisplay = 11
    case streamConfig = 12
    case viewportChanged = 13
    case qualityFeedback = 20
    case requestKeyframe = 21
    case streamStats = 22
    case clipboard = 30
    case hostCommand = 40
    case ping = 50
    case pong = 51
    case disconnect = 52
    case protocolError = 53
    case attachMedia = 60
    case textInput = 61
    case modifierState = 62
    /// Capability-gated: only sent to hosts whose capabilities say `audio`.
    case audioRequest = 63
    /// Capability-gated: only sent to hosts that list dictation engines.
    case dictationControl = 64
    case cursorShape = 70
    case videoConfig = 71
    case hostStatus = 72
    /// Capability-gated: only sent to clients that asked for audio (`Hello.features.macAudio`).
    case audioConfig = 73
    /// Capability-gated: only sent to clients whose `Hello.features` includes dictation.
    case dictationResult = 74

    // MARK: Hot path (binary)
    case videoFrame = 100
    case cursorPosition = 101
    /// Capability-gated like `audioConfig`.
    case audioPacket = 102
    case pointerEvent = 120
    case scrollEvent = 121
    case keyEvent = 122
    /// Capability-gated like `dictationControl`.
    case micAudio = 123

    public var isBinary: Bool { rawValue >= 100 }
}
