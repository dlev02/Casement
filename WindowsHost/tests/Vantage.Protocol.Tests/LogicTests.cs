using System.Buffers.Binary;
using System.Net;
using Microsoft.Extensions.Logging.Abstractions;
using Vantage.Protocol.Adaptive;
using Vantage.Protocol.Files;
using Vantage.Protocol.Input;
using Vantage.Protocol.Messages;
using Vantage.Protocol.Video;

namespace Vantage.Protocol.Tests;

public class VideoTests
{
    [Fact]
    public void AnnexBAccessUnitLosesParameterSetsAndAudAndBecomesAvcc()
    {
        byte[] sps = [0x67, 0x64, 0x00, 0x28], pps = [0x68, 0xEE, 0x3C], aud = [0x09, 0xF0], idr = [0x65, 0x88, 0x84, 0x00, 0x21];
        var annexB = new List<byte>();
        foreach (var unit in new[] { aud, sps, pps, idr }) annexB.AddRange([0, 0, 0, 1, .. unit]);
        var au = AnnexB.ToAccessUnit(annexB.ToArray());
        Assert.True(au.IsKeyframe);
        Assert.Equal(sps, au.Sps);
        Assert.Equal(pps, au.Pps);
        Assert.Equal([0, 0, 0, 5, .. idr], au.Avcc);
        Assert.Equal([0, 0, 0, 1, .. idr], AnnexB.FromAvcc(au.Avcc));
    }

    [Fact]
    public void ThreeByteStartCodesAndTrailingZerosSplitCleanly()
    {
        byte[] data = [0, 0, 1, 0x41, 0x9A, 0x00, 0x00, 0x00, 0x01, 0x41, 0x9B];
        var units = AnnexB.SplitNalUnits(data);
        Assert.Equal(2, units.Count);
        Assert.Equal(new byte[] { 0x41, 0x9A }, units[0].ToArray());
        Assert.False(AnnexB.ToAccessUnit(data).IsKeyframe);
    }

    [Fact]
    public void TheTestClipHasAnIdrEverySecond()
    {
        var clip = new SyntheticHost.Clip(ClipPath());
        Assert.Equal(120, clip.Units.Count);
        Assert.Equal([0, 30, 60, 90], clip.Keyframes);
        Assert.Equal(30, clip.NextKeyframe(1));
        Assert.Equal(0, clip.NextKeyframe(91));
        var first = AnnexB.ToAccessUnit(clip.Units[0]);
        Assert.NotNull(first.Sps);
        Assert.NotNull(first.Pps);
        Assert.True(AnnexB.AvccHasIdr(first.Avcc));
    }

    internal static string ClipPath()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null && !File.Exists(Path.Combine(directory.FullName, "assets", "test-clip", "clip-1600x1000.h264")))
            directory = directory.Parent;
        return Path.Combine(directory!.FullName, "assets", "test-clip", "clip-1600x1000.h264");
    }
}

public class FileNamesTests
{
    [Theory]
    [InlineData("../../.ssh/authorized_keys", "authorized_keys")]
    [InlineData("C:\\Users\\x\\Report.pdf", "Report.pdf")]
    [InlineData("invoice\u202Efdp.exe", "invoicefdp.exe")]
    [InlineData("  ...hidden. ", "hidden")]
    [InlineData("a:b", "a-b")]
    [InlineData("what?<is>|this*\".txt", "what--is--this--.txt")]
    [InlineData("CON", "_CON")]
    [InlineData("nul.txt", "_nul.txt")]
    [InlineData("com1.tar.gz", "_com1.tar.gz")]
    [InlineData("LPT¹", "_LPT¹")]
    [InlineData("CONSOLE.txt", "CONSOLE.txt")]
    [InlineData("", "Untitled")]
    [InlineData("///", "Untitled")]
    [InlineData("e\u0301t\u00e9.txt", "\u00e9t\u00e9.txt")]
    public void Sanitizes(string raw, string expected) => Assert.Equal(expected, FileNames.Sanitize(raw));

    [Fact]
    public void LongNamesKeepTheirExtensionAndWholeCharacters()
    {
        var name = new string('a', 150) + string.Concat(Enumerable.Repeat("👍🏽", 20)) + ".pdf";
        var result = FileNames.Sanitize(name);
        Assert.EndsWith(".pdf", result);
        Assert.True(System.Text.Encoding.UTF8.GetByteCount(result) <= 200);
        Assert.DoesNotContain('\uFFFD', result);
        Assert.True(System.Globalization.StringInfo.ParseCombiningCharacters(result).Length > 150);
    }

    [Fact]
    public void UniqueNamesCountUpAndIgnoreCase()
    {
        var folder = Directory.CreateTempSubdirectory("vantage-names-").FullName;
        try
        {
            File.WriteAllText(Path.Combine(folder, "report.PDF"), "");
            File.WriteAllText(Path.Combine(folder, "Report 2.pdf"), "");
            Assert.Equal(Path.Combine(folder, "Report 3.pdf"), FileNames.UniquePath("Report.pdf", folder, caseInsensitive: true));
            Assert.Equal("Makefile 2", FileNames.Candidate("Makefile", 2));
            Assert.Equal(".env 2", FileNames.Candidate(".env", 2));
        }
        finally
        {
            Directory.Delete(folder, true);
        }
    }
}

public class AttachTokenTests
{
    private sealed class Owner;

    [Fact]
    public void TokensAreSingleUseBoundToTheAddressAndExpire()
    {
        var time = new ManualTime();
        var registry = new AttachTokenRegistry<Owner>(time);
        var owner = new Owner();
        var loopback = IPAddress.Parse("127.0.0.1");

        var token = registry.Issue(owner, loopback);
        Assert.Equal(32, token.Length);
        Assert.Same(owner, registry.Claim(token, IPAddress.Parse("::ffff:127.0.0.1")));
        Assert.Null(registry.Claim(token, loopback)); // used

        token = registry.Issue(owner, loopback);
        Assert.Null(registry.Claim(token, IPAddress.IPv6Loopback)); // ::1 isn't 127.0.0.1
        Assert.Null(registry.Claim(token, loopback)); // and the miss burned it

        token = registry.Issue(owner, loopback);
        time.Advance(TimeSpan.FromSeconds(61));
        Assert.Null(registry.Claim(token, loopback));

        token = registry.Issue(owner, loopback);
        registry.Revoke(owner);
        Assert.Null(registry.Claim(token, loopback));

        var first = registry.Issue(owner, loopback);
        registry.Issue(owner, loopback);
        Assert.Null(registry.Claim(first, loopback)); // a new token replaces the owner's old one
    }
}

public class AdaptiveTests
{
    [Fact]
    public void LossCutsAndHoldsThenProbesUp()
    {
        var time = new ManualTime();
        var adaptive = new AdaptiveController(20_000, time);
        QualityFeedback Feedback(ulong dropped) => new()
        {
            RttMillis = 10, DecodeMillis = 2, FramesReceived = 15, FramesDropped = dropped, QueueDepth = 0, BytesReceived = 1, WindowSeconds = 0.25,
        };
        time.Advance(TimeSpan.FromSeconds(3));
        Assert.Equal(22_000, adaptive.Apply(Feedback(0)));
        Assert.Null(adaptive.Apply(Feedback(0))); // 2 s between raises
        Assert.Equal(15_399, adaptive.Apply(Feedback(1)));
        time.Advance(TimeSpan.FromSeconds(1));
        Assert.Null(adaptive.Apply(Feedback(0))); // held
        time.Advance(TimeSpan.FromSeconds(1.5));
        Assert.Equal(16_938, adaptive.Apply(Feedback(0)));
        Assert.Equal(11_856, adaptive.NoteBacklog());
        Assert.Equal(4_000, AdaptiveController.StartBitrate(640 * 480, 30));
        Assert.Equal(60_000, AdaptiveController.StartBitrate(5120 * 2880, 60));
    }

    [Fact]
    public void StaticScreensDropToTextMode()
    {
        var adaptive = new AdaptiveController(20_000);
        Assert.Equal(EncodingMode.Motion, adaptive.Mode);
        for (var i = 0; i < 60; i++) adaptive.Observe(0);
        Assert.Equal(EncodingMode.Text, adaptive.Mode);
        Assert.Equal(30, adaptive.Fps);
        Assert.Equal(32, adaptive.MaxQP);
    }
}

public class InputTranslatorTests
{
    private readonly List<string> _sent = [];
    private readonly WindowsInputTranslator _translator;

    public InputTranslatorTests()
    {
        _translator = new WindowsInputTranslator(new Recorder(_sent), NullLogger.Instance);
        _translator.SetDisplay(new DisplayInfo
        {
            Id = 2, Name = "Dell", PixelWidth = 3840, PixelHeight = 2160, PointWidth = 2560, PointHeight = 1440, Scale = 1.5,
            OriginX = -3840, OriginY = 0, IsMain = false, IsBuiltIn = false, IsVirtual = false, RefreshRate = 60,
        });
    }

    private sealed class Recorder(List<string> sent) : IInputInjector
    {
        public void Send(ReadOnlySpan<InputAction> actions)
        {
            foreach (var action in actions) sent.Add(action.ToString());
        }
    }

    [Fact]
    public void ChordsPressMissingModifiersCtrlAltShiftWinAndReleaseInReverse()
    {
        _translator.Key(new KeyEvent { KeyCode = 0x02, IsDown = true, Modifiers = KeyModifiers.Command | KeyModifiers.Shift | KeyModifiers.Control | KeyModifiers.Option });
        _translator.Key(new KeyEvent { KeyCode = 0x02, IsDown = false, Modifiers = KeyModifiers.Command | KeyModifiers.Shift | KeyModifiers.Control | KeyModifiers.Option });
        Assert.Equal([
            "key 1D down", "key 38 down", "key 2A down", "key E0 5B down", "key 20 down",
            "key 20 up", "key E0 5B up", "key 2A up", "key 38 up", "key 1D up",
        ], _sent);
    }

    [Fact]
    public void HeldModifiersAreNotPressedAgainAndRepeatsAreKeydowns()
    {
        _translator.Key(new KeyEvent { KeyCode = 0x3E, IsDown = true }); // right Ctrl held
        _translator.Key(new KeyEvent { KeyCode = 0x08, IsDown = true, Modifiers = KeyModifiers.Control });
        _translator.Key(new KeyEvent { KeyCode = 0x08, IsDown = true, Modifiers = KeyModifiers.Control, IsRepeat = true });
        _translator.Key(new KeyEvent { KeyCode = 0x08, IsDown = false, Modifiers = KeyModifiers.Control });
        Assert.Equal(["key E0 1D down", "key 2E down", "key 2E down", "key 2E up"], _sent);
        _translator.ReleaseAll();
        Assert.Equal("key E0 1D up", _sent[^1]);
    }

    [Fact]
    public void FunctionKeyIsDroppedAndArrowsAreExtended()
    {
        _translator.Key(new KeyEvent { KeyCode = 0x3F, IsDown = true });
        _translator.Key(new KeyEvent { KeyCode = 0x7E, IsDown = true, Modifiers = KeyModifiers.Function });
        Assert.Equal(["key E0 48 down"], _sent);
    }

    [Fact]
    public void PointsMapToTheMonitorsPixelsWithEdgesOnTheLastPixel()
    {
        _translator.Pointer(new PointerEvent { Action = PointerAction.Move, X = 1280, Y = 720 });
        _translator.Pointer(new PointerEvent { Action = PointerAction.Move, X = 2559, Y = 1439 });
        _translator.Pointer(new PointerEvent { Action = PointerAction.Move, X = -5, Y = 99999 });
        Assert.Equal(["move -1920,1080", "move -1,2159", "move -3840,2159"], _sent);
    }

    [Fact]
    public void ModifiedClicksWrapTheButtonAndReleaseAllLetsEverythingGo()
    {
        _translator.Pointer(new PointerEvent { Action = PointerAction.Down, Button = PointerButton.Left, X = 0, Y = 0, Modifiers = KeyModifiers.Shift });
        _translator.Pointer(new PointerEvent { Action = PointerAction.Up, Button = PointerButton.Left, X = 0, Y = 0, Modifiers = KeyModifiers.Shift });
        Assert.Equal(["key 2A down", "move -3840,0", "Left down -3840,0", "move -3840,0", "Left up -3840,0", "key 2A up"], _sent);
        _sent.Clear();
        _translator.Pointer(new PointerEvent { Action = PointerAction.Down, Button = PointerButton.Forward, X = 10, Y = 10 });
        _translator.Key(new KeyEvent { KeyCode = 0x00, IsDown = true });
        _translator.Key(new KeyEvent { KeyCode = 0x37, IsDown = true });
        _sent.Clear();
        _translator.ReleaseAll();
        Assert.Equal(["Forward up -3825,15", "key 1E up", "key E0 5B up"], _sent);
    }

    [Fact]
    public void ScrollingScalesAndCarriesTheRemainder()
    {
        _translator.Scroll(new ScrollEvent { Phase = ScrollPhase.None, IsContinuous = false, DeltaX = 0, DeltaY = 1, X = 0, Y = 0 });
        _translator.Scroll(new ScrollEvent { Phase = ScrollPhase.Began, IsContinuous = true, DeltaX = 0, DeltaY = 10, X = 0, Y = 0 });
        _translator.Scroll(new ScrollEvent { Phase = ScrollPhase.Changed, IsContinuous = true, DeltaX = 0, DeltaY = 10, X = 0, Y = 0 });
        _translator.Scroll(new ScrollEvent { Phase = ScrollPhase.Changed, IsContinuous = true, DeltaX = 4, DeltaY = 0, X = 0, Y = 0, Modifiers = KeyModifiers.Control });
        // 10 pt = 25 units twice; −4 pt horizontally = −10 units, with Ctrl around it.
        Assert.Equal(["wheel 120", "wheel 25", "wheel 25", "key 1D down", "hwheel -10", "key 1D up"], _sent);
        _sent.Clear();
        _translator.Scroll(new ScrollEvent { Phase = ScrollPhase.Changed, IsContinuous = true, DeltaX = 0, DeltaY = 0.19f, X = 0, Y = 0 });
        _translator.Scroll(new ScrollEvent { Phase = ScrollPhase.Changed, IsContinuous = true, DeltaX = 0, DeltaY = 0.19f, X = 0, Y = 0 });
        Assert.Empty(_sent); // 0.475 + 0.475 units: nothing yet
        _translator.Scroll(new ScrollEvent { Phase = ScrollPhase.Changed, IsContinuous = true, DeltaX = 0, DeltaY = 0.19f, X = 0, Y = 0 });
        Assert.Equal(["wheel 1"], _sent);
    }

    [Fact]
    public void TextTypesUnicodeWithReturnAndTab()
    {
        _translator.Text("a\r\n\t😀");
        Assert.Equal([
            "unicode U+0061 down", "unicode U+0061 up", "key 1C down", "key 1C up", "key 0F down", "key 0F up",
            "unicode U+D83D down", "unicode U+D83D up", "unicode U+DE00 down", "unicode U+DE00 up",
        ], _sent);
    }

    [Fact]
    public void EveryKeyInTheSpecTableMaps()
    {
        ushort[] extended = [0x72, 0x73, 0x74, 0x75, 0x77, 0x79, 0x7B, 0x7C, 0x7D, 0x7E, 0x47, 0x4B, 0x4C, 0x6E, 0x4A, 0x48, 0x49, 0x3E, 0x3D, 0x37, 0x36];
        foreach (var code in extended) Assert.True(ScanCodes.For(code)!.Value.Extended, $"0x{code:X2}");
        Assert.Equal(new ScanCode(0x1E, false), ScanCodes.For(0x00));
        Assert.Equal(new ScanCode(0x56, false), ScanCodes.For(0x0A));
        Assert.Equal(new ScanCode(0x6B, false), ScanCodes.For(0x5A));
        Assert.Null(ScanCodes.For(0x3F));
        Assert.Null(ScanCodes.For(0xFF));
        Assert.Equal(119, Enumerable.Range(0, 0x80).Count(code => ScanCodes.For((ushort)code) is not null));
    }
}

internal sealed class ManualTime : TimeProvider
{
    private DateTimeOffset _now = new(2026, 9, 24, 12, 0, 0, TimeSpan.Zero);
    public override DateTimeOffset GetUtcNow() => _now;
    public void Advance(TimeSpan by) => _now += by;
}
