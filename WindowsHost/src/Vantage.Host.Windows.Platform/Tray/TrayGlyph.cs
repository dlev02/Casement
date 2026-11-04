using System.Buffers.Binary;

namespace Vantage.Host.Windows.Tray;

/// <summary>
/// The tray icon while files move: a progress ring filling clockwise from the top over a faint
/// track, with an arrow inside (down receiving, up sending), in the same white / near-black as the
/// baked glyphs from <c>make-icons.py</c>. Drawn here rather than baked because the ring has
/// <see cref="Files.HostTransferActivity.Steps"/>+1 fills × 2 arrows × 2 taskbar themes × every
/// DPI size; computed with analytic anti-aliasing (distance to each stroke), so it is crisp at the
/// taskbar's exact pixel size. The result is a DIB icon resource for <c>CreateIconFromResourceEx</c>,
/// the same call the baked icons go through. Pure; unit-tested.
/// </summary>
public static class TrayGlyph
{
    /// <summary>The track's opacity (the Mac's ring uses 30 % black; a touch more reads on acrylic).</summary>
    public const double TrackOpacity = 0.35;

    /// <summary>Glyph colour on a light taskbar (as <c>make-icons.py</c>).</summary>
    public static readonly (byte R, byte G, byte B) OnLight = (27, 27, 27);

    /// <summary>Glyph colour on a dark taskbar.</summary>
    public static readonly (byte R, byte G, byte B) OnDark = (255, 255, 255);

    /// <summary>Straight-alpha RGBA pixels, top row first.</summary>
    /// <param name="size">Width and height in pixels (16, 20, 24, 32 … at 100–200 %).</param>
    /// <param name="fraction">The ring's fill, 0–1 (a sliver always shows, so it never looks idle).</param>
    /// <param name="pointsDown">Arrow down (receiving) or up (sending).</param>
    /// <param name="lightTaskbar">Dark glyph for a light taskbar.</param>
    public static byte[] Render(int size, double fraction, bool pointsDown, bool lightTaskbar)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(size, 8);
        var (r, g, b) = lightTaskbar ? OnLight : OnDark;
        var pixels = new byte[size * size * 4];
        var s = (double)size;
        var center = s / 2;
        var stroke = Math.Max(1.5, s * 0.1);
        var radius = center - stroke / 2 - s * 0.05;
        var sweep = 2 * Math.PI * Math.Clamp(Math.Max(0.04, fraction), 0, 1);
        // A whole, even number of pixels: the shaft sits on the centre line between two pixel columns
        // (sizes are even), so an even width fills whole pixels and stays sharp at 16 px.
        var arrowStroke = Math.Max(2, 2 * Math.Round(stroke * 0.85 / 2));
        var half = radius * 0.5;
        var wing = radius * 0.38;
        var tipY = pointsDown ? center + half : center - half;
        var tailY = pointsDown ? center - half : center + half;
        var backY = pointsDown ? tipY - wing : tipY + wing;

        for (var y = 0; y < size; y++)
        {
            for (var x = 0; x < size; x++)
            {
                var px = x + 0.5;
                var py = y + 0.5;
                var dx = px - center;
                var dy = py - center;
                var ringDistance = Math.Abs(Math.Sqrt(dx * dx + dy * dy) - radius);
                var track = Coverage(ringDistance, stroke);
                var arc = Coverage(ArcDistance(dx, dy, radius, sweep, ringDistance), stroke);
                var arrow = Math.Max(Coverage(Segment(px, py, center, tailY, center, tipY), arrowStroke),
                                     Math.Max(Coverage(Segment(px, py, center - wing, backY, center, tipY), arrowStroke),
                                              Coverage(Segment(px, py, center + wing, backY, center, tipY), arrowStroke)));
                var solid = Math.Max(arc, arrow);
                var alpha = solid + track * TrackOpacity * (1 - solid);
                var at = (y * size + x) * 4;
                pixels[at] = r;
                pixels[at + 1] = g;
                pixels[at + 2] = b;
                pixels[at + 3] = (byte)Math.Round(Math.Clamp(alpha, 0, 1) * 255);
            }
        }
        return pixels;
    }

    /// <summary>
    /// <see cref="Render"/> as an icon resource: a 32-bit <c>BITMAPINFOHEADER</c> (height doubled for
    /// the mask), bottom-up BGRA, then an all-zero AND mask (the alpha channel does the work).
    /// </summary>
    public static byte[] IconResource(int size, double fraction, bool pointsDown, bool lightTaskbar)
    {
        var rgba = Render(size, fraction, pointsDown, lightTaskbar);
        var maskStride = (size + 31) / 32 * 4;
        var colorBytes = size * size * 4;
        var resource = new byte[40 + colorBytes + maskStride * size];
        var header = resource.AsSpan();
        BinaryPrimitives.WriteInt32LittleEndian(header, 40);
        BinaryPrimitives.WriteInt32LittleEndian(header[4..], size);
        BinaryPrimitives.WriteInt32LittleEndian(header[8..], size * 2);
        BinaryPrimitives.WriteUInt16LittleEndian(header[12..], 1);
        BinaryPrimitives.WriteUInt16LittleEndian(header[14..], 32);
        BinaryPrimitives.WriteInt32LittleEndian(header[20..], colorBytes + maskStride * size);
        for (var y = 0; y < size; y++)
        {
            var row = 40 + (size - 1 - y) * size * 4;
            for (var x = 0; x < size; x++)
            {
                var from = (y * size + x) * 4;
                var to = row + x * 4;
                resource[to] = rgba[from + 2];
                resource[to + 1] = rgba[from + 1];
                resource[to + 2] = rgba[from];
                resource[to + 3] = rgba[from + 3];
            }
        }
        return resource;
    }

    /// <summary>How much of a pixel a stroke of <paramref name="width"/> covers at this distance from its centre line.</summary>
    private static double Coverage(double distance, double width) => Math.Clamp(width / 2 + 0.5 - distance, 0, 1);

    /// <summary>Distance to the filled part of the ring: the ring itself inside the sweep, else to the nearer round cap.</summary>
    private static double ArcDistance(double dx, double dy, double radius, double sweep, double ringDistance)
    {
        // Clockwise from 12 o'clock (y grows downwards, so atan2's angle already runs clockwise).
        var angle = Math.Atan2(dy, dx) + Math.PI / 2;
        if (angle < 0) angle += 2 * Math.PI;
        if (angle <= sweep) return ringDistance;
        var startX = 0.0;
        var startY = -radius;
        var endX = radius * Math.Sin(sweep);
        var endY = -radius * Math.Cos(sweep);
        return Math.Min(Math.Sqrt((dx - startX) * (dx - startX) + (dy - startY) * (dy - startY)),
                        Math.Sqrt((dx - endX) * (dx - endX) + (dy - endY) * (dy - endY)));
    }

    /// <summary>Distance from a point to a line segment (a stroke with round caps).</summary>
    private static double Segment(double px, double py, double ax, double ay, double bx, double by)
    {
        var vx = bx - ax;
        var vy = by - ay;
        var lengthSquared = vx * vx + vy * vy;
        var t = lengthSquared == 0 ? 0 : Math.Clamp(((px - ax) * vx + (py - ay) * vy) / lengthSquared, 0, 1);
        var cx = ax + t * vx - px;
        var cy = ay + t * vy - py;
        return Math.Sqrt(cx * cx + cy * cy);
    }
}
