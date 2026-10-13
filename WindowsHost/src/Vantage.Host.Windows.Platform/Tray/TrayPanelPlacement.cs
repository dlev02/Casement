namespace Vantage.Host.Windows.Tray;

/// <summary>A rectangle in physical screen pixels (right and bottom exclusive).</summary>
/// <param name="Left">Left edge.</param>
/// <param name="Top">Top edge.</param>
/// <param name="Right">Right edge.</param>
/// <param name="Bottom">Bottom edge.</param>
public readonly record struct ScreenRect(int Left, int Top, int Right, int Bottom)
{
    /// <summary>Width in pixels.</summary>
    public int Width => Right - Left;

    /// <summary>Height in pixels.</summary>
    public int Height => Bottom - Top;
}

/// <summary>
/// Where the tray panel opens, the way Windows 11's own flyouts do: on the taskbar's side of the
/// work area, a margin away from it, centred on the icon and kept inside the work area. A taskbar
/// on any edge works; an icon inside the work area (the overflow flyout, an auto-hidden taskbar)
/// gets the panel above it, or below when there's no room. Pure; unit-tested.
/// </summary>
public static class TrayPanelPlacement
{
    /// <summary>The panel's top-left corner.</summary>
    /// <param name="icon">The tray icon (Shell_NotifyIconGetRect, or the click point).</param>
    /// <param name="workArea">The work area of the monitor the icon is on.</param>
    /// <param name="width">Panel width in pixels.</param>
    /// <param name="height">Panel height in pixels.</param>
    /// <param name="margin">Gap to the taskbar and the screen edges, in pixels.</param>
    public static (int X, int Y) Place(ScreenRect icon, ScreenRect workArea, int width, int height, int margin)
    {
        var centerX = icon.Left + icon.Width / 2;
        var centerY = icon.Top + icon.Height / 2;
        int x, y;
        if (icon.Top >= workArea.Bottom)
        {
            x = centerX - width / 2;
            y = workArea.Bottom - margin - height;
        }
        else if (icon.Bottom <= workArea.Top)
        {
            x = centerX - width / 2;
            y = workArea.Top + margin;
        }
        else if (icon.Left >= workArea.Right)
        {
            x = workArea.Right - margin - width;
            y = centerY - height / 2;
        }
        else if (icon.Right <= workArea.Left)
        {
            x = workArea.Left + margin;
            y = centerY - height / 2;
        }
        else
        {
            x = centerX - width / 2;
            y = icon.Top - margin - height >= workArea.Top + margin ? icon.Top - margin - height : icon.Bottom + margin;
        }
        return (Clamp(x, workArea.Left + margin, workArea.Right - margin - width),
                Clamp(y, workArea.Top + margin, workArea.Bottom - margin - height));
    }

    private static int Clamp(int value, int min, int max) => max < min ? min : Math.Clamp(value, min, max);
}
