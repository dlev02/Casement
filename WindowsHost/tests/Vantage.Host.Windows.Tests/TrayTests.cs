using Vantage.Host.Windows.Tray;

namespace Vantage.Host.Windows.Tests;

public class TrayMenuModelTests
{
    private static readonly Guid Session = Guid.Parse("11111111-2222-3333-4444-555555555555");
    private static readonly Guid Channel = Guid.Parse("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee");

    [Fact]
    public void IdleMenu()
    {
        var items = TrayMenuModel.Build(new TrayState("drew-pc", true, null, [], []));
        Assert.Equal(["Porthole Host: Listening on drew-pc", "", "Show Pairing Code…", "", "Settings…", "Quit Porthole Host"],
                     items.Select(i => i.Text));
        Assert.False(items[0].IsEnabled);
        Assert.True(items[1].IsSeparator);
        Assert.Equal(TrayCommandKind.ShowPairingCode, items[2].Command.Kind);
        Assert.True(items[2].IsEnabled);
        Assert.Equal(TrayCommandKind.Quit, items[^1].Command.Kind);
    }

    [Fact]
    public void ConnectedMenuHasTheClientSendFileAndDisconnect()
    {
        var state = new TrayState("drew-pc", true, null, [new TrayClient(Session, "Drew's iPad")], [new TrayFileTarget(Channel, "Drew's iPad")]);
        var items = TrayMenuModel.Build(state);
        Assert.Equal(["Porthole Host: Listening on drew-pc", "Connected: Drew's iPad", "", "Show Pairing Code…",
                      "Send File to Drew's iPad…", "Disconnect Drew's iPad", "", "Settings…", "Quit Porthole Host"],
                     items.Select(i => i.Text));
        Assert.False(items[1].IsEnabled);
        Assert.Equal(new TrayCommand(TrayCommandKind.SendFile, Channel), items[4].Command);
        Assert.Equal(new TrayCommand(TrayCommandKind.Disconnect, Session), items[5].Command);
    }

    [Fact]
    public void NotListeningExplainsWhyAndDisablesPairing()
    {
        var items = TrayMenuModel.Build(new TrayState("drew-pc", false, "Port 47820 is in use", [], []));
        Assert.Equal("Porthole Host: Port 47820 is in use", items[0].Text);
        Assert.False(items.Single(i => i.Command.Kind == TrayCommandKind.ShowPairingCode).IsEnabled);
        Assert.Equal("Porthole Host: Starting…", TrayMenuModel.Headline(TrayState.Starting("drew-pc")));
    }

    [Fact]
    public void Tooltips()
    {
        Assert.Equal("Porthole Host — ready", TrayMenuModel.Tooltip(new TrayState("pc", true, null, [], [])));
        Assert.Equal("Porthole Host — Drew's iPad connected",
                     TrayMenuModel.Tooltip(new TrayState("pc", true, null, [new TrayClient(Session, "Drew's iPad")], [])));
        Assert.Equal("Porthole Host — 2 devices connected",
                     TrayMenuModel.Tooltip(new TrayState("pc", true, null, [new TrayClient(Session, "A"), new TrayClient(Guid.NewGuid(), "B")], [])));
        var longName = new string('x', 300);
        var tip = TrayMenuModel.Tooltip(new TrayState("pc", true, null, [new TrayClient(Session, longName)], []));
        Assert.Equal(TrayMenuModel.MaxTooltip, tip.Length);
        Assert.EndsWith("…", tip);
    }

    [Fact]
    public void AmpersandsAreEscapedForWin32Menus() => Assert.Equal("Tom && Jerry's iPad", TrayMenuModel.MenuText("Tom & Jerry's iPad"));
}

public class IconDirectoryTests
{
    public static TheoryData<string> Names => new() { "tray-idle-light.ico", "tray-idle-dark.ico", "tray-connected-light.ico", "tray-connected-dark.ico" };

    [Theory]
    [MemberData(nameof(Names))]
    public void EmbeddedTrayIconsHaveEverySize(string name)
    {
        var entries = IconDirectory.Read(Embedded(name));
        Assert.Equal([16, 20, 24, 32, 40, 48], entries.Select(e => e.Width));
        Assert.All(entries, e => Assert.Equal(e.Width, e.Height));
    }

    [Theory]
    [InlineData(16, 16)]
    [InlineData(18, 20)]
    [InlineData(20, 20)]
    [InlineData(30, 32)]
    [InlineData(48, 48)]
    [InlineData(64, 48)]
    public void PicksTheSmallestImageAtLeastTheSize(int wanted, int picked)
    {
        var entries = IconDirectory.Read(Embedded("tray-idle-dark.ico"));
        Assert.Equal(picked, IconDirectory.Pick(entries, wanted)!.Value.Width);
    }

    [Fact]
    public void NotAnIcon() => Assert.Empty(IconDirectory.Read("PNG"u8));

    private static byte[] Embedded(string name)
    {
        using var stream = typeof(TrayMenuModel).Assembly.GetManifestResourceStream("Vantage.Host.Windows.Tray.Icons." + name)!;
        var bytes = new byte[stream.Length];
        stream.ReadExactly(bytes);
        return bytes;
    }
}
