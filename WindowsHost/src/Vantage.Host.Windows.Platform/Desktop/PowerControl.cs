using Microsoft.Extensions.Logging;
using Vantage.Host.Windows.Input;
using Vantage.Protocol.Host;
using Windows.Win32;
using Windows.Win32.System.Power;
using static Vantage.Host.Windows.Interop.Win32Constants;

namespace Vantage.Host.Windows.Desktop;

/// <summary>
/// <see cref="IPowerControl"/> for Windows (spec §9.4): <c>SetThreadExecutionState(ES_CONTINUOUS |
/// ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED)</c> held by one dedicated thread while any session asks
/// (execution state is per thread, so the same thread sets and clears it), <c>SC_MONITORPOWER 2</c>
/// posted to the host's own window to turn the display off, a 1-pixel <c>SendInput</c> nudge plus
/// <c>ES_DISPLAY_REQUIRED</c> to wake it, and <c>LockWorkStation</c>.
/// </summary>
public sealed class PowerControl : IPowerControl, IDisposable
{
    private readonly MessageWindow _window;
    private readonly ILogger _log;
    private readonly Thread _keeper;
    private readonly AutoResetEvent _changed = new(false);
    private int _holders;
    private volatile bool _disposed;

    /// <param name="window">The host's message window (receives <c>SC_MONITORPOWER</c>).</param>
    /// <param name="logging">Loggers (category <c>Vantage.Power</c>).</param>
    public PowerControl(MessageWindow window, ILoggerFactory logging)
    {
        _window = window;
        _log = logging.CreateLogger("Vantage.Power");
        _keeper = new Thread(KeepAwakeLoop) { IsBackground = true, Name = "Vantage keep-awake" };
        _keeper.Start();
    }

    /// <inheritdoc />
    public IDisposable KeepAwake()
    {
        Interlocked.Increment(ref _holders);
        _changed.Set();
        return new Release(this);
    }

    /// <inheritdoc />
    public void SleepDisplay()
    {
        _log.LogInformation("turning the display off");
        PInvoke.PostMessage(_window.Hwnd, WM_SYSCOMMAND, (nuint)SC_MONITORPOWER, 2);
    }

    /// <inheritdoc />
    public void WakeDisplay()
    {
        SendInputInjector.Nudge();
        PInvoke.SetThreadExecutionState(EXECUTION_STATE.ES_DISPLAY_REQUIRED);
    }

    /// <inheritdoc />
    public void LockScreen()
    {
        if (!PInvoke.LockWorkStation()) _log.LogWarning("LockWorkStation failed");
    }

    /// <inheritdoc />
    public void Dispose()
    {
        _disposed = true;
        _changed.Set();
        _keeper.Join(TimeSpan.FromSeconds(1));
    }

    private void KeepAwakeLoop()
    {
        var holding = false;
        while (!_disposed)
        {
            _changed.WaitOne();
            var want = !_disposed && Volatile.Read(ref _holders) > 0;
            if (want == holding) continue;
            holding = want;
            PInvoke.SetThreadExecutionState(want
                ? EXECUTION_STATE.ES_CONTINUOUS | EXECUTION_STATE.ES_SYSTEM_REQUIRED | EXECUTION_STATE.ES_DISPLAY_REQUIRED
                : EXECUTION_STATE.ES_CONTINUOUS);
            _log.LogDebug(want ? "keeping the PC and display awake" : "letting the PC sleep again");
        }
        if (holding) PInvoke.SetThreadExecutionState(EXECUTION_STATE.ES_CONTINUOUS);
    }

    private sealed class Release(PowerControl owner) : IDisposable
    {
        private int _done;

        public void Dispose()
        {
            if (Interlocked.Exchange(ref _done, 1) != 0) return;
            Interlocked.Decrement(ref owner._holders);
            owner._changed.Set();
        }
    }
}

/// <summary>Power control that only logs (synthetic runs never touch the real display).</summary>
public sealed class LoggingPowerControl(ILogger logger) : IPowerControl
{
    /// <inheritdoc />
    public IDisposable KeepAwake() => new Nothing();

    /// <inheritdoc />
    public void SleepDisplay() => logger.LogInformation("(synthetic) sleep display");

    /// <inheritdoc />
    public void WakeDisplay() => logger.LogInformation("(synthetic) wake display");

    /// <inheritdoc />
    public void LockScreen() => logger.LogInformation("(synthetic) lock screen");

    private sealed class Nothing : IDisposable
    {
        public void Dispose()
        {
        }
    }
}

/// <summary>A status source that never changes (synthetic runs).</summary>
public sealed class StaticHostStatus : IHostStatusSource
{
    /// <inheritdoc />
    public HostConditions Current { get; } = new(false, false, false, null);

    /// <inheritdoc />
    public IDisposable Watch(Action onChanged) => new Nothing();

    private sealed class Nothing : IDisposable
    {
        public void Dispose()
        {
        }
    }
}
