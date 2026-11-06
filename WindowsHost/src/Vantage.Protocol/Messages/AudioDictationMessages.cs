using System.Text.Json.Serialization;

namespace Vantage.Protocol.Messages;

// AudioMessages.swift, DictationMessages.swift. The Windows host streams the PC's sound
// (`audioRequest` → `audioConfig`/`audioPacket`, see Audio/) once it advertises `audio`; it never
// advertises `dictationEngines`, so the dictation kinds never arrive and are here so the codec
// knows every kind.

/// <summary>Client → host: raise or lower the curtain for this session.</summary>
public sealed record CurtainRequest : IMessage
{
    MessageKind IMessage.Kind => MessageKind.CurtainRequest;
    [JsonPropertyName("enabled")] public required bool Enabled { get; init; }
}

/// <summary>Host → client: whether the curtain is up, and when a request failed, why.</summary>
public sealed record CurtainStatus : IMessage
{
    MessageKind IMessage.Kind => MessageKind.CurtainStatus;
    [JsonPropertyName("isUp")] public required bool IsUp { get; init; }
    [JsonPropertyName("unavailable")] public string? Unavailable { get; init; }
}

public sealed record AudioRequest : IMessage
{
    MessageKind IMessage.Kind => MessageKind.AudioRequest;
    [JsonPropertyName("enabled")] public required bool Enabled { get; init; }
    [JsonPropertyName("muteMacOutput")] public bool? MuteMacOutput { get; init; }
}

public sealed record AudioConfig : IMessage
{
    /// <summary><c>AudioConfig.opus</c>: the only codec today.</summary>
    public const string Opus = "opus";

    MessageKind IMessage.Kind => MessageKind.AudioConfig;
    [JsonPropertyName("codec")] public required string Codec { get; init; }
    [JsonPropertyName("sampleRate")] public required int SampleRate { get; init; }
    [JsonPropertyName("channels")] public required int Channels { get; init; }
    [JsonPropertyName("framesPerPacket")] public required int FramesPerPacket { get; init; }
    [JsonPropertyName("bitrate")] public required int Bitrate { get; init; }
    [JsonPropertyName("unavailable")] public string? Unavailable { get; init; }

    /// <summary>The stream every host sends (Swift's defaults): Opus, 48 kHz stereo, 480-frame packets.</summary>
    public static AudioConfig Streaming(int bitrate = 128_000) => new()
    {
        Codec = Opus,
        SampleRate = 48_000,
        Channels = 2,
        FramesPerPacket = 480,
        Bitrate = bitrate,
    };

    /// <summary>Audio didn't start or stopped (Swift <c>AudioConfig.unavailable(_:)</c>), with the reason to show.</summary>
    public static AudioConfig UnavailableBecause(string reason) => Streaming() with { Unavailable = reason };
}

[JsonConverter(typeof(StrictStringEnumConverter<DictationAction>))]
public enum DictationAction
{
    [JsonStringEnumMemberName("begin")] Begin,
    [JsonStringEnumMemberName("commit")] Commit,
    [JsonStringEnumMemberName("cancel")] Cancel,
}

/// <summary>Swift <c>MicAudioFormat: UInt8</c>; a number in JSON, a byte in <c>micAudio</c>.</summary>
public enum MicAudioFormat : byte
{
    Pcm16LE16k = 0,
}

public sealed record DictationControl : IMessage
{
    MessageKind IMessage.Kind => MessageKind.DictationControl;
    [JsonPropertyName("action")] public required DictationAction Action { get; init; }
    [JsonPropertyName("id")] public required Guid Id { get; init; }
    /// <summary>A <c>DictationEngineID</c>: a plain string.</summary>
    [JsonPropertyName("engine")] public string? Engine { get; init; }
    [JsonPropertyName("language")] public string? Language { get; init; }
    [JsonPropertyName("format")] public MicAudioFormat? Format { get; init; }
}

public sealed record DictationResult : IMessage
{
    MessageKind IMessage.Kind => MessageKind.DictationResult;
    [JsonPropertyName("id")] public required Guid Id { get; init; }
    [JsonPropertyName("text")] public required string Text { get; init; }
    [JsonPropertyName("isFinal")] public required bool IsFinal { get; init; }
    [JsonPropertyName("engine")] public string? Engine { get; init; }
    [JsonPropertyName("error")] public string? Error { get; init; }
}
