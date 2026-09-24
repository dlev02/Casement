using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using System.Threading.Channels;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using Vantage.Protocol.Messages;
using Vantage.Protocol.Net;
using Vantage.Protocol.Wire;

namespace Vantage.Protocol.Transport;

/// <summary>Settings for one <see cref="FramedConnection"/>.</summary>
public sealed record FramedConnectionOptions
{
    /// <summary>
    /// Decoded messages waiting to be taken before the reader stops reading, so a slow consumer
    /// (a file being written to disk) pushes back through TCP. The Mac host uses 64.
    /// </summary>
    public int MaxBufferedMessages { get; init; } = 64;

    /// <summary>Video frames queued (not yet written) above which new P-frames are dropped (spec §7.3).</summary>
    public int MaxQueuedVideoFrames { get; init; } = 2;

    /// <summary>Queued video bytes above which new P-frames are dropped.</summary>
    public int MaxQueuedVideoBytes { get; init; } = 2 * 1024 * 1024;
}

/// <summary>A frame kind this build doesn't know: its payload was read and skipped (spec §3).</summary>
/// <param name="RawKind">The kind byte.</param>
/// <param name="Length">Payload bytes skipped.</param>
public sealed record UnknownMessage(byte RawKind, uint Length) : IMessage
{
    public MessageKind Kind => (MessageKind)RawKind;
}

/// <summary>A known kind whose payload didn't decode. During the handshake: close; afterwards: log and drop.</summary>
/// <param name="MessageKind">The frame's kind.</param>
/// <param name="Error">Why it didn't decode.</param>
public sealed record UndecodableMessage(MessageKind MessageKind, Exception Error) : IMessage
{
    public MessageKind Kind => MessageKind;
}

/// <summary>
/// One framed TCP connection (Swift <c>MessageChannel</c>): exact reads of header then payload;
/// one writer task that writes whole frames in order from three lanes — control first, then
/// video, then bulk — so a 256 KiB file chunk or a keyframe never interleaves with another frame
/// and a pong never waits behind a queue of video. The video lane is bounded: past
/// <see cref="FramedConnectionOptions.MaxQueuedVideoFrames"/> frames or
/// <see cref="FramedConnectionOptions.MaxQueuedVideoBytes"/> bytes, new droppable frames (P-frames)
/// are refused whole, and the sender forces an IDR once the lane drains.
/// </summary>
public sealed class FramedConnection : IAsyncDisposable
{
    private readonly Socket _socket;
    private readonly FramedConnectionOptions _options;
    private readonly ILogger _log;
    private readonly Channel<IMessage> _inbound;
    private readonly CancellationTokenSource _closing = new();
    private readonly Lock _lock = new();
    private readonly Queue<Outbound> _control = new();
    private readonly Queue<Outbound> _video = new();
    private readonly Queue<Outbound> _bulk = new();
    private readonly SemaphoreSlim _wake = new(0);
    private readonly TaskCompletionSource _closed = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private int _videoBytes;
    private bool _started;
    private bool _isClosed;

    /// <summary>Wraps a connected socket (tunes it for the protocol). Call <see cref="Start"/>.</summary>
    public FramedConnection(Socket socket, FramedConnectionOptions? options = null, ILogger? logger = null)
    {
        _socket = socket;
        _options = options ?? new FramedConnectionOptions();
        _log = logger ?? NullLogger.Instance;
        _inbound = Channel.CreateBounded<IMessage>(new BoundedChannelOptions(Math.Max(1, _options.MaxBufferedMessages))
        {
            SingleReader = true,
            SingleWriter = true,
            FullMode = BoundedChannelFullMode.Wait,
        });
        ConfigureSocket(socket);
        var remote = socket.RemoteEndPoint as IPEndPoint;
        RemoteEndPoint = remote ?? new IPEndPoint(IPAddress.None, 0);
        PeerAddress = PeerPolicy.Normalize(RemoteEndPoint.Address);
    }

    /// <summary>The peer's address and port.</summary>
    public IPEndPoint RemoteEndPoint { get; }

    /// <summary>The peer's address, IPv4-mapped addresses mapped to IPv4.</summary>
    public IPAddress PeerAddress { get; }

    /// <summary>Completes when the connection has closed (either side, or an error).</summary>
    public Task Completion => _closed.Task;

    /// <summary>Whether the connection has closed.</summary>
    public bool IsClosed
    {
        get { lock (_lock) return _isClosed; }
    }

    /// <summary>Why it closed, when it was an error.</summary>
    public Exception? CloseError { get; private set; }

    /// <summary>Video frames queued and not yet written.</summary>
    public int QueuedVideoFrames
    {
        get { lock (_lock) return _video.Count; }
    }

    /// <summary>The video lane is at or over its limits: a droppable frame would be refused now.</summary>
    public bool IsVideoBacklogged
    {
        get { lock (_lock) return VideoFullLocked(); }
    }

    /// <summary>Raised (writer thread) when the video lane empties after it refused a frame.</summary>
    public event Action? VideoDrained;

    private bool _videoDropped;

    /// <summary>
    /// The TCP tuning of <c>VantageNetwork.tcpParameters()</c>: no Nagle, keepalive after 5 s idle,
    /// every 2 s, 3 probes (about 11 s to notice a dead peer).
    /// </summary>
    public static void ConfigureSocket(Socket socket)
    {
        socket.NoDelay = true;
        socket.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.KeepAlive, true);
        try
        {
            socket.SetSocketOption(SocketOptionLevel.Tcp, SocketOptionName.TcpKeepAliveTime, 5);
            socket.SetSocketOption(SocketOptionLevel.Tcp, SocketOptionName.TcpKeepAliveInterval, 2);
            socket.SetSocketOption(SocketOptionLevel.Tcp, SocketOptionName.TcpKeepAliveRetryCount, 3);
        }
        catch (SocketException)
        {
            // Older platforms: plain keepalive still helps.
        }
    }

    /// <summary>Connects to <paramref name="host"/>:<paramref name="port"/> (8 s limit) and starts the connection.</summary>
    public static async Task<FramedConnection> ConnectAsync(string host, int port, FramedConnectionOptions? options = null,
                                                             ILogger? logger = null, CancellationToken cancellationToken = default)
    {
        var addresses = await Dns.GetHostAddressesAsync(host, cancellationToken).ConfigureAwait(false);
        var address = addresses.First();
        var socket = new Socket(address.AddressFamily, SocketType.Stream, ProtocolType.Tcp);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(8));
        try
        {
            await socket.ConnectAsync(new IPEndPoint(address, port), timeout.Token).ConfigureAwait(false);
        }
        catch
        {
            socket.Dispose();
            throw;
        }
        var connection = new FramedConnection(socket, options, logger);
        connection.Start();
        return connection;
    }

    /// <summary>Starts the reader and writer.</summary>
    public void Start()
    {
        lock (_lock)
        {
            if (_started) return;
            _started = true;
        }
        _ = Task.Run(ReadLoopAsync);
        _ = Task.Run(WriteLoopAsync);
    }

    /// <summary>
    /// The next message, or null once the connection has closed. Unknown kinds arrive as
    /// <see cref="UnknownMessage"/>, bad payloads as <see cref="UndecodableMessage"/>. One reader at a time.
    /// </summary>
    public async ValueTask<IMessage?> ReceiveAsync(CancellationToken cancellationToken = default)
    {
        try
        {
            return await _inbound.Reader.ReadAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (ChannelClosedException)
        {
            return null;
        }
    }

    /// <summary>Queues a control message and completes when it has been written to the socket. Throws if the connection closes first.</summary>
    public Task SendAsync(IMessage message)
    {
        var outbound = new Outbound(MessageCodec.EncodeFrame(message), IsVideo: false,
                                    new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously), null);
        Enqueue(_control, outbound);
        return outbound.Done!.Task;
    }

    /// <summary>Queues a control message without waiting (replies from a receive loop, pongs, status).</summary>
    public void Post(IMessage message) => Enqueue(_control, new Outbound(MessageCodec.EncodeFrame(message), false, null, null));

    /// <summary>
    /// Queues a video-lane message (<c>videoConfig</c>, <c>videoFrame</c>). A
    /// <paramref name="droppable"/> one (a P-frame) is refused whole, returning false, while the
    /// lane is over its limits; the caller must then force an IDR (wait for <see cref="VideoDrained"/>).
    /// </summary>
    public bool PostVideo(IMessage message, bool droppable)
    {
        byte[] frame;
        lock (_lock)
        {
            if (_isClosed) return false;
            if (droppable && VideoFullLocked())
            {
                _videoDropped = true;
                return false;
            }
        }
        frame = MessageCodec.EncodeFrame(message);
        Enqueue(_video, new Outbound(frame, IsVideo: true, null, null));
        return true;
    }

    /// <summary>
    /// Queues a bulk message (file chunks, clipboard) behind control and video. <paramref name="completion"/>
    /// runs once it has been written (null) or failed; use it to keep a few chunks in flight.
    /// </summary>
    public void PostBulk(IMessage message, Action<Exception?>? completion = null)
    {
        byte[] frame;
        try
        {
            frame = MessageCodec.EncodeFrame(message);
        }
        catch (Exception error)
        {
            completion?.Invoke(error);
            return;
        }
        Enqueue(_bulk, new Outbound(frame, false, null, completion));
    }

    /// <summary>Queues an already-framed message on the control lane (tests: unknown kinds, bad payloads).</summary>
    internal void PostRaw(byte[] frame) => Enqueue(_control, new Outbound(frame, false, null, null));

    /// <summary>Closes the connection; queued sends fail, <see cref="ReceiveAsync"/> returns null.</summary>
    public void Close() => Finish(null);

    /// <inheritdoc />
    public ValueTask DisposeAsync()
    {
        Close();
        return ValueTask.CompletedTask;
    }

    private bool VideoFullLocked() =>
        _video.Count >= _options.MaxQueuedVideoFrames || _videoBytes >= _options.MaxQueuedVideoBytes;

    private void Enqueue(Queue<Outbound> lane, Outbound outbound)
    {
        lock (_lock)
        {
            if (!_isClosed)
            {
                lane.Enqueue(outbound);
                if (outbound.IsVideo) _videoBytes += outbound.Frame.Length;
                _wake.Release();
                return;
            }
        }
        Fail(outbound, new IOException("The connection is closed."));
    }

    private Outbound? DequeueLocked()
    {
        if (_control.Count > 0) return _control.Dequeue();
        if (_video.Count > 0)
        {
            var next = _video.Dequeue();
            _videoBytes -= next.Frame.Length;
            return next;
        }
        return _bulk.Count > 0 ? _bulk.Dequeue() : null;
    }

    private async Task WriteLoopAsync()
    {
        var token = _closing.Token;
        Outbound? next = null;
        try
        {
            while (true)
            {
                next = null;
                await _wake.WaitAsync(token).ConfigureAwait(false);
                bool drained;
                lock (_lock)
                {
                    next = DequeueLocked();
                    drained = next is { IsVideo: true } && _video.Count == 0 && _videoDropped;
                }
                if (next is null) continue;
                var written = 0;
                while (written < next.Frame.Length)
                {
                    written += await _socket.SendAsync(next.Frame.AsMemory(written), SocketFlags.None, token).ConfigureAwait(false);
                }
                var done = next;
                next = null;
                done.Done?.TrySetResult();
                done.Completion?.Invoke(null);
                if (drained)
                {
                    lock (_lock) _videoDropped = false;
                    VideoDrained?.Invoke();
                }
            }
        }
        catch (Exception error) when (error is OperationCanceledException or ObjectDisposedException)
        {
            Finish(null);
            if (next is not null) Fail(next, new IOException("The connection was closed."));
        }
        catch (Exception error)
        {
            Finish(error);
            if (next is not null) Fail(next, new IOException("The connection was lost.", error));
        }
    }

    private async Task ReadLoopAsync()
    {
        var token = _closing.Token;
        var header = new byte[Frame.HeaderLength];
        try
        {
            while (true)
            {
                if (!await ReadExactlyAsync(header, token).ConfigureAwait(false)) break;
                var parsed = Frame.ReadHeader(header);
                var payload = parsed.Length == 0 ? [] : new byte[parsed.Length];
                if (payload.Length > 0 && !await ReadExactlyAsync(payload, token).ConfigureAwait(false))
                    throw new IOException("The connection closed in the middle of a message.");
                IMessage message;
                if (!parsed.IsKnownKind)
                {
                    message = new UnknownMessage(parsed.RawKind, parsed.Length);
                }
                else
                {
                    try
                    {
                        message = MessageCodec.Decode(parsed.Kind, payload);
                    }
                    catch (Exception error) when (error is JsonException or WireFormatException or FrameException or FormatException or NotSupportedException)
                    {
                        message = new UndecodableMessage(parsed.Kind, error);
                    }
                }
                await _inbound.Writer.WriteAsync(message, token).ConfigureAwait(false);
            }
            Finish(null);
        }
        catch (Exception error) when (error is OperationCanceledException or ObjectDisposedException)
        {
            Finish(null);
        }
        catch (Exception error)
        {
            if (!IsClosed) _log.LogDebug("receive loop ended: {Error}", error.Message);
            Finish(error);
        }
    }

    private async Task<bool> ReadExactlyAsync(Memory<byte> buffer, CancellationToken token)
    {
        var read = 0;
        while (read < buffer.Length)
        {
            var count = await _socket.ReceiveAsync(buffer[read..], SocketFlags.None, token).ConfigureAwait(false);
            if (count == 0)
            {
                if (read == 0) return false;
                throw new IOException("The connection closed in the middle of a message.");
            }
            read += count;
        }
        return true;
    }

    private void Finish(Exception? error)
    {
        List<Outbound> pending;
        lock (_lock)
        {
            if (_isClosed) return;
            _isClosed = true;
            CloseError = error;
            pending = [.. _control, .. _video, .. _bulk];
            _control.Clear();
            _video.Clear();
            _bulk.Clear();
            _videoBytes = 0;
        }
        _closing.Cancel();
        try
        {
            _socket.Shutdown(SocketShutdown.Both);
        }
        catch (Exception shutdownError) when (shutdownError is SocketException or ObjectDisposedException)
        {
            // Already gone.
        }
        _socket.Dispose();
        _inbound.Writer.TryComplete();
        var failure = new IOException("The connection was closed.", error);
        foreach (var outbound in pending) Fail(outbound, failure);
        _closed.TrySetResult();
    }

    private static void Fail(Outbound outbound, Exception error)
    {
        outbound.Done?.TrySetException(error);
        outbound.Completion?.Invoke(error);
    }

    private sealed record Outbound(byte[] Frame, bool IsVideo, TaskCompletionSource? Done, Action<Exception?>? Completion);
}
