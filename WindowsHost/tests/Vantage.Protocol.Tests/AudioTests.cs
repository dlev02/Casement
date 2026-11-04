using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using Microsoft.Extensions.Logging.Abstractions;
using Vantage.Protocol.Audio;
using Vantage.Protocol.Host;
using Vantage.Protocol.Messages;
using Vantage.Protocol.Transport;
using Vantage.Protocol.Wire;

namespace Vantage.Protocol.Tests;

/// <summary>Opus decoding for the tests (the host only encodes).</summary>
internal static class OpusCheck
{
    /// <summary>Decodes packets in order into interleaved stereo float.</summary>
    public static float[] Decode(IEnumerable<byte[]> packets)
    {
#pragma warning disable CS0618 // the managed decoder, as the encoder
        var decoder = new Concentus.Structs.OpusDecoder(AudioFormat.SampleRate, AudioFormat.Channels);
#pragma warning restore CS0618
        var output = new List<float>();
        var pcm = new float[AudioFormat.SamplesPerBlock];
        foreach (var packet in packets)
        {
            var frames = decoder.Decode(packet, pcm, AudioFormat.FramesPerBlock, false);
            output.AddRange(pcm.AsSpan(0, frames * AudioFormat.Channels).ToArray());
        }
        return [.. output];
    }

    public static double Rms(ReadOnlySpan<float> samples)
    {
        if (samples.IsEmpty) return 0;
        double sum = 0;
        foreach (var sample in samples) sum += sample * sample;
        return Math.Sqrt(sum / samples.Length);
    }

    /// <summary>The first <paramref name="count"/> blocks of the chime.</summary>
    public static List<AudioBlock> ChimeBlocks(int count, ulong startNanos = 1_000_000_000)
    {
        var synth = new ChimeSynth();
        var blocks = new List<AudioBlock>();
        for (var i = 0; i < count; i++)
        {
            var samples = new float[AudioFormat.SamplesPerBlock];
            synth.Render(samples);
            blocks.Add(new AudioBlock(samples, startNanos + (ulong)i * AudioFormat.NanosPerBlock));
        }
        return blocks;
    }
}

public class AudioRepacketizerTests
{
    private static float[] Ramp(int frames, int from)
    {
        var samples = new float[frames * 2];
        for (var i = 0; i < frames; i++)
        {
            samples[i * 2] = from + i;
            samples[i * 2 + 1] = -(from + i);
        }
        return samples;
    }

    [Fact]
    public void BuffersOfAnySizeBecome480FrameBlocksOnTheSampleClock()
    {
        var repacketizer = new AudioRepacketizer();
        var blocks = new List<AudioBlock>();
        const ulong start = 5_000_000_000;
        var frames = 0;
        // 300 + 300 + 100 + 1000 + 220 = 1920 frames = 4 blocks, with timestamps that wobble by ±2 ms.
        foreach (var (size, wobble) in new[] { (300, 0L), (300, 2_000_000L), (100, -1_500_000L), (1000, 1_000_000L), (220, 0L) })
        {
            var nanos = (ulong)((long)(start + AudioFormat.NanosFor(frames)) + wobble);
            repacketizer.Append(Ramp(size, frames), nanos, blocks);
            frames += size;
        }
        Assert.Equal(4, blocks.Count);
        for (var i = 0; i < blocks.Count; i++)
        {
            Assert.Equal(AudioFormat.SamplesPerBlock, blocks[i].Samples.Length);
            Assert.Equal(start + (ulong)i * 10_000_000, blocks[i].CaptureNanos); // the samples are the clock, not the wobble
            Assert.Equal(i * 480, blocks[i].Samples[0]);
            Assert.Equal(-(i * 480 + 479), blocks[i].Samples[^1]);
        }
        Assert.Equal(0, repacketizer.TimelineRestarts);
    }

    [Fact]
    public void ATimestampJumpFinishesThePartialBlockWithSilenceAndStartsANewTimeline()
    {
        var repacketizer = new AudioRepacketizer();
        var blocks = new List<AudioBlock>();
        repacketizer.Append(Ramp(600, 1), 1_000_000_000, blocks); // one block + 120 frames pending
        Assert.Single(blocks);
        // Loopback delivered nothing for a second (the PC was quiet).
        repacketizer.Append(Ramp(480, 1000), 2_000_000_000, blocks);
        Assert.Equal(3, blocks.Count);
        var padded = blocks[1];
        Assert.Equal(1_010_000_000UL, padded.CaptureNanos);
        Assert.Equal(481, padded.Samples[0]);
        Assert.All(padded.Samples[240..], sample => Assert.Equal(0, sample));
        Assert.Equal(2_000_000_000UL, blocks[2].CaptureNanos);
        Assert.Equal(1000, blocks[2].Samples[0]);
        Assert.Equal(1, repacketizer.TimelineRestarts);
    }

    [Fact]
    public void ADiscontinuityFlagStartsANewTimelineEvenOnTime()
    {
        var repacketizer = new AudioRepacketizer();
        var blocks = new List<AudioBlock>();
        repacketizer.Append(Ramp(240, 1), 1_000_000_000, blocks);
        repacketizer.Append(Ramp(480, 1000), 1_005_000_000, blocks, discontinuity: true);
        Assert.Equal(2, blocks.Count);
        Assert.Equal(1_000_000_000UL, blocks[0].CaptureNanos);
        Assert.Equal(0, blocks[0].Samples[^1]); // padded
        Assert.Equal(1_005_000_000UL, blocks[1].CaptureNanos);
        Assert.Equal(1, repacketizer.TimelineRestarts);
    }

    [Fact]
    public void ResetDropsThePartialBlockWithoutCountingARestart()
    {
        var repacketizer = new AudioRepacketizer();
        var blocks = new List<AudioBlock>();
        repacketizer.Append(Ramp(400, 1), 1_000_000_000, blocks);
        repacketizer.Reset();
        repacketizer.Append(Ramp(480, 7), 9_000_000_000, blocks);
        var block = Assert.Single(blocks);
        Assert.Equal(9_000_000_000UL, block.CaptureNanos);
        Assert.Equal(7, block.Samples[0]);
        Assert.Equal(0, repacketizer.TimelineRestarts);
    }
}

public class SilenceGateTests
{
    private static AudioBlock Block(float level, int index = 0) =>
        new(Enumerable.Repeat(level, AudioFormat.SamplesPerBlock).ToArray(), (ulong)index * AudioFormat.NanosPerBlock);

    [Fact]
    public void SilenceIsSentForHalfASecondThenHeldBackUntilSoundReturns()
    {
        var gate = new SilenceGate();
        Assert.False(gate.Admit(Block(0)), "a capture starts closed: nothing to send until something plays");
        Assert.True(gate.Admit(Block(0.1f)));
        for (var i = 0; i < 50; i++) Assert.True(gate.Admit(Block(0)), $"silent block {i} is within the hangover");
        Assert.False(gate.Admit(Block(0)));
        Assert.False(gate.Admit(Block(1e-5f)), "dither under −90 dBFS is silence too");
        Assert.True(gate.IsClosed);
        Assert.Equal(1, gate.Pauses);
        Assert.True(gate.Admit(Block(-0.01f)));
        Assert.False(gate.IsClosed);
    }

    [Fact]
    public void ShortGapsStayOnOneTimeline()
    {
        var gate = new SilenceGate();
        for (var round = 0; round < 5; round++)
        {
            Assert.True(gate.Admit(Block(0.2f)));
            for (var i = 0; i < 30; i++) Assert.True(gate.Admit(Block(0)));
        }
        Assert.Equal(0, gate.Pauses);
    }
}

public class PcmConverterTests
{
    [Fact]
    public void Float48kStereoPassesThrough()
    {
        var converter = new PcmConverter(PcmFormat.Target);
        Assert.True(converter.IsPassthrough);
        var input = new float[] { 0.5f, -0.25f, 0.125f, 1f };
        var output = converter.Convert(System.Runtime.InteropServices.MemoryMarshal.AsBytes(input.AsSpan()), 2).ToArray();
        Assert.Equal(input, output);
    }

    [Fact]
    public void SixteenBitMonoGoesToBothSides()
    {
        var converter = new PcmConverter(new PcmFormat(48_000, 1, 16, IsFloat: false));
        var bytes = new byte[4];
        BinaryPrimitives.WriteInt16LittleEndian(bytes, 16_384);
        BinaryPrimitives.WriteInt16LittleEndian(bytes.AsSpan(2), -32_768);
        Assert.Equal([0.5f, 0.5f, -1f, -1f], converter.Convert(bytes, 2).ToArray());
    }

    [Fact]
    public void TwentyFourBitSamplesKeepTheirSign()
    {
        var converter = new PcmConverter(new PcmFormat(48_000, 2, 24, IsFloat: false));
        byte[] bytes = [0x00, 0x00, 0xC0, 0x00, 0x00, 0x40]; // −0.5, +0.5
        Assert.Equal([-0.5f, 0.5f], converter.Convert(bytes, 1).ToArray());
    }

    [Fact]
    public void SurroundFoldsDownWithTheCentreInBothSides()
    {
        // 5.1: FL FR FC LFE BL BR
        var converter = new PcmConverter(new PcmFormat(48_000, 6, 32, IsFloat: true));
        var frame = new float[] { 0.1f, 0.2f, 0.4f, 0.9f, 0.3f, 0f };
        var output = converter.Convert(System.Runtime.InteropServices.MemoryMarshal.AsBytes(frame.AsSpan()), 1).ToArray();
        Assert.Equal(0.1f + 0.4f * 0.70710678f + 0.3f * 0.70710678f, output[0], 5);
        Assert.Equal(0.2f + 0.4f * 0.70710678f, output[1], 5); // LFE left out
    }

    [Fact]
    public void SilentBuffersAreZerosWhateverTheyHold()
    {
        var converter = new PcmConverter(new PcmFormat(44_100, 2, 16, IsFloat: false));
        var output = converter.Convert([], 441, silent: true);
        Assert.InRange(output.Length / 2, 478, 482);
        Assert.All(output.ToArray(), sample => Assert.Equal(0, sample));
    }

    [Fact]
    public void ResamplingFrom44100KeepsATonesShapeAcrossBuffers()
    {
        // A 1 kHz tone at 44.1 kHz in uneven buffers comes out as the same tone at 48 kHz.
        var converter = new PcmConverter(new PcmFormat(44_100, 2, 32, IsFloat: true));
        var output = new List<float>();
        var frame = 0;
        foreach (var size in Enumerable.Repeat(new[] { 441, 100, 1000, 7 }, 10).SelectMany(sizes => sizes))
        {
            var input = new float[size * 2];
            for (var i = 0; i < size; i++)
            {
                var value = (float)Math.Sin(2 * Math.PI * 1000 * (frame + i) / 44_100.0);
                input[i * 2] = value;
                input[i * 2 + 1] = -value;
            }
            frame += size;
            output.AddRange(converter.Convert(System.Runtime.InteropServices.MemoryMarshal.AsBytes(input.AsSpan()), size).ToArray());
        }
        var outFrames = output.Count / 2;
        Assert.InRange(outFrames, frame * 48_000 / 44_100 - 2, frame * 48_000 / 44_100 + 1);
        var worst = 0.0;
        for (var i = 0; i < outFrames; i++)
        {
            var expected = Math.Sin(2 * Math.PI * 1000 * i / 48_000.0);
            worst = Math.Max(worst, Math.Abs(output[i * 2] - expected));
            Assert.Equal(-output[i * 2], output[i * 2 + 1]);
        }
        Assert.True(worst < 0.01, $"linear interpolation of a 1 kHz tone stays within 1 % (worst {worst:0.0000})");
    }
}

public class AudioEncodingTests
{
    [Fact]
    public void AudioPacketIsTheMacsLayout()
    {
        var packet = new AudioPacket { Sequence = 0x0102030405060708, CaptureNanos = 0x1112131415161718, FrameCount = 480, Data = new byte[] { 0xAA, 0xBB } };
        var frame = MessageCodec.EncodeFrame(packet);
        var header = Frame.ReadHeader(frame);
        Assert.Equal((byte)MessageKind.AudioPacket, header.RawKind);
        Assert.Equal(20u, header.Length);
        Assert.Equal(new byte[]
        {
            0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01, // sequence u64 LE
            0x18, 0x17, 0x16, 0x15, 0x14, 0x13, 0x12, 0x11, // captureNanos u64 LE
            0xE0, 0x01,                                     // frameCount u16 LE (480)
            0xAA, 0xBB,                                     // opus
        }, frame[Frame.HeaderLength..]);
        var decoded = Assert.IsType<AudioPacket>(MessageCodec.Decode(MessageKind.AudioPacket, frame.AsMemory(Frame.HeaderLength)));
        Assert.Equal(packet.Sequence, decoded.Sequence);
        Assert.Equal(packet.CaptureNanos, decoded.CaptureNanos);
        Assert.Equal(packet.Data.ToArray(), decoded.Data.ToArray());
    }

    [Fact]
    public void AudioConfigUsesTheMacsKeys()
    {
        var json = System.Text.Encoding.UTF8.GetString(MessageCodec.EncodePayload(AudioConfig.Streaming()));
        Assert.Equal("""{"codec":"opus","sampleRate":48000,"channels":2,"framesPerPacket":480,"bitrate":128000}""", json);
        var unavailable = System.Text.Encoding.UTF8.GetString(MessageCodec.EncodePayload(AudioConfig.UnavailableBecause("No audio device")));
        Assert.Contains("\"unavailable\":\"No audio device\"", unavailable);
    }

    [Fact]
    public void OpusPacketsDecodeBackToTheChime()
    {
        var encoder = new OpusBlockEncoder();
        var blocks = OpusCheck.ChimeBlocks(100); // the first second: both notes
        var packets = blocks.Select(block => encoder.Encode(block.Samples)).ToList();
        Assert.All(packets, packet => Assert.InRange(packet.Length, 1, 1275));
        var decoded = OpusCheck.Decode(packets);
        Assert.Equal(100 * AudioFormat.SamplesPerBlock, decoded.Length);
        var original = blocks.SelectMany(block => block.Samples).ToArray();
        var ratio = OpusCheck.Rms(decoded) / OpusCheck.Rms(original);
        Assert.InRange(ratio, 0.8, 1.2);
        Assert.True(decoded.Max() <= ChimeSynth.Peak * 1.1f, "still about −18 dBFS");
    }

    [Fact]
    public async Task EncoderNumbersPacketsAndHoldsBackSilence()
    {
        var packets = new List<AudioPacket>();
        var encoder = new AudioStreamEncoder(packet => { lock (packets) packets.Add(packet); }, NullLogger.Instance);
        var blocks = OpusCheck.ChimeBlocks(60);
        for (var i = 0; i < 100; i++)
            blocks.Add(new AudioBlock(new float[AudioFormat.SamplesPerBlock], blocks[^1].CaptureNanos + AudioFormat.NanosPerBlock));
        blocks.AddRange(OpusCheck.ChimeBlocks(10, startNanos: blocks[^1].CaptureNanos + AudioFormat.NanosPerBlock));
        for (var i = 0; i < blocks.Count; i++)
        {
            encoder.Enqueue(blocks[i]);
            // Real capture delivers 100 a second; don't outrun the queue (it drops the oldest past 50).
            while (encoder.BlocksTaken < i - 20) await Task.Delay(1);
        }
        await encoder.DisposeAsync();

        // 60 chime blocks, 50 of the 100 silent ones (the hangover), then the 10 after the pause.
        Assert.Equal(120, packets.Count);
        Assert.Equal(Enumerable.Range(0, 120).Select(i => (ulong)i), packets.Select(packet => packet.Sequence));
        Assert.All(packets, packet => Assert.Equal(480, packet.FrameCount));
        Assert.Equal(blocks[109].CaptureNanos, packets[109].CaptureNanos);
        Assert.Equal(blocks[160].CaptureNanos, packets[110].CaptureNanos); // captureNanos jumps 0.5 s: the client's pause
        Assert.Equal(120, encoder.PacketsSent);
    }
}

public class FramedConnectionAudioTests
{
    [Fact]
    public async Task AudioRidesTheControlLaneAndAStalledSocketDropsItInsteadOfPilingUp()
    {
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var accept = listener.AcceptSocketAsync();
        var client = await FramedConnection.ConnectAsync("127.0.0.1", ((IPEndPoint)listener.LocalEndpoint).Port);
        // Not started yet: nothing is written, as if the socket were stalled.
        var host = new FramedConnection(await accept, new FramedConnectionOptions { MaxQueuedAudioPackets = 2 });
        AudioPacket Packet(ulong sequence) => new() { Sequence = sequence, CaptureNanos = sequence * 10_000_000, FrameCount = 480, Data = new byte[] { 1 } };
        Assert.True(host.PostAudio(Packet(0)));
        Assert.True(host.PostAudio(Packet(1)));
        Assert.False(host.PostAudio(Packet(2)));
        host.PostVideo(new VideoFrame { Sequence = 0, CaptureNanos = 0, IsKeyframe = true, Width = 16, Height = 16, Data = new byte[64] }, droppable: false);
        host.Start();
        Assert.Equal(0UL, (await Loopback.Next<AudioPacket>(client)).Sequence);
        Assert.Equal(1UL, (await Loopback.Next<AudioPacket>(client)).Sequence);
        await Loopback.Next<VideoFrame>(client);
        Assert.True(host.PostAudio(Packet(3)));
        Assert.Equal(3UL, (await Loopback.Next<AudioPacket>(client)).Sequence);
        host.Close();
        client.Close();
    }
}

/// <summary>The synthetic chime, counting starts and stops, failing or stopping on demand.</summary>
internal sealed class FakeAudioSource(string? unavailable = null, string? startFails = null) : IAudioSource
{
    private readonly SyntheticAudioSource _chime = new();
    public int Starts;
    public int Stops;
    public Action<string>? StopOnItsOwn;

    public string? UnavailableReason => unavailable;

    public async Task<IAudioCapture> StartAsync(Action<AudioBlock> onBlock, Action<string> onStopped, CancellationToken cancellationToken)
    {
        Interlocked.Increment(ref Starts);
        if (startFails is not null) throw new AudioUnavailableException(startFails);
        StopOnItsOwn = onStopped;
        return new Counted(await _chime.StartAsync(onBlock, onStopped, cancellationToken), this);
    }

    private sealed class Counted(IAudioCapture inner, FakeAudioSource owner) : IAudioCapture
    {
        public string Description => "fake " + inner.Description;

        public async ValueTask DisposeAsync()
        {
            await inner.DisposeAsync();
            Interlocked.Increment(ref owner.Stops);
        }
    }
}

public class AudioSessionTests
{
    private static async Task<bool> EventuallyAsync(Func<bool> condition, double seconds = 5)
    {
        var until = DateTime.UtcNow.AddSeconds(seconds);
        while (DateTime.UtcNow < until)
        {
            if (condition()) return true;
            await Task.Delay(20);
        }
        return condition();
    }

    [Fact]
    public async Task AskedForSoundTheHostSendsConfigThenTenMillisecondPacketsUntilTold()
    {
        var audio = new FakeAudioSource();
        await using var host = new TestHost(audio: audio);
        var (connection, _, result) = await new TestClient().ConnectAsync(host.Port, "246810", macAudio: true);
        Assert.True(result.Capabilities!.Audio);
        await connection.SendAsync(new AudioRequest { Enabled = true });

        var config = await Loopback.Next<AudioConfig>(connection);
        Assert.Equal(AudioConfig.Streaming(), config);
        var packets = new List<AudioPacket>();
        while (packets.Count < 50) packets.Add(await Loopback.Next<AudioPacket>(connection));
        Assert.Equal(Enumerable.Range(0, 50).Select(i => (ulong)i), packets.Select(packet => packet.Sequence));
        for (var i = 1; i < packets.Count; i++) Assert.Equal(10_000_000UL, packets[i].CaptureNanos - packets[i - 1].CaptureNanos);
        Assert.True(OpusCheck.Rms(OpusCheck.Decode(packets.Select(packet => packet.Data.ToArray()))) > 0.01, "the chime is audible");

        await connection.SendAsync(new AudioRequest { Enabled = false });
        Assert.True(await EventuallyAsync(() => audio.Stops == 1));
        await connection.SendAsync(new AudioRequest { Enabled = true });
        Assert.Equal(AudioConfig.Streaming(), await Loopback.Next<AudioConfig>(connection));
        Assert.Equal(0UL, (await Loopback.Next<AudioPacket>(connection)).Sequence); // a new stream counts from 0
        connection.Close();
        Assert.True(await EventuallyAsync(() => audio.Stops == 2), "a disconnect stops capture");
        Assert.Equal(2, audio.Starts);
    }

    [Fact]
    public async Task AClientThatNeverSaidMacAudioIsNeverSentAudioKinds()
    {
        var audio = new FakeAudioSource();
        await using var host = new TestHost(audio: audio);
        var (connection, _, result) = await new TestClient().ConnectAsync(host.Port, "246810");
        Assert.True(result.Capabilities!.Audio); // offered to everyone, like the Mac
        await connection.SendAsync(new AudioRequest { Enabled = true });
        await connection.SendAsync(new Ping { SentAtNanos = 42 });
        // The pong comes after anything the request could have produced, on the same lane.
        using var limit = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        while (await connection.ReceiveAsync(limit.Token) is { } message)
        {
            Assert.IsNotType<AudioConfig>(message);
            Assert.IsNotType<AudioPacket>(message);
            if (message is Pong) break;
        }
        await Task.Delay(200);
        Assert.Equal(0, audio.Starts);
        connection.Close();
    }

    [Fact]
    public async Task NoCapabilityWithoutASourceThatCanCapture()
    {
        await using (var host = new TestHost(audio: new FakeAudioSource(unavailable: "This PC has no sound output device.")))
        {
            var (connection, _, result) = await new TestClient().ConnectAsync(host.Port, "246810", macAudio: true);
            Assert.Null(result.Capabilities!.Audio);
            connection.Close();
        }
        await using (var host = new TestHost())
        {
            var (connection, _, result) = await new TestClient().ConnectAsync(host.Port, "246810", macAudio: true);
            Assert.Null(result.Capabilities!.Audio);
            connection.Close();
        }
    }

    [Fact]
    public async Task AFailedStartAndACaptureThatStopsAreExplained()
    {
        await using (var host = new TestHost(audio: new FakeAudioSource(startFails: "No audio device")))
        {
            var (connection, _, _) = await new TestClient().ConnectAsync(host.Port, "246810", macAudio: true);
            await connection.SendAsync(new AudioRequest { Enabled = true });
            Assert.Null((await Loopback.Next<AudioConfig>(connection)).Unavailable); // the format, then why it didn't start
            Assert.Equal("No audio device", (await Loopback.Next<AudioConfig>(connection)).Unavailable);
            connection.Close();
        }

        var audio = new FakeAudioSource();
        await using (var host = new TestHost(audio: audio))
        {
            var (connection, _, _) = await new TestClient().ConnectAsync(host.Port, "246810", macAudio: true);
            await connection.SendAsync(new AudioRequest { Enabled = true });
            await Loopback.Next<AudioPacket>(connection);
            audio.StopOnItsOwn!("The PC stopped sending its sound (the output device went away)");
            Assert.Equal("The PC stopped sending its sound (the output device went away)", (await Loopback.Next<AudioConfig>(connection)).Unavailable);
            Assert.True(await EventuallyAsync(() => audio.Stops == 1));
            connection.Close();
        }
    }
}
