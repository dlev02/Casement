using System.Runtime.InteropServices;
using Microsoft.Extensions.Logging;
using Vantage.Host.Windows.Storage;
using Vantage.Protocol.Host;
using Vantage.Protocol.Messages;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.UI.Shell;

namespace Vantage.Host.Windows.Files;

/// <summary>
/// <see cref="IFileStore"/> for Windows (spec §10.6–10.8): Downloads (<c>FOLDERID_Downloads</c>) or
/// the Settings folder, partials hidden while they arrive, and every saved file marked as downloaded
/// from the Internet with a <c>Zone.Identifier</c> stream (Mark of the Web), so SmartScreen and
/// Office treat it like a browser download.
/// </summary>
public sealed class WindowsFileStore : IFileStore
{
    private readonly HostSettingsStore? _settings;
    private readonly string? _override;
    private readonly ILogger _log;

    /// <param name="settings">Settings (receive folder), or null to use only Downloads/the override.</param>
    /// <param name="overridePath"><c>--receive-folder</c>.</param>
    /// <param name="logging">Loggers (category <c>Vantage.Files</c>).</param>
    public WindowsFileStore(HostSettingsStore? settings, string? overridePath, ILoggerFactory logging)
    {
        _settings = settings;
        _override = overridePath;
        _log = logging.CreateLogger("Vantage.Files");
    }

    /// <summary>A file was saved (any thread): the app shows a notification and runs the after-arrival action.</summary>
    public event Action<string, FileOffer>? Saved;

    /// <inheritdoc />
    public string ReceiveDirectory =>
        ReceiveFolder.Resolve(_override, _settings?.Current.ReceiveFolder, DownloadsFolder(), ReceiveFolder.IsWritableDirectory);

    /// <inheritdoc />
    public bool IsCaseInsensitive => true;

    /// <inheritdoc />
    public long? GetAvailableFreeSpace(string directory)
    {
        try
        {
            var root = Path.GetPathRoot(Path.GetFullPath(directory));
            return string.IsNullOrEmpty(root) ? null : new DriveInfo(root).AvailableFreeSpace;
        }
        catch (Exception ex) when (ex is IOException or ArgumentException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    /// <inheritdoc />
    public void OnPartialCreated(string partialPath)
    {
        try { File.SetAttributes(partialPath, File.GetAttributes(partialPath) | FileAttributes.Hidden); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { _log.LogDebug("hiding {Path}: {Message}", partialPath, ex.Message); }
    }

    /// <inheritdoc />
    public void OnBeforeFinalize(string partialPath)
    {
        try { File.SetAttributes(partialPath, File.GetAttributes(partialPath) & ~FileAttributes.Hidden); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { _log.LogDebug("unhiding {Path}: {Message}", partialPath, ex.Message); }
    }

    /// <inheritdoc />
    public void OnSaved(string path, FileOffer offer)
    {
        try
        {
            File.WriteAllText(path + ":Zone.Identifier", ArrivalPolicy.ZoneIdentifier);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or NotSupportedException)
        {
            // FAT32/exFAT drives and some network shares have no alternate data streams.
            _log.LogInformation("couldn't mark {Path} as downloaded: {Message}", path, ex.Message);
        }
        try
        {
            Saved?.Invoke(path, offer);
        }
        catch (Exception ex)
        {
            _log.LogWarning(ex, "after-arrival handling failed");
        }
    }

    /// <summary>The user's Downloads folder (<c>FOLDERID_Downloads</c>, which follows a moved Downloads).</summary>
    public static unsafe string DownloadsFolder()
    {
        PWSTR path;
        var id = PInvoke.FOLDERID_Downloads;
        if (PInvoke.SHGetKnownFolderPath(&id, KNOWN_FOLDER_FLAG.KF_FLAG_DEFAULT, HANDLE.Null, &path).Succeeded)
        {
            try { return path.ToString(); }
            finally { Marshal.FreeCoTaskMem((nint)path.Value); }
        }
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
    }
}
