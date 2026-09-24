using System.Collections.Concurrent;

namespace Vantage.Host.Windows.Encode;

/// <summary>One dedicated thread running posted actions in order (the synchronous software encoder).</summary>
internal sealed class BlockingWorker : IDisposable
{
    private readonly BlockingCollection<Action> _work = new();
    private readonly Thread _thread;

    public BlockingWorker(string name)
    {
        _thread = new Thread(Run) { IsBackground = true, Name = name };
        _thread.Start();
    }

    public void Post(Action action)
    {
        if (!_work.IsAddingCompleted) _work.Add(action);
    }

    public void Dispose()
    {
        _work.CompleteAdding();
        _thread.Join(TimeSpan.FromSeconds(2));
    }

    private void Run()
    {
        foreach (var action in _work.GetConsumingEnumerable()) action();
    }
}
