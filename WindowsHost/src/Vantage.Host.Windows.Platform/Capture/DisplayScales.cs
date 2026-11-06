using System.Runtime.InteropServices;
using Windows.Win32;
using Windows.Win32.Devices.Display;
using Windows.Win32.Foundation;

namespace Vantage.Host.Windows.Capture;

/// <summary>
/// Windows' display scale: choosing one for a device's screen (pure, tested) and reading and
/// setting it. Windows has no public API for this; <c>DisplayConfigGetDeviceInfo</c> and
/// <c>DisplayConfigSetDeviceInfo</c> take the undocumented types -3 and -4, as Settings itself
/// does. A value is a step relative to the scale Windows recommends for the current mode, so the
/// same value means different scales in different modes. The registry keeps one per monitor and
/// mode, but the live value carries across a mode change and outlives the host unless it's put back:
/// after a crash the user's own mode came back at 225%, not 150%, with its registry value untouched.
/// </summary>
public static unsafe class DisplayScales
{
    /// <summary>The steps Windows offers, in percent.</summary>
    public static readonly int[] Steps = [100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500];

    /// <summary>The smallest desktop chosen, in points: below it Windows' own UI stops fitting.</summary>
    public const int MinimumWidth = 1024, MinimumHeight = 720;

    /// <summary>
    /// The scale at which the desktop has about the room of the device's own screen, so the taskbar
    /// and everything else come out the size the device's own UI is. This is what Remote Desktop
    /// gets by asking for the device's pixels at its scale: an iPad at 2420×1570 and 200%.
    /// </summary>
    /// <param name="modeWidth">The display mode's pixels across.</param>
    /// <param name="modeHeight">The display mode's pixels down.</param>
    /// <param name="viewportWidthPoints">The device's viewport in points.</param>
    /// <param name="viewportHeightPoints">The device's viewport in points.</param>
    public static int Choose(int modeWidth, int modeHeight, double viewportWidthPoints, double viewportHeightPoints)
    {
        if (viewportWidthPoints <= 0 || viewportHeightPoints <= 0) return 100;
        // The picture is letterboxed into the viewport, so the tighter side sets its pixels per point.
        var wanted = Math.Max(modeWidth / viewportWidthPoints, modeHeight / viewportHeightPoints) * 100;
        return Steps.Where(step => modeWidth * 100 / step >= MinimumWidth && modeHeight * 100 / step >= MinimumHeight)
                    .DefaultIfEmpty(100)
                    .MinBy(step => Math.Abs(Math.Log(step / wanted)));
    }

    /// <summary>A display's scale now.</summary>
    /// <param name="Relative">The value to give <see cref="SetRelative"/> to come back to this.</param>
    /// <param name="Percent">The scale.</param>
    /// <param name="MaximumPercent">The largest Windows allows in this mode.</param>
    /// <param name="RecommendedIndex">Where Windows' recommended scale is in <see cref="Steps"/>.</param>
    public readonly record struct Scale(int Relative, int Percent, int MaximumPercent, int RecommendedIndex);

    /// <summary>The display's scale, or null when Windows won't say.</summary>
    public static Scale? Read(string gdiName)
    {
        if (Source(gdiName) is not { } source) return null;
        var packet = new GetPacket { Header = new Header { Type = -3, Size = (uint)sizeof(GetPacket), AdapterId = source.Adapter, Id = source.Id } };
        if (DisplayConfigGetDeviceInfo(&packet) != 0) return null;
        var recommended = Math.Abs(packet.Minimum);
        var current = recommended + packet.Current;
        var maximum = recommended + packet.Maximum;
        if (current < 0 || current >= Steps.Length || maximum < 0 || maximum >= Steps.Length) return null;
        return new Scale(packet.Current, Steps[current], Steps[maximum], recommended);
    }

    /// <summary>Sets a scale from <see cref="Steps"/>, as far as this mode allows.</summary>
    public static bool SetPercent(string gdiName, Scale now, int percent)
    {
        var index = Array.IndexOf(Steps, Math.Min(percent, now.MaximumPercent));
        return index >= 0 && SetRelative(gdiName, index - now.RecommendedIndex);
    }

    /// <summary>Sets the value <see cref="Read"/> reported.</summary>
    public static bool SetRelative(string gdiName, int relative)
    {
        if (Source(gdiName) is not { } source) return false;
        var packet = new SetPacket { Header = new Header { Type = -4, Size = (uint)sizeof(SetPacket), AdapterId = source.Adapter, Id = source.Id }, Relative = relative };
        return DisplayConfigSetDeviceInfo(&packet) == 0;
    }

    private static (LUID Adapter, uint Id)? Source(string gdiName)
    {
        for (var attempt = 0; attempt < 3; attempt++)
        {
            if (PInvoke.GetDisplayConfigBufferSizes(QUERY_DISPLAY_CONFIG_FLAGS.QDC_ONLY_ACTIVE_PATHS, out var pathCount, out var modeCount) != WIN32_ERROR.NO_ERROR) return null;
            var paths = new DISPLAYCONFIG_PATH_INFO[pathCount];
            var modes = new DISPLAYCONFIG_MODE_INFO[modeCount];
            var error = PInvoke.QueryDisplayConfig(QUERY_DISPLAY_CONFIG_FLAGS.QDC_ONLY_ACTIVE_PATHS, ref pathCount, paths, ref modeCount, modes);
            if (error == WIN32_ERROR.ERROR_INSUFFICIENT_BUFFER) continue;
            if (error != WIN32_ERROR.NO_ERROR) return null;
            for (var i = 0; i < pathCount; i++)
            {
                var name = new DISPLAYCONFIG_SOURCE_DEVICE_NAME();
                name.header.type = DISPLAYCONFIG_DEVICE_INFO_TYPE.DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
                name.header.size = (uint)sizeof(DISPLAYCONFIG_SOURCE_DEVICE_NAME);
                name.header.adapterId = paths[i].sourceInfo.adapterId;
                name.header.id = paths[i].sourceInfo.id;
                if (PInvoke.DisplayConfigGetDeviceInfo(&name.header) != 0) continue;
                var text = name.viewGdiDeviceName.AsReadOnlySpan();
                var end = text.IndexOf('\0');
                if ((end >= 0 ? text[..end] : text).SequenceEqual(gdiName)) return (paths[i].sourceInfo.adapterId, paths[i].sourceInfo.id);
            }
            return null;
        }
        return null;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Header
    {
        public int Type;
        public uint Size;
        public LUID AdapterId;
        public uint Id;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct GetPacket
    {
        public Header Header;
        public int Minimum, Current, Maximum;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SetPacket
    {
        public Header Header;
        public int Relative;
    }

    [DllImport("user32.dll")] private static extern int DisplayConfigGetDeviceInfo(GetPacket* packet);
    [DllImport("user32.dll")] private static extern int DisplayConfigSetDeviceInfo(SetPacket* packet);
}
