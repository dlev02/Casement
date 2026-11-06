using Windows.Win32;
using Windows.Win32.Graphics.Gdi;

namespace Vantage.Host.Windows.Capture;

/// <summary>A display mode: pixel size and refresh rate (always 32-bit colour, progressive).</summary>
/// <param name="Width">Pixels across.</param>
/// <param name="Height">Pixels down.</param>
/// <param name="RefreshRate">Hz (<c>dmDisplayFrequency</c>).</param>
public readonly record struct DisplayMode(int Width, int Height, int RefreshRate)
{
    /// <summary>Width over height.</summary>
    public double Aspect => (double)Width / Height;

    /// <inheritdoc />
    public override string ToString() => $"{Width}x{Height} @ {RefreshRate} Hz";
}

/// <summary>One mode as <c>EnumDisplaySettingsEx</c> lists it, before filtering.</summary>
/// <param name="Width">Pixels across.</param>
/// <param name="Height">Pixels down.</param>
/// <param name="BitsPerPixel"><c>dmBitsPerPel</c>.</param>
/// <param name="RefreshRate"><c>dmDisplayFrequency</c>.</param>
/// <param name="Interlaced"><c>DM_INTERLACED</c> in <c>dmDisplayFlags</c>.</param>
public readonly record struct RawDisplayMode(int Width, int Height, int BitsPerPixel, int RefreshRate, bool Interlaced = false);

/// <summary>
/// A display's modes and the choice of the one that best fits a device's screen (the pure parts
/// are unit-tested). The rule, in order:
/// <list type="number">
/// <item>Candidates are at least 1280×720, no larger than the panel's native (largest) mode, and
/// at least the viewport in points, so the scale chosen with the mode (<see cref="DisplayScales"/>)
/// never has to go below 100% to give the device the room of its own screen.</item>
/// <item>The current mode stays when its shape already matches the viewport within 1%.</item>
/// <item>Otherwise the candidate whose shape covers most of the viewport wins (coverage =
/// min(aspect ratio quotient, its inverse): the letterboxed fraction left over); among shapes
/// within 1% of the best, the one whose pixel count is closest to viewport × device scale.</item>
/// <item>A mode switch has to pay for itself: the winner must cover at least 5% more of the
/// viewport than the current mode, else the current mode stays (a portrait iPad or iPhone gains
/// nothing from a landscape mode, and a 16:9 phone nothing from another 16:9 mode).</item>
/// </list>
/// </summary>
public static class DisplayModes
{
    /// <summary>Smallest mode ever chosen.</summary>
    public const int MinimumWidth = 1280;

    /// <summary>Smallest mode ever chosen.</summary>
    public const int MinimumHeight = 720;

    /// <summary>Shapes this close (coverage) count as the same.</summary>
    private const double SameShape = 0.01;

    /// <summary>How much more of the viewport a new mode must cover to be worth a switch.</summary>
    private const double WorthSwitching = 0.05;

    /// <summary>
    /// 32-bit, progressive modes, one per size: at <paramref name="current"/>'s refresh rate when
    /// the size offers it, else the highest. Largest first.
    /// </summary>
    public static IReadOnlyList<DisplayMode> Distinct(IEnumerable<RawDisplayMode> raw, DisplayMode current)
    {
        var bySize = new Dictionary<(int, int), DisplayMode>();
        foreach (var mode in raw)
        {
            if (mode.BitsPerPixel != 32 || mode.Interlaced || mode.Width <= 0 || mode.Height <= 0) continue;
            var key = (mode.Width, mode.Height);
            var candidate = new DisplayMode(mode.Width, mode.Height, mode.RefreshRate);
            if (!bySize.TryGetValue(key, out var kept)) bySize[key] = candidate;
            else if (kept.RefreshRate != current.RefreshRate && (mode.RefreshRate == current.RefreshRate || mode.RefreshRate > kept.RefreshRate)) bySize[key] = candidate;
        }
        return [.. bySize.Values.OrderByDescending(m => (long)m.Width * m.Height).ThenByDescending(m => m.Width)];
    }

    /// <summary>The fraction of a viewport of shape <paramref name="viewportAspect"/> a picture of shape <paramref name="modeAspect"/> fills when letterboxed.</summary>
    public static double Coverage(double modeAspect, double viewportAspect) =>
        modeAspect <= 0 || viewportAspect <= 0 ? 0 : Math.Min(modeAspect / viewportAspect, viewportAspect / modeAspect);

    /// <summary>
    /// The mode that best fits a viewport (see the class remarks), or <paramref name="current"/>
    /// when nothing fits better.
    /// </summary>
    /// <param name="modes">The display's modes (<see cref="Distinct"/>).</param>
    /// <param name="current">The mode the user had (the one to keep when in doubt).</param>
    /// <param name="viewportWidthPoints">The device's viewport in points.</param>
    /// <param name="viewportHeightPoints">The device's viewport in points.</param>
    /// <param name="deviceScale">The device's pixels per point (2 on an iPad, 3 on an iPhone).</param>
    public static DisplayMode Choose(IReadOnlyList<DisplayMode> modes, DisplayMode current, double viewportWidthPoints, double viewportHeightPoints,
                                     double deviceScale)
    {
        if (viewportWidthPoints <= 0 || viewportHeightPoints <= 0 || modes.Count == 0) return current;
        // A monitor lists landscape modes: a portrait device would only trade pixels for a little less letterbox.
        if (viewportHeightPoints > viewportWidthPoints) return current;
        var aspect = viewportWidthPoints / viewportHeightPoints;
        var currentCoverage = Coverage(current.Aspect, aspect);
        if (currentCoverage >= 1 - SameShape) return current;

        var native = modes.MaxBy(m => (long)m.Width * m.Height);
        var minimumWidth = Math.Max(MinimumWidth, viewportWidthPoints - 0.5);
        var minimumHeight = Math.Max(MinimumHeight, viewportHeightPoints - 0.5);
        var candidates = modes.Where(m => m.Width >= minimumWidth && m.Height >= minimumHeight
                                          && m.Width <= native.Width && m.Height <= native.Height).ToList();
        if (candidates.Count == 0) return current;

        var bestCoverage = candidates.Max(m => Coverage(m.Aspect, aspect));
        if (bestCoverage < currentCoverage + WorthSwitching) return current;
        var density = deviceScale > 0 ? deviceScale : 1;
        var targetPixels = viewportWidthPoints * density * viewportHeightPoints * density;
        return candidates.Where(m => Coverage(m.Aspect, aspect) >= bestCoverage - SameShape)
                         .OrderBy(m => Math.Abs(Math.Log((double)m.Width * m.Height / targetPixels)))
                         .ThenByDescending(m => m.Width)
                         .First();
    }

    /// <summary>
    /// The display's modes (<see cref="Distinct"/>) and the one it shows now, from
    /// <c>EnumDisplaySettingsEx</c>. Null when Windows lists nothing for <paramref name="gdiName"/>.
    /// </summary>
    internal static unsafe (IReadOnlyList<DisplayMode> Modes, DisplayMode Current)? Enumerate(string gdiName)
    {
        var mode = new DEVMODEW { dmSize = (ushort)sizeof(DEVMODEW) };
        DisplayMode current;
        var raw = new List<RawDisplayMode>();
        fixed (char* name = gdiName)
        {
            if (!PInvoke.EnumDisplaySettingsEx(name, ENUM_DISPLAY_SETTINGS_MODE.ENUM_CURRENT_SETTINGS, &mode, 0)) return null;
            current = new DisplayMode((int)mode.dmPelsWidth, (int)mode.dmPelsHeight, (int)mode.dmDisplayFrequency);
            for (uint index = 0; index < 10_000; index++)
            {
                mode = new DEVMODEW { dmSize = (ushort)sizeof(DEVMODEW) };
                if (!PInvoke.EnumDisplaySettingsEx(name, (ENUM_DISPLAY_SETTINGS_MODE)index, &mode, 0)) break;
                raw.Add(new RawDisplayMode((int)mode.dmPelsWidth, (int)mode.dmPelsHeight, (int)mode.dmBitsPerPel, (int)mode.dmDisplayFrequency,
                                           (mode.Anonymous2.dmDisplayFlags & 2u) != 0)); // DM_INTERLACED
            }
        }
        return (Distinct(raw, current), current);
    }
}
