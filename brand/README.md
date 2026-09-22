# Vantage icon

The mark shows two views meeting to form a subtle V. We kept the Vantage name because it already fits the idea of seeing and controlling a distant desktop, and it avoids changing app identities while development is underway.

`vantage-ios-master.png` is the full-bleed, opaque image-generation master. `vantage-mac-master.png` is the matching rounded tile with transparent outside corners. `vantage-concept.png` is the initial exploration. These are the editable source images for future visual work; the two final masters are the source of the app icons. The repository also includes a Windows `.ico` for a future host app. The Windows host itself has not been built.

From the repository root, regenerate platform exports with regular Xcode selected:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 scripts/generate-icons.py
```

The script uses macOS `sips` and Python Pillow to size the approved artwork for the asset catalogs and Windows ICO. It preserves the same brand across platforms. Xcode derives dark and tinted Home Screen treatments from the primary iOS image.
