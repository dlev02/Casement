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
    private readonly IInputInjector _injector;
    private readonly ILogger _log;

    /// <summary>Creates a translator that sends through <paramref name="injector"/>.</summary>
    public WindowsInputTranslator(IInputInjector injector, ILogger logger)
    {
        _injector = injector;
        _log = logger;
    }

    /// <inheritdoc />
    public void SetDisplay(DisplayInfo display) => throw new NotImplementedException("W1 step 2");

    /// <inheritdoc />
    public void Pointer(PointerEvent pointerEvent) => throw new NotImplementedException("W1 step 2");

    /// <inheritdoc />
    public void Scroll(ScrollEvent scrollEvent) => throw new NotImplementedException("W1 step 2");

    /// <inheritdoc />
    public void Key(KeyEvent keyEvent) => throw new NotImplementedException("W1 step 2");

    /// <inheritdoc />
    public void Text(string text) => throw new NotImplementedException("W1 step 2");

    /// <inheritdoc />
    public void ReleaseAll() => throw new NotImplementedException("W1 step 2");

    /// <summary>Releases everything still held.</summary>
    public void Dispose() => GC.KeepAlive((_injector, _log));
}
