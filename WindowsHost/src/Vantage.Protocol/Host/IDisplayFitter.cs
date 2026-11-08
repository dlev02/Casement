using Vantage.Protocol.Messages;

namespace Vantage.Protocol.Host;

/// <summary>What <see cref="IDisplayFitter.Fit"/> did.</summary>
public enum DisplayFitResult
{
    /// <summary>The display now runs a different mode; list the displays again before capturing.</summary>
    Changed,
    /// <summary>The display already shows the best mode for the viewport (or nothing fits better): nothing changed.</summary>
    Unchanged,
    /// <summary>Another session holds this display fitted to its own screen; stream what's there.</summary>
    Busy,
    /// <summary>Windows refused the mode (logged); stream the current mode.</summary>
    Failed,
}

/// <summary>
/// The Windows stand-in for the Mac's virtual display (<c>selectDisplay{fitViewport, useVirtualDisplay: true}</c>):
/// Windows has no user-space virtual display, so the shared display is switched to the mode that
/// best matches the device's screen, temporarily, and put back afterwards (as Parsec and Sunshine
/// do). Calls come from any session's queue; implementations lock. One session holds a display at
/// a time, identified by its <c>owner</c>.
/// </summary>
public interface IDisplayFitter
{
    /// <summary>
    /// Whether devices may change the display mode now (the host's "Let devices change this PC's
    /// display mode" setting). Advertised as <c>HostCapabilities.canManageVirtualDisplay</c>.
    /// </summary>
    bool IsEnabled { get; }

    /// <summary>
    /// Switches <paramref name="display"/> to the mode that best fits <paramref name="viewport"/>,
    /// remembering the mode it had so <see cref="Restore"/> can put it back. Choosing the display's
    /// original mode again restores it and lets go of the display.
    /// </summary>
    DisplayFitResult Fit(Guid owner, DisplayInfo display, Viewport viewport);

    /// <summary>Puts back every display <paramref name="owner"/> changed; true when a mode changed.</summary>
    bool Restore(Guid owner);

    /// <summary>Puts back every display any owner changed (listener stop, host quit).</summary>
    void RestoreAll();
}
