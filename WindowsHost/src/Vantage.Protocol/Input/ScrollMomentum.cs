using Vantage.Protocol.Messages;

namespace Vantage.Protocol.Input;

/// <summary>
/// The glide after a flick, for clients that end a scroll with the finger's velocity instead of
/// a momentum stream of their own: the iPad sends <c>ended</c> + momentum <c>began</c> + velocity
/// in one event, because <c>UIPanGestureRecognizer</c> has no deceleration. A port of the Mac
/// host's <c>ScrollMomentum</c>, with the same numbers, so a flick glides as far on a PC as on a
/// Mac instead of stopping dead.
/// </summary>
/// <remarks>
/// The velocity decays like <c>UIScrollView</c>'s normal deceleration (0.998 per millisecond), one
/// frame every 1/60 s, in whole points with the fraction carried, and ends with a zero-delta
/// <see cref="MomentumPhase.Ended"/> once the speed drops under <see cref="StopSpeed"/> or after
/// <see cref="MaximumDuration"/>. Deltas and velocity are in the client's units and sign; the
/// translator's wheel conversion applies Windows' scale and sign. Pure: <see cref="MomentumInputSink"/>
/// decides when frames are due.
/// </remarks>
public sealed class ScrollMomentum
{
    /// <summary>One frame of a glide, in points.</summary>
    public readonly record struct Frame(double DeltaX, double DeltaY, MomentumPhase Phase);

    /// <summary>Seconds between frames.</summary>
    public const double FrameInterval = 1.0 / 60;

    /// <summary>Velocity kept per millisecond (<c>UIScrollView.DecelerationRate.normal</c>).</summary>
    public const double DecelerationPerMillisecond = 0.998;

    /// <summary>Points per second under which a flick doesn't glide, like a trackpad let go without one.</summary>
    public const double MinimumSpeed = 60;

    /// <summary>Points per second under which the glide ends.</summary>
    public const double StopSpeed = 10;

    /// <summary>The longest glide, in seconds.</summary>
    public const double MaximumDuration = 3;

    private static readonly double s_decayPerFrame = Math.Pow(DecelerationPerMillisecond, FrameInterval * 1000);

    private double _velocityX;
    private double _velocityY;
    private double _remainderX;
    private double _remainderY;
    private double _elapsed;
    private bool _started;

    private ScrollMomentum(double velocityX, double velocityY)
    {
        _velocityX = velocityX;
        _velocityY = velocityY;
    }

    /// <summary>The glide has sent its end (or was cancelled before it began).</summary>
    public bool IsFinished { get; private set; }

    /// <summary>A glide for a flick at this velocity (points per second), or null when it's too slow to glide.</summary>
    public static ScrollMomentum? Start(double velocityX, double velocityY) =>
        Math.Sqrt(velocityX * velocityX + velocityY * velocityY) >= MinimumSpeed ? new ScrollMomentum(velocityX, velocityY) : null;

    /// <summary>
    /// The next frame to post: <see cref="MomentumPhase.Began"/> first, then
    /// <see cref="MomentumPhase.Changed"/> (never with nothing in it), then one
    /// <see cref="MomentumPhase.Ended"/>; null after that.
    /// </summary>
    public Frame? Next()
    {
        if (IsFinished) return null;
        while (true)
        {
            var speed = Math.Sqrt(_velocityX * _velocityX + _velocityY * _velocityY);
            if (_started && (speed < StopSpeed || _elapsed >= MaximumDuration)) return Finish();
            _elapsed += FrameInterval;
            var dx = Take(_velocityX * FrameInterval, ref _remainderX);
            var dy = Take(_velocityY * FrameInterval, ref _remainderY);
            _velocityX *= s_decayPerFrame;
            _velocityY *= s_decayPerFrame;
            if (!_started)
            {
                _started = true;
                return new Frame(dx, dy, MomentumPhase.Began);
            }
            if (dx != 0 || dy != 0) return new Frame(dx, dy, MomentumPhase.Changed);
        }
    }

    /// <summary>Stops the glide early (the next scroll, a click): the end frame if one is still owed.</summary>
    public Frame? Cancel()
    {
        if (!_started || IsFinished)
        {
            IsFinished = true;
            return null;
        }
        return Finish();
    }

    private Frame Finish()
    {
        IsFinished = true;
        return new Frame(0, 0, MomentumPhase.Ended);
    }

    /// <summary>Adds <paramref name="delta"/> to <paramref name="remainder"/> and takes out the whole points.</summary>
    private static double Take(double delta, ref double remainder)
    {
        remainder += delta;
        var whole = Math.Truncate(remainder);
        remainder -= whole;
        return whole;
    }
}
