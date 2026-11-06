using Microsoft.Win32;
using Vantage.Host.Windows.Startup;

namespace Vantage.Host.Windows.Tests;

public sealed class InstallRegistrationTests : IDisposable
{
    private const string Exe = @"C:\Users\you\AppData\Local\Programs\Casement Host\VantageHost.exe";
    private readonly string _key = $@"Software\CasementHostTests\{Guid.NewGuid():N}";

    private void Row(string location, string version)
    {
        using var key = Registry.CurrentUser.CreateSubKey(_key);
        key.SetValue("InstallLocation", location);
        key.SetValue("DisplayVersion", version);
    }

    private string? Version()
    {
        using var key = Registry.CurrentUser.OpenSubKey(_key);
        return key?.GetValue("DisplayVersion") as string;
    }

    [Fact]
    public void AnUpdatedCopyCorrectsItsRow()
    {
        Row(@"C:\Users\you\AppData\Local\Programs\Casement Host\", "1.4");
        Assert.True(InstallRegistration.SyncVersion(Exe, "1.5", _key));
        Assert.Equal("1.5", Version());
        Assert.False(InstallRegistration.SyncVersion(Exe, "1.5", _key));
    }

    [Fact]
    public void ACopyElsewhereLeavesTheRowAlone()
    {
        Row(@"C:\Other\Casement Host\", "1.4");
        Assert.False(InstallRegistration.SyncVersion(Exe, "1.5", _key));
        Assert.Equal("1.4", Version());
    }

    [Fact]
    public void NoRowIsFine() => Assert.False(InstallRegistration.SyncVersion(Exe, "1.5", _key));

    public void Dispose() => Registry.CurrentUser.DeleteSubKeyTree(_key, throwOnMissingSubKey: false);
}
