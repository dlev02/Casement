using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Vantage.Protocol.Messages;
using Vantage.Protocol.Wire;

namespace Vantage.Protocol.Tests;

public class FrameTests
{
    [Fact]
    public void HeaderIsMagicKindFlagsLengthLittleEndian()
    {
        var frame = Frame.Encode(MessageKind.Ping, [1, 2, 3]);
        Assert.Equal(new byte[] { 0x56, 50, 0, 0, 3, 0, 0, 0, 1, 2, 3 }, frame);
        var header = Frame.ReadHeader(frame);
        Assert.Equal(MessageKind.Ping, header.Kind);
        Assert.Equal(3u, header.Length);
    }

    [Fact]
    public void BadMagicAndOversizedPayloadAreRejected()
    {
        Assert.Equal(FrameError.BadMagic, Assert.Throws<FrameException>(() => Frame.ReadHeader([0x57, 1, 0, 0, 0, 0, 0, 0])).Error);
        Span<byte> big = stackalloc byte[8];
        Frame.WriteHeader(big, 1, Frame.MaxPayloadLength + 1);
        var copy = big.ToArray();
        Assert.Equal(FrameError.PayloadTooLarge, Assert.Throws<FrameException>(() => Frame.ReadHeader(copy)).Error);
    }

    [Fact]
    public void UnknownKindIsReadableSoItCanBeSkipped()
    {
        var header = Frame.ReadHeader([0x56, 99, 0, 0, 4, 0, 0, 0]);
        Assert.False(header.IsKnownKind);
        Assert.Equal(4u, header.Length);
    }

    [Fact]
    public void RequestKeyframeHasAnEmptyPayload()
    {
        var frame = MessageCodec.EncodeFrame(RequestKeyframe.Instance);
        Assert.Equal(new byte[] { 0x56, 21, 0, 0, 0, 0, 0, 0 }, frame);
        Assert.Same(RequestKeyframe.Instance, MessageCodec.Decode(MessageKind.RequestKeyframe, ReadOnlyMemory<byte>.Empty));
    }
}

public class JsonTests
{
    private static JsonObject Json(IMessage message) =>
        JsonNode.Parse(MessageCodec.EncodePayload(message))!.AsObject();

    [Fact]
    public void DisplaySelectionUsesSwiftAssociatedValueCoding()
    {
        var byId = new SelectDisplay { Selection = new DisplaySelection.Display(3), TargetFPS = 60, Quality = QualityPreset.Auto };
        Assert.Equal("""{"display":{"_0":3}}""", Json(byId)["selection"]!.ToJsonString());

        const string fromSwift = """{"selection":{"fitViewport":{"_0":{"widthPoints":1210,"heightPoints":834,"scale":2}}},"targetFPS":60,"quality":"auto","preferredCodec":"hevc","useVirtualDisplay":false}""";
        var decoded = Assert.IsType<SelectDisplay>(MessageCodec.Decode(MessageKind.SelectDisplay, Encoding.UTF8.GetBytes(fromSwift)));
        var fit = Assert.IsType<DisplaySelection.FitViewport>(decoded.Selection);
        Assert.Equal(1210, fit.Viewport.WidthPoints);
        Assert.Equal(VideoCodec.Hevc, decoded.PreferredCodec);
        Assert.False(decoded.UseVirtualDisplay);
    }

    [Fact]
    public void OptionalsAreOmittedAndKeysAreSwiftNames()
    {
        var result = new AuthResult { Status = AuthStatus.PairingRequired, Message = "Enter the pairing code shown on the PC" };
        var json = Json(result);
        Assert.Equal(["status", "message"], json.Select(p => p.Key));
        Assert.Equal("pairingRequired", (string?)json["status"]);

        var caps = new HostCapabilities { Codecs = [VideoCodec.H264], CanManageVirtualDisplay = false, Clipboard = true, MaxFPS = 60, Platform = HostPlatforms.Windows };
        Assert.Equal("""{"codecs":["h264"],"canManageVirtualDisplay":false,"clipboard":true,"maxFPS":60,"platform":"windows"}""",
                     Encoding.UTF8.GetString(JsonSerializer.SerializeToUtf8Bytes(caps, VantageJsonContext.Wire.HostCapabilities)));
    }

    [Fact]
    public void MissingRequiredKeyOrNullIsRejectedLikeSwift()
    {
        Assert.ThrowsAny<JsonException>(() => MessageCodec.Decode(MessageKind.FileAccept, Encoding.UTF8.GetBytes("""{"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F"}""")));
        Assert.ThrowsAny<JsonException>(() => MessageCodec.Decode(MessageKind.TextInput, Encoding.UTF8.GetBytes("""{"text":null}""")));
        Assert.ThrowsAny<JsonException>(() => MessageCodec.Decode(MessageKind.Ping, Encoding.UTF8.GetBytes("""{"sentAtNanos":1.5}""")));
        Assert.ThrowsAny<JsonException>(() => MessageCodec.Decode(MessageKind.HostCommand, Encoding.UTF8.GetBytes("""{"command":"reboot"}""")));
    }

    [Fact]
    public void UnknownKeysAreIgnored()
    {
        var ping = Assert.IsType<Ping>(MessageCodec.Decode(MessageKind.Ping, Encoding.UTF8.GetBytes("""{"sentAtNanos":5,"future":true}""")));
        Assert.Equal(5ul, ping.SentAtNanos);
    }

    [Fact]
    public void PingNanosAbove2To53SurviveExactly()
    {
        const ulong nanos = 9_007_199_254_740_993; // 2^53 + 1
        var ping = Assert.IsType<Ping>(MessageCodec.Decode(MessageKind.Ping, Encoding.UTF8.GetBytes($$"""{"sentAtNanos":{{nanos}}}""")));
        Assert.Equal(nanos, ping.SentAtNanos);
        Assert.Equal($$"""{"echoNanos":{{nanos}}}""", Encoding.UTF8.GetString(MessageCodec.EncodePayload(new Pong { EchoNanos = ping.SentAtNanos })));
    }

    [Fact]
    public void UuidsAreUppercaseAndDatesAreAppleReferenceSeconds()
    {
        var id = Guid.Parse("e621e1f8-c36c-495a-93fc-0c247a3e6e5f");
        var offer = new FileOffer
        {
            Id = id,
            Name = "Report.pdf",
            ByteCount = 42,
            Modified = new DateTimeOffset(2001, 1, 1, 0, 1, 0, TimeSpan.Zero).AddMilliseconds(500),
        };
        var json = Json(offer);
        Assert.Equal("E621E1F8-C36C-495A-93FC-0C247A3E6E5F", (string?)json["id"]);
        Assert.Equal(60.5, (double)json["modified"]!);
        Assert.Null(json["uti"]);

        var back = Assert.IsType<FileOffer>(MessageCodec.Decode(MessageKind.FileOffer, MessageCodec.EncodePayload(offer)));
        Assert.Equal(offer.Modified, back.Modified);
        Assert.Equal(id, back.Id);
    }

    [Fact]
    public void KeyModifiersAreAPlainNumber()
    {
        var state = new ModifierState { Modifiers = KeyModifiers.Shift | KeyModifiers.Command };
        Assert.Equal("""{"modifiers":18}""", Encoding.UTF8.GetString(MessageCodec.EncodePayload(state)));
    }

    [Fact]
    public void DataIsPaddedBase64AndSwiftEscapedSlashesDecode()
    {
        var token = new AttachMedia { SessionToken = [0xFB, 0xFF, 0xBF, 0x01] };
        Assert.Equal("""{"sessionToken":"+/+/AQ=="}""", Encoding.UTF8.GetString(MessageCodec.EncodePayload(token)));
        var fromSwift = Assert.IsType<AttachMedia>(MessageCodec.Decode(MessageKind.AttachMedia, Encoding.UTF8.GetBytes("""{"sessionToken":"+\/+\/AQ=="}""")));
        Assert.Equal(token.SessionToken, fromSwift.SessionToken);
    }
}

public class BinaryTests
{
    [Fact]
    public void LayoutsHaveTheSpecSizes()
    {
        Assert.Equal(15, MessageCodec.EncodePayload(new PointerEvent { Action = PointerAction.Down, X = 1, Y = 2 }).Length);
        Assert.Equal(31, MessageCodec.EncodePayload(new ScrollEvent { Phase = ScrollPhase.Changed, IsContinuous = true, DeltaX = 0, DeltaY = 1, X = 0, Y = 0 }).Length);
        Assert.Equal(8, MessageCodec.EncodePayload(new KeyEvent { KeyCode = 0x31, IsDown = true }).Length);
        Assert.Equal(25 + 3, MessageCodec.EncodePayload(new VideoFrame { Sequence = 1, CaptureNanos = 2, IsKeyframe = true, Width = 4, Height = 6, Data = new byte[] { 0, 0, 1 } }).Length);
    }

    [Fact]
    public void FileChunkIdIsRfcByteOrder()
    {
        var chunk = new FileChunk { ToHost = false, Id = Guid.Parse("00112233-4455-6677-8899-AABBCCDDEEFF"), Offset = 0x0102, Data = new byte[] { 9 } };
        var payload = MessageCodec.EncodePayload(chunk);
        Assert.Equal(Convert.FromHexString("00112233445566778899AABBCCDDEEFF" + "0201000000000000" + "09"), payload);
        var back = Assert.IsType<FileChunk>(MessageCodec.Decode(MessageKind.FileChunkToClient, payload));
        Assert.Equal(chunk.Id, back.Id);
        Assert.Equal(0x0102ul, back.Offset);
        Assert.Equal(MessageKind.FileChunkToClient, back.Kind);
    }

    [Fact]
    public void TruncationAndUnknownEnumBytesThrowButTrailingBytesAreIgnored()
    {
        var key = MessageCodec.EncodePayload(new KeyEvent { KeyCode = 0x24, IsDown = true, Modifiers = KeyModifiers.Control });
        Assert.Throws<WireFormatException>(() => MessageCodec.Decode(MessageKind.KeyEvent, key.AsMemory(0, 7)));
        var withExtra = key.Concat(new byte[] { 0xAA, 0xBB }).ToArray();
        var decoded = Assert.IsType<KeyEvent>(MessageCodec.Decode(MessageKind.KeyEvent, withExtra));
        Assert.Equal(KeyModifiers.Control, decoded.Modifiers);

        var pointer = MessageCodec.EncodePayload(new PointerEvent { Action = PointerAction.Move, X = 0, Y = 0 });
        pointer[0] = 7;
        Assert.Throws<WireFormatException>(() => MessageCodec.Decode(MessageKind.PointerEvent, pointer));
    }
}
