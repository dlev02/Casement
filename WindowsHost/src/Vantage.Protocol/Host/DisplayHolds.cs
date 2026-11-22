using Microsoft.Extensions.Logging;
using Vantage.Protocol.Messages;

namespace Vantage.Protocol.Host;

/// <summary>
/// Who holds a fitted display: a device (its key's fingerprint), through whichever of its sessions
/// fitted it last. One per listener, in front of <see cref="IDisplayFitter"/>, which sees one owner
/// per device. So a device that reconnects takes over its own fitted mode (the same viewport is
/// <see cref="DisplayFitResult.Unchanged"/>, no switch at all) even while its old session hasn't
/// noticed the connection is gone, and a session that ends without the device saying goodbye
/// (a dropped connection, the app sent to the background) lets go after <see cref="ReconnectGrace"/>
/// rather than at once, so the reconnect that usually follows finds the mode still fitted instead
/// of switching the display back and then forth again. A goodbye (<c>disconnect</c>, a revoke),
/// <c>restoreDisplays</c>, Fit Display turned off, and the listener stopping restore at once.
/// </summary>
/// <remarks>
/// Thread-safe: sessions call it from their own queues and the grace timer from the thread pool.
/// Another device asking to fit while a hold is in its grace gets the display at once (the held
/// mode goes back first), never <see cref="DisplayFitResult.Busy"/> for a device that has left.
/// </remarks>
internal sealed class DisplayHolds(IDisplayFitter fitter, TimeProvider time, ILogger log)
{
    /// <summary>How long a mode stays fitted after its session ended without a goodbye.</summary>
    public static readonly TimeSpan ReconnectGrace = TimeSpan.FromSeconds(10);

    private readonly Lock _lock = new();
    private readonly Dictionary<string, Holder> _holders = [];
    private bool _stopped;

    /// <summary>A device's hold: the owner the fitter knows it by, its current session (null while in its grace), and the grace timer.</summary>
    private sealed class Holder
    {
        public Guid FitterOwner { get; } = Guid.NewGuid();
        public Guid? Session { get; set; }
        public ITimer? Grace { get; set; }
    }

    /// <summary>Whether devices may change the display mode now.</summary>
    public bool IsEnabled => fitter.IsEnabled;

    /// <summary>
    /// <paramref name="session"/> of <paramref name="device"/> wants <paramref name="display"/> fitted
    /// to <paramref name="viewport"/>: it becomes the device's holding session, cancelling any grace.
    /// </summary>
    public DisplayFitResult Fit(Guid session, string device, DisplayInfo display, Viewport viewport)
    {
        lock (_lock)
        {
            foreach (var (other, held) in _holders.Where(h => h.Key != device && h.Value.Session is null).ToList())
            {
                // That device left; its grace ends now so this one can fit the display.
                log.LogInformation("ending another device's grace so this one can fit the display");
                RestoreLocked(other, held);
            }
            if (!_holders.TryGetValue(device, out var holder))
            {
                holder = new Holder();
                _holders[device] = holder;
            }
            else if (holder.Session is null)
            {
                log.LogInformation("device came back within its grace; the fitted mode stays");
            }
            holder.Grace?.Dispose();
            holder.Grace = null;
            holder.Session = session;
            return fitter.Fit(holder.FitterOwner, display, viewport);
        }
    }

    /// <summary>
    /// Puts back what <paramref name="device"/> fitted, now, if <paramref name="session"/> is the one
    /// holding it (a newer session of the same device keeps it). True when a mode changed.
    /// </summary>
    public bool Restore(Guid session, string device)
    {
        lock (_lock)
        {
            if (!_holders.TryGetValue(device, out var holder) || holder.Session != session) return false;
            return RestoreLocked(device, holder);
        }
    }

    /// <summary>
    /// <paramref name="session"/> ended without a goodbye: if it holds the device's display, the mode
    /// goes back after <see cref="ReconnectGrace"/> unless a session of the same device fits it first.
    /// </summary>
    public void Release(Guid session, string device)
    {
        lock (_lock)
        {
            if (!_holders.TryGetValue(device, out var holder) || holder.Session != session) return;
            if (_stopped)
            {
                RestoreLocked(device, holder);
                return;
            }
            holder.Session = null;
            holder.Grace = time.CreateTimer(_ => Expire(device, holder), null, ReconnectGrace, Timeout.InfiniteTimeSpan);
            log.LogInformation("session ended without a goodbye; the display mode stays fitted for {Seconds} s in case the device reconnects",
                               ReconnectGrace.TotalSeconds);
        }
    }

    /// <summary>The listener is stopping: every fitted mode goes back now, and later releases restore at once.</summary>
    public void RestoreAll()
    {
        lock (_lock)
        {
            _stopped = true;
            foreach (var holder in _holders.Values) holder.Grace?.Dispose();
            _holders.Clear();
        }
        fitter.RestoreAll();
    }

    private void Expire(string device, Holder holder)
    {
        lock (_lock)
        {
            if (!_holders.TryGetValue(device, out var current) || current != holder || holder.Session is not null) return;
            if (RestoreLocked(device, holder)) log.LogInformation("display mode restored: the device didn't come back within {Seconds} s", ReconnectGrace.TotalSeconds);
        }
    }

    private bool RestoreLocked(string device, Holder holder)
    {
        holder.Grace?.Dispose();
        holder.Grace = null;
        _holders.Remove(device);
        try
        {
            return fitter.Restore(holder.FitterOwner);
        }
        catch (Exception error)
        {
            log.LogError("restoring the display mode failed: {Error}", error.Message);
            return false;
        }
    }
}
