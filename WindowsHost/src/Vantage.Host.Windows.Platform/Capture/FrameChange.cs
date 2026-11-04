namespace Vantage.Host.Windows.Capture;

/// <summary>Where a capture's dirty ratio comes from (<c>--dirty-regions</c>).</summary>
public enum DirtyRegionSource
{
    /// <summary>
    /// Windows.Graphics.Capture's own dirty rectangles (<c>DirtyRegionMode.ReportOnly</c>, Windows 11
    /// 24H2+). The default; older Windows falls back to <see cref="Compare"/>.
    /// </summary>
    Native,

    /// <summary>The GPU compares each frame with the previous one in 32×32 blocks (<c>FrameComparer</c>).</summary>
    Compare,

    /// <summary>No estimate: every frame counts as fully changed (what older Windows did before the compare pass).</summary>
    None,
}

/// <summary>
/// The pure half of the frame compare: which source a capture uses, block maps to dirty ratios,
/// and the readback ring's bookkeeping. Unit-tested without a GPU.
/// </summary>
public static class FrameChange
{
    /// <summary>Block edge in pixels; one byte per block comes back from the GPU (8 160 bytes at 4K).</summary>
    public const int BlockSize = 32;

    /// <summary>
    /// The least a frame with any changed block reports, about what 24H2 reports for a 32×32 cursor
    /// at 1080p. A blinking caret is one block, and on a 4K or larger display its plain share would
    /// fall under <c>HostSessionCore.IdleDirtyRatio</c> and the core would skip it as unchanged.
    /// </summary>
    public const double MinChangedRatio = 0.0005;

    /// <summary>Whether native dirty regions exist on this Windows (11 24H2, build 26100, and later).</summary>
    public static bool NativeAvailable => OperatingSystem.IsWindowsVersionAtLeast(10, 0, 26100);

    /// <summary>
    /// The source a capture actually uses: <see cref="DirtyRegionSource.Native"/> only where Windows
    /// has it (else <see cref="DirtyRegionSource.Compare"/>); the other two as asked.
    /// </summary>
    public static DirtyRegionSource Resolve(DirtyRegionSource preference, bool nativeAvailable) =>
        preference == DirtyRegionSource.Native && !nativeAvailable ? DirtyRegionSource.Compare : preference;

    /// <summary>The word the log, the flag and the Display page use.</summary>
    public static string Name(DirtyRegionSource source) => source switch
    {
        DirtyRegionSource.Native => "native",
        DirtyRegionSource.Compare => "compare",
        _ => "none",
    };

    /// <summary>Parses <c>native|compare|none</c>; null otherwise.</summary>
    public static DirtyRegionSource? Parse(string text) => text.ToLowerInvariant() switch
    {
        "native" => DirtyRegionSource.Native,
        "compare" => DirtyRegionSource.Compare,
        "none" => DirtyRegionSource.None,
        _ => null,
    };

    /// <summary>Blocks needed to cover <paramref name="pixels"/> (the last one may be partial).</summary>
    public static int Blocks(int pixels) => (pixels + BlockSize - 1) / BlockSize;

    /// <summary>Nonzero bytes in a mapped block map: <paramref name="rows"/> rows of <paramref name="columns"/> bytes, <paramref name="rowPitch"/> apart.</summary>
    public static int CountChanged(ReadOnlySpan<byte> map, int rowPitch, int columns, int rows)
    {
        var changed = 0;
        for (var y = 0; y < rows; y++)
        {
            var row = map.Slice(y * rowPitch, columns);
            changed += columns - CountZeros(row);
        }
        return changed;
    }

    /// <summary>
    /// The dirty ratio for <paramref name="changed"/> of <paramref name="total"/> blocks: exactly 0
    /// when nothing changed (the core skips the frame), else the changed share, never under
    /// <see cref="MinChangedRatio"/>.
    /// </summary>
    public static double Ratio(int changed, int total)
    {
        if (total <= 0) return 1;
        if (changed <= 0) return 0;
        return Math.Min(1, Math.Max(MinChangedRatio, (double)changed / total));
    }

    private static int CountZeros(ReadOnlySpan<byte> row)
    {
        var zeros = 0;
        foreach (var b in row)
            if (b == 0) zeros++;
        return zeros;
    }
}

/// <summary>One frame's place in the <see cref="ReadbackRing"/>.</summary>
/// <param name="Slot">The staging texture its block map was copied into.</param>
/// <param name="Sequence">Which use of that slot it was.</param>
public readonly record struct ReadbackTicket(int Slot, long Sequence);

/// <summary>
/// Hands out staging slots round-robin and remembers which frame last used each, so a frame whose
/// block map was overwritten before anyone read it (the core fell more than a ring behind) is
/// recognised and reports "unknown" (1) instead of another frame's answer. Not thread-safe.
/// </summary>
public sealed class ReadbackRing
{
    private readonly long[] _sequences;
    private long _next;

    /// <param name="slots">How many staging textures there are.</param>
    public ReadbackRing(int slots)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(slots, 1);
        _sequences = new long[slots];
        Array.Fill(_sequences, -1);
    }

    /// <summary>Number of slots.</summary>
    public int Slots => _sequences.Length;

    /// <summary>Claims the next slot for a new frame.</summary>
    public ReadbackTicket Begin()
    {
        var sequence = _next++;
        var slot = (int)(sequence % _sequences.Length);
        _sequences[slot] = sequence;
        return new ReadbackTicket(slot, sequence);
    }

    /// <summary>Whether <paramref name="ticket"/>'s slot still holds that frame's block map.</summary>
    public bool IsCurrent(ReadbackTicket ticket) =>
        ticket.Slot >= 0 && ticket.Slot < _sequences.Length && _sequences[ticket.Slot] == ticket.Sequence;
}

/// <summary>What the frame compare saw over a stats window (logged every 10 s).</summary>
public readonly record struct CompareSummary(int Frames, int Unchanged, double MeanRatio, double MaxRatio,
                                             double MeanWaitMs, double MaxWaitMs, double Seconds);

/// <summary>Running totals for <see cref="CompareSummary"/>. Not thread-safe.</summary>
public sealed class CompareStats
{
    private long _started = System.Diagnostics.Stopwatch.GetTimestamp();
    private int _frames;
    private int _unchanged;
    private double _ratioSum;
    private double _ratioMax;
    private double _waitSum;
    private double _waitMax;

    /// <summary>Time since the window began.</summary>
    public TimeSpan Elapsed => System.Diagnostics.Stopwatch.GetElapsedTime(_started);

    /// <summary>One frame's ratio and how long its readback took.</summary>
    public void Add(double ratio, double waitMs)
    {
        _frames++;
        if (ratio <= 0) _unchanged++;
        _ratioSum += ratio;
        _ratioMax = Math.Max(_ratioMax, ratio);
        _waitSum += waitMs;
        _waitMax = Math.Max(_waitMax, waitMs);
    }

    /// <summary>The window so far; starts a new one.</summary>
    public CompareSummary TakeAndReset()
    {
        var summary = new CompareSummary(_frames, _unchanged, _frames == 0 ? 0 : _ratioSum / _frames, _ratioMax,
                                         _frames == 0 ? 0 : _waitSum / _frames, _waitMax, Elapsed.TotalSeconds);
        _started = System.Diagnostics.Stopwatch.GetTimestamp();
        _frames = _unchanged = 0;
        _ratioSum = _ratioMax = _waitSum = _waitMax = 0;
        return summary;
    }
}
