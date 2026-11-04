using Microsoft.Extensions.Logging;
using Vantage.Protocol.Host;
using Vantage.Protocol.Messages;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.Graphics.Gdi;

namespace Vantage.Host.Windows.Capture;

/// <summary>
/// <see cref="IDisplayFitter"/> over <c>ChangeDisplaySettingsEx</c>: switches a monitor to the mode
/// <see cref="DisplayModes.Choose"/> picks for a device's screen and puts the user's mode back
/// afterwards. Changes use <c>CDS_FULLSCREEN</c> ("the mode is temporary in nature"): nothing is
/// written to the registry, so the user's mode is what Windows comes back to, and restoring is
/// <c>ChangeDisplaySettingsEx(name, null, null, 0, null)</c> (the registry's mode). One session
/// holds a monitor at a time.
/// </summary>
public sealed class DisplayFitter : IDisplayFitter, IDisposable
{
    private readonly Func<bool> _enabled;
    private readonly ILogger _log;
    private readonly Lock _lock = new();
    private readonly Dictionary<uint, Hold> _holds = [];

    /// <summary>A monitor this fitter changed: who asked, and what to go back to.</summary>
    private sealed record Hold(Guid Owner, string GdiName, DisplayMode Original, double OriginalScale, DisplayMode Applied);

    /// <param name="enabled">The "Let devices change this PC's display mode" setting, read at each request.</param>
    /// <param name="logging">Loggers (category <c>Vantage.Display</c>).</param>
    public DisplayFitter(Func<bool> enabled, ILoggerFactory logging)
    {
        _enabled = enabled;
        _log = logging.CreateLogger("Vantage.Display");
    }

    /// <inheritdoc />
    public bool IsEnabled => _enabled();

    /// <inheritdoc />
    public bool WouldChange(Guid owner, DisplayInfo display, Viewport viewport)
    {
        lock (_lock)
        {
            if (!IsEnabled) return false;
            var hold = _holds.GetValueOrDefault(display.Id);
            if (hold is not null && hold.Owner != owner) return false;
            return Plan(display, viewport, hold) is { } plan && plan.Choice != plan.Current;
        }
    }

    /// <inheritdoc />
    public DisplayFitResult Fit(Guid owner, DisplayInfo display, Viewport viewport)
    {
        lock (_lock)
        {
            if (!IsEnabled) return DisplayFitResult.Unchanged;
            var hold = _holds.GetValueOrDefault(display.Id);
            if (hold is not null && hold.Owner != owner) return DisplayFitResult.Busy;
            if (Plan(display, viewport, hold) is not { } plan)
            {
                _log.LogWarning("display {Id}: Windows lists no modes; leaving it as it is", display.Id);
                return DisplayFitResult.Failed;
            }
            _log.LogInformation("display {Id}: viewport {Width}x{Height} points at {Scale}x; mode {Current} now, {Choice} fits best (user's mode {Original})",
                                display.Id, viewport.WidthPoints, viewport.HeightPoints, viewport.Scale, plan.Current, plan.Choice, plan.Original);
            if (plan.Choice == plan.Current) return DisplayFitResult.Unchanged;
            if (hold is not null && plan.Choice == hold.Original)
            {
                // Back to the user's own mode: that's a restore, and the display is free again.
                RestoreLocked(hold);
                _holds.Remove(display.Id);
                return DisplayFitResult.Changed;
            }
            if (!Apply(plan.GdiName, plan.Choice)) return DisplayFitResult.Failed;
            _holds[display.Id] = new Hold(owner, plan.GdiName, plan.Original, hold?.OriginalScale ?? display.Scale, plan.Choice);
            return DisplayFitResult.Changed;
        }
    }

    /// <inheritdoc />
    public bool Restore(Guid owner)
    {
        lock (_lock)
        {
            var mine = _holds.Where(h => h.Value.Owner == owner).ToList();
            foreach (var (id, hold) in mine)
            {
                RestoreLocked(hold);
                _holds.Remove(id);
            }
            return mine.Count > 0;
        }
    }

    /// <inheritdoc />
    public void RestoreAll()
    {
        lock (_lock)
        {
            foreach (var hold in _holds.Values) RestoreLocked(hold);
            _holds.Clear();
        }
    }

    /// <summary>Puts every changed mode back.</summary>
    public void Dispose() => RestoreAll();

    private readonly record struct ModePlan(string GdiName, DisplayMode Current, DisplayMode Original, DisplayMode Choice);

    /// <summary>
    /// What to show: chosen against the user's own mode and scale (not a fitted mode's), so a
    /// rotation back finds the user's mode again.
    /// </summary>
    private static ModePlan? Plan(DisplayInfo display, Viewport viewport, Hold? hold)
    {
        var gdiName = hold?.GdiName ?? $@"\\.\DISPLAY{display.Id}";
        if (DisplayModes.Enumerate(gdiName) is not { } listed) return null;
        var original = hold?.Original ?? listed.Current;
        var scale = hold?.OriginalScale ?? display.Scale;
        var choice = DisplayModes.Choose(listed.Modes, original, viewport.WidthPoints, viewport.HeightPoints, viewport.Scale, scale);
        return new ModePlan(gdiName, listed.Current, original, choice);
    }

    private unsafe bool Apply(string gdiName, DisplayMode mode)
    {
        var devmode = new DEVMODEW
        {
            dmSize = (ushort)sizeof(DEVMODEW),
            dmPelsWidth = (uint)mode.Width,
            dmPelsHeight = (uint)mode.Height,
            dmBitsPerPel = 32,
            dmDisplayFrequency = (uint)mode.RefreshRate,
            dmFields = DEVMODE_FIELD_FLAGS.DM_PELSWIDTH | DEVMODE_FIELD_FLAGS.DM_PELSHEIGHT | DEVMODE_FIELD_FLAGS.DM_BITSPERPEL
                       | DEVMODE_FIELD_FLAGS.DM_DISPLAYFREQUENCY,
        };
        DISP_CHANGE result;
        fixed (char* name = gdiName)
        {
            result = PInvoke.ChangeDisplaySettingsEx(name, &devmode, HWND.Null, CDS_TYPE.CDS_FULLSCREEN, null);
        }
        if (result == DISP_CHANGE.DISP_CHANGE_SUCCESSFUL)
        {
            _log.LogInformation("{Display} switched to {Mode} for a device's screen", gdiName, mode);
            return true;
        }
        _log.LogError("{Display} refused {Mode} ({Result}); streaming the current mode", gdiName, mode, result);
        return false;
    }

    private unsafe void RestoreLocked(Hold hold)
    {
        DISP_CHANGE result;
        fixed (char* name = hold.GdiName)
        {
            result = PInvoke.ChangeDisplaySettingsEx(name, null, HWND.Null, 0, null);
        }
        if (result == DISP_CHANGE.DISP_CHANGE_SUCCESSFUL)
            _log.LogInformation("{Display} back to its own mode (was {Applied} for a device)", hold.GdiName, hold.Applied);
        else
            _log.LogError("{Display} didn't go back to its own mode ({Result})", hold.GdiName, result);
    }
}
