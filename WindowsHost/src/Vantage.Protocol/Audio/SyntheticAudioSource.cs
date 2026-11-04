using System.Diagnostics;
using Vantage.Protocol.Host;

namespace Vantage.Protocol.Audio;

/// <summary>
/// The Mac synthetic host's test signal (<c>ChimeSynth</c>, same notes and envelope): a two-note
/// "ding-dong" every two seconds, never above −18 dBFS, the first note (G5) leaning left and the
/// second (E5) right. Pure and deterministic, so tests can check what comes out the far end.
/// </summary>
public sealed class ChimeSynth
{
    /// <summary>−18 dBFS.</summary>
    public const float Peak = 0.1259f;
    public const double Period = 2.0;
    public const double NoteLength = 1.4;

    /// <summary>(start seconds into the period, frequency, left gain, right gain).</summary>
    public static readonly (double Start, double Frequency, float Left, float Right)[] Notes =
    [
        (0.0, 783.99, 1.0f, 0.7f),  // G5
        (0.32, 659.25, 0.7f, 1.0f), // E5
    ];

    private readonly double _sampleRate;
    private long _frame;

    public ChimeSynth(double sampleRate = AudioFormat.SampleRate) => _sampleRate = sampleRate;

    /// <summary>Renders <c>output.Length / 2</c> interleaved stereo frames and advances.</summary>
    public void Render(Span<float> output)
    {
        var frames = output.Length / 2;
        var periodFrames = (long)(Period * _sampleRate);
        for (var index = 0; index < frames; index++)
        {
            var t = (double)((_frame + index) % periodFrames) / _sampleRate;
            float left = 0, right = 0;
            foreach (var note in Notes)
            {
                if (t < note.Start || t >= note.Start + NoteLength) continue;
                var value = Voice(t - note.Start, note.Frequency);
                left += value * note.Left;
                right += value * note.Right;
            }
            output[index * 2] = left;
            output[index * 2 + 1] = right;
        }
        _frame += frames;
    }

    /// <summary>
    /// Fundamental plus a softer octave, a 4 ms attack, an exponential decay, and a short fade at
    /// the end so it never clicks. The second note starts while the first still rings (at 40 % in
    /// the louder channel), so each voice sits a little under the peak and the overlap never crosses it.
    /// </summary>
    private static float Voice(double time, double frequency)
    {
        var attack = Math.Min(1, time / 0.004);
        var release = Math.Min(1, (NoteLength - time) / 0.05);
        var envelope = attack * Math.Exp(-time / 0.35) * release;
        var tone = Math.Sin(2 * Math.PI * frequency * time) + 0.3 * Math.Sin(2 * Math.PI * 2 * frequency * time);
        return (float)(envelope * tone / 1.3 / 1.28) * Peak;
    }
}

/// <summary>
/// Feeds <see cref="ChimeSynth"/> through the same repacketizer as real capture, paced by the
/// clock so the stream runs at exactly 48 kHz on average whatever the thread's sleeps do (Windows
/// rounds a 5 ms sleep up to its 15.6 ms tick; the blocks just come in pairs). The synthetic hosts'
/// sound, so the whole audio path runs without a sound card.
/// </summary>
public sealed class SyntheticAudioSource : IAudioSource
{
    /// <inheritdoc />
    public string? UnavailableReason => null;

    /// <inheritdoc />
    public Task<IAudioCapture> StartAsync(Action<AudioBlock> onBlock, Action<string> onStopped, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult<IAudioCapture>(new Capture(onBlock));
    }

    private sealed class Capture : IAudioCapture
    {
        private readonly Action<AudioBlock> _onBlock;
        private readonly Thread _thread;
        private volatile bool _stopping;

        public Capture(Action<AudioBlock> onBlock)
        {
            _onBlock = onBlock;
            _thread = new Thread(Run) { IsBackground = true, Name = "Vantage synthetic audio" };
            _thread.Start();
        }

        public string Description => "synthetic chime";

        public ValueTask DisposeAsync()
        {
            _stopping = true;
            _thread.Join();
            return ValueTask.CompletedTask;
        }

        private void Run()
        {
            var synth = new ChimeSynth();
            var repacketizer = new AudioRepacketizer();
            var blocks = new List<AudioBlock>();
            var scratch = new float[AudioFormat.SampleRate / 10 * AudioFormat.Channels];
            var startNanos = HostClock.Nanos;
            var started = Stopwatch.GetTimestamp();
            long produced = 0;
            while (!_stopping)
            {
                var due = (long)(Stopwatch.GetElapsedTime(started).TotalSeconds * AudioFormat.SampleRate);
                // After a long stall (debugger, sleep) skip ahead instead of bursting.
                if (due - produced > AudioFormat.SampleRate / 10) produced = due - AudioFormat.FramesPerBlock;
                while (produced < due)
                {
                    var frames = (int)Math.Min(due - produced, scratch.Length / AudioFormat.Channels);
                    var chunk = scratch.AsSpan(0, frames * AudioFormat.Channels);
                    synth.Render(chunk);
                    blocks.Clear();
                    repacketizer.Append(chunk, startNanos + AudioFormat.NanosFor(produced), blocks);
                    produced += frames;
                    foreach (var block in blocks) _onBlock(block);
                }
                Thread.Sleep(5);
            }
        }
    }
}
