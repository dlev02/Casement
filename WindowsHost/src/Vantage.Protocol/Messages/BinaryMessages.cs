using Vantage.Protocol.Wire;

namespace Vantage.Protocol.Messages;

// Hot-path binary messages (Messages/BinaryMessages.swift, spec §6). Little-endian throughout;
// decoders ignore trailing bytes and throw WireFormatException on truncation or an unknown enum byte.

/// <summary>A message with a packed binary layout.</summary>
public interface IBinaryMessage : IMessage
{
    /// <summary>Payload size in bytes (no frame header).</summary>
    int EncodedLength { get; }

    /// <summary>Writes exactly <see cref="EncodedLength"/> bytes.</summary>
    void Encode(Span<byte> destination);
}

/// <summary>
/// Kind 100: one encoded access unit. 25-byte header, then the AU in AVCC form: each NAL unit
/// behind a 4-byte <em>big-endian</em> length, no start codes, no SPS/PPS/AUD (those travel in
/// <c>videoConfig</c>).
/// </summary>
public sealed record VideoFrame : IBinaryMessage
{
    public const int HeaderLength = 25;
    MessageKind IMessage.Kind => MessageKind.VideoFrame;

    /// <summary>Per encoder, from 0, +1 per frame.</summary>
    public required ulong Sequence { get; init; }
    /// <summary>Host monotonic nanoseconds (the client ignores it today).</summary>
    public required ulong CaptureNanos { get; init; }
    /// <summary>The AU holds an IDR (H.264 NAL type 5).</summary>
    public required bool IsKeyframe { get; init; }
    public required uint Width { get; init; }
    public required uint Height { get; init; }
    public required ReadOnlyMemory<byte> Data { get; init; }

    public int EncodedLength => HeaderLength + Data.Length;

    public void Encode(Span<byte> destination)
    {
        var writer = new LittleEndianWriter(destination);
        writer.Write(Sequence);
        writer.Write(CaptureNanos);
        writer.Write(IsKeyframe);
        writer.Write(Width);
        writer.Write(Height);
        writer.WriteBytes(Data.Span);
    }

    /// <summary>Decodes; <see cref="Data"/> slices <paramref name="payload"/> (no copy).</summary>
    public static VideoFrame Decode(ReadOnlyMemory<byte> payload)
    {
        var reader = new LittleEndianReader(payload.Span);
        return new VideoFrame
        {
            Sequence = reader.ReadUInt64(),
            CaptureNanos = reader.ReadUInt64(),
            IsKeyframe = reader.ReadBool(),
            Width = reader.ReadUInt32(),
            Height = reader.ReadUInt32(),
            Data = payload[reader.Offset..],
        };
    }
}

/// <summary>Kind 101, 9 bytes. Not sent by Windows v1.</summary>
public sealed record CursorPosition : IBinaryMessage
{
    MessageKind IMessage.Kind => MessageKind.CursorPosition;
    public required float X { get; init; }
    public required float Y { get; init; }
    public required bool IsVisible { get; init; }

    public int EncodedLength => 9;

    public void Encode(Span<byte> destination)
    {
        var writer = new LittleEndianWriter(destination);
        writer.Write(X);
        writer.Write(Y);
        writer.Write(IsVisible);
    }

    public static CursorPosition Decode(ReadOnlySpan<byte> payload)
    {
        var reader = new LittleEndianReader(payload);
        return new CursorPosition { X = reader.ReadSingle(), Y = reader.ReadSingle(), IsVisible = reader.ReadBool() };
    }
}

public enum PointerButton : byte
{
    Left = 0,
    Right = 1,
    Middle = 2,
    Back = 3,
    Forward = 4,
}

public enum PointerAction : byte
{
    /// <summary>Move, or drag the held button.</summary>
    Move = 0,
    Down = 1,
    Up = 2,
}

/// <summary>
/// Kind 120, 15 bytes. <see cref="X"/>/<see cref="Y"/> are in the streamed display's point space
/// (0…pointWidth, 0…pointHeight, origin top-left).
/// </summary>
public sealed record PointerEvent : IBinaryMessage
{
    MessageKind IMessage.Kind => MessageKind.PointerEvent;
    public required PointerAction Action { get; init; }
    public PointerButton Button { get; init; } = PointerButton.Left;
    public required float X { get; init; }
    public required float Y { get; init; }
    /// <summary>Informational (≥ 1); Windows derives double-clicks from timing.</summary>
    public byte ClickCount { get; init; } = 1;
    public KeyModifiers Modifiers { get; init; }

    public int EncodedLength => 15;

    public void Encode(Span<byte> destination)
    {
        var writer = new LittleEndianWriter(destination);
        writer.Write((byte)Action);
        writer.Write((byte)Button);
        writer.Write(X);
        writer.Write(Y);
        writer.Write(ClickCount);
        writer.Write((uint)Modifiers);
    }

    public static PointerEvent Decode(ReadOnlySpan<byte> payload)
    {
        var reader = new LittleEndianReader(payload);
        return new PointerEvent
        {
            Action = reader.ReadEnum<PointerAction>(),
            Button = reader.ReadEnum<PointerButton>(),
            X = reader.ReadSingle(),
            Y = reader.ReadSingle(),
            ClickCount = reader.ReadByte(),
            Modifiers = (KeyModifiers)reader.ReadUInt32(),
        };
    }
}

public enum ScrollPhase : byte
{
    None = 0,
    Began = 1,
    Changed = 2,
    Ended = 3,
    Cancelled = 4,
}

public enum MomentumPhase : byte
{
    None = 0,
    Began = 1,
    Changed = 2,
    Ended = 3,
}

/// <summary>
/// Kind 121, 31 bytes. Continuous (trackpad) deltas are points; discrete (wheel) deltas are lines
/// (translation ÷ 10 points). Natural scrolling is already applied by the client.
/// </summary>
public sealed record ScrollEvent : IBinaryMessage
{
    MessageKind IMessage.Kind => MessageKind.ScrollEvent;
    public required ScrollPhase Phase { get; init; }
    public MomentumPhase Momentum { get; init; }
    public required bool IsContinuous { get; init; }
    public required float DeltaX { get; init; }
    public required float DeltaY { get; init; }
    public required float X { get; init; }
    public required float Y { get; init; }
    /// <summary>Points per second, only on <see cref="ScrollPhase.Ended"/>.</summary>
    public float VelocityX { get; init; }
    public float VelocityY { get; init; }
    public KeyModifiers Modifiers { get; init; }

    public int EncodedLength => 31;

    public void Encode(Span<byte> destination)
    {
        var writer = new LittleEndianWriter(destination);
        writer.Write((byte)Phase);
        writer.Write((byte)Momentum);
        writer.Write(IsContinuous);
        writer.Write(DeltaX);
        writer.Write(DeltaY);
        writer.Write(X);
        writer.Write(Y);
        writer.Write(VelocityX);
        writer.Write(VelocityY);
        writer.Write((uint)Modifiers);
    }

    public static ScrollEvent Decode(ReadOnlySpan<byte> payload)
    {
        var reader = new LittleEndianReader(payload);
        return new ScrollEvent
        {
            Phase = reader.ReadEnum<ScrollPhase>(),
            Momentum = reader.ReadEnum<MomentumPhase>(),
            IsContinuous = reader.ReadBool(),
            DeltaX = reader.ReadSingle(),
            DeltaY = reader.ReadSingle(),
            X = reader.ReadSingle(),
            Y = reader.ReadSingle(),
            VelocityX = reader.ReadSingle(),
            VelocityY = reader.ReadSingle(),
            Modifiers = (KeyModifiers)reader.ReadUInt32(),
        };
    }
}

/// <summary>Kind 122, 8 bytes. <see cref="KeyCode"/> is a <b>macOS virtual key code (kVK)</b>, not a HID usage.</summary>
public sealed record KeyEvent : IBinaryMessage
{
    MessageKind IMessage.Kind => MessageKind.KeyEvent;
    public required ushort KeyCode { get; init; }
    public required bool IsDown { get; init; }
    public KeyModifiers Modifiers { get; init; }
    public bool IsRepeat { get; init; }

    public int EncodedLength => 8;

    public void Encode(Span<byte> destination)
    {
        var writer = new LittleEndianWriter(destination);
        writer.Write(KeyCode);
        writer.Write(IsDown);
        writer.Write((uint)Modifiers);
        writer.Write(IsRepeat);
    }

    public static KeyEvent Decode(ReadOnlySpan<byte> payload)
    {
        var reader = new LittleEndianReader(payload);
        return new KeyEvent
        {
            KeyCode = reader.ReadUInt16(),
            IsDown = reader.ReadBool(),
            Modifiers = (KeyModifiers)reader.ReadUInt32(),
            IsRepeat = reader.ReadBool(),
        };
    }
}

/// <summary>Kind 102: <c>seq u64 | captureNanos u64 | frameCount u16 | opus…</c>. Never sent by Windows v1.</summary>
public sealed record AudioPacket : IBinaryMessage
{
    public const int HeaderLength = 18;
    MessageKind IMessage.Kind => MessageKind.AudioPacket;
    public required ulong Sequence { get; init; }
    public required ulong CaptureNanos { get; init; }
    public required ushort FrameCount { get; init; }
    public required ReadOnlyMemory<byte> Data { get; init; }

    public int EncodedLength => HeaderLength + Data.Length;

    public void Encode(Span<byte> destination)
    {
        var writer = new LittleEndianWriter(destination);
        writer.Write(Sequence);
        writer.Write(CaptureNanos);
        writer.Write(FrameCount);
        writer.WriteBytes(Data.Span);
    }

    public static AudioPacket Decode(ReadOnlyMemory<byte> payload)
    {
        var reader = new LittleEndianReader(payload.Span);
        return new AudioPacket
        {
            Sequence = reader.ReadUInt64(),
            CaptureNanos = reader.ReadUInt64(),
            FrameCount = reader.ReadUInt16(),
            Data = payload[reader.Offset..],
        };
    }
}

/// <summary>Kind 123: <c>dictationID 16 B | seq u32 | format u8 | pcm…</c>. Parse-only on Windows v1.</summary>
public sealed record MicAudio : IBinaryMessage
{
    public const int HeaderLength = 21;
    MessageKind IMessage.Kind => MessageKind.MicAudio;
    public required Guid DictationId { get; init; }
    public required uint Sequence { get; init; }
    public MicAudioFormat Format { get; init; } = MicAudioFormat.Pcm16LE16k;
    public required ReadOnlyMemory<byte> Samples { get; init; }

    public int EncodedLength => HeaderLength + Samples.Length;

    public void Encode(Span<byte> destination)
    {
        var writer = new LittleEndianWriter(destination);
        writer.WriteUuid(DictationId);
        writer.Write(Sequence);
        writer.Write((byte)Format);
        writer.WriteBytes(Samples.Span);
    }

    public static MicAudio Decode(ReadOnlyMemory<byte> payload)
    {
        var reader = new LittleEndianReader(payload.Span);
        return new MicAudio
        {
            DictationId = reader.ReadUuid(),
            Sequence = reader.ReadUInt32(),
            Format = reader.ReadEnum<MicAudioFormat>(),
            Samples = payload[reader.Offset..],
        };
    }
}

/// <summary>
/// Kinds 103 (host → client) and 124 (client → host): <c>id 16 B (RFC order) | offset u64 | bytes</c>.
/// </summary>
public sealed record FileChunk : IBinaryMessage
{
    public const int HeaderLength = 24;
    /// <summary>What senders put in one chunk: 256 KiB, except the last.</summary>
    public const int StandardSize = 256 * 1024;

    /// <summary>True for <see cref="MessageKind.FileChunkToHost"/> (124), false for <see cref="MessageKind.FileChunkToClient"/> (103).</summary>
    public required bool ToHost { get; init; }
    public MessageKind Kind => ToHost ? MessageKind.FileChunkToHost : MessageKind.FileChunkToClient;
    public required Guid Id { get; init; }
    public required ulong Offset { get; init; }
    public required ReadOnlyMemory<byte> Data { get; init; }

    public int EncodedLength => HeaderLength + Data.Length;

    public void Encode(Span<byte> destination)
    {
        var writer = new LittleEndianWriter(destination);
        writer.WriteUuid(Id);
        writer.Write(Offset);
        writer.WriteBytes(Data.Span);
    }

    public static FileChunk Decode(ReadOnlyMemory<byte> payload, bool toHost)
    {
        var reader = new LittleEndianReader(payload.Span);
        return new FileChunk
        {
            ToHost = toHost,
            Id = reader.ReadUuid(),
            Offset = reader.ReadUInt64(),
            Data = payload[reader.Offset..],
        };
    }
}
