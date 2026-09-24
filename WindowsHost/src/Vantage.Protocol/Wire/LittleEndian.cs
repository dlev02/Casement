using System.Buffers.Binary;

namespace Vantage.Protocol.Wire;

/// <summary>
/// Little-endian reader for hot-path payloads (<c>Wire/BinaryCoding.swift</c>). Throws
/// <see cref="WireFormatException"/> on truncation; trailing bytes are the caller's to ignore,
/// as the Swift decoders do.
/// </summary>
public ref struct LittleEndianReader(ReadOnlySpan<byte> data)
{
    private readonly ReadOnlySpan<byte> _data = data;
    private int _offset;

    public readonly int Offset => _offset;
    public readonly int Remaining => _data.Length - _offset;

    private ReadOnlySpan<byte> Take(int count)
    {
        if (Remaining < count) throw new WireFormatException($"Truncated payload: needed {count} bytes, {Remaining} left.");
        var slice = _data.Slice(_offset, count);
        _offset += count;
        return slice;
    }

    public byte ReadByte() => Take(1)[0];
    /// <summary>Any non-zero byte is true.</summary>
    public bool ReadBool() => ReadByte() != 0;
    public ushort ReadUInt16() => BinaryPrimitives.ReadUInt16LittleEndian(Take(2));
    public uint ReadUInt32() => BinaryPrimitives.ReadUInt32LittleEndian(Take(4));
    public ulong ReadUInt64() => BinaryPrimitives.ReadUInt64LittleEndian(Take(8));
    public int ReadInt32() => BinaryPrimitives.ReadInt32LittleEndian(Take(4));
    public float ReadSingle() => BinaryPrimitives.ReadSingleLittleEndian(Take(4));
    public double ReadDouble() => BinaryPrimitives.ReadDoubleLittleEndian(Take(8));

    /// <summary>A UUID stored as its 16 bytes in RFC 4122 order (the printed order).</summary>
    public Guid ReadUuid() => new(Take(16), bigEndian: true);

    public ReadOnlySpan<byte> ReadBytes(int count) => Take(count);

    public ReadOnlySpan<byte> ReadRemaining() => Take(Remaining);

    /// <summary>Reads a byte and checks it names a defined member of <typeparamref name="TEnum"/>.</summary>
    public TEnum ReadEnum<TEnum>() where TEnum : struct, Enum
    {
        var raw = ReadByte();
        var value = (TEnum)Enum.ToObject(typeof(TEnum), raw);
        if (!Enum.IsDefined(value)) throw new WireFormatException($"Unknown {typeof(TEnum).Name} value {raw}.");
        return value;
    }
}

/// <summary>Little-endian writer into a caller-sized span (every binary layout has a known size).</summary>
public ref struct LittleEndianWriter(Span<byte> destination)
{
    private readonly Span<byte> _buffer = destination;
    private int _offset;

    public readonly int Written => _offset;

    private Span<byte> Next(int count)
    {
        if (_buffer.Length - _offset < count) throw new InvalidOperationException("LittleEndianWriter buffer too small.");
        var slice = _buffer.Slice(_offset, count);
        _offset += count;
        return slice;
    }

    public void Write(byte value) => Next(1)[0] = value;
    /// <summary>Writes 1 or 0.</summary>
    public void Write(bool value) => Next(1)[0] = value ? (byte)1 : (byte)0;
    public void Write(ushort value) => BinaryPrimitives.WriteUInt16LittleEndian(Next(2), value);
    public void Write(uint value) => BinaryPrimitives.WriteUInt32LittleEndian(Next(4), value);
    public void Write(ulong value) => BinaryPrimitives.WriteUInt64LittleEndian(Next(8), value);
    public void Write(int value) => BinaryPrimitives.WriteInt32LittleEndian(Next(4), value);
    public void Write(float value) => BinaryPrimitives.WriteSingleLittleEndian(Next(4), value);
    public void Write(double value) => BinaryPrimitives.WriteDoubleLittleEndian(Next(8), value);

    /// <summary>Writes the 16 bytes of a UUID in RFC 4122 order. Never <c>Guid.ToByteArray()</c>.</summary>
    public void WriteUuid(Guid value)
    {
        if (!value.TryWriteBytes(Next(16), bigEndian: true, out _)) throw new InvalidOperationException("Couldn't write a UUID.");
    }

    public void WriteBytes(ReadOnlySpan<byte> value) => value.CopyTo(Next(value.Length));
}
