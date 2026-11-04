using Microsoft.Win32;

namespace Vantage.Host.Windows.Tray;

/// <summary>
/// Whether Windows 11 shows the host's icon next to the clock or behind the ^ (Settings ›
/// Personalization › Taskbar › Other system tray icons). Explorer keeps that choice per executable
/// under <c>HKCU\Control Panel\NotifyIconSettings\&lt;id&gt;</c> (<c>ExecutablePath</c>, and
/// <c>IsPromoted</c> 1 = next to the clock, 0 or missing = behind the ^), adds the entry when the
/// icon first appears, and applies a change at once. The key is undocumented, so everything here
/// is best effort: no entry means "unknown" and the switch stays unavailable, never an error.
/// </summary>
public static class TrayIconVisibility
{
    private const string Key = @"Control Panel\NotifyIconSettings";

    /// <summary>Whether an entry's <c>ExecutablePath</c> is <paramref name="executablePath"/>. Pure.</summary>
    public static bool Matches(string? entryPath, string executablePath) =>
        !string.IsNullOrWhiteSpace(entryPath)
        && string.Equals(Path.GetFullPath(entryPath), Path.GetFullPath(executablePath), StringComparison.OrdinalIgnoreCase);

    /// <summary>What an entry's <c>IsPromoted</c> value means: 1 shown, anything else (or missing) hidden. Pure.</summary>
    public static bool IsShown(object? isPromoted) => isPromoted is int value && value != 0;

    /// <summary>
    /// True when the icon sits next to the clock, false when it's behind the ^, null when Windows
    /// has no entry for <paramref name="executablePath"/> (the icon hasn't appeared yet, or an
    /// older Windows).
    /// </summary>
    public static bool? Shown(string executablePath)
    {
        try
        {
            using var entry = Find(executablePath, writable: false);
            return entry is null ? null : IsShown(entry.GetValue("IsPromoted"));
        }
        catch (Exception ex) when (ex is System.Security.SecurityException or IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    /// <summary>Moves the icon next to the clock or behind the ^. False when there's no entry or the registry refused.</summary>
    public static bool SetShown(string executablePath, bool shown)
    {
        try
        {
            using var entry = Find(executablePath, writable: true);
            if (entry is null) return false;
            entry.SetValue("IsPromoted", shown ? 1 : 0, RegistryValueKind.DWord);
            return true;
        }
        catch (Exception ex) when (ex is System.Security.SecurityException or IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    private static RegistryKey? Find(string executablePath, bool writable)
    {
        using var root = Registry.CurrentUser.OpenSubKey(Key);
        if (root is null) return null;
        foreach (var name in root.GetSubKeyNames())
        {
            var entry = root.OpenSubKey(name, writable);
            if (entry is null) continue;
            if (Matches(entry.GetValue("ExecutablePath") as string, executablePath)) return entry;
            entry.Dispose();
        }
        return null;
    }
}
