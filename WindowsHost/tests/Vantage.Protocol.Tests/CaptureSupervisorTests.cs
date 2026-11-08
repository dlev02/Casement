using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Time.Testing;
using Vantage.Protocol.Host;
using Vantage.Protocol.Messages;
using Vantage.SyntheticHost;

namespace Vantage.Protocol.Tests;

/// <summary>The capture lifecycle on a fake clock: the listener tests prove the wiring, these the rules.</summary>
public class CaptureSupervisorTests
{
    private static readonly SelectDisplay s_select = new() { Selection = new DisplaySelection.Display(1), TargetFPS = 30, Quality = QualityPreset.Auto };

    private static (CaptureSupervisor Supervisor, FakeTimeProvider Clock) Running()
    {
        var clock = new FakeTimeProvider();
        var supervisor = new CaptureSupervisor(clock, NullLogger.Instance);
        Assert.Equal([new CaptureStep.SendStatus(Force: true), new CaptureStep.Start(s_select)], supervisor.DeviceAsked(s_select, displayAsleep: false));
        Assert.Empty(supervisor.Started(FakeDisplay.Info, VideoCodec.H264));
        return (supervisor, clock);
    }

    private static SelectDisplay SameDisplayKeepingItsCodec() =>
        new() { Selection = new DisplaySelection.Display(FakeDisplay.Info.Id), TargetFPS = 30, Quality = QualityPreset.Auto, PreferredCodec = VideoCodec.H264 };

    [Fact]
    public void ASleepingDisplayExplainsTheMissingPictureAndWakingStartsAgain()
    {
        var (supervisor, clock) = Running();
        Assert.Empty(supervisor.FrameArrived());

        Assert.Equal([new CaptureStep.SendStatus(Force: false)], supervisor.StatusChanged(displayAsleep: true));
        Assert.False(supervisor.WantsTicks);
        // Input wakes the display once a second and is dropped; releases still go through.
        Assert.False(supervisor.AdmitsInput(isRelease: false, out var wake));
        Assert.True(wake);
        Assert.False(supervisor.AdmitsInput(isRelease: false, out wake));
        Assert.False(wake);
        Assert.True(supervisor.AdmitsInput(isRelease: true, out _));

        // Capture going down while the display sleeps schedules no retries: the status says why.
        Assert.Equal([new CaptureStep.SendStatus(Force: false)], supervisor.CaptureStopped("display off"));
        Assert.False(supervisor.WantsTicks);
        clock.Advance(TimeSpan.FromSeconds(10));
        Assert.Empty(supervisor.Tick());
        Assert.False(supervisor.ScreenUnavailable);

        // Waking tries the display it was on first, keeping the codec it streamed, then the device's own choice.
        Assert.Equal([new CaptureStep.SendStatus(Force: false), new CaptureStep.Start(SameDisplayKeepingItsCodec())], supervisor.StatusChanged(displayAsleep: false));
        Assert.Equal([new CaptureStep.Start(s_select)], supervisor.StartFailed("not yet"));
        Assert.Empty(supervisor.Started(FakeDisplay.Info, VideoCodec.H264));
        Assert.True(supervisor.AdmitsInput(isRelease: false, out _));
    }

    [Fact]
    public void AFailingCaptureIsRetriedWithBackoffAndExplainedAfterThreeSeconds()
    {
        var clock = new FakeTimeProvider();
        var supervisor = new CaptureSupervisor(clock, NullLogger.Instance);
        supervisor.DeviceAsked(s_select, displayAsleep: false);
        Assert.Equal([new CaptureStep.SendStatus(Force: false)], supervisor.StartFailed("no displays"));
        Assert.True(supervisor.WantsTicks);

        var started = clock.GetUtcNow();
        var retries = new List<double>();
        double? toldAt = null;
        while (clock.GetUtcNow() - started < TimeSpan.FromSeconds(20))
        {
            clock.Advance(CaptureSupervisor.TickInterval);
            var seconds = (clock.GetUtcNow() - started).TotalSeconds;
            foreach (var step in supervisor.Tick())
            {
                switch (step)
                {
                    case CaptureStep.SendStatus when supervisor.ScreenUnavailable:
                        toldAt ??= seconds;
                        break;
                    case CaptureStep.Start start:
                        Assert.Equal(s_select, start.Target); // no display yet, so only the device's choice
                        retries.Add(seconds);
                        Assert.Equal([new CaptureStep.SendStatus(Force: false)], supervisor.StartFailed("still no displays"));
                        break;
                }
            }
        }
        Assert.Equal([0.5, 1.5, 3.5, 7.5, 12.5, 17.5], retries); // 0.5 s doubling to 5 s
        Assert.Equal(3.0, toldAt);

        // The picture returns: the note is cleared and the clock is no longer needed.
        clock.Advance(TimeSpan.FromSeconds(2.5)); // the next retry, 5 s after the last
        Assert.Equal([new CaptureStep.Start(s_select)], supervisor.Tick());
        Assert.Empty(supervisor.Started(FakeDisplay.Info, VideoCodec.H264));
        Assert.Equal([new CaptureStep.SendStatus(Force: false)], supervisor.FrameArrived());
        Assert.False(supervisor.ScreenUnavailable);
        Assert.False(supervisor.WantsTicks);
    }

    [Fact]
    public void ASlowFailureDoesNotUseUpTheRetryWait()
    {
        var (supervisor, clock) = Running();
        Assert.Empty(supervisor.FrameArrived());
        Assert.Equal([new CaptureStep.SendStatus(Force: false)], supervisor.CaptureStopped("display gone"));
        var lost = clock.GetUtcNow();
        clock.Advance(CaptureSupervisor.FirstRetryDelay);
        Assert.Equal([new CaptureStep.Start(SameDisplayKeepingItsCodec())], supervisor.Tick());

        // Each target takes a second to fail, so the attempt is over at 2.5 s and the 1 s wait runs from there to 3.5 s.
        clock.Advance(TimeSpan.FromSeconds(1));
        Assert.Equal([new CaptureStep.Start(s_select)], supervisor.StartFailed("still coming up"));
        clock.Advance(TimeSpan.FromSeconds(1));
        Assert.Equal([new CaptureStep.SendStatus(Force: false)], supervisor.StartFailed("still coming up"));
        var retries = new List<double>();
        while (clock.GetUtcNow() - lost < TimeSpan.FromSeconds(4))
        {
            clock.Advance(CaptureSupervisor.TickInterval);
            if (supervisor.Tick().Any(step => step is CaptureStep.Start)) retries.Add((clock.GetUtcNow() - lost).TotalSeconds);
        }
        Assert.Equal([3.5], retries); // counting from when the attempt began would have retried at 2.75 s
    }

    [Fact]
    public void ACaptureThatNeverFramesCountsAsFailedAfterFiveSeconds()
    {
        var (supervisor, clock) = Running();
        Assert.True(supervisor.WantsTicks);
        clock.Advance(TimeSpan.FromSeconds(5));
        Assert.Empty(supervisor.Tick());
        clock.Advance(CaptureSupervisor.TickInterval);
        Assert.Equal([new CaptureStep.Stop("capture started but sent no frames")], supervisor.Tick());

        Assert.Equal([new CaptureStep.SendStatus(Force: false)], supervisor.CaptureStopped("capture started but sent no frames"));
        clock.Advance(CaptureSupervisor.FirstRetryDelay);
        Assert.Equal([new CaptureStep.Start(SameDisplayKeepingItsCodec())], supervisor.Tick());
        Assert.Empty(supervisor.Started(FakeDisplay.Info, VideoCodec.H264));
        Assert.Empty(supervisor.FrameArrived());
        Assert.False(supervisor.WantsTicks);
    }
}
