# Casement icon

The mark is a C-shaped casement frame with one pane swung open. Casement uses plum and lavender;
Casement Host uses slate and adds an inset screen. The extra shape keeps the Host distinct in
clear, tinted, and monochrome appearances too.

The shipping icons are Icon Composer documents, so iOS, iPadOS and macOS 26 render Liquid Glass and the
dark, clear and tinted appearances themselves:

- `Vantage/Casement.icon` (client; separate SVG frame and pane layers).
- `VantageHost/CasementHost.icon` (Host).
- `Vantage/Assets.xcassets/AppIcon.solidimagestack` (visionOS, which can't use `.icon`: back, middle and
  front layers for the headset's parallax).
- `WindowsHost/src/Vantage.Host.Windows/Assets/Vantage.ico` (Casement Host for Windows; a transparent,
  contrast-balanced mark at 16–256 px). The title bar, About page, and tray panel select
  `CasementHostLight.png` or `CasementHostDark.png` through a XAML theme resource. Monochrome tray
  glyphs follow the taskbar theme and retain the connected arrow; transfer progress stays separate.

This folder holds the sources and exports:

| File | Use |
| --- | --- |
| `casement-1024.png`, `casement-host-1024.png` | Full-bleed squares, no mask (store art, website) |
| `casement-dark-1024.png`, `casement-host-dark-1024.png` | Dark full-bleed reference compositions |
| `casement-mac.png`, `casement-host-mac.png` | 512 px native macOS renders on transparency (README, docs) |
| `casement-mac-dark.png`, `casement-host-mac-dark.png` | 512 px native dark macOS renders |
| `casement-host.ico` | Windows export |
| `social-preview.png` | GitHub social preview, 1280×640 |
| `layers/` | SVG frame, pane, and Host screen layers |
| `generate-icons.py` | Shared geometry and palettes; regenerates Apple, visionOS, Windows, tray, and brand assets |

Edit the icons in Icon Composer (`/Applications/Xcode.app/Contents/Applications/Icon Composer.app`).
Default and dark backgrounds and foreground fills are explicit. The mono specialization uses a
neutral foreground so dark brand colors stay legible in clear and tinted modes. Apple supplies the
glass effects and platform masks; the source layers contain neither.

Regenerate everything on a Mac with Pillow and Xcode's Icon Composer installed:

```sh
python3 brand/generate-icons.py
```

`python3 WindowsHost/scripts/make-icons.py` regenerates only the Windows app and tray assets from
the same geometry, without Apple tools. Neither command changes versions or release metadata.
