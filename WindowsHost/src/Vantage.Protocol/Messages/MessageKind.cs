namespace Vantage.Protocol.Messages;

/// <summary>
/// The payload type of a frame (<c>Messages/MessageKind.swift</c>). Values below 100 are JSON
/// control messages; 100 and up are hand-packed little-endian binary.
/// </summary>
/// <remarks>
/// Swift peers close the connection on a kind they don't know, so the host must never send a kind
/// the client didn't opt into (see the "Windows v1" column in the protocol spec, §3).
/// </remarks>
public enum MessageKind : byte
{
    // Handshake and authentication (JSON)
    Hello = 1,
    Challenge = 2,
    Authenticate = 3,
    AuthResult = 4,

    // Session control (JSON)
    DisplayList = 10,
    SelectDisplay = 11,
    StreamConfig = 12,
    ViewportChanged = 13,
    QualityFeedback = 20,
    /// <summary>Empty payload: never JSON-parse it.</summary>
    RequestKeyframe = 21,
    StreamStats = 22,
    Clipboard = 30,
    HostCommand = 40,
    Ping = 50,
    Pong = 51,
    Disconnect = 52,
    ProtocolError = 53,
    AttachMedia = 60,
    TextInput = 61,
    ModifierState = 62,
    /// <summary>Gated on <c>HostCapabilities.audio</c>; a Windows v1 host never advertises it.</summary>
    AudioRequest = 63,
    /// <summary>Gated on <c>HostCapabilities.dictationEngines</c>; never advertised on Windows v1.</summary>
    DictationControl = 64,
    CursorShape = 70,
    VideoConfig = 71,
    HostStatus = 72,
    AudioConfig = 73,
    DictationResult = 74,

    // File channel only (JSON)
    FileOffer = 80,
    FileAccept = 81,
    FileComplete = 82,
    FileResult = 83,
    FileCancel = 84,

    // Hot path (binary)
    VideoFrame = 100,
    CursorPosition = 101,
    AudioPacket = 102,
    /// <summary>A file chunk from the host (file channel only).</summary>
    FileChunkToClient = 103,
    PointerEvent = 120,
    ScrollEvent = 121,
    KeyEvent = 122,
    MicAudio = 123,
    /// <summary>A file chunk from the client (file channel only).</summary>
    FileChunkToHost = 124,
}

public static class MessageKindExtensions
{
    /// <summary>Kinds from 100 up carry packed binary; the rest carry JSON.</summary>
    public static bool IsBinary(this MessageKind kind) => (byte)kind >= 100;

    /// <summary>The five JSON file kinds and the two chunk kinds: the only ones a file channel carries.</summary>
    public static bool IsFileChannelKind(this MessageKind kind) =>
        kind is >= MessageKind.FileOffer and <= MessageKind.FileCancel
            or MessageKind.FileChunkToClient or MessageKind.FileChunkToHost;
}
