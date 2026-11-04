using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using Microsoft.Extensions.Logging;
using Vantage.Protocol.Audio;
using Vantage.Protocol.Host;

namespace Vantage.Host.Windows.Audio;

/// <summary>
/// A running loopback capture: one MTA thread that waits on WASAPI's event, drains every packet,
/// converts it to 48 kHz stereo float, cuts it into 10 ms blocks with capture-time stamps and
/// hands them to the session (which only queues them, so this thread never waits on encoding or
/// the network and WASAPI's buffer never overflows).
/// </summary>
/// <remarks>
/// Timestamps: WASAPI's <c>qpcPosition</c> (100 ns units of the performance counter, the same
/// clock as <see cref="HostClock"/>) for the packet's first frame; when it is missing or flagged
/// <c>AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR</c>, now minus the packet's length.
/// <c>AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY</c> starts a new timeline; <c>SILENT</c> packets are
/// zeros (the encoder's silence gate turns long runs of them into a pause). Endpoint loopback
/// delivers nothing while nothing plays: the next packet's timestamp has jumped and the
/// repacketizer starts a new timeline itself. The event is waited with a 20 ms timeout as well,
/// since loopback streams have not always signalled it. A new default output device, or a device
/// invalidated under us, closes the stream and opens a new one (backing off 0.25 s → 4 s, about
/// 8 s in all); after that the session hears why through <c>onStopped</c>.
/// </remarks>
[SupportedOSPlatform("windows10.0.19041.0")]
internal sealed class WasapiLoopbackCapture : IAudioCapture
{
    private static readonly TimeSpan[] s_retryDelays =
        [TimeSpan.Zero, TimeSpan.FromSeconds(0.25), TimeSpan.FromSeconds(0.5), TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(4)];
    private static readonly ulong s_maxTimestampAge = 1_000_000_000;

    private readonly AudioLoopback _mode;
    private readonly Action<AudioBlock> _onBlock;
    private readonly Action<string> _onStopped;
    private readonly ILogger _log;
    private readonly Thread _thread;
    private readonly AutoResetEvent _ready = new(false);
    private readonly TaskCompletionSource _started = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly AudioRepacketizer _repacketizer = new();
    private readonly List<AudioBlock> _blocks = [];
    private volatile bool _stopping;
    private volatile bool _deviceChanged;
    private string _description = "";
    // Capture-thread only.
    private long _packets;
    private long _discontinuities;
    private long _timestampFallbacks;
    private int _reopens;

    public WasapiLoopbackCapture(AudioLoopback mode, Action<AudioBlock> onBlock, Action<string> onStopped, ILogger log)
    {
        _mode = mode;
        _onBlock = onBlock;
        _onStopped = onStopped;
        _log = log;
        _thread = new Thread(Run) { IsBackground = true, Name = "Vantage audio capture", Priority = ThreadPriority.AboveNormal };
        _thread.SetApartmentState(ApartmentState.MTA);
        _thread.Start();
    }

    /// <summary>Completes once the first stream is open, or faults with <see cref="AudioUnavailableException"/>.</summary>
    public Task Started => _started.Task;

    /// <inheritdoc />
    public string Description => Volatile.Read(ref _description);

    /// <inheritdoc />
    public async ValueTask DisposeAsync()
    {
        _stopping = true;
        _ready.Set();
        await Task.Run(_thread.Join).ConfigureAwait(false);
        _ready.Dispose();
    }

    private void Run()
    {
        using var com = Mta.Enter();
        try
        {
            Capture();
        }
        catch (Exception error)
        {
            // Nothing above this thread would catch it: report it the way the session hears every
            // other end of capture, instead of taking the host down.
            _log.LogError("audio capture failed: {Error}", error);
            if (!_started.TrySetException(new AudioUnavailableException($"Windows refused loopback capture: {error.Message}", error)))
                _onStopped($"The PC stopped sending its sound ({error.Message})");
        }
    }

    private void Capture()
    {
        nint enumerator;
        try
        {
            enumerator = Wasapi.CreateEnumerator();
        }
        catch (COMException error)
        {
            _started.TrySetException(LoopbackStream.Unavailable(error));
            return;
        }
        var watcher = DefaultDeviceWatcher.Create(() =>
        {
            _deviceChanged = true;
            _ready.Set();
        });
        var watching = Wasapi.RegisterEndpointNotificationCallback(enumerator, watcher) >= 0;
        LoopbackStream? stream = null;
        try
        {
            try
            {
                stream = LoopbackStream.Open(_mode, _ready, _log);
            }
            catch (AudioUnavailableException error)
            {
                _started.TrySetException(error);
                return;
            }
            Volatile.Write(ref _description, stream.Description);
            _log.LogInformation("audio capture started: {Description}", stream.Description);
            _started.TrySetResult();
            while (!_stopping)
            {
                string? failure = null;
                try
                {
                    _ready.WaitOne(20);
                    if (_stopping) break;
                    if (_deviceChanged)
                    {
                        _deviceChanged = false;
                        failure = "the default output device changed";
                    }
                    else
                    {
                        Drain(stream);
                    }
                }
                catch (COMException error)
                {
                    failure = error.HResult == Wasapi.AUDCLNT_E_DEVICE_INVALIDATED ? "the output device went away" : error.Message;
                }
                if (failure is null) continue;
                stream.Dispose();
                stream = Reopen(failure);
                if (stream is null) return;
            }
        }
        finally
        {
            stream?.Dispose();
            if (watching) Wasapi.UnregisterEndpointNotificationCallback(enumerator, watcher);
            NativeCallbackObject.Release(watcher);
            Wasapi.Release(ref enumerator);
            if (_packets > 0)
            {
                _log.LogInformation("audio capture ended after {Packets} packets, {Discontinuities} discontinuities, {Fallbacks} estimated timestamps, {Reopens} reopens, {Restarts} timeline restarts",
                                    _packets, _discontinuities, _timestampFallbacks, _reopens, _repacketizer.TimelineRestarts);
            }
        }
    }

    /// <summary>Opens a new stream after <paramref name="why"/>; null (and <c>onStopped</c>) when every attempt failed or capture is stopping.</summary>
    private LoopbackStream? Reopen(string why)
    {
        _log.LogInformation("audio capture restarting: {Why}", why);
        _repacketizer.Reset();
        string reason = "";
        foreach (var delay in s_retryDelays)
        {
            if (delay > TimeSpan.Zero && _ready.WaitOne(delay) && _stopping) return null;
            if (_stopping) return null;
            _deviceChanged = false;
            try
            {
                var stream = LoopbackStream.Open(_mode, _ready, _log);
                _reopens++;
                Volatile.Write(ref _description, stream.Description);
                _log.LogInformation("audio capture reopened: {Description}", stream.Description);
                return stream;
            }
            catch (AudioUnavailableException error)
            {
                reason = error.Message;
            }
        }
        _log.LogError("audio capture gave up: {Reason}", reason);
        _onStopped($"The PC stopped sending its sound ({reason})");
        return null;
    }

    private unsafe void Drain(LoopbackStream stream)
    {
        var capture = stream.CaptureClient;
        while (!_stopping)
        {
            Wasapi.Check(Wasapi.GetNextPacketSize(capture, out var next), "IAudioCaptureClient::GetNextPacketSize");
            if (next == 0) return;
            var hr = Wasapi.GetBuffer(capture, out var data, out var frames, out var flags, out var qpc);
            if (hr == Wasapi.AUDCLNT_S_BUFFER_EMPTY) return;
            Wasapi.Check(hr, "IAudioCaptureClient::GetBuffer");
            try
            {
                Deliver(stream, data, frames, flags, qpc);
            }
            finally
            {
                Wasapi.ReleaseBuffer(capture, frames);
            }
        }
    }

    private unsafe void Deliver(LoopbackStream stream, byte* data, uint frames, uint flags, ulong qpc)
    {
        if (frames == 0) return;
        _packets++;
        var now = HostClock.Nanos;
        var startNanos = qpc * 100;
        if ((flags & Wasapi.AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR) != 0 || qpc == 0 || startNanos > now + 1_000_000 || now - startNanos > s_maxTimestampAge)
        {
            _timestampFallbacks++;
            startNanos = now - Math.Min(now, AudioFormat.NanosFor(frames * (long)AudioFormat.SampleRate / stream.Converter.Format.SampleRate));
        }
        var discontinuity = (flags & Wasapi.AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY) != 0;
        if (discontinuity) _discontinuities++;
        var silent = (flags & Wasapi.AUDCLNT_BUFFERFLAGS_SILENT) != 0;
        if (discontinuity) stream.Converter.Reset();
        var converter = stream.Converter;
        ReadOnlySpan<float> samples = converter.IsPassthrough && !silent
            ? MemoryMarshal.Cast<byte, float>(new ReadOnlySpan<byte>(data, (int)frames * converter.Format.BytesPerFrame))
            : converter.Convert(new ReadOnlySpan<byte>(data, silent ? 0 : (int)frames * converter.Format.BytesPerFrame), (int)frames, silent);
        if (_packets == 1)
        {
            _log.LogInformation("audio capture: {Frames} frames in the first packet, timestamp {Age:0.0} ms old{Flags}",
                                frames, (now - startNanos) / 1e6, flags != 0 ? $", flags 0x{flags:X}" : "");
        }
        _blocks.Clear();
        var restarts = _repacketizer.TimelineRestarts;
        _repacketizer.Append(samples, startNanos, _blocks, discontinuity);
        if (_repacketizer.TimelineRestarts != restarts)
        {
            _log.LogInformation("audio timeline restarted: the packet's timestamp was {Drift:+0.0;-0.0} ms off the sample clock{Flags}",
                                _repacketizer.LastRestartDriftNanos / 1e6, discontinuity ? " (discontinuity)" : silent ? " (silent)" : "");
        }
        foreach (var block in _blocks) _onBlock(block);
    }
}
