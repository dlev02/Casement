using System.Diagnostics;
using Microsoft.Extensions.Logging.Abstractions;
using Vantage.Host.Windows.Audio;
using Vantage.Protocol.Audio;

namespace Vantage.Host.Windows.Tests;

/// <summary>
/// Real WASAPI loopback on this PC. Opt-in (<c>VANTAGE_LIVE_PC_AUDIO=1</c>): it makes the PC
/// speak a few words through the default output device, which is audible.
/// </summary>
public class AudioLiveTests
{
    private static void RequireOptIn()
    {
        if (Environment.GetEnvironmentVariable("VANTAGE_LIVE_PC_AUDIO") != "1")
            Assert.Skip("Set VANTAGE_LIVE_PC_AUDIO=1 to capture this PC's sound (it speaks).");
    }

    /// <summary>Speaks through SAPI in another process, so the sound goes through the default endpoint.</summary>
    private static Process Speak(string text) => Process.Start(new ProcessStartInfo("powershell.exe",
        $"-NoProfile -Command \"(New-Object -ComObject SAPI.SpVoice).Speak('{text}') | Out-Null\"")
    {
        CreateNoWindow = true,
        UseShellExecute = false,
    })!;

    private static async Task<List<AudioBlock>> CaptureAsync(AudioLoopback mode, TimeSpan length, bool speak)
    {
        var source = new WasapiAudioSource(NullLoggerFactory.Instance, mode);
        Assert.Null(source.UnavailableReason);
        var blocks = new List<AudioBlock>();
        string? stopped = null;
        using var speaker = speak ? Speak("Casement is listening to this PC, one two three four five") : null;
        await using (await source.StartAsync(block => { lock (blocks) blocks.Add(block); }, reason => stopped = reason, CancellationToken.None))
        {
            await Task.Delay(length);
        }
        Assert.Null(stopped);
        lock (blocks) return [.. blocks];
    }

    [Fact]
    public async Task TheOutputDevicesLoopbackHearsSpeech()
    {
        RequireOptIn();
        var blocks = await CaptureAsync(AudioLoopback.Endpoint, TimeSpan.FromSeconds(4), speak: true);
        Assert.True(blocks.Count >= 100, $"at least a second of sound in 4 s (got {blocks.Count} blocks)");
        Assert.All(blocks, block => Assert.Equal(AudioFormat.SamplesPerBlock, block.Samples.Length));
        var loud = blocks.Count(block => !SilenceGate.IsSilent(block.Samples));
        Assert.True(loud >= 50, $"half a second of speech (got {loud} blocks with sound)");
        var steps = blocks.Zip(blocks.Skip(1), (a, b) => b.CaptureNanos - a.CaptureNanos).ToList();
        var onTimeline = steps.Count(step => step == AudioFormat.NanosPerBlock);
        Assert.True(onTimeline >= steps.Count - 5, $"blocks follow each other 10 ms apart ({onTimeline} of {steps.Count})");
        var age = (double)(Vantage.Protocol.Host.HostClock.Nanos - blocks[^1].CaptureNanos) / 1e6;
        Assert.InRange(age, 0, 1500); // stamped on this machine's clock, not some other
    }

    [Fact]
    public async Task ProcessLoopbackOpensAndDeliversBlocks()
    {
        RequireOptIn();
        // Speech from a child process is in this process's tree, which process loopback leaves out:
        // what arrives is everything else (often silence), so only the cadence is checked.
        var blocks = await CaptureAsync(AudioLoopback.Process, TimeSpan.FromSeconds(1), speak: false);
        if (blocks.Count == 0) return; // nothing playing and the stream delivered nothing: fine
        var steps = blocks.Zip(blocks.Skip(1), (a, b) => b.CaptureNanos - a.CaptureNanos);
        Assert.All(steps, step => Assert.True(step >= AudioFormat.NanosPerBlock, $"monotonic, 10 ms or a new timeline ({step} ns)"));
    }

    [Fact]
    public void AutoModeCanCapture()
    {
        RequireOptIn();
        Assert.Null(new WasapiAudioSource(NullLoggerFactory.Instance).UnavailableReason);
    }
}
