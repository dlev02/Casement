using System.Globalization;
using Vantage.Protocol.Files;
using Vantage.Protocol.Host;

namespace Vantage.Host.Windows.Files;

/// <summary>Where a <see cref="HostTransfer"/> stands.</summary>
public enum HostTransferState
{
    /// <summary>Queued behind another send.</summary>
    Waiting,
    /// <summary>Bytes are moving.</summary>
    Moving,
    /// <summary>The connection cut it off; it carries on when its device comes back (<see cref="HostTransfer.ResumesBefore"/>).</summary>
    Paused,
    /// <summary>Sent or received.</summary>
    Done,
    /// <summary>Failed; <see cref="HostTransfer.FailureReason"/> says why.</summary>
    Failed,
    /// <summary>Cancelled here or by the device.</summary>
    Cancelled,
}

/// <summary>
/// One file in the tray's and the Files page's transfer lists (the Mac's <c>HostTransfer</c>):
/// what it is, how far it got, its smoothed speed, and how it ended. Immutable; a
/// <see cref="HostTransferList"/> replaces it as events arrive.
/// </summary>
/// <param name="Id">The transfer id (the same across a resume).</param>
/// <param name="Name">The file's name as offered.</param>
/// <param name="Direction">Which way it moves.</param>
/// <param name="DeviceName">The device on the other end ("Drew's iPad").</param>
public sealed record HostTransfer(Guid Id, string Name, FileDirection Direction, string DeviceName)
{
    /// <summary>The file channel it is (or was last) on, for <c>HostListener.CancelTransfer</c>.</summary>
    public Guid ChannelId { get; init; }

    /// <summary>Total size.</summary>
    public ulong ByteCount { get; init; }

    /// <summary>Bytes done so far (a resumed prefix included).</summary>
    public ulong BytesDone { get; init; }

    /// <summary>Where it stands.</summary>
    public HostTransferState State { get; init; }

    /// <summary>Why it failed (user-facing), when <see cref="State"/> is <see cref="HostTransferState.Failed"/>.</summary>
    public string? FailureReason { get; init; }

    /// <summary>Where a received file was saved.</summary>
    public string? SavedPath { get; init; }

    /// <summary>Smoothed speed once there's enough to go on (about half a second of progress).</summary>
    public double? BytesPerSecond { get; init; }

    /// <summary>When it ended (finished rows stay listed for <see cref="HostTransferList.KeepFinishedFor"/>).</summary>
    public DateTimeOffset? FinishedAt { get; init; }

    /// <summary>A paused file that hasn't resumed by then has failed.</summary>
    public DateTimeOffset? ResumesBefore { get; init; }

    internal DateTimeOffset? SampledAt { get; init; }

    internal ulong SampledBytes { get; init; }

    /// <summary>Still waiting, moving or paused: it can be cancelled.</summary>
    public bool IsActive => State is HostTransferState.Waiting or HostTransferState.Moving or HostTransferState.Paused;

    /// <summary>Counted by the tray's progress ring. A paused file can wait an hour for its device, so it isn't.</summary>
    public bool IsMoving => State is HostTransferState.Waiting or HostTransferState.Moving;

    /// <summary>The name to show: once saved, the name it got ("Report (2).pdf" when Report.pdf was taken).</summary>
    public string DisplayName => SavedPath is { } path ? Path.GetFileName(path) : Name;

    /// <summary>0–1.</summary>
    public double Fraction => ByteCount == 0 ? (State == HostTransferState.Done ? 1 : 0) : Math.Min(1, (double)BytesDone / ByteCount);

    /// <summary>Time left at the current speed, while it's moving.</summary>
    public TimeSpan? TimeLeft =>
        State == HostTransferState.Moving && BytesPerSecond is > 0 and var rate && ByteCount > BytesDone
            ? TimeSpan.FromSeconds((ByteCount - BytesDone) / rate)
            : null;

    /// <summary>The row's status line (<see cref="HostTransferText.Detail"/>).</summary>
    public string Detail => HostTransferText.Detail(this);
}

/// <summary>
/// The transfers the tray and the Files page show, driven by <c>HostListener</c>'s
/// <c>FileSendQueued</c>, <c>FileTransfer</c> and <c>FileTransferPaused</c> events (the Mac's
/// <c>HostController.transfers</c>). Rows are kept in arrival order; finished ones stay
/// <see cref="KeepFinishedFor"/> so the outcome can be read (and a received file shown), then
/// <see cref="Tick"/> drops them. Not thread-safe: the app uses it on the UI thread only.
/// </summary>
public sealed class HostTransferList
{
    /// <summary>How long a done, failed or cancelled row stays listed.</summary>
    public static readonly TimeSpan KeepFinishedFor = TimeSpan.FromSeconds(60);

    /// <summary>What a paused file that never resumed says, like any lost connection.</summary>
    public const string LostConnection = "The connection was lost.";

    private readonly TimeProvider _time;
    private readonly List<HostTransfer> _items = [];

    /// <param name="time">Clock (tests use a fake).</param>
    public HostTransferList(TimeProvider? time = null) => _time = time ?? TimeProvider.System;

    /// <summary>The rows, oldest first.</summary>
    public IReadOnlyList<HostTransfer> Items => _items;

    /// <summary>The row with this id, if listed.</summary>
    public HostTransfer? Find(Guid id) => _items.Find(t => t.Id == id);

    /// <summary>Something is paused or finished, so <see cref="Tick"/> has work to do.</summary>
    public bool NeedsTicking => _items.Exists(t => t.State == HostTransferState.Paused || !t.IsActive);

    /// <summary>A send was queued (it waits its turn).</summary>
    public void Queue(Guid channelId, string deviceName, FileTransferItem item)
    {
        if (Find(item.Id) is not null) return;
        _items.Add(new HostTransfer(item.Id, item.Name, item.Direction, deviceName)
        {
            ChannelId = channelId,
            ByteCount = item.ByteCount,
            State = HostTransferState.Waiting,
        });
    }

    /// <summary>
    /// Applies an engine event from <paramref name="channelId"/>. Returns the row when this event
    /// ended it (for a notification), else null. Events for rows already settled are ignored, so
    /// a late progress report can't revive a finished file.
    /// </summary>
    /// <param name="channelId">The channel it came from.</param>
    /// <param name="deviceName">Who is on that channel (used for a row it creates).</param>
    /// <param name="transferEvent">The event.</param>
    public HostTransfer? Apply(Guid channelId, string deviceName, FileTransferEvent transferEvent)
    {
        switch (transferEvent)
        {
            case FileTransferEvent.Started started:
            {
                var item = started.Item;
                var index = _items.FindIndex(t => t.Id == item.Id);
                if (index < 0)
                {
                    _items.Add(new HostTransfer(item.Id, item.Name, item.Direction, deviceName)
                    {
                        ChannelId = channelId,
                        ByteCount = item.ByteCount,
                        State = HostTransferState.Moving,
                    });
                    return null;
                }
                // Its turn came, or it resumed on a new channel: carry on from where it was. The
                // speed sample starts again, so the pause doesn't count as slow progress.
                _items[index] = _items[index] with
                {
                    ChannelId = channelId,
                    ByteCount = item.ByteCount,
                    State = HostTransferState.Moving,
                    FailureReason = null,
                    FinishedAt = null,
                    ResumesBefore = null,
                    SampledAt = null,
                };
                return null;
            }
            case FileTransferEvent.Progress progress:
            {
                var index = _items.FindIndex(t => t.Id == progress.Id);
                if (index < 0 || !_items[index].IsActive) return null;
                _items[index] = Record(_items[index], progress.Bytes, _time.GetUtcNow());
                return null;
            }
            case FileTransferEvent.Finished finished:
            {
                var index = _items.FindIndex(t => t.Id == finished.Id);
                if (index < 0 || !_items[index].IsActive) return null;
                _items[index] = Finish(_items[index], finished.Outcome, _time.GetUtcNow());
                return _items[index];
            }
            default:
                return null;
        }
    }

    /// <summary>The connection cut a file off: it waits for its device instead of failing.</summary>
    public void Pause(FileTransferPause pause)
    {
        var index = _items.FindIndex(t => t.Id == pause.TransferId);
        if (index < 0) return;
        _items[index] = _items[index] with
        {
            State = HostTransferState.Paused,
            ResumesBefore = pause.ResumesBefore,
            BytesPerSecond = null,
            SampledAt = null,
            FailureReason = null,
            FinishedAt = null,
        };
    }

    /// <summary>
    /// Cancelled here. A queued or paused file has nothing moving to report back, so it's settled
    /// now; a moving one is settled by the engine's <see cref="FileTransferOutcome.Cancelled"/>.
    /// </summary>
    public void MarkCancelled(Guid id)
    {
        var index = _items.FindIndex(t => t.Id == id);
        if (index < 0 || _items[index].State is not (HostTransferState.Waiting or HostTransferState.Paused)) return;
        _items[index] = Finish(_items[index], new FileTransferOutcome.Cancelled(false), _time.GetUtcNow());
    }

    /// <summary>
    /// Fails paused files whose device didn't come back in time and drops rows finished more than
    /// <see cref="KeepFinishedFor"/> ago. Returns the newly failed ones (they say so like any failure).
    /// </summary>
    public IReadOnlyList<HostTransfer> Tick()
    {
        var now = _time.GetUtcNow();
        var expired = new List<HostTransfer>();
        for (var i = 0; i < _items.Count; i++)
        {
            if (_items[i] is { State: HostTransferState.Paused, ResumesBefore: { } deadline } && deadline <= now)
            {
                _items[i] = Finish(_items[i], new FileTransferOutcome.Failed(LostConnection), now);
                expired.Add(_items[i]);
            }
        }
        _items.RemoveAll(t => t.FinishedAt is { } at && now - at >= KeepFinishedFor);
        return expired;
    }

    /// <summary>The tray's ring while files move, else null.</summary>
    public HostTransferActivity? Activity => HostTransferActivity.From(_items);

    /// <summary>What's moving, for the tooltip, the panel and Narrator ("Receiving Report.pdf, 45%"), else null.</summary>
    public string? Summary => HostTransferText.Summary(_items);

    /// <summary>Progress so far; updates the smoothed speed from the bytes since the last sample (the Mac's <c>record</c>).</summary>
    internal static HostTransfer Record(HostTransfer transfer, ulong bytes, DateTimeOffset now)
    {
        var updated = transfer with { BytesDone = bytes };
        if (updated.State == HostTransferState.Waiting) updated = updated with { State = HostTransferState.Moving };
        if (transfer.SampledAt is not { } sampledAt) return updated with { SampledAt = now, SampledBytes = bytes };
        var elapsed = (now - sampledAt).TotalSeconds;
        // Half a second at least, so one burst of chunks doesn't swing it.
        if (elapsed < 0.5 || bytes < transfer.SampledBytes) return updated;
        var rate = (bytes - transfer.SampledBytes) / elapsed;
        return updated with
        {
            BytesPerSecond = transfer.BytesPerSecond is { } previous ? previous * 0.6 + rate * 0.4 : rate,
            SampledAt = now,
            SampledBytes = bytes,
        };
    }

    private static HostTransfer Finish(HostTransfer transfer, FileTransferOutcome outcome, DateTimeOffset now)
    {
        var ended = transfer with { FinishedAt = now, ResumesBefore = null };
        return outcome switch
        {
            FileTransferOutcome.Sent => ended with { State = HostTransferState.Done, BytesDone = transfer.ByteCount },
            FileTransferOutcome.Received received => ended with
            {
                State = HostTransferState.Done,
                BytesDone = transfer.ByteCount,
                SavedPath = received.Path,
            },
            FileTransferOutcome.Failed failed => ended with { State = HostTransferState.Failed, FailureReason = failed.Reason },
            _ => ended with { State = HostTransferState.Cancelled },
        };
    }
}

/// <summary>
/// The files the tray's ring counts (the Mac's <c>StatusItemIcon.Activity</c>): overall progress in
/// <see cref="Steps"/> steps, so progress events don't redraw the icon every time, and which ways
/// they move.
/// </summary>
/// <param name="Step">0 to <see cref="Steps"/>.</param>
/// <param name="Receiving">Something is arriving.</param>
/// <param name="Sending">Something is going out.</param>
public readonly record struct HostTransferActivity(int Step, bool Receiving, bool Sending)
{
    /// <summary>Steps in a full ring.</summary>
    public const int Steps = 24;

    /// <summary>The ring's fill, 0–1.</summary>
    public double Fraction => (double)Step / Steps;

    /// <summary>The arrow points down when anything is arriving, up only when everything is going out (the Mac's rule).</summary>
    public bool PointsDown => Receiving || !Sending;

    /// <summary>The activity for these rows, or null when nothing is moving (paused files don't count).</summary>
    public static HostTransferActivity? From(IEnumerable<HostTransfer> transfers)
    {
        var moving = transfers.Where(t => t.IsMoving).ToList();
        if (moving.Count == 0) return null;
        var step = (int)Math.Floor(OverallFraction(moving) * Steps);
        return new HostTransferActivity(Math.Clamp(step, 0, Steps),
                                        moving.Exists(t => t.Direction == FileDirection.Receiving),
                                        moving.Exists(t => t.Direction == FileDirection.Sending));
    }

    internal static double OverallFraction(IReadOnlyCollection<HostTransfer> moving)
    {
        var total = moving.Aggregate(0UL, (sum, t) => sum + t.ByteCount);
        var done = moving.Aggregate(0UL, (sum, t) => sum + Math.Min(t.BytesDone, t.ByteCount));
        return total > 0 ? (double)done / total : 0;
    }
}

/// <summary>The words for transfers, in one place (the Mac's <c>HostTransferRow.detail</c> and <c>StatusItemIcon.accessibilityValue</c>).</summary>
public static class HostTransferText
{
    /// <summary>
    /// A row's status line: "Waiting · 12.0 MB · To Drew's iPad", "12.4 MB of 48.0 MB · 6.20 MB/s ·
    /// 5 sec left", "Paused at 45% · resumes when Drew's iPad reconnects", "Received from Drew's
    /// iPad · in Downloads", "Sent to Drew's iPad", the failure's reason, or "Cancelled".
    /// </summary>
    public static string Detail(HostTransfer transfer)
    {
        var total = Bytes(transfer.ByteCount);
        var toFrom = transfer.Direction == FileDirection.Sending ? $"To {transfer.DeviceName}" : $"From {transfer.DeviceName}";
        switch (transfer.State)
        {
            case HostTransferState.Paused:
                // Cut off mid-file: it picks up where it stopped when the device comes back.
                return Format($"Paused at {Math.Floor(transfer.Fraction * 100):0}% · resumes when {transfer.DeviceName} reconnects");
            case HostTransferState.Waiting:
                return $"Waiting · {total} · {toFrom}";
            case HostTransferState.Moving:
                var parts = new List<string> { $"{Bytes(transfer.BytesDone)} of {total}" };
                if (transfer.BytesPerSecond is > 0 and var rate) parts.Add($"{Bytes((ulong)rate)}/s");
                parts.Add(transfer.TimeLeft is { TotalSeconds: >= 1 } left ? $"{Duration(left)} left" : toFrom);
                return string.Join(" · ", parts);
            case HostTransferState.Done:
                if (transfer.Direction == FileDirection.Sending) return $"Sent to {transfer.DeviceName}";
                var folder = transfer.SavedPath is { } path ? Path.GetFileName(Path.GetDirectoryName(path)) : null;
                return folder is { Length: > 0 } ? $"Received from {transfer.DeviceName} · in {folder}" : $"Received from {transfer.DeviceName}";
            case HostTransferState.Failed:
                return transfer.FailureReason ?? "It didn't arrive.";
            default:
                return "Cancelled";
        }
    }

    /// <summary>
    /// What's moving, for the tooltip, the panel's status line and Narrator: "Receiving Report.pdf,
    /// 45%", "Sending 3 files, 10%", "Transferring 2 files, 50%"; null when nothing moves.
    /// </summary>
    public static string? Summary(IEnumerable<HostTransfer> transfers)
    {
        var moving = transfers.Where(t => t.IsMoving).ToList();
        if (moving.Count == 0) return null;
        var verb = moving.TrueForAll(t => t.Direction == FileDirection.Receiving) ? "Receiving"
                 : moving.TrueForAll(t => t.Direction == FileDirection.Sending) ? "Sending"
                 : "Transferring";
        var what = moving.Count == 1 ? moving[0].Name : Format($"{moving.Count} files");
        return Format($"{verb} {what}, {Math.Round(HostTransferActivity.OverallFraction(moving) * 100, MidpointRounding.AwayFromZero):0}%");
    }

    /// <summary>
    /// A size the way File Explorer shows one (1,024-based, three significant digits, cut rather
    /// than rounded): "512 bytes", "12.4 KB", "1.23 MB", "123 GB". The same file then reads the same
    /// in the menu as in Explorer's details pane.
    /// </summary>
    public static string Bytes(ulong count)
    {
        if (count < 1024) return Format($"{count} {(count == 1 ? "byte" : "bytes")}");
        string[] units = ["KB", "MB", "GB", "TB", "PB"];
        var value = count / 1024.0;
        var unit = 0;
        while (value >= 1000 && unit < units.Length - 1)
        {
            value /= 1024;
            unit++;
        }
        var decimals = value < 10 ? 2 : value < 100 ? 1 : 0;
        var scale = Math.Pow(10, decimals);
        var cut = Math.Floor(value * scale + 1e-9) / scale; // cut, as Explorer does, but not by a rounding error
        return cut.ToString("F" + decimals, CultureInfo.CurrentCulture) + " " + units[unit];
    }

    /// <summary>One unit, abbreviated, like the Mac's: "5 sec", "2 min", "1 hr".</summary>
    public static string Duration(TimeSpan left)
    {
        var seconds = Math.Ceiling(left.TotalSeconds);
        if (seconds < 60) return Format($"{seconds:0} sec");
        var minutes = Math.Round(seconds / 60, MidpointRounding.AwayFromZero);
        if (minutes < 60) return Format($"{minutes:0} min");
        return Format($"{Math.Round(seconds / 3600, MidpointRounding.AwayFromZero):0} hr");
    }

    private static string Format(FormattableString text) => text.ToString(CultureInfo.CurrentCulture);
}
