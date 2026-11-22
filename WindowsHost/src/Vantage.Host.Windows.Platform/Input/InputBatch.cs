using Vantage.Protocol.Input;
using Windows.Win32;
using Windows.Win32.UI.Input.KeyboardAndMouse;
using Windows.Win32.UI.WindowsAndMessaging;

namespace Vantage.Host.Windows.Input;

/// <summary>
/// <see cref="InputAction"/>s as one <c>SendInput</c> call, mapped as <see cref="IInputInjector"/>
/// documents. Shared by the host (<see cref="SendInputInjector"/>) and the SYSTEM desktop helper,
/// which sends the same events on the secure desktop. Every event carries
/// <see cref="SendInputInjector.ExtraInfoTag"/>.
/// </summary>
internal static class InputBatch
{
    /// <summary>Sends the batch on the calling thread's desktop; how many events Windows took.</summary>
    public static unsafe uint Send(ReadOnlySpan<InputAction> actions)
    {
        if (actions.IsEmpty) return 0;
        var left = PInvoke.GetSystemMetrics(SYSTEM_METRICS_INDEX.SM_XVIRTUALSCREEN);
        var top = PInvoke.GetSystemMetrics(SYSTEM_METRICS_INDEX.SM_YVIRTUALSCREEN);
        var width = PInvoke.GetSystemMetrics(SYSTEM_METRICS_INDEX.SM_CXVIRTUALSCREEN);
        var height = PInvoke.GetSystemMetrics(SYSTEM_METRICS_INDEX.SM_CYVIRTUALSCREEN);

        Span<INPUT> inputs = actions.Length <= 32 ? stackalloc INPUT[actions.Length] : new INPUT[actions.Length];
        for (var i = 0; i < actions.Length; i++)
            inputs[i] = Build(actions[i], left, top, width, height);
        return PInvoke.SendInput(inputs, sizeof(INPUT));
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
                    dwExtraInfo = SendInputInjector.ExtraInfoTag,
                };
                break;

            case InputActionType.Key:
                input.type = INPUT_TYPE.INPUT_KEYBOARD;
                var keyFlags = KEYBD_EVENT_FLAGS.KEYEVENTF_SCANCODE;
                if (action.IsExtended) keyFlags |= KEYBD_EVENT_FLAGS.KEYEVENTF_EXTENDEDKEY;
                if (!action.IsDown) keyFlags |= KEYBD_EVENT_FLAGS.KEYEVENTF_KEYUP;
                input.ki = new KEYBDINPUT { wVk = 0, wScan = action.ScanCode, dwFlags = keyFlags, dwExtraInfo = SendInputInjector.ExtraInfoTag };
                break;

            case InputActionType.Unicode:
                input.type = INPUT_TYPE.INPUT_KEYBOARD;
                var unicodeFlags = KEYBD_EVENT_FLAGS.KEYEVENTF_UNICODE;
                if (!action.IsDown) unicodeFlags |= KEYBD_EVENT_FLAGS.KEYEVENTF_KEYUP;
                input.ki = new KEYBDINPUT { wVk = 0, wScan = action.Unicode, dwFlags = unicodeFlags, dwExtraInfo = SendInputInjector.ExtraInfoTag };
                break;
        }
        return input;
    }

    private static MOUSEINPUT Absolute(int x, int y, int left, int top, int width, int height, MOUSE_EVENT_FLAGS extra) => new()
    {
        dx = AbsoluteCoordinates.Normalize(x, left, width),
        dy = AbsoluteCoordinates.Normalize(y, top, height),
        dwFlags = MOUSE_EVENT_FLAGS.MOUSEEVENTF_MOVE | MOUSE_EVENT_FLAGS.MOUSEEVENTF_ABSOLUTE | MOUSE_EVENT_FLAGS.MOUSEEVENTF_VIRTUALDESK | extra,
        dwExtraInfo = SendInputInjector.ExtraInfoTag,
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
