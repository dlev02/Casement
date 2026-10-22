using System.Text.Json.Serialization;

namespace Vantage.Protocol.Messages;

// JSON control messages (kinds < 100), mirroring Messages/ControlMessages.swift field for field.
//
// Rules the Swift decoder enforces (spec §5): every key below is exactly the Swift property name;
// a non-optional field must be present and non-null (`required` here, and the serializer respects
// nullable annotations); optional fields are nullable and omitted when null; byte[] is standard
// base64 with padding; enums are their raw strings except KeyModifiers (a number).

/// <summary>A decoded protocol message. <see cref="Kind"/> is the frame kind it travels as.</summary>
public interface IMessage
{
    MessageKind Kind { get; }
}

[JsonConverter(typeof(StrictStringEnumConverter<VideoCodec>))]
public enum VideoCodec
{
    [JsonStringEnumMemberName("h264")] H264,
    [JsonStringEnumMemberName("hevc")] Hevc,
}

[JsonConverter(typeof(StrictStringEnumConverter<QualityPreset>))]
public enum QualityPreset
{
    [JsonStringEnumMemberName("auto")] Auto,
    [JsonStringEnumMemberName("text")] Text,
    [JsonStringEnumMemberName("motion")] Motion,
    [JsonStringEnumMemberName("maximum")] Maximum,
}

[JsonConverter(typeof(StrictStringEnumConverter<AuthStatus>))]
public enum AuthStatus
{
    [JsonStringEnumMemberName("ok")] Ok,
    [JsonStringEnumMemberName("pairingRequired")] PairingRequired,
    [JsonStringEnumMemberName("badPairingCode")] BadPairingCode,
    [JsonStringEnumMemberName("badSignature")] BadSignature,
    [JsonStringEnumMemberName("denied")] Denied,
    [JsonStringEnumMemberName("versionMismatch")] VersionMismatch,
}

[JsonConverter(typeof(StrictStringEnumConverter<HostInputPath>))]
public enum HostInputPath
{
    [JsonStringEnumMemberName("native")] Native,
    [JsonStringEnumMemberName("screenSharingBridge")] ScreenSharingBridge,
}

[JsonConverter(typeof(StrictStringEnumConverter<HostCommand>))]
public enum HostCommand
{
    [JsonStringEnumMemberName("lockScreen")] LockScreen,
    [JsonStringEnumMemberName("sleepDisplay")] SleepDisplay,
    [JsonStringEnumMemberName("wakeDisplay")] WakeDisplay,
    [JsonStringEnumMemberName("releaseAllInput")] ReleaseAllInput,
    [JsonStringEnumMemberName("refreshDisplays")] RefreshDisplays,
    [JsonStringEnumMemberName("restoreDisplays")] RestoreDisplays,
}

/// <summary>Modifier bits (an OptionSet in Swift), sent as a plain JSON number and as a u32 in binary.</summary>
[Flags]
[JsonConverter(typeof(KeyModifiersJsonConverter))]
public enum KeyModifiers : uint
{
    None = 0,
    CapsLock = 1 << 0,
    Shift = 1 << 1,
    Control = 1 << 2,
    /// <summary>⌥ Option; Alt on Windows.</summary>
    Option = 1 << 3,
    /// <summary>⌘ Command; the Windows key on Windows (the host maps it literally).</summary>
    Command = 1 << 4,
    /// <summary>Fn; no Windows equivalent (dropped).</summary>
    Function = 1 << 5,
}

// MARK: - Geometry

public sealed record Viewport
{
    [JsonPropertyName("widthPoints")] public required double WidthPoints { get; init; }
    [JsonPropertyName("heightPoints")] public required double HeightPoints { get; init; }
    [JsonPropertyName("scale")] public required double Scale { get; init; }
}

public sealed record DisplayInfo
{
    /// <summary>On Windows, the n in <c>\\.\DISPLAYn</c>.</summary>
    [JsonPropertyName("id")] public required uint Id { get; init; }
    [JsonPropertyName("name")] public required string Name { get; init; }
    [JsonPropertyName("pixelWidth")] public required int PixelWidth { get; init; }
    [JsonPropertyName("pixelHeight")] public required int PixelHeight { get; init; }
    /// <summary><c>round(pixelWidth / scale)</c>; pointer events arrive in this space.</summary>
    [JsonPropertyName("pointWidth")] public required int PointWidth { get; init; }
    [JsonPropertyName("pointHeight")] public required int PointHeight { get; init; }
    /// <summary>On Windows, effective DPI / 96.</summary>
    [JsonPropertyName("scale")] public required double Scale { get; init; }
    /// <summary>Top-left of the monitor in virtual-desktop pixels on Windows.</summary>
    [JsonPropertyName("originX")] public required double OriginX { get; init; }
    [JsonPropertyName("originY")] public required double OriginY { get; init; }
    [JsonPropertyName("isMain")] public required bool IsMain { get; init; }
    [JsonPropertyName("isBuiltIn")] public required bool IsBuiltIn { get; init; }
    [JsonPropertyName("isVirtual")] public required bool IsVirtual { get; init; }
    [JsonPropertyName("refreshRate")] public required double RefreshRate { get; init; }
}

// MARK: - Handshake

public sealed record ClientFeatures
{
    [JsonPropertyName("dictation")] public bool? Dictation { get; init; }
    [JsonPropertyName("macAudio")] public bool? MacAudio { get; init; }
    [JsonPropertyName("fileTransfer")] public bool? FileTransfer { get; init; }
    [JsonPropertyName("filesOnly")] public bool? FilesOnly { get; init; }
    /// <summary>The client draws the pointer itself from <c>cursorShape</c>/<c>cursorPosition</c>.</summary>
    [JsonPropertyName("localCursor")] public bool? LocalCursor { get; init; }
}

public sealed record Hello : IMessage
{
    MessageKind IMessage.Kind => MessageKind.Hello;
    [JsonPropertyName("protocolVersion")] public required ushort ProtocolVersion { get; init; }
    [JsonPropertyName("clientName")] public required string ClientName { get; init; }
    [JsonPropertyName("deviceModel")] public required string DeviceModel { get; init; }
    [JsonPropertyName("appVersion")] public required string AppVersion { get; init; }
    /// <summary>Raw 32-byte Ed25519 public key.</summary>
    [JsonPropertyName("clientPublicKey")] public required byte[] ClientPublicKey { get; init; }
    [JsonPropertyName("supportedCodecs")] public required IReadOnlyList<VideoCodec> SupportedCodecs { get; init; }
    [JsonPropertyName("maxDecodeWidth")] public required int MaxDecodeWidth { get; init; }
    [JsonPropertyName("maxDecodeHeight")] public required int MaxDecodeHeight { get; init; }
    [JsonPropertyName("viewport")] public Viewport? Viewport { get; init; }
    [JsonPropertyName("isReadinessProbe")] public bool? IsReadinessProbe { get; init; }
    [JsonPropertyName("features")] public ClientFeatures? Features { get; init; }
}

public sealed record Challenge : IMessage
{
    MessageKind IMessage.Kind => MessageKind.Challenge;
    [JsonPropertyName("hostName")] public required string HostName { get; init; }
    [JsonPropertyName("hostVersion")] public required string HostVersion { get; init; }
    [JsonPropertyName("hostPublicKey")] public required byte[] HostPublicKey { get; init; }
    /// <summary>32 random bytes from a CSPRNG.</summary>
    [JsonPropertyName("nonce")] public required byte[] Nonce { get; init; }
    [JsonPropertyName("isPaired")] public required bool IsPaired { get; init; }
    /// <summary>Tailnet login of the peer; omitted for probes and files-only sessions.</summary>
    [JsonPropertyName("peerTailnetName")] public string? PeerTailnetName { get; init; }
    /// <summary><see cref="HostPlatforms"/> value; older clients ignore it.</summary>
    [JsonPropertyName("hostPlatform")] public string? HostPlatform { get; init; }
}

public sealed record Authenticate : IMessage
{
    MessageKind IMessage.Kind => MessageKind.Authenticate;
    /// <summary>64-byte Ed25519 signature over the 111-byte auth transcript.</summary>
    [JsonPropertyName("signature")] public required byte[] Signature { get; init; }
    [JsonPropertyName("pairingCode")] public string? PairingCode { get; init; }
}

public sealed record HostCapabilities
{
    [JsonPropertyName("codecs")] public required IReadOnlyList<VideoCodec> Codecs { get; init; }
    [JsonPropertyName("canManageVirtualDisplay")] public required bool CanManageVirtualDisplay { get; init; }
    [JsonPropertyName("clipboard")] public required bool Clipboard { get; init; }
    [JsonPropertyName("maxFPS")] public required int MaxFPS { get; init; }
    [JsonPropertyName("dictationEngines")] public IReadOnlyList<string>? DictationEngines { get; init; }
    [JsonPropertyName("audio")] public bool? Audio { get; init; }
    [JsonPropertyName("fileTransfer")] public bool? FileTransfer { get; init; }
    [JsonPropertyName("filesOnlySessions")] public bool? FilesOnlySessions { get; init; }
    /// <summary><see cref="HostPlatforms"/> value; nil means macOS to the client.</summary>
    [JsonPropertyName("platform")] public string? Platform { get; init; }
    /// <summary>
    /// For a client with <c>features.localCursor</c>: the video leaves the pointer out and the host
    /// sends <c>cursorShape</c> and <c>cursorPosition</c> instead.
    /// </summary>
    [JsonPropertyName("cursorShapes")] public bool? CursorShapes { get; init; }
}

public sealed record HostReadiness
{
    [JsonPropertyName("screenRecordingGranted")] public required bool ScreenRecordingGranted { get; init; }
    [JsonPropertyName("accessibilityGranted")] public required bool AccessibilityGranted { get; init; }
}

public sealed record AuthResult : IMessage
{
    MessageKind IMessage.Kind => MessageKind.AuthResult;
    [JsonPropertyName("status")] public required AuthStatus Status { get; init; }
    [JsonPropertyName("message")] public string? Message { get; init; }
    /// <summary>32 bytes for <c>attachMedia</c>; only to a client that said <c>fileTransfer</c>.</summary>
    [JsonPropertyName("sessionToken")] public byte[]? SessionToken { get; init; }
    [JsonPropertyName("displays")] public IReadOnlyList<DisplayInfo>? Displays { get; init; }
    [JsonPropertyName("capabilities")] public HostCapabilities? Capabilities { get; init; }
    [JsonPropertyName("readiness")] public HostReadiness? Readiness { get; init; }
}

public sealed record AttachMedia : IMessage
{
    MessageKind IMessage.Kind => MessageKind.AttachMedia;
    [JsonPropertyName("sessionToken")] public required byte[] SessionToken { get; init; }
}

// MARK: - Session control

/// <summary>
/// Swift's <c>enum DisplaySelection { case display(UInt32); case fitViewport(Viewport) }</c> with
/// synthesized Codable: <c>{"display":{"_0":3}}</c> or <c>{"fitViewport":{"_0":{…}}}</c>.
/// </summary>
[JsonConverter(typeof(DisplaySelectionJsonConverter))]
public abstract record DisplaySelection
{
    private protected DisplaySelection() { }

    /// <summary>Stream this existing display.</summary>
    public sealed record Display(uint Id) : DisplaySelection;

    /// <summary>Fit the viewport. Windows v1 streams the primary display and ignores the size.</summary>
    public sealed record FitViewport(Viewport Viewport) : DisplaySelection;
}

public sealed record SelectDisplay : IMessage
{
    MessageKind IMessage.Kind => MessageKind.SelectDisplay;
    [JsonPropertyName("selection")] public required DisplaySelection Selection { get; init; }
    [JsonPropertyName("targetFPS")] public required int TargetFPS { get; init; }
    [JsonPropertyName("quality")] public required QualityPreset Quality { get; init; }
    [JsonPropertyName("preferredCodec")] public VideoCodec? PreferredCodec { get; init; }
    [JsonPropertyName("useVirtualDisplay")] public bool? UseVirtualDisplay { get; init; }
}

public sealed record DisplayList : IMessage
{
    MessageKind IMessage.Kind => MessageKind.DisplayList;
    [JsonPropertyName("displays")] public required IReadOnlyList<DisplayInfo> Displays { get; init; }
}

public sealed record StreamConfig : IMessage
{
    MessageKind IMessage.Kind => MessageKind.StreamConfig;
    [JsonPropertyName("display")] public required DisplayInfo Display { get; init; }
    [JsonPropertyName("codec")] public required VideoCodec Codec { get; init; }
    [JsonPropertyName("fps")] public required int Fps { get; init; }
    [JsonPropertyName("bitrateKbps")] public required int BitrateKbps { get; init; }
}

public sealed record ViewportChanged : IMessage
{
    MessageKind IMessage.Kind => MessageKind.ViewportChanged;
    [JsonPropertyName("viewport")] public required Viewport Viewport { get; init; }
}

public sealed record QualityFeedback : IMessage
{
    MessageKind IMessage.Kind => MessageKind.QualityFeedback;
    [JsonPropertyName("rttMillis")] public required double RttMillis { get; init; }
    [JsonPropertyName("decodeMillis")] public required double DecodeMillis { get; init; }
    [JsonPropertyName("framesReceived")] public required ulong FramesReceived { get; init; }
    [JsonPropertyName("framesDropped")] public required ulong FramesDropped { get; init; }
    [JsonPropertyName("queueDepth")] public required int QueueDepth { get; init; }
    [JsonPropertyName("bytesReceived")] public required ulong BytesReceived { get; init; }
    [JsonPropertyName("windowSeconds")] public required double WindowSeconds { get; init; }
}

/// <summary>Kind 21. Its payload is empty and never parsed.</summary>
public sealed record RequestKeyframe : IMessage
{
    public static readonly RequestKeyframe Instance = new();
    MessageKind IMessage.Kind => MessageKind.RequestKeyframe;
}

/// <summary>Never sent by a host (the client ignores it); decodable for completeness.</summary>
public sealed record StreamStats : IMessage
{
    MessageKind IMessage.Kind => MessageKind.StreamStats;
    [JsonPropertyName("captureFPS")] public required double CaptureFPS { get; init; }
    [JsonPropertyName("encodeMillis")] public required double EncodeMillis { get; init; }
    [JsonPropertyName("bitrateKbps")] public required int BitrateKbps { get; init; }
    [JsonPropertyName("targetBitrateKbps")] public required int TargetBitrateKbps { get; init; }
    [JsonPropertyName("framesSent")] public required ulong FramesSent { get; init; }
    [JsonPropertyName("framesSkipped")] public required ulong FramesSkipped { get; init; }
}

/// <summary>Clipboard contents (kind 30, both ways). Never send one with all three fields null.</summary>
public sealed record ClipboardPayload : IMessage
{
    MessageKind IMessage.Kind => MessageKind.Clipboard;
    /// <summary>Plain text with LF line endings.</summary>
    [JsonPropertyName("text")] public string? Text { get; init; }
    /// <summary>PNG bytes (≤ 24 MiB).</summary>
    [JsonPropertyName("imagePNG")] public byte[]? ImagePNG { get; init; }
    /// <summary>RTF bytes alongside <see cref="Text"/>.</summary>
    [JsonPropertyName("rtf")] public byte[]? Rtf { get; init; }

    [JsonIgnore] public bool IsEmpty => Text is null && ImagePNG is null && Rtf is null;
}

public sealed record HostStatus : IMessage
{
    MessageKind IMessage.Kind => MessageKind.HostStatus;
    [JsonPropertyName("isScreenLocked")] public required bool IsScreenLocked { get; init; }
    /// <summary>On Windows: the secure desktop (UAC, Ctrl+Alt+Del) is up while the session isn't locked.</summary>
    [JsonPropertyName("isSecureInputActive")] public required bool IsSecureInputActive { get; init; }
    [JsonPropertyName("inputPath")] public required HostInputPath InputPath { get; init; }
    [JsonPropertyName("message")] public string? Message { get; init; }
    [JsonPropertyName("isDisplayAsleep")] public bool? IsDisplayAsleep { get; init; }
    [JsonPropertyName("isScreenUnavailable")] public bool? IsScreenUnavailable { get; init; }
}

public sealed record HostCommandMessage : IMessage
{
    MessageKind IMessage.Kind => MessageKind.HostCommand;
    [JsonPropertyName("command")] public required HostCommand Command { get; init; }
}

public sealed record Ping : IMessage
{
    MessageKind IMessage.Kind => MessageKind.Ping;
    /// <summary>Client uptime in ns; exceeds 2^53, so it is parsed as ulong, never through double.</summary>
    [JsonPropertyName("sentAtNanos")] public required ulong SentAtNanos { get; init; }
}

public sealed record Pong : IMessage
{
    MessageKind IMessage.Kind => MessageKind.Pong;
    /// <summary>Exactly the ping's <c>sentAtNanos</c>.</summary>
    [JsonPropertyName("echoNanos")] public required ulong EchoNanos { get; init; }
}

public sealed record DisconnectMessage : IMessage
{
    MessageKind IMessage.Kind => MessageKind.Disconnect;
    [JsonPropertyName("reason")] public required string Reason { get; init; }
}

/// <summary>Never sent by the host; decodable for completeness.</summary>
public sealed record ProtocolErrorMessage : IMessage
{
    MessageKind IMessage.Kind => MessageKind.ProtocolError;
    [JsonPropertyName("code")] public required string Code { get; init; }
    [JsonPropertyName("message")] public required string Message { get; init; }
}

public sealed record TextInput : IMessage
{
    MessageKind IMessage.Kind => MessageKind.TextInput;
    [JsonPropertyName("text")] public required string Text { get; init; }
}

/// <summary>Never sent by current clients; ignored.</summary>
public sealed record ModifierState : IMessage
{
    MessageKind IMessage.Kind => MessageKind.ModifierState;
    [JsonPropertyName("modifiers")] public required KeyModifiers Modifiers { get; init; }
}

public sealed record VideoConfig : IMessage
{
    MessageKind IMessage.Kind => MessageKind.VideoConfig;
    [JsonPropertyName("codec")] public required VideoCodec Codec { get; init; }
    [JsonPropertyName("width")] public required int Width { get; init; }
    [JsonPropertyName("height")] public required int Height { get; init; }
    /// <summary>H.264: [SPS, PPS]; raw NAL units with their 1-byte header, no start code or length.</summary>
    [JsonPropertyName("parameterSets")] public required IReadOnlyList<byte[]> ParameterSets { get; init; }
    /// <summary>Always 4 (and always present: Swift requires the key).</summary>
    [JsonPropertyName("nalLengthSize")] public required int NalLengthSize { get; init; }
    [JsonPropertyName("fps")] public required int Fps { get; init; }
}

/// <summary>The pointer's look, for a client that draws it (<c>features.localCursor</c>). PNG pixels; sizes and hotspot in points.</summary>
public sealed record CursorShape : IMessage
{
    MessageKind IMessage.Kind => MessageKind.CursorShape;
    [JsonPropertyName("pngData")] public required byte[] PngData { get; init; }
    [JsonPropertyName("widthPoints")] public required double WidthPoints { get; init; }
    [JsonPropertyName("heightPoints")] public required double HeightPoints { get; init; }
    [JsonPropertyName("hotspotX")] public required double HotspotX { get; init; }
    [JsonPropertyName("hotspotY")] public required double HotspotY { get; init; }
    [JsonPropertyName("scale")] public required double Scale { get; init; }
}
