namespace Vantage.Host.Windows.Files;

/// <summary>
/// Groups files that arrive together (the Mac's <c>ArrivalBatcher</c>): a batch is released 1.5 s
/// after the last file, or 20 s after its first, so ten files make one notification and one
/// Explorer window. Thread-safe; the callback runs on a timer thread.
/// </summary>
public sealed class ArrivalBatcher : IDisposable
{
    /// <summary>Quiet time after the last file.</summary>
    public static readonly TimeSpan Quiet = TimeSpan.FromSeconds(1.5);

    /// <summary>Longest a batch waits after its first file.</summary>
    public static readonly TimeSpan MaxWait = TimeSpan.FromSeconds(20);

    private readonly TimeProvider _time;
    private readonly Action<IReadOnlyList<string>> _release;
    private readonly Lock _lock = new();
    private readonly List<string> _paths = [];
    private readonly ITimer _timer;
    private DateTimeOffset _firstAt;

    /// <param name="release">Called with each batch, in arrival order.</param>
    /// <param name="time">Clock (tests use a fake).</param>
    public ArrivalBatcher(Action<IReadOnlyList<string>> release, TimeProvider? time = null)
    {
        _release = release;
        _time = time ?? TimeProvider.System;
        _timer = _time.CreateTimer(_ => Flush(), null, Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);
    }

    /// <summary>Adds a saved file.</summary>
    public void Add(string path)
    {
        lock (_lock)
        {
            var now = _time.GetUtcNow();
            if (_paths.Count == 0) _firstAt = now;
            _paths.Add(path);
            var due = Min(Quiet, _firstAt + MaxWait - now);
            _timer.Change(due < TimeSpan.Zero ? TimeSpan.Zero : due, Timeout.InfiniteTimeSpan);
        }
    }

    /// <summary>Releases whatever is waiting now.</summary>
    public void Flush()
    {
        string[] batch;
        lock (_lock)
        {
            if (_paths.Count == 0) return;
            batch = [.. _paths];
            _paths.Clear();
        }
        _release(batch);
    }

    /// <inheritdoc />
    public void Dispose() => _timer.Dispose();

    private static TimeSpan Min(TimeSpan a, TimeSpan b) => a < b ? a : b;
}
