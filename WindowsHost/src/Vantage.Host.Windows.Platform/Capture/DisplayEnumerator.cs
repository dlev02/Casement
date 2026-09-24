using System.Runtime.InteropServices;
using Microsoft.Extensions.Logging;
using Vantage.Protocol.Messages;
using Windows.Win32;
using Windows.Win32.Devices.Display;
using Windows.Win32.Foundation;
using Windows.Win32.Graphics.Gdi;
using Windows.Win32.UI.HiDpi;

namespace Vantage.Host.Windows.Capture;

/// <summary>A monitor as the host sees it: the wire <see cref="DisplayInfo"/> plus its <c>HMONITOR</c>.</summary>
/// <param name="Info">What the client is told (spec §9.2).</param>
/// <param name="Monitor">The <c>HMONITOR</c> for capture; valid until the topology changes.</param>
/// <param name="GdiName"><c>\\.\DISPLAYn</c>.</param>
public sealed record MonitorEntry(DisplayInfo Info, nint Monitor, string GdiName);

/// <summary>
/// Lists monitors with <c>EnumDisplayMonitors</c> + <c>GetMonitorInfo</c> (rect, primary, GDI name),
/// <c>GetDpiForMonitor(MDT_EFFECTIVE_DPI)</c> (scale), <c>EnumDisplaySettings</c> (refresh) and
/// DisplayConfig (friendly name, output technology). The process must be per-monitor-v2 DPI aware so
/// rects are physical pixels.
/// </summary>
public static unsafe class DisplayEnumerator
{
    /// <summary>Every active monitor, primary first. Empty when the topology is empty (a DisplayPort monitor asleep).</summary>
    public static IReadOnlyList<MonitorEntry> Enumerate(ILogger? log = null)
    {
        var handles = new List<nint>();
        var gcHandle = GCHandle.Alloc(handles);
        try
        {
            PInvoke.EnumDisplayMonitors(HDC.Null, (RECT*)null, &OnMonitor, (LPARAM)GCHandle.ToIntPtr(gcHandle));
        }
        finally
        {
            gcHandle.Free();
        }

        var targets = TargetsBySourceName(log);
        var entries = new List<MonitorEntry>(handles.Count);
        foreach (var handle in handles)
        {
            var info = new MONITORINFOEXW();
            info.monitorInfo.cbSize = (uint)sizeof(MONITORINFOEXW);
            if (!PInvoke.GetMonitorInfo((HMONITOR)handle, (MONITORINFO*)&info)) continue;
            var gdiName = NativeText(info.szDevice.AsReadOnlySpan());
            var number = DisplayMath.DisplayNumber(gdiName);
            if (number is null) continue;

            var rect = info.monitorInfo.rcMonitor;
            var pixelWidth = rect.right - rect.left;
            var pixelHeight = rect.bottom - rect.top;
            uint dpiX = 96, dpiY = 96;
            if (PInvoke.GetDpiForMonitor((HMONITOR)handle, MONITOR_DPI_TYPE.MDT_EFFECTIVE_DPI, &dpiX, &dpiY).Failed) dpiX = 96;
            var scale = DisplayMath.Scale(dpiX);

            var mode = new DEVMODEW { dmSize = (ushort)sizeof(DEVMODEW) };
            double refresh = 60;
            fixed (char* name = gdiName)
            {
                if (PInvoke.EnumDisplaySettings(name, ENUM_DISPLAY_SETTINGS_MODE.ENUM_CURRENT_SETTINGS, &mode))
                    refresh = DisplayMath.RefreshRate(mode.dmDisplayFrequency);
            }

            targets.TryGetValue(gdiName, out var target);
            var isPrimary = (info.monitorInfo.dwFlags & 1u) != 0; // MONITORINFOF_PRIMARY
            var friendly = string.IsNullOrWhiteSpace(target.FriendlyName)
                ? (target.IsBuiltIn ? "Built-in Display" : $"Display {number}")
                : target.FriendlyName;

            entries.Add(new MonitorEntry(new DisplayInfo
            {
                Id = number.Value,
                Name = friendly,
                PixelWidth = pixelWidth,
                PixelHeight = pixelHeight,
                PointWidth = DisplayMath.Points(pixelWidth, scale),
                PointHeight = DisplayMath.Points(pixelHeight, scale),
                Scale = scale,
                OriginX = rect.left,
                OriginY = rect.top,
                IsMain = isPrimary,
                IsBuiltIn = target.IsBuiltIn,
                IsVirtual = false,
                RefreshRate = refresh,
            }, handle, gdiName));
        }
        entries.Sort((a, b) => b.Info.IsMain.CompareTo(a.Info.IsMain));
        return entries;
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvStdcall)])]
    private static BOOL OnMonitor(HMONITOR monitor, HDC hdc, RECT* rect, LPARAM data)
    {
        var list = (List<nint>)GCHandle.FromIntPtr(data.Value).Target!;
        list.Add((nint)monitor.Value);
        return true;
    }

    private readonly record struct TargetInfo(string? FriendlyName, bool IsBuiltIn);

    /// <summary>GDI source name (<c>\\.\DISPLAYn</c>) → the monitor's friendly name and output technology.</summary>
    private static Dictionary<string, TargetInfo> TargetsBySourceName(ILogger? log)
    {
        var result = new Dictionary<string, TargetInfo>(StringComparer.OrdinalIgnoreCase);
        for (var attempt = 0; attempt < 3; attempt++)
        {
            if (PInvoke.GetDisplayConfigBufferSizes(QUERY_DISPLAY_CONFIG_FLAGS.QDC_ONLY_ACTIVE_PATHS, out var pathCount, out var modeCount) != WIN32_ERROR.NO_ERROR)
                return result;
            var paths = new DISPLAYCONFIG_PATH_INFO[pathCount];
            var modes = new DISPLAYCONFIG_MODE_INFO[modeCount];
            var error = PInvoke.QueryDisplayConfig(QUERY_DISPLAY_CONFIG_FLAGS.QDC_ONLY_ACTIVE_PATHS, ref pathCount, paths, ref modeCount, modes);
            if (error == WIN32_ERROR.ERROR_INSUFFICIENT_BUFFER) continue;
            if (error != WIN32_ERROR.NO_ERROR)
            {
                log?.LogDebug("QueryDisplayConfig failed: {Error}", error);
                return result;
            }

            for (var i = 0; i < pathCount; i++)
            {
                var path = paths[i];
                var source = new DISPLAYCONFIG_SOURCE_DEVICE_NAME();
                source.header.type = DISPLAYCONFIG_DEVICE_INFO_TYPE.DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
                source.header.size = (uint)sizeof(DISPLAYCONFIG_SOURCE_DEVICE_NAME);
                source.header.adapterId = path.sourceInfo.adapterId;
                source.header.id = path.sourceInfo.id;
                if (PInvoke.DisplayConfigGetDeviceInfo(&source.header) != 0) continue;

                var target = new DISPLAYCONFIG_TARGET_DEVICE_NAME();
                target.header.type = DISPLAYCONFIG_DEVICE_INFO_TYPE.DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME;
                target.header.size = (uint)sizeof(DISPLAYCONFIG_TARGET_DEVICE_NAME);
                target.header.adapterId = path.targetInfo.adapterId;
                target.header.id = path.targetInfo.id;
                string? friendly = null;
                if (PInvoke.DisplayConfigGetDeviceInfo(&target.header) == 0)
                    friendly = NativeText(target.monitorFriendlyDeviceName.AsReadOnlySpan());

                var gdiName = NativeText(source.viewGdiDeviceName.AsReadOnlySpan());
                result.TryAdd(gdiName, new TargetInfo(friendly, DisplayMath.IsBuiltIn((uint)path.targetInfo.outputTechnology)));
            }
            return result;
        }
        return result;
    }

    private static string NativeText(ReadOnlySpan<char> text)
    {
        var end = text.IndexOf('\0');
        return (end >= 0 ? text[..end] : text).ToString();
    }
}
