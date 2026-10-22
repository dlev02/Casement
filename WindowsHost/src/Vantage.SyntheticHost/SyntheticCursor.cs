using Vantage.Host.Windows.Clipboard;
using Vantage.Host.Windows.Cursor;
using Vantage.Protocol.Host;
using Vantage.Protocol.Messages;

namespace Vantage.SyntheticHost;

/// <summary>
/// <c>--cursor-shapes</c>: a pretend pointer for clients that draw it themselves. It cycles every
/// 2 s through an arrow, an I-beam (drawn as an inverting cursor, like Windows' own, so it runs
/// through <see cref="CursorImage"/>'s inverting path) and a second of being hidden.
/// </summary>
internal sealed class SyntheticCursorSource : ICursorSource
{
    private static readonly TimeSpan s_step = TimeSpan.FromSeconds(2);

    public IDisposable Watch(DisplayInfo display, Action<CursorState> onChange)
    {
        var scale = display.Scale > 0 ? display.Scale : 1;
        CursorShape[] shapes = [Arrow(scale), IBeam(scale)];
        var step = 0;
        void Tick()
        {
            var phase = step++ % 3;
            var x = (float)(display.PointWidth / 2.0);
            var y = (float)(display.PointHeight / 2.0);
            onChange(phase < 2 ? new CursorState(shapes[phase], true, x, y) : new CursorState(null, false, x, y));
        }
        Tick();
        return new Timer(_ => Tick(), null, s_step, s_step);
    }

    /// <summary>A white arrow with a black edge, hotspot at its tip.</summary>
    private static CursorShape Arrow(double scale)
    {
        (double X, double Y)[] outline = [(0, 0), (0, 17), (4.2, 13), (7.2, 19.5), (9.6, 18.4), (6.7, 12.2), (12, 12.2)];
        var width = (int)Math.Ceiling(13 * scale);
        var height = (int)Math.Ceiling(21 * scale);
        bool Inside(double px, double py) => Contains(outline, px / scale, py / scale);
        var pixels = new byte[width * height * 4];
        for (var y = 0; y < height; y++)
        {
            for (var x = 0; x < width; x++)
            {
                if (!Inside(x + 0.5, y + 0.5)) continue;
                var edge = !Inside(x + 0.5 - scale, y + 0.5) || !Inside(x + 0.5 + scale, y + 0.5)
                           || !Inside(x + 0.5, y + 0.5 - scale) || !Inside(x + 0.5, y + 0.5 + scale);
                var value = edge ? (byte)0 : (byte)255;
                var o = (y * width + x) * 4;
                pixels[o] = pixels[o + 1] = pixels[o + 2] = value;
                pixels[o + 3] = 255;
            }
        }
        // An opaque cursor draws the same on black and on white, outside its shape the background.
        var onBlack = Composite(pixels, 0);
        var onWhite = Composite(pixels, 255);
        return Shape(CursorImage.FromBackgrounds(onBlack, onWhite, width, height), scale, 0, 0);
    }

    /// <summary>The text I-beam as Windows draws it: pixels that invert whatever is under them.</summary>
    private static CursorShape IBeam(double scale)
    {
        var width = (int)Math.Ceiling(9 * scale);
        var height = (int)Math.Ceiling(18 * scale);
        var onBlack = new byte[width * height * 4];
        var onWhite = new byte[width * height * 4];
        onWhite.AsSpan().Fill(255);
        var stem = (int)Math.Max(1, Math.Round(scale));
        for (var y = 0; y < height; y++)
        {
            for (var x = 0; x < width; x++)
            {
                var serif = y < stem || y >= height - stem;
                var bar = Math.Abs(x - width / 2) < stem / 2.0 + 0.5;
                if (!(serif && x > 0 && x < width - 1) && !bar) continue;
                var o = (y * width + x) * 4;
                onBlack[o] = onBlack[o + 1] = onBlack[o + 2] = 255; // inverted: white on black
                onWhite[o] = onWhite[o + 1] = onWhite[o + 2] = 0;   // and black on white
            }
        }
        return Shape(CursorImage.FromBackgrounds(onBlack, onWhite, width, height), scale, 4.5, 9);
    }

    private static CursorShape Shape(BgraImage image, double scale, double hotspotX, double hotspotY) => new()
    {
        PngData = PngWriter.Encode(image),
        WidthPoints = image.Width / scale,
        HeightPoints = image.Height / scale,
        HotspotX = hotspotX,
        HotspotY = hotspotY,
        Scale = scale,
    };

    private static byte[] Composite(byte[] bgra, byte background)
    {
        var output = new byte[bgra.Length];
        for (var i = 0; i < bgra.Length; i += 4)
        {
            var opaque = bgra[i + 3] != 0;
            output[i] = opaque ? bgra[i] : background;
            output[i + 1] = opaque ? bgra[i + 1] : background;
            output[i + 2] = opaque ? bgra[i + 2] : background;
        }
        return output;
    }

    private static bool Contains((double X, double Y)[] polygon, double x, double y)
    {
        var inside = false;
        for (int i = 0, j = polygon.Length - 1; i < polygon.Length; j = i++)
        {
            var (xi, yi) = polygon[i];
            var (xj, yj) = polygon[j];
            if ((yi > y) != (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi) inside = !inside;
        }
        return inside;
    }
}
