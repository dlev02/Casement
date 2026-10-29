using System.Runtime.InteropServices;
using Microsoft.Extensions.Logging;
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
/// logged. Nothing reaches the secure desktop; <c>SendInput</c> then sends fewer events than asked,
/// which is logged (at most once a second).
/// </remarks>
public sealed class SendInputInjector(ILogger logger) : IInputInjector
{
    /// <summary><c>dwExtraInfo</c> on every event this host injects ("VANT").</summary>
    public const nuint ExtraInfoTag = 0x56414E54;

    private long _lastBlockedLog;
    private nint _lastElevatedWindow;
    private long _lastElevatedReport;

    /// <summary>
    /// Raised on the input thread when a click or key press went to a window of an elevated process
    /// while this host isn't elevated (so Windows dropped it); at most once a minute per window.
    /// </summary>
    public event Action<ElevatedWindow>? ElevatedWindowBlocked;

    /// <inheritdoc />
    public unsafe void Send(ReadOnlySpan<InputAction> actions)
    {
        if (actions.IsEmpty) return;
        if (!ElevatedWindows.ThisProcessIsElevated) CheckElevatedTarget(actions);
        var left = PInvoke.GetSystemMetrics(SYSTEM_METRICS_INDEX.SM_XVIRTUALSCREEN);
        var top = PInvoke.GetSystemMetrics(SYSTEM_METRICS_INDEX.SM_YVIRTUALSCREEN);
        var width = PInvoke.GetSystemMetrics(SYSTEM_METRICS_INDEX.SM_CXVIRTUALSCREEN);
        var height = PInvoke.GetSystemMetrics(SYSTEM_METRICS_INDEX.SM_CYVIRTUALSCREEN);

        Span<INPUT> inputs = actions.Length <= 32 ? stackalloc INPUT[actions.Length] : new INPUT[actions.Length];
        for (var i = 0; i < actions.Length; i++)
            inputs[i] = Build(actions[i], left, top, width, height);

        var sent = PInvoke.SendInput(inputs, sizeof(INPUT));
        if (sent != inputs.Length)
        {
            var now = Environment.TickCount64;
            if (now - Interlocked.Read(ref _lastBlockedLog) > 1000)
            {
                Interlocked.Exchange(ref _lastBlockedLog, now);
                logger.LogWarning("SendInput delivered {Sent} of {Count} events (error {Error}): the secure desktop or an elevated window has the input",
                                  sent, inputs.Length, Marshal.GetLastPInvokeError());
            }
        }
    }

    private void CheckElevatedTarget(ReadOnlySpan<InputAction> actions)
    {
        ElevatedWindow? target = null;
        foreach (var action in actions)
        {
            if (!action.IsDown) continue;
            if (action.Type == InputActionType.MouseButton) target = ElevatedWindows.At(action.X, action.Y);
            else if (action.Type is InputActionType.Key or InputActionType.Unicode) target = ElevatedWindows.Foreground();
            else continue;
            break;
        }
        if (target is null) return;

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

    private static INPUT Build(in InputAction action, int left, int top, int width, int height)
    {
        var input = new INPUT();
        switch (action.Type)
        {
            case InputActionType.MouseMove:
                input.type = INPUT_TYPE.INPUT_MOUSE;
                input.mi = Absolute(action.X, action.Y, left, top, width, height, 0);
                break;

            case InputActionType.MouseButton:
                input.type = INPUT_TYPE.INPUT_MOUSE;
                var (flag, data) = ButtonFlags(action.Button, action.IsDown);
                input.mi = Absolute(action.X, action.Y, left, top, width, height, flag);
                input.mi.mouseData = data;
                break;

            case InputActionType.Wheel:
            case InputActionType.HorizontalWheel:
                input.type = INPUT_TYPE.INPUT_MOUSE;
                input.mi = new MOUSEINPUT
                {
                    mouseData = unchecked((uint)action.WheelDelta),
                    dwFlags = action.Type == InputActionType.Wheel ? MOUSE_EVENT_FLAGS.MOUSEEVENTF_WHEEL : MOUSE_EVENT_FLAGS.MOUSEEVENTF_HWHEEL,
                    dwExtraInfo = ExtraInfoTag,
                };
                break;

            case InputActionType.Key:
                input.type = INPUT_TYPE.INPUT_KEYBOARD;
                var keyFlags = KEYBD_EVENT_FLAGS.KEYEVENTF_SCANCODE;
                if (action.IsExtended) keyFlags |= KEYBD_EVENT_FLAGS.KEYEVENTF_EXTENDEDKEY;
                if (!action.IsDown) keyFlags |= KEYBD_EVENT_FLAGS.KEYEVENTF_KEYUP;
                input.ki = new KEYBDINPUT { wVk = 0, wScan = action.ScanCode, dwFlags = keyFlags, dwExtraInfo = ExtraInfoTag };
                break;

            case InputActionType.Unicode:
                input.type = INPUT_TYPE.INPUT_KEYBOARD;
                var unicodeFlags = KEYBD_EVENT_FLAGS.KEYEVENTF_UNICODE;
                if (!action.IsDown) unicodeFlags |= KEYBD_EVENT_FLAGS.KEYEVENTF_KEYUP;
                input.ki = new KEYBDINPUT { wVk = 0, wScan = action.Unicode, dwFlags = unicodeFlags, dwExtraInfo = ExtraInfoTag };
                break;
        }
        return input;
    }

    private static MOUSEINPUT Absolute(int x, int y, int left, int top, int width, int height, MOUSE_EVENT_FLAGS extra) => new()
    {
        dx = AbsoluteCoordinates.Normalize(x, left, width),
        dy = AbsoluteCoordinates.Normalize(y, top, height),
        dwFlags = MOUSE_EVENT_FLAGS.MOUSEEVENTF_MOVE | MOUSE_EVENT_FLAGS.MOUSEEVENTF_ABSOLUTE | MOUSE_EVENT_FLAGS.MOUSEEVENTF_VIRTUALDESK | extra,
        dwExtraInfo = ExtraInfoTag,
    };

    private static (MOUSE_EVENT_FLAGS Flag, uint Data) ButtonFlags(MouseButton button, bool down) => button switch
    {
        MouseButton.Left => (down ? MOUSE_EVENT_FLAGS.MOUSEEVENTF_LEFTDOWN : MOUSE_EVENT_FLAGS.MOUSEEVENTF_LEFTUP, 0u),
        MouseButton.Right => (down ? MOUSE_EVENT_FLAGS.MOUSEEVENTF_RIGHTDOWN : MOUSE_EVENT_FLAGS.MOUSEEVENTF_RIGHTUP, 0u),
        MouseButton.Middle => (down ? MOUSE_EVENT_FLAGS.MOUSEEVENTF_MIDDLEDOWN : MOUSE_EVENT_FLAGS.MOUSEEVENTF_MIDDLEUP, 0u),
        MouseButton.Back => (down ? MOUSE_EVENT_FLAGS.MOUSEEVENTF_XDOWN : MOUSE_EVENT_FLAGS.MOUSEEVENTF_XUP, 1u), // XBUTTON1
        MouseButton.Forward => (down ? MOUSE_EVENT_FLAGS.MOUSEEVENTF_XDOWN : MOUSE_EVENT_FLAGS.MOUSEEVENTF_XUP, 2u), // XBUTTON2
        _ => (0, 0u),
    };
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
