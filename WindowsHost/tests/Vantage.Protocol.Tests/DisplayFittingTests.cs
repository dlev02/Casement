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

        // Asking again fits again; the session ending restores.
        await connection.SendAsync(Fit(s_iPad));
        await WaitUntil(() => fitter.IsHeld, "fitted again");
        connection.Close();
        await WaitUntil(() => !fitter.IsHeld, "restored at the end");
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

    [Fact]
    public async Task ASecondDeviceStreamsWhatsThere()
    {
        var fitter = new RecordingDisplayFitter();
        await using var host = new TestHost(displayFitter: fitter);
        var first = new TestClient();
        var (a, _, _) = await first.ConnectAsync(host.Port, "246810");
        await a.SendAsync(Fit(s_iPad));
        await Loopback.Next<VideoFrame>(a);

        var (b, _, _) = await first.ConnectAsync(host.Port); // the same paired key stands in for a second device
        await b.SendAsync(Fit(new Viewport { WidthPoints = 874, HeightPoints = 402, Scale = 3 }));
        Assert.True((await Loopback.Next<VideoFrame>(b)).IsKeyframe);
        Assert.Equal(["fit 1376x1032", "fit 874x402"], fitter.Snapshot()); // the second got Busy
        b.Close();
        await Task.Delay(300);
        Assert.True(fitter.IsHeld); // still the first device's
        a.Close();
        await WaitUntil(() => !fitter.IsHeld, "restored when its owner left");
    }
}
