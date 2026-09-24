using Vantage.Protocol.Messages;

namespace Vantage.Protocol.Host;

/// <summary>
/// Where the session sends the client's input, still in wire terms (spec §6, §7.4): points in the
/// streamed display's space, macOS virtual key codes, <see cref="KeyModifiers"/> bits.
/// </summary>
/// <remarks>
/// <para>
/// On Windows, don't implement this directly: use <see cref="Input.WindowsInputTranslator"/>,
/// which does the pure part (kVK → scan code, chords, held-modifier bookkeeping, scroll
/// accumulation, point → virtual-desktop pixel mapping, text → Unicode/Return/Tab) and hands
/// ready-made <see cref="Input.InputAction"/> batches to an <see cref="Input.IInputInjector"/>,
/// which is the only part that calls <c>SendInput</c>. The synthetic host implements this
/// interface as a JSONL log.
/// </para>
/// <para>
/// Calls arrive from the session's receive loop, one at a time, in order. The core already applies
/// the display-sleep rule (while asleep only releases get here; spec §7.2). One sink lives for a
/// whole screen session, across capture restarts.
/// </para>
/// </remarks>
public interface IInputSink : IDisposable
{
    /// <summary>
    /// The display being streamed, before the first event and whenever it changes. Pointer and
    /// scroll coordinates are in its point space (0…pointWidth × 0…pointHeight, top-left origin).
    /// </summary>
    void SetDisplay(DisplayInfo display);

    /// <summary>
    /// Move, button down or up. A move while a button is held is a drag of that button.
    /// <see cref="PointerEvent.Modifiers"/> adds modifiers to the ones already held: press the
    /// missing modifier keys around the click and release them afterwards.
    /// </summary>
    void Pointer(PointerEvent pointerEvent);

    /// <summary>
    /// A scroll. Positive <see cref="ScrollEvent.DeltaY"/> means content moves down (a positive
    /// Windows wheel delta). Discrete: <c>round(deltaY × 120)</c>. Continuous: <c>deltaY × 120 / 48</c>
    /// per point, fractional remainder carried. Horizontal uses <c>−deltaX</c> with the same scale.
    /// </summary>
    void Scroll(ScrollEvent scrollEvent);

    /// <summary>
    /// A key by macOS virtual key code (spec §7.5). Modifier keys change held state; a non-modifier
    /// key-down whose <see cref="KeyEvent.Modifiers"/> name modifiers not held presses them first
    /// (left-hand keys, order Ctrl, Alt, Shift, Win) and its key-up releases them after, in reverse.
    /// Caps Lock and Fn are never pressed implicitly. Unmapped codes are dropped and logged.
    /// </summary>
    void Key(KeyEvent keyEvent);

    /// <summary>
    /// Types Unicode text (<c>textInput</c>): each UTF-16 unit down and up (surrogates in order),
    /// except <c>\n</c> or <c>\r\n</c> (a Return press) and <c>\t</c> (a Tab press).
    /// </summary>
    void Text(string text);

    /// <summary>Releases every held button, then every held key, then every held modifier (<c>releaseAllInput</c>, disconnect, session end).</summary>
    void ReleaseAll();
}
