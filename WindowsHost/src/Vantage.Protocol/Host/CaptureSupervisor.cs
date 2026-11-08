using Microsoft.Extensions.Logging;
using Vantage.Protocol.Messages;

namespace Vantage.Protocol.Host;

/// <summary>Something the session must do for the <see cref="CaptureSupervisor"/>, in the order given.</summary>
internal abstract record CaptureStep
{
    private CaptureStep()
    {
    }

    /// <summary>Wake the display and wait (up to ~3 s) until it is awake with displays listed; a <see cref="Start"/> follows.</summary>
    public sealed record WakeDisplayAndWait : CaptureStep;

    /// <summary>Start (or restart) capture on this target, then report <see cref="CaptureSupervisor.Started"/> or <see cref="CaptureSupervisor.StartFailed"/>.</summary>
    public sealed record Start(SelectDisplay Target) : CaptureStep;

    /// <summary>Stop the running capture (it never sent a frame), then report <see cref="CaptureSupervisor.CaptureStopped"/>.</summary>
    public sealed record Stop(string Reason) : CaptureStep;

    /// <summary>Send <c>hostStatus</c> when it changed, or regardless when <paramref name="Force"/>.</summary>
    public sealed record SendStatus(bool Force) : CaptureStep;

    /// <summary>Wake the display now (the Wake command).</summary>
    public sealed record WakeDisplay : CaptureStep;

    /// <summary>The display woke under a running capture: the client needs an IDR.</summary>
    public sealed record ForceKeyframe : CaptureStep;
}

/// <summary>
/// Keeps a picture coming for one screen session (the Mac's capture lifecycle in <c>HostSession</c>):
/// what the device wants streamed, one start at a time with a pending takeover, display sleep and
/// wake, the input-while-asleep rule, the retry backoff (0.5 s doubling to 5 s) with the 3 s
/// "screen unavailable" notice, the 5 s no-frame rule, and which targets a restart tries (the
/// display it was on, keeping its codec, then the device's original choice).
/// </summary>
/// <remarks>
/// Events come in, <see cref="CaptureStep"/>s go out; the supervisor does no I/O itself. The session
/// feeds it on its serial queue and runs the steps in order, reporting each start's and stop's
/// outcome back. It reads the clock from <paramref name="time"/> and learns the display's sleep
/// state from <see cref="DeviceAsked"/> and <see cref="StatusChanged"/>, so a change the session has
/// not relayed yet is not seen. While <see cref="WantsTicks"/> is true the session calls
/// <see cref="Tick"/> every <see cref="TickInterval"/>.
/// </remarks>
internal sealed class CaptureSupervisor(TimeProvider time, ILogger log)
{
    /// <summary>A capture that started but sent nothing for this long counts as failed.</summary>
    public static readonly TimeSpan NoFrameLimit = TimeSpan.FromSeconds(5);

    /// <summary>How long capture may be down before the client is told (<c>isScreenUnavailable</c>).</summary>
    public static readonly TimeSpan UnavailableNotice = TimeSpan.FromSeconds(3);

    /// <summary>The first retry comes this long after capture was lost; each later one waits twice as long, up to <see cref="MaxRetryDelay"/>.</summary>
    public static readonly TimeSpan FirstRetryDelay = TimeSpan.FromMilliseconds(500);

    /// <summary>The longest wait between retries.</summary>
    public static readonly TimeSpan MaxRetryDelay = TimeSpan.FromSeconds(5);

    /// <summary>How often the session ticks while <see cref="WantsTicks"/>.</summary>
    public static readonly TimeSpan TickInterval = TimeSpan.FromMilliseconds(250);

    /// <summary>Input while the display sleeps wakes it at most this often.</summary>
    public static readonly TimeSpan WakeForInputInterval = TimeSpan.FromSeconds(1);

    /// <summary>Input this soon after a Sleep Display command neither wakes the display nor goes through.</summary>
    public static readonly TimeSpan SleepCommandGrace = TimeSpan.FromSeconds(2);

    private static readonly CaptureStep[] s_nothing = [];

    private SelectDisplay? _wanted;
    private bool _starting;
    private SelectDisplay? _pending;
    private readonly Queue<SelectDisplay> _targets = new();
    private bool _capturing;
    private DisplayInfo? _display;
    private VideoCodec _codec;
    private DateTimeOffset _startedAt;
    private bool _framed;
    private DateTimeOffset? _lostAt;
    private string _lossReason = "";
    private TimeSpan _retryDelay;
    private DateTimeOffset _nextRetry;
    private bool _screenUnavailable;
    private bool _displayAsleep;
    private DateTimeOffset? _sleptAt;
    private DateTimeOffset _lastWakeForInput = DateTimeOffset.MinValue;

    /// <summary>The device's last <c>selectDisplay</c>, once it asked for one.</summary>
    public SelectDisplay? Wanted => _wanted;

    /// <summary>Capture has been down for <see cref="UnavailableNotice"/> while the display was awake (<c>hostStatus.isScreenUnavailable</c>).</summary>
    public bool ScreenUnavailable => _screenUnavailable;

    /// <summary>
    /// The clock matters right now: capture is lost (retries due, the notice pending) or up without a
    /// frame yet (the no-frame rule). The session ticks every <see cref="TickInterval"/> while this holds.
    /// </summary>
    public bool WantsTicks => _wanted is not null && !_displayAsleep && (_lostAt is not null || (_capturing && !_framed));

    /// <summary>
    /// The device asked for this selection. <paramref name="displayAsleep"/> is the display's state
    /// right now; the first request also sends the first <c>hostStatus</c>.
    /// </summary>
    public IReadOnlyList<CaptureStep> DeviceAsked(SelectDisplay select, bool displayAsleep)
    {
        var first = _wanted is null;
        _wanted = select;
        _displayAsleep = displayAsleep;
        var steps = new List<CaptureStep>();
        if (first) steps.Add(new CaptureStep.SendStatus(Force: true));
        if (displayAsleep) steps.Add(new CaptureStep.WakeDisplayAndWait());
        steps.AddRange(BeginStart([select], reason: null));
        return steps;
    }

    /// <summary>A <see cref="CaptureStep.Start"/> succeeded: capture runs on <paramref name="display"/> with <paramref name="codec"/>.</summary>
    public IReadOnlyList<CaptureStep> Started(DisplayInfo display, VideoCodec codec)
    {
        _targets.Clear();
        _starting = false;
        _capturing = true;
        _display = display;
        _codec = codec;
        _startedAt = time.GetUtcNow();
        _framed = false;
        return TakePending();
    }

    /// <summary>A <see cref="CaptureStep.Start"/> threw: nothing is captured now.</summary>
    public IReadOnlyList<CaptureStep> StartFailed(string reason)
    {
        _capturing = false;
        _lossReason = reason;
        log.LogError("capture didn't start: {Reason}{Asleep}", reason, _displayAsleep ? " (display asleep)" : "");
        if (_pending is not null) return TakePending();
        if (_targets.TryDequeue(out var next)) return [new CaptureStep.Start(next)];
        _starting = false;
        return Unavailable();
    }

    /// <summary>The running capture stopped (on its own, with its encoder, or on a <see cref="CaptureStep.Stop"/>) and the session has torn it down.</summary>
    public IReadOnlyList<CaptureStep> CaptureStopped(string reason)
    {
        _capturing = false;
        _lossReason = reason;
        log.LogInformation("capture stopped ({Reason}); display {State}", reason, _displayAsleep ? "asleep" : "awake");
        return Unavailable();
    }

    /// <summary>A captured frame arrived.</summary>
    public IReadOnlyList<CaptureStep> FrameArrived()
    {
        _framed = true;
        if (_lostAt is not { } lostAt) return s_nothing;
        _lostAt = null;
        log.LogInformation("capture back after {Ms} ms", (int)(time.GetUtcNow() - lostAt).TotalMilliseconds);
        if (!_screenUnavailable) return s_nothing;
        _screenUnavailable = false;
        return [new CaptureStep.SendStatus(Force: false)];
    }

    /// <summary>
    /// The host's conditions changed (lock, secure desktop, display power). A display that went to
    /// sleep explains the missing picture by itself; one that woke needs a new IDR or a new capture.
    /// </summary>
    public IReadOnlyList<CaptureStep> StatusChanged(bool displayAsleep)
    {
        var steps = new List<CaptureStep> { new CaptureStep.SendStatus(Force: false) };
        if (displayAsleep == _displayAsleep)
        {
            // Capture waiting on something else (a lock screen): try again now that things changed.
            if (!displayAsleep && !_capturing && _wanted is not null && !_starting) steps.AddRange(BeginStart(RestartTargets(), "host state changed"));
            return steps;
        }
        _displayAsleep = displayAsleep;
        if (displayAsleep)
        {
            log.LogInformation("display went to sleep; the session stays up");
            _lostAt = null; // the asleep state explains the missing picture
            _screenUnavailable = false;
            return steps;
        }
        log.LogInformation("display woke");
        _sleptAt = null;
        if (_capturing) steps.Add(new CaptureStep.ForceKeyframe());
        else steps.AddRange(BeginStart(RestartTargets(), "display woke"));
        return steps;
    }

    /// <summary>The client sent Sleep Display (the session turns the display off itself).</summary>
    public void SleepAsked() => _sleptAt = time.GetUtcNow();

    /// <summary>The client sent Wake Display, which doubles as Retry when capture is down.</summary>
    public IReadOnlyList<CaptureStep> WakeAsked()
    {
        _sleptAt = null;
        var steps = new List<CaptureStep> { new CaptureStep.WakeDisplay() };
        if (_lostAt is null || _capturing) return steps;
        _retryDelay = FirstRetryDelay;
        _nextRetry = time.GetUtcNow() + _retryDelay;
        log.LogInformation("capture retry asked for by the client");
        if (!_starting) steps.AddRange(BeginStart(RestartTargets(), "client asked to retry"));
        return steps;
    }

    /// <summary>The session put the display mode back (or something else changed under capture): start again.</summary>
    public IReadOnlyList<CaptureStep> RestartAsked(string reason) =>
        _wanted is null || _starting ? s_nothing : BeginStart(RestartTargets(), reason);

    /// <summary>
    /// Whether input may reach the screen. While the display is asleep only releases go through;
    /// anything else wakes the display (at most once a second, <paramref name="wakeDisplay"/>) and
    /// is dropped, except in the 2 s after a Sleep Display command.
    /// </summary>
    public bool AdmitsInput(bool isRelease, out bool wakeDisplay)
    {
        wakeDisplay = false;
        if (!_displayAsleep || isRelease) return true;
        var now = time.GetUtcNow();
        if (_sleptAt is { } slept && now - slept < SleepCommandGrace) return false;
        if (now - _lastWakeForInput >= WakeForInputInterval)
        {
            _lastWakeForInput = now;
            wakeDisplay = true;
        }
        return false;
    }

    /// <summary>The clock moved on (<see cref="TickInterval"/>): the no-frame rule, the notice, and retries.</summary>
    public IReadOnlyList<CaptureStep> Tick()
    {
        if (_wanted is null || _displayAsleep) return s_nothing;
        var now = time.GetUtcNow();
        if (_capturing && !_framed && now - _startedAt > NoFrameLimit)
        {
            // The session stops it and reports CaptureStopped, which starts the retries.
            _lossReason = "capture started but sent no frames";
            return [new CaptureStep.Stop(_lossReason)];
        }
        if (_lostAt is not { } lostAt) return s_nothing;
        var steps = new List<CaptureStep>();
        var seconds = (int)(now - lostAt).TotalSeconds;
        if (now - lostAt >= UnavailableNotice && !_screenUnavailable)
        {
            _screenUnavailable = true;
            log.LogError("capture unavailable for {Seconds} s: {Reason}; telling the client", seconds, _lossReason);
            steps.Add(new CaptureStep.SendStatus(Force: false));
        }
        if (_capturing || _starting || now < _nextRetry) return steps;
        log.LogError("capture unavailable for {Seconds} s: {Reason}; trying again", seconds, _lossReason);
        _retryDelay = TimeSpan.FromTicks(Math.Min(_retryDelay.Ticks * 2, MaxRetryDelay.Ticks));
        _nextRetry = now + _retryDelay;
        steps.AddRange(BeginStart(RestartTargets(), $"capture unavailable for {seconds} s"));
        return steps;
    }

    /// <summary>
    /// Capture is down while the device waits: tell the client (the status says why when the display
    /// sleeps) and, with the display awake, begin the retry schedule.
    /// </summary>
    private IReadOnlyList<CaptureStep> Unavailable()
    {
        if (_wanted is null || _capturing) return s_nothing;
        if (_displayAsleep || _lostAt is not null) return [new CaptureStep.SendStatus(Force: false)];
        _lostAt = time.GetUtcNow();
        _retryDelay = FirstRetryDelay;
        _nextRetry = _lostAt.Value + _retryDelay;
        return [new CaptureStep.SendStatus(Force: false)];
    }

    /// <summary>One start at a time: a request while one runs waits as the pending takeover.</summary>
    private IReadOnlyList<CaptureStep> BeginStart(IReadOnlyList<SelectDisplay> targets, string? reason)
    {
        if (_starting)
        {
            _pending = targets[0];
            return s_nothing;
        }
        if (reason is not null) log.LogInformation("restarting capture: {Reason}", reason);
        _starting = true;
        _targets.Clear();
        foreach (var target in targets.Skip(1)) _targets.Enqueue(target);
        return [new CaptureStep.Start(targets[0])];
    }

    private IReadOnlyList<CaptureStep> TakePending()
    {
        if (_pending is not { } pending) return s_nothing;
        _pending = null;
        _starting = false;
        return BeginStart([pending], reason: null);
    }

    /// <summary>The display capture was on, keeping its codec (as the Mac does), then the device's original choice.</summary>
    private IReadOnlyList<SelectDisplay> RestartTargets()
    {
        var wanted = _wanted!;
        if (_display is not { } display) return [wanted];
        return
        [
            new SelectDisplay { Selection = new DisplaySelection.Display(display.Id), TargetFPS = wanted.TargetFPS, Quality = wanted.Quality, PreferredCodec = _codec },
            wanted,
        ];
    }
}
