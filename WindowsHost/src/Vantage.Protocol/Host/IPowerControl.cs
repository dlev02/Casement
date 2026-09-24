namespace Vantage.Protocol.Host;

/// <summary>Display power, keep-awake and locking (spec §9.4). The core decides when; this only does.</summary>
public interface IPowerControl
{
    /// <summary>
    /// Keeps the machine and display awake while a screen session runs (Windows:
    /// <c>SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED)</c> held on a
    /// dedicated thread). Disposing the result lets go. Sessions may overlap; each holds its own.
    /// An explicit <see cref="SleepDisplay"/> still turns the monitor off.
    /// </summary>
    IDisposable KeepAwake();

    /// <summary>Turns the display off now (Windows: <c>SendMessage(ownHwnd, WM_SYSCOMMAND, SC_MONITORPOWER, 2)</c>).</summary>
    void SleepDisplay();

    /// <summary>
    /// Wakes the display (Windows: a 1 px <c>SendInput</c> move and back, plus
    /// <c>SetThreadExecutionState(ES_DISPLAY_REQUIRED)</c>). The core rate-limits calls.
    /// </summary>
    void WakeDisplay();

    /// <summary>Locks the session (Windows: <c>LockWorkStation()</c>).</summary>
    void LockScreen();
}
