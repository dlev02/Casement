using System.Runtime.InteropServices;
using Microsoft.Extensions.Logging;
using Vantage.Host.Windows.DesktopHelper;
using Vantage.Protocol.Input;
using Windows.Win32;
using Windows.Win32.UI.Input.KeyboardAndMouse;
using Windows.Win32.UI.WindowsAndMessaging;

namespace Vantage.Host.Windows.Input;

/// <summary>
/// <see cref="IInputInjector"/> with <c>SendInput</c>, mapped exactly as the interface documents:
/// absolute virtual-desktop moves, buttons (X buttons for back/forward) at the pointer position,
/// wheel/h-wheel, scan-code keys (<c>KEYEVENTF_EXTENDEDKEY</c> for E0 keys), and Unicode units.
/// One call is one <c>SendInput</c> batch, so a chord arrives uninterrupted.
/// </summary>
/// <remarks>
/// Needs a per-monitor-v2 DPI aware process (the host's manifest) so pixels are physical. Events
/// are tagged with <see cref="ExtraInfoTag"/> in <c>dwExtraInfo</c>, which tools/InputProbe shows.
/// UIPI blocks injection into elevated windows unless the host runs elevated, without saying so:
/// <c>SendInput</c> still reports every event sent. So a press aimed at an elevated window (the one
/// under a click, or the foreground one for a key) raises <see cref="ElevatedWindowBlocked"/> and is
/// logged, and <see cref="BlockedAppChanged"/> follows which app the latest press was dropped by
/// (the client's banner). Nothing reaches the secure desktop; <c>SendInput</c> then sends fewer events than asked,
/// which is logged (at most once a second).
/// <para>With Casement Host Service's desktop helper connected, input goes through the helper
/// (SYSTEM, so neither UIPI nor the secure desktop stops it) while the secure desktop has the input,
/// and from a press aimed at an elevated window until a press lands on an ordinary one; nothing is
/// reported blocked then.</para>
/// </remarks>
/// <param name="logger">Input logs.</param>
/// <param name="helper">The SYSTEM desktop helper, when Casement Host Service is installed.</param>
public sealed class SendInputInjector(ILogger logger, HelperClient? helper = null) : IInputInjector
{
    /// <summary><c>dwExtraInfo</c> on every event this host injects ("VANT").</summary>
    public const nuint ExtraInfoTag = 0x56414E54;

    private long _lastBlockedLog;
    private nint _lastElevatedWindow;
    private long _lastElevatedReport;
    private string? _blockedApp;
    private bool _elevatedTarget;

    /// <summary>
    /// Raised on the input thread when a click or key press went to a window of an elevated process
    /// while this host isn't elevated (so Windows dropped it); at most once a minute per window.
    /// </summary>
    public event Action<ElevatedWindow>? ElevatedWindowBlocked;

    /// <summary>
    /// Raised on the input thread when the app the latest press was dropped by changes: its name
    /// when a press goes to an elevated window, null when one reaches an ordinary window again.
    /// </summary>
    public event Action<string?>? BlockedAppChanged;

    /// <inheritdoc />
    public void Send(ReadOnlySpan<InputAction> actions)
    {
        if (actions.IsEmpty) return;
        var secure = helper?.IsSecureDesktopUp == true;
        // Window lookups mean nothing while the secure desktop has the input.
        if (!ElevatedWindows.ThisProcessIsElevated && !secure) CheckElevatedTarget(actions);
        if ((secure || _elevatedTarget) && helper!.SendInput(actions)) return;
        var sent = InputBatch.Send(actions);
        if (sent != actions.Length)
        {
            var now = Environment.TickCount64;
            if (now - Interlocked.Read(ref _lastBlockedLog) > 1000)
            {
                Interlocked.Exchange(ref _lastBlockedLog, now);
                logger.LogWarning("SendInput delivered {Sent} of {Count} events (error {Error}): the secure desktop or an elevated window has the input",
                                  sent, actions.Length, Marshal.GetLastPInvokeError());
            }
        }
    }

    private void CheckElevatedTarget(ReadOnlySpan<InputAction> actions)
    {
        ElevatedWindow? target = null;
        var pressed = false;
        foreach (var action in actions)
        {
            if (!action.IsDown) continue;
            if (action.Type == InputActionType.MouseButton) target = ElevatedWindows.At(action.X, action.Y);
            else if (action.Type is InputActionType.Key or InputActionType.Unicode) target = ElevatedWindows.Foreground();
            else continue;
            pressed = true;
            break;
        }
        if (!pressed) return;

        // Moves, scrolls and releases leave the state as it was; a press decides it.
        var helperCovers = helper?.IsConnected == true;
        _elevatedTarget = target is not null && helperCovers;
        var blocked = helperCovers ? null : target?.Name;
        if (blocked != _blockedApp)
        {
            _blockedApp = blocked;
            BlockedAppChanged?.Invoke(blocked);
        }
        if (target is null || helperCovers) return;

        var now = Environment.TickCount64;
        if (target.Handle == _lastElevatedWindow && now - _lastElevatedReport < 60_000) return;
        _lastElevatedWindow = target.Handle;
        _lastElevatedReport = now;
        logger.LogWarning("input to {Window} was dropped: it runs as administrator and Casement Host doesn't", target.Name);
        ElevatedWindowBlocked?.Invoke(target);
    }

    /// <summary>A 1-pixel relative move right and back (wakes a sleeping display; the pointer ends where it was).</summary>
    public static unsafe void Nudge()
    {
        Span<INPUT> inputs = stackalloc INPUT[2];
        inputs[0] = new INPUT { type = INPUT_TYPE.INPUT_MOUSE };
        inputs[0].mi = new MOUSEINPUT { dx = 1, dy = 0, dwFlags = MOUSE_EVENT_FLAGS.MOUSEEVENTF_MOVE, dwExtraInfo = ExtraInfoTag };
        inputs[1] = new INPUT { type = INPUT_TYPE.INPUT_MOUSE };
        inputs[1].mi = new MOUSEINPUT { dx = -1, dy = 0, dwFlags = MOUSE_EVENT_FLAGS.MOUSEEVENTF_MOVE, dwExtraInfo = ExtraInfoTag };
        PInvoke.SendInput(inputs, sizeof(INPUT));
    }
}

/// <summary>
/// An <see cref="IInputInjector"/> that only logs (<c>--synthetic</c> runs of the Windows CLI, so a
/// test client can't move the real pointer).
/// </summary>
public sealed class LoggingInputInjector(ILogger logger) : IInputInjector
{
    /// <inheritdoc />
    public void Send(ReadOnlySpan<InputAction> actions)
    {
        foreach (var action in actions) logger.LogInformation("input: {Action}", action);
    }
}
