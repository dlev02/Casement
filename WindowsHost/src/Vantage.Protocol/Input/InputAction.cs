namespace Vantage.Protocol.Input;

/// <summary>
/// Injects primitive input events: the one part of Windows input that calls <c>SendInput</c>.
/// Everything that decides <em>what</em> to send lives in <see cref="WindowsInputTranslator"/>.
/// </summary>
public interface IInputInjector
{
    /// <summary>
    /// Sends <paramref name="actions"/> in order, as one <c>SendInput</c> batch where possible (a
    /// chord's modifier presses, the key, and the releases arrive together).
    /// </summary>
    /// <remarks>
    /// Mapping to <c>INPUT</c>:
    /// <list type="bullet">
    /// <item><see cref="InputActionType.MouseMove"/>: <c>MOUSEEVENTF_MOVE | ABSOLUTE | VIRTUALDESK</c>,
    /// <c>dx = round((X − vx) × 65535 / (vw − 1))</c> with the virtual screen's left/width (and the same for y).
    /// The process must be per-monitor-v2 DPI aware so X/Y are physical pixels.</item>
    /// <item><see cref="InputActionType.MouseButton"/>: <c>MOUSEEVENTF_{LEFT,RIGHT,MIDDLE}{DOWN,UP}</c>;
    /// Back/Forward are <c>XDOWN/XUP</c> with <c>XBUTTON1/XBUTTON2</c>. X/Y repeat the pointer position
    /// (send an absolute move first if the cursor may have moved).</item>
    /// <item><see cref="InputActionType.Wheel"/> / <see cref="InputActionType.HorizontalWheel"/>:
    /// <c>MOUSEEVENTF_WHEEL</c> / <c>HWHEEL</c> with <c>mouseData = WheelDelta</c>.</item>
    /// <item><see cref="InputActionType.Key"/>: <c>KEYEVENTF_SCANCODE</c> with <c>wScan = ScanCode</c>,
    /// plus <c>KEYEVENTF_EXTENDEDKEY</c> when <see cref="InputAction.IsExtended"/>, plus <c>KEYEVENTF_KEYUP</c> on release.</item>
    /// <item><see cref="InputActionType.Unicode"/>: <c>KEYEVENTF_UNICODE</c> with <c>wScan = Unicode</c>, <c>wVk = 0</c>.</item>
    /// </list>
    /// </remarks>
    void Send(ReadOnlySpan<InputAction> actions);
}

/// <summary>Kinds of <see cref="InputAction"/>.</summary>
public enum InputActionType : byte
{
    MouseMove,
    MouseButton,
    Wheel,
    HorizontalWheel,
    Key,
    Unicode,
}

/// <summary>Mouse buttons as Windows knows them.</summary>
public enum MouseButton : byte
{
    Left,
    Right,
    Middle,
    /// <summary>XBUTTON1.</summary>
    Back,
    /// <summary>XBUTTON2.</summary>
    Forward,
}

/// <summary>One primitive input event, ready for <c>SendInput</c>. Build with the static factories.</summary>
public readonly record struct InputAction
{
    public InputActionType Type { get; init; }
    /// <summary>Virtual-desktop pixel X (mouse actions).</summary>
    public int X { get; init; }
    /// <summary>Virtual-desktop pixel Y (mouse actions).</summary>
    public int Y { get; init; }
    public MouseButton Button { get; init; }
    /// <summary>Press (true) or release (false): buttons, keys, Unicode units.</summary>
    public bool IsDown { get; init; }
    /// <summary>Wheel amount in <c>WHEEL_DELTA</c> units (120 per notch); positive scrolls up / right.</summary>
    public int WheelDelta { get; init; }
    /// <summary>Set-1 scan code without the E0 prefix.</summary>
    public ushort ScanCode { get; init; }
    /// <summary>The scan code has the E0 prefix: send <c>KEYEVENTF_EXTENDEDKEY</c>.</summary>
    public bool IsExtended { get; init; }
    /// <summary>One UTF-16 code unit.</summary>
    public char Unicode { get; init; }

    public static InputAction MoveTo(int x, int y) => new() { Type = InputActionType.MouseMove, X = x, Y = y };
    public static InputAction MouseButtonAt(MouseButton button, bool isDown, int x, int y) =>
        new() { Type = InputActionType.MouseButton, Button = button, IsDown = isDown, X = x, Y = y };
    public static InputAction VerticalWheel(int delta) => new() { Type = InputActionType.Wheel, WheelDelta = delta };
    public static InputAction HorizontalWheelBy(int delta) => new() { Type = InputActionType.HorizontalWheel, WheelDelta = delta };
    public static InputAction KeyScan(ushort scanCode, bool extended, bool isDown) =>
        new() { Type = InputActionType.Key, ScanCode = scanCode, IsExtended = extended, IsDown = isDown };
    public static InputAction UnicodeUnit(char unit, bool isDown) => new() { Type = InputActionType.Unicode, Unicode = unit, IsDown = isDown };

    public override string ToString() => Type switch
    {
        InputActionType.MouseMove => $"move {X},{Y}",
        InputActionType.MouseButton => $"{Button} {(IsDown ? "down" : "up")} {X},{Y}",
        InputActionType.Wheel => $"wheel {WheelDelta}",
        InputActionType.HorizontalWheel => $"hwheel {WheelDelta}",
        InputActionType.Key => $"key {(IsExtended ? "E0 " : "")}{ScanCode:X2} {(IsDown ? "down" : "up")}",
        InputActionType.Unicode => $"unicode U+{(int)Unicode:X4} {(IsDown ? "down" : "up")}",
        _ => Type.ToString(),
    };
}
