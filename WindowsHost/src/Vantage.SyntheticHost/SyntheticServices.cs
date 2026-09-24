using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Extensions.Logging;
using Vantage.Protocol.Host;
using Vantage.Protocol.Input;
using Vantage.Protocol.Messages;

namespace Vantage.SyntheticHost;

/// <summary>
/// One JSON object per line for everything the client sends that a real host would act on:
/// input (with the Windows events the translator would inject) and clipboard contents. Tests read
/// it to check what arrived.
/// </summary>
internal sealed class EventLog : IDisposable
{
    private static readonly JsonSerializerOptions s_json = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };
    private readonly Lock _lock = new();
    private readonly StreamWriter? _writer;
    private readonly ILogger _log;
    private readonly bool _echo;

    public EventLog(string? path, bool echo, ILogger log)
    {
        _log = log;
        _echo = echo;
        if (path is null) return;
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        _writer = new StreamWriter(new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite)) { AutoFlush = true };
    }

    public void Write(JsonObject entry)
    {
        entry["t"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var line = entry.ToJsonString(s_json);
        lock (_lock) _writer?.WriteLine(line);
        if (_echo) _log.LogInformation("input {Line}", line);
    }

    public void Dispose() => _writer?.Dispose();
}

/// <summary>Logs wire input and what <see cref="WindowsInputTranslator"/> would inject for it.</summary>
internal sealed class LoggingInputSink : IInputSink
{
    private readonly EventLog _log;
    private readonly WindowsInputTranslator _translator;
    private readonly List<string> _actions = [];

    public LoggingInputSink(EventLog log, ILogger logger)
    {
        _log = log;
        _translator = new WindowsInputTranslator(new Recorder(_actions), logger);
    }

    public void SetDisplay(DisplayInfo display)
    {
        _translator.SetDisplay(display);
        Write(new JsonObject { ["type"] = "display", ["id"] = display.Id, ["pointWidth"] = display.PointWidth, ["pointHeight"] = display.PointHeight });
    }

    public void Pointer(PointerEvent e)
    {
        _translator.Pointer(e);
        Write(new JsonObject
        {
            ["type"] = "pointer", ["action"] = e.Action.ToString().ToLowerInvariant(), ["button"] = e.Button.ToString().ToLowerInvariant(),
            ["x"] = e.X, ["y"] = e.Y, ["clickCount"] = e.ClickCount, ["modifiers"] = (uint)e.Modifiers,
        });
    }

    public void Scroll(ScrollEvent e)
    {
        _translator.Scroll(e);
        Write(new JsonObject
        {
            ["type"] = "scroll", ["phase"] = e.Phase.ToString().ToLowerInvariant(), ["continuous"] = e.IsContinuous,
            ["deltaX"] = e.DeltaX, ["deltaY"] = e.DeltaY, ["x"] = e.X, ["y"] = e.Y, ["modifiers"] = (uint)e.Modifiers,
        });
    }

    public void Key(KeyEvent e)
    {
        _translator.Key(e);
        Write(new JsonObject
        {
            ["type"] = "key", ["keyCode"] = e.KeyCode, ["down"] = e.IsDown, ["modifiers"] = (uint)e.Modifiers, ["repeat"] = e.IsRepeat,
        });
    }

    public void Text(string text)
    {
        _translator.Text(text);
        Write(new JsonObject { ["type"] = "text", ["text"] = text });
    }

    public void ReleaseAll()
    {
        _translator.ReleaseAll();
        Write(new JsonObject { ["type"] = "releaseAll" });
    }

    public void Dispose() => _translator.Dispose();

    private void Write(JsonObject entry)
    {
        var actions = new JsonArray();
        foreach (var action in _actions) actions.Add(action);
        _actions.Clear();
        entry["windows"] = actions;
        _log.Write(entry);
    }

    private sealed class Recorder(List<string> actions) : IInputInjector
    {
        public void Send(ReadOnlySpan<InputAction> batch)
        {
            foreach (var action in batch) actions.Add(action.ToString());
        }
    }
}

/// <summary>An in-memory clipboard: <c>--clipboard-text</c> seeds it (sent at stream start); what the client sends is logged.</summary>
internal sealed class MemoryClipboard(string? initialText, EventLog log) : IClipboard
{
    private readonly Lock _lock = new();
    private ClipboardPayload? _current = initialText is null ? null : new ClipboardPayload { Text = initialText };

    public ClipboardPayload? Read()
    {
        lock (_lock) return _current;
    }

    public void Apply(ClipboardPayload payload)
    {
        lock (_lock) _current = payload;
        log.Write(new JsonObject
        {
            ["type"] = "clipboard",
            ["text"] = payload.Text,
            ["pngBytes"] = payload.ImagePNG?.Length,
            ["rtfBytes"] = payload.Rtf?.Length,
        });
    }

    /// <summary>Nothing changes it locally.</summary>
    public IDisposable Watch(Action<ClipboardPayload> onChanged) => new Nothing();

    private sealed class Nothing : IDisposable
    {
        public void Dispose()
        {
        }
    }
}

/// <summary>Received files go to the synthetic folder; the hooks only log.</summary>
internal sealed class SyntheticFileStore(string directory, ILogger log) : IFileStore
{
    public string ReceiveDirectory { get; } = directory;

    public bool IsCaseInsensitive => true;

    public long? GetAvailableFreeSpace(string directory)
    {
        try
        {
            return new DriveInfo(directory).AvailableFreeSpace;
        }
        catch (Exception error) when (error is ArgumentException or IOException)
        {
            return null;
        }
    }

    public void OnPartialCreated(string partialPath)
    {
    }

    public void OnBeforeFinalize(string partialPath)
    {
    }

    public void OnSaved(string path, FileOffer offer) => log.LogInformation("saved {Path} ({Bytes} bytes)", path, offer.ByteCount);
}
