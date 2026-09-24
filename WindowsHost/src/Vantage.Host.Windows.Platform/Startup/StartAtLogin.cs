using Microsoft.Win32;

namespace Vantage.Host.Windows.Startup;

/// <summary>
/// "Start Vantage Host when I sign in": the <c>HKCU\Software\Microsoft\Windows\CurrentVersion\Run</c>
/// value <c>Vantage Host</c> = <c>"…\VantageHost.exe" --background</c> (plan §1; <c>StartupTask</c> needs
/// packaging). Windows' Startup apps page can still turn it off; that shows up here as disabled.
/// </summary>
public static class StartAtLogin
{
    /// <summary>The Run value's name.</summary>
    public const string ValueName = "Vantage Host";

    /// <summary>The flag the app gets at login: start in the tray without opening the window.</summary>
    public const string BackgroundFlag = "--background";

    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ApprovedKey = @"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run";

    /// <summary>The command line stored in the Run value. Pure.</summary>
    public static string Command(string executablePath) => $"\"{executablePath}\" {BackgroundFlag}";

    /// <summary>Whether a Run value starts this executable. Pure.</summary>
    public static bool PointsAt(string? command, string executablePath)
    {
        if (string.IsNullOrWhiteSpace(command)) return false;
        var trimmed = command.Trim();
        string path;
        if (trimmed.StartsWith('"'))
        {
            var end = trimmed.IndexOf('"', 1);
            if (end < 0) return false;
            path = trimmed[1..end];
        }
        else
        {
            var space = trimmed.IndexOf(' ');
            path = space < 0 ? trimmed : trimmed[..space];
        }
        return string.Equals(Path.GetFullPath(path), Path.GetFullPath(executablePath), StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>
    /// Whether the Startup apps switch leaves it on: <c>StartupApproved\Run</c> holds 12 bytes whose
    /// first byte is even (2) when enabled and odd (3) when the user switched it off. Pure.
    /// </summary>
    public static bool IsApproved(byte[]? approval) => approval is not { Length: > 0 } || (approval[0] & 1) == 0;

    /// <summary>Whether starting at login is on for <paramref name="executablePath"/>.</summary>
    public static bool IsEnabled(string executablePath)
    {
        using var run = Registry.CurrentUser.OpenSubKey(RunKey);
        if (!PointsAt(run?.GetValue(ValueName) as string, executablePath)) return false;
        using var approved = Registry.CurrentUser.OpenSubKey(ApprovedKey);
        return IsApproved(approved?.GetValue(ValueName) as byte[]);
    }

    /// <summary>Turns starting at login on or off.</summary>
    public static void SetEnabled(string executablePath, bool enabled)
    {
        using var run = Registry.CurrentUser.CreateSubKey(RunKey, writable: true);
        if (enabled)
        {
            run.SetValue(ValueName, Command(executablePath), RegistryValueKind.String);
            // Clear a previous "off" from Settings → Apps → Startup so turning it on here works.
            using var approved = Registry.CurrentUser.OpenSubKey(ApprovedKey, writable: true);
            approved?.DeleteValue(ValueName, throwOnMissingValue: false);
        }
        else
        {
            run.DeleteValue(ValueName, throwOnMissingValue: false);
        }
    }
}
