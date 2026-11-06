using Microsoft.Win32;

namespace Vantage.Host.Windows.Startup;

/// <summary>
/// The host's row in Windows' Installed apps, which Setup writes
/// (<c>WindowsHost\installer\CasementHost.iss</c>). The updater replaces the folder without Setup, so
/// the host keeps the row's version right itself. A copy from a zip has no row and does nothing here.
/// </summary>
public static class InstallRegistration
{
    /// <summary>Setup's uninstall key: the installer's AppId with Inno Setup's <c>_is1</c>.</summary>
    public const string KeyPath = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\{8E1F7C0A-3B52-4E7D-A6C4-2D9B1F60C7E4}_is1";

    /// <summary>
    /// Writes <paramref name="version"/> into the row when it belongs to the folder of
    /// <paramref name="executablePath"/> and says something else. True when it changed.
    /// </summary>
    public static bool SyncVersion(string executablePath, string version, string keyPath = KeyPath)
    {
        using var key = Registry.CurrentUser.OpenSubKey(keyPath, writable: true);
        if (key?.GetValue("InstallLocation") is not string location || !IsSameFolder(location, Path.GetDirectoryName(executablePath))) return false;
        if (key.GetValue("DisplayVersion") as string == version) return false;
        key.SetValue("DisplayVersion", version, RegistryValueKind.String);
        return true;
    }

    private static bool IsSameFolder(string a, string? b) =>
        !string.IsNullOrWhiteSpace(a) && !string.IsNullOrWhiteSpace(b)
        && string.Equals(Path.TrimEndingDirectorySeparator(Path.GetFullPath(a)), Path.TrimEndingDirectorySeparator(Path.GetFullPath(b)), StringComparison.OrdinalIgnoreCase);
}
