using System.Diagnostics;
using System.IO.Compression;
using System.Net;
using System.Security.Cryptography;
using Microsoft.Extensions.Logging.Abstractions;
using Vantage.Host.Windows.Updates;
using Vantage.Protocol.Auth;
using Vantage.Protocol.Updates;
using Xunit;

namespace Vantage.Host.Windows.Tests;

/// <summary>The updater against a fake GitHub, on real folders.</summary>
public sealed class HostUpdaterTests : IDisposable
{
    private const string Feed = "https://feed.test/";
    private static readonly NSecEd25519 s_ed25519 = new();
    private readonly byte[] _seed = s_ed25519.GenerateSeed();
    private readonly string _root = Path.Combine(Path.GetTempPath(), "casement-updater-" + Guid.NewGuid().ToString("N"));
    private readonly Dictionary<string, byte[]> _files = [];
    private readonly List<string> _requests = [];

    /// <summary>A real PE with a known version, standing in for VantageHost.exe.</summary>
    private static readonly string s_exeSource = typeof(HostUpdaterTests).Assembly.Location;
    private static readonly string s_exeVersion = UpdateVersion.Display(FileVersionInfo.GetVersionInfo(s_exeSource).ProductVersion!);

    public HostUpdaterTests()
    {
        Directory.CreateDirectory(Install);
        File.WriteAllText(Path.Combine(Install, UpdateInstaller.ExecutableName), "old");
    }

    private string Install => Path.Combine(_root, "Casement Host");

    private string Updates => Path.Combine(_root, "data", "updates");

    private string Staged => UpdateInstaller.StagedDirectory(Install);

    public void Dispose()
    {
        try { Directory.Delete(_root, recursive: true); } catch (IOException) { }
    }

    private sealed class FakeGitHub(Dictionary<string, byte[]> files, List<string> requests) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var url = request.RequestUri!.ToString();
            requests.Add(url);
            return Task.FromResult(files.TryGetValue(url, out var bytes)
                ? new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(bytes) }
                : new HttpResponseMessage(HttpStatusCode.NotFound));
        }
    }

    private HostUpdater Updater(string current = "0.1") => new(
        new HttpClient(new FakeGitHub(_files, _requests)),
        new HostUpdaterOptions(Feed, s_ed25519.PublicKeyFromSeed(_seed), current, Install, Updates),
        s_ed25519,
        NullLogger.Instance);

    private byte[] Zip(bool withExe = true, string folder = "Casement Host/")
    {
        using var stream = new MemoryStream();
        using (var zip = new ZipArchive(stream, ZipArchiveMode.Create, leaveOpen: true))
        {
            zip.CreateEntry(folder + "README.txt");
            if (withExe)
            {
                using var entry = zip.CreateEntry(folder + UpdateInstaller.ExecutableName).Open();
                entry.Write(File.ReadAllBytes(s_exeSource));
            }
        }
        return stream.ToArray();
    }

    private void Publish(byte[] zip, string? version = null, string? hash = null, long? size = null, string architecture = "")
    {
        var name = Feed + "host.zip";
        _files[name] = zip;
        var key = architecture.Length > 0 ? architecture : HostUpdater.Architecture;
        var manifest = new UpdateManifest(version ?? s_exeVersion, "https://feed.test/notes", new Dictionary<string, UpdateAsset>
        {
            [key] = new(name, hash ?? Convert.ToHexStringLower(SHA256.HashData(zip)), size ?? zip.Length),
        }).ToBytes();
        _files[Feed + HostUpdater.ManifestName] = manifest;
        _files[Feed + HostUpdater.ManifestName + ".sig"] = System.Text.Encoding.UTF8.GetBytes(UpdateSignature.Sign(s_ed25519, _seed, manifest));
    }

    [Fact]
    public async Task ASignedNewerReleaseGetsStaged()
    {
        Publish(Zip());
        var updater = Updater();
        await updater.CheckAsync(userAsked: false, TestContext.Current.CancellationToken);

        Assert.Equal(UpdateStage.Ready, updater.Status.Stage);
        Assert.True(updater.IsReady);
        Assert.Equal(s_exeVersion, updater.Status.Version);
        Assert.Equal("https://feed.test/notes", updater.Status.NotesUrl);
        Assert.True(File.Exists(Path.Combine(Staged, UpdateInstaller.ExecutableName)));
        Assert.True(File.Exists(Path.Combine(Staged, "README.txt")));
        Assert.False(File.Exists(Path.Combine(Updates, "download.zip")));
        Assert.False(Directory.Exists(Staged + ".tmp"));
        Assert.Equal("old", File.ReadAllText(Path.Combine(Install, UpdateInstaller.ExecutableName))); // nothing installed yet
    }

    [Fact]
    public async Task AFlatZipWorksToo()
    {
        Publish(Zip(folder: ""));
        var updater = Updater();
        await updater.CheckAsync(userAsked: false, TestContext.Current.CancellationToken);
        Assert.Equal(UpdateStage.Ready, updater.Status.Stage);
    }

    [Fact]
    public async Task ASecondCheckDoesntDownloadAgain()
    {
        Publish(Zip());
        var updater = Updater();
        await updater.CheckAsync(userAsked: false, TestContext.Current.CancellationToken);
        _requests.Clear();
        await updater.CheckAsync(userAsked: false, TestContext.Current.CancellationToken);
        Assert.Equal(UpdateStage.Ready, updater.Status.Stage);
        Assert.DoesNotContain(Feed + "host.zip", _requests);
    }

    [Fact]
    public async Task NoManifestOnTheReleaseMeansNothingOnOffer()
    {
        var updater = Updater();
        await updater.CheckAsync(userAsked: false, TestContext.Current.CancellationToken);
        Assert.Equal(UpdateStage.UpToDate, updater.Status.Stage);
    }

    [Fact]
    public async Task TheSameOrAnOlderVersionIsNeverFetched()
    {
        Publish(Zip());
        var updater = Updater(current: "99.0");
        await updater.CheckAsync(userAsked: false, TestContext.Current.CancellationToken);
        Assert.Equal(UpdateStage.UpToDate, updater.Status.Stage);
        Assert.DoesNotContain(Feed + "host.zip", _requests);
    }

    [Fact]
    public async Task AReleaseForAnotherProcessorIsNotOnOffer()
    {
        Publish(Zip(), architecture: "riscv");
        var updater = Updater();
        await updater.CheckAsync(userAsked: false, TestContext.Current.CancellationToken);
        Assert.Equal(UpdateStage.UpToDate, updater.Status.Stage);
    }

    [Fact]
    public async Task AForgedManifestIsRefusedBeforeAnythingIsDownloaded()
    {
        Publish(Zip());
        var forged = s_ed25519.GenerateSeed();
        _files[Feed + HostUpdater.ManifestName + ".sig"] = System.Text.Encoding.UTF8.GetBytes(UpdateSignature.Sign(s_ed25519, forged, _files[Feed + HostUpdater.ManifestName]));
        var updater = Updater();
        await updater.CheckAsync(userAsked: false, TestContext.Current.CancellationToken);

        Assert.Equal(UpdateStage.Failed, updater.Status.Stage);
        Assert.Contains("security check", updater.Status.Message);
        Assert.DoesNotContain(Feed + "host.zip", _requests);
        Assert.False(Directory.Exists(Staged));
    }

    [Fact]
    public async Task AManifestWithoutASignatureIsRefused()
    {
        Publish(Zip());
        _files.Remove(Feed + HostUpdater.ManifestName + ".sig");
        var updater = Updater();
        await updater.CheckAsync(userAsked: false, TestContext.Current.CancellationToken);
        Assert.Equal(UpdateStage.Failed, updater.Status.Stage);
        Assert.DoesNotContain(Feed + "host.zip", _requests);
    }

    [Fact]
    public async Task ADownloadThatIsntTheSignedOneIsRefusedAndDeleted()
    {
        var zip = Zip();
        Publish(zip);
        var tampered = (byte[])zip.Clone();
        tampered[tampered.Length / 2] ^= 1;
        _files[Feed + "host.zip"] = tampered;
        var updater = Updater();
        await updater.CheckAsync(userAsked: false, TestContext.Current.CancellationToken);

        Assert.Equal(UpdateStage.Failed, updater.Status.Stage);
        Assert.False(Directory.Exists(Staged));
        Assert.False(File.Exists(Path.Combine(Updates, "download.zip")));
    }

    [Fact]
    public async Task ADownloadLongerThanSignedForIsCutOff()
    {
        var zip = Zip();
        Publish(zip, size: 100);
        var updater = Updater();
        await updater.CheckAsync(userAsked: false, TestContext.Current.CancellationToken);
        Assert.Equal(UpdateStage.Failed, updater.Status.Stage);
        Assert.False(File.Exists(Path.Combine(Updates, "download.zip")));
    }

    [Fact]
    public async Task AZipWithoutTheAppIsRefused()
    {
        Publish(Zip(withExe: false));
        var updater = Updater();
        await updater.CheckAsync(userAsked: false, TestContext.Current.CancellationToken);
        Assert.Equal(UpdateStage.Failed, updater.Status.Stage);
        Assert.False(Directory.Exists(Staged));
    }

    [Fact]
    public async Task AnExeThatIsntTheVersionOnOfferIsRefused()
    {
        Publish(Zip(), version: "99.0");
        var updater = Updater();
        await updater.CheckAsync(userAsked: false, TestContext.Current.CancellationToken);
        Assert.Equal(UpdateStage.Failed, updater.Status.Stage);
        Assert.False(Directory.Exists(Staged));
    }

    [Fact]
    public async Task AVersionThatWouldntStartIsSkippedUntilSomeoneAsks()
    {
        Publish(Zip());
        Directory.CreateDirectory(Updates);
        File.WriteAllText(UpdateInstaller.SkipFile(Updates), s_exeVersion);

        var updater = Updater();
        Assert.Equal(UpdateStage.RolledBack, updater.Status.Stage); // said at launch, before any check

        await updater.CheckAsync(userAsked: false, TestContext.Current.CancellationToken);
        Assert.Equal(UpdateStage.RolledBack, updater.Status.Stage);
        Assert.DoesNotContain(Feed + "host.zip", _requests);

        await updater.CheckAsync(userAsked: true, TestContext.Current.CancellationToken);
        Assert.Equal(UpdateStage.Ready, updater.Status.Stage);
    }

    [Fact]
    public async Task ANewerVersionThanTheSkippedOneIsOffered()
    {
        Publish(Zip());
        Directory.CreateDirectory(Updates);
        File.WriteAllText(UpdateInstaller.SkipFile(Updates), "0.5");
        var updater = Updater();
        await updater.CheckAsync(userAsked: false, TestContext.Current.CancellationToken);
        Assert.Equal(UpdateStage.Ready, updater.Status.Stage);
    }

    [Fact]
    public async Task AFolderThatCantBeReplacedGetsToldToDownload()
    {
        Publish(Zip());
        File.Delete(Path.Combine(Install, UpdateInstaller.ExecutableName)); // CanReplace: not a real install here
        var updater = Updater();
        await updater.CheckAsync(userAsked: false, TestContext.Current.CancellationToken);
        Assert.Equal(UpdateStage.ManualOnly, updater.Status.Stage);
        Assert.DoesNotContain(Feed + "host.zip", _requests);
    }

    [Fact]
    public void AVersionItHasGoneBackFromAndSinceOvertakenIsForgotten()
    {
        Directory.CreateDirectory(Updates);
        File.WriteAllText(UpdateInstaller.SkipFile(Updates), "1.0");
        Assert.Equal(UpdateStage.Idle, Updater(current: "2.0").Status.Stage);
    }
}

/// <summary>The swap, on plain folders, with the processes faked.</summary>
public sealed class UpdateInstallerTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "casement-swap-" + Guid.NewGuid().ToString("N"));
    private readonly List<string> _log = [];
    private int _starts;
    private int _stops;

    public UpdateInstallerTests()
    {
        Directory.CreateDirectory(Install);
        Directory.CreateDirectory(Path.Combine(Staged, "sub"));
        Directory.CreateDirectory(Updates);
        File.WriteAllText(Path.Combine(Install, "app.dll"), "old");
        File.WriteAllText(Path.Combine(Install, "only-in-old.dll"), "old");
        File.WriteAllText(Path.Combine(Staged, "app.dll"), "new");
        File.WriteAllText(Path.Combine(Staged, "sub", "more.dll"), "new");
        File.WriteAllText(UpdateInstaller.PendingFile(Updates), "1");
    }

    private string Install => Path.Combine(_root, "Casement Host");

    private string Staged => UpdateInstaller.StagedDirectory(Install);

    private string Updates => Path.Combine(_root, "updates");

    public void Dispose()
    {
        try { Directory.Delete(_root, recursive: true); } catch (IOException) { }
    }

    private UpdateInstaller.SwapEnvironment Environment(Action? onStart = null) => new(
        Install, Updates,
        WaitForHostExit: () => { },
        StartHost: () =>
        {
            _starts++;
            onStart?.Invoke();
        },
        StopHost: () => _stops++,
        Log: _log.Add)
    {
        HealthTimeout = TimeSpan.FromMilliseconds(300),
        PollInterval = TimeSpan.FromMilliseconds(10),
    };

    [Fact]
    public void AHealthyNewVersionStays()
    {
        var result = UpdateInstaller.Finish(Staged, "1.5", Environment(() => UpdateInstaller.MarkHealthy(Updates)));

        Assert.Equal(UpdateInstaller.SwapResult.Installed, result);
        Assert.Equal("new", File.ReadAllText(Path.Combine(Install, "app.dll")));
        Assert.Equal("new", File.ReadAllText(Path.Combine(Install, "sub", "more.dll")));
        Assert.False(File.Exists(Path.Combine(Install, "only-in-old.dll"))); // a whole replacement, not an overlay
        Assert.Equal(1, _starts);
        Assert.Equal(0, _stops);
        Assert.False(File.Exists(UpdateInstaller.SkipFile(Updates)));
    }

    [Fact]
    public void ANewVersionThatNeverReportsInIsUndone()
    {
        var result = UpdateInstaller.Finish(Staged, "1.5", Environment());

        Assert.Equal(UpdateInstaller.SwapResult.RolledBack, result);
        Assert.Equal("old", File.ReadAllText(Path.Combine(Install, "app.dll")));
        Assert.True(File.Exists(Path.Combine(Install, "only-in-old.dll")));
        Assert.False(File.Exists(Path.Combine(Install, "sub", "more.dll")));
        Assert.False(Directory.Exists(UpdateInstaller.OldDirectory(Install)));
        Assert.Equal(1, _stops);
        Assert.Equal(2, _starts); // the new one, then the old one back
        Assert.Equal("1.5", File.ReadAllText(UpdateInstaller.SkipFile(Updates)));
        Assert.False(File.Exists(UpdateInstaller.PendingFile(Updates))); // or the old one would look unhealthy
    }

    [Fact]
    public void ASuccessClearsAnEarlierSkip()
    {
        File.WriteAllText(UpdateInstaller.SkipFile(Updates), "1.4");
        UpdateInstaller.Finish(Staged, "1.5", Environment(() => UpdateInstaller.MarkHealthy(Updates)));
        Assert.False(File.Exists(UpdateInstaller.SkipFile(Updates)));
    }

    [Fact]
    public void AStagedCopyThatCantBeCopiedLeavesTheOldVersionInPlace()
    {
        var missing = Path.Combine(_root, "not-there");
        var result = UpdateInstaller.Finish(missing, "1.5", Environment());
        Assert.Equal(UpdateInstaller.SwapResult.RolledBack, result);
        Assert.Equal("old", File.ReadAllText(Path.Combine(Install, "app.dll")));
        Assert.Equal(1, _starts);
    }

    [Fact]
    public void LeftoversGoOnlyOnceNoSwapIsWatching()
    {
        Directory.CreateDirectory(UpdateInstaller.OldDirectory(Install));
        UpdateInstaller.CleanUp(Install, Updates);
        Assert.True(Directory.Exists(Staged)); // pending: the swapper is still running from here

        UpdateInstaller.MarkHealthy(Updates);
        UpdateInstaller.CleanUp(Install, Updates);
        Assert.False(Directory.Exists(Staged));
        Assert.False(Directory.Exists(UpdateInstaller.OldDirectory(Install)));
        Assert.True(Directory.Exists(Install));
    }

    [Fact]
    public void AnExistingInstallCanBeReplacedAndAMissingOneCant()
    {
        File.WriteAllText(Path.Combine(Install, UpdateInstaller.ExecutableName), "x");
        Assert.True(UpdateInstaller.CanReplace(Install));
        Assert.False(UpdateInstaller.CanReplace(Path.Combine(_root, "nope")));
    }
}

/// <summary>When it checks, when it may restart unasked, and what the row says.</summary>
public sealed class UpdatePolicyTests
{
    private static readonly DateTimeOffset s_now = new(2026, 11, 5, 15, 0, 0, TimeSpan.Zero);
    private static readonly TimeSpan s_launched = TimeSpan.FromHours(1);
    private static readonly UpdateActivity s_quiet = new(0, 0, false, false, TimeSpan.FromHours(1));

    [Fact]
    public void ChecksOnceADayAfterAShortWait()
    {
        Assert.True(UpdatePolicy.ShouldCheck(true, s_launched, null, s_now));
        Assert.False(UpdatePolicy.ShouldCheck(true, TimeSpan.FromSeconds(30), null, s_now));
        Assert.False(UpdatePolicy.ShouldCheck(true, s_launched, s_now.AddHours(-23), s_now));
        Assert.True(UpdatePolicy.ShouldCheck(true, s_launched, s_now.AddHours(-24), s_now));
    }

    [Fact]
    public void OffMeansNoBackgroundNetworkAtAll() => Assert.False(UpdatePolicy.ShouldCheck(false, s_launched, null, s_now));

    [Fact]
    public void AClockThatWentBackwardsDoesntStopChecks() => Assert.True(UpdatePolicy.ShouldCheck(true, s_launched, s_now.AddYears(1), s_now));

    [Fact]
    public void InstallsOnlyWhenNothingIsGoingOnAndHasntBeenForAWhile()
    {
        Assert.True(UpdatePolicy.MayInstallUnattended(true, s_quiet));
        Assert.False(UpdatePolicy.MayInstallUnattended(false, s_quiet));
        Assert.False(UpdatePolicy.MayInstallUnattended(true, s_quiet with { Connections = 1 }));
        Assert.False(UpdatePolicy.MayInstallUnattended(true, s_quiet with { ActiveTransfers = 1 }));
        Assert.False(UpdatePolicy.MayInstallUnattended(true, s_quiet with { ShowingPairingCode = true }));
        Assert.False(UpdatePolicy.MayInstallUnattended(true, s_quiet with { WindowOpen = true }));
        Assert.False(UpdatePolicy.MayInstallUnattended(true, s_quiet with { QuietFor = TimeSpan.FromMinutes(4) })); // probably reconnecting
    }

    [Theory]
    [InlineData(UpdateStage.Idle, UpdateRowAction.Check, "Checks for updates once a day.")]
    [InlineData(UpdateStage.UpToDate, UpdateRowAction.Check, "You're up to date.")]
    [InlineData(UpdateStage.Checking, UpdateRowAction.None, "Checking for updates…")]
    [InlineData(UpdateStage.Ready, UpdateRowAction.Restart, "Version 1.5 is ready. It installs by itself when no device is connected.")]
    [InlineData(UpdateStage.ManualOnly, UpdateRowAction.Download, "Version 1.5 is out. Casement Host can't change this folder itself, so download it from GitHub.")]
    [InlineData(UpdateStage.RolledBack, UpdateRowAction.TryAgain, "Version 1.5 wouldn't start, so Casement Host went back to this version.")]
    public void EveryStateSaysWhatsGoingOn(UpdateStage stage, UpdateRowAction action, string text)
    {
        var row = UpdateRow.For(new UpdateStatus(stage) { Version = "1.5" }, automatic: true, lastCheck: null, s_now);
        Assert.Equal(text, row.Description);
        Assert.Equal(action, row.Action);
    }

    [Fact]
    public void TheRowFollowsTheSetting()
    {
        Assert.Equal("Automatic updates are off.", UpdateRow.For(new UpdateStatus(UpdateStage.Idle), false, null, s_now).Description);
        Assert.Equal("Version 1.5 is ready to install.", UpdateRow.For(new UpdateStatus(UpdateStage.Ready) { Version = "1.5" }, false, null, s_now).Description);
    }

    [Fact]
    public void AFailureSaysWhyAndOffersARetry()
    {
        var row = UpdateRow.For(new UpdateStatus(UpdateStage.Failed) { Message = "GitHub couldn't be reached." }, true, null, s_now);
        Assert.Equal("Couldn't check for updates. GitHub couldn't be reached.", row.Description);
        Assert.Equal("Try again", row.ActionLabel);
    }

    [Fact]
    public void TheLastCheckReadsNaturally()
    {
        var local = new DateTimeOffset(s_now.ToLocalTime().Date.AddHours(12), s_now.ToLocalTime().Offset);
        Assert.StartsWith("You're up to date. Last checked today at", UpdateRow.For(new UpdateStatus(UpdateStage.UpToDate), true, local.AddMinutes(-5), local).Description);
        Assert.StartsWith("Last checked yesterday at", UpdateRow.For(new UpdateStatus(UpdateStage.Idle), true, local.AddDays(-1), local).Description);
    }
}
