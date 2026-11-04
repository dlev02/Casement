using System.Diagnostics;
using System.Threading.Channels;
using Concentus.Enums;
using Microsoft.Extensions.Logging;
using Vantage.Protocol.Messages;

namespace Vantage.Protocol.Audio;

/// <summary>
/// Opus through Concentus (a pure C# port of libopus, so it runs wherever the protocol library
/// does, including the synthetic host on a Mac): one 480-frame block in, one packet out.
/// </summary>
/// <remarks>
/// The Mac's settings: 48 kHz stereo, <c>OPUS_APPLICATION_AUDIO</c>, 128 kbps, 10 ms frames
/// (Opus's own packet size, so the client's decoder and jitter buffer count the same unit). VBR
/// as libopus defaults it (constrained), which averages ~160 bytes a packet at 128 kbps and far
/// less for quiet passages. Unlike AudioToolbox, libopus returns a packet for every frame from
/// the first (its 6.5 ms lookahead shows up as decoder delay, not missing packets), so each
/// packet keeps its own block's time. Not thread-safe; one caller at a time.
/// </remarks>
public sealed class OpusBlockEncoder
{
    /// <summary>The largest Opus packet for one frame (RFC 6716 §3.2.1: 1275 bytes) with room to spare.</summary>
    public const int MaxPacketBytes = 1_500;

#pragma warning disable CS0618 // The factory may load a native opus.dll; the managed encoder is what we test and ship.
    private readonly Concentus.Structs.OpusEncoder _encoder = new(AudioFormat.SampleRate, AudioFormat.Channels, OpusApplication.OPUS_APPLICATION_AUDIO);
#pragma warning restore CS0618
    private readonly byte[] _packet = new byte[MaxPacketBytes];

    public OpusBlockEncoder(int bitrate = 128_000)
    {
        _encoder.Bitrate = bitrate;
        Bitrate = bitrate;
    }

    /// <summary>Target bits per second.</summary>
    public int Bitrate { get; }

    /// <summary>Encodes one block (<see cref="AudioFormat.SamplesPerBlock"/> interleaved samples) into a new packet.</summary>
    public byte[] Encode(ReadOnlySpan<float> samples)
    {
        if (samples.Length != AudioFormat.SamplesPerBlock) throw new ArgumentException("An Opus packet here is exactly one 480-frame block.", nameof(samples));
        var length = _encoder.Encode(samples, AudioFormat.FramesPerBlock, _packet, _packet.Length);
        return _packet.AsSpan(0, length).ToArray();
    }
}

/// <summary>
/// The Mac's <c>AudioEncoder</c>: takes blocks from a capture thread, drops silence
/// (<see cref="SilenceGate"/>), encodes on its own serial loop and hands out numbered
/// <see cref="AudioPacket"/>s, which the session sends straight onto the connection. Logs
/// throughput every 10 s (category <c>Vantage.Audio</c>), never per packet.
/// </summary>
/// <remarks>
/// <see cref="Enqueue"/> never blocks: the capture thread mustn't wait on encoding or the
/// network, or WASAPI's buffer overflows and the next read is a glitch. Up to
/// <see cref="MaxQueuedBlocks"/> blocks (half a second) wait; past that the oldest is dropped,
/// which only happens if the machine stalls. The sequence counts packets sent, so it stays
/// continuous across silence (the client resets its decoder on a sequence gap, which a pause
/// isn't), and the client sees a pause from <c>captureNanos</c> jumping instead.
/// </remarks>
public sealed class AudioStreamEncoder : IAsyncDisposable
{
    /// <summary>Blocks waiting to be encoded before the oldest is dropped.</summary>
    public const int MaxQueuedBlocks = 50;

    private static readonly TimeSpan s_statsInterval = TimeSpan.FromSeconds(10);

    private readonly Channel<AudioBlock> _blocks = Channel.CreateBounded<AudioBlock>(new BoundedChannelOptions(MaxQueuedBlocks)
    {
        SingleReader = true,
        SingleWriter = false,
        FullMode = BoundedChannelFullMode.DropOldest,
    });
    private readonly OpusBlockEncoder _encoder;
    private readonly SilenceGate _gate = new();
    private readonly Action<AudioPacket> _onPacket;
    private readonly ILogger _log;
    private readonly Task _loop;
    // Loop-confined.
    private ulong _sequence;
    private ulong? _expectedNanos;
    private int _timelineRestarts;
    private long _windowStart = Stopwatch.GetTimestamp();
    private int _windowPackets;
    private long _windowBytes;
    private int _windowSilent;
    private double _windowEncodeMs;
    private long _packetsSent;
    private long _blocksTaken;

    /// <summary>Starts the encode loop.</summary>
    /// <param name="onPacket">Called on the encode loop for every packet, in order. Must not block.</param>
    /// <param name="log">Category <c>Vantage.Audio</c>.</param>
    /// <param name="bitrate">Target bits per second.</param>
    public AudioStreamEncoder(Action<AudioPacket> onPacket, ILogger log, int bitrate = 128_000)
    {
        _encoder = new OpusBlockEncoder(bitrate);
        _onPacket = onPacket;
        _log = log;
        Config = AudioConfig.Streaming(bitrate);
        _loop = Task.Run(RunAsync);
    }

    /// <summary>The <c>audioConfig</c> describing the packets.</summary>
    public AudioConfig Config { get; }

    /// <summary>Packets handed out so far.</summary>
    public long PacketsSent => Interlocked.Read(ref _packetsSent);

    /// <summary>Blocks the loop has taken, sent or held back (tests wait on it).</summary>
    internal long BlocksTaken => Interlocked.Read(ref _blocksTaken);

    /// <summary>Queues one block. Safe from any thread; never blocks.</summary>
    public void Enqueue(in AudioBlock block) => _blocks.Writer.TryWrite(block);

    /// <summary>Stops taking blocks and waits for the loop to finish the ones queued.</summary>
    public async ValueTask DisposeAsync()
    {
        _blocks.Writer.TryComplete();
        await _loop.ConfigureAwait(false);
    }

    private async Task RunAsync()
    {
        await foreach (var block in _blocks.Reader.ReadAllAsync().ConfigureAwait(false))
        {
            try
            {
                EncodeNow(block);
            }
            catch (Exception error) when (error is ArgumentException or InvalidOperationException or IndexOutOfRangeException)
            {
                // A broken block shouldn't end the stream; Concentus reports bad input this way.
                _log.LogError("audio block didn't encode: {Error}", error.Message);
            }
            Interlocked.Increment(ref _blocksTaken);
        }
    }

    private void EncodeNow(AudioBlock block)
    {
        if (!_gate.Admit(block))
        {
            _windowSilent++;
            LogStatsIfDue();
            return;
        }
        if (_expectedNanos is { } expected)
        {
            var drift = block.CaptureNanos > expected ? block.CaptureNanos - expected : expected - block.CaptureNanos;
            if (drift > AudioRepacketizer.DiscontinuityNanos) _timelineRestarts++;
        }
        _expectedNanos = block.CaptureNanos + AudioFormat.NanosPerBlock;
        var started = Stopwatch.GetTimestamp();
        var data = _encoder.Encode(block.Samples);
        _windowEncodeMs += Stopwatch.GetElapsedTime(started).TotalMilliseconds;
        _onPacket(new AudioPacket { Sequence = _sequence, CaptureNanos = block.CaptureNanos, FrameCount = AudioFormat.FramesPerBlock, Data = data });
        _sequence++;
        Interlocked.Increment(ref _packetsSent);
        _windowPackets++;
        _windowBytes += data.Length;
        LogStatsIfDue();
    }

    private void LogStatsIfDue()
    {
        var elapsed = Stopwatch.GetElapsedTime(_windowStart);
        if (elapsed < s_statsInterval) return;
        var seconds = elapsed.TotalSeconds;
        _log.LogInformation("audio: {Total} packets sent, {Rate:0}/s, {Kbps:0} kbps, {Bytes:0} bytes/packet, {Encode:0.00} ms/encode, {Silent} silent blocks held back, {Restarts} timeline restarts",
                            PacketsSent, _windowPackets / seconds, _windowBytes * 8 / seconds / 1000,
                            _windowPackets == 0 ? 0 : (double)_windowBytes / _windowPackets,
                            _windowPackets == 0 ? 0 : _windowEncodeMs / _windowPackets, _windowSilent, _timelineRestarts);
        _windowStart = Stopwatch.GetTimestamp();
        _windowPackets = 0;
        _windowBytes = 0;
        _windowSilent = 0;
        _windowEncodeMs = 0;
    }
}
