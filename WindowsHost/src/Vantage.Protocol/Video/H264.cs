using System.Buffers.Binary;

namespace Vantage.Protocol.Video;

/// <summary>H.264 NAL unit types the host cares about.</summary>
public static class NalType
{
    public const int Slice = 1;
    public const int Idr = 5;
    public const int Sei = 6;
    public const int Sps = 7;
    public const int Pps = 8;
    public const int AccessUnitDelimiter = 9;

    /// <summary><c>nal_unit_type</c> of a NAL unit (its first byte's low 5 bits).</summary>
    public static int Of(ReadOnlySpan<byte> nal) => nal.IsEmpty ? -1 : nal[0] & 0x1F;
}

/// <summary>One access unit split for the wire: slices as AVCC, parameter sets on the side.</summary>
/// <param name="Avcc">Every kept NAL unit behind a 4-byte big-endian length (the <c>videoFrame</c> data).</param>
/// <param name="Sps">The SPS inside the AU, if any.</param>
/// <param name="Pps">The PPS inside the AU, if any.</param>
/// <param name="IsKeyframe">The AU holds an IDR slice.</param>
public sealed record AccessUnit(byte[] Avcc, byte[]? Sps, byte[]? Pps, bool IsKeyframe);

/// <summary>Annex-B ↔ AVCC conversion for H.264 (spec §6 videoFrame, §5.2 VideoConfig).</summary>
public static class AnnexB
{
    /// <summary>
    /// Splits Annex-B data (3- or 4-byte start codes) into NAL units, without start codes and
    /// without the zero bytes that trail a unit before the next 4-byte start code.
    /// </summary>
    public static List<ReadOnlyMemory<byte>> SplitNalUnits(ReadOnlyMemory<byte> data)
    {
        var units = new List<ReadOnlyMemory<byte>>();
        var span = data.Span;
        var start = -1;
        var i = 0;
        while (i + 2 < span.Length)
        {
            if (span[i] == 0 && span[i + 1] == 0 && span[i + 2] == 1)
            {
                if (start >= 0) units.Add(Trim(data[start..i]));
                i += 3;
                start = i;
                continue;
            }
            i++;
        }
        if (start >= 0 && start < span.Length) units.Add(Trim(data[start..]));
        units.RemoveAll(u => u.IsEmpty);
        return units;

        static ReadOnlyMemory<byte> Trim(ReadOnlyMemory<byte> unit)
        {
            var end = unit.Length;
            while (end > 0 && unit.Span[end - 1] == 0) end--;
            return unit[..end];
        }
    }

    /// <summary>Splits AVCC data (4-byte big-endian lengths) into NAL units. Throws on a length past the end.</summary>
    public static List<ReadOnlyMemory<byte>> SplitAvcc(ReadOnlyMemory<byte> data)
    {
        var units = new List<ReadOnlyMemory<byte>>();
        var offset = 0;
        while (offset < data.Length)
        {
            if (data.Length - offset < 4) throw new FormatException("Truncated AVCC length.");
            var length = (int)BinaryPrimitives.ReadUInt32BigEndian(data.Span[offset..]);
            offset += 4;
            if (length < 0 || length > data.Length - offset) throw new FormatException("AVCC length past the end.");
            units.Add(data.Slice(offset, length));
            offset += length;
        }
        return units;
    }

    /// <summary>
    /// Converts one Annex-B access unit for the wire: SPS and PPS are pulled out (they travel in
    /// <c>videoConfig</c>), AUD is dropped, SEI is dropped unless <paramref name="keepSei"/>, and the
    /// rest is written as AVCC.
    /// </summary>
    public static AccessUnit ToAccessUnit(ReadOnlyMemory<byte> annexB, bool keepSei = false) =>
        FromUnits(SplitNalUnits(annexB), keepSei);

    /// <summary>The same for units already split (AVCC input from an encoder).</summary>
    public static AccessUnit FromUnits(IReadOnlyList<ReadOnlyMemory<byte>> units, bool keepSei = false)
    {
        byte[]? sps = null, pps = null;
        var keyframe = false;
        var kept = new List<ReadOnlyMemory<byte>>(units.Count);
        foreach (var unit in units)
        {
            switch (NalType.Of(unit.Span))
            {
                case NalType.Sps: sps ??= unit.ToArray(); break;
                case NalType.Pps: pps ??= unit.ToArray(); break;
                case NalType.AccessUnitDelimiter: break;
                case NalType.Sei when !keepSei: break;
                case NalType.Idr:
                    keyframe = true;
                    kept.Add(unit);
                    break;
                default: kept.Add(unit); break;
            }
        }
        return new AccessUnit(ToAvcc(kept), sps, pps, keyframe);
    }

    /// <summary>Writes NAL units as AVCC (4-byte big-endian length before each).</summary>
    public static byte[] ToAvcc(IReadOnlyList<ReadOnlyMemory<byte>> units)
    {
        var total = 0;
        foreach (var unit in units) total += 4 + unit.Length;
        var output = new byte[total];
        var offset = 0;
        foreach (var unit in units)
        {
            BinaryPrimitives.WriteUInt32BigEndian(output.AsSpan(offset), (uint)unit.Length);
            unit.Span.CopyTo(output.AsSpan(offset + 4));
            offset += 4 + unit.Length;
        }
        return output;
    }

    /// <summary>AVCC back to Annex-B with 4-byte start codes (tests, dumps).</summary>
    public static byte[] FromAvcc(ReadOnlyMemory<byte> avcc)
    {
        using var stream = new MemoryStream();
        foreach (var unit in SplitAvcc(avcc))
        {
            stream.Write([0, 0, 0, 1]);
            stream.Write(unit.Span);
        }
        return stream.ToArray();
    }

    /// <summary>Whether AVCC data holds an IDR slice.</summary>
    public static bool AvccHasIdr(ReadOnlyMemory<byte> avcc) =>
        SplitAvcc(avcc).Exists(u => NalType.Of(u.Span) == NalType.Idr);

    /// <summary>
    /// Splits an Annex-B elementary stream into access units: a new AU starts at an AUD, or at an
    /// SPS/PPS/SEI or a slice with <c>first_mb_in_slice == 0</c> after the previous AU had a slice.
    /// Enough for encoder output and the synthetic host's clip.
    /// </summary>
    public static List<byte[]> SplitAccessUnits(ReadOnlyMemory<byte> stream)
    {
        var result = new List<byte[]>();
        var current = new List<ReadOnlyMemory<byte>>();
        var hasSlice = false;
        foreach (var unit in SplitNalUnits(stream))
        {
            var type = NalType.Of(unit.Span);
            var isSlice = type is NalType.Slice or NalType.Idr;
            var startsNew = hasSlice && (type is NalType.AccessUnitDelimiter or NalType.Sps or NalType.Pps or NalType.Sei
                                         || (isSlice && unit.Length > 1 && (unit.Span[1] & 0x80) != 0));
            if (startsNew)
            {
                result.Add(Join(current));
                current.Clear();
                hasSlice = false;
            }
            current.Add(unit);
            hasSlice |= isSlice;
        }
        if (current.Count > 0) result.Add(Join(current));
        return result;

        static byte[] Join(List<ReadOnlyMemory<byte>> units)
        {
            using var stream = new MemoryStream();
            foreach (var unit in units)
            {
                stream.Write([0, 0, 0, 1]);
                stream.Write(unit.Span);
            }
            return stream.ToArray();
        }
    }
}
