using Vantage.Host.Windows.Clipboard;

namespace Vantage.Host.Windows.Cursor;

/// <summary>
/// Turns a cursor drawn twice, once on black and once on white (<c>DrawIconEx</c>), into straight
/// BGRA. That covers every kind of Windows cursor: colour cursors with alpha, old masked ones, and
/// monochrome ones whose pixels invert the screen (the text I-beam). An inverting pixel has no
/// colour of its own, so it becomes opaque black with a white edge around the shape, which reads
/// on light and dark backgrounds alike. Pure; runs on macOS.
/// </summary>
public static class CursorImage
{
    /// <summary>Recovers the cursor from its two renderings (BGRX, top-down, same size).</summary>
    public static BgraImage FromBackgrounds(ReadOnlySpan<byte> onBlack, ReadOnlySpan<byte> onWhite, int width, int height)
    {
        var count = width * height;
        if (onBlack.Length < count * 4 || onWhite.Length < count * 4) throw new ArgumentException("The renderings are smaller than the cursor.");
        var output = new byte[count * 4];
        var inverting = new bool[count];
        var anyInverting = false;
        for (var i = 0; i < count; i++)
        {
            var o = i * 4;
            // On black a pixel shows alpha × colour; on white, that plus (1 − alpha) × 255.
            // An inverting pixel is white on black and black on white: a "negative" alpha.
            int b0 = onBlack[o], g0 = onBlack[o + 1], r0 = onBlack[o + 2];
            int b1 = onWhite[o], g1 = onWhite[o + 1], r1 = onWhite[o + 2];
            var lift = ((b1 - b0) + (g1 - g0) + (r1 - r0)) / 3; // (1 − alpha) × 255
            if (lift < -64)
            {
                inverting[i] = true;
                anyInverting = true;
                output[o + 3] = 255; // black, opaque
                continue;
            }
            var alpha = Math.Clamp(255 - lift, 0, 255);
            if (alpha == 0) continue;
            output[o] = (byte)Math.Min(255, b0 * 255 / alpha);
            output[o + 1] = (byte)Math.Min(255, g0 * 255 / alpha);
            output[o + 2] = (byte)Math.Min(255, r0 * 255 / alpha);
            output[o + 3] = (byte)alpha;
        }
        if (anyInverting) AddHalo(output, inverting, width, height);
        return new BgraImage(width, height, output);
    }

    /// <summary>Paints the clear pixels next to an inverting one white, so the shape shows on black too.</summary>
    private static void AddHalo(byte[] output, bool[] inverting, int width, int height)
    {
        for (var y = 0; y < height; y++)
        {
            for (var x = 0; x < width; x++)
            {
                var i = y * width + x;
                if (output[i * 4 + 3] != 0) continue;
                var touches = false;
                for (var dy = -1; dy <= 1 && !touches; dy++)
                {
                    for (var dx = -1; dx <= 1; dx++)
                    {
                        int nx = x + dx, ny = y + dy;
                        if (nx < 0 || ny < 0 || nx >= width || ny >= height) continue;
                        if (inverting[ny * width + nx]) { touches = true; break; }
                    }
                }
                if (!touches) continue;
                output[i * 4] = output[i * 4 + 1] = output[i * 4 + 2] = 255;
                output[i * 4 + 3] = 255;
            }
        }
    }
}
