using System.Globalization;

namespace Vantage.Host.Windows.Capture;

/// <summary>Pure display arithmetic (spec §7.4, §9.2). No Windows calls; unit-tested on macOS.</summary>
public static class DisplayMath
{
    /// <summary>The n in <c>\\.\DISPLAYn</c>, or null when the name doesn't have that shape.</summary>
    public static uint? DisplayNumber(string gdiDeviceName)
    {
        const string prefix = @"\\.\DISPLAY";
        if (!gdiDeviceName.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) return null;
        return uint.TryParse(gdiDeviceName.AsSpan(prefix.Length), NumberStyles.None, CultureInfo.InvariantCulture, out var number)
            ? number
            : null;
    }

    /// <summary><c>scale = dpi / 96</c> (effective DPI from <c>GetDpiForMonitor</c>). 96 when unknown.</summary>
    public static double Scale(uint effectiveDpi) => effectiveDpi == 0 ? 1.0 : effectiveDpi / 96.0;

    /// <summary><c>round(pixels / scale)</c>, at least 1.</summary>
    public static int Points(int pixels, double scale) =>
        Math.Max(1, (int)Math.Round(pixels / (scale <= 0 ? 1 : scale), MidpointRounding.AwayFromZero));

    /// <summary>
    /// Whether a DisplayConfig output technology is a built-in panel: INTERNAL (0x80000000), LVDS (6),
    /// DISPLAYPORT_EMBEDDED (11) or UDI_EMBEDDED (13).
    /// </summary>
    public static bool IsBuiltIn(uint outputTechnology) => outputTechnology is 0x80000000u or 6u or 11u or 13u;

    /// <summary>
    /// The refresh rate to report: DEVMODE's <c>dmDisplayFrequency</c>, where 0 and 1 mean "hardware
    /// default" and are reported as 60.
    /// </summary>
    public static double RefreshRate(uint displayFrequency) => displayFrequency <= 1 ? 60 : displayFrequency;
}
