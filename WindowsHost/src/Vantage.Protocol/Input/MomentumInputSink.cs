using Vantage.Protocol.Host;
using Vantage.Protocol.Messages;

namespace Vantage.Protocol.Input;

/// <summary>
/// Wraps a session's <see cref="IInputSink"/> and plays the glide after an iPad flick (an
/// <c>ended</c> continuous scroll carrying momentum <c>began</c> and a velocity) as a stream of
/// momentum scroll events, the way the Mac host does. The inner sink sees them as ordinary
/// continuous scrolls (phase none, momentum began/changed/ended), so on Windows they go through
/// <see cref="WindowsInputTranslator"/>'s wheel conversion, remainder and all, and the synthetic
/// host's input log shows them.
/// </summary>
/// <remarks>
/// <para>
/// Any scroll, a button press, <see cref="ReleaseAll"/> and <see cref="Dispose"/> end a glide at
/// once (with its end frame), as touching a trackpad does. One timer per sink, on the session's
/// <see cref="TimeProvider"/>, ticks every 1/60 s only while a glide runs; each tick is posted onto
/// the session's queue (<c>post</c>), so the inner sink is still called one event at a time and
/// never after <see cref="Dispose"/>.
/// </para>
/// <para>
/// Windows' default timer resolution is about 15.6 ms, so ticks arrive at 15.6 or 31.2 ms rather
/// than every 16.7 ms. Each tick sends as many frames as are due by the clock (up to
/// <see cref="MaximumFramesPerTick"/>), so the glide covers its distance in the time it would on a
/// Mac instead of slowing down with a coarse timer.
/// </para>
/// </remarks>
public sealed class MomentumInputSink : IInputSink
{
    /// <summary>Catch-up limit after a late tick: after a stall the glide runs late rather than lurching.</summary>
    public const int MaximumFramesPerTick = 4;

    private static readonly TimeSpan s_frameInterval = TimeSpan.FromSeconds(ScrollMomentum.FrameInterval);

    private readonly IInputSink _inner;
    private readonly TimeProvider _time;
    private readonly Func<Action, bool> _post;
    private ITimer? _timer;
    private ScrollMomentum? _glide;
    private ScrollEvent? _flick;
    private long _glideStartedAt;
    private int _framesSent;
    private int _generation;
    private int _tickQueued;
    private bool _disposed;

    /// <summary>
    /// Wraps <paramref name="inner"/>. <paramref name="post"/> queues work where the session calls
    /// the sink (its serial queue) and returns false once that queue is closed.
    /// </summary>
    public MomentumInputSink(IInputSink inner, TimeProvider time, Func<Action, bool> post)
    {
        _inner = inner;
        _time = time;
        _post = post;
    }

    /// <summary>A glide is running.</summary>
    public bool IsGliding => _glide is not null;

    /// <inheritdoc />
    public void SetDisplay(DisplayInfo display) => _inner.SetDisplay(display);

    /// <inheritdoc />
    public void Pointer(PointerEvent pointerEvent)
    {
        if (pointerEvent.Action == PointerAction.Down) StopGlide(); // a click stops a glide
        _inner.Pointer(pointerEvent);
    }

    /// <inheritdoc />
    public void Scroll(ScrollEvent scrollEvent)
    {
        StopGlide();
        if (scrollEvent is { IsContinuous: true, Phase: ScrollPhase.Ended, Momentum: MomentumPhase.Began })
        {
            // End the gesture, then glide from the finger's velocity. The momentum phase stays off
            // the ended event itself, as on the Mac: one phase at a time.
            _inner.Scroll(scrollEvent with { Momentum = MomentumPhase.None });
            if (!_disposed && ScrollMomentum.Start(scrollEvent.VelocityX, scrollEvent.VelocityY) is { } glide) StartGlide(glide, scrollEvent);
            return;
        }
        _inner.Scroll(scrollEvent);
    }

    /// <inheritdoc />
    public void Key(KeyEvent keyEvent) => _inner.Key(keyEvent);

    /// <inheritdoc />
    public void Text(string text) => _inner.Text(text);

    /// <inheritdoc />
    public void ReleaseAll()
    {
        StopGlide();
        _inner.ReleaseAll();
    }

    /// <summary>Ends any glide, stops the timer for good, and disposes the inner sink.</summary>
    public void Dispose()
    {
        if (_disposed) return;
        try
        {
            StopGlide();
        }
        finally
        {
            _disposed = true;
            _timer?.Dispose();
            _timer = null;
            _inner.Dispose();
        }
    }

    private void StartGlide(ScrollMomentum glide, ScrollEvent flick)
    {
        _glide = glide;
        _flick = flick;
        _glideStartedAt = _time.GetTimestamp();
        _framesSent = 0;
        Interlocked.Increment(ref _generation);
        _timer ??= _time.CreateTimer(_ => OnTick(), null, Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);
        _timer.Change(s_frameInterval, s_frameInterval);
    }

    /// <summary>On the timer's thread: queue one step unless one is already waiting.</summary>
    private void OnTick()
    {
        if (Interlocked.Exchange(ref _tickQueued, 1) == 1) return;
        var generation = Volatile.Read(ref _generation);
        if (!_post(() => Step(generation))) Volatile.Write(ref _tickQueued, 0);
    }

    /// <summary>On the session's queue: send the frames due by now.</summary>
    private void Step(int generation)
    {
        Volatile.Write(ref _tickQueued, 0);
        if (_disposed || generation != _generation || _glide is not { } glide) return;
        var due = (int)Math.Round(_time.GetElapsedTime(_glideStartedAt).TotalSeconds / ScrollMomentum.FrameInterval);
        var count = Math.Min(due - _framesSent, MaximumFramesPerTick);
        for (var i = 0; i < count; i++)
        {
            if (glide.Next() is not { } frame) break;
            Send(frame);
        }
        // A backlog past the catch-up limit is forgiven, not owed: the glide runs late instead.
        _framesSent = Math.Max(_framesSent, due);
        if (glide.IsFinished) EndGlide();
    }

    /// <summary>Ends a glide still running, with its end frame if one is owed, and stops the timer.</summary>
    private void StopGlide()
    {
        if (_glide is not { } glide) return;
        if (glide.Cancel() is { } frame) Send(frame);
        EndGlide();
    }

    private void EndGlide()
    {
        _glide = null;
        _flick = null;
        Interlocked.Increment(ref _generation);
        _timer?.Change(Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);
    }

    private void Send(ScrollMomentum.Frame frame)
    {
        var flick = _flick!;
        _inner.Scroll(new ScrollEvent
        {
            Phase = ScrollPhase.None,
            Momentum = frame.Phase,
            IsContinuous = true,
            DeltaX = (float)frame.DeltaX,
            DeltaY = (float)frame.DeltaY,
            X = flick.X,
            Y = flick.Y,
            Modifiers = flick.Modifiers,
        });
    }
}
