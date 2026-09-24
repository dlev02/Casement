using System.Threading.Channels;
using Microsoft.Extensions.Logging;

namespace Vantage.Protocol.Host;

/// <summary>
/// Runs work items one at a time, in the order posted (a session's "actor"). A work item may
/// await; nothing else runs until it finishes, so it must never wait for something that itself
/// needs the queue.
/// </summary>
internal sealed class SerialQueue
{
    private readonly Channel<Func<Task>> _work = Channel.CreateUnbounded<Func<Task>>(new() { SingleReader = true });
    private readonly ILogger _log;

    public SerialQueue(ILogger log)
    {
        _log = log;
        Completion = Task.Run(RunAsync);
    }

    /// <summary>Completes after <see cref="Complete"/> once the queue has drained.</summary>
    public Task Completion { get; }

    /// <summary>Queues work; false once the queue is closed.</summary>
    public bool Post(Func<Task> work) => _work.Writer.TryWrite(work);

    /// <summary>Queues synchronous work.</summary>
    public bool Post(Action work) => Post(() =>
    {
        work();
        return Task.CompletedTask;
    });

    /// <summary>Queues work and completes when it has run (faults if it threw, cancels if the queue closed first).</summary>
    public Task RunAsync(Func<Task> work)
    {
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!Post(async () =>
            {
                try
                {
                    await work().ConfigureAwait(false);
                    done.TrySetResult();
                }
                catch (Exception error)
                {
                    done.TrySetException(error);
                }
            }))
        {
            done.TrySetCanceled();
        }
        return done.Task;
    }

    /// <summary>Stops taking work; what's queued still runs.</summary>
    public void Complete() => _work.Writer.TryComplete();

    private async Task RunAsync()
    {
        await foreach (var work in _work.Reader.ReadAllAsync().ConfigureAwait(false))
        {
            try
            {
                await work().ConfigureAwait(false);
            }
            catch (Exception error)
            {
                _log.LogError(error, "session work failed");
            }
        }
    }
}
