import Foundation

/// A fully decoded protocol message.
public enum Message: Sendable {
    case hello(Hello)
    case challenge(Challenge)
    case authenticate(Authenticate)
    case authResult(AuthResult)
    case displayList(DisplayList)
    case selectDisplay(SelectDisplay)
    case streamConfig(StreamConfig)
    case viewportChanged(ViewportChanged)
    case qualityFeedback(QualityFeedback)
    case requestKeyframe
    case streamStats(StreamStats)
    case clipboard(ClipboardPayload)
    case hostCommand(HostCommandMessage)
    case ping(Ping)
    case pong(Pong)
    case disconnect(DisconnectMessage)
    case protocolError(ProtocolErrorMessage)
    case attachMedia(AttachMedia)
    case textInput(TextInput)
    case modifierState(ModifierState)
    case cursorShape(CursorShape)
    case videoConfig(VideoConfig)
    case hostStatus(HostStatus)
    case videoFrame(VideoFrame)
    case cursorPosition(CursorPosition)
    case pointerEvent(PointerEvent)
    case scrollEvent(ScrollEvent)
    case keyEvent(KeyEvent)
    case dictationControl(DictationControl)
    case dictationResult(DictationResult)
    case micAudio(MicAudio)

    public var kind: MessageKind {
        switch self {
        case .hello: .hello
        case .challenge: .challenge
        case .authenticate: .authenticate
        case .authResult: .authResult
        case .displayList: .displayList
        case .selectDisplay: .selectDisplay
        case .streamConfig: .streamConfig
        case .viewportChanged: .viewportChanged
        case .qualityFeedback: .qualityFeedback
        case .requestKeyframe: .requestKeyframe
        case .streamStats: .streamStats
        case .clipboard: .clipboard
        case .hostCommand: .hostCommand
        case .ping: .ping
        case .pong: .pong
        case .disconnect: .disconnect
        case .protocolError: .protocolError
        case .attachMedia: .attachMedia
        case .textInput: .textInput
        case .modifierState: .modifierState
        case .cursorShape: .cursorShape
        case .videoConfig: .videoConfig
        case .hostStatus: .hostStatus
        case .videoFrame: .videoFrame
        case .cursorPosition: .cursorPosition
        case .pointerEvent: .pointerEvent
        case .scrollEvent: .scrollEvent
        case .keyEvent: .keyEvent
        case .dictationControl: .dictationControl
        case .dictationResult: .dictationResult
        case .micAudio: .micAudio
        }
    }
}

public enum MessageCodingError: Error, Sendable {
    case emptyPayloadExpected(MessageKind)
}

extension Message {
    private static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dataEncodingStrategy = .base64
        return encoder
    }()

    private static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dataDecodingStrategy = .base64
        return decoder
    }()

    private static func json<T: Encodable>(_ value: T) throws -> Data {
        try jsonEncoder.encode(value)
    }

    private static func decodeJSON<T: Decodable>(_ type: T.Type, _ payload: Data) throws -> T {
        try jsonDecoder.decode(type, from: payload)
    }

    /// Encodes the payload only (no frame header).
    public func encodedPayload() throws -> Data {
        switch self {
        case .hello(let value): try Self.json(value)
        case .challenge(let value): try Self.json(value)
        case .authenticate(let value): try Self.json(value)
        case .authResult(let value): try Self.json(value)
        case .displayList(let value): try Self.json(value)
        case .selectDisplay(let value): try Self.json(value)
        case .streamConfig(let value): try Self.json(value)
        case .viewportChanged(let value): try Self.json(value)
        case .qualityFeedback(let value): try Self.json(value)
        case .requestKeyframe: Data()
        case .streamStats(let value): try Self.json(value)
        case .clipboard(let value): try Self.json(value)
        case .hostCommand(let value): try Self.json(value)
        case .ping(let value): try Self.json(value)
        case .pong(let value): try Self.json(value)
        case .disconnect(let value): try Self.json(value)
        case .protocolError(let value): try Self.json(value)
        case .attachMedia(let value): try Self.json(value)
        case .textInput(let value): try Self.json(value)
        case .modifierState(let value): try Self.json(value)
        case .cursorShape(let value): try Self.json(value)
        case .videoConfig(let value): try Self.json(value)
        case .hostStatus(let value): try Self.json(value)
        case .videoFrame(let value): value.encode()
        case .cursorPosition(let value): value.encode()
        case .pointerEvent(let value): value.encode()
        case .scrollEvent(let value): value.encode()
        case .keyEvent(let value): value.encode()
        case .dictationControl(let value): try Self.json(value)
        case .dictationResult(let value): try Self.json(value)
        case .micAudio(let value): value.encode()
        }
    }

    /// Encodes a complete frame (header + payload).
    public func encodedFrame() throws -> Data {
        Frame.encode(kind: kind, payload: try encodedPayload())
    }

    public static func decode(kind: MessageKind, payload: Data) throws -> Message {
        switch kind {
        case .hello: .hello(try decodeJSON(Hello.self, payload))
        case .challenge: .challenge(try decodeJSON(Challenge.self, payload))
        case .authenticate: .authenticate(try decodeJSON(Authenticate.self, payload))
        case .authResult: .authResult(try decodeJSON(AuthResult.self, payload))
        case .displayList: .displayList(try decodeJSON(DisplayList.self, payload))
        case .selectDisplay: .selectDisplay(try decodeJSON(SelectDisplay.self, payload))
        case .streamConfig: .streamConfig(try decodeJSON(StreamConfig.self, payload))
        case .viewportChanged: .viewportChanged(try decodeJSON(ViewportChanged.self, payload))
        case .qualityFeedback: .qualityFeedback(try decodeJSON(QualityFeedback.self, payload))
        case .requestKeyframe: .requestKeyframe
        case .streamStats: .streamStats(try decodeJSON(StreamStats.self, payload))
        case .clipboard: .clipboard(try decodeJSON(ClipboardPayload.self, payload))
        case .hostCommand: .hostCommand(try decodeJSON(HostCommandMessage.self, payload))
        case .ping: .ping(try decodeJSON(Ping.self, payload))
        case .pong: .pong(try decodeJSON(Pong.self, payload))
        case .disconnect: .disconnect(try decodeJSON(DisconnectMessage.self, payload))
        case .protocolError: .protocolError(try decodeJSON(ProtocolErrorMessage.self, payload))
        case .attachMedia: .attachMedia(try decodeJSON(AttachMedia.self, payload))
        case .textInput: .textInput(try decodeJSON(TextInput.self, payload))
        case .modifierState: .modifierState(try decodeJSON(ModifierState.self, payload))
        case .cursorShape: .cursorShape(try decodeJSON(CursorShape.self, payload))
        case .videoConfig: .videoConfig(try decodeJSON(VideoConfig.self, payload))
        case .hostStatus: .hostStatus(try decodeJSON(HostStatus.self, payload))
        case .videoFrame: .videoFrame(try VideoFrame.decode(payload))
        case .cursorPosition: .cursorPosition(try CursorPosition.decode(payload))
        case .pointerEvent: .pointerEvent(try PointerEvent.decode(payload))
        case .scrollEvent: .scrollEvent(try ScrollEvent.decode(payload))
        case .keyEvent: .keyEvent(try KeyEvent.decode(payload))
        case .dictationControl: .dictationControl(try decodeJSON(DictationControl.self, payload))
        case .dictationResult: .dictationResult(try decodeJSON(DictationResult.self, payload))
        case .micAudio: .micAudio(try MicAudio.decode(payload))
        }
    }
}
