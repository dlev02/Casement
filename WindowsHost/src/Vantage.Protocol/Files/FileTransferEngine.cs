using System.Globalization;
using System.Security.Cryptography;
using System.Threading.Channels;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using Vantage.Protocol.Host;
using Vantage.Protocol.Messages;
using Vantage.Protocol.Transport;

namespace Vantage.Protocol.Files;

/// <summary>Which end of the file channel an engine is (it decides the chunk kinds).</summary>
public enum FileTransferRole
{
    /// <summary>Sends <c>fileChunkToClient</c> (103), accepts <c>fileChunkToHost</c> (124).</summary>
    Host,
    /// <summary>Sends 124, accepts 103 (tests and tools).</summary>
    Client,
}

/// <summary>Settings for a <see cref="FileTransferEngine"/> (<c>FileTransferConfiguration</c> in Swift).</summary>
public sealed record FileTransferConfiguration
{
    /// <summary>Where received files are saved (created if missing).</summary>
    public required string ReceiveDirectory { get; init; }

    public int ChunkSize { get; init; } = FileChunk.StandardSize;

    /// <summary>Chunks handed to the connection but not yet written.</summary>
    public int Window { get; init; } = 4;

    /// <summary>Offers above this are refused (64 GiB).</summary>
    public ulong MaxIncomingBytes { get; init; } = 64UL << 30;

    /// <summary>Free space that must remain after a received file (256 MiB).</summary>
    public ulong FreeSpaceMargin { get; init; } = 256UL << 20;

    public TimeSpan ProgressInterval { get; init; } = TimeSpan.FromMilliseconds(100);

    /// <summary>A pause before each chunk sent (tests only).</summary>
    public TimeSpan ChunkDelay { get; init; } = TimeSpan.Zero;

    /// <summary>How long a partial cut off by a lost connection waits for its sender to resume it.</summary>
    public TimeSpan PartialLifetime { get; init; } = TimeSpan.FromHours(24);

    /// <summary>Where an earlier connection left a file's partial, when that isn't <see cref="ReceiveDirectory"/>.</summary>
    public Func<Guid, string?>? PartialDirectory { get; init; }

    /// <summary>Platform hooks: Hidden attribute, Zone.Identifier, free space, case-insensitive names.</summary>
    public IFileStore? Store { get; init; }

    /// <summary>Who is on the other end, passed to <see cref="IFileStore.OnSaved(string, FileOffer, FileSender)"/>.</summary>
    public FileSender? Sender { get; init; }

    /// <summary>Apply the Windows name rules on top of the Mac's (reserved names, <c>&lt;&gt;"|?*</c>).</summary>
    public bool WindowsNameRules { get; init; } = true;
}

/// <summary>
/// File transfers over a file channel, both ways at once (<c>Transfer/FileTransferEngine.swift</c>,
/// spec §10.6): one outgoing file at a time (sends queue FIFO) with at most
/// <see cref="FileTransferConfiguration.Window"/> chunks in flight, and whatever the peer offers,
/// saved through a hidden <c>.vantage-&lt;ID&gt;.partial</c> renamed only after its size and SHA-256
/// check out. A lost connection keeps incoming partials; a re-offer of the same id resumes from
/// what's there (re-hashed, since a hash state can't be saved). Replies from the receive loop are
/// queued without waiting for the socket.
/// </summary>
public sealed class FileTransferEngine
{
    /// <summary>Prefix of partial files.</summary>
    public const string PartialPrefix = ".vantage-";

    /// <summary>Suffix of partial files.</summary>
    public const string PartialSuffix = ".partial";

    private readonly FramedConnection _channel;
    private readonly FileTransferRole _role;
    private readonly FileTransferConfiguration _config;
    private readonly ILogger _log;
    private readonly Lock _gate = new();
    private readonly Channel<FileTransferEvent> _events = Channel.CreateUnbounded<FileTransferEvent>(new() { SingleReader = true });
    private readonly Queue<TaskCompletionSource> _turnWaiters = new();
    private readonly HashSet<Guid> _cancelledBeforeStart = [];
    private readonly Dictionary<Guid, Incoming> _incoming = [];
    private readonly TaskCompletionSource _finished = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private bool _outgoingBusy;
    private Outgoing? _outgoing;
    private CancellationTokenSource? _rehashing;
    private bool _isClosed;

    public FileTransferEngine(FramedConnection channel, FileTransferRole role, FileTransferConfiguration configuration, ILogger? logger = null)
    {
        _channel = channel;
        _role = role;
        _config = configuration;
        _log = logger ?? NullLogger.Instance;
        _ = Task.Run(PumpEventsAsync);
    }

    /// <summary>Progress, raised in order on a background thread.</summary>
    public event Action<FileTransferEvent>? Events;

    /// <summary>Completes once the engine has shut down and every event has been raised.</summary>
    public Task Completion => _finished.Task;

    /// <summary>The channel has closed; nothing more will move on this engine.</summary>
    public bool HasClosed
    {
        get { lock (_gate) return _isClosed; }
    }

    /// <summary>A file is moving, queued, or being re-hashed, in either direction.</summary>
    public bool IsBusy
    {
        get
        {
            lock (_gate) return _outgoingBusy || _outgoing is not null || _turnWaiters.Count > 0 || _incoming.Count > 0 || _rehashing is not null;
        }
    }

    /// <summary>Reads the channel until it closes, then fails what was in flight. Any message that doesn't belong on a file channel ends it.</summary>
    public async Task RunAsync()
    {
        RemoveStalePartials();
        try
        {
            while (await _channel.ReceiveAsync().ConfigureAwait(false) is { } message)
            {
                if (!await HandleAsync(message).ConfigureAwait(false)) break;
            }
        }
        catch (Exception error)
        {
            if (!HasClosed) _log.LogError("file channel ended: {Error}", error.Message);
        }
        ShutDown("The connection was lost.");
    }

    /// <summary>Ends the channel and every transfer on it; incoming partials are kept for a resume.</summary>
    public void Close() => ShutDown("The connection was closed.");

    // MARK: Sending

    /// <summary>
    /// Sends one file and completes once the peer has answered (or it failed). Calls queue behind
    /// each other. Sending the same <paramref name="id"/> again after a lost connection lets the
    /// receiver resume.
    /// </summary>
    public async Task<FileTransferOutcome> SendAsync(string path, string? name = null, Guid? id = null)
    {
        var transferId = id ?? Guid.NewGuid();
        await TakeTurnAsync().ConfigureAwait(false);
        try
        {
            lock (_gate)
            {
                if (_cancelledBeforeStart.Remove(transferId)) return Finish(transferId, new FileTransferOutcome.Cancelled(false));
                if (_isClosed) return Finish(transferId, new FileTransferOutcome.Failed("The connection was lost."));
            }
            FileStream stream;
            FileOffer offer;
            try
            {
                if (Directory.Exists(path)) return Finish(transferId, new FileTransferOutcome.Failed("Folders can't be sent. Compress it first."));
                stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1 << 16, FileOptions.SequentialScan);
                offer = new FileOffer
                {
                    Id = transferId,
                    Name = name ?? Path.GetFileName(path),
                    ByteCount = (ulong)stream.Length,
                    Modified = new DateTimeOffset(File.GetLastWriteTimeUtc(path), TimeSpan.Zero),
                };
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                _log.LogError("can't read file to send: {Error}", error.Message);
                return Finish(transferId, new FileTransferOutcome.Failed("Porthole couldn't read that file."));
            }
            await using (stream.ConfigureAwait(false))
            {
                var state = new Outgoing(transferId);
                lock (_gate) _outgoing = state;
                try
                {
                    Emit(new FileTransferEvent.Started(new FileTransferItem(transferId, offer.Name, offer.ByteCount, FileDirection.Sending)));
                    try
                    {
                        await _channel.SendAsync(offer).ConfigureAwait(false);
                    }
                    catch (IOException)
                    {
                        return Finish(transferId, new FileTransferOutcome.Failed("The connection was lost."));
                    }
                    var reply = await state.NextReplyAsync().ConfigureAwait(false);
                    switch (reply)
                    {
                        case PeerReply.Accept accept:
                            if (accept.Message.Rejected is { } reason) return Finish(transferId, new FileTransferOutcome.Failed(reason));
                            if (accept.Message.ResumeOffset > offer.ByteCount)
                                return Finish(transferId, new FileTransferOutcome.Failed("The other device asked for a part of the file that doesn't exist."));
                            return await StreamAsync(stream, path, offer, accept.Message.ResumeOffset, state).ConfigureAwait(false);
                        case PeerReply.Result result:
                            return Finish(transferId, new FileTransferOutcome.Failed(result.Message.Ok
                                ? "The other device answered out of turn."
                                : result.Message.Error ?? "The other device couldn't save the file."));
                        case PeerReply.Cancelled cancelled:
                            return Finish(transferId, new FileTransferOutcome.Cancelled(cancelled.ByPeer));
                        default:
                            return Finish(transferId, new FileTransferOutcome.Failed("The connection was lost."));
                    }
                }
                finally
                {
                    lock (_gate)
                    {
                        if (ReferenceEquals(_outgoing, state)) _outgoing = null;
                    }
                }
            }
        }
        finally
        {
            PassTurn();
        }
    }

    /// <summary>Stops a transfer in either direction (or a queued send before it starts). The receiver deletes what it has.</summary>
    public void Cancel(Guid id)
    {
        Outgoing? outgoing;
        Incoming? incoming = null;
        lock (_gate)
        {
            outgoing = _outgoing is { } current && current.Id == id ? current : null;
            if (outgoing is null && !_incoming.Remove(id, out incoming)) _cancelledBeforeStart.Add(id);
        }
        if (outgoing is not null)
        {
            if (outgoing.Cancelled) return;
            outgoing.Cancelled = true;
            outgoing.Stop.Cancel();
            outgoing.Window?.Abort(new OperationCanceledException());
            _channel.Post(new FileCancel { Id = id });
            outgoing.Deliver(new PeerReply.Cancelled(false));
        }
        else if (incoming is not null)
        {
            Discard(incoming);
            _channel.Post(new FileCancel { Id = id });
            Emit(new FileTransferEvent.Finished(id, new FileTransferOutcome.Cancelled(false)));
        }
    }

    private async Task<FileTransferOutcome> StreamAsync(FileStream stream, string path, FileOffer offer, ulong start, Outgoing state)
    {
        var id = offer.Id;
        using var hasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        var offset = start;
        var window = new SendWindow(_config.Window);
        state.Window = window;
        var lastProgress = DateTime.UtcNow;
        var began = DateTime.UtcNow;
        try
        {
            if (start > 0)
            {
                Emit(new FileTransferEvent.Progress(id, start));
                var hashStart = DateTime.UtcNow;
                if (!await HashPrefixAsync(path, start, hasher, state.Stop.Token).ConfigureAwait(false))
                {
                    if (state.TakeTerminalReply() is { } early) return Finish(id, early);
                    throw new FileChangedException();
                }
                if (state.TakeTerminalReply() is { } earlyAfterHash) return Finish(id, earlyAfterHash);
                stream.Seek((long)start, SeekOrigin.Begin);
                _log.LogInformation("resuming a send at {Start} of {Total} bytes (hashed the start in {Ms} ms)",
                                    start, offer.ByteCount, (int)(DateTime.UtcNow - hashStart).TotalMilliseconds);
            }
            while (offset < offer.ByteCount)
            {
                if (state.TakeTerminalReply() is { } early) return Finish(id, early);
                var wanted = (int)Math.Min((ulong)_config.ChunkSize, offer.ByteCount - offset);
                var piece = new byte[wanted];
                var read = 0;
                while (read < wanted)
                {
                    var count = await stream.ReadAsync(piece.AsMemory(read)).ConfigureAwait(false);
                    if (count == 0) break;
                    read += count;
                }
                if (read != wanted) throw new FileChangedException();
                hasher.AppendData(piece);
                if (_config.ChunkDelay > TimeSpan.Zero) await Task.Delay(_config.ChunkDelay).ConfigureAwait(false);
                await window.AcquireAsync().ConfigureAwait(false);
                if (state.TakeTerminalReply() is { } earlyAfterWait) return Finish(id, earlyAfterWait);
                _channel.PostBulk(new FileChunk { ToHost = _role == FileTransferRole.Client, Id = id, Offset = offset, Data = piece },
                                  window.Release);
                offset += (ulong)wanted;
                if (DateTime.UtcNow - lastProgress >= _config.ProgressInterval)
                {
                    lastProgress = DateTime.UtcNow;
                    Emit(new FileTransferEvent.Progress(id, offset));
                }
            }
            await window.DrainAsync().ConfigureAwait(false);
            if (state.TakeTerminalReply() is { } earlyAfterDrain) return Finish(id, earlyAfterDrain);
            Emit(new FileTransferEvent.Progress(id, offset));
            await _channel.SendAsync(new FileComplete { Id = id, Sha256 = hasher.GetHashAndReset() }).ConfigureAwait(false);
        }
        catch (FileChangedException)
        {
            _channel.Post(new FileCancel { Id = id });
            return Finish(id, new FileTransferOutcome.Failed("The file changed while it was being sent."));
        }
        catch (Exception error)
        {
            if (state.TakeTerminalReply() is { } early) return Finish(id, early);
            if (state.Cancelled) return Finish(id, new FileTransferOutcome.Cancelled(false));
            _log.LogError("send failed: {Error}", error.Message);
            return Finish(id, new FileTransferOutcome.Failed(error is UnauthorizedAccessException ? "Porthole couldn't read that file." : "The connection was lost."));
        }
        var reply = await state.NextReplyAsync().ConfigureAwait(false);
        switch (reply)
        {
            case PeerReply.Result result:
                if (result.Message.Ok) LogRate("sent", offer.ByteCount - start, began, start);
                return Finish(id, result.Message.Ok
                    ? new FileTransferOutcome.Sent(result.Message.SavedName)
                    : new FileTransferOutcome.Failed(result.Message.Error ?? "The other device couldn't save the file."));
            case PeerReply.Cancelled cancelled:
                return Finish(id, new FileTransferOutcome.Cancelled(cancelled.ByPeer));
            case PeerReply.Accept:
                return Finish(id, new FileTransferOutcome.Failed("The other device answered out of turn."));
            default:
                return Finish(id, new FileTransferOutcome.Failed("The connection was lost before the other device confirmed the file."));
        }
    }

    private FileTransferOutcome Finish(Guid id, FileTransferOutcome outcome)
    {
        Emit(new FileTransferEvent.Finished(id, outcome));
        return outcome;
    }

    private Task TakeTurnAsync()
    {
        lock (_gate)
        {
            if (!_outgoingBusy)
            {
                _outgoingBusy = true;
                return Task.CompletedTask;
            }
            var waiter = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            _turnWaiters.Enqueue(waiter);
            return waiter.Task;
        }
    }

    private void PassTurn()
    {
        TaskCompletionSource? next = null;
        lock (_gate)
        {
            if (_turnWaiters.Count == 0) _outgoingBusy = false;
            else next = _turnWaiters.Dequeue(); // stays busy: the turn passes straight on
        }
        next?.TrySetResult();
    }

    // MARK: Receiving

    /// <summary>False when the message ends the channel.</summary>
    private async Task<bool> HandleAsync(IMessage message)
    {
        switch (message)
        {
            case FileOffer offer:
                await ReceiveOfferAsync(offer).ConfigureAwait(false);
                return true;
            case FileChunk chunk when chunk.ToHost == (_role == FileTransferRole.Host):
                ReceiveChunk(chunk);
                return true;
            case FileComplete complete:
                ReceiveComplete(complete);
                return true;
            case FileAccept accept:
                DeliverToOutgoing(accept.Id, new PeerReply.Accept(accept));
                return true;
            case FileResult result:
                DeliverToOutgoing(result.Id, new PeerReply.Result(result));
                return true;
            case FileCancel cancel:
                ReceiveCancel(cancel.Id);
                return true;
            default:
                // Nothing else belongs on a file channel (including chunks going the wrong way).
                _log.LogError("unexpected {Kind} on the file channel", message.Kind);
                return false;
        }
    }

    private void DeliverToOutgoing(Guid id, PeerReply reply)
    {
        Outgoing? outgoing;
        lock (_gate) outgoing = _outgoing is { } current && current.Id == id ? current : null;
        outgoing?.Deliver(reply);
    }

    private void ReceiveCancel(Guid id)
    {
        Outgoing? outgoing;
        Incoming? incoming = null;
        lock (_gate)
        {
            outgoing = _outgoing is { } current && current.Id == id ? current : null;
            if (outgoing is null) _incoming.Remove(id, out incoming);
        }
        if (outgoing is not null)
        {
            outgoing.CancelledByPeer = true;
            outgoing.Stop.Cancel();
            outgoing.Window?.Abort(new OperationCanceledException());
            outgoing.Deliver(new PeerReply.Cancelled(true));
        }
        else if (incoming is not null)
        {
            Discard(incoming);
            Emit(new FileTransferEvent.Finished(id, new FileTransferOutcome.Cancelled(true)));
        }
        else
        {
            // A sender that gave up on a file not being received right now: its partial from an
            // earlier connection will never be finished.
            var partial = PartialPath(id);
            if (!PartialClaims.IsClaimed(partial)) TryDelete(partial);
        }
    }

    private async Task ReceiveOfferAsync(FileOffer offer)
    {
        lock (_gate)
        {
            if (_isClosed || _incoming.ContainsKey(offer.Id) || _outgoing?.Id == offer.Id)
            {
                Reply(new FileAccept { Id = offer.Id, ResumeOffset = 0, Rejected = "That file is already being transferred." });
                return;
            }
        }
        var name = FileNames.Sanitize(offer.Name, _config.WindowsNameRules);
        var directory = FolderFor(offer.Id);
        var partial = PartialPath(offer.Id);
        // Another file channel may still be writing it (this sender's old connection that hasn't
        // noticed it died yet): take it over.
        PartialClaims.Claim(partial, this)?.Relinquish(offer.Id);

        IncrementalHash? resumeHash = null;
        ulong resumeOffset = 0;
        if (FileSize(partial) is { } existing && existing > 0 && existing <= offer.ByteCount)
        {
            var stop = new CancellationTokenSource();
            lock (_gate) _rehashing = stop;
            var began = DateTime.UtcNow;
            var hasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            if (await HashPrefixAsync(partial, existing, hasher, stop.Token).ConfigureAwait(false))
            {
                resumeHash = hasher;
                resumeOffset = existing;
                _log.LogInformation("resuming a receive at {Existing} of {Total} bytes (re-hashed in {Ms} ms)",
                                    existing, offer.ByteCount, (int)(DateTime.UtcNow - began).TotalMilliseconds);
            }
            else
            {
                hasher.Dispose();
            }
            lock (_gate)
            {
                if (ReferenceEquals(_rehashing, stop)) _rehashing = null;
            }
            stop.Dispose();
        }
        lock (_gate)
        {
            if (_isClosed || _incoming.ContainsKey(offer.Id))
            {
                PartialClaims.Release(partial, this);
                resumeHash?.Dispose();
                if (!_isClosed) Reply(new FileAccept { Id = offer.Id, ResumeOffset = 0, Rejected = "That file is already being transferred." });
                return;
            }
        }
        if (Rejection(offer, directory, resumeOffset) is { } reason)
        {
            _log.LogInformation("refusing incoming file ({Bytes} bytes): {Reason}", offer.ByteCount, reason);
            PartialClaims.Release(partial, this);
            resumeHash?.Dispose();
            TryDelete(partial);
            Reply(new FileAccept { Id = offer.Id, ResumeOffset = 0, Rejected = reason });
            return;
        }
        FileStream handle;
        try
        {
            Directory.CreateDirectory(directory);
            if (resumeHash is not null)
            {
                handle = new FileStream(partial, FileMode.Open, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
                handle.SetLength((long)resumeOffset);
                handle.Seek(0, SeekOrigin.End);
            }
            else
            {
                handle = new FileStream(partial, FileMode.Create, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
                RunHook(() => _config.Store?.OnPartialCreated(partial));
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            _log.LogError("can't open partial file: {Error}", error.Message);
            PartialClaims.Release(partial, this);
            resumeHash?.Dispose();
            Reply(new FileAccept { Id = offer.Id, ResumeOffset = 0, Rejected = "The file couldn't be saved on this device." });
            return;
        }
        var state = new Incoming(offer, name, directory, partial, handle, resumeHash ?? IncrementalHash.CreateHash(HashAlgorithmName.SHA256))
        {
            Received = resumeOffset,
            ResumedAt = resumeOffset,
        };
        lock (_gate) _incoming[offer.Id] = state;
        Emit(new FileTransferEvent.Started(new FileTransferItem(offer.Id, name, offer.ByteCount, FileDirection.Receiving)));
        if (state.Received > 0 || offer.ByteCount == 0) Emit(new FileTransferEvent.Progress(offer.Id, state.Received));
        Reply(new FileAccept { Id = offer.Id, ResumeOffset = state.Received });
    }

    /// <summary>Answers from the receive loop never wait on the network (two big files crossing would deadlock).</summary>
    private void Reply(IMessage message) => _channel.Post(message);

    /// <summary>A newer engine took this file over: let go without deleting or reporting.</summary>
    private void Relinquish(Guid id)
    {
        lock (_gate)
        {
            if (!_incoming.Remove(id, out var state)) return;
            state.Handle.Dispose();
            state.Hasher.Dispose();
        }
        _log.LogInformation("handed a partly received file over to a newer connection");
    }

    private string? Rejection(FileOffer offer, string directory, ulong alreadyHave)
    {
        if (offer.ByteCount > _config.MaxIncomingBytes) return $"The file is too large ({FormatBytes(offer.ByteCount)}).";
        var probe = directory;
        while (!Directory.Exists(probe) && Path.GetDirectoryName(probe) is { } parent && parent != probe) probe = parent;
        var free = FreeSpace(probe);
        if (free is { } available && available >= 0 && (ulong)available < offer.ByteCount - alreadyHave + _config.FreeSpaceMargin)
            return "There isn't enough free space for it.";
        return null;
    }

    private long? FreeSpace(string directory)
    {
        if (_config.Store is { } store) return store.GetAvailableFreeSpace(directory);
        try
        {
            return new DriveInfo(directory).AvailableFreeSpace;
        }
        catch (Exception error) when (error is ArgumentException or IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    private void ReceiveChunk(FileChunk chunk)
    {
        Incoming? failed = null;
        string reason = "";
        ulong progress = 0;
        var report = false;
        lock (_gate)
        {
            if (!_incoming.TryGetValue(chunk.Id, out var state)) return; // late chunks after a cancel
            if (chunk.Offset != state.Received || state.Received + (ulong)chunk.Data.Length > state.Offer.ByteCount)
            {
                failed = state;
                reason = "The file arrived damaged.";
            }
            else
            {
                try
                {
                    state.Handle.Write(chunk.Data.Span);
                    state.Hasher.AppendData(chunk.Data.Span);
                    state.Received += (ulong)chunk.Data.Length;
                    if (DateTime.UtcNow - state.LastProgress >= _config.ProgressInterval)
                    {
                        state.LastProgress = DateTime.UtcNow;
                        progress = state.Received;
                        report = true;
                    }
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException)
                {
                    _log.LogError("write failed: {Error}", error.Message);
                    failed = state;
                    reason = "The file couldn't be saved. The disk may be full.";
                }
            }
            if (failed is not null) _incoming.Remove(chunk.Id);
        }
        if (failed is not null)
        {
            Discard(failed);
            _channel.Post(new FileResult { Id = chunk.Id, Ok = false, Error = reason });
            Emit(new FileTransferEvent.Finished(chunk.Id, new FileTransferOutcome.Failed(reason)));
        }
        else if (report)
        {
            Emit(new FileTransferEvent.Progress(chunk.Id, progress));
        }
    }

    private void ReceiveComplete(FileComplete complete)
    {
        Incoming? state;
        lock (_gate)
        {
            if (!_incoming.Remove(complete.Id, out state)) return;
        }
        state.Handle.Dispose();
        var digest = state.Hasher.GetHashAndReset();
        if (state.Received != state.Offer.ByteCount || !CryptographicOperations.FixedTimeEquals(digest, complete.Sha256))
        {
            Discard(state);
            _log.LogError("incoming file failed its checksum ({Received}/{Total} bytes, resumed at {ResumedAt})",
                          state.Received, state.Offer.ByteCount, state.ResumedAt);
            Reply(new FileResult { Id = complete.Id, Ok = false, Error = "The file arrived damaged. Try sending it again." });
            Emit(new FileTransferEvent.Finished(complete.Id, new FileTransferOutcome.Failed("The file arrived damaged.")));
            return;
        }
        Emit(new FileTransferEvent.Progress(complete.Id, state.Received));
        try
        {
            var saved = Place(state);
            PartialClaims.Release(state.Partial, this);
            RunHook(() =>
            {
                if (_config.Sender is { } sender) _config.Store?.OnSaved(saved, state.Offer, sender);
                else _config.Store?.OnSaved(saved, state.Offer);
            });
            LogRate("received", state.Received - state.ResumedAt, state.Started, state.ResumedAt);
            // Saved whether or not the answer reaches the sender.
            Emit(new FileTransferEvent.Finished(complete.Id, new FileTransferOutcome.Received(saved)));
            Reply(new FileResult { Id = complete.Id, Ok = true, SavedName = Path.GetFileName(saved) });
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            Discard(state);
            _log.LogError("couldn't move received file into place: {Error}", error.Message);
            Reply(new FileResult { Id = complete.Id, Ok = false, Error = "The file couldn't be saved on the other device." });
            Emit(new FileTransferEvent.Finished(complete.Id, new FileTransferOutcome.Failed("The file couldn't be saved.")));
        }
        finally
        {
            state.Hasher.Dispose();
        }
    }

    /// <summary>Sets the modification date, clears Hidden, then renames to the first free name (8 tries).</summary>
    private string Place(Incoming state)
    {
        if (state.Offer.Modified is { } modified)
        {
            try
            {
                File.SetLastWriteTimeUtc(state.Partial, modified.UtcDateTime);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException)
            {
                // Not worth failing the file over.
            }
        }
        RunHook(() => _config.Store?.OnBeforeFinalize(state.Partial));
        IOException? last = null;
        for (var attempt = 0; attempt < 8; attempt++)
        {
            var target = FileNames.UniquePath(state.Name, state.Directory, _config.Store?.IsCaseInsensitive ?? false);
            try
            {
                File.Move(state.Partial, target, overwrite: false);
                return target;
            }
            catch (IOException error) when (File.Exists(target) || Directory.Exists(target))
            {
                last = error;
            }
        }
        throw last ?? new IOException("No free name.");
    }

    private void Discard(Incoming state)
    {
        state.Handle.Dispose();
        TryDelete(state.Partial);
        PartialClaims.Release(state.Partial, this);
    }

    private string FolderFor(Guid id) => _config.PartialDirectory?.Invoke(id) ?? _config.ReceiveDirectory;

    /// <summary>The partial path for a transfer id: <c>&lt;folder&gt;/.vantage-&lt;ID uppercase&gt;.partial</c>.</summary>
    public string PartialPath(Guid id) => Path.Combine(FolderFor(id), PartialName(id));

    /// <summary><c>.vantage-&lt;ID uppercase&gt;.partial</c>.</summary>
    public static string PartialName(Guid id) => PartialPrefix + id.ToString("D").ToUpperInvariant() + PartialSuffix;

    private void RemoveStalePartials()
    {
        try
        {
            if (!Directory.Exists(_config.ReceiveDirectory)) return;
            var cutoff = DateTime.UtcNow - _config.PartialLifetime;
            foreach (var path in Directory.EnumerateFiles(_config.ReceiveDirectory, PartialPrefix + "*" + PartialSuffix))
            {
                if (File.GetLastWriteTimeUtc(path) < cutoff && !PartialClaims.IsClaimed(path)) TryDelete(path);
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            _log.LogDebug("couldn't tidy partials: {Error}", error.Message);
        }
    }

    private void ShutDown(string reason)
    {
        Outgoing? outgoing;
        List<(Guid Id, Incoming State)> incoming;
        List<TaskCompletionSource> waiters;
        lock (_gate)
        {
            if (_isClosed) return;
            _isClosed = true;
            _rehashing?.Cancel();
            outgoing = _outgoing;
            incoming = [.. _incoming.Select(pair => (pair.Key, pair.Value))];
            _incoming.Clear();
            waiters = [.. _turnWaiters];
            _turnWaiters.Clear();
            _outgoingBusy = waiters.Count > 0;
        }
        _channel.Close();
        if (outgoing is not null)
        {
            outgoing.Stop.Cancel();
            outgoing.Window?.Abort(new IOException("The connection was closed."));
            outgoing.Deliver(new PeerReply.Closed());
        }
        foreach (var (id, state) in incoming)
        {
            // Kept for a resume; RemoveStalePartials deletes it if nobody comes back.
            state.Handle.Dispose();
            state.Hasher.Dispose();
            PartialClaims.Release(state.Partial, this);
            Emit(new FileTransferEvent.Finished(id, new FileTransferOutcome.Failed(reason)));
        }
        // Queued sends find the engine closed when their turn comes.
        foreach (var waiter in waiters) waiter.TrySetResult();
        _events.Writer.TryComplete();
    }

    // MARK: Helpers

    private void Emit(FileTransferEvent transferEvent) => _events.Writer.TryWrite(transferEvent);

    private async Task PumpEventsAsync()
    {
        await foreach (var transferEvent in _events.Reader.ReadAllAsync().ConfigureAwait(false))
        {
            try
            {
                Events?.Invoke(transferEvent);
            }
            catch (Exception error)
            {
                _log.LogError("file event handler failed: {Error}", error.Message);
            }
        }
        _finished.TrySetResult();
    }

    private void RunHook(Action hook)
    {
        try
        {
            hook();
        }
        catch (Exception error)
        {
            _log.LogError("file store hook failed: {Error}", error.Message);
        }
    }

    private void LogRate(string verb, ulong bytes, DateTime since, ulong resumedAt)
    {
        var seconds = Math.Max(0.000_001, (DateTime.UtcNow - since).TotalSeconds);
        _log.LogInformation("{Verb} {Bytes} bytes in {Ms} ms ({Rate:F1} MiB/s){Resumed}", verb, bytes, (int)(seconds * 1000),
                            bytes / seconds / 1_048_576, resumedAt > 0 ? $" after resuming at {resumedAt}" : "");
    }

    /// <summary>"70 GB", "1.2 MB": decimal units, like Finder.</summary>
    public static string FormatBytes(ulong bytes)
    {
        string[] units = ["bytes", "KB", "MB", "GB", "TB", "PB"];
        double value = bytes;
        var unit = 0;
        while (value >= 1000 && unit < units.Length - 1)
        {
            value /= 1000;
            unit++;
        }
        return unit == 0 ? $"{bytes} bytes" : value.ToString(value >= 100 ? "0" : "0.#", CultureInfo.InvariantCulture) + " " + units[unit];
    }

    /// <summary>
    /// Feeds the first <paramref name="length"/> bytes of a file into <paramref name="hasher"/> off
    /// the calling thread. False if the file is shorter, can't be read, or <paramref name="stop"/> fires.
    /// </summary>
    internal static Task<bool> HashPrefixAsync(string path, ulong length, IncrementalHash hasher, CancellationToken stop) =>
        Task.Run(() =>
        {
            try
            {
                using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1 << 20);
                var buffer = new byte[1 << 20];
                ulong done = 0;
                while (done < length)
                {
                    if (stop.IsCancellationRequested) return false;
                    var count = stream.Read(buffer, 0, (int)Math.Min((ulong)buffer.Length, length - done));
                    if (count == 0) return false;
                    hasher.AppendData(buffer, 0, count);
                    done += (ulong)count;
                }
                return true;
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                return false;
            }
        }, CancellationToken.None);

    private static ulong? FileSize(string path)
    {
        try
        {
            var info = new FileInfo(path);
            return info.Exists ? (ulong)info.Length : null;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    private static void TryDelete(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            // Left for the stale-partial sweep.
        }
    }

    private sealed class FileChangedException : Exception;

    private abstract record PeerReply
    {
        public sealed record Accept(FileAccept Message) : PeerReply;
        public sealed record Result(FileResult Message) : PeerReply;
        public sealed record Cancelled(bool ByPeer) : PeerReply;
        public sealed record Closed : PeerReply;
    }

    /// <summary>The file being sent.</summary>
    private sealed class Outgoing(Guid id)
    {
        private readonly Lock _lock = new();
        private readonly List<PeerReply> _replies = [];
        private TaskCompletionSource<PeerReply>? _waiter;

        public Guid Id { get; } = id;
        public CancellationTokenSource Stop { get; } = new();
        public volatile bool Cancelled;
        public volatile bool CancelledByPeer;
        public SendWindow? Window { get; set; }

        public void Deliver(PeerReply reply)
        {
            TaskCompletionSource<PeerReply>? waiter;
            lock (_lock)
            {
                waiter = _waiter;
                _waiter = null;
                if (waiter is null) _replies.Add(reply);
            }
            waiter?.TrySetResult(reply);
        }

        public Task<PeerReply> NextReplyAsync()
        {
            lock (_lock)
            {
                if (_replies.Count > 0)
                {
                    var reply = _replies[0];
                    _replies.RemoveAt(0);
                    return Task.FromResult(reply);
                }
                _waiter = new TaskCompletionSource<PeerReply>(TaskCreationOptions.RunContinuationsAsynchronously);
                return _waiter.Task;
            }
        }

        /// <summary>A reply that ends the transfer early (cancel, failure, close), as its outcome.</summary>
        public FileTransferOutcome? TakeTerminalReply()
        {
            lock (_lock)
            {
                var index = _replies.FindIndex(r => r is not PeerReply.Accept);
                if (index < 0) return Cancelled ? new FileTransferOutcome.Cancelled(false) : null;
                var reply = _replies[index];
                _replies.RemoveAt(index);
                return reply switch
                {
                    PeerReply.Result result => new FileTransferOutcome.Failed(result.Message.Error ?? "The other device couldn't save the file."),
                    PeerReply.Cancelled cancelled => new FileTransferOutcome.Cancelled(cancelled.ByPeer),
                    PeerReply.Closed => new FileTransferOutcome.Failed("The connection was lost."),
                    _ => null,
                };
            }
        }
    }

    /// <summary>A file being received.</summary>
    private sealed class Incoming(FileOffer offer, string name, string directory, string partial, FileStream handle, IncrementalHash hasher)
    {
        public FileOffer Offer { get; } = offer;
        public string Name { get; } = name;
        public string Directory { get; } = directory;
        public string Partial { get; } = partial;
        public FileStream Handle { get; } = handle;
        public IncrementalHash Hasher { get; } = hasher;
        public ulong Received { get; set; }
        public ulong ResumedAt { get; init; }
        public DateTime LastProgress { get; set; } = DateTime.UtcNow;
        public DateTime Started { get; } = DateTime.UtcNow;
    }

    /// <summary>Partials an engine in this process is writing, so a newer engine takes one over instead of two writing it.</summary>
    private static class PartialClaims
    {
        private static readonly Lock s_lock = new();
        private static readonly Dictionary<string, WeakReference<FileTransferEngine>> s_owners = new(StringComparer.Ordinal);

        public static FileTransferEngine? Claim(string path, FileTransferEngine engine)
        {
            var key = Path.GetFullPath(path);
            lock (s_lock)
            {
                FileTransferEngine? previous = null;
                if (s_owners.TryGetValue(key, out var owner) && owner.TryGetTarget(out var target) && !target.HasClosed) previous = target;
                s_owners[key] = new WeakReference<FileTransferEngine>(engine);
                return ReferenceEquals(previous, engine) ? null : previous;
            }
        }

        public static void Release(string path, FileTransferEngine engine)
        {
            var key = Path.GetFullPath(path);
            lock (s_lock)
            {
                if (!s_owners.TryGetValue(key, out var owner)) return;
                if (!owner.TryGetTarget(out var target) || ReferenceEquals(target, engine)) s_owners.Remove(key);
            }
        }

        public static bool IsClaimed(string path)
        {
            var key = Path.GetFullPath(path);
            lock (s_lock) return s_owners.TryGetValue(key, out var owner) && owner.TryGetTarget(out var target) && !target.HasClosed;
        }
    }
}

/// <summary>
/// Up to <c>size</c> sends in flight: acquire before handing a chunk to the connection, release
/// from its completion. The first send error (or an abort) fails every later call.
/// </summary>
internal sealed class SendWindow(int size)
{
    private readonly Lock _lock = new();
    private readonly Queue<TaskCompletionSource> _waiters = new();
    private readonly List<TaskCompletionSource> _drainers = [];
    private int _available = Math.Max(1, size);
    private int _inFlight;
    private Exception? _error;

    public Task AcquireAsync()
    {
        lock (_lock)
        {
            if (_error is not null) return Task.FromException(_error);
            if (_available > 0)
            {
                _available--;
                _inFlight++;
                return Task.CompletedTask;
            }
            var waiter = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            _waiters.Enqueue(waiter);
            return waiter.Task;
        }
    }

    public void Release(Exception? error)
    {
        List<TaskCompletionSource> wake = [];
        List<TaskCompletionSource> drained = [];
        Exception? failure;
        lock (_lock)
        {
            _inFlight--;
            if (error is not null) _error ??= error;
            failure = _error;
            if (failure is not null)
            {
                wake.AddRange(_waiters);
                _waiters.Clear();
                if (_inFlight == 0)
                {
                    drained.AddRange(_drainers);
                    _drainers.Clear();
                }
            }
            else if (_waiters.Count > 0)
            {
                _inFlight++;
                wake.Add(_waiters.Dequeue());
            }
            else
            {
                _available++;
                if (_inFlight == 0)
                {
                    drained.AddRange(_drainers);
                    _drainers.Clear();
                }
            }
        }
        foreach (var waiter in wake.Concat(drained))
        {
            if (failure is not null) waiter.TrySetException(failure); else waiter.TrySetResult();
        }
    }

    public Task DrainAsync()
    {
        lock (_lock)
        {
            if (_error is not null) return Task.FromException(_error);
            if (_inFlight == 0) return Task.CompletedTask;
            var drainer = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            _drainers.Add(drainer);
            return drainer.Task;
        }
    }

    public void Abort(Exception error)
    {
        List<TaskCompletionSource> pending;
        lock (_lock)
        {
            _error ??= error;
            pending = [.. _waiters, .. _drainers];
            _waiters.Clear();
            _drainers.Clear();
        }
        foreach (var waiter in pending) waiter.TrySetException(error);
    }
}
