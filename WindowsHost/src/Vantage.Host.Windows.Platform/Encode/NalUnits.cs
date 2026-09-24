namespace Vantage.Host.Windows.Encode;

/// <summary>
/// Small H.264 Annex-B helpers for the encoder and the <c>--dump-h264</c> writer. The protocol
/// library does the real AVCC conversion; these only look at NAL types. Pure; unit-tested on macOS.
/// </summary>
public static class NalUnits
{
    /// <summary>NAL unit type of an IDR slice.</summary>
    public const int Idr = 5;

    /// <summary>NAL unit type of a sequence parameter set.</summary>
    public const int Sps = 7;

    /// <summary>NAL unit type of a picture parameter set.</summary>
    public const int Pps = 8;

    /// <summary>Access unit delimiter.</summary>
    public const int AccessUnitDelimiter = 9;

    /// <summary>
    /// The NAL units in an Annex-B buffer as (offset, length) of each unit's payload (after its
    /// start code, including the NAL header byte). Trailing zero bytes before the next start code
    /// are left out.
    /// </summary>
    public static List<(int Offset, int Length)> Split(ReadOnlySpan<byte> annexB)
    {
        var units = new List<(int, int)>();
        var start = -1;
        var i = 0;
        while (i + 2 < annexB.Length)
        {
            if (annexB[i] == 0 && annexB[i + 1] == 0 && annexB[i + 2] == 1)
            {
                if (start >= 0) units.Add((start, TrimZeros(annexB, start, i)));
                i += 3;
                start = i;
                continue;
            }
            i++;
        }
        if (start >= 0 && start < annexB.Length) units.Add((start, annexB.Length - start));
        return units;
    }

    /// <summary>The <c>nal_unit_type</c> of each unit, in order.</summary>
    public static List<int> Types(ReadOnlySpan<byte> annexB)
    {
        var types = new List<int>();
        foreach (var (offset, length) in Split(annexB))
            if (length > 0) types.Add(annexB[offset] & 0x1F);
        return types;
    }

    /// <summary>Whether the buffer holds a unit of <paramref name="type"/>.</summary>
    public static bool Contains(ReadOnlySpan<byte> annexB, int type) => Types(annexB).Contains(type);

    /// <summary>
    /// Converts length-prefixed (AVCC, 4-byte big-endian) NAL units to Annex-B with 4-byte start
    /// codes, putting <paramref name="parameterSets"/> (raw SPS/PPS) first when given.
    /// </summary>
    public static byte[] AvccToAnnexB(ReadOnlySpan<byte> avcc, IReadOnlyList<byte[]>? parameterSets = null)
    {
        using var output = new MemoryStream(avcc.Length + 64);
        ReadOnlySpan<byte> startCode = [0, 0, 0, 1];
        if (parameterSets is not null)
        {
            foreach (var set in parameterSets)
            {
                output.Write(startCode);
                output.Write(set);
            }
        }
        var position = 0;
        while (position + 4 <= avcc.Length)
        {
            var length = (avcc[position] << 24) | (avcc[position + 1] << 16) | (avcc[position + 2] << 8) | avcc[position + 3];
            position += 4;
            if (length < 0 || position + length > avcc.Length) throw new FormatException("Truncated AVCC NAL unit.");
            output.Write(startCode);
            output.Write(avcc.Slice(position, length));
            position += length;
        }
        return output.ToArray();
    }

    private static int TrimZeros(ReadOnlySpan<byte> data, int start, int end)
    {
        var last = end;
        while (last > start && data[last - 1] == 0) last--;
        return last - start;
    }
}
