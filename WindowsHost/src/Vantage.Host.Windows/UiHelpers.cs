using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using DataPackage = global::Windows.ApplicationModel.DataTransfer.DataPackage;
using WindowsClipboard = global::Windows.ApplicationModel.DataTransfer.Clipboard;

namespace Vantage.Host.Windows.App;

/// <summary>Small things the tray panel and the pages share.</summary>
internal static class UiHelpers
{
    /// <summary>A resource from the app's dictionaries (theme brushes follow the system theme).</summary>
    public static T? Resource<T>(string key) where T : class =>
        Application.Current.Resources.TryGetValue(key, out var value) ? value as T : null;

    /// <summary>A Segoe Fluent Icons glyph at the size Settings uses beside a row's text.</summary>
    public static FontIcon Glyph(string glyph, double size = 16) => new() { Glyph = glyph, FontSize = size };

    /// <summary>
    /// A glyph for what the device calls itself. A guess from the name, which is all the host has
    /// (the Mac host's <c>DeviceSymbol</c> does the same for older pairings); a tablet otherwise.
    /// </summary>
    public static string DeviceGlyph(string name)
    {
        if (name.Contains("iphone", StringComparison.OrdinalIgnoreCase)) return "";   // CellPhone
        if (name.Contains("mac", StringComparison.OrdinalIgnoreCase)) return "";      // Laptop
        return "";                                                                    // Tablet
    }

    /// <summary>"Expires in 9 minutes" for a pairing code, or seconds in its last minute.</summary>
    public static string ExpiryText(TimeSpan left)
    {
        if (left.TotalSeconds < 60)
        {
            var seconds = Math.Max(1, (int)Math.Ceiling(left.TotalSeconds));
            return seconds == 1 ? "Expires in 1 second" : $"Expires in {seconds} seconds";
        }
        var minutes = (int)Math.Ceiling(left.TotalMinutes);
        return minutes == 1 ? "Expires in 1 minute" : $"Expires in {minutes} minutes";
    }

    /// <summary>Puts <paramref name="text"/> on the clipboard and has <paramref name="button"/> say so for a moment.</summary>
    public static void Copy(string text, Button button)
    {
        var package = new DataPackage();
        package.SetText(text);
        WindowsClipboard.SetContent(package);

        if (button.Tag is null) button.Tag = button.Content;
        button.Content = "Copied";
        var timer = DispatcherQueue.GetForCurrentThread().CreateTimer();
        timer.Interval = TimeSpan.FromSeconds(1.5);
        timer.IsRepeating = false;
        timer.Tick += (_, _) => button.Content = button.Tag;
        timer.Start();
    }

    /// <summary>The brush for a status dot or badge.</summary>
    public static Brush? StatusBrush(HostStatus status) => Resource<Brush>(status switch
    {
        HostStatus.Problem => "SystemFillColorCriticalBrush",
        HostStatus.Starting => "SystemFillColorCautionBrush",
        HostStatus.Busy => "AccentFillColorDefaultBrush",
        _ => "SystemFillColorSuccessBrush",
    });
}

/// <summary>What the status dot and the General page's status row say about the host.</summary>
internal enum HostStatus
{
    /// <summary>Listening; nothing else to report.</summary>
    Ready,
    /// <summary>Not listening yet.</summary>
    Starting,
    /// <summary>A device is connected or files are moving.</summary>
    Busy,
    /// <summary>It can't accept connections.</summary>
    Problem,
}
