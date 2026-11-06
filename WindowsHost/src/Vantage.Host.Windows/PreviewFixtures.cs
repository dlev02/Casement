#if DEBUG
using System.Net;
using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Xaml;
using Vantage.Host.Windows.Files;
using Vantage.Host.Windows.Tailscale;
using Vantage.Host.Windows.Updates;
using Vantage.Protocol.Files;
using Vantage.Protocol.Host;

namespace Vantage.Host.Windows.App;

/// <summary>
/// DEBUG flags to look at the UI without a device (the Mac host's <c>--open-menu</c> and
/// <c>--open-settings</c>). Use with <c>--synthetic</c>, which has its own trust store and runs beside
/// the installed host: <c>--open-settings general|devices|files|display|about</c>, <c>--open-panel</c>,
/// <c>--window-size WxH</c> (DIPs), <c>--theme light|dark</c>,
/// <c>--preview-state empty|one|many|transfers|pairing|problem</c>, <c>--expand</c> (open the expanders), <c>--pane-closed</c>,
/// and <c>--capture PATH</c> (see <see cref="PreviewCapture"/>). Updates: <c>--preview-update
/// uptodate|checking|downloading|ready|manual|failed|rolledback</c> shows a state, and <c>--update-feed URL
/// --update-key HEX --update-soon</c> runs the real thing against a test feed without the waits.
/// </summary>
internal sealed record PreviewOptions(string? Settings, bool Panel, int? Width, int? Height, string? State, string? Capture, bool ExpandAll, bool PaneClosed, string? UpdateFeed, string? UpdateKey, string? UpdatePreview, bool UpdateSoon, string? HelpSearch = null)
{
    /// <summary>The flags in <paramref name="args"/>, which are removed from it (the host's parser refuses them).</summary>
    public static PreviewOptions Take(ref string[] args)
    {
        var rest = new List<string>();
        string? settings = null, state = null, capture = null, updateFeed = null, updateKey = null, updatePreview = null;
        var updateSoon = false;
        string? helpSearch = null;
        var panel = false;
        var expand = false;
        var paneClosed = false;
        int? width = null, height = null;
        for (var i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--open-settings" when i + 1 < args.Length:
                    settings = args[++i];
                    break;
                case "--help-search" when i + 1 < args.Length:
                    helpSearch = args[++i];
                    break;
                case "--open-panel":
                    panel = true;
                    break;
                case "--capture" when i + 1 < args.Length:
                    capture = args[++i];
                    break;
                case "--update-feed" when i + 1 < args.Length:
                    updateFeed = args[++i];
                    break;
                case "--update-key" when i + 1 < args.Length:
                    updateKey = args[++i];
                    break;
                case "--preview-update" when i + 1 < args.Length:
                    updatePreview = args[++i];
                    break;
                case "--update-soon":
                    updateSoon = true;
                    break;
                case "--pane-closed":
                    paneClosed = true;
                    break;
                case "--expand":
                    expand = true;
                    break;
                case "--preview-state" when i + 1 < args.Length:
                    state = args[++i];
                    break;
                case "--theme" when i + 1 < args.Length:
                    i++;
                    break;
                case "--window-size" when i + 1 < args.Length:
                    var parts = args[++i].Split('x');
                    width = int.Parse(parts[0], System.Globalization.CultureInfo.InvariantCulture);
                    height = int.Parse(parts[1], System.Globalization.CultureInfo.InvariantCulture);
                    break;
                default:
                    rest.Add(args[i]);
                    break;
            }
        }
        args = [.. rest];
        return new PreviewOptions(settings, panel, width, height, state, capture, expand, paneClosed, updateFeed, updateKey, updatePreview, updateSoon, helpSearch);
    }

    /// <summary><c>--theme</c>, if given.</summary>
    public static ApplicationTheme? Theme(string[] args)
    {
        var at = Array.IndexOf(args, "--theme");
        if (at < 0 || at + 1 >= args.Length) return null;
        return args[at + 1] == "light" ? ApplicationTheme.Light : ApplicationTheme.Dark;
    }
}

/// <summary>
/// <c>--capture PATH</c>: renders a window's XAML to a PNG and quits, for design reviews on a PC whose
/// desktop can't be screenshotted (a composed WinUI window copies off the screen as black when the
/// session isn't being drawn). A backdrop isn't XAML, so a flat colour close to it goes underneath.
/// </summary>
internal static class PreviewCapture
{
    public static async Task SaveAsync(UIElement root, string path, bool panel)
    {
        var bitmap = new Microsoft.UI.Xaml.Media.Imaging.RenderTargetBitmap();
        await bitmap.RenderAsync(root);
        var pixels = (await bitmap.GetPixelsAsync()).ToArray();
        var light = Application.Current.RequestedTheme == ApplicationTheme.Light;
        byte under = (light, panel) switch
        {
            (true, false) => 0xF3,
            (true, true) => 0xEE,
            (false, false) => 0x20,
            (false, true) => 0x2C,
        };
        for (var i = 0; i < pixels.Length; i += 4)
        {
            var alpha = pixels[i + 3];
            for (var c = 0; c < 3; c++) pixels[i + c] = (byte)(pixels[i + c] + under * (255 - alpha) / 255);
            pixels[i + 3] = 255;
        }
        var folder = await global::Windows.Storage.StorageFolder.GetFolderFromPathAsync(Path.GetDirectoryName(path)!);
        var file = await folder.CreateFileAsync(Path.GetFileName(path), global::Windows.Storage.CreationCollisionOption.ReplaceExisting);
        using var stream = await file.OpenAsync(global::Windows.Storage.FileAccessMode.ReadWrite);
        var encoder = await global::Windows.Graphics.Imaging.BitmapEncoder.CreateAsync(global::Windows.Graphics.Imaging.BitmapEncoder.PngEncoderId, stream);
        encoder.SetPixelData(global::Windows.Graphics.Imaging.BitmapPixelFormat.Bgra8, global::Windows.Graphics.Imaging.BitmapAlphaMode.Premultiplied,
                             (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, 96, 96, pixels);
        await encoder.FlushAsync();
    }

    /// <summary>Opens every expander under <paramref name="root"/> (<c>--expand</c>).</summary>
    public static void Expand(DependencyObject root)
    {
        if (root is CommunityToolkit.WinUI.Controls.SettingsExpander expander) expander.IsExpanded = true;
        if (root is Microsoft.UI.Xaml.Controls.Expander nativeExpander) nativeExpander.IsExpanded = true;
        for (var i = 0; i < Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(root); i++)
            Expand(Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(root, i));
    }
}

/// <summary>Made-up devices and files for a <c>--preview-state</c>.</summary>
internal sealed record PreviewFixture
{
    private static readonly TailscaleSelf Fictional = new("Running", "drew-pc", "drew-pc.tail1234.ts.net", ["100.64.0.7"]);

    public IReadOnlyList<SessionSnapshot> Sessions { get; init; } = [];
    public IReadOnlyList<FileChannelSnapshot> FileChannels { get; init; } = [];
    public IReadOnlyList<TrustedClient> Paired { get; init; } = [];
    public string? Problem { get; init; }
    public bool ShowCode { get; init; }
    public bool WithTransfers { get; init; }
    public TailscaleSelf? Tailnet { get; init; } = Fictional;

    public static UpdateStatus UpdateStatusFor(string state) => state switch
    {
        "uptodate" => new UpdateStatus(UpdateStage.UpToDate),
        "checking" => new UpdateStatus(UpdateStage.Checking),
        "downloading" => new UpdateStatus(UpdateStage.Downloading) { Version = "1.5", Fraction = 0.45 },
        "ready" => new UpdateStatus(UpdateStage.Ready) { Version = "1.5", NotesUrl = "https://github.com/dlev02/Casement/releases" },
        "manual" => new UpdateStatus(UpdateStage.ManualOnly) { Version = "1.5", NotesUrl = "https://github.com/dlev02/Casement/releases" },
        "failed" => new UpdateStatus(UpdateStage.Failed) { Message = "GitHub couldn't be reached." },
        "rolledback" => new UpdateStatus(UpdateStage.RolledBack) { Version = "1.5" },
        _ => new UpdateStatus(UpdateStage.Idle),
    };

    public static PreviewFixture For(string state)
    {
        var paired = new List<TrustedClient>
        {
            new("e5f8a4df59acc24b", "iPad", DateTimeOffset.Now.AddDays(-30), "drew-ipad-pro"),
            new("833f0757d1eb1386", "iPhone", DateTimeOffset.Now.AddDays(-12), "drew-iphone"),
            new("9a6ac13dbf60c5cd", "MacBook Pro", DateTimeOffset.Now.AddDays(-2), "drews-macbook-pro"),
        };
        var ipad = Guid.NewGuid();
        var channel = Guid.NewGuid();
        var one = new SessionSnapshot(ipad, "drew-ipad-pro", "e5f8a4df59acc24b", IPAddress.Parse("100.64.0.12"), false, DateTimeOffset.Now, null);
        var ipadChannel = new FileChannelSnapshot(channel, ipad, "drew-ipad-pro", "e5f8a4df59acc24b", "", false, false);
        return state switch
        {
            "empty" => new PreviewFixture(),
            "pairing" => new PreviewFixture { Paired = paired, ShowCode = true },
            "transfers" => new PreviewFixture { Paired = paired, Sessions = [one], FileChannels = [ipadChannel], WithTransfers = true },
            "many" => new PreviewFixture
            {
                Paired = [.. paired, .. Enumerable.Range(1, 14).Select(i => new TrustedClient($"{i:x16}", "Test iPad", DateTimeOffset.Now.AddDays(-i)))],
                Sessions =
                [
                    one,
                    new SessionSnapshot(Guid.NewGuid(), "drew-iphone", "833f0757d1eb1386", IPAddress.Parse("100.64.0.13"), true, DateTimeOffset.Now, null),
                    new SessionSnapshot(Guid.NewGuid(), "A device with a really long name that goes on for a while", "9a6ac13dbf60c5cd", IPAddress.Parse("100.64.0.14"), false, DateTimeOffset.Now, null),
                ],
                FileChannels = [ipadChannel],
            },
            "problem" => new PreviewFixture { Paired = paired, Problem = "Port 47820 is in use by another app. Quit that app, then open Casement Host again." },
            _ => new PreviewFixture { Paired = paired, Sessions = [one], FileChannels = [ipadChannel] },
        };
    }

    /// <summary>A file moving, one paused, one received.</summary>
    public void FillTransfers(HostTransferList list)
    {
        if (!WithTransfers) return;
        var channel = FileChannels[0].Id;
        var moving = new FileTransferItem(Guid.NewGuid(), "Quarterly report final v3.pdf", 48_000_000, FileDirection.Receiving);
        list.Apply(channel, "drew-ipad-pro", new FileTransferEvent.Started(moving));
        list.Apply(channel, "drew-ipad-pro", new FileTransferEvent.Progress(moving.Id, 21_000_000));

        var paused = new FileTransferItem(Guid.NewGuid(), "Holiday video.mov", 900_000_000, FileDirection.Sending);
        list.Apply(channel, "drew-ipad-pro", new FileTransferEvent.Started(paused));
        list.Apply(channel, "drew-ipad-pro", new FileTransferEvent.Progress(paused.Id, 400_000_000));
        list.Pause(new FileTransferPause(channel, paused.Id, FileDirection.Sending, "drew-ipad-pro", "e5f8a4df59acc24b", DateTimeOffset.Now.AddHours(1)));

        var done = new FileTransferItem(Guid.NewGuid(), "Boarding pass.pdf", 180_000, FileDirection.Receiving);
        list.Apply(channel, "drew-ipad-pro", new FileTransferEvent.Started(done));
        list.Apply(channel, "drew-ipad-pro", new FileTransferEvent.Finished(done.Id, new FileTransferOutcome.Received(@"C:\Users\Public\Downloads\Boarding pass.pdf")));
    }
}
#endif
