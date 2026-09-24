using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Extensions.Logging;
using Vantage.Host.Windows.Desktop;
using Vantage.Protocol.Host;
using Vantage.Protocol.Messages;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.System.Memory;
using static Vantage.Host.Windows.Interop.Win32Constants;
using BitmapAlphaMode = global::Windows.Graphics.Imaging.BitmapAlphaMode;
using BitmapDecoder = global::Windows.Graphics.Imaging.BitmapDecoder;
using BitmapPixelFormat = global::Windows.Graphics.Imaging.BitmapPixelFormat;
using BitmapTransform = global::Windows.Graphics.Imaging.BitmapTransform;
using ColorManagementMode = global::Windows.Graphics.Imaging.ColorManagementMode;
using ExifOrientationMode = global::Windows.Graphics.Imaging.ExifOrientationMode;

namespace Vantage.Host.Windows.Clipboard;

/// <summary>
/// <see cref="IClipboard"/> on the Win32 clipboard (spec §9.3), owned by the host's
/// <see cref="MessageWindow"/>: <c>AddClipboardFormatListener</c> for changes, the clipboard owner and
/// <c>GetClipboardSequenceNumber</c> for echo suppression, <c>CF_UNICODETEXT</c> with CRLF,
/// <c>"Rich Text Format"</c>, and images as <c>"PNG"</c> (preferred) or <c>CF_DIBV5</c>/<c>CF_DIB</c>
/// converted to PNG. Writes put both <c>"PNG"</c> and <c>CF_DIBV5</c>.
/// </summary>
public sealed class Win32Clipboard : IClipboard
{
    /// <summary>Images larger than this (as PNG) are left out (spec §9.3).</summary>
    public const int MaxImageBytes = 24 * 1024 * 1024;

    private static readonly TimeSpan s_debounce = TimeSpan.FromMilliseconds(150);

    private readonly MessageWindow _window;
    private readonly ILogger _log;
    private readonly uint _rtfFormat;
    private readonly uint _pngFormat;
    private readonly Lock _lock = new();
    private readonly List<Action<ClipboardPayload>> _watchers = [];
    private IDisposable? _hook;
    private Timer? _debounceTimer;
    private uint _appliedSequence;
    private byte[]? _lastSentHash;

    /// <param name="window">The host's message window (owns the clipboard listener).</param>
    /// <param name="logging">Loggers (category <c>Vantage.Clipboard</c>).</param>
    public Win32Clipboard(MessageWindow window, ILoggerFactory logging)
    {
        _window = window;
        _log = logging.CreateLogger("Vantage.Clipboard");
        _rtfFormat = PInvoke.RegisterClipboardFormat("Rich Text Format");
        _pngFormat = PInvoke.RegisterClipboardFormat("PNG");
    }

    /// <inheritdoc />
    public ClipboardPayload? Read()
    {
        var raw = _window.Invoke(ReadRaw);
        return raw is null ? null : ToPayload(raw);
    }

    /// <inheritdoc />
    public void Apply(ClipboardPayload payload)
    {
        byte[]? dib = null;
        if (payload.ImagePNG is { Length: > 0 and <= MaxImageBytes } png)
        {
            try
            {
                dib = DibCodec.EncodeV5(DecodePng(png));
            }
            catch (Exception ex)
            {
                _log.LogWarning("couldn't decode the iPad's image: {Message}", ex.Message);
            }
        }

        _window.Invoke(() =>
        {
            if (!OpenWithRetry()) throw new IOException("Another app is holding the clipboard.");
            try
            {
                PInvoke.EmptyClipboard();
                if (payload.Text is { } text) SetUnicodeText(ClipboardText.ToWindows(text));
                if (payload.Rtf is { Length: > 0 } rtf) SetBytes(_rtfFormat, rtf, addNul: true);
                if (payload.ImagePNG is { Length: > 0 and <= MaxImageBytes } image)
                {
                    SetBytes(_pngFormat, image, addNul: false);
                    if (dib is not null) SetBytes(CF_DIBV5, dib, addNul: false);
                }
            }
            finally
            {
                PInvoke.CloseClipboard();
            }
            _appliedSequence = PInvoke.GetClipboardSequenceNumber();
        });
        lock (_lock) _lastSentHash = Hash(payload);
        _log.LogInformation("clipboard set from the iPad (text {Text}, rtf {Rtf}, image {Image})",
                            payload.Text is not null, payload.Rtf is not null, payload.ImagePNG is not null);
    }

    /// <inheritdoc />
    public IDisposable Watch(Action<ClipboardPayload> onChanged)
    {
        lock (_lock)
        {
            _watchers.Add(onChanged);
            if (_watchers.Count == 1)
            {
                _debounceTimer = new Timer(_ => Publish(), null, Timeout.Infinite, Timeout.Infinite);
                _window.Invoke(() =>
                {
                    _hook = _window.AddHook(OnMessage);
                    if (!PInvoke.AddClipboardFormatListener(_window.Hwnd))
                        _log.LogWarning("AddClipboardFormatListener failed ({Error})", Marshal.GetLastPInvokeError());
                });
            }
        }
        return new Unwatch(this, onChanged);
    }

    private void StopWatching(Action<ClipboardPayload> onChanged)
    {
        lock (_lock)
        {
            if (!_watchers.Remove(onChanged) || _watchers.Count > 0) return;
            _debounceTimer?.Dispose();
            _debounceTimer = null;
            _window.Invoke(() =>
            {
                PInvoke.RemoveClipboardFormatListener(_window.Hwnd);
                _hook?.Dispose();
                _hook = null;
            });
        }
    }

    private bool OnMessage(uint message, nuint wParam, nint lParam, out nint result)
    {
        result = 0;
        if (message != WM_CLIPBOARDUPDATE) return false;
        // Our own write: the owner is this window, or the sequence number is the one Apply left.
        if (PInvoke.GetClipboardOwner() == _window.Hwnd || PInvoke.GetClipboardSequenceNumber() == _appliedSequence) return true;
        lock (_lock) _debounceTimer?.Change(s_debounce, Timeout.InfiniteTimeSpan);
        return true;
    }

    private void Publish()
    {
        Action<ClipboardPayload>[] watchers;
        lock (_lock) watchers = [.. _watchers];
        if (watchers.Length == 0) return;
        ClipboardPayload? payload;
        try
        {
            payload = Read();
        }
        catch (Exception ex)
        {
            _log.LogDebug("reading the clipboard failed: {Message}", ex.Message);
            return;
        }
        if (payload is null) return;
        var hash = Hash(payload);
        lock (_lock)
        {
            if (_lastSentHash is not null && hash.AsSpan().SequenceEqual(_lastSentHash)) return;
            _lastSentHash = hash;
        }
        foreach (var watcher in watchers) watcher(payload);
    }

    private sealed record RawClipboard(string? Text, byte[]? Rtf, byte[]? Png, byte[]? Dib);

    private RawClipboard? ReadRaw()
    {
        if (!OpenWithRetry()) return null;
        try
        {
            string? text = null;
            if (PInvoke.IsClipboardFormatAvailable(CF_UNICODETEXT))
            {
                var bytes = GetBytes(CF_UNICODETEXT);
                if (bytes is not null) text = ClipboardText.ToWire(global::System.Text.Encoding.Unicode.GetString(bytes));
            }
            byte[]? rtf = null;
            if (_rtfFormat != 0 && PInvoke.IsClipboardFormatAvailable(_rtfFormat))
            {
                var bytes = GetBytes(_rtfFormat);
                if (bytes is not null) rtf = ClipboardText.TrimRtf(bytes);
            }
            byte[]? png = null, dib = null;
            if (_pngFormat != 0 && PInvoke.IsClipboardFormatAvailable(_pngFormat)) png = GetBytes(_pngFormat);
            if (png is null)
            {
                if (PInvoke.IsClipboardFormatAvailable(CF_DIBV5)) dib = GetBytes(CF_DIBV5);
                else if (PInvoke.IsClipboardFormatAvailable(CF_DIB)) dib = GetBytes(CF_DIB);
            }
            if (text is null && rtf is null && png is null && dib is null) return null;
            return new RawClipboard(text, rtf is { Length: > 0 } ? rtf : null, png, dib);
        }
        finally
        {
            PInvoke.CloseClipboard();
        }
    }

    private ClipboardPayload? ToPayload(RawClipboard raw)
    {
        var png = raw.Png;
        if (png is null && raw.Dib is not null && DibCodec.TryDecode(raw.Dib, out var image)) png = PngWriter.Encode(image!);
        if (png is { Length: > MaxImageBytes })
        {
            _log.LogInformation("clipboard image is {Bytes} bytes as PNG; leaving it out", png.Length);
            png = null;
        }
        var payload = new ClipboardPayload { Text = raw.Text, Rtf = raw.Text is not null ? raw.Rtf : null, ImagePNG = png };
        return payload.IsEmpty ? null : payload;
    }

    private bool OpenWithRetry()
    {
        for (var attempt = 0; attempt < 10; attempt++)
        {
            if (PInvoke.OpenClipboard(_window.Hwnd)) return true;
            Thread.Sleep(10);
        }
        _log.LogDebug("OpenClipboard failed ({Error})", Marshal.GetLastPInvokeError());
        return false;
    }

    private static unsafe byte[]? GetBytes(uint format)
    {
        var handle = PInvoke.GetClipboardData(format);
        if (handle.IsNull) return null;
        var global = (HGLOBAL)handle.Value;
        var size = (int)Math.Min(PInvoke.GlobalSize(global), int.MaxValue);
        var pointer = PInvoke.GlobalLock(global);
        if (pointer is null) return null;
        try
        {
            return new ReadOnlySpan<byte>(pointer, size).ToArray();
        }
        finally
        {
            PInvoke.GlobalUnlock(global);
        }
    }

    private static void SetUnicodeText(string text)
    {
        var bytes = new byte[(text.Length + 1) * 2];
        global::System.Text.Encoding.Unicode.GetBytes(text, bytes);
        SetBytes(CF_UNICODETEXT, bytes, addNul: false);
    }

    private static unsafe void SetBytes(uint format, ReadOnlySpan<byte> data, bool addNul)
    {
        var size = (nuint)(data.Length + (addNul ? 1 : 0));
        var global = PInvoke.GlobalAlloc(GLOBAL_ALLOC_FLAGS.GMEM_MOVEABLE, size);
        if (global.IsNull) throw new OutOfMemoryException("GlobalAlloc failed for the clipboard.");
        var pointer = PInvoke.GlobalLock(global);
        try
        {
            var target = new Span<byte>(pointer, (int)size);
            data.CopyTo(target);
            if (addNul) target[^1] = 0;
        }
        finally
        {
            PInvoke.GlobalUnlock(global);
        }
        if (PInvoke.SetClipboardData(format, (HANDLE)global.Value).IsNull)
        {
            PInvoke.GlobalFree(global); // ownership passes to the system only on success
        }
    }

    private static BgraImage DecodePng(byte[] png)
    {
        using var stream = new MemoryStream(png, writable: false);
        var randomAccess = stream.AsRandomAccessStream();
        var decoder = BitmapDecoder.CreateAsync(randomAccess).AsTask().GetAwaiter().GetResult();
        var pixels = decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Straight, new BitmapTransform(),
                                               ExifOrientationMode.IgnoreExifOrientation, ColorManagementMode.DoNotColorManage)
                            .AsTask().GetAwaiter().GetResult();
        return new BgraImage((int)decoder.PixelWidth, (int)decoder.PixelHeight, pixels.DetachPixelData());
    }

    private static byte[] Hash(ClipboardPayload payload)
    {
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        hash.AppendData(global::System.Text.Encoding.UTF8.GetBytes(payload.Text ?? "\u0001"));
        hash.AppendData(payload.Rtf ?? [1]);
        hash.AppendData(payload.ImagePNG ?? [2]);
        return hash.GetHashAndReset();
    }

    private sealed class Unwatch(Win32Clipboard owner, Action<ClipboardPayload> watcher) : IDisposable
    {
        private int _done;

        public void Dispose()
        {
            if (Interlocked.Exchange(ref _done, 1) == 0) owner.StopWatching(watcher);
        }
    }
}

/// <summary>An in-memory <see cref="IClipboard"/> (synthetic runs): Apply stores, Read returns it, never watches.</summary>
public sealed class InMemoryClipboard : IClipboard
{
    private ClipboardPayload? _current;

    /// <inheritdoc />
    public ClipboardPayload? Read() => Volatile.Read(ref _current);

    /// <inheritdoc />
    public void Apply(ClipboardPayload payload) => Volatile.Write(ref _current, payload);

    /// <inheritdoc />
    public IDisposable Watch(Action<ClipboardPayload> onChanged) => new NoWatch();

    private sealed class NoWatch : IDisposable
    {
        public void Dispose()
        {
        }
    }
}
