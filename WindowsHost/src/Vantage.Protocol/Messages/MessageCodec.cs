using System.Text.Json;
using System.Text.Json.Serialization.Metadata;
using Vantage.Protocol.Wire;

namespace Vantage.Protocol.Messages;

/// <summary>
/// Encodes and decodes message payloads and whole frames (Swift <c>Message.encodedPayload</c>,
/// <c>encodedFrame</c>, <c>decode(kind:payload:)</c>).
/// </summary>
public static class MessageCodec
{
    private static VantageJsonContext Json => VantageJsonContext.Wire;

    /// <summary>The payload bytes only (no header). <c>requestKeyframe</c> is empty.</summary>
    public static byte[] EncodePayload(IMessage message)
    {
        if (message is IBinaryMessage binary)
        {
            var buffer = new byte[binary.EncodedLength];
            binary.Encode(buffer);
            return buffer;
        }
        if (message is RequestKeyframe) return [];
        return JsonSerializer.SerializeToUtf8Bytes(message, TypeInfo(message.GetType()));
    }

    /// <summary>A complete frame (header + payload) in one allocation.</summary>
    public static byte[] EncodeFrame(IMessage message)
    {
        if (message is IBinaryMessage binary)
        {
            var frame = new byte[Frame.HeaderLength + binary.EncodedLength];
            Frame.WriteHeader(frame, (byte)message.Kind, (uint)binary.EncodedLength);
            binary.Encode(frame.AsSpan(Frame.HeaderLength));
            return frame;
        }
        return Frame.Encode(message.Kind, EncodePayload(message));
    }

    /// <summary>
    /// Decodes a payload of a known kind. Binary kinds slice <paramref name="payload"/> for their
    /// data (keep the buffer alive while the message is in use). Throws <see cref="JsonException"/>
    /// for JSON Swift would reject (missing required key, wrong type, null in a required field)
    /// and <see cref="WireFormatException"/> for a truncated binary layout or unknown enum byte.
    /// </summary>
    public static IMessage Decode(MessageKind kind, ReadOnlyMemory<byte> payload) => kind switch
    {
        MessageKind.Hello => FromJson(payload, Json.Hello),
        MessageKind.Challenge => FromJson(payload, Json.Challenge),
        MessageKind.Authenticate => FromJson(payload, Json.Authenticate),
        MessageKind.AuthResult => FromJson(payload, Json.AuthResult),
        MessageKind.DisplayList => FromJson(payload, Json.DisplayList),
        MessageKind.SelectDisplay => FromJson(payload, Json.SelectDisplay),
        MessageKind.StreamConfig => FromJson(payload, Json.StreamConfig),
        MessageKind.ViewportChanged => FromJson(payload, Json.ViewportChanged),
        MessageKind.QualityFeedback => FromJson(payload, Json.QualityFeedback),
        MessageKind.RequestKeyframe => RequestKeyframe.Instance,
        MessageKind.StreamStats => FromJson(payload, Json.StreamStats),
        MessageKind.Clipboard => FromJson(payload, Json.ClipboardPayload),
        MessageKind.HostCommand => FromJson(payload, Json.HostCommandMessage),
        MessageKind.Ping => FromJson(payload, Json.Ping),
        MessageKind.Pong => FromJson(payload, Json.Pong),
        MessageKind.Disconnect => FromJson(payload, Json.DisconnectMessage),
        MessageKind.ProtocolError => FromJson(payload, Json.ProtocolErrorMessage),
        MessageKind.AttachMedia => FromJson(payload, Json.AttachMedia),
        MessageKind.TextInput => FromJson(payload, Json.TextInput),
        MessageKind.ModifierState => FromJson(payload, Json.ModifierState),
        MessageKind.AudioRequest => FromJson(payload, Json.AudioRequest),
        MessageKind.DictationControl => FromJson(payload, Json.DictationControl),
        MessageKind.CursorShape => FromJson(payload, Json.CursorShape),
        MessageKind.VideoConfig => FromJson(payload, Json.VideoConfig),
        MessageKind.HostStatus => FromJson(payload, Json.HostStatus),
        MessageKind.AudioConfig => FromJson(payload, Json.AudioConfig),
        MessageKind.DictationResult => FromJson(payload, Json.DictationResult),
        MessageKind.FileOffer => FromJson(payload, Json.FileOffer),
        MessageKind.FileAccept => FromJson(payload, Json.FileAccept),
        MessageKind.FileComplete => FromJson(payload, Json.FileComplete),
        MessageKind.FileResult => FromJson(payload, Json.FileResult),
        MessageKind.FileCancel => FromJson(payload, Json.FileCancel),
        MessageKind.VideoFrame => VideoFrame.Decode(payload),
        MessageKind.CursorPosition => CursorPosition.Decode(payload.Span),
        MessageKind.AudioPacket => AudioPacket.Decode(payload),
        MessageKind.FileChunkToClient => FileChunk.Decode(payload, toHost: false),
        MessageKind.PointerEvent => PointerEvent.Decode(payload.Span),
        MessageKind.ScrollEvent => ScrollEvent.Decode(payload.Span),
        MessageKind.KeyEvent => KeyEvent.Decode(payload.Span),
        MessageKind.MicAudio => MicAudio.Decode(payload),
        MessageKind.FileChunkToHost => FileChunk.Decode(payload, toHost: true),
        _ => throw new FrameException(FrameError.UnknownKind, $"Unknown message kind {(byte)kind}."),
    };

    private static T FromJson<T>(ReadOnlyMemory<byte> payload, JsonTypeInfo<T> typeInfo) where T : class
    {
        // Swift rejects a JSON `null` document too.
        return JsonSerializer.Deserialize(payload.Span, typeInfo) ?? throw new JsonException($"{typeof(T).Name} payload was null.");
    }

    private static JsonTypeInfo TypeInfo(Type type) =>
        Json.GetTypeInfo(type) ?? throw new InvalidOperationException($"{type.Name} has no JSON metadata.");
}
