#!/usr/bin/env python3
"""Draws the Windows host's icons (run on the Mac; needs Pillow).

- Tray glyphs, like the Mac menu bar item ("display", "display.and.arrow.down"):
  src/Vantage.Host.Windows.Platform/Tray/Icons/tray-{idle,connected}-{light,dark}.ico
  "light" is for a light taskbar (dark glyph), "dark" for a dark taskbar (white glyph).
  Sizes 16, 20, 24, 32, 40, 48 px (100–300 % scaling), PNG entries.
- The app icon from the Mac/iOS artwork: src/Vantage.Host.Windows/Assets/Vantage.ico (16–256 px).

Usage: python3 WindowsHost/scripts/make-icons.py
"""
import io
import os
import struct

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
REPO = os.path.dirname(ROOT)
TRAY_DIR = os.path.join(ROOT, "src", "Vantage.Host.Windows.Platform", "Tray", "Icons")
APP_DIR = os.path.join(ROOT, "src", "Vantage.Host.Windows", "Assets")
APP_ART = os.path.join(REPO, "VantageHost", "Assets.xcassets", "AppIcon.appiconset", "Vantage-512@2x.png")

TRAY_SIZES = [16, 20, 24, 32, 40, 48]
APP_SIZES = [16, 20, 24, 32, 40, 48, 64, 256]
SUPERSAMPLE = 8


def glyph(size, color, connected):
    s = size * SUPERSAMPLE
    image = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    stroke = max(SUPERSAMPLE, round(s * 0.085))
    # Screen
    left, top, right, bottom = s * 0.07, s * 0.14, s * 0.93, s * 0.70
    draw.rounded_rectangle([left, top, right, bottom], radius=s * 0.09, outline=color, width=stroke)
    # Stand: neck and foot
    neck = stroke * 0.9
    draw.rectangle([s * 0.5 - neck / 2, bottom, s * 0.5 + neck / 2, s * 0.84], fill=color)
    draw.rounded_rectangle([s * 0.28, s * 0.82, s * 0.72, s * 0.82 + stroke], radius=stroke / 2, fill=color)
    if connected:
        # Arrow down into the screen: someone is watching.
        shaft = stroke * 0.9
        draw.rectangle([s * 0.5 - shaft / 2, s * 0.25, s * 0.5 + shaft / 2, s * 0.47], fill=color)
        draw.polygon([(s * 0.33, s * 0.42), (s * 0.67, s * 0.42), (s * 0.5, s * 0.60)], fill=color)
    return image.resize((size, size), Image.LANCZOS)


def write_ico(path, images):
    """An ICO whose entries are PNG streams (Windows Vista+), largest last."""
    entries = []
    for image in images:
        buffer = io.BytesIO()
        image.save(buffer, format="PNG", optimize=True)
        entries.append((image.width, image.height, buffer.getvalue()))
    header = struct.pack("<HHH", 0, 1, len(entries))
    offset = 6 + 16 * len(entries)
    directory = b""
    data = b""
    for width, height, png in entries:
        directory += struct.pack("<BBBBHHII", width % 256, height % 256, 0, 0, 1, 32, len(png), offset + len(data))
        data += png
    with open(path, "wb") as handle:
        handle.write(header + directory + data)


def main():
    os.makedirs(TRAY_DIR, exist_ok=True)
    for connected in (False, True):
        for theme, color in (("light", (27, 27, 27, 255)), ("dark", (255, 255, 255, 255))):
            name = f"tray-{'connected' if connected else 'idle'}-{theme}.ico"
            write_ico(os.path.join(TRAY_DIR, name), [glyph(size, color, connected) for size in TRAY_SIZES])
            print("wrote", name)
    if os.path.exists(APP_ART):
        os.makedirs(APP_DIR, exist_ok=True)
        art = Image.open(APP_ART).convert("RGBA")
        write_ico(os.path.join(APP_DIR, "Vantage.ico"), [art.resize((size, size), Image.LANCZOS) for size in APP_SIZES])
        print("wrote Vantage.ico")


if __name__ == "__main__":
    main()
