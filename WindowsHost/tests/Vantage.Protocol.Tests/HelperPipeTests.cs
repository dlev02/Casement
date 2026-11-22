using Vantage.Protocol.DesktopHelper;
using Vantage.Protocol.Input;
using Xunit;

namespace Vantage.Protocol.Tests;

/// <summary>The host ↔ SYSTEM helper pipe: every message survives the trip, and a big frame splits and reassembles.</summary>
public sealed class HelperPipeTests
{
    [Fact]
    public async Task EveryMessageRoundTripsAndGarbageIsRefused()
    {
        HelperMessage[] messages =
        [
            new HelperHello(HelperPipe.Version, [1, 2, 3, 4]),
            new HelperWelcome(HelperPipe.Version, "1.8", Enumerable.Range(0, 64).Select(i => (byte)i).ToArray()),
            new HelperStartCapture(@"\\.\DISPLAY1", 30),
            new HelperStopCapture(),
            new HelperInput([
                InputAction.MoveTo(-1920, 1079),
                InputAction.MouseButtonAt(MouseButton.Forward, true, 5, 6),
                InputAction.VerticalWheel(-120),
                InputAction.KeyScan(0x1D, extended: true, isDown: false),
                InputAction.UnicodeUnit('é', isDown: true),
            ]),
            new HelperDesktop(HelperDesktopKind.Secure),
            new HelperFrame(4, 2, 123_456_789, [new HelperFrameStrip(1, 1, 2, 1, [1, 2, 3, 4, 5, 6, 7, 8])], IsLastPart: false),
            new HelperCaptureStopped("access lost"),
        ];

        using var stream = new MemoryStream();
        foreach (var message in messages) stream.Write(HelperCodec.Encode(message));
        stream.Position = 0;
        foreach (var expected in messages)
        {
            var actual = await HelperCodec.ReadAsync(stream, CancellationToken.None);
            Assert.Equal(HelperCodec.Encode(expected), HelperCodec.Encode(actual!));
        }
        Assert.Null(await HelperCodec.ReadAsync(stream, CancellationToken.None));

        // A strip outside the frame, an unknown kind, and a truncated message are refused.
        var outside = HelperCodec.Encode(new HelperFrame(4, 2, 0, [new HelperFrameStrip(3, 0, 2, 1, new byte[8])]));
        Assert.Throws<InvalidDataException>(() => HelperCodec.Decode(HelperMessageKind.Frame, outside[5..]));
        Assert.Throws<InvalidDataException>(() => HelperCodec.Decode((HelperMessageKind)77, []));
        var cut = HelperCodec.Encode(new HelperCaptureStopped("gone"));
        await Assert.ThrowsAsync<InvalidDataException>(() => HelperCodec.ReadAsync(new MemoryStream(cut[..^1]), CancellationToken.None));
    }

    [Fact]
    public void ABigFrameSplitsIntoBandsAndOnlyTheLastPartCompletesIt()
    {
        const int width = 10, height = 7;
        var pixels = Enumerable.Range(0, width * height * 4).Select(i => (byte)i).ToArray();
        var frame = new HelperFrame(width, height, 9, [new HelperFrameStrip(0, 0, width, height, pixels), new HelperFrameStrip(2, 3, 1, 1, [9, 9, 9, 9])]);

        var parts = HelperFrames.Split(frame, maxBytes: width * 4 * 3).ToList(); // three rows a message

        Assert.All(parts, part => Assert.True(part.Strips.Sum(s => s.Pixels.Length) <= width * 4 * 3));
        Assert.Equal([false, false, true], parts.Select(p => p.IsLastPart));
        var painted = new byte[width * height * 4];
        foreach (var strip in parts.SelectMany(p => p.Strips).Take(3))
            strip.Pixels.CopyTo(painted, strip.Y * width * 4);
        Assert.Equal(pixels, painted);
        Assert.Equal(new HelperFrameStrip(2, 3, 1, 1, [9, 9, 9, 9]).Pixels, parts[^1].Strips[^1].Pixels);
    }
}
