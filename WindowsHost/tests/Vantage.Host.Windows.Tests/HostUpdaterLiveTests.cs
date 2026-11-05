using Microsoft.Extensions.Logging.Abstractions;
using Vantage.Host.Windows.Updates;
using Vantage.Protocol.Auth;
using Xunit;

namespace Vantage.Host.Windows.Tests;

/// <summary>
/// The published release as an installed copy sees it: GitHub, HTTPS and the real key. Run it after
/// publishing, since it downloads the zip: <c>VANTAGE_LIVE_UPDATE_FEED=1</c>. It stages into a
/// throwaway folder and installs nothing.
/// </summary>
public sealed class HostUpdaterLiveTests
{
    [Fact]
    public async Task ThePublishedReleaseVerifiesAndStages()
    {
        if (Environment.GetEnvironmentVariable("VANTAGE_LIVE_UPDATE_FEED") != "1")
            Assert.Skip("Set VANTAGE_LIVE_UPDATE_FEED=1 to fetch the latest release from GitHub.");

        var root = Path.Combine(Path.GetTempPath(), "casement-live-" + Guid.NewGuid().ToString("N"));
        var install = Path.Combine(root, "Casement Host");
        Directory.CreateDirectory(install);
        File.WriteAllText(Path.Combine(install, UpdateInstaller.ExecutableName), "old");
        try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromMinutes(2) };
            http.DefaultRequestHeaders.UserAgent.ParseAdd("CasementHost/test");
            var updater = new HostUpdater(http,
                                          new HostUpdaterOptions(HostUpdater.ReleaseFeed, Convert.FromHexString(HostUpdater.ReleasePublicKeyHex), "0.1", install, Path.Combine(root, "updates")),
                                          new NSecEd25519(), NullLogger.Instance);
            await updater.CheckAsync(userAsked: false, TestContext.Current.CancellationToken);

            Assert.True(updater.Status.Stage == UpdateStage.Ready, $"{updater.Status.Stage}: {updater.Status.Message}");
            Assert.True(File.Exists(Path.Combine(UpdateInstaller.StagedDirectory(install), UpdateInstaller.ExecutableName)));
            TestContext.Current.SendDiagnosticMessage($"staged {updater.Status.Version} ({HostUpdater.Architecture})");
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }
}
