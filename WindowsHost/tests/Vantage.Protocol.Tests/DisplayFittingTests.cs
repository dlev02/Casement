using Vantage.Protocol.Host;
using Vantage.Protocol.Messages;
using Vantage.Protocol.Transport;

namespace Vantage.Protocol.Tests;

/// <summary>A fitter that records what sessions asked; a viewport "fits" by changing the pretend mode.</summary>
internal sealed class RecordingDisplayFitter : IDisplayFitter
{
    private readonly Lock _lock = new();
    private (Guid Owner, Viewport Viewport)? _held;
    public readonly List<string> Calls = [];
    public bool Enabled = true;

    public bool IsEnabled => Enabled;

    public bool IsHeld
    {
        get { lock (_lock) return _held is not null; }
    }

    public string[] Snapshot()
    {
        lock (_lock) return [.. Calls];
    }

    public DisplayFitResult Fit(Guid owner, DisplayInfo display, Viewport viewport)
    {
        lock (_lock)
        {
            Calls.Add($"fit {viewport.WidthPoints}x{viewport.HeightPoints}");
            if (_held is { } held && held.Owner != owner) return DisplayFitResult.Busy;
            if (_held is { } same && same.Viewport == viewport) return DisplayFitResult.Unchanged;
            _held = (owner, viewport);
            return DisplayFitResult.Changed;
        }
    }

    public bool Restore(Guid owner)
    {
        lock (_lock)
        {
            if (_held is not { } held || held.Owner != owner) return false;
            Calls.Add("restore");
            _held = null;
            return true;
        }
    }

    public void RestoreAll()
    {
        lock (_lock)
        {
            if (_held is null) return;
            Calls.Add("restore all");
            _held = null;
        }
    }
}

public class DisplayFittingTests
{
    private static readonly Viewport s_iPad = new() { WidthPoints = 1376, HeightPoints = 1032, Scale = 2 };

    private static SelectDisplay Fit(Viewport viewport, bool useVirtualDisplay = true) => new()
    {
        Selection = new DisplaySelection.FitViewport(viewport), TargetFPS = 60, Quality = QualityPreset.Auto, UseVirtualDisplay = useVirtualDisplay,
    };

    private static async Task WaitUntil(Func<bool> condition, string what)
    {
        for (var i = 0; i < 100 && !condition(); i++) await Task.Delay(50);
        Assert.True(condition(), what);
    }

    [Fact]
    public async Task AdvertisedOnlyWithAnEnabledFitter()
    {
        await using (var plain = new TestHost())
        {
            var (connection, _, result) = await new TestClient().ConnectAsync(plain.Port, "246810");
            Assert.False(result.Capabilities!.CanManageVirtualDisplay);
            connection.Close();
        }
        var fitter = new RecordingDisplayFitter();
        await using var host = new TestHost(displayFitter: fitter);
        var client = new TestClient();
        var (first, _, enabled) = await client.ConnectAsync(host.Port, "246810");
        Assert.True(enabled.Capabilities!.CanManageVirtualDisplay);
        first.Close();
        fitter.Enabled = false; // the Display page's switch
        var (second, _, disabled) = await client.ConnectAsync(host.Port);
        Assert.False(disabled.Capabilities!.CanManageVirtualDisplay);
        await second.SendAsync(Fit(s_iPad));
        await Loopback.Next<VideoFrame>(second);
        Assert.Empty(fitter.Snapshot());
        second.Close();
    }

    [Fact]
    public async Task FitsOnlyWhenAskedAndRestoresOnRequestAndAtTheEnd()
    {
        var fitter = new RecordingDisplayFitter();
        await using var host = new TestHost(displayFitter: fitter);
        var client = new TestClient();

        // The default fitViewport streams the main display as it is.
        var (plain, _, _) = await client.ConnectAsync(host.Port, "246810");
        await plain.SendAsync(Fit(s_iPad, useVirtualDisplay: false));
        await Loopback.Next<VideoFrame>(plain);
        Assert.Empty(fitter.Snapshot());
        plain.Close();

        var (connection, _, _) = await client.ConnectAsync(host.Port);
        await connection.SendAsync(Fit(s_iPad));
        var config = await Loopback.Next<StreamConfig>(connection);
        Assert.Equal("Vantage Synthetic Display", config.Display.Name);
        Assert.True((await Loopback.Next<VideoFrame>(connection)).IsKeyframe);
        Assert.Equal(["fit 1376x1032"], fitter.Snapshot());
        Assert.True(fitter.IsHeld);

        // restoreDisplays puts it back and the stream carries on, from a new keyframe.
        await connection.SendAsync(new HostCommandMessage { Command = HostCommand.RestoreDisplays });
        await Loopback.Next<StreamConfig>(connection);
        VideoFrame frame;
        do frame = await Loopback.Next<VideoFrame>(connection); while (!frame.IsKeyframe);
        Assert.Equal(["fit 1376x1032", "restore"], fitter.Snapshot());

        // Asking again fits again; the device saying goodbye restores at once.
        await connection.SendAsync(Fit(s_iPad));
        await WaitUntil(() => fitter.IsHeld, "fitted again");
        await Loopback.Next<StreamConfig>(connection);
        await connection.SendAsync(new DisconnectMessage { Reason = "closed" });
        await WaitUntil(() => !fitter.IsHeld, "restored at the end");
        connection.Close();
        Assert.Equal(["fit 1376x1032", "restore", "fit 1376x1032", "restore"], fitter.Snapshot());
    }

    /// <summary>
    /// Casement never sends <c>viewportChanged</c>: a rotation arrives as a new <c>selectDisplay</c>
    /// (<c>ClientSession.updateViewport</c>). A client that does send it gets a keyframe, as from the
    /// Mac host, and the display is left alone.
    /// </summary>
    [Fact]
    public async Task AViewportChangeOnlyForcesAKeyframeAndANewSelectionRefits()
    {
        var fitter = new RecordingDisplayFitter();
        await using var host = new TestHost(displayFitter: fitter);
        var (connection, _, _) = await new TestClient().ConnectAsync(host.Port, "246810");
        await connection.SendAsync(Fit(s_iPad));
        await Loopback.Next<VideoFrame>(connection);

        var portrait = new Viewport { WidthPoints = 1032, HeightPoints = 1376, Scale = 2 };
        await connection.SendAsync(new ViewportChanged { Viewport = portrait });
        VideoFrame frame;
        do frame = await Loopback.Next<VideoFrame>(connection); while (!frame.IsKeyframe);
        await Task.Delay(300);
        Assert.Equal(["fit 1376x1032"], fitter.Snapshot());

        await connection.SendAsync(Fit(portrait));
        await Loopback.Next<StreamConfig>(connection); // capture restarted on the new mode
        Assert.Equal(["fit 1376x1032", "fit 1032x1376"], fitter.Snapshot());
        connection.Close();
    }

    /// <summary>
    /// A dropped connection keeps the device's fitted mode for <see cref="DisplayHolds.ReconnectGrace"/>:
    /// the reconnect (even one that arrives before the old session has noticed it's gone) takes the
    /// hold over with no switch, and only a device that stays away gets its mode put back.
    /// </summary>
    [Fact]
    public void AReconnectWithinTheGraceKeepsTheFittedModeAndOnlyStayingAwayRestoresIt()
    {
        var clock = new Microsoft.Extensions.Time.Testing.FakeTimeProvider();
        var fitter = new RecordingDisplayFitter();
        var holds = new DisplayHolds(fitter, clock, Microsoft.Extensions.Logging.Abstractions.NullLogger.Instance);
        Guid old = Guid.NewGuid(), lingering = Guid.NewGuid(), back = Guid.NewGuid();
        var display = Vantage.SyntheticHost.FakeDisplay.Info;

        Assert.Equal(DisplayFitResult.Changed, holds.Fit(old, "ipad", display, s_iPad));
        // The new connection arrives while the old session still thinks it's up: not Busy, nothing switches.
        Assert.Equal(DisplayFitResult.Unchanged, holds.Fit(lingering, "ipad", display, s_iPad));
        holds.Release(old, "ipad"); // the old one finally notices; it no longer holds anything
        Assert.False(holds.Restore(old, "ipad"));

        holds.Release(lingering, "ipad"); // dropped again
        clock.Advance(DisplayHolds.ReconnectGrace - TimeSpan.FromSeconds(1));
        Assert.Equal(DisplayFitResult.Unchanged, holds.Fit(back, "ipad", display, s_iPad)); // back in time
        clock.Advance(DisplayHolds.ReconnectGrace * 2);
        Assert.True(fitter.IsHeld);
        Assert.Equal(["fit 1376x1032", "fit 1376x1032", "fit 1376x1032"], fitter.Snapshot()); // never restored

        holds.Release(back, "ipad"); // and this time it stays away
        clock.Advance(DisplayHolds.ReconnectGrace);
        Assert.False(fitter.IsHeld);
        Assert.Equal("restore", fitter.Snapshot()[^1]);
    }

    /// <summary>Switching only the quality preset (the session menu's Quality) changes it in place: no new capture, no new streamConfig.</summary>
    [Fact]
    public async Task AQualityChangeAloneDoesNotRestartTheStream()
    {
        await using var host = new TestHost();
        var (connection, _, _) = await new TestClient().ConnectAsync(host.Port, "246810");
        await connection.SendAsync(Fit(s_iPad, useVirtualDisplay: false));
        await Loopback.Next<StreamConfig>(connection);
        await Loopback.Next<VideoFrame>(connection);

        await connection.SendAsync(Fit(s_iPad, useVirtualDisplay: false) with { Quality = QualityPreset.Text });
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => Loopback.Next<StreamConfig>(connection, TimeSpan.FromSeconds(1)));

        // Anything else about the selection still restarts it.
        await connection.SendAsync(Fit(s_iPad, useVirtualDisplay: false) with { Quality = QualityPreset.Text, TargetFPS = 30 });
        Assert.Equal(30, (await Loopback.Next<StreamConfig>(connection)).Fps);
        connection.Close();
    }

    [Fact]
    public async Task ASecondDeviceStreamsWhatsThere()
    {
        var fitter = new RecordingDisplayFitter();
        await using var host = new TestHost(displayFitter: fitter);
        var first = new TestClient();
        var (a, _, _) = await first.ConnectAsync(host.Port, "246810");
        await a.SendAsync(Fit(s_iPad));
        await Loopback.Next<VideoFrame>(a);

        host.Listener.Pairing.NewCode(); // the fixed code again, for a second device
        var (b, _, _) = await new TestClient().ConnectAsync(host.Port, "246810");
        await b.SendAsync(Fit(new Viewport { WidthPoints = 874, HeightPoints = 402, Scale = 3 }));
        Assert.True((await Loopback.Next<VideoFrame>(b)).IsKeyframe);
        Assert.Equal(["fit 1376x1032", "fit 874x402"], fitter.Snapshot()); // the second got Busy
        await b.SendAsync(new DisconnectMessage { Reason = "closed" });
        b.Close();
        await Task.Delay(300);
        Assert.True(fitter.IsHeld); // still the first device's
        await a.SendAsync(new DisconnectMessage { Reason = "closed" });
        a.Close();
        await WaitUntil(() => !fitter.IsHeld, "restored when its owner left");
    }
}
