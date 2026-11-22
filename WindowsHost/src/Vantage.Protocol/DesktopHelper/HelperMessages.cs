using System.Buffers.Binary;
using System.Text;
using Vantage.Protocol.Input;

namespace Vantage.Protocol.DesktopHelper;

/// <summary>
/// The local pipe between Casement Host (in the signed-in user's session) and the desktop helper
/// that Casement Host Service starts as SYSTEM in the same session. The helper shows and controls
/// Windows' secure desktop (the lock screen, administrator prompts, Ctrl+Alt+Del) and apps that run
/// as administrator, which Windows keeps out of reach of a process running as the user.
/// </summary>
/// <remarks>
/// Framing: a little-endian <c>u32</c> payload length, a <c>u8</c> kind, then the payload. Strings
/// are a <c>u16</c> byte count and UTF-8. Nothing here is on the network: the host is the only
/// thing devices talk to, and it relays.
/// <list type="number">
/// <item>The host connects to <see cref="PipeName"/> and sends <see cref="HelperHello"/> with a fresh
/// nonce. The helper answers <see cref="HelperWelcome"/>, signing the nonce with the key Casement
/// Host Service made when it was installed (<see cref="HelperProof"/>); the host checks it against
/// the public half in Program Files, which a program running as the user can't change, so nothing
/// else can pose as the helper by taking the pipe's name first.</item>
/// <item>The helper sends <see cref="HelperDesktop"/> at once and whenever the input desktop
/// changes.</item>
/// <item>The host sends <see cref="HelperInput"/> (the same events it would give <c>SendInput</c>),
/// and <see cref="HelperStartCapture"/>/<see cref="HelperStopCapture"/> while the secure desktop is
/// up; the helper answers with <see cref="HelperFrame"/>s (only the changed areas after the first)
/// until it stops or <see cref="HelperCaptureStopped"/>.</item>
/// </list>
/// </remarks>
public static class HelperPipe
{
    /// <summary>Bumped on any incompatible change; the two sides refuse each other's other versions.</summary>
    public const uint Version = 1;

    /// <summary>The pipe for a Windows session (one helper per signed-in console session).</summary>
    public static string PipeName(uint sessionId) => $"CasementHostDesktop-{sessionId}";

    /// <summary>The largest payload either side accepts (a strip of a frame is cut to fit).</summary>
    public const int MaxPayload = 16 * 1024 * 1024;

    /// <summary>The pixel bytes one <see cref="HelperFrameStrip"/> carries at most.</summary>
    public const int MaxStripBytes = 8 * 1024 * 1024;
}

/// <summary>Message kinds on the helper pipe.</summary>
public enum HelperMessageKind : byte
{
    Hello = 1,
    StartCapture = 2,
    StopCapture = 3,
    Input = 4,
    Welcome = 101,
    Desktop = 102,
    Frame = 103,
    CaptureStopped = 104,
}

/// <summary>Which desktop has the keyboard and mouse.</summary>
public enum HelperDesktopKind : byte
{
    /// <summary>The user's own desktop ("Default").</summary>
    Default = 0,
    /// <summary>The secure desktop ("Winlogon"): the lock screen, an administrator prompt, Ctrl+Alt+Del.</summary>
    Secure = 1,
    /// <summary>Another desktop (the screen saver's) or one that couldn't be read.</summary>
    Other = 2,
}

/// <summary>A message on the helper pipe.</summary>
public abstract record HelperMessage
{
    public abstract HelperMessageKind Kind { get; }
}

/// <summary>Host → helper, first: its protocol version and a nonce for the helper to sign.</summary>
public sealed record HelperHello(uint Version, byte[] Nonce) : HelperMessage
{
    public override HelperMessageKind Kind => HelperMessageKind.Hello;
}

/// <summary>Helper → host, in answer: its version, its build, and its signature over <see cref="HelperProof.Transcript"/>.</summary>
public sealed record HelperWelcome(uint Version, string Build, byte[] Signature) : HelperMessage
{
    public override HelperMessageKind Kind => HelperMessageKind.Welcome;
}

/// <summary>Host → helper: capture the monitor with this GDI name (<c>\\.\DISPLAY1</c>), at most this often.</summary>
public sealed record HelperStartCapture(string MonitorDevice, uint MaxFps) : HelperMessage
{
    public override HelperMessageKind Kind => HelperMessageKind.StartCapture;
}

/// <summary>Host → helper: stop capturing.</summary>
public sealed record HelperStopCapture : HelperMessage
{
    public override HelperMessageKind Kind => HelperMessageKind.StopCapture;
}

/// <summary>Host → helper: inject these on the input desktop, as one batch.</summary>
public sealed record HelperInput(InputAction[] Actions) : HelperMessage
{
    public override HelperMessageKind Kind => HelperMessageKind.Input;
}

/// <summary>Helper → host: the input desktop now.</summary>
public sealed record HelperDesktop(HelperDesktopKind Desktop) : HelperMessage
{
    public override HelperMessageKind Kind => HelperMessageKind.Desktop;
}

/// <summary>Helper → host: a frame, as the areas that changed (the whole screen first).</summary>
/// <param name="Width">The monitor's width in pixels.</param>
/// <param name="Height">Its height.</param>
/// <param name="TimestampNanos">When it was captured, on the shared QPC clock (<c>HostClock</c>).</param>
/// <param name="Strips">The changed areas' pixels (BGRA, rows packed).</param>
/// <param name="IsLastPart">
/// A frame too big for one message comes in several (<see cref="HelperFrames.Split"/>); only the
/// last completes it, so the receiver shows it then and never half a frame.
/// </param>
public sealed record HelperFrame(int Width, int Height, ulong TimestampNanos, HelperFrameStrip[] Strips, bool IsLastPart = true) : HelperMessage
{
    public override HelperMessageKind Kind => HelperMessageKind.Frame;
}

/// <summary>One changed rectangle's BGRA pixels, <c>Width × 4</c> bytes a row.</summary>
public sealed record HelperFrameStrip(int X, int Y, int Width, int Height, byte[] Pixels);

/// <summary>Helper → host: capture ended by itself (the reason is logged).</summary>
public sealed record HelperCaptureStopped(string Reason) : HelperMessage
{
    public override HelperMessageKind Kind => HelperMessageKind.CaptureStopped;
}

/// <summary>The helper proving it's the one Casement Host Service installed.</summary>
public static class HelperProof
{
    private static readonly byte[] s_domain = "casement-desktop-helper-v1"u8.ToArray();

    /// <summary>What the helper signs: a fixed label, the session id and the host's nonce.</summary>
    public static byte[] Transcript(uint sessionId, ReadOnlySpan<byte> nonce)
    {
        var transcript = new byte[s_domain.Length + 4 + nonce.Length];
        s_domain.CopyTo(transcript, 0);
        BinaryPrimitives.WriteUInt32LittleEndian(transcript.AsSpan(s_domain.Length), sessionId);
        nonce.CopyTo(transcript.AsSpan(s_domain.Length + 4));
        return transcript;
    }
}

/// <summary>Reads and writes helper messages on a stream (one reader, writes serialised by the caller or <see cref="HelperChannel"/>).</summary>
public static class HelperCodec
{
    private const int InputSize = 20;

    /// <summary>The frame for <paramref name="message"/>: length, kind, payload.</summary>
    public static byte[] Encode(HelperMessage message)
    {
        using var payload = new MemoryStream();
        using (var writer = new BinaryWriter(payload, Encoding.UTF8, leaveOpen: true))
        {
            switch (message)
            {
                case HelperHello hello:
                    writer.Write(hello.Version);
                    WriteBytes(writer, hello.Nonce);
                    break;
                case HelperWelcome welcome:
                    writer.Write(welcome.Version);
                    WriteString(writer, welcome.Build);
                    WriteBytes(writer, welcome.Signature);
                    break;
                case HelperStartCapture start:
                    WriteString(writer, start.MonitorDevice);
                    writer.Write(start.MaxFps);
                    break;
                case HelperStopCapture:
                    break;
                case HelperInput input:
                    writer.Write((ushort)input.Actions.Length);
                    foreach (var action in input.Actions) WriteAction(writer, action);
                    break;
                case HelperDesktop desktop:
                    writer.Write((byte)desktop.Desktop);
                    break;
                case HelperFrame frame:
                    writer.Write(frame.Width);
                    writer.Write(frame.Height);
                    writer.Write(frame.TimestampNanos);
                    writer.Write(frame.IsLastPart);
                    writer.Write((ushort)frame.Strips.Length);
                    foreach (var strip in frame.Strips)
                    {
                        if (strip.Pixels.Length != strip.Width * strip.Height * 4)
                            throw new ArgumentException("A strip's pixels must be width × height × 4 bytes.", nameof(message));
                        writer.Write(strip.X);
                        writer.Write(strip.Y);
                        writer.Write(strip.Width);
                        writer.Write(strip.Height);
                        writer.Write(strip.Pixels);
                    }
                    break;
                case HelperCaptureStopped stopped:
                    WriteString(writer, stopped.Reason);
                    break;
                default:
                    throw new ArgumentException($"Unknown helper message {message.GetType().Name}.", nameof(message));
            }
        }
        if (payload.Length > HelperPipe.MaxPayload) throw new ArgumentException("Helper message too large.", nameof(message));
        var frameBytes = new byte[5 + payload.Length];
        BinaryPrimitives.WriteUInt32LittleEndian(frameBytes, (uint)payload.Length);
        frameBytes[4] = (byte)message.Kind;
        payload.GetBuffer().AsSpan(0, (int)payload.Length).CopyTo(frameBytes.AsSpan(5));
        return frameBytes;
    }

    /// <summary>The next message, or null at the end of the stream. Throws <see cref="InvalidDataException"/> on garbage.</summary>
    public static async Task<HelperMessage?> ReadAsync(Stream stream, CancellationToken cancellationToken)
    {
        var header = new byte[5];
        if (!await ReadExactlyOrEndAsync(stream, header, cancellationToken).ConfigureAwait(false)) return null;
        var length = BinaryPrimitives.ReadUInt32LittleEndian(header);
        if (length > HelperPipe.MaxPayload) throw new InvalidDataException($"Helper message of {length} bytes is too large.");
        var payload = new byte[length];
        if (length > 0 && !await ReadExactlyOrEndAsync(stream, payload, cancellationToken).ConfigureAwait(false))
            throw new InvalidDataException("The helper pipe ended inside a message.");
        return Decode((HelperMessageKind)header[4], payload);
    }

    /// <summary>A message from its kind and payload.</summary>
    public static HelperMessage Decode(HelperMessageKind kind, byte[] payload)
    {
        try
        {
            using var reader = new BinaryReader(new MemoryStream(payload), Encoding.UTF8);
            HelperMessage message = kind switch
            {
                HelperMessageKind.Hello => new HelperHello(reader.ReadUInt32(), ReadBytes(reader)),
                HelperMessageKind.Welcome => new HelperWelcome(reader.ReadUInt32(), ReadString(reader), ReadBytes(reader)),
                HelperMessageKind.StartCapture => new HelperStartCapture(ReadString(reader), reader.ReadUInt32()),
                HelperMessageKind.StopCapture => new HelperStopCapture(),
                HelperMessageKind.Input => ReadInput(reader),
                HelperMessageKind.Desktop => new HelperDesktop((HelperDesktopKind)reader.ReadByte()),
                HelperMessageKind.Frame => ReadFrame(reader),
                HelperMessageKind.CaptureStopped => new HelperCaptureStopped(ReadString(reader)),
                _ => throw new InvalidDataException($"Unknown helper message kind {(byte)kind}."),
            };
            if (reader.BaseStream.Position != payload.Length) throw new InvalidDataException($"Extra bytes after helper message {kind}.");
            return message;
        }
        catch (EndOfStreamException ex)
        {
            throw new InvalidDataException($"Helper message {kind} is cut short.", ex);
        }
    }

    private static HelperInput ReadInput(BinaryReader reader)
    {
        var count = reader.ReadUInt16();
        if (count * InputSize != reader.BaseStream.Length - reader.BaseStream.Position)
            throw new InvalidDataException("Helper input has the wrong length.");
        var actions = new InputAction[count];
        for (var i = 0; i < count; i++) actions[i] = ReadAction(reader);
        return new HelperInput(actions);
    }

    private static HelperFrame ReadFrame(BinaryReader reader)
    {
        var width = reader.ReadInt32();
        var height = reader.ReadInt32();
        var timestamp = reader.ReadUInt64();
        var isLastPart = reader.ReadBoolean();
        var count = reader.ReadUInt16();
        if (width <= 0 || height <= 0) throw new InvalidDataException("Helper frame has no size.");
        var strips = new HelperFrameStrip[count];
        for (var i = 0; i < count; i++)
        {
            var x = reader.ReadInt32();
            var y = reader.ReadInt32();
            var w = reader.ReadInt32();
            var h = reader.ReadInt32();
            if (x < 0 || y < 0 || w <= 0 || h <= 0 || x + (long)w > width || y + (long)h > height)
                throw new InvalidDataException("Helper frame strip lies outside the frame.");
            var bytes = (long)w * h * 4;
            if (bytes > reader.BaseStream.Length - reader.BaseStream.Position) throw new InvalidDataException("Helper frame strip is cut short.");
            strips[i] = new HelperFrameStrip(x, y, w, h, reader.ReadBytes((int)bytes));
        }
        return new HelperFrame(width, height, timestamp, strips, isLastPart);
    }

    private static void WriteAction(BinaryWriter writer, in InputAction action)
    {
        writer.Write((byte)action.Type);
        writer.Write((byte)action.Button);
        writer.Write((byte)((action.IsDown ? 1 : 0) | (action.IsExtended ? 2 : 0)));
        writer.Write((byte)0);
        writer.Write(action.X);
        writer.Write(action.Y);
        writer.Write(action.WheelDelta);
        writer.Write(action.ScanCode);
        writer.Write((ushort)action.Unicode);
    }

    private static InputAction ReadAction(BinaryReader reader)
    {
        var type = (InputActionType)reader.ReadByte();
        var button = (MouseButton)reader.ReadByte();
        var flags = reader.ReadByte();
        reader.ReadByte();
        if (type > InputActionType.Unicode || button > MouseButton.Forward) throw new InvalidDataException("Unknown input in a helper message.");
        return new InputAction
        {
            Type = type,
            Button = button,
            IsDown = (flags & 1) != 0,
            IsExtended = (flags & 2) != 0,
            X = reader.ReadInt32(),
            Y = reader.ReadInt32(),
            WheelDelta = reader.ReadInt32(),
            ScanCode = reader.ReadUInt16(),
            Unicode = (char)reader.ReadUInt16(),
        };
    }

    private static void WriteString(BinaryWriter writer, string value)
    {
        var bytes = Encoding.UTF8.GetBytes(value);
        if (bytes.Length > ushort.MaxValue) throw new ArgumentException("String too long for the helper pipe.");
        writer.Write((ushort)bytes.Length);
        writer.Write(bytes);
    }

    private static string ReadString(BinaryReader reader) => Encoding.UTF8.GetString(reader.ReadBytes(reader.ReadUInt16()));

    private static void WriteBytes(BinaryWriter writer, byte[] value)
    {
        if (value.Length > ushort.MaxValue) throw new ArgumentException("Too many bytes for the helper pipe.");
        writer.Write((ushort)value.Length);
        writer.Write(value);
    }

    private static byte[] ReadBytes(BinaryReader reader)
    {
        var length = reader.ReadUInt16();
        var bytes = reader.ReadBytes(length);
        if (bytes.Length != length) throw new EndOfStreamException();
        return bytes;
    }

    private static async Task<bool> ReadExactlyOrEndAsync(Stream stream, byte[] buffer, CancellationToken cancellationToken)
    {
        var read = 0;
        while (read < buffer.Length)
        {
            var n = await stream.ReadAsync(buffer.AsMemory(read), cancellationToken).ConfigureAwait(false);
            if (n == 0)
            {
                if (read == 0) return false;
                throw new InvalidDataException("The helper pipe ended inside a message.");
            }
            read += n;
        }
        return true;
    }
}

/// <summary>A helper pipe with serialised writes (any thread may send).</summary>
public sealed class HelperChannel(Stream stream) : IDisposable
{
    private readonly SemaphoreSlim _writeLock = new(1, 1);

    /// <summary>The next message, or null when the other side closed the pipe.</summary>
    public Task<HelperMessage?> ReadAsync(CancellationToken cancellationToken) => HelperCodec.ReadAsync(stream, cancellationToken);

    /// <summary>Sends a message; throws <see cref="IOException"/> once the pipe is gone.</summary>
    public async Task SendAsync(HelperMessage message, CancellationToken cancellationToken = default)
    {
        var bytes = HelperCodec.Encode(message);
        await _writeLock.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await stream.WriteAsync(bytes, cancellationToken).ConfigureAwait(false);
            await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _writeLock.Release();
        }
    }

    /// <summary>Sends a frame cut into strips of at most <see cref="HelperPipe.MaxStripBytes"/> each, one message per strip group.</summary>
    public async Task SendFrameAsync(HelperFrame frame, CancellationToken cancellationToken = default)
    {
        foreach (var part in HelperFrames.Split(frame, HelperPipe.MaxStripBytes))
            await SendAsync(part, cancellationToken).ConfigureAwait(false);
    }

    public void Dispose()
    {
        stream.Dispose();
        _writeLock.Dispose();
    }
}

/// <summary>Cutting frames to fit the pipe.</summary>
public static class HelperFrames
{
    /// <summary>
    /// <paramref name="frame"/> as messages whose strips add up to at most <paramref name="maxBytes"/>
    /// each, big strips cut into bands of rows. Every message carries the frame's size and time,
    /// and only the last is <see cref="HelperFrame.IsLastPart"/>; the receiver paints them in order.
    /// Pure.
    /// </summary>
    public static IEnumerable<HelperFrame> Split(HelperFrame frame, int maxBytes)
    {
        var batch = new List<HelperFrameStrip>();
        var batchBytes = 0;
        foreach (var strip in frame.Strips)
        {
            var rowBytes = strip.Width * 4;
            var rowsPerBand = Math.Max(1, maxBytes / rowBytes);
            for (var row = 0; row < strip.Height; row += rowsPerBand)
            {
                var rows = Math.Min(rowsPerBand, strip.Height - row);
                var band = rows == strip.Height
                    ? strip
                    : new HelperFrameStrip(strip.X, strip.Y + row, strip.Width, rows, strip.Pixels.AsSpan(row * rowBytes, rows * rowBytes).ToArray());
                var bytes = band.Pixels.Length;
                if (batch.Count > 0 && batchBytes + bytes > maxBytes)
                {
                    yield return frame with { Strips = [.. batch], IsLastPart = false };
                    batch.Clear();
                    batchBytes = 0;
                }
                batch.Add(band);
                batchBytes += bytes;
            }
        }
        yield return frame with { Strips = [.. batch], IsLastPart = true };
    }
}
