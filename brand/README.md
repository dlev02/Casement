# Casement icon

The mark is a white pointer resting on a tilted pane of frosted glass: reaching through a window into
your other computer. Casement Host uses the same mark in graphite on silver.

The shipping icons are Icon Composer documents, so iOS, iPadOS and macOS 26 render Liquid Glass and the
dark, clear and tinted appearances themselves:

- `Vantage/Casement.icon` (client; the pointer is vector, the glass slab is a rendered PNG layer over a
  cobalt fill with a navy dark-mode fill).
- `VantageHost/CasementHost.icon` (Host).
- `Vantage/Assets.xcassets/AppIcon.solidimagestack` (visionOS, which can't use `.icon`: back, middle and
  front layers for the headset's parallax).
- `WindowsHost/src/Vantage.Host.Windows/Assets/Vantage.ico` (Casement Host for Windows; 16–32 px use a
  simplified cut with no tilt and a larger pointer).

This folder holds the sources and exports:

| File | Use |
| --- | --- |
| `casement-1024.png`, `casement-host-1024.png` | Full-bleed squares, no mask (store art, website) |
| `casement-mac.png`, `casement-host-mac.png` | macOS shape and shadow on transparency (README, docs) |
| `casement-host.ico` | Windows export |
| `social-preview.png` | GitHub social preview, 1280×640 |
| `layers/` | Background, slab and pointer layers (SVG and PNG) for both icons, plus the 16 px small cut |

Edit the icons in Icon Composer (`/Applications/Xcode.app/Contents/Applications/Icon Composer.app`).
The glass slab began as an image-generation render and was refitted to the vector geometry by hand.
