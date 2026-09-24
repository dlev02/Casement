using Vantage.Protocol.Messages;

namespace Vantage.Protocol.Host;

/// <summary>
/// Where received files go and how they're marked (spec §10.6–10.8). The file engine itself
/// (partials, resume, hashing, naming) is in the protocol library; this is the platform's say.
/// </summary>
public interface IFileStore
{
    /// <summary>
    /// The folder received files are saved in, resolved now: <c>FOLDERID_Downloads</c>, or the folder
    /// chosen in Settings while it exists and is writable, else Downloads again. The synthetic host
    /// uses <c>$TMPDIR/VantageSynthetic/Received</c> or <c>--receive-folder</c>. Read once per file
    /// channel, so a change applies from the next connection. The engine creates it if missing.
    /// </summary>
    string ReceiveDirectory { get; }

    /// <summary>File names in the receive folder compare case-insensitively (true on NTFS).</summary>
    bool IsCaseInsensitive { get; }

    /// <summary>Free bytes on the volume holding <paramref name="directory"/>, or null to skip the free-space check.</summary>
    long? GetAvailableFreeSpace(string directory);

    /// <summary>
    /// A new hidden partial (<c>.vantage-&lt;ID&gt;.partial</c>) was just created (Windows: set
    /// <c>FileAttributes.Hidden</c>). Errors are logged, not fatal.
    /// </summary>
    void OnPartialCreated(string partialPath);

    /// <summary>
    /// The finished partial is about to be renamed to its final name (Windows: clear
    /// <c>FileAttributes.Hidden</c> first). Errors are logged, not fatal.
    /// </summary>
    void OnBeforeFinalize(string partialPath);

    /// <summary>
    /// A received file was saved at <paramref name="path"/> (Windows: write the
    /// <c>Zone.Identifier</c> stream <c>[ZoneTransfer]\r\nZoneId=3</c>, then tell the UI).
    /// Called on the engine's thread; don't block.
    /// </summary>
    void OnSaved(string path, FileOffer offer);

    /// <summary>
    /// The same, with who sent it (for "Report.pdf from Drew's iPad"). The core calls this one;
    /// by default it forwards to <see cref="OnSaved(string, FileOffer)"/>.
    /// </summary>
    void OnSaved(string path, FileOffer offer, FileSender sender) => OnSaved(path, offer);
}

/// <summary>Who a received file came from.</summary>
/// <param name="Name">The device's name: the tailnet device name when known, else what it calls itself ("iPad").</param>
/// <param name="Fingerprint">Its key fingerprint (the same on every connection).</param>
public sealed record FileSender(string Name, string Fingerprint);
