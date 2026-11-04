using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Time.Testing;
using Vantage.Protocol.Host;
using Vantage.Protocol.Input;
using Vantage.Protocol.Messages;

namespace Vantage.Protocol.Tests;

/// <summary>The glide after an iPad flick: the Mac host's numbers, then the PC's wheel events.</summary>
public class ScrollMomentumTests
{
    private static List<ScrollMomentum.Frame> Glide(double vx, double vy)
    {
        var frames = new List<ScrollMomentum.Frame>();
        if (ScrollMomentum.Start(vx, vy) is not { } glide) return frames;
        while (glide.Next() is { } frame) frames.Add(frame);
        return frames;
    }

    [Fact]
    public void FlickSlowerThan60PointsASecondDoesNotGlide()
    {
        Assert.Null(ScrollMomentum.Start(20, 30));
        Assert.Null(ScrollMomentum.Start(0, 59.9));
        Assert.Null(ScrollMomentum.Start(0, 0));
        Assert.NotNull(ScrollMomentum.Start(36, 48)); // exactly 60 pt/s

        var rig = new Rig();
        rig.Sink.Scroll(Flick(0, 50));
        rig.Run(1);
        Assert.False(rig.Sink.IsGliding);
        Assert.Equal(["scroll ended none 0,4"], rig.Inner.Events);
    }

    /// <summary>Began, changes in whole points decaying at 0.998 per ms, then one empty end once under 10 pt/s.</summary>
    [Fact]
    public void FlickDecaysAtUIScrollViewsRateAndStopsUnder10PointsASecond()
    {
        var frames = Glide(0, 1000);
        Assert.Equal(MomentumPhase.Began, frames[0].Phase);
        Assert.Equal(new ScrollMomentum.Frame(0, 0, MomentumPhase.Ended), frames[^1]);
        Assert.All(frames.Skip(1).SkipLast(1), f => Assert.True(f.Phase == MomentumPhase.Changed && f.DeltaY != 0));
        Assert.All(frames, f => Assert.True(f.DeltaX == 0 && f.DeltaY >= 0 && f.DeltaY == Math.Round(f.DeltaY)));

        // The same decay worked out by hand: frames until the speed falls under 10 pt/s, and the
        // distance they cover (whole points, so within one of the exact sum).
        var decay = Math.Pow(0.998, 1000.0 / 60);
        double speed = 1000, exact = 0;
        var moving = 0;
        do
        {
            exact += speed / 60;
            speed *= decay;
            moving++;
        } while (speed >= 10);
        var distance = frames.Sum(f => f.DeltaY);
        Assert.InRange(distance, Math.Floor(exact) - 1, exact);
        Assert.InRange(distance, 450, 510); // UIScrollView carries 1000 pt/s about 500 pt
        // Frames with nothing in them (the slow tail, under a point a frame) are skipped.
        Assert.InRange(frames.Count(f => f.Phase != MomentumPhase.Ended), moving / 2, moving);
        Assert.True(moving / 60.0 < ScrollMomentum.MaximumDuration);
        Assert.True(frames[0].DeltaY > frames[frames.Count / 2].DeltaY);
    }

    [Fact]
    public void GlideStopsAfterThreeSeconds()
    {
        // 100 000 pt/s would take about 4.6 s to fall under 10 pt/s.
        var frames = Glide(0, 100_000);
        Assert.Equal(MomentumPhase.Ended, frames[^1].Phase);
        Assert.InRange(frames.Count - 1, 179, 181);
        Assert.True(frames[^2].DeltaY >= 3, "still moving when cut off"); // about 250 pt/s left

        var rig = new Rig();
        rig.Sink.Scroll(Flick(0, 100_000));
        rig.Run(3.1);
        Assert.False(rig.Sink.IsGliding);
        Assert.EndsWith("none ended 0,0", rig.Inner.Events[^1]);
        var count = rig.Inner.Events.Count;
        rig.Run(5);
        Assert.Equal(count, rig.Inner.Events.Count);
    }

    /// <summary>Frames arrive one per 1/60 s on the session's queue, after the flick's own ended event.</summary>
    [Fact]
    public void SinkPlaysTheGlideAtSixtyFramesASecond()
    {
        var rig = new Rig();
        rig.Sink.Scroll(Flick(0, 1000));
        Assert.Equal(["scroll ended none 0,4"], rig.Inner.Events);
        Assert.True(rig.Sink.IsGliding);
        rig.Run(1.0 / 60);
        Assert.Equal("scroll none began 0,16", rig.Inner.Events[^1]);
        rig.Run(9.0 / 60);
        Assert.Equal(11, rig.Inner.Events.Count);
        Assert.All(rig.Inner.Events.Skip(2), e => Assert.StartsWith("scroll none changed 0,", e));

        rig.Run(4);
        var expected = Glide(0, 1000).Select(f => $"scroll none {f.Phase.ToString().ToLowerInvariant()} 0,{f.DeltaY}");
        Assert.Equal(expected, rig.Inner.Events.Skip(1));
        Assert.False(rig.Sink.IsGliding);
    }

    /// <summary>A tick that comes late (Windows' 15.6 ms timer, a busy queue) sends what's due, up to four frames.</summary>
    [Fact]
    public void LateTicksCatchUpByTheClock()
    {
        var queued = new List<Action>();
        var rig = new Rig(work =>
        {
            queued.Add(work);
            return true;
        });
        rig.Sink.Scroll(Flick(0, 1000));
        rig.Time.Advance(TimeSpan.FromSeconds(3.0 / 60)); // one late tick, three frames due
        Assert.Single(queued);
        queued[0]();
        Assert.Equal(4, rig.Inner.Events.Count); // the flick's end, then three frames
        queued.Clear();
        rig.Time.Advance(TimeSpan.FromSeconds(10.0 / 60));
        Assert.Single(queued);
        queued[0]();
        Assert.Equal(8, rig.Inner.Events.Count); // at most four at once; the rest of the backlog is forgiven
    }

    [Fact]
    public void ClickNewScrollAndReleaseAllEndTheGlideAtOnce()
    {
        var rig = new Rig();
        rig.Sink.Scroll(Flick(0, 2000));
        rig.Run(0.1);
        rig.Inner.Events.Clear();
        rig.Sink.Pointer(new PointerEvent { Action = PointerAction.Move, X = 5, Y = 5 });
        Assert.True(rig.Sink.IsGliding); // moving the pointer doesn't stop it
        rig.Sink.Pointer(new PointerEvent { Action = PointerAction.Down, Button = PointerButton.Left, X = 5, Y = 5 });
        Assert.Equal(["pointer move", "scroll none ended 0,0", "pointer down"], rig.Inner.Events);
        rig.Run(1);
        Assert.Equal(3, rig.Inner.Events.Count);

        // A finger touching down again (began) ends it before its own event.
        rig.Sink.Scroll(Flick(0, 2000));
        rig.Run(0.05);
        rig.Inner.Events.Clear();
        rig.Sink.Scroll(new ScrollEvent { Phase = ScrollPhase.Began, IsContinuous = true, DeltaX = 0, DeltaY = 1, X = 0, Y = 0 });
        Assert.Equal(["scroll none ended 0,0", "scroll began none 0,1"], rig.Inner.Events);
        rig.Run(1);
        Assert.Equal(2, rig.Inner.Events.Count);

        rig.Sink.Scroll(Flick(0, 2000));
        rig.Run(0.05);
        rig.Inner.Events.Clear();
        rig.Sink.ReleaseAll();
        Assert.Equal(["scroll none ended 0,0", "releaseAll"], rig.Inner.Events);
        rig.Run(1);
        Assert.Equal(2, rig.Inner.Events.Count);
    }

    /// <summary>The session ending stops the glide and its timer for good, even for a tick already queued.</summary>
    [Fact]
    public void GlideNeverOutlivesTheSession()
    {
        var queued = new List<Action>();
        var rig = new Rig(work =>
        {
            queued.Add(work);
            return true;
        });
        rig.Sink.Scroll(Flick(0, 2000));
        rig.Run(1.0 / 60);
        Assert.Single(queued);
        rig.Sink.Dispose();
        Assert.True(rig.Inner.IsDisposed);
        foreach (var work in queued) work();
        rig.Run(1);
        Assert.Single(queued); // the timer is gone
        Assert.Equal(["scroll ended none 0,4"], rig.Inner.Events); // never began, so no end is owed
    }

    /// <summary>
    /// The glide goes through the translator's continuous-scroll conversion (2.5 wheel units a point)
    /// with the remainder carried, so a slow tail of single points still comes out as 2 then 3 units.
    /// </summary>
    [Fact]
    public void WheelUnitsAccumulateThroughTheTail()
    {
        var sent = new List<InputAction>();
        var rig = new Rig(inner: new WindowsInputTranslator(new Recorder(sent), NullLogger.Instance));
        rig.Sink.Scroll(Flick(0, 400) with { DeltaY = 0.2f }); // 0.5 units, carried into the glide
        rig.Run(4);
        Assert.All(sent, a => Assert.Equal(InputActionType.Wheel, a.Type));
        Assert.All(sent, a => Assert.True(a.WheelDelta is > 0 and < WindowsInputTranslator.WheelDelta, $"{a.WheelDelta}"));
        var points = Glide(0, 400).Sum(f => f.DeltaY) + 0.2;
        Assert.Equal((int)Math.Truncate(points * 120 / 48), sent.Sum(a => a.WheelDelta));
        var tail = sent.TakeLast(6).Select(a => a.WheelDelta).ToList();
        Assert.Contains(2, tail);
        Assert.Contains(3, tail);
    }

    [Fact]
    public void GlidesHorizontallyAndVerticallyInTheFlicksDirection()
    {
        var frames = Glide(-600, 300);
        Assert.All(frames, f => Assert.True(f.DeltaX <= 0 && f.DeltaY >= 0));
        Assert.InRange(frames.Sum(f => f.DeltaX) / frames.Sum(f => f.DeltaY), -2.1, -1.9);

        var sent = new List<InputAction>();
        var rig = new Rig(inner: new WindowsInputTranslator(new Recorder(sent), NullLogger.Instance));
        rig.Sink.Scroll(Flick(-600, 300) with { DeltaY = 0 });
        rig.Run(4);
        var vertical = sent.Where(a => a.Type == InputActionType.Wheel).Sum(a => a.WheelDelta);
        var horizontal = sent.Where(a => a.Type == InputActionType.HorizontalWheel).Sum(a => a.WheelDelta);
        Assert.True(vertical > 0); // positive deltaY = positive WHEEL
        Assert.True(horizontal > 0); // negative deltaX = positive HWHEEL
        Assert.InRange(horizontal / (double)vertical, 1.9, 2.1);

        // Upward and leftward too.
        sent.Clear();
        rig.Sink.Scroll(Flick(600, -300) with { DeltaY = 0 });
        rig.Run(4);
        Assert.NotEmpty(sent);
        Assert.All(sent, a => Assert.True(a.WheelDelta < 0));
    }

    /// <summary>The iPad's flick: ended, momentum began, the finger's velocity, and its last delta.</summary>
    private static ScrollEvent Flick(float vx, float vy) => new()
    {
        Phase = ScrollPhase.Ended, Momentum = MomentumPhase.Began, IsContinuous = true,
        DeltaX = 0, DeltaY = 4, X = 100, Y = 100, VelocityX = vx, VelocityY = vy,
    };

    private sealed class Rig
    {
        public Rig(Func<Action, bool>? post = null, IInputSink? inner = null)
        {
            Sink = new MomentumInputSink(inner ?? Inner, Time, post ?? (work =>
            {
                work();
                return true;
            }));
        }

        public FakeTimeProvider Time { get; } = new();

        /// <summary>
        /// Advances one frame at a time, as a real timer ticks (<see cref="FakeTimeProvider.Advance"/>
        /// fires a periodic timer once per call, at the end time).
        /// </summary>
        public void Run(double seconds)
        {
            for (var i = 0; i < (int)Math.Round(seconds * 60); i++) Time.Advance(TimeSpan.FromSeconds(1.0 / 60));
        }
        public RecordingSink Inner { get; } = new();
        public MomentumInputSink Sink { get; }
    }

    private sealed class RecordingSink : IInputSink
    {
        public List<string> Events { get; } = [];
        public bool IsDisposed { get; private set; }
        public void SetDisplay(DisplayInfo display) => Events.Add("display");
        public void Pointer(PointerEvent e) => Events.Add($"pointer {e.Action.ToString().ToLowerInvariant()}");
        public void Scroll(ScrollEvent e) =>
            Events.Add($"scroll {e.Phase.ToString().ToLowerInvariant()} {e.Momentum.ToString().ToLowerInvariant()} {e.DeltaX},{e.DeltaY}");
        public void Key(KeyEvent e) => Events.Add("key");
        public void Text(string text) => Events.Add("text");
        public void ReleaseAll() => Events.Add("releaseAll");
        public void Dispose() => IsDisposed = true;
    }

    private sealed class Recorder(List<InputAction> sent) : IInputInjector
    {
        public void Send(ReadOnlySpan<InputAction> actions)
        {
            foreach (var action in actions) sent.Add(action);
        }
    }
}
