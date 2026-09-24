using System.Buffers.Binary;
using Vantage.Protocol.Messages;

namespace Vantage.Protocol.Wire;

/// <summary>
/// Wire framing (<c>Wire/Frame.swift</c>): every message is an 8-byte header followed by
/// <c>length</c> payload bytes. All header integers are little-endian.
/// <code>
/// 0      1      2        4                8
/// | 'V'  | kind | flags  | payload length |  payload...
/// </code>
/// </summary>
public static class Frame
{
    public const byte Magic = 0x56; // 'V'
    public const int HeaderLength = 8;
    /// <summary>Hard cap on one payload (32 MiB). Anything larger is <c>payloadTooLarge</c>: close.</summary>
    public const uint MaxPayloadLength = 32 * 1024 * 1024;

    /// <summary>Writes a header into the first 8 bytes of <paramref name="destination"/>.</summary>
    public static void WriteHeader(Span<byte> destination, byte kind, uint length, ushort flags = 0)
    {
        if (destination.Length < HeaderLength) throw new ArgumentException("Header needs 8 bytes.", nameof(destination));
        destination[0] = Magic;
        destination[1] = kind;
        BinaryPrimitives.WriteUInt16LittleEndian(destination[2..], flags);
        BinaryPrimitives.WriteUInt32LittleEndian(destination[4..], length);
    }

    /// <summary>
    /// Parses a header. Throws <see cref="FrameException"/> for a bad magic byte or an oversized
    /// payload. An unknown kind is <em>not</em> an error here (the Windows host skips those); check
    /// <see cref="FrameHeader.IsKnownKind"/>.
    /// </summary>
    public static FrameHeader ReadHeader(ReadOnlySpan<byte> source)
    {
        if (source.Length < HeaderLength) throw new WireFormatException($"Truncated frame header ({source.Length} of 8 bytes).");
        if (source[0] != Magic) throw new FrameException(FrameError.BadMagic, $"Bad magic 0x{source[0]:X2}.");
        var kind = source[1];
        var flags = BinaryPrimitives.ReadUInt16LittleEndian(source[2..]);
        var length = BinaryPrimitives.ReadUInt32LittleEndian(source[4..]);
        if (length > MaxPayloadLength) throw new FrameException(FrameError.PayloadTooLarge, $"Payload of {length} bytes is over the 32 MiB limit.");
        return new FrameHeader(kind, flags, length);
    }

    /// <summary>One allocation holding header + payload, ready to write to the socket.</summary>
    public static byte[] Encode(MessageKind kind, ReadOnlySpan<byte> payload)
    {
        var frame = new byte[HeaderLength + payload.Length];
        WriteHeader(frame, (byte)kind, (uint)payload.Length);
        payload.CopyTo(frame.AsSpan(HeaderLength));
        return frame;
    }
}

/// <summary>A decoded frame header. <see cref="RawKind"/> may be a kind this build doesn't know.</summary>
public readonly record struct FrameHeader(byte RawKind, ushort Flags, uint Length)
{
    public bool IsKnownKind => Enum.IsDefined(typeof(MessageKind), RawKind);
    public MessageKind Kind => (MessageKind)RawKind;
}

public enum FrameError
{
    BadMagic,
    UnknownKind,
    PayloadTooLarge,
}

/// <summary>A framing error: the connection must be closed.</summary>
public sealed class FrameException(FrameError error, string message) : Exception(message)
{
    public FrameError Error { get; } = error;
}

/// <summary>A payload that is truncated or otherwise malformed (Swift's <c>BinaryDecodingError</c>).</summary>
public sealed class WireFormatException(string message, Exception? inner = null) : Exception(message, inner);
