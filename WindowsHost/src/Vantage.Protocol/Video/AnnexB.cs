using System.Buffers.Binary;
using Vantage.Protocol.Messages;

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

    /// <summary><c>nal_unit_type</c> of a NAL unit of <paramref name="codec"/>.</summary>
    public static int Of(ReadOnlySpan<byte> nal, VideoCodec codec) => codec == VideoCodec.Hevc ? HevcNalType.Of(nal) : Of(nal);
}

/// <summary>
/// HEVC (H.265) NAL unit types the host cares about. HEVC's NAL header is two bytes, with the type
/// in bits 1–6 of the first (ITU-T H.265 §7.3.1.2).
/// </summary>
public static class HevcNalType
{
    /// <summary>The first IRAP type (BLA_W_LP); 16–21 are the random-access pictures an encoder emits.</summary>
    public const int BlaWLp = 16;
    public const int IdrWRadl = 19;
    public const int IdrNLp = 20;
    public const int Cra = 21;
    public const int Vps = 32;
    public const int Sps = 33;
    public const int Pps = 34;
    public const int AccessUnitDelimiter = 35;
    public const int PrefixSei = 39;
    public const int SuffixSei = 40;

    /// <summary><c>nal_unit_type</c> of an HEVC NAL unit.</summary>
    public static int Of(ReadOnlySpan<byte> nal) => nal.IsEmpty ? -1 : (nal[0] >> 1) & 0x3F;

    /// <summary>A coded slice (VCL, types 0–31).</summary>
    public static bool IsSlice(int type) => type is >= 0 and <= 31;

    /// <summary>
    /// An intra random-access point (BLA, IDR, CRA). With no reordering (no B-frames, so no leading
    /// pictures) any of them starts a decodable stream, so each counts as a keyframe.
    /// </summary>
    public static bool IsRandomAccess(int type) => type is >= BlaWLp and <= Cra;
}

/// <summary>
/// One access unit split for the wire: slices as AVCC (HEVC's HVCC framing is the same 4-byte
/// lengths), parameter sets on the side.
/// </summary>
/// <param name="Avcc">Every kept NAL unit behind a 4-byte big-endian length (the <c>videoFrame</c> data).</param>
/// <param name="Sps">The SPS inside the AU, if any.</param>
/// <param name="Pps">The PPS inside the AU, if any.</param>
/// <param name="IsKeyframe">The AU holds an IDR slice (HEVC: an IRAP slice).</param>
/// <param name="Vps">HEVC only: the VPS inside the AU, if any.</param>
public sealed record AccessUnit(byte[] Avcc, byte[]? Sps, byte[]? Pps, bool IsKeyframe, byte[]? Vps = null)
{
    /// <summary>
    /// The parameter sets for <c>videoConfig</c> in wire order, or null if the AU lacks any of them:
    /// H.264 <c>[SPS, PPS]</c>, HEVC <c>[VPS, SPS, PPS]</c>.
    /// </summary>
    public byte[][]? ParameterSets(VideoCodec codec) => codec == VideoCodec.Hevc
        ? Vps is not null && Sps is not null && Pps is not null ? [Vps, Sps, Pps] : null
        : Sps is not null && Pps is not null ? [Sps, Pps] : null;
}

/// <summary>
/// Annex-B ↔ AVCC conversion for H.264 and HEVC (spec §6 videoFrame, §5.2 VideoConfig). The
/// overloads without a codec are H.264.
/// </summary>
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
    /// Converts one H.264 Annex-B access unit for the wire: SPS and PPS are pulled out (they travel
    /// in <c>videoConfig</c>), AUD is dropped, SEI is dropped unless <paramref name="keepSei"/>, and
    /// the rest is written as AVCC.
    /// </summary>
    public static AccessUnit ToAccessUnit(ReadOnlyMemory<byte> annexB, bool keepSei = false) =>
        FromUnits(SplitNalUnits(annexB), keepSei);

    /// <summary>
    /// The same for <paramref name="codec"/>. HEVC: VPS, SPS and PPS are pulled out, AUD is dropped,
    /// and prefix and suffix SEI are dropped unless <paramref name="keepSei"/>.
    /// </summary>
    public static AccessUnit ToAccessUnit(ReadOnlyMemory<byte> annexB, VideoCodec codec, bool keepSei = false) =>
        FromUnits(SplitNalUnits(annexB), codec, keepSei);

    /// <summary>The same for H.264 units already split (AVCC input from an encoder).</summary>
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

    /// <summary>The same for units of <paramref name="codec"/> already split.</summary>
    public static AccessUnit FromUnits(IReadOnlyList<ReadOnlyMemory<byte>> units, VideoCodec codec, bool keepSei = false)
    {
        if (codec != VideoCodec.Hevc) return FromUnits(units, keepSei);
        byte[]? vps = null, sps = null, pps = null;
        var keyframe = false;
        var kept = new List<ReadOnlyMemory<byte>>(units.Count);
        foreach (var unit in units)
        {
            var type = HevcNalType.Of(unit.Span);
            switch (type)
            {
                case HevcNalType.Vps: vps ??= unit.ToArray(); break;
                case HevcNalType.Sps: sps ??= unit.ToArray(); break;
                case HevcNalType.Pps: pps ??= unit.ToArray(); break;
                case HevcNalType.AccessUnitDelimiter: break;
                case HevcNalType.PrefixSei or HevcNalType.SuffixSei when !keepSei: break;
                default:
                    keyframe |= HevcNalType.IsRandomAccess(type);
                    kept.Add(unit);
                    break;
            }
        }
        return new AccessUnit(ToAvcc(kept), sps, pps, keyframe, vps);
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

    /// <summary>Whether H.264 AVCC data holds an IDR slice.</summary>
    public static bool AvccHasIdr(ReadOnlyMemory<byte> avcc) =>
        SplitAvcc(avcc).Exists(u => NalType.Of(u.Span) == NalType.Idr);

    /// <summary>Whether AVCC data of <paramref name="codec"/> holds an IDR slice (HEVC: an IRAP slice).</summary>
    public static bool AvccHasIdr(ReadOnlyMemory<byte> avcc, VideoCodec codec) => codec == VideoCodec.Hevc
        ? SplitAvcc(avcc).Exists(u => HevcNalType.IsRandomAccess(HevcNalType.Of(u.Span)))
        : AvccHasIdr(avcc);

    /// <summary>
    /// Splits an H.264 Annex-B elementary stream into access units: a new AU starts at an AUD, or at
    /// an SPS/PPS/SEI or a slice with <c>first_mb_in_slice == 0</c> after the previous AU had a
    /// slice. Enough for encoder output and the synthetic host's clip.
    /// </summary>
    public static List<byte[]> SplitAccessUnits(ReadOnlyMemory<byte> stream) => SplitAccessUnits(stream, VideoCodec.H264);

    /// <summary>
    /// The same for <paramref name="codec"/>. HEVC: a new AU starts at an AUD, VPS, SPS, PPS or
    /// prefix SEI, or at a slice with <c>first_slice_segment_in_pic_flag</c> set (the top bit after
    /// the two-byte header), once the previous AU had a slice.
    /// </summary>
    public static List<byte[]> SplitAccessUnits(ReadOnlyMemory<byte> stream, VideoCodec codec)
    {
        var hevc = codec == VideoCodec.Hevc;
        var result = new List<byte[]>();
        var current = new List<ReadOnlyMemory<byte>>();
        var hasSlice = false;
        foreach (var unit in SplitNalUnits(stream))
        {
            bool isSlice, startsNew;
            if (hevc)
            {
                var type = HevcNalType.Of(unit.Span);
                isSlice = HevcNalType.IsSlice(type);
                startsNew = hasSlice && (type is HevcNalType.AccessUnitDelimiter or HevcNalType.Vps or HevcNalType.Sps or HevcNalType.Pps
                                             or HevcNalType.PrefixSei
                                         || (isSlice && unit.Length > 2 && (unit.Span[2] & 0x80) != 0));
            }
            else
            {
                var type = NalType.Of(unit.Span);
                isSlice = type is NalType.Slice or NalType.Idr;
                startsNew = hasSlice && (type is NalType.AccessUnitDelimiter or NalType.Sps or NalType.Pps or NalType.Sei
                                         || (isSlice && unit.Length > 1 && (unit.Span[1] & 0x80) != 0));
            }
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
