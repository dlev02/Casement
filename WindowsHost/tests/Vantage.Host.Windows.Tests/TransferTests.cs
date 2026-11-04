using System.Buffers.Binary;
using System.Globalization;
using Microsoft.Extensions.Time.Testing;
using Vantage.Host.Windows.Files;
using Vantage.Host.Windows.Tray;
using Vantage.Protocol.Files;
using Vantage.Protocol.Host;

namespace Vantage.Host.Windows.Tests;

public class HostTransferListTests
{
    private const ulong MiB = 1024 * 1024;
    private static readonly Guid Channel = Guid.Parse("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee");
    private static readonly Guid Report = Guid.Parse("00000000-0000-0000-0000-00000000000a");
    private static readonly Guid Movie = Guid.Parse("00000000-0000-0000-0000-00000000000b");

    private readonly FakeTimeProvider _time = new(DateTimeOffset.Parse("2026-11-04T12:00:00Z", CultureInfo.InvariantCulture));
    private readonly HostTransferList _list;

    public HostTransferListTests()
    {
        _list = new HostTransferList(_time);
    }

    private static void English() => CultureInfo.CurrentCulture = CultureInfo.GetCultureInfo("en-US");

    private static FileTransferItem Item(Guid id, string name, ulong bytes, FileDirection direction) => new(id, name, bytes, direction);

    private HostTransfer Row(Guid id) => _list.Find(id)!;

    private void Progress(Guid id, ulong bytes, double afterSeconds)
    {
        _time.Advance(TimeSpan.FromSeconds(afterSeconds));
        _list.Apply(Channel, "Drew's iPad", new FileTransferEvent.Progress(id, bytes));
    }

    [Fact]
    public void AQueuedSendWaitsThenMovesWithASmoothedSpeedAndTimeLeft()
    {
        English();
        _list.Queue(Channel, "Drew's iPad", Item(Report, "Report.pdf", 48 * MiB, FileDirection.Sending));
        Assert.Equal(HostTransferState.Waiting, Row(Report).State);
        Assert.Equal("Waiting · 48.0 MB · To Drew's iPad", Row(Report).Detail);

        _list.Apply(Channel, "Drew's iPad", new FileTransferEvent.Started(Item(Report, "Report.pdf", 48 * MiB, FileDirection.Sending)));
        Progress(Report, 0, 0);
        Progress(Report, 1 * MiB, 0.25);
        // Under half a second of progress: no speed yet, so it says where it's going instead.
        Assert.Null(Row(Report).BytesPerSecond);
        Assert.Equal("1.00 MB of 48.0 MB · To Drew's iPad", Row(Report).Detail);

        Progress(Report, 4 * MiB, 0.75);
        Assert.Equal(4.0 * MiB, Row(Report).BytesPerSecond!.Value, 3);
        Progress(Report, 6 * MiB, 1);
        // 60 % of the old speed, 40 % of the new (the Mac's smoothing): 4 × 0.6 + 2 × 0.4.
        Assert.Equal(3.2 * MiB, Row(Report).BytesPerSecond!.Value, 3);
        Assert.InRange(Row(Report).TimeLeft!.Value.TotalSeconds, 13.12, 13.13);
        Assert.Equal("6.00 MB of 48.0 MB · 3.19 MB/s · 14 sec left", Row(Report).Detail);
    }

    [Fact]
    public void ACutOffFileIsPausedLeftOutOfTheRingAndCarriesOnWhenItResumes()
    {
        English();
        _list.Apply(Channel, "Drew's iPad", new FileTransferEvent.Started(Item(Movie, "Movie.mov", 100 * MiB, FileDirection.Sending)));
        Progress(Movie, 0, 0);
        Progress(Movie, 45 * MiB + 1, 1);
        Assert.NotNull(_list.Activity);

        _list.Pause(new FileTransferPause(Channel, Movie, FileDirection.Sending, "Drew's iPad", "fp", _time.GetUtcNow().AddHours(1)));
        Assert.Equal(HostTransferState.Paused, Row(Movie).State);
        Assert.True(Row(Movie).IsActive);
        Assert.Equal("Paused at 45% · resumes when Drew's iPad reconnects", Row(Movie).Detail);
        Assert.Null(_list.Activity);
        Assert.Null(_list.Summary);

        // The same id on a new channel: it picks up where it was.
        var newChannel = Guid.NewGuid();
        _time.Advance(TimeSpan.FromMinutes(10));
        Assert.Null(_list.Apply(newChannel, "Drew's iPad", new FileTransferEvent.Started(Item(Movie, "Movie.mov", 100 * MiB, FileDirection.Sending))));
        Assert.Equal(HostTransferState.Moving, Row(Movie).State);
        Assert.Equal(newChannel, Row(Movie).ChannelId);
        Assert.Equal(45 * MiB + 1, Row(Movie).BytesDone);
        Assert.Null(Row(Movie).ResumesBefore);
        Assert.Equal("Sending Movie.mov, 45%", _list.Summary);

        var ended = _list.Apply(newChannel, "Drew's iPad", new FileTransferEvent.Finished(Movie, new FileTransferOutcome.Sent("Movie.mov")));
        Assert.Equal(HostTransferState.Done, ended!.State);
        Assert.Equal("Sent to Drew's iPad", ended.Detail);
        Assert.Equal(1.0, ended.Fraction);
    }

    [Fact]
    public void APausedFileThatNeverComesBackFailsOnce()
    {
        _list.Apply(Channel, "Drew's iPad", new FileTransferEvent.Started(Item(Report, "Report.pdf", 10, FileDirection.Receiving)));
        _list.Pause(new FileTransferPause(Channel, Report, FileDirection.Receiving, "Drew's iPad", "fp", _time.GetUtcNow().AddHours(1)));
        _time.Advance(TimeSpan.FromMinutes(59));
        Assert.Empty(_list.Tick());
        _time.Advance(TimeSpan.FromMinutes(1));
        var failed = Assert.Single(_list.Tick());
        Assert.Equal(HostTransferState.Failed, failed.State);
        Assert.Equal("The connection was lost.", failed.Detail);
        Assert.Empty(_list.Tick());
    }

    [Fact]
    public void FinishedRowsStayAMinuteAndLateEventsDontReviveThem()
    {
        _list.Apply(Channel, "Drew's iPad", new FileTransferEvent.Started(Item(Report, "Report.pdf", 10, FileDirection.Receiving)));
        Assert.NotNull(_list.Apply(Channel, "Drew's iPad", new FileTransferEvent.Finished(Report, new FileTransferOutcome.Failed("The disk is full."))));
        Assert.Null(_list.Apply(Channel, "Drew's iPad", new FileTransferEvent.Progress(Report, 5)));
        Assert.Null(_list.Apply(Channel, "Drew's iPad", new FileTransferEvent.Finished(Report, new FileTransferOutcome.Failed("Again."))));
        Assert.Equal("The disk is full.", Row(Report).Detail);
        Assert.Equal(0UL, Row(Report).BytesDone);

        _time.Advance(TimeSpan.FromSeconds(59));
        _list.Tick();
        Assert.Single(_list.Items);
        _time.Advance(TimeSpan.FromSeconds(1));
        _list.Tick();
        Assert.Empty(_list.Items);
        Assert.False(_list.NeedsTicking);
    }

    [Fact]
    public void AReceivedFileNamesWhereItWasSaved()
    {
        var saved = Path.Combine(Path.GetTempPath(), "Downloads", "Report (2).pdf");
        _list.Apply(Channel, "Drew's iPad", new FileTransferEvent.Started(Item(Report, "Report.pdf", 10, FileDirection.Receiving)));
        _list.Apply(Channel, "Drew's iPad", new FileTransferEvent.Finished(Report, new FileTransferOutcome.Received(saved)));
        Assert.Equal("Report (2).pdf", Row(Report).DisplayName);
        Assert.Equal("Received from Drew's iPad · in Downloads", Row(Report).Detail);
        Assert.Equal(saved, Row(Report).SavedPath);
    }

    [Fact]
    public void CancellingHereSettlesOnlyFilesWithNothingMoving()
    {
        _list.Queue(Channel, "Drew's iPad", Item(Report, "Report.pdf", 10, FileDirection.Sending));
        _list.Apply(Channel, "Drew's iPad", new FileTransferEvent.Started(Item(Movie, "Movie.mov", 10, FileDirection.Sending)));
        _list.MarkCancelled(Report);
        _list.MarkCancelled(Movie);
        Assert.Equal("Cancelled", Row(Report).Detail);
        Assert.False(Row(Report).IsActive);
        // A moving one is settled by the engine's own Cancelled.
        Assert.Equal(HostTransferState.Moving, Row(Movie).State);
        _list.Apply(Channel, "Drew's iPad", new FileTransferEvent.Finished(Movie, new FileTransferOutcome.Cancelled(false)));
        Assert.Equal(HostTransferState.Cancelled, Row(Movie).State);
    }

    [Theory]
    [InlineData(true, false, true)]
    [InlineData(false, true, false)]
    [InlineData(true, true, true)]
    public void TheArrowPointsDownWhenAnythingArrives(bool receiving, bool sending, bool down)
    {
        if (receiving) _list.Apply(Channel, "iPad", new FileTransferEvent.Started(Item(Report, "a", 100, FileDirection.Receiving)));
        if (sending) _list.Apply(Channel, "iPad", new FileTransferEvent.Started(Item(Movie, "b", 100, FileDirection.Sending)));
        var activity = _list.Activity!.Value;
        Assert.Equal(receiving, activity.Receiving);
        Assert.Equal(sending, activity.Sending);
        Assert.Equal(down, activity.PointsDown);
    }

    [Fact]
    public void TheRingCountsBytesAcrossEveryMovingFileInSteps()
    {
        English();
        _list.Apply(Channel, "iPad", new FileTransferEvent.Started(Item(Report, "Report.pdf", 300, FileDirection.Receiving)));
        _list.Apply(Channel, "iPad", new FileTransferEvent.Progress(Report, 150));
        Assert.Equal("Receiving Report.pdf, 50%", _list.Summary);
        Assert.Equal(12, _list.Activity!.Value.Step);
        _list.Queue(Channel, "iPad", Item(Movie, "Movie.mov", 700, FileDirection.Sending));
        // 150 of 1,000 bytes: 15 %, step 3 of 24.
        Assert.Equal(3, _list.Activity!.Value.Step);
        Assert.Equal(0.125, _list.Activity!.Value.Fraction);
        Assert.Equal("Transferring 2 files, 15%", _list.Summary);
    }

    [Fact]
    public void SummariesNameTheWay()
    {
        English();
        HostTransfer Sending(string name, ulong done) =>
            new(Guid.NewGuid(), name, FileDirection.Sending, "iPad") { State = HostTransferState.Moving, ByteCount = 100, BytesDone = done };
        Assert.Equal("Sending 3 files, 10%", HostTransferText.Summary([Sending("a", 10), Sending("b", 10), Sending("c", 10)]));
        Assert.Null(HostTransferText.Summary([Sending("a", 10) with { State = HostTransferState.Paused }]));
    }

    [Theory]
    [InlineData(0UL, "0 bytes")]
    [InlineData(1UL, "1 byte")]
    [InlineData(1023UL, "1023 bytes")]
    [InlineData(1024UL, "1.00 KB")]
    [InlineData(12697UL, "12.3 KB")]
    [InlineData(1024000UL, "0.97 MB")]
    [InlineData(1288490188UL, "1.19 GB")]
    [InlineData(132070244352UL, "123 GB")]
    public void SizesReadLikeFileExplorer(ulong bytes, string text)
    {
        English();
        Assert.Equal(text, HostTransferText.Bytes(bytes));
    }

    [Theory]
    [InlineData(4.2, "5 sec")]
    [InlineData(59.5, "1 min")]
    [InlineData(90, "2 min")]
    [InlineData(3599, "1 hr")]
    [InlineData(9000, "3 hr")]
    public void TimeLeftIsOneAbbreviatedUnit(double seconds, string text)
    {
        English();
        Assert.Equal(text, HostTransferText.Duration(TimeSpan.FromSeconds(seconds)));
    }
}

public class TrayGlyphTests
{
    private static byte Alpha(byte[] rgba, int size, int x, int y) => rgba[(y * size + x) * 4 + 3];

    [Fact]
    public void TheRingFillsClockwiseFromTheTopOverAFaintTrack()
    {
        // 16 px: the ring's bottom (6 o'clock) is track at 40 %, filled at 60 %.
        var partly = TrayGlyph.Render(16, 0.4, true, false);
        var mostly = TrayGlyph.Render(16, 0.6, true, false);
        var trackAlpha = (int)Math.Round(TrayGlyph.TrackOpacity * 255);
        Assert.InRange(Alpha(partly, 16, 8, 14), trackAlpha - 30, trackAlpha + 10);
        Assert.Equal(255, Alpha(mostly, 16, 8, 14));
        // The top is always filled; the corners are always clear.
        Assert.Equal(255, Alpha(partly, 16, 8, 1));
        Assert.Equal(0, Alpha(partly, 16, 0, 0));
        Assert.Equal(0, Alpha(mostly, 16, 15, 15));
    }

    [Fact]
    public void TheArrowPointsTheWayFilesMove()
    {
        // The left wing ends low for a down arrow and high for an up one.
        var down = TrayGlyph.Render(16, 0.5, true, false);
        var up = TrayGlyph.Render(16, 0.5, false, false);
        Assert.True(Alpha(down, 16, 5, 8) > 200);
        Assert.True(Alpha(up, 16, 5, 8) < 60);
        Assert.True(Alpha(up, 16, 5, 7) > Alpha(down, 16, 5, 7) || Alpha(up, 16, 5, 6) > 200);
    }

    [Fact]
    public void ColoursFollowTheTaskbar()
    {
        var onLight = TrayGlyph.Render(20, 1, true, true);
        var onDark = TrayGlyph.Render(20, 1, true, false);
        Assert.Equal(new byte[] { 27, 27, 27 }, onLight[..3]);
        Assert.Equal(new byte[] { 255, 255, 255 }, onDark[..3]);
    }

    [Theory]
    [InlineData(16)]
    [InlineData(20)]
    [InlineData(24)]
    [InlineData(32)]
    public void IconResourceIsABottomUpDibWithAMask(int size)
    {
        var rgba = TrayGlyph.Render(size, 0.5, true, false);
        var resource = TrayGlyph.IconResource(size, 0.5, true, false);
        var maskStride = (size + 31) / 32 * 4;
        Assert.Equal(40 + size * size * 4 + maskStride * size, resource.Length);
        Assert.Equal(40, BinaryPrimitives.ReadInt32LittleEndian(resource));
        Assert.Equal(size, BinaryPrimitives.ReadInt32LittleEndian(resource.AsSpan(4)));
        Assert.Equal(size * 2, BinaryPrimitives.ReadInt32LittleEndian(resource.AsSpan(8)));
        Assert.Equal(32, BinaryPrimitives.ReadUInt16LittleEndian(resource.AsSpan(14)));
        // The top-left pixel of the picture is the first pixel of the last row (BGRA).
        var topRow = 40 + (size - 1) * size * 4;
        var x = size / 2;
        Assert.Equal(rgba[x * 4 + 3], resource[topRow + x * 4 + 3]);
        Assert.Equal(rgba[x * 4], resource[topRow + x * 4 + 2]);
        Assert.All(resource[(40 + size * size * 4)..], b => Assert.Equal(0, b));
    }
}
