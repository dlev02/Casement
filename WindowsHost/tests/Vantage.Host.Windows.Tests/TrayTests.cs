using Vantage.Host.Windows.Files;
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
        Assert.Equal(["Casement Host: Listening on drew-pc", "", "Show pairing code…", "", "Open receive folder", "", "Settings…", "Quit Casement Host"],
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
        Assert.Equal(["Casement Host: Listening on drew-pc", "Connected: Drew's iPad", "", "Show pairing code…",
                      "Send File to Drew's iPad…", "Disconnect Drew's iPad", "", "Open receive folder", "", "Settings…", "Quit Casement Host"],
                     items.Select(i => i.Text));
        Assert.False(items[1].IsEnabled);
        Assert.Equal(new TrayCommand(TrayCommandKind.SendFile, Channel), items[4].Command);
        Assert.Equal(new TrayCommand(TrayCommandKind.Disconnect, Session), items[5].Command);
    }

    [Fact]
    public void NotListeningExplainsWhyAndDisablesPairing()
    {
        var items = TrayMenuModel.Build(new TrayState("drew-pc", false, "Port 47820 is in use", [], []));
        Assert.Equal("Casement Host: Port 47820 is in use", items[0].Text);
        Assert.False(items.Single(i => i.Command.Kind == TrayCommandKind.ShowPairingCode).IsEnabled);
        Assert.Equal("Casement Host: Starting…", TrayMenuModel.Headline(TrayState.Starting("drew-pc")));
    }

    [Fact]
    public void Tooltips()
    {
        Assert.Equal("Casement Host — ready", TrayMenuModel.Tooltip(new TrayState("pc", true, null, [], [])));
        Assert.Equal("Casement Host — Drew's iPad connected",
                     TrayMenuModel.Tooltip(new TrayState("pc", true, null, [new TrayClient(Session, "Drew's iPad")], [])));
        Assert.Equal("Casement Host — 2 devices connected",
                     TrayMenuModel.Tooltip(new TrayState("pc", true, null, [new TrayClient(Session, "A"), new TrayClient(Guid.NewGuid(), "B")], [])));
        var longName = new string('x', 300);
        var tip = TrayMenuModel.Tooltip(new TrayState("pc", true, null, [new TrayClient(Session, longName)], []));
        Assert.Equal(TrayMenuModel.MaxTooltip, tip.Length);
        Assert.EndsWith("…", tip);
    }

    [Fact]
    public void AmpersandsAreEscapedForWin32Menus() => Assert.Equal("Tom && Jerry's iPad", TrayMenuModel.MenuText("Tom & Jerry's iPad"));

    private static readonly Guid Moving = Guid.Parse("00000000-0000-0000-0000-000000000001");
    private static readonly Guid Paused = Guid.Parse("00000000-0000-0000-0000-000000000002");
    private static readonly Guid Received = Guid.Parse("00000000-0000-0000-0000-000000000003");
    private static readonly Guid Failed = Guid.Parse("00000000-0000-0000-0000-000000000004");

    [Fact]
    public void FilesSectionListsEachFileWithWhatCanBeDoneWithIt()
    {
        var state = new TrayState("drew-pc", true, null, [], [])
        {
            Transfers =
            [
                new TrayTransfer(Moving, "Report.pdf", "12.4 MB of 48.0 MB · 6.20 MB/s · 5 sec left", true, false),
                new TrayTransfer(Paused, "Movie.mov", "Paused at 45% · resumes when Drew's iPad reconnects", true, false),
                new TrayTransfer(Received, "Photo.heic", "Received from Drew's iPad · in Downloads", false, true),
                new TrayTransfer(Failed, "Big.zip", "The disk is full.", false, false),
            ],
        };
        var items = TrayMenuModel.Build(state);
        var files = items.SkipWhile(i => i.Command.Kind != TrayCommandKind.ShowPairingCode).Skip(2).TakeWhile(i => !i.IsSeparator).ToList();
        Assert.Equal(["Report.pdf: 12.4 MB of 48.0 MB · 6.20 MB/s · 5 sec left", "Cancel Report.pdf",
                      "Movie.mov: Paused at 45% · resumes when Drew's iPad reconnects", "Cancel Movie.mov",
                      "Photo.heic: Received from Drew's iPad · in Downloads", "Show Photo.heic in folder",
                      "Big.zip: The disk is full.",
                      "Open receive folder"],
                     files.Select(i => i.Text));
        Assert.False(files[0].IsEnabled);
        Assert.Equal(new TrayCommand(TrayCommandKind.CancelTransfer, Moving), files[1].Command);
        Assert.Equal(new TrayCommand(TrayCommandKind.CancelTransfer, Paused), files[3].Command);
        Assert.Equal(new TrayCommand(TrayCommandKind.ShowTransfer, Received), files[5].Command);
        Assert.Equal(TrayCommandKind.OpenReceiveFolder, files[^1].Command.Kind);
        Assert.All(files.Where(i => i.Command.Kind != TrayCommandKind.None), i => Assert.True(i.IsEnabled));
    }

    [Fact]
    public void ALongQueueShowsTheNewestFilesAndPointsToTheRest()
    {
        var transfers = Enumerable.Range(1, 8)
            .Select(n => new TrayTransfer(Guid.NewGuid(), $"File {n}.txt", "Waiting · 1.00 KB · To Drew's iPad", true, false)).ToList();
        var items = TrayMenuModel.Build(new TrayState("drew-pc", true, null, [], []) { Transfers = transfers });
        var labels = items.Where(i => i.Text.EndsWith("To Drew's iPad", StringComparison.Ordinal)).Select(i => i.Text[..i.Text.IndexOf(':')]).ToList();
        Assert.Equal(["File 4.txt", "File 5.txt", "File 6.txt", "File 7.txt", "File 8.txt"], labels);
        var more = Assert.Single(items, i => i.Command.Kind == TrayCommandKind.ShowTransfers);
        Assert.Equal("3 more files…", more.Text);
    }

    [Fact]
    public void TooltipSaysWhatIsMovingFirst()
    {
        var state = new TrayState("pc", true, null, [new TrayClient(Session, "Drew's iPad")], []) { TransferSummary = "Receiving Report.pdf, 45%" };
        Assert.Equal("Casement Host — Receiving Report.pdf, 45%", TrayMenuModel.Tooltip(state));
    }

    [Fact]
    public void TrayRowsComeFromTheTransferList()
    {
        var done = new HostTransfer(Received, "Photo.heic", Vantage.Protocol.Files.FileDirection.Receiving, "Drew's iPad")
        {
            State = HostTransferState.Done,
            SavedPath = Path.Combine(Path.GetTempPath(), "Downloads", "Photo (2).heic"),
        };
        Assert.Equal(new TrayTransfer(Received, "Photo (2).heic", "Received from Drew's iPad · in Downloads", false, true), TrayTransfer.From(done));
        var paused = done with { State = HostTransferState.Paused, SavedPath = null, ByteCount = 100, BytesDone = 45 };
        Assert.Equal(new TrayTransfer(Received, "Photo.heic", "Paused at 45% · resumes when Drew's iPad reconnects", true, false), TrayTransfer.From(paused));
    }
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
