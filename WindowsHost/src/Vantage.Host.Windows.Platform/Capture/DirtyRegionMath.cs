namespace Vantage.Host.Windows.Capture;

/// <summary>A pixel rectangle (x, y, width, height).</summary>
public readonly record struct PixelRect(int X, int Y, int Width, int Height);

/// <summary>
/// Turns Windows.Graphics.Capture dirty regions (<c>DirtyRegionMode.ReportOnly</c>, Windows 11 24H2+)
/// into the fraction of the frame that changed. Pure; unit-tested on macOS.
/// </summary>
public static class DirtyRegionMath
{
    /// <summary>
    /// What a frame that arrived with no dirty rectangles counts as: roughly a 32×32 cursor's worth.
    /// WGC delivers a frame when only the (captured) cursor moved; reporting 0 would let the core
    /// skip it, and the pointer would freeze on the iPad.
    /// </summary>
    public const int CursorSizedArea = 32 * 32;

    /// <summary>
    /// The union area of <paramref name="rects"/> clipped to the frame, divided by the frame's area
    /// (0…1). Overlaps count once. No rectangles gives <see cref="CursorSizedArea"/>'s share.
    /// </summary>
    public static double Ratio(IReadOnlyList<PixelRect> rects, int frameWidth, int frameHeight)
    {
        if (frameWidth <= 0 || frameHeight <= 0) return 1;
        double total = (double)frameWidth * frameHeight;
        if (rects.Count == 0) return Math.Min(1, CursorSizedArea / total);
        var area = UnionArea(rects, frameWidth, frameHeight);
        return area <= 0 ? Math.Min(1, CursorSizedArea / total) : Math.Min(1, area / total);
    }

    /// <summary>Area covered by the union of the rectangles, clipped to 0…width × 0…height.</summary>
    public static long UnionArea(IReadOnlyList<PixelRect> rects, int width, int height)
    {
        var clipped = new List<(int Left, int Top, int Right, int Bottom)>(rects.Count);
        foreach (var r in rects)
        {
            var left = Math.Clamp(r.X, 0, width);
            var top = Math.Clamp(r.Y, 0, height);
            var right = Math.Clamp((long)r.X + r.Width, 0, width);
            var bottom = Math.Clamp((long)r.Y + r.Height, 0, height);
            if (right > left && bottom > top) clipped.Add((left, top, (int)right, (int)bottom));
        }
        if (clipped.Count == 0) return 0;
        if (clipped.Count == 1) return (long)(clipped[0].Right - clipped[0].Left) * (clipped[0].Bottom - clipped[0].Top);

        // Sweep over x: between consecutive x edges, measure the merged y coverage of the active rects.
        var xs = new List<int>(clipped.Count * 2);
        foreach (var c in clipped)
        {
            xs.Add(c.Left);
            xs.Add(c.Right);
        }
        xs.Sort();
        long area = 0;
        var spans = new List<(int Top, int Bottom)>(clipped.Count);
        for (var i = 0; i + 1 < xs.Count; i++)
        {
            var x0 = xs[i];
            var x1 = xs[i + 1];
            if (x1 == x0) continue;
            spans.Clear();
            foreach (var c in clipped)
            {
                if (c.Left <= x0 && c.Right >= x1) spans.Add((c.Top, c.Bottom));
            }
            if (spans.Count == 0) continue;
            spans.Sort((a, b) => a.Top.CompareTo(b.Top));
            long covered = 0;
            var (top, bottom) = spans[0];
            for (var s = 1; s < spans.Count; s++)
            {
                if (spans[s].Top > bottom)
                {
                    covered += bottom - top;
                    (top, bottom) = spans[s];
                }
                else if (spans[s].Bottom > bottom)
                {
                    bottom = spans[s].Bottom;
                }
            }
            covered += bottom - top;
            area += covered * (x1 - x0);
        }
        return area;
    }
}
