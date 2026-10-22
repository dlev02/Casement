using Microsoft.Extensions.Logging;
using Vantage.Host.Windows.Clipboard;
using Vantage.Protocol.Host;
using Vantage.Protocol.Messages;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.Graphics.Gdi;
using Windows.Win32.UI.WindowsAndMessaging;

namespace Vantage.Host.Windows.Cursor;

/// <summary>
/// <see cref="ICursorSource"/> for Windows: polls <c>GetCursorInfo</c> at 120 Hz on a thread of
/// its own (no hook, so nothing slows the PC's own input) and, when the cursor handle changes,
/// draws it with <c>DrawIconEx</c> on black and on white to recover its pixels
/// (<see cref="CursorImage"/>). The same handle is never drawn twice: shapes are cached by handle.
/// This is what lets the client move its pointer locally, the way Remote Desktop does.
/// </summary>
public sealed class WindowsCursorSource(ILoggerFactory logging) : ICursorSource
{
    private readonly ILogger _log = logging.CreateLogger("Vantage.Cursor");

    /// <inheritdoc />
    public IDisposable Watch(DisplayInfo display, Action<CursorState> onChange) => new Watcher(display, onChange, _log);

    private sealed class Watcher : IDisposable
    {
        private static readonly TimeSpan s_interval = TimeSpan.FromMilliseconds(8);
        private readonly DisplayInfo _display;
        private readonly Action<CursorState> _onChange;
        private readonly ILogger _log;
        private readonly Dictionary<nint, CursorShape?> _shapes = [];
        private readonly Thread _thread;
        private volatile bool _stopped;

        public Watcher(DisplayInfo display, Action<CursorState> onChange, ILogger log)
        {
            _display = display;
            _onChange = onChange;
            _log = log;
            _thread = new Thread(Run) { IsBackground = true, Name = "Vantage cursor", Priority = ThreadPriority.AboveNormal };
            _thread.Start();
        }

        public void Dispose() => _stopped = true;

        private void Run()
        {
            nint lastHandle = -1;
            bool? lastVisible = null;
            while (!_stopped)
            {
                try
                {
                    if (Read(out var handle, out var visible, out var x, out var y) && (handle != lastHandle || visible != lastVisible))
                    {
                        CursorShape? shape = null;
                        if (visible && handle != lastHandle)
                        {
                            if (!_shapes.TryGetValue(handle, out shape))
                            {
                                shape = Draw(handle);
                                if (_shapes.Count > 64) _shapes.Clear();
                                _shapes[handle] = shape;
                            }
                            lastHandle = handle;
                        }
                        lastVisible = visible;
                        _onChange(new CursorState(shape, visible && lastHandle != 0, x, y));
                    }
                }
                catch (Exception error)
                {
                    _log.LogDebug("reading the cursor failed: {Message}", error.Message);
                }
                Thread.Sleep(s_interval);
            }
        }

        /// <summary>The current cursor; false when Windows won't say (the secure desktop).</summary>
        private unsafe bool Read(out nint handle, out bool visible, out float x, out float y)
        {
            var info = new CURSORINFO { cbSize = (uint)sizeof(CURSORINFO) };
            handle = 0;
            visible = false;
            x = y = 0;
            if (!PInvoke.GetCursorInfo(ref info)) return false;
            handle = (nint)info.hCursor.Value;
            // CURSOR_SHOWING = 1; CURSOR_SUPPRESSED = 2 (touch or pen input hides it).
            var flags = (uint)info.flags;
            visible = handle != 0 && (flags & 1) != 0 && (flags & 2) == 0;
            var scale = _display.Scale > 0 ? _display.Scale : 1;
            x = (float)((info.ptScreenPos.X - _display.OriginX) / scale);
            y = (float)((info.ptScreenPos.Y - _display.OriginY) / scale);
            return true;
        }

        /// <summary>The cursor's pixels and hotspot, or null when it can't be drawn.</summary>
        private unsafe CursorShape? Draw(nint handle)
        {
            ICONINFO icon;
            if (!PInvoke.GetIconInfo(new HICON((void*)handle), &icon)) return null;
            try
            {
                var source = icon.hbmColor.IsNull ? icon.hbmMask : icon.hbmColor;
                BITMAP bitmap;
                if (PInvoke.GetObject(source, sizeof(BITMAP), &bitmap) == 0) return null;
                var width = bitmap.bmWidth;
                var height = icon.hbmColor.IsNull ? bitmap.bmHeight / 2 : bitmap.bmHeight; // a mono mask is AND over XOR
                if (width <= 0 || height <= 0 || width > 256 || height > 256) return null;

                var onBlack = Render(handle, width, height, 0x00);
                var onWhite = Render(handle, width, height, 0xFF);
                if (onBlack is null || onWhite is null) return null;
                var image = CursorImage.FromBackgrounds(onBlack, onWhite, width, height);
                var scale = _display.Scale > 0 ? _display.Scale : 1;
                return new CursorShape
                {
                    PngData = PngWriter.Encode(image),
                    WidthPoints = width / scale,
                    HeightPoints = height / scale,
                    HotspotX = icon.xHotspot / scale,
                    HotspotY = icon.yHotspot / scale,
                    Scale = scale,
                };
            }
            finally
            {
                if (!icon.hbmMask.IsNull) PInvoke.DeleteObject(icon.hbmMask);
                if (!icon.hbmColor.IsNull) PInvoke.DeleteObject(icon.hbmColor);
            }
        }

        /// <summary>Draws the cursor on a solid background into a top-down 32-bit DIB.</summary>
        private static unsafe byte[]? Render(nint handle, int width, int height, byte background)
        {
            var dc = PInvoke.CreateCompatibleDC(HDC.Null);
            if (dc.IsNull) return null;
            try
            {
                var header = new BITMAPINFO();
                header.bmiHeader.biSize = (uint)sizeof(BITMAPINFOHEADER);
                header.bmiHeader.biWidth = width;
                header.bmiHeader.biHeight = -height; // top-down
                header.bmiHeader.biPlanes = 1;
                header.bmiHeader.biBitCount = 32;
                header.bmiHeader.biCompression = 0; // BI_RGB
                void* bits;
                var dib = PInvoke.CreateDIBSection(dc, &header, DIB_USAGE.DIB_RGB_COLORS, &bits, HANDLE.Null, 0);
                if (dib.IsNull || bits is null) return null;
                try
                {
                    var previous = PInvoke.SelectObject(dc, dib);
                    var length = width * height * 4;
                    new Span<byte>(bits, length).Fill(background);
                    var drawn = PInvoke.DrawIconEx(dc, 0, 0, new HICON((void*)handle), width, height, 0, HBRUSH.Null, DI_FLAGS.DI_NORMAL);
                    PInvoke.SelectObject(dc, previous);
                    return drawn ? new Span<byte>(bits, length).ToArray() : null;
                }
                finally
                {
                    PInvoke.DeleteObject(dib);
                }
            }
            finally
            {
                PInvoke.DeleteDC(dc);
            }
        }
    }
}
