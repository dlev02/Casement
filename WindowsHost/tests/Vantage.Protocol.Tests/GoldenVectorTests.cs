using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Vantage.Protocol.Messages;
using Vantage.Protocol.Wire;

namespace Vantage.Protocol.Tests;

/// <summary>
/// Wire vectors shared with the Swift side (<c>Packages/VantageCore/Tests/VantageCoreTests/WireGoldenVectorTests.swift</c>,
/// which defines the same messages under the same names). Each side writes its frames to
/// <c>tests/golden/&lt;side&gt;/&lt;name&gt;.frame</c> when <c>VANTAGE_WRITE_GOLDEN=1</c>, and always decodes
/// the other side's: JSON must match key for key and value for value, binary byte for byte.
/// </summary>
public class GoldenVectorTests
{
    private static readonly Guid Id = Guid.Parse("E621E1F8-C36C-495A-93FC-0C247A3E6E5F");
    private static readonly byte[] Key32 = [.. Enumerable.Range(1, 32).Select(i => (byte)i)];
    private static readonly byte[] Signature64 = [.. Enumerable.Range(0, 64).Select(i => (byte)(255 - i))];
    private static readonly byte[] Token = [.. Enumerable.Range(0, 32).Select(i => (byte)(i * 7))];
    private static readonly DisplayInfo Display = new()
    {
        Id = 1, Name = "DELL U2723QE", PixelWidth = 3840, PixelHeight = 2160, PointWidth = 2560, PointHeight = 1440, Scale = 1.5,
        OriginX = -3840, OriginY = 0, IsMain = true, IsBuiltIn = false, IsVirtual = false, RefreshRate = 59.94,
    };

    /// <summary>The shared vectors. Keep in step with the Swift list.</summary>
    public static readonly IReadOnlyList<(string Name, IMessage Message)> Vectors =
    [
        ("hello", new Hello
        {
            ProtocolVersion = 2, ClientName = "iPad", DeviceModel = "iPad16,6", AppVersion = "1.0", ClientPublicKey = Key32,
            SupportedCodecs = [VideoCodec.Hevc, VideoCodec.H264], MaxDecodeWidth = 4096, MaxDecodeHeight = 2304,
            Viewport = new Viewport { WidthPoints = 1210, HeightPoints = 834, Scale = 2 },
            Features = new ClientFeatures { Dictation = true, MacAudio = true, FileTransfer = true },
        }),
        ("helloFilesOnly", new Hello
        {
            ProtocolVersion = 2, ClientName = "iPad", DeviceModel = "iPad16,6", AppVersion = "1.0", ClientPublicKey = Key32,
            SupportedCodecs = [], MaxDecodeWidth = 0, MaxDecodeHeight = 0, IsReadinessProbe = false,
            Features = new ClientFeatures { FileTransfer = true, FilesOnly = true },
        }),
        ("challenge", new Challenge
        {
            HostName = "DREW-PC", HostVersion = "1.0", HostPublicKey = Key32, Nonce = Token, IsPaired = false,
            PeerTailnetName = "drew@example.com", HostPlatform = "windows",
        }),
        ("authenticate", new Authenticate { Signature = Signature64, PairingCode = "024680" }),
        ("authResultOk", new AuthResult
        {
            Status = AuthStatus.Ok, SessionToken = Token, Displays = [Display],
            Capabilities = new HostCapabilities
            {
                Codecs = [VideoCodec.H264], CanManageVirtualDisplay = false, Clipboard = true, MaxFPS = 60,
                FileTransfer = true, FilesOnlySessions = true, Platform = "windows",
            },
        }),
        ("authResultPairing", new AuthResult { Status = AuthStatus.PairingRequired, Message = "Enter the pairing code shown on the PC" }),
        ("authResultProbe", new AuthResult { Status = AuthStatus.Ok, Readiness = new HostReadiness { ScreenRecordingGranted = true, AccessibilityGranted = true } }),
        ("displayList", new DisplayList { Displays = [Display] }),
        ("selectDisplayFit", new SelectDisplay
        {
            Selection = new DisplaySelection.FitViewport(new Viewport { WidthPoints = 1210, HeightPoints = 834, Scale = 2 }),
            TargetFPS = 60, Quality = QualityPreset.Auto, PreferredCodec = VideoCodec.Hevc, UseVirtualDisplay = false,
        }),
        ("selectDisplayId", new SelectDisplay { Selection = new DisplaySelection.Display(3), TargetFPS = 30, Quality = QualityPreset.Text }),
        ("streamConfig", new StreamConfig { Display = Display, Codec = VideoCodec.H264, Fps = 60, BitrateKbps = 39_813 }),
        ("viewportChanged", new ViewportChanged { Viewport = new Viewport { WidthPoints = 1366, HeightPoints = 1024, Scale = 2 } }),
        ("qualityFeedback", new QualityFeedback
        {
            RttMillis = 12.5, DecodeMillis = 3.25, FramesReceived = 15, FramesDropped = 1, QueueDepth = 0,
            BytesReceived = 9_007_199_254_740_993, WindowSeconds = 0.25,
        }),
        ("requestKeyframe", RequestKeyframe.Instance),
        ("clipboard", new ClipboardPayload { Text = "Line one\nLíne two ✓", ImagePNG = [0x89, 0x50, 0x4E, 0x47, 0xFF, 0xFE], Rtf = Encoding.UTF8.GetBytes("{\\rtf1 hi}") }),
        ("hostCommand", new HostCommandMessage { Command = HostCommand.SleepDisplay }),
        ("ping", new Ping { SentAtNanos = 18_446_744_073_709_551_615 }),
        ("pong", new Pong { EchoNanos = 9_007_199_254_740_993 }),
        ("disconnect", new DisconnectMessage { Reason = "The PC ended the session." }),
        ("attachMedia", new AttachMedia { SessionToken = Token }),
        ("textInput", new TextInput { Text = "héllo\n\t😀" }),
        ("videoConfig", new VideoConfig
        {
            Codec = VideoCodec.H264, Width = 1600, Height = 1000, ParameterSets = [[0x67, 0x64, 0x00, 0x28, 0xAC], [0x68, 0xEE, 0x3C, 0xB0]],
            NalLengthSize = 4, Fps = 60,
        }),
        ("hostStatus", new HostStatus
        {
            IsScreenLocked = true, IsSecureInputActive = false, InputPath = HostInputPath.Native, Message = "The PC is locked",
            IsDisplayAsleep = false, IsScreenUnavailable = false,
        }),
        ("fileOffer", new FileOffer
        {
            Id = Id, Name = "Quarterly Report.pdf", ByteCount = 70_000_000_000,
            Modified = AppleReferenceDateJsonConverter.FromAppleSeconds(780_000_000.5), Uti = "com.adobe.pdf",
        }),
        ("fileAccept", new FileAccept { Id = Id, ResumeOffset = 1_048_576 }),
        ("fileAcceptRejected", new FileAccept { Id = Id, ResumeOffset = 0, Rejected = "There isn't enough free space for it." }),
        ("fileComplete", new FileComplete { Id = Id, Sha256 = Key32 }),
        ("fileResultOk", new FileResult { Id = Id, Ok = true, SavedName = "Quarterly Report 2.pdf" }),
        ("fileResultError", new FileResult { Id = Id, Ok = false, Error = "The file arrived damaged. Try sending it again." }),
        ("fileCancel", new FileCancel { Id = Id }),
        ("videoFrame", new VideoFrame
        {
            Sequence = 42, CaptureNanos = 123_456_789_012, IsKeyframe = true, Width = 1600, Height = 1000,
            Data = new byte[] { 0, 0, 0, 5, 0x65, 0x88, 0x84, 0x00, 0x21 },
        }),
        ("pointerEvent", new PointerEvent { Action = PointerAction.Down, Button = PointerButton.Right, X = 400.5f, Y = 250.25f, ClickCount = 2, Modifiers = KeyModifiers.Shift | KeyModifiers.Command }),
        ("scrollEvent", new ScrollEvent
        {
            Phase = ScrollPhase.Ended, Momentum = MomentumPhase.None, IsContinuous = true, DeltaX = -1.5f, DeltaY = 12.75f, X = 100, Y = 200,
            VelocityX = -30, VelocityY = 640.5f, Modifiers = KeyModifiers.Control,
        }),
        ("keyEvent", new KeyEvent { KeyCode = 0x7E, IsDown = true, Modifiers = KeyModifiers.Control | KeyModifiers.Function, IsRepeat = true }),
        ("fileChunkToClient", new FileChunk { ToHost = false, Id = Id, Offset = 262_144, Data = new byte[] { 1, 2, 3, 4, 5 } }),
        ("fileChunkToHost", new FileChunk { ToHost = true, Id = Id, Offset = 0x0102_0304_0506_0708, Data = new byte[] { 0xFF } }),
    ];

    public static TheoryData<string> Names => [.. Vectors.Select(v => v.Name)];

    internal static string GoldenDirectory()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null && !Directory.Exists(Path.Combine(directory.FullName, "tests", "golden")))
            directory = directory.Parent;
        return Path.Combine(directory!.FullName, "tests", "golden");
    }

    [Theory]
    [MemberData(nameof(Names))]
    public void CSharpVectorsAreCommittedAndStable(string name)
    {
        var message = Vectors.Single(v => v.Name == name).Message;
        var frame = MessageCodec.EncodeFrame(message);
        var path = Path.Combine(GoldenDirectory(), "csharp", name + ".frame");
        if (Environment.GetEnvironmentVariable("VANTAGE_WRITE_GOLDEN") == "1")
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllBytes(path, frame);
        }
        Assert.Equal(frame, File.ReadAllBytes(path));
    }

    [Theory]
    [MemberData(nameof(Names))]
    public void SwiftVectorsDecodeToTheSameMessage(string name)
    {
        var expected = Vectors.Single(v => v.Name == name).Message;
        var swift = File.ReadAllBytes(Path.Combine(GoldenDirectory(), "swift", name + ".frame"));
        var header = Frame.ReadHeader(swift);
        Assert.Equal(expected.Kind, header.Kind);
        Assert.Equal(swift.Length - Frame.HeaderLength, (int)header.Length);
        var payload = swift.AsMemory(Frame.HeaderLength);
        var decoded = MessageCodec.Decode(header.Kind, payload);
        var ours = MessageCodec.EncodePayload(expected);
        if (expected.Kind.IsBinary())
        {
            Assert.Equal(ours, payload.ToArray());
            Assert.Equal(ours, MessageCodec.EncodePayload(decoded));
        }
        else
        {
            // Swift's bytes as sent (escaped slashes, its key order) mean the same JSON as ours…
            Assert.Equal(Canonical(ours), Canonical(payload.ToArray()));
            // …and survive a round trip through the C# types unchanged.
            Assert.Equal(Canonical(ours), Canonical(MessageCodec.EncodePayload(decoded)));
        }
    }

    /// <summary>Sorted keys, numbers by value, strings unescaped: two encodings of the same JSON compare equal.</summary>
    internal static string Canonical(byte[] json)
    {
        if (json.Length == 0) return "";
        var builder = new StringBuilder();
        Write(JsonNode.Parse(json));
        return builder.ToString();

        void Write(JsonNode? node)
        {
            switch (node)
            {
                case null:
                    builder.Append("null");
                    break;
                case JsonObject obj:
                    builder.Append('{');
                    foreach (var (key, value) in obj.OrderBy(p => p.Key, StringComparer.Ordinal))
                    {
                        builder.Append(JsonSerializer.Serialize(key)).Append(':');
                        Write(value);
                        builder.Append(',');
                    }
                    builder.Append('}');
                    break;
                case JsonArray array:
                    builder.Append('[');
                    foreach (var item in array)
                    {
                        Write(item);
                        builder.Append(',');
                    }
                    builder.Append(']');
                    break;
                default:
                    var element = node.GetValue<JsonElement>();
                    builder.Append(element.ValueKind switch
                    {
                        JsonValueKind.Number => decimal.Parse(element.GetRawText(), NumberStyles.Float, CultureInfo.InvariantCulture).ToString("G29", CultureInfo.InvariantCulture),
                        JsonValueKind.String => JsonSerializer.Serialize(element.GetString()),
                        _ => element.GetRawText(),
                    });
                    break;
            }
        }
    }
}
