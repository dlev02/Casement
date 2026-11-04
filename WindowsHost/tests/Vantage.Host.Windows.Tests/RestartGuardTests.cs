using Vantage.Host.Windows.Desktop;
using Vantage.Host.Windows.Storage;

namespace Vantage.Host.Windows.Tests;

public class RestartGuardTests
{
    private const uint CloseApp = 0x00000001;
    private const uint Critical = 0x40000000;
    private const uint Logoff = 0x80000000;

    private static nint Flags(uint flags) => (nint)(nuint)flags;

    [Fact]
    public void NoReasonWhileNothingIsConnected() => Assert.Null(RestartGuardPolicy.BlockReason([]));

    [Fact]
    public void OneDeviceIsNamed()
    {
        Assert.Equal("Drew's iPad is connected through Casement Host. It can't reconnect until someone signs in to this PC again.",
                     RestartGuardPolicy.BlockReason(["Drew's iPad"]));
    }

    [Fact]
    public void SeveralDevicesAreCounted()
    {
        Assert.Equal("2 devices are connected through Casement Host. They can't reconnect until someone signs in to this PC again.",
                     RestartGuardPolicy.BlockReason(["Drew's iPad", "Drew's iPhone"]));
    }

    [Fact]
    public void ReasonsFitWindowsLimit()
    {
        var reason = RestartGuardPolicy.BlockReason([new string('x', 400)])!;
        Assert.True(reason.Length <= RestartGuardPolicy.MaxReasonLength);
        Assert.StartsWith("A device is connected", reason);
        Assert.StartsWith("A device is connected", RestartGuardPolicy.BlockReason(["  "]));
    }

    [Theory]
    [InlineData(0u)]
    [InlineData(Logoff)]
    public void HoldsAnInteractiveRestartOrSignOutWhileConnected(uint flags) =>
        Assert.Equal(QueryEndSessionAnswer.Block, RestartGuardPolicy.Decide(enabled: true, hasReason: true, Flags(flags)));

    [Theory]
    [InlineData(Critical)]
    [InlineData(Critical | Logoff)]
    [InlineData(CloseApp)]
    public void NeverHoldsAForcedRestartOrAnInstaller(uint flags) =>
        Assert.Equal(QueryEndSessionAnswer.Allow, RestartGuardPolicy.Decide(enabled: true, hasReason: true, Flags(flags)));

    [Fact]
    public void LetsGoWhenOffOrNothingIsConnected()
    {
        Assert.Equal(QueryEndSessionAnswer.Allow, RestartGuardPolicy.Decide(enabled: false, hasReason: true, 0));
        Assert.Equal(QueryEndSessionAnswer.Allow, RestartGuardPolicy.Decide(enabled: true, hasReason: false, 0));
    }

    [Theory]
    [InlineData(0u, SessionEnding.Restart, "restart")]
    [InlineData(Critical, SessionEnding.Restart, "restart")]
    [InlineData(Logoff, SessionEnding.SignOut, "sign-out")]
    [InlineData(Logoff | Critical, SessionEnding.SignOut, "sign-out")]
    [InlineData(CloseApp, SessionEnding.AppClosing, "close-app")]
    public void EndingSessionsAreTold(uint flags, SessionEnding kind, string logName)
    {
        Assert.Equal(kind, RestartGuardPolicy.Kind(Flags(flags)));
        Assert.Equal(logName, RestartGuardPolicy.LogName(kind));
    }

    [Fact]
    public void SettingsMissingFromTheFileKeepTheirDefaults()
    {
        var folder = Path.Combine(Path.GetTempPath(), "vantage-settings-" + Guid.NewGuid().ToString("N"));
        var path = Path.Combine(folder, "settings.json");
        Directory.CreateDirectory(folder);
        try
        {
            File.WriteAllText(path, """{"receiveFolder": null}""");
            var settings = new HostSettingsStore(path).Current;
            Assert.True(settings.NotifyOnArrival);
            Assert.Equal(AfterArrival.ShowInFolder, settings.AfterArrival);
            Assert.True(settings.AskBeforeRestart);
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }

    [Fact]
    public void AskingIsOnByDefaultAndForSettingsSavedBeforeIt()
    {
        Assert.True(new HostSettings().AskBeforeRestart);
        var path = Path.Combine(Path.GetTempPath(), "vantage-settings-" + Guid.NewGuid().ToString("N"), "settings.json");
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        try
        {
            File.WriteAllText(path, """{ "notifyOnArrival": false }""");
            Assert.True(new HostSettingsStore(path).Current.AskBeforeRestart);
            new HostSettingsStore(path).Update(s => s with { AskBeforeRestart = false });
            Assert.False(new HostSettingsStore(path).Current.AskBeforeRestart);
        }
        finally
        {
            Directory.Delete(Path.GetDirectoryName(path)!, recursive: true);
        }
    }
}
