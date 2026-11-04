using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Time.Testing;
using Vantage.Protocol.Host;
using Vantage.Protocol.Input;
using Vantage.Protocol.Messages;
using Vantage.SyntheticHost;

namespace Vantage.Protocol.Tests;

/// <summary>Long <c>textInput</c> goes clipboard → Ctrl+V → the old clipboard back, on a fake clock.</summary>
public class ClipboardPasteTests
{
    private const string Dictation = "seventeen units!!"; // 17 UTF-16 units

    private sealed class Rig
    {
        public readonly FakeTimeProvider Time = new();
        public readonly MemoryClipboard Clipboard;
        public readonly RecordingInput Input = new();
        public readonly ClipboardPaster Paster;
        public readonly List<ClipboardPayload> Heard = [];

        public Rig(string? before = "copied earlier", IClipboard? clipboard = null)
        {
            Clipboard = new MemoryClipboard(before, new EventLog(null, false, NullLogger.Instance));
            Clipboard.Watch(payload => { lock (Heard) Heard.Add(payload); });
            Paster = new ClipboardPaster(clipboard ?? Clipboard, Time, ClipboardPaster.DefaultRestoreDelay, NullLogger.Instance);
        }

        public string? Text => Clipboard.Read()?.Text;

        public KeyEvent[] Keys()
        {
            lock (Input.Events) return [.. Input.Events.OfType<KeyEvent>()];
        }
    }

    [Fact]
    public void SixteenUnitsAreTypedSeventeenArePasted()
    {
        Assert.Equal(17, Dictation.Length);
        Assert.False(ClipboardPaster.ShouldPaste(Dictation[..16]));
        Assert.True(ClipboardPaster.ShouldPaste(Dictation));
        Assert.True(ClipboardPaster.ShouldPaste("😀😀😀😀😀😀😀😀a")); // 8 emoji are 16 units; units count, not characters
        Assert.False(ClipboardPaster.ShouldPaste("\n"));
    }

    [Fact]
    public void PasteWritesTheTextPressesCtrlVAndRestoresAfterTheDelay()
    {
        var rig = new Rig();
        Assert.True(rig.Paster.Paste(Dictation, rig.Input));

        Assert.Equal(Dictation, rig.Text);
        Assert.Equal(
            [(ClipboardPaster.VKeyCode, true, KeyModifiers.Control), (ClipboardPaster.VKeyCode, false, KeyModifiers.Control)],
            rig.Keys().Select(k => (k.KeyCode, k.IsDown, k.Modifiers)));
        Assert.Empty(rig.Input.Texts);

        rig.Time.Advance(ClipboardPaster.DefaultRestoreDelay - TimeSpan.FromMilliseconds(1));
        Assert.Equal(Dictation, rig.Text); // still there while the app may be reading it
        rig.Time.Advance(TimeSpan.FromMilliseconds(1));
        Assert.Equal("copied earlier", rig.Text);
        Assert.Empty(rig.Heard); // neither write is a change to send to the client

        rig.Clipboard.Copy(new ClipboardPayload { Text = "the user's next copy" });
        Assert.Equal("the user's next copy", Assert.Single(rig.Heard).Text); // nothing swallowed it
    }

    [Fact]
    public void PastesInARowGiveBackTheClipboardFromBeforeTheFirst()
    {
        var rig = new Rig();
        Assert.True(rig.Paster.Paste(Dictation, rig.Input));
        rig.Time.Advance(TimeSpan.FromSeconds(1));
        Assert.True(rig.Paster.Paste(Dictation + " again", rig.Input));
        rig.Time.Advance(TimeSpan.FromSeconds(1)); // the first paste's restore would have been due
        Assert.Equal(Dictation + " again", rig.Text);
        rig.Time.Advance(TimeSpan.FromSeconds(0.5));
        Assert.Equal("copied earlier", rig.Text);
        Assert.Equal(4, rig.Keys().Length);
    }

    [Fact]
    public void ACopyBeforeTheRestoreWins()
    {
        var rig = new Rig();
        Assert.True(rig.Paster.Paste(Dictation, rig.Input));
        rig.Time.Advance(TimeSpan.FromSeconds(0.5));
        rig.Clipboard.Copy(new ClipboardPayload { Text = "copied meanwhile" });
        rig.Time.Advance(TimeSpan.FromSeconds(5));
        Assert.Equal("copied meanwhile", rig.Text);

        // The next paste saves that copy, not the one from before the first paste.
        Assert.True(rig.Paster.Paste(Dictation, rig.Input));
        rig.Time.Advance(TimeSpan.FromSeconds(2));
        Assert.Equal("copied meanwhile", rig.Text);
    }

    [Fact]
    public void AnEmptyClipboardIsEmptyAgainAfterwards()
    {
        var rig = new Rig(before: null);
        Assert.True(rig.Paster.Paste(Dictation, rig.Input));
        rig.Time.Advance(TimeSpan.FromSeconds(2));
        Assert.Null(rig.Clipboard.Read());
    }

    [Fact]
    public void BusyClipboardSendsNothingSoTheCallerTypes()
    {
        var rig = new Rig(clipboard: new BusyClipboard());
        Assert.False(rig.Paster.Paste(Dictation, rig.Input));
        Assert.False(rig.Paster.Paste(Dictation, rig.Input)); // logged once; still falls back
        Assert.Empty(rig.Keys());
    }

    [Fact]
    public void RestoreNowGivesTheClipboardBackOnce()
    {
        var rig = new Rig();
        Assert.True(rig.Paster.Paste(Dictation, rig.Input));
        rig.Paster.RestoreNow();
        Assert.Equal("copied earlier", rig.Text);
        rig.Clipboard.Copy(new ClipboardPayload { Text = "later" });
        rig.Time.Advance(TimeSpan.FromSeconds(2)); // the cancelled timer doesn't run a second restore
        Assert.Equal("later", rig.Text);
    }

    /// <summary>The chord the translator makes of it: Ctrl, V, V up, Ctrl up, set-1 scan codes.</summary>
    [Fact]
    public void PasteChordIsCtrlVOnThePc()
    {
        var sent = new List<string>();
        using var translator = new WindowsInputTranslator(new Recorder(sent), NullLogger.Instance);
        foreach (var key in ClipboardPaster.PasteChord) translator.Key(key);
        Assert.Equal(["key 1D down", "key 2F down", "key 2F up", "key 1D up"], sent);
    }

    private sealed class Recorder(List<string> sent) : IInputInjector
    {
        public void Send(ReadOnlySpan<InputAction> actions)
        {
            foreach (var action in actions) sent.Add(action.ToString());
        }
    }

    private sealed class BusyClipboard : IClipboard
    {
        public ClipboardPayload? Read() => null;

        public void Apply(ClipboardPayload payload) => throw new IOException("Another app is holding the clipboard.");

        public IDisposable Watch(Action<ClipboardPayload> onChanged) => throw new NotSupportedException();

        public PasteWrite? WriteForPaste(string text, PasteWrite? earlier) => null;

        public bool RestoreAfterPaste(PasteWrite write) => throw new InvalidOperationException("nothing was written");
    }
}
