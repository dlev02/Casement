using Microsoft.Extensions.Logging;
using Vantage.Protocol.Host;
using Vantage.Protocol.Messages;

namespace Vantage.Protocol.Input;

/// <summary>
/// The pure half of Windows input: turns wire input (<see cref="IInputSink"/>) into
/// <see cref="InputAction"/> batches for an <see cref="IInputInjector"/>. Holds the button,
/// key and modifier state (a port of the Mac's <c>KeyboardSequencer</c>), the kVK → scan code
/// table (spec §7.5), the continuous-scroll remainder, and the point → virtual-desktop pixel map
/// (spec §7.4). Testable on any OS.
/// </summary>
/// <remarks>Not thread-safe: the session calls it from its receive loop only.</remarks>
public sealed class WindowsInputTranslator : IInputSink
{
    /// <summary>Wheel units per discrete line (<c>WHEEL_DELTA</c>).</summary>
    public const int WheelDelta = 120;

    /// <summary>
    /// Trackpad points per wheel notch: <c>deltaY × 120 / 48</c> wheel units per point. Positive
    /// deltaY scrolls content down (reveals what's above) = positive WHEEL. Verify the sign on
    /// hardware; this and <see cref="VerticalSign"/> are the only knobs.
    /// </summary>
    public const double PointsPerNotch = 48;

    /// <summary>+1: the wire's positive deltaY is a positive <c>MOUSEEVENTF_WHEEL</c>.</summary>
    public const int VerticalSign = 1;

    private readonly IInputInjector _injector;
    private readonly ILogger _log;
    private readonly HashSet<ushort> _heldModifiers = [];
    private readonly HashSet<ushort> _heldKeys = [];
    private readonly Dictionary<ushort, List<ushort>> _impliedForKey = [];
    private readonly HashSet<PointerButton> _heldButtons = [];
    private readonly Dictionary<PointerButton, List<ushort>> _impliedForButton = [];
    private readonly List<InputAction> _batch = [];
    private DisplayInfo? _display;
    private int _lastX;
    private int _lastY;
    private double _verticalRemainder;
    private double _horizontalRemainder;

    /// <summary>Creates a translator that sends through <paramref name="injector"/>.</summary>
    public WindowsInputTranslator(IInputInjector injector, ILogger logger)
    {
        _injector = injector;
        _log = logger;
    }

    /// <summary>Modifier keys (kVK) held right now, left and right apart.</summary>
    public IReadOnlyCollection<ushort> HeldModifiers => _heldModifiers;

    /// <inheritdoc />
    public void SetDisplay(DisplayInfo display) => _display = display;

    /// <summary>
    /// A point in the display's point space → virtual-desktop pixels:
    /// <c>px = x / pointWidth × pixelWidth + originX</c>, clamped inside the monitor. A point on the
    /// last point row or column (where the client puts edge positions) lands on the last pixel, so
    /// the taskbar and screen edges respond as they do for a real mouse.
    /// </summary>
    public static (int X, int Y) MapToPixels(DisplayInfo display, float x, float y)
    {
        static int Axis(double value, int points, int pixels, double origin)
        {
            if (points <= 0 || pixels <= 0) return (int)origin;
            int pixel = value >= points - 1 ? pixels - 1 : (int)Math.Floor(value / points * pixels);
            return (int)origin + Math.Clamp(pixel, 0, pixels - 1);
        }
        return (Axis(x, display.PointWidth, display.PixelWidth, display.OriginX),
                Axis(y, display.PointHeight, display.PixelHeight, display.OriginY));
    }

    /// <inheritdoc />
    public void Pointer(PointerEvent pointerEvent)
    {
        if (_display is null) return;
        (_lastX, _lastY) = MapToPixels(_display, pointerEvent.X, pointerEvent.Y);
        _batch.Clear();
        switch (pointerEvent.Action)
        {
            case PointerAction.Move:
                _batch.Add(InputAction.MoveTo(_lastX, _lastY));
                break;
            case PointerAction.Down:
                var implied = PressImplied(pointerEvent.Modifiers);
                if (implied.Count > 0) _impliedForButton[pointerEvent.Button] = implied;
                _batch.Add(InputAction.MoveTo(_lastX, _lastY));
                _batch.Add(InputAction.MouseButtonAt(Map(pointerEvent.Button), true, _lastX, _lastY));
                _heldButtons.Add(pointerEvent.Button);
                break;
            case PointerAction.Up:
                _batch.Add(InputAction.MoveTo(_lastX, _lastY));
                _batch.Add(InputAction.MouseButtonAt(Map(pointerEvent.Button), false, _lastX, _lastY));
                _heldButtons.Remove(pointerEvent.Button);
                if (_impliedForButton.Remove(pointerEvent.Button, out var release)) ReleaseImplied(release);
                break;
        }
        Flush();
    }

    /// <inheritdoc />
    public void Scroll(ScrollEvent scrollEvent)
    {
        if (scrollEvent.Phase == ScrollPhase.Began)
        {
            _verticalRemainder = 0;
            _horizontalRemainder = 0;
        }
        int vertical, horizontal;
        if (scrollEvent.IsContinuous)
        {
            _verticalRemainder += VerticalSign * scrollEvent.DeltaY * WheelDelta / PointsPerNotch;
            _horizontalRemainder += -scrollEvent.DeltaX * WheelDelta / PointsPerNotch;
            vertical = (int)Math.Truncate(_verticalRemainder);
            horizontal = (int)Math.Truncate(_horizontalRemainder);
            _verticalRemainder -= vertical;
            _horizontalRemainder -= horizontal;
        }
        else
        {
            vertical = (int)Math.Round(VerticalSign * scrollEvent.DeltaY * (double)WheelDelta);
            horizontal = (int)Math.Round(-scrollEvent.DeltaX * (double)WheelDelta);
        }
        if (vertical == 0 && horizontal == 0) return;
        _batch.Clear();
        var implied = PressImplied(scrollEvent.Modifiers);
        if (vertical != 0) _batch.Add(InputAction.VerticalWheel(vertical));
        if (horizontal != 0) _batch.Add(InputAction.HorizontalWheelBy(horizontal));
        ReleaseImplied(implied);
        Flush();
    }

    /// <inheritdoc />
    public void Key(KeyEvent keyEvent)
    {
        var code = keyEvent.KeyCode;
        if (ScanCodes.For(code) is not { } scan)
        {
            if (code != ScanCodes.Function) _log.LogInformation("dropping key 0x{KeyCode:X2}: no Windows key", code);
            return;
        }
        _batch.Clear();
        if (ScanCodes.IsModifier(code))
        {
            if (keyEvent.IsDown) _heldModifiers.Add(code); else _heldModifiers.Remove(code);
            _batch.Add(InputAction.KeyScan(scan.Code, scan.Extended, keyEvent.IsDown));
            Flush();
            return;
        }
        if (keyEvent.IsDown && !keyEvent.IsRepeat && !_heldKeys.Contains(code))
        {
            var implied = PressImplied(keyEvent.Modifiers);
            if (implied.Count > 0) _impliedForKey[code] = implied;
        }
        _batch.Add(InputAction.KeyScan(scan.Code, scan.Extended, keyEvent.IsDown));
        if (keyEvent.IsDown)
        {
            _heldKeys.Add(code);
        }
        else
        {
            _heldKeys.Remove(code);
            if (_impliedForKey.Remove(code, out var release)) ReleaseImplied(release);
        }
        Flush();
    }

    /// <inheritdoc />
    public void Text(string text)
    {
        _batch.Clear();
        for (var i = 0; i < text.Length; i++)
        {
            var unit = text[i];
            if (unit == '\r' || unit == '\n')
            {
                if (unit == '\r' && i + 1 < text.Length && text[i + 1] == '\n') i++;
                AddTap(ScanCodes.Return);
            }
            else if (unit == '\t')
            {
                AddTap(ScanCodes.Tab);
            }
            else
            {
                _batch.Add(InputAction.UnicodeUnit(unit, true));
                _batch.Add(InputAction.UnicodeUnit(unit, false));
            }
        }
        Flush();

        void AddTap(ushort macKey)
        {
            var scan = ScanCodes.For(macKey)!.Value;
            _batch.Add(InputAction.KeyScan(scan.Code, scan.Extended, true));
            _batch.Add(InputAction.KeyScan(scan.Code, scan.Extended, false));
        }
    }

    /// <inheritdoc />
    public void ReleaseAll()
    {
        _batch.Clear();
        foreach (var button in _heldButtons.OrderBy(b => b))
            _batch.Add(InputAction.MouseButtonAt(Map(button), false, _lastX, _lastY));
        _heldButtons.Clear();
        _impliedForButton.Clear();
        foreach (var key in _heldKeys.OrderBy(k => k))
        {
            if (ScanCodes.For(key) is { } scan) _batch.Add(InputAction.KeyScan(scan.Code, scan.Extended, false));
        }
        _heldKeys.Clear();
        _impliedForKey.Clear();
        foreach (var modifier in _heldModifiers.OrderBy(k => k))
        {
            var scan = ScanCodes.For(modifier)!.Value;
            _batch.Add(InputAction.KeyScan(scan.Code, scan.Extended, false));
        }
        _heldModifiers.Clear();
        Flush();
    }

    /// <summary>Releases everything still held.</summary>
    public void Dispose() => ReleaseAll();

    /// <summary>
    /// The left-hand keys for a chord's modifiers, in the order a hand presses them (Ctrl, Alt,
    /// Shift, Win). Caps Lock and Fn are never pressed implicitly.
    /// </summary>
    public static List<ushort> ModifierKeys(KeyModifiers modifiers)
    {
        var keys = new List<ushort>(4);
        if (modifiers.HasFlag(KeyModifiers.Control)) keys.Add(ScanCodes.LeftControl);
        if (modifiers.HasFlag(KeyModifiers.Option)) keys.Add(ScanCodes.LeftOption);
        if (modifiers.HasFlag(KeyModifiers.Shift)) keys.Add(ScanCodes.LeftShift);
        if (modifiers.HasFlag(KeyModifiers.Command)) keys.Add(ScanCodes.LeftCommand);
        return keys;
    }

    private List<ushort> PressImplied(KeyModifiers modifiers)
    {
        var implied = ModifierKeys(modifiers).Where(key => !IsSideHeld(key)).ToList();
        foreach (var key in implied)
        {
            _heldModifiers.Add(key);
            var scan = ScanCodes.For(key)!.Value;
            _batch.Add(InputAction.KeyScan(scan.Code, scan.Extended, true));
        }
        return implied;
    }

    private void ReleaseImplied(List<ushort> implied)
    {
        for (var i = implied.Count - 1; i >= 0; i--)
        {
            var key = implied[i];
            if (!_heldModifiers.Remove(key)) continue;
            var scan = ScanCodes.For(key)!.Value;
            _batch.Add(InputAction.KeyScan(scan.Code, scan.Extended, false));
        }
    }

    /// <summary>Either side of this modifier is already down.</summary>
    private bool IsSideHeld(ushort key) => key switch
    {
        ScanCodes.LeftControl => _heldModifiers.Contains(ScanCodes.LeftControl) || _heldModifiers.Contains(ScanCodes.RightControl),
        ScanCodes.LeftOption => _heldModifiers.Contains(ScanCodes.LeftOption) || _heldModifiers.Contains(ScanCodes.RightOption),
        ScanCodes.LeftShift => _heldModifiers.Contains(ScanCodes.LeftShift) || _heldModifiers.Contains(ScanCodes.RightShift),
        ScanCodes.LeftCommand => _heldModifiers.Contains(ScanCodes.LeftCommand) || _heldModifiers.Contains(ScanCodes.RightCommand),
        _ => _heldModifiers.Contains(key),
    };

    private static MouseButton Map(PointerButton button) => button switch
    {
        PointerButton.Right => MouseButton.Right,
        PointerButton.Middle => MouseButton.Middle,
        PointerButton.Back => MouseButton.Back,
        PointerButton.Forward => MouseButton.Forward,
        _ => MouseButton.Left,
    };

    private void Flush()
    {
        if (_batch.Count == 0) return;
        _injector.Send(System.Runtime.InteropServices.CollectionsMarshal.AsSpan(_batch));
        _batch.Clear();
    }
}
