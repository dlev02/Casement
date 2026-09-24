using System.Text.Json.Serialization;

namespace Vantage.Protocol.Messages;

// File channel messages (Messages/FileTransferMessages.swift). Only ever on the file channel.
// One file: sender fileOffer → receiver fileAccept (or rejection) → sender chunks in order →
// sender fileComplete{sha256} → receiver fileResult. Either side may fileCancel at any point.

public sealed record FileOffer : IMessage
{
    MessageKind IMessage.Kind => MessageKind.FileOffer;
    /// <summary>Written as an uppercase UUID string.</summary>
    [JsonPropertyName("id")] public required Guid Id { get; init; }
    /// <summary>Untrusted; the receiver sanitises it.</summary>
    [JsonPropertyName("name")] public required string Name { get; init; }
    [JsonPropertyName("byteCount")] public required ulong ByteCount { get; init; }
    /// <summary>On the wire: seconds since 2001-01-01T00:00:00Z (Swift's default Date coding).</summary>
    [JsonPropertyName("modified")]
    [JsonConverter(typeof(AppleReferenceDateJsonConverter))]
    public DateTimeOffset? Modified { get; init; }
    /// <summary>Uniform type identifier, when known (e.g. "com.adobe.pdf").</summary>
    [JsonPropertyName("uti")] public string? Uti { get; init; }
}

public sealed record FileAccept : IMessage
{
    MessageKind IMessage.Kind => MessageKind.FileAccept;
    [JsonPropertyName("id")] public required Guid Id { get; init; }
    /// <summary>Required on the wire: 0 for a fresh file (or a rejection), else the kept partial's size.</summary>
    [JsonPropertyName("resumeOffset")] public required ulong ResumeOffset { get; init; }
    /// <summary>A user-facing reason; present means refused.</summary>
    [JsonPropertyName("rejected")] public string? Rejected { get; init; }
}

public sealed record FileComplete : IMessage
{
    MessageKind IMessage.Kind => MessageKind.FileComplete;
    [JsonPropertyName("id")] public required Guid Id { get; init; }
    /// <summary>SHA-256 of the whole file (a resumed prefix included).</summary>
    [JsonPropertyName("sha256")] public required byte[] Sha256 { get; init; }
}

public sealed record FileResult : IMessage
{
    MessageKind IMessage.Kind => MessageKind.FileResult;
    [JsonPropertyName("id")] public required Guid Id { get; init; }
    [JsonPropertyName("ok")] public required bool Ok { get; init; }
    [JsonPropertyName("savedName")] public string? SavedName { get; init; }
    [JsonPropertyName("error")] public string? Error { get; init; }
}

public sealed record FileCancel : IMessage
{
    MessageKind IMessage.Kind => MessageKind.FileCancel;
    [JsonPropertyName("id")] public required Guid Id { get; init; }
}
