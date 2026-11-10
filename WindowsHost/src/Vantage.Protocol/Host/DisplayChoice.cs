using Microsoft.Extensions.Logging;
using Vantage.Protocol.Messages;

namespace Vantage.Protocol.Host;

/// <summary>
/// Which display a screen session streams, and what it changed to get there that must be put back:
/// the Windows stand-in for the Mac's virtual display. Given the device's <c>selectDisplay</c> it
/// fits the main display's mode to the viewport through <see cref="IDisplayFitter"/> (when asked
/// with <c>useVirtualDisplay</c> and the host allows it), waits for the new mode to show, and
/// picks the display; it restores the mode on <c>restoreDisplays</c>, on a later <c>selectDisplay</c>
/// that doesn't fit, and when the session ends. A refused mode, or a display another session
/// holds, streams what's there.
/// </summary>
/// <remarks>
/// Capture must be stopped around <see cref="ChooseAsync"/> and <see cref="RestoreNow"/>: a running
/// capture stops itself on the size change, and its late stop could land on the capture that
/// replaces it. Refits come from the <c>selectDisplay</c> Casement resends when its viewport changes;
/// <c>viewportChanged</c> only forces a keyframe, as on the Mac.
/// </remarks>
internal sealed class DisplayChoice(Guid owner, IDisplayFitter? fitter, IScreenSource screen, TimeProvider time, ILogger log)
{
    /// <summary>How long to wait for the monitor to report a changed mode's size before describing the old one.</summary>
    public static readonly TimeSpan ModeSettleLimit = TimeSpan.FromSeconds(1);

    /// <summary>Right after a mode change, a capture sized for the old mode is started again for up to this long.</summary>
    public static readonly TimeSpan CaptureCatchUp = TimeSpan.FromSeconds(2);

    // The device asked for the display fitted to its screen (fitViewport + useVirtualDisplay) and
    // hasn't sent restoreDisplays since: capture (re)starts fit the mode.
    private bool _fitting;
    private DateTimeOffset? _modeChangedAt; // the next capture start checks it got the new mode's size

    /// <summary>Whether the device currently wants the display fitted to its screen.</summary>
    public bool IsFitting => _fitting;

    /// <summary>The device sent this <c>selectDisplay</c>: remember whether it wants the display fitted.</summary>
    public void Wanted(SelectDisplay select) =>
        _fitting = select is { Selection: DisplaySelection.FitViewport, UseVirtualDisplay: true } && fitter is { IsEnabled: true };

    /// <summary>
    /// With capture stopped: lists the displays, fits or restores the main display's mode as wanted,
    /// and returns the display to stream (<c>display(id)</c>: that one; <c>fitViewport</c>: the main
    /// one, else the first). Throws <see cref="CaptureUnavailableException"/> when there is none.
    /// </summary>
    public async Task<DisplayInfo> ChooseAsync(SelectDisplay select)
    {
        var displays = await screen.GetDisplaysAsync(CancellationToken.None).ConfigureAwait(false);
        displays = await FitAsync(select, displays).ConfigureAwait(false);
        return select.Selection switch
        {
            DisplaySelection.Display byId => displays.FirstOrDefault(d => d.Id == byId.Id)
                                             ?? throw new CaptureUnavailableException($"display {byId.Id} isn't connected"),
            _ => displays.FirstOrDefault(d => d.IsMain) ?? displays.FirstOrDefault()
                 ?? throw new CaptureUnavailableException("no displays to capture"),
        };
    }

    /// <summary>
    /// Just after a mode change, Windows.Graphics.Capture can still size a new capture for the old
    /// mode, which then stops at its first frame: true while the session should start it again
    /// (sizes differ and the change is under <see cref="CaptureCatchUp"/> old).
    /// </summary>
    public bool CaptureSizedForOldMode(int frameWidth, int frameHeight, DisplayInfo chosen)
    {
        if (_modeChangedAt is not { } changedAt) return false;
        if ((frameWidth == chosen.PixelWidth && frameHeight == chosen.PixelHeight) || time.GetUtcNow() - changedAt >= CaptureCatchUp)
        {
            _modeChangedAt = null;
            return false;
        }
        log.LogInformation("capture still sized {Width}x{Height} for the old mode; starting it again", frameWidth, frameHeight);
        return true;
    }

    /// <summary><c>restoreDisplays</c>: the device no longer wants the display fitted. True when it was, so the stream must restart on the restored mode.</summary>
    public bool StopFitting()
    {
        var wasFitting = _fitting;
        _fitting = false;
        return wasFitting && fitter is not null;
    }

    /// <summary>Puts back a mode this session changed, now (capture stopped first when a stream is up).</summary>
    public void RestoreNow()
    {
        if (fitter?.Restore(owner) != true) return;
        log.LogInformation("display mode restored");
        _modeChangedAt = time.GetUtcNow();
    }

    /// <summary>The session is over: whatever it changed goes back; a failure is logged, never thrown.</summary>
    public void RestoreAtEnd()
    {
        try
        {
            if (fitter?.Restore(owner) == true) log.LogInformation("display mode restored at session end");
        }
        catch (Exception error)
        {
            log.LogError("restoring the display mode failed: {Error}", error.Message);
        }
    }

    /// <summary>
    /// Fits the main display's mode to the viewport while the device wants a fitted display, or puts
    /// back a mode this session changed once it doesn't. Returns the displays as they are afterwards.
    /// </summary>
    private async Task<IReadOnlyList<DisplayInfo>> FitAsync(SelectDisplay select, IReadOnlyList<DisplayInfo> displays)
    {
        if (fitter is null) return displays;
        var main = displays.FirstOrDefault(d => d.IsMain) ?? displays.FirstOrDefault();
        bool changed;
        try
        {
            if (_fitting && select.Selection is DisplaySelection.FitViewport fit && main is not null)
            {
                var result = fitter.Fit(owner, main, fit.Viewport);
                if (result is DisplayFitResult.Busy) log.LogInformation("another device has display {Id} fitted to its screen; streaming it as it is", main.Id);
                changed = result is DisplayFitResult.Changed;
            }
            else
            {
                // A display chosen by id while fitting, or fitting over: only the latter puts the mode back.
                changed = !_fitting && fitter.Restore(owner);
            }
        }
        catch (Exception error)
        {
            log.LogError("fitting the display mode failed: {Error}", error.Message);
            return displays;
        }
        if (!changed) return displays;
        _modeChangedAt = time.GetUtcNow();

        // The monitor's rect follows the mode at once, but give it a moment (≤ 1 s) to report the
        // new size so streamConfig describes the mode being shown.
        var started = time.GetTimestamp();
        while (true)
        {
            var now = await screen.GetDisplaysAsync(CancellationToken.None).ConfigureAwait(false);
            var after = main is null ? null : now.FirstOrDefault(d => d.Id == main.Id);
            if (main is null || after is null || after.PixelWidth != main.PixelWidth || after.PixelHeight != main.PixelHeight
                || after.Scale != main.Scale
                || time.GetElapsedTime(started) >= ModeSettleLimit)
            {
                if (after is not null)
                    log.LogInformation("display {Id} now {Width}x{Height} at {Scale}x ({PointWidth}x{PointHeight} points)",
                                       after.Id, after.PixelWidth, after.PixelHeight, after.Scale, after.PointWidth, after.PointHeight);
                return now;
            }
            await Task.Delay(TimeSpan.FromMilliseconds(100), time, CancellationToken.None).ConfigureAwait(false);
        }
    }
}
