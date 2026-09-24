using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Time.Testing;
using Vantage.Host.Windows.Composition;
using Vantage.Host.Windows.Encode;
using Vantage.Host.Windows.Files;
using Vantage.Host.Windows.Logging;
using Vantage.Host.Windows.Startup;
using Vantage.Host.Windows.Tailscale;

namespace Vantage.Host.Windows.Tests;

public class TailscaleJsonTests
{
    [Fact]
    public void WhoisGivesLoginAndDeviceName()
    {
        const string json = """
            {
              "Node": { "ID": 1, "Name": "drews-ipad.tail1234.ts.net.", "ComputedName": "drews-ipad",
                        "Hostinfo": { "OS": "iOS", "Hostname": "Drew's iPad Pro" } },
              "UserProfile": { "ID": 2, "LoginName": "drew@example.com", "DisplayName": "Drew" }
            }
            """;
        var identity = TailscaleJson.ParseWhois(json)!;
        Assert.Equal("drew@example.com", identity.LoginName);
        Assert.Equal("Drew", identity.DisplayName);
        Assert.Equal("Drew's iPad Pro", identity.DeviceName);
        Assert.Equal("drew@example.com", identity.TailnetName);
    }

    [Fact]
    public void WhoisFallsBackToTheComputedName()
    {
        var identity = TailscaleJson.ParseWhois("""{ "Node": { "ComputedName": "ipad" }, "UserProfile": { "DisplayName": "Drew" } }""")!;
        Assert.Equal("ipad", identity.DeviceName);
        Assert.Equal("Drew", identity.TailnetName);
    }

    [Theory]
    [InlineData("")]
    [InlineData("not json")]
    [InlineData("[]")]
    [InlineData("{}")]
    public void WhoisNonsenseIsNull(string json) => Assert.Null(TailscaleJson.ParseWhois(json));

    [Fact]
    public void StatusGivesThisPc()
    {
        const string json = """
            {
              "BackendState": "Running",
              "Self": { "HostName": "drew-pc", "DNSName": "drew-pc.tail1234.ts.net.",
                        "TailscaleIPs": ["fd7a:115c:a1e0::1", "100.64.0.20"] }
            }
            """;
        var self = TailscaleJson.ParseStatus(json)!;
        Assert.True(self.IsRunning);
        Assert.Equal("drew-pc", self.HostName);
        Assert.Equal("drew-pc.tail1234.ts.net", self.DnsName);
        Assert.Equal("100.64.0.20", self.PrimaryAddress);
        Assert.Equal(["100.64.0.20", "fd7a:115c:a1e0::1"], self.Addresses);
    }

    [Fact]
    public void StoppedTailscale()
    {
        var self = TailscaleJson.ParseStatus("""{ "BackendState": "Stopped", "Self": { "HostName": "drew-pc" } }""")!;
        Assert.False(self.IsRunning);
        Assert.Null(self.PrimaryAddress);
    }
}

public class NalUnitsTests
{
    [Fact]
    public void SplitsThreeAndFourByteStartCodes()
    {
        byte[] data = [0, 0, 0, 1, 0x67, 0xAA, 0, 0, 1, 0x68, 0xBB, 0, 0, 0, 1, 0x65, 0x01, 0x02];
        Assert.Equal([7, 8, 5], NalUnits.Types(data));
        var units = NalUnits.Split(data);
        Assert.Equal([(4, 2), (9, 2), (15, 3)], units);
        Assert.True(NalUnits.Contains(data, NalUnits.Idr));
        Assert.False(NalUnits.Contains(data, NalUnits.AccessUnitDelimiter));
    }

    [Fact]
    public void NoStartCodeNoUnits() => Assert.Empty(NalUnits.Split([1, 2, 3, 4]));

    [Fact]
    public void AvccBecomesAnnexBWithParameterSetsFirst()
    {
        byte[] avcc = [0, 0, 0, 2, 0x65, 0x11, 0, 0, 0, 1, 0x06];
        var annexB = NalUnits.AvccToAnnexB(avcc, [[0x67, 0x42], [0x68, 0x43]]);
        Assert.Equal<byte>([0, 0, 0, 1, 0x67, 0x42, 0, 0, 0, 1, 0x68, 0x43, 0, 0, 0, 1, 0x65, 0x11, 0, 0, 0, 1, 0x06], annexB);
        Assert.Equal([7, 8, 5, 6], NalUnits.Types(annexB));
    }

    [Fact]
    public void TruncatedAvccThrows() => Assert.Throws<FormatException>(() => NalUnits.AvccToAnnexB([0, 0, 0, 9, 1]));
}

public class HostCommandLineTests
{
    [Fact]
    public void Defaults()
    {
        var options = HostCommandLine.Parse([], debugBuild: false);
        Assert.Equal(47820, options.Port);
        Assert.Equal("windows", options.Platform);
        Assert.Equal(EncoderPreference.Auto, options.Encoder);
        Assert.False(options.Synthetic);
    }

    [Fact]
    public void ParsesTheBringUpFlags()
    {
        var options = HostCommandLine.Parse(["--port", "47821", "--pairing-code", "246810", "--exit-after", "30", "--receive-folder", @"C:\temp\in",
                                             "--log-file", @"C:\temp\host.log", "--dump-h264", @"C:\temp\v.h264", "--platform", "macos",
                                             "--synthetic", "--encoder", "software", "--rate-control", "lowdelayvbr", "--verbose",
                                             "--send-file-on-connect", @"C:\temp\f.bin", "--capture-fails-for", "6", "--background"],
                                            debugBuild: true);
        Assert.Equal(47821, options.Port);
        Assert.Equal("246810", options.PairingCode);
        Assert.Equal(TimeSpan.FromSeconds(30), options.ExitAfter);
        Assert.Equal(@"C:\temp\in", options.ReceiveFolder);
        Assert.Equal(@"C:\temp\host.log", options.LogFile);
        Assert.Equal(@"C:\temp\v.h264", options.DumpH264);
        Assert.Equal("macos", options.Platform);
        Assert.True(options.Synthetic);
        Assert.Equal(EncoderPreference.SoftwareOnly, options.Encoder);
        Assert.Equal(RateControl.LowDelayVbr, options.RateControl);
        Assert.True(options.Verbose);
        Assert.Equal(@"C:\temp\f.bin", options.SendFileOnConnect);
        Assert.Equal(TimeSpan.FromSeconds(6), options.CaptureFailsFor);
        Assert.True(options.Background);
    }

    [Theory]
    [InlineData("--pairing-code", "246810")]
    [InlineData("--send-file-on-connect", "x")]
    [InlineData("--capture-fails-for", "3")]
    public void DebugFlagsAreRefusedInRelease(string flag, string value) =>
        Assert.Throws<ArgumentException>(() => HostCommandLine.Parse([flag, value], debugBuild: false));

    [Theory]
    [InlineData("--port", "0")]
    [InlineData("--port", "70000")]
    [InlineData("--port", "abc")]
    [InlineData("--pairing-code", "12345")]
    [InlineData("--platform", "linux")]
    [InlineData("--encoder", "gpu")]
    [InlineData("--exit-after", "-1")]
    [InlineData("--what", "")]
    public void BadValues(string flag, string value) =>
        Assert.Throws<ArgumentException>(() => HostCommandLine.Parse(value.Length == 0 ? [flag] : [flag, value], debugBuild: true));

    [Fact]
    public void MissingValue() => Assert.Throws<ArgumentException>(() => HostCommandLine.Parse(["--port"], debugBuild: true));
}

public class FilesTests
{
    [Fact]
    public void ReceiveFolderPrefersTheOverrideThenAUsableChoiceThenDownloads()
    {
        Assert.Equal("override", ReceiveFolder.Resolve("override", "chosen", "downloads", _ => true));
        Assert.Equal("chosen", ReceiveFolder.Resolve(null, "chosen", "downloads", _ => true));
        Assert.Equal("downloads", ReceiveFolder.Resolve(null, "chosen", "downloads", _ => false));
        Assert.Equal("downloads", ReceiveFolder.Resolve(null, null, "downloads", _ => true));
        Assert.Equal("downloads", ReceiveFolder.Resolve("  ", " ", "downloads", _ => true));
    }

    [Fact]
    public void WritableDirectoryCheck()
    {
        var directory = Directory.CreateTempSubdirectory("vantage-tests-").FullName;
        try
        {
            Assert.True(ReceiveFolder.IsWritableDirectory(directory));
            Assert.False(ReceiveFolder.IsWritableDirectory(Path.Combine(directory, "missing")));
            Assert.Empty(Directory.GetFiles(directory));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Theory]
    [InlineData("Report.pdf", true)]
    [InlineData("photo.HEIC", true)]
    [InlineData("clip.mov", true)]
    [InlineData("notes.txt", true)]
    [InlineData("setup.exe", false)]
    [InlineData("script.ps1", false)]
    [InlineData("link.lnk", false)]
    [InlineData("site.url", false)]
    [InlineData("package.msi", false)]
    [InlineData("macro.docm", false)]
    [InlineData("archive.zip", false)]
    [InlineData("noextension", false)]
    public void OnlySafeFilesOpenThemselves(string name, bool opens) => Assert.Equal(opens, ArrivalPolicy.CanAutoOpen(name));

    [Fact]
    public void MarkOfTheWebIsTheInternetZone() => Assert.Equal("[ZoneTransfer]\r\nZoneId=3\r\n", ArrivalPolicy.ZoneIdentifier);

    [Fact]
    public void BatcherWaitsForQuietThenReleasesTogether()
    {
        var time = new FakeTimeProvider();
        var batches = new List<IReadOnlyList<string>>();
        using var batcher = new ArrivalBatcher(batches.Add, time);
        batcher.Add("a");
        time.Advance(TimeSpan.FromSeconds(1));
        batcher.Add("b");
        time.Advance(TimeSpan.FromSeconds(1));
        Assert.Empty(batches);
        time.Advance(TimeSpan.FromSeconds(0.6));
        Assert.Equal(["a", "b"], Assert.Single(batches));
    }

    [Fact]
    public void BatcherGivesUpWaitingAfterTwentySeconds()
    {
        var time = new FakeTimeProvider();
        var batches = new List<IReadOnlyList<string>>();
        using var batcher = new ArrivalBatcher(batches.Add, time);
        for (var i = 0; i < 25; i++)
        {
            batcher.Add($"f{i}");
            time.Advance(TimeSpan.FromSeconds(1));
        }
        Assert.NotEmpty(batches);
        Assert.Equal(20, batches[0].Count); // released 20 s after the first file, with the 20 added before then
    }
}

public class StartupAndTuningTests
{
    private const string Exe = @"C:\Users\you\AppData\Local\Programs\Vantage Host\VantageHost.exe";

    [Fact]
    public void RunValueQuotesThePathAndAddsBackground() =>
        Assert.Equal("\"" + Exe + "\" --background", StartAtLogin.Command(Exe));

    [Fact]
    public void RecognisesItsOwnRunValue()
    {
        Assert.True(StartAtLogin.PointsAt(StartAtLogin.Command(Exe), Exe));
        Assert.True(StartAtLogin.PointsAt("\"" + Exe.ToUpperInvariant() + "\"", Exe));
        Assert.False(StartAtLogin.PointsAt("\"C:\\Other\\VantageHost.exe\" --background", Exe));
        Assert.False(StartAtLogin.PointsAt(null, Exe));
        Assert.False(StartAtLogin.PointsAt("\"unterminated", Exe));
    }

    [Fact]
    public void StartupAppsSwitch()
    {
        Assert.True(StartAtLogin.IsApproved(null));
        Assert.True(StartAtLogin.IsApproved([2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]));
        Assert.False(StartAtLogin.IsApproved([3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]));
    }

    [Theory]
    [InlineData(20_000, 60, 2.0, 666_666u)]
    [InlineData(60_000, 30, 2.0, 4_000_000u)]
    [InlineData(100, 60, 2.0, 64_000u)] // floor
    public void BufferIsFramesAtTheBitrate(int kbps, int fps, double frames, uint bits) =>
        Assert.Equal(bits, EncoderTuning.BufferBits(kbps, fps, frames));

    [Fact]
    public void LogLineFormat()
    {
        var line = FileLoggerProvider.Format(new DateTimeOffset(2026, 9, 24, 14, 3, 11, 482, TimeSpan.Zero).ToLocalTime(),
                                             LogLevel.Information, "Vantage.Session", "stream setup took 12 ms", null);
        Assert.EndsWith(" info  Vantage.Session: stream setup took 12 ms", line);
        Assert.Matches(@"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} ", line);
    }
}
