using Microsoft.Extensions.Logging;
using Vantage.Protocol.Messages;

namespace Vantage.Protocol.Host;

/// <summary>
/// Delivers long <c>textInput</c> (a dictation, a paste from the iPad) the way the Mac host does: puts
/// it on the clipboard, presses Ctrl+V, and puts back what was there <see cref="RestoreDelay"/> later.
/// Typing it as a burst of <c>KEYEVENTF_UNICODE</c> events drops characters in Chromium and Electron
/// apps (Slack, VS Code, Discord) and some games; a paste arrives whole.
/// </summary>
/// <remarks>
/// <para>
/// One per listener, since the clipboard is the PC's, not a session's. Neither write reaches the client
/// as a clipboard change (<see cref="IClipboard.WriteForPaste"/> and
/// <see cref="IClipboard.RestoreAfterPaste"/> are own-writes the watcher already knows), pastes in a
/// row keep the clipboard from before the first, and a copy made before the restore wins: the restore
/// only runs while the clipboard still holds the paste. There is no "ignore the next change" flag to
/// outlive its write and swallow the user's next copy.
/// </para>
/// <para>
/// The restore waits on a <see cref="TimeProvider"/> timer, so the session's queue never blocks on it
/// and tests can drive it with a fake clock.
/// </para>
/// </remarks>
public sealed class ClipboardPaster
{
    /// <summary>Text longer than this many UTF-16 units is pasted; shorter text is typed (the Mac's rule).</summary>
    public const int TypedTextLimit = 16;

    /// <summary>
    /// How long the pasted text stays on the clipboard, the Mac's <c>pasteRestoreDelay</c>. The Ctrl+V is
    /// only queued when <c>SendInput</c> returns; the app reads the clipboard when it gets round to the
    /// key, and a busy Electron app can take hundreds of milliseconds. One that hasn't read it by the
    /// restore pastes the old clipboard, which is worse than the text sitting there a moment longer.
    /// </summary>
    public static readonly TimeSpan DefaultRestoreDelay = TimeSpan.FromSeconds(1.5);

    /// <summary>macOS <c>kVK_ANSI_V</c>; the translator sends it as the V key's scan code.</summary>
    public const ushort VKeyCode = 0x09;

    private readonly IClipboard _clipboard;
    private readonly TimeProvider _time;
    private readonly ILogger _log;
    private readonly Lock _lock = new();
    private PasteWrite? _held;
    private ITimer? _restore;
    private bool _reportedBusy;

    /// <param name="clipboard">The PC's clipboard.</param>
    /// <param name="time">Clock for the restore.</param>
    /// <param name="restoreDelay">How long a paste stays on the clipboard (<see cref="DefaultRestoreDelay"/>).</param>
    /// <param name="log">Logger (category <c>Vantage.Input</c>).</param>
    public ClipboardPaster(IClipboard clipboard, TimeProvider time, TimeSpan restoreDelay, ILogger log)
    {
        _clipboard = clipboard;
        _time = time;
        _log = log;
        RestoreDelay = restoreDelay;
    }

    /// <summary>How long a paste stays on the clipboard before what was there comes back.</summary>
    public TimeSpan RestoreDelay { get; }

    /// <summary>Whether <paramref name="text"/> is long enough to paste rather than type.</summary>
    public static bool ShouldPaste(string text) => text.Length > TypedTextLimit;

    /// <summary>
    /// The paste chord in wire terms: V down and up, each naming Control, so the translator presses
    /// Ctrl around it the way it does for a control-strip chord (Ctrl down, V down, V up, Ctrl up, set-1
    /// scan codes). Ctrl, not ⌘: on a PC ⌘ is the Windows key.
    /// </summary>
    public static IReadOnlyList<KeyEvent> PasteChord { get; } =
    [
        new KeyEvent { KeyCode = VKeyCode, IsDown = true, Modifiers = KeyModifiers.Control },
        new KeyEvent { KeyCode = VKeyCode, IsDown = false, Modifiers = KeyModifiers.Control },
    ];

    /// <summary>
    /// Puts <paramref name="text"/> on the clipboard, sends <see cref="PasteChord"/> to
    /// <paramref name="input"/>, and schedules the restore. Returns false, having sent nothing, when the
    /// clipboard couldn't be opened (another app holds it); the caller then types the text instead, so
    /// it's never dropped. That is logged once until a paste works again.
    /// </summary>
    public bool Paste(string text, IInputSink input)
    {
        lock (_lock)
        {
            var write = _clipboard.WriteForPaste(text, _held);
            if (write is null)
            {
                if (!_reportedBusy) _log.LogWarning("another app is holding the clipboard; typing {Units} characters instead of pasting them", text.Length);
                _reportedBusy = true;
                return false; // an earlier paste's restore stays scheduled
            }
            _reportedBusy = false;
            _restore?.Dispose();
            _held = write;
            foreach (var key in PasteChord) input.Key(key);
            _restore = _time.CreateTimer(_ => Restore(write), null, RestoreDelay, Timeout.InfiniteTimeSpan);
            _log.LogInformation("pasted {Units} characters through the clipboard", text.Length);
            return true;
        }
    }

    /// <summary>Restores a pending paste now (the host is stopping).</summary>
    public void RestoreNow()
    {
        PasteWrite? held;
        lock (_lock) held = _held;
        if (held is not null) Restore(held);
    }

    private void Restore(PasteWrite write)
    {
        lock (_lock)
        {
            // A later paste took over (and kept this one's former clipboard), or it already ran.
            if (!ReferenceEquals(_held, write)) return;
            _held = null;
            _restore?.Dispose();
            _restore = null;
            try
            {
                if (!_clipboard.RestoreAfterPaste(write)) _log.LogInformation("left the clipboard as it is after a paste: it changed or couldn't be opened");
            }
            catch (Exception error) when (error is IOException or OutOfMemoryException or InvalidOperationException)
            {
                // On a timer thread: an exception here would end the process.
                _log.LogError("putting the clipboard back after a paste failed: {Error}", error.Message);
            }
        }
    }
}
