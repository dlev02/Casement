#!/usr/bin/env python3
"""Export the approved generated Vantage artwork to Apple and Windows icon sizes."""
import json
import os
from pathlib import Path
import subprocess

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
BRAND = ROOT / "brand"
CLIENT = ROOT / "Vantage/Assets.xcassets/AppIcon.appiconset"
HOST = ROOT / "VantageHost/Assets.xcassets/AppIcon.appiconset"
DEVELOPER_DIR = os.environ.get("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")


def resize(source: Path, output: Path, pixels: int) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["sips", "-s", "format", "png", "-z", str(pixels), str(pixels),
                    str(source), "--out", str(output)], check=True,
                   stdout=subprocess.DEVNULL,
                   env=os.environ | {"DEVELOPER_DIR": DEVELOPER_DIR})


def contents(path: Path, entries: list[dict]) -> None:
    path.write_text(json.dumps({"images": entries, "info": {"author": "xcode", "version": 1}},
                               indent=2) + "\n")


ios = BRAND / "vantage-ios-master.png"
mac = BRAND / "vantage-mac-master.png"
resize(ios, CLIENT / "Vantage.png", 1024)
# Xcode derives dark and tinted appearances from the primary icon. The generated
# mark already uses a dark ground, so a separate dark illustration adds no value.
contents(CLIENT / "Contents.json", [{"filename": "Vantage.png", "idiom": "universal",
                                     "platform": "ios", "size": "1024x1024"}])
for stale in ("Vantage-dark.png", "Vantage-tinted.png"):
    (CLIENT / stale).unlink(missing_ok=True)

entries = []
for points in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        pixels = points * scale
        name = f"Vantage-{points}@{scale}x.png"
        resize(mac, HOST / name, pixels)
        entries.append({"filename": name, "idiom": "mac", "scale": f"{scale}x",
                        "size": f"{points}x{points}"})
contents(HOST / "Contents.json", entries)

logo = ROOT / "VantageHost/Assets.xcassets/VantageLogo.imageset"
resize(mac, logo / "VantageLogo.png", 128)
contents(logo / "Contents.json", [{"filename": "VantageLogo.png", "idiom": "universal"}])

with Image.open(HOST / "Vantage-512@2x.png") as image:
    image.save(BRAND / "vantage.ico", format="ICO",
               sizes=[(n, n) for n in (16, 24, 32, 48, 64, 128, 256)])
print("Exported generated Vantage artwork to iOS, macOS, and Windows icon formats.")
