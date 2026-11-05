using System.Diagnostics;
using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Extensions.Logging;
using Vantage.Protocol.Auth;
using Vantage.Protocol.Updates;

namespace Vantage.Host.Windows.Updates;

/// <summary>Where an update stands.</summary>
public enum UpdateStage
{
    /// <summary>Nothing has been checked in this run.</summary>
    Idle,
    /// <summary>Asking GitHub.</summary>
    Checking,
    /// <summary>This is the newest version.</summary>
    UpToDate,
    /// <summary>Fetching a newer one (<see cref="UpdateStatus.Fraction"/>).</summary>
    Downloading,
    /// <summary>Verified and staged; it installs at the next quiet moment, or when asked.</summary>
    Ready,
    /// <summary>There's a newer one, but this folder can't be changed: it has to be downloaded by hand.</summary>
    ManualOnly,
    /// <summary>The check or the download failed (<see cref="UpdateStatus.Message"/>); the next check tries again.</summary>
    Failed,
    /// <summary>A newer version was put in place and wouldn't start, so this one came back.</summary>
    RolledBack,
}

/// <summary>What the Settings row shows.</summary>
/// <param name="Stage">Where it stands.</param>
public sealed record UpdateStatus(UpdateStage Stage)
{
    /// <summary>The version on offer ("1.5"), once known.</summary>
    public string? Version { get; init; }

    /// <summary>The release's page.</summary>
    public string? NotesUrl { get; init; }

    /// <summary>0–1 while downloading.</summary>
    public double Fraction { get; init; }

    /// <summary>A failure's reason, in a sentence.</summary>
    public string? Message { get; init; }
}

/// <summary>What <see cref="HostUpdater"/> needs to know about this copy.</summary>
/// <param name="FeedBaseUrl">Where <c>windows-update.json</c> and its <c>.sig</c> are, ending in a slash.</param>
/// <param name="PublicKey">The key a manifest must be signed with.</param>
/// <param name="CurrentVersion">This version.</param>
/// <param name="InstallDirectory">This copy's folder.</param>
/// <param name="UpdatesDirectory">The data folder's <c>updates</c>: the download, and the swap's markers.</param>
public sealed record HostUpdaterOptions(string FeedBaseUrl, byte[] PublicKey, string CurrentVersion, string InstallDirectory, string UpdatesDirectory);

/// <summary>
/// Finds, fetches and verifies a newer Casement Host. A manifest counts only if its signature checks
/// out against the key built into this app, a download only if its SHA-256 is the signed one, and a
/// staged copy only if it says it's the version on offer, so nothing short of the signing key can
/// put anything in the install folder. Nothing here runs the update: <see cref="UpdateInstaller"/>
/// does, once the app says it's a good moment. Used on the UI thread; <see cref="Changed"/> is raised there too.
/// </summary>
public sealed class HostUpdater
{
    /// <summary>Where a published release's files are: GitHub always serves the latest one here.</summary>
    public const string ReleaseFeed = "https://github.com/dlev02/Casement/releases/latest/download/";

    /// <summary>The signed manifest's name on a release.</summary>
    public const string ManifestName = "windows-update.json";

    /// <summary>
    /// The public half of the release signing key (the private half is only on the release machine;
    /// <c>tools/UpdateSigner</c> made them). Changing it strands every copy already out there.
    /// </summary>
    public const string ReleasePublicKeyHex = "36d83eafa13daf91bca1618e78ab894e9d01c54ee21bac15ac1c3bf5c470f50e";

    private readonly HttpClient _http;
    private readonly HostUpdaterOptions _options;
    private readonly IEd25519 _ed25519;
    private readonly ILogger _log;
    private bool _busy;

    /// <param name="http">Talks to the feed.</param>
    /// <param name="options">About this copy.</param>
    /// <param name="ed25519">Checks signatures.</param>
    /// <param name="log">Logs.</param>
    public HostUpdater(HttpClient http, HostUpdaterOptions options, IEd25519 ed25519, ILogger log)
    {
        _http = http;
        _options = options;
        _ed25519 = ed25519;
        _log = log;
        // Back from a version that wouldn't start: say so until a check says otherwise.
        if (ReadSkippedVersion() is { } skipped && UpdateVersion.IsNewer(skipped, options.CurrentVersion))
            Status = new UpdateStatus(UpdateStage.RolledBack) { Version = skipped };
    }

    /// <summary>Raised when <see cref="Status"/> changes.</summary>
    public event Action? Changed;

    /// <summary>Where things stand.</summary>
    public UpdateStatus Status { get; private set; } = new(UpdateStage.Idle);

    /// <summary>The processor architecture's name in a manifest.</summary>
    public static string Architecture => RuntimeInformation.ProcessArchitecture == System.Runtime.InteropServices.Architecture.Arm64 ? "arm64" : "x64";

    /// <summary>Checks, and fetches anything newer.</summary>
    /// <param name="userAsked">Someone pressed the button: a version that failed before is tried again.</param>
    /// <param name="cancellationToken">Stops it.</param>
    public async Task CheckAsync(bool userAsked, CancellationToken cancellationToken = default)
    {
        if (_busy) return;
        _busy = true;
        var before = Status;
        // A background check that finds the same thing shouldn't flicker the row.
        if (userAsked || before.Stage is not (UpdateStage.Ready or UpdateStage.RolledBack)) Set(new UpdateStatus(UpdateStage.Checking));
        try
        {
            var manifest = await FetchManifestAsync(cancellationToken);
            if (manifest is null)
            {
                Set(before.Stage == UpdateStage.Ready ? before : new UpdateStatus(UpdateStage.UpToDate));
                return;
            }
            if (!UpdateVersion.IsNewer(manifest.Version, _options.CurrentVersion)
                || !manifest.Assets.TryGetValue(Architecture, out var asset))
            {
                Set(new UpdateStatus(UpdateStage.UpToDate));
                return;
            }
            var version = UpdateVersion.Display(manifest.Version);
            if (!userAsked && ReadSkippedVersion() is { } skipped && !UpdateVersion.IsNewer(manifest.Version, skipped))
            {
                Set(new UpdateStatus(UpdateStage.RolledBack) { Version = version, NotesUrl = manifest.NotesUrl });
                return;
            }
            if (!UpdateInstaller.CanReplace(_options.InstallDirectory))
            {
                Set(new UpdateStatus(UpdateStage.ManualOnly) { Version = version, NotesUrl = manifest.NotesUrl });
                return;
            }
            if (before is { Stage: UpdateStage.Ready } && before.Version == version && StagedCopyIs(manifest.Version))
            {
                Set(before);
                return;
            }
            await DownloadAndStageAsync(manifest, asset, version, cancellationToken);
        }
        catch (UpdateRefusedException ex)
        {
            _log.LogWarning("update refused: {Reason}", ex.Message);
            Set(new UpdateStatus(UpdateStage.Failed) { Message = ex.Message });
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or IOException or UnauthorizedAccessException or InvalidDataException)
        {
            _log.LogInformation("update check failed: {Reason}", ex.Message);
            Set(new UpdateStatus(UpdateStage.Failed)
            {
                Message = ex is HttpRequestException or TaskCanceledException ? "GitHub couldn't be reached." : "The download couldn't be saved.",
            });
        }
        finally
        {
            _busy = false;
        }
    }

    /// <summary>A verified copy is staged and nothing is touching it.</summary>
    public bool IsReady => Status.Stage == UpdateStage.Ready && !_busy;

    /// <summary>Windows wouldn't run the staged copy (Smart App Control, say); the host keeps running.</summary>
    public void ReportSwapFailed() =>
        Set(new UpdateStatus(UpdateStage.Failed) { Message = "Windows wouldn't start the new version." });

    private async Task<UpdateManifest?> FetchManifestAsync(CancellationToken cancellationToken)
    {
        var bytes = await GetSmallAsync(_options.FeedBaseUrl + ManifestName, cancellationToken);
        // A release without a manifest (a Mac-only one, say) just means nothing's on offer here.
        if (bytes is null) return null;
        var signature = await GetSmallAsync(_options.FeedBaseUrl + ManifestName + ".sig", cancellationToken);
        if (signature is null) throw new UpdateRefusedException("The update didn't pass its security check.");
        if (!UpdateSignature.Verify(_ed25519, _options.PublicKey, bytes, System.Text.Encoding.UTF8.GetString(signature)))
            throw new UpdateRefusedException("The update didn't pass its security check.");
        return UpdateManifest.Parse(bytes) ?? throw new UpdateRefusedException("The update didn't pass its security check.");
    }

    private async Task<byte[]?> GetSmallAsync(string url, CancellationToken cancellationToken)
    {
        using var response = await _http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
        if (response.StatusCode == System.Net.HttpStatusCode.NotFound) return null;
        response.EnsureSuccessStatusCode();
        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
        using var buffer = new MemoryStream();
        var chunk = new byte[8192];
        int read;
        while ((read = await stream.ReadAsync(chunk, cancellationToken)) > 0)
        {
            buffer.Write(chunk, 0, read);
            if (buffer.Length > UpdateManifest.MaxBytes) throw new UpdateRefusedException("The update didn't pass its security check.");
        }
        return buffer.ToArray();
    }

    private async Task DownloadAndStageAsync(UpdateManifest manifest, UpdateAsset asset, string version, CancellationToken cancellationToken)
    {
        Directory.CreateDirectory(_options.UpdatesDirectory);
        var zip = Path.Combine(_options.UpdatesDirectory, "download.zip");
        var downloading = new UpdateStatus(UpdateStage.Downloading) { Version = version, NotesUrl = manifest.NotesUrl };
        Set(downloading);
        try
        {
            using (var response = await _http.GetAsync(asset.Url, HttpCompletionOption.ResponseHeadersRead, cancellationToken))
            {
                response.EnsureSuccessStatusCode();
                await using var input = await response.Content.ReadAsStreamAsync(cancellationToken);
                await using var output = new FileStream(zip, FileMode.Create, FileAccess.Write, FileShare.None);
                using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
                var buffer = new byte[256 * 1024];
                long total = 0;
                var lastReport = Stopwatch.StartNew();
                int read;
                while ((read = await input.ReadAsync(buffer, cancellationToken)) > 0)
                {
                    total += read;
                    // Never more than was signed for, whatever the server sends.
                    if (total > asset.Size) throw new UpdateRefusedException("The update didn't pass its security check.");
                    hash.AppendData(buffer, 0, read);
                    await output.WriteAsync(buffer.AsMemory(0, read), cancellationToken);
                    if (lastReport.ElapsedMilliseconds >= 250)
                    {
                        lastReport.Restart();
                        Set(downloading with { Fraction = asset.Size > 0 ? (double)total / asset.Size : 0 });
                    }
                }
                if (total != asset.Size || !string.Equals(Convert.ToHexStringLower(hash.GetHashAndReset()), asset.Sha256, StringComparison.OrdinalIgnoreCase))
                    throw new UpdateRefusedException("The update didn't pass its security check.");
            }
            await Task.Run(() => Stage(zip, manifest.Version), cancellationToken);
            _log.LogInformation("update {Version} is ready", version);
            Set(new UpdateStatus(UpdateStage.Ready) { Version = version, NotesUrl = manifest.NotesUrl });
        }
        finally
        {
            try { File.Delete(zip); } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
        }
    }

    /// <summary>Unzips beside the install folder. The zip holds a "Casement Host" folder; a flat one works too.</summary>
    private void Stage(string zip, string version)
    {
        var staged = UpdateInstaller.StagedDirectory(_options.InstallDirectory);
        var temporary = staged + ".tmp";
        if (Directory.Exists(staged)) Directory.Delete(staged, recursive: true);
        if (Directory.Exists(temporary)) Directory.Delete(temporary, recursive: true);
        // ExtractToDirectory refuses entries that climb out of the folder.
        ZipFile.ExtractToDirectory(zip, temporary);
        var root = File.Exists(Path.Combine(temporary, UpdateInstaller.ExecutableName))
            ? temporary
            : Directory.EnumerateDirectories(temporary).FirstOrDefault(d => File.Exists(Path.Combine(d, UpdateInstaller.ExecutableName)));
        if (root is null) throw new UpdateRefusedException("The update didn't contain Casement Host.");
        Directory.Move(root, staged);
        if (Directory.Exists(temporary)) Directory.Delete(temporary, recursive: true);
        // A release whose exe isn't the version it claims would install forever.
        if (!StagedCopyIs(version))
        {
            Directory.Delete(staged, recursive: true);
            throw new UpdateRefusedException("The update isn't the version it says it is.");
        }
    }

    private bool StagedCopyIs(string version)
    {
        var exe = Path.Combine(UpdateInstaller.StagedDirectory(_options.InstallDirectory), UpdateInstaller.ExecutableName);
        if (!File.Exists(exe)) return false;
        var found = FileVersionInfo.GetVersionInfo(exe).ProductVersion;
        return UpdateVersion.TryParse(found, out var theirs) && UpdateVersion.TryParse(version, out var wanted) && theirs == wanted;
    }

    private string? ReadSkippedVersion()
    {
        try
        {
            var file = UpdateInstaller.SkipFile(_options.UpdatesDirectory);
            return File.Exists(file) ? File.ReadAllText(file).Trim() : null;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    private void Set(UpdateStatus status)
    {
        Status = status;
        Changed?.Invoke();
    }

#if DEBUG
    /// <summary><c>--preview-update</c>: shows a state without a feed.</summary>
    public void SetForPreview(UpdateStatus status) => Set(status);
#endif
}

/// <summary>An update that failed a check; the message is for the person.</summary>
internal sealed class UpdateRefusedException(string message) : Exception(message);
