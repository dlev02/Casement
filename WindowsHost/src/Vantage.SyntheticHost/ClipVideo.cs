using Microsoft.Extensions.Logging;
using Vantage.Protocol.Host;
using Vantage.Protocol.Messages;
using Vantage.Protocol.Video;

namespace Vantage.SyntheticHost;

/// <summary>The pre-encoded clip, split into access units, with the IDRs marked.</summary>
internal sealed class Clip
{
    public Clip(string path)
    {
        Units = AnnexB.SplitAccessUnits(File.ReadAllBytes(path));
        if (Units.Count == 0) throw new InvalidDataException($"{path} holds no H.264 access units.");
        Keyframes = [.. Enumerable.Range(0, Units.Count).Where(i => AnnexB.ToAccessUnit(Units[i]).IsKeyframe)];
        if (Keyframes.Count == 0 || Keyframes[0] != 0) throw new InvalidDataException($"{path} must start with an IDR.");
    }

    public const int Width = 1600;
    public const int Height = 1000;
    public const int Fps = 30;

    public IReadOnlyList<byte[]> Units { get; }
    public IReadOnlyList<int> Keyframes { get; }

    /// <summary>The first IDR at or after <paramref name="index"/>, wrapping to the start.</summary>
    public int NextKeyframe(int index)
    {
        foreach (var keyframe in Keyframes)
        {
            if (keyframe >= index) return keyframe;
        }
        return 0;
    }
}

/// <summary>A pretend display the clip plays on; its sleep state is what <c>--display-asleep</c> and the sleep/wake commands move.</summary>
internal sealed class FakeDisplay(bool enabled, bool startsAsleep, ILogger log) : IHostStatusSource, IPowerControl
{
    private readonly Lock _lock = new();
    private readonly List<Action> _watchers = [];
    private bool _asleep = enabled && startsAsleep;

    public static readonly DisplayInfo Info = new()
    {
        Id = 1,
        Name = "Vantage Synthetic Display",
        PixelWidth = Clip.Width,
        PixelHeight = Clip.Height,
        PointWidth = Clip.Width / 2,
        PointHeight = Clip.Height / 2,
        Scale = 2,
        OriginX = 0,
        OriginY = 0,
        IsMain = true,
        IsBuiltIn = false,
        IsVirtual = true,
        RefreshRate = 60,
    };

    /// <summary>Raised when the display sleeps (running captures stop, as a real display's would).</summary>
    public event Action? FellAsleep;

    public bool IsAsleep
    {
        get { lock (_lock) return _asleep; }
    }

    public HostConditions Current => new(false, false, IsAsleep, null);

    public IDisposable Watch(Action onChanged)
    {
        lock (_lock) _watchers.Add(onChanged);
        return new Unsubscribe(() =>
        {
            lock (_lock) _watchers.Remove(onChanged);
        });
    }

    public IDisposable KeepAwake() => new Unsubscribe(() => { });

    public void SleepDisplay() => SetAsleep(true, "Sleep Display");

    public void WakeDisplay() => SetAsleep(false, "Wake");

    public void LockScreen() => log.LogInformation("lock screen asked for (synthetic: ignored)");

    private void SetAsleep(bool asleep, string reason)
    {
        if (!enabled)
        {
            log.LogInformation("{Reason} asked for (synthetic without --display-asleep: ignored)", reason);
            return;
        }
        List<Action> watchers;
        lock (_lock)
        {
            if (_asleep == asleep) return;
            _asleep = asleep;
            watchers = [.. _watchers];
        }
        log.LogInformation("pretend display {State} ({Reason})", asleep ? "asleep" : "awake", reason);
        if (asleep) FellAsleep?.Invoke();
        foreach (var watcher in watchers) watcher();
    }

    private sealed class Unsubscribe(Action action) : IDisposable
    {
        public void Dispose() => action();
    }
}

/// <summary>"Captures" the pretend display: a tick per clip frame, each an opaque frame the clip encoder turns into the next access unit.</summary>
internal sealed class ClipScreenSource(FakeDisplay display, ILogger log) : IScreenSource
{
    public bool IsCaptureSupported => true;

    public string CaptureUnsupportedMessage => "";

    public Task<IReadOnlyList<DisplayInfo>> GetDisplaysAsync(CancellationToken cancellationToken) =>
        Task.FromResult<IReadOnlyList<DisplayInfo>>(display.IsAsleep ? [] : [FakeDisplay.Info]);

    public Task<ICaptureStream> StartAsync(CaptureRequest request, Action<ICapturedFrame> onFrame, Action<string> onStopped, CancellationToken cancellationToken)
    {
        if (display.IsAsleep) throw new CaptureUnavailableException("the display is asleep (no displays to capture)");
        return Task.FromResult<ICaptureStream>(new Stream(display, onFrame, onStopped, log));
    }

    private sealed class Stream : ICaptureStream
    {
        private readonly FakeDisplay _display;
        private readonly CancellationTokenSource _stop = new();
        private readonly Action<string> _onStopped;
        private int _stopped;

        public Stream(FakeDisplay display, Action<ICapturedFrame> onFrame, Action<string> onStopped, ILogger log)
        {
            _display = display;
            _onStopped = onStopped;
            display.FellAsleep += OnSleep;
            _ = Task.Run(async () =>
            {
                using var timer = new PeriodicTimer(TimeSpan.FromSeconds(1.0 / Clip.Fps));
                try
                {
                    while (await timer.WaitForNextTickAsync(_stop.Token).ConfigureAwait(false))
                        onFrame(new ClipFrame(HostClock.Nanos));
                }
                catch (OperationCanceledException)
                {
                    // Stopped.
                }
                catch (Exception error)
                {
                    log.LogError("synthetic capture failed: {Error}", error.Message);
                }
            });
        }

        public DisplayInfo Display => FakeDisplay.Info;
        public int FrameWidth => Clip.Width;
        public int FrameHeight => Clip.Height;

        public void SetFrameRate(int fps)
        {
            // The clip plays at its own rate.
        }

        private void OnSleep()
        {
            if (Interlocked.Exchange(ref _stopped, 1) != 0) return;
            _stop.Cancel();
            _onStopped("display asleep");
        }

        public ValueTask DisposeAsync()
        {
            Interlocked.Exchange(ref _stopped, 1);
            _display.FellAsleep -= OnSleep;
            _stop.Cancel();
            return ValueTask.CompletedTask;
        }
    }

    private sealed class ClipFrame(ulong nanos) : ICapturedFrame
    {
        public ulong TimestampNanos { get; } = nanos;
        public double DirtyRatio => 0.05;
        public int Width => Clip.Width;
        public int Height => Clip.Height;

        public void Dispose()
        {
        }
    }
}

/// <summary>
/// "Encodes" by handing out the clip's access units in order, looping. A forced keyframe jumps to
/// the next IDR (GOP-aligned), so the picture stays decodable whatever frames the session skipped.
/// </summary>
internal sealed class ClipEncoderFactory(Clip clip) : IVideoEncoderFactory
{
    public IReadOnlyList<VideoCodec> SupportedCodecs { get; } = [VideoCodec.H264];

    public IVideoEncoder Create(ICaptureStream source, VideoEncoderSettings settings) => new Encoder(clip);

    private sealed class Encoder(Clip clip) : IVideoEncoder
    {
        private IEncodedFrameSink? _sink;
        private int _next;

        public void Start(IEncodedFrameSink sink) => _sink = sink;

        public ValueTask EncodeAsync(ICapturedFrame frame, bool forceKeyframe, CancellationToken cancellationToken)
        {
            if (forceKeyframe) _next = clip.NextKeyframe(_next);
            var index = _next;
            _next = (_next + 1) % clip.Units.Count;
            var output = new EncodedFrame
            {
                Data = clip.Units[index],
                Format = NalFormat.AnnexB,
                IsKeyframe = clip.Keyframes.Contains(index),
                CaptureNanos = frame.TimestampNanos,
                Width = Clip.Width,
                Height = Clip.Height,
            };
            var sink = _sink;
            _ = Task.Run(() => sink?.OnFrame(output), cancellationToken);
            return ValueTask.CompletedTask;
        }

        public void SetBitrate(int kbps)
        {
        }

        public void SetFrameRate(int fps)
        {
        }

        public void SetMaxQP(int maxQP)
        {
        }

        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
}
