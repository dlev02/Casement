namespace Vantage.Host.Windows.Input;

/// <summary>
/// <c>MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK</c> coordinates: 0…65535 across the whole
/// virtual screen. Pure; unit-tested on macOS.
/// </summary>
public static class AbsoluteCoordinates
{
    /// <summary>
    /// <c>round((pixel − origin) × 65535 / (extent − 1))</c>, clamped to 0…65535. With this mapping
    /// the first pixel is 0 and the last is 65535, and every pixel round-trips through Windows'
    /// inverse (<c>value × (extent − 1) / 65535</c>) to itself.
    /// </summary>
    /// <param name="pixel">Virtual-desktop pixel.</param>
    /// <param name="origin">SM_XVIRTUALSCREEN / SM_YVIRTUALSCREEN.</param>
    /// <param name="extent">SM_CXVIRTUALSCREEN / SM_CYVIRTUALSCREEN.</param>
    public static int Normalize(int pixel, int origin, int extent)
    {
        if (extent <= 1) return 0;
        var value = Math.Round((double)(pixel - origin) * 65535 / (extent - 1), MidpointRounding.AwayFromZero);
        return (int)Math.Clamp(value, 0, 65535);
    }

    /// <summary>What Windows maps a normalised value back to (for tests): <c>origin + value × (extent − 1) / 65535</c>, rounded.</summary>
    public static int Denormalize(int value, int origin, int extent) =>
        origin + (int)Math.Round((double)value * (extent - 1) / 65535, MidpointRounding.AwayFromZero);
}
