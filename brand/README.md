# Casement icon

The mark shows two views meeting to form a subtle V. It dates from the app's first name, Vantage, which is also why the files are named `vantage-…`.

`vantage-ios-master.png` is the full-bleed, opaque image-generation master. `vantage-mac-master.png` is the matching rounded tile with transparent outside corners. `vantage-concept.png` is the initial exploration. These are the editable source images for future visual work; the two final masters are the source of the app icons. `vantage.ico` is the Windows export, used by Casement Host for Windows.

From the repository root, regenerate platform exports with regular Xcode selected:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 scripts/generate-icons.py
```

The script uses macOS `sips` and Python Pillow to size the approved artwork for the asset catalogs and Windows ICO. It preserves the same brand across platforms. Xcode derives dark and tinted Home Screen treatments from the primary iOS image.
