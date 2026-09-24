namespace Vantage.Protocol.Files;

/// <summary>Which way a file moves, from this host's point of view.</summary>
public enum FileDirection
{
    /// <summary>Host → client.</summary>
    Sending,
    /// <summary>Client → host.</summary>
    Receiving,
}

/// <summary>A file the engine is moving.</summary>
/// <param name="Id">The transfer id (the same across resumes).</param>
/// <param name="Name">The offered name (sanitised for receives).</param>
/// <param name="ByteCount">Total size.</param>
/// <param name="Direction">Which way.</param>
public sealed record FileTransferItem(Guid Id, string Name, ulong ByteCount, FileDirection Direction);

/// <summary>How one transfer ended.</summary>
public abstract record FileTransferOutcome
{
    private protected FileTransferOutcome() { }

    /// <summary>The client saved it (under <paramref name="SavedName"/>, if it said).</summary>
    public sealed record Sent(string? SavedName) : FileTransferOutcome;

    /// <summary>Saved on this host at <paramref name="Path"/>.</summary>
    public sealed record Received(string Path) : FileTransferOutcome;

    /// <summary>Failed with a user-facing reason. A lost connection keeps an incoming partial for resume.</summary>
    public sealed record Failed(string Reason) : FileTransferOutcome;

    /// <summary>Cancelled, by the other side or here.</summary>
    public sealed record Cancelled(bool ByPeer) : FileTransferOutcome;

    /// <summary>Sent or received.</summary>
    public bool IsSuccess => this is Sent or Received;
}

/// <summary>Progress reports from a file engine, in order per transfer.</summary>
public abstract record FileTransferEvent
{
    private protected FileTransferEvent() { }

    /// <summary>A transfer began (or resumed).</summary>
    public sealed record Started(FileTransferItem Item) : FileTransferEvent;

    /// <summary><paramref name="Bytes"/> of the file are done (resumed prefix included); at most a few per second.</summary>
    public sealed record Progress(Guid Id, ulong Bytes) : FileTransferEvent;

    /// <summary>The transfer ended.</summary>
    public sealed record Finished(Guid Id, FileTransferOutcome Outcome) : FileTransferEvent;
}
