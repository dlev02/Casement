using Microsoft.Extensions.Logging;
using Vantage.Protocol.Host;
using Vantage.Protocol.Messages;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.Graphics.Gdi;

namespace Vantage.Host.Windows.Capture;

/// <summary>
/// <see cref="IDisplayFitter"/>: switches a monitor to the mode <see cref="DisplayModes.Choose"/>
/// picks for a device's screen and the scale <see cref="DisplayScales.Choose"/> picks for that mode,
/// and puts both back afterwards. Mode changes use <c>CDS_FULLSCREEN</c> ("the mode is temporary in
/// nature"): nothing is written to the registry, so Windows returns to the user's mode by itself,
/// and restoring is <c>ChangeDisplaySettingsEx(name, null, null, 0, null)</c>. A scale is saved by
/// Windows, so it would outlive a crash: <c>restoreFile</c> holds the value to go back to while a
/// scale is changed, and the next launch applies it. One session holds a monitor at a time.
/// </summary>
public sealed class DisplayFitter : IDisplayFitter, IDisposable
{
    private readonly Func<bool> _enabled;
    private readonly ILogger _log;
    private readonly Lock _lock = new();
    private readonly string _restoreFile;
    private readonly Dictionary<uint, Hold> _holds = [];

    /// <summary>A monitor this fitter changed: who asked, and what to go back to.</summary>
    private sealed record Hold(Guid Owner, string GdiName, DisplayMode Original, DisplayScales.Scale? OriginalScale, DisplayMode Applied);

    /// <param name="enabled">The "Let devices change this PC's display mode" setting, read at each request.</param>
    /// <param name="logging">Loggers (category <c>Vantage.Display</c>).</param>
    /// <param name="restoreFile">Where to note the scale to go back to, across a crash.</param>
    public DisplayFitter(Func<bool> enabled, ILoggerFactory logging, string restoreFile)
    {
        _enabled = enabled;
        _log = logging.CreateLogger("Vantage.Display");
        _restoreFile = restoreFile;
        RecoverScale();
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
            if (Plan(display, viewport, hold) is not { } plan) return false;
            return plan.Choice != plan.Current
                || (DisplayScales.Read(plan.GdiName) is { } scale && scale.Percent != Math.Min(plan.Percent, scale.MaximumPercent));
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
            var before = DisplayScales.Read(plan.GdiName);
            _log.LogInformation("display {Id}: viewport {Width}x{Height} points at {Scale}x; mode {Current} at {Percent}% now, {Choice} at {Wanted}% fits best (user's mode {Original})",
                                display.Id, viewport.WidthPoints, viewport.HeightPoints, viewport.Scale, plan.Current, before?.Percent, plan.Choice, plan.Percent, plan.Original);
            var original = hold?.OriginalScale ?? before;
            if (hold is not null && plan.Choice == hold.Original && original is { } own && plan.Percent == own.Percent)
            {
                // Back to the user's own mode and scale: that's a restore, and the display is free again.
                RestoreLocked(hold);
                _holds.Remove(display.Id);
                ForgetScale();
                return DisplayFitResult.Changed;
            }
            var modeChanges = plan.Choice != plan.Current;
            if (modeChanges && !Apply(plan.GdiName, plan.Choice)) return DisplayFitResult.Failed;
            // Noted first: if the host dies right after the change, the next launch undoes it.
            if (original is { } value) RememberScale(plan.GdiName, value.Relative);
            var scaleChanges = ApplyScale(plan.GdiName, plan.Percent);
            if (!modeChanges && !scaleChanges)
            {
                if (hold is null) ForgetScale();
                return DisplayFitResult.Unchanged;
            }
            _holds[display.Id] = new Hold(owner, plan.GdiName, plan.Original, original, plan.Choice);
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
            if (_holds.Count == 0) ForgetScale();
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
            ForgetScale();
        }
    }

    /// <summary>Puts every changed mode back.</summary>
    public void Dispose() => RestoreAll();

    private readonly record struct ModePlan(string GdiName, DisplayMode Current, DisplayMode Original, DisplayMode Choice, int Percent);

    /// <summary>
    /// What to show: chosen against the user's own mode (not a fitted one), so a rotation back finds
    /// the user's mode again.
    /// </summary>
    private static ModePlan? Plan(DisplayInfo display, Viewport viewport, Hold? hold)
    {
        var gdiName = hold?.GdiName ?? $@"\\.\DISPLAY{display.Id}";
        if (DisplayModes.Enumerate(gdiName) is not { } listed) return null;
        var original = hold?.Original ?? listed.Current;
        var choice = DisplayModes.Choose(listed.Modes, original, viewport.WidthPoints, viewport.HeightPoints, viewport.Scale);
        return new ModePlan(gdiName, listed.Current, original, choice, DisplayScales.Choose(choice.Width, choice.Height, viewport.WidthPoints, viewport.HeightPoints));
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

    /// <summary>Sets the scale for the mode now showing, once Windows has settled on it. True if it changed.</summary>
    private bool ApplyScale(string gdiName, int percent)
    {
        if (DisplayScales.Read(gdiName) is not { } now)
        {
            _log.LogWarning("{Display}: Windows won't report its scale; leaving it", gdiName);
            return false;
        }
        if (now.Percent == Math.Min(percent, now.MaximumPercent)) return false;
        if (DisplayScales.SetPercent(gdiName, now, percent))
        {
            _log.LogInformation("{Display} scale {Before}% -> {After}% for a device's screen", gdiName, now.Percent, Math.Min(percent, now.MaximumPercent));
            return true;
        }
        _log.LogError("{Display} refused {Percent}%; leaving {Current}%", gdiName, percent, now.Percent);
        return false;
    }

    /// <summary>
    /// Scale first, while the temporary mode shows: the value is relative to the mode's recommended
    /// scale, so the user's mode with the fitted value would flash a wrong scale. Checked afterwards
    /// because Windows may rewrite the value when the mode changes.
    /// </summary>
    private unsafe void RestoreLocked(Hold hold)
    {
        if (hold.OriginalScale is { } scale && !DisplayScales.SetRelative(hold.GdiName, scale.Relative))
            _log.LogError("{Display} didn't take its own scale back", hold.GdiName);
        DISP_CHANGE result;
        fixed (char* name = hold.GdiName)
        {
            result = PInvoke.ChangeDisplaySettingsEx(name, null, HWND.Null, 0, null);
        }
        if (result == DISP_CHANGE.DISP_CHANGE_SUCCESSFUL)
            _log.LogInformation("{Display} back to its own mode (was {Applied} for a device)", hold.GdiName, hold.Applied);
        else
            _log.LogError("{Display} didn't go back to its own mode ({Result})", hold.GdiName, result);
        if (hold.OriginalScale is { } own && DisplayScales.Read(hold.GdiName) is { } after)
        {
            if (after.Relative != own.Relative) DisplayScales.SetRelative(hold.GdiName, own.Relative);
            _log.LogInformation("{Display} scale back to {Percent}%", hold.GdiName, DisplayScales.Read(hold.GdiName)?.Percent);
        }
    }

    private void RememberScale(string gdiName, int relative)
    {
        try
        {
            File.WriteAllText(_restoreFile, FormattableString.Invariant($"{relative} {gdiName}"));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            _log.LogWarning("couldn't note the scale to go back to: {Error}", error.Message);
        }
    }

    private void ForgetScale()
    {
        try
        {
            File.Delete(_restoreFile);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            _log.LogWarning("couldn't clear the scale note: {Error}", error.Message);
        }
    }

    /// <summary>The last run ended with a scale changed: Windows has the mode back, this does the scale.</summary>
    private void RecoverScale()
    {
        try
        {
            if (!File.Exists(_restoreFile)) return;
            var parts = File.ReadAllText(_restoreFile).Split(' ', 2);
            if (parts.Length == 2 && int.TryParse(parts[0], System.Globalization.CultureInfo.InvariantCulture, out var relative) && DisplayScales.SetRelative(parts[1], relative))
                _log.LogInformation("{Display} scale put back after the last run ended early", parts[1]);
            File.Delete(_restoreFile);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            _log.LogWarning("couldn't put the scale back: {Error}", error.Message);
        }
    }
}
