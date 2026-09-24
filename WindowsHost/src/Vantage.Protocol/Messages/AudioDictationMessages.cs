using System.Text.Json.Serialization;

namespace Vantage.Protocol.Messages;

// Mac-only features (AudioMessages.swift, DictationMessages.swift). A Windows v1 host never
// advertises `audio` or `dictationEngines`, so these never arrive; they're here so the codec
// knows every kind and the golden vectors cover them.

public sealed record AudioRequest : IMessage
{
    MessageKind IMessage.Kind => MessageKind.AudioRequest;
    [JsonPropertyName("enabled")] public required bool Enabled { get; init; }
    [JsonPropertyName("muteMacOutput")] public bool? MuteMacOutput { get; init; }
}

public sealed record AudioConfig : IMessage
{
    MessageKind IMessage.Kind => MessageKind.AudioConfig;
    [JsonPropertyName("codec")] public required string Codec { get; init; }
    [JsonPropertyName("sampleRate")] public required int SampleRate { get; init; }
    [JsonPropertyName("channels")] public required int Channels { get; init; }
    [JsonPropertyName("framesPerPacket")] public required int FramesPerPacket { get; init; }
    [JsonPropertyName("bitrate")] public required int Bitrate { get; init; }
    [JsonPropertyName("unavailable")] public string? Unavailable { get; init; }
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
