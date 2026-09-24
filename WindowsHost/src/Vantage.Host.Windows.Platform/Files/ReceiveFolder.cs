namespace Vantage.Host.Windows.Files;

/// <summary>
/// Chooses the receive folder (spec §10.8): an explicit override (<c>--receive-folder</c>), else
/// the folder chosen in Settings while it exists and is writable, else Downloads. Pure apart from
/// the injected checks; unit-tested on macOS.
/// </summary>
public static class ReceiveFolder
{
    /// <summary>
    /// The folder to use now.
    /// </summary>
    /// <param name="overridePath"><c>--receive-folder</c> (created if missing, always used).</param>
    /// <param name="chosen">Settings → Files, or null.</param>
    /// <param name="downloads">The Downloads folder.</param>
    /// <param name="isUsable">Whether a folder exists and can be written to.</param>
    public static string Resolve(string? overridePath, string? chosen, string downloads, Func<string, bool> isUsable)
    {
        if (!string.IsNullOrWhiteSpace(overridePath)) return overridePath;
        if (!string.IsNullOrWhiteSpace(chosen) && isUsable(chosen)) return chosen;
        return downloads;
    }

    /// <summary>A real check: the folder exists and a temporary file can be created in it.</summary>
    public static bool IsWritableDirectory(string path)
    {
        try
        {
            if (!Directory.Exists(path)) return false;
            var probe = Path.Combine(path, ".vantage-write-test-" + Guid.NewGuid().ToString("N"));
            using (File.Create(probe, 1, FileOptions.DeleteOnClose)) { }
            return true;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            return false;
        }
    }
}

/// <summary>What to do with arrived files, and which files are safe to open automatically. Pure.</summary>
public static class ArrivalPolicy
{
    /// <summary>Contents of the <c>Zone.Identifier</c> stream: "from the Internet" (zone 3), like a browser download.</summary>
    public const string ZoneIdentifier = "[ZoneTransfer]\r\nZoneId=3\r\n";

    /// <summary>More files than this in one batch are shown in the folder instead of opened.</summary>
    public const int MaxFilesToOpen = 5;

    private static readonly HashSet<string> s_openable = new(StringComparer.OrdinalIgnoreCase)
    {
        // Documents that run no code
        ".pdf", ".txt", ".rtf", ".md", ".csv", ".log", ".json", ".xml",
        ".docx", ".xlsx", ".pptx", ".doc", ".xls", ".ppt", ".odt", ".ods", ".odp",
        // Images
        ".jpg", ".jpeg", ".png", ".gif", ".bmp", ".tif", ".tiff", ".webp", ".heic", ".heif", ".avif",
        // Audio and video
        ".mp3", ".m4a", ".aac", ".wav", ".flac", ".ogg", ".mp4", ".m4v", ".mov", ".mkv", ".webm", ".avi",
    };

    /// <summary>Whether a received file may be opened with its default app (an allowlist: nothing that runs code, installs, or points elsewhere).</summary>
    public static bool CanAutoOpen(string path) => s_openable.Contains(Path.GetExtension(path));
}
