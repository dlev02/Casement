# Casement Host 1.5

## A window of its own

Casement Host now wears the C-shaped casement mark, with an inset screen that distinguishes it from the client. Mac uses native light, dark, clear and tinted appearances. Windows updates the executable, installer, title bar, About page and tray panel, with light and dark artwork and a connected-state tray glyph.

<p><img src="https://raw.githubusercontent.com/dlev02/Casement/main/brand/casement-host-mac.png" width="144" alt="Casement Host light icon"> <img src="https://raw.githubusercontent.com/dlev02/Casement/main/brand/casement-host-mac-dark.png" width="144" alt="Casement Host dark icon"></p>

## Clearer control on Windows

The Windows Host adds searchable Help & FAQ, clearer pairing controls, and controls for paired devices. Windows Setup installs the Host in a stable location and keeps Installed apps’ version current after an update. The app’s icon follows the Windows theme while the executable icon remains legible on either background.

## Getting the update

Hosts running 1.4 can check for updates in **Settings → General → Updates**. Automatic updates wait until the computer is idle and connections and transfers have finished. Hosts older than 1.4 need a manual download once.

- **Mac:** download the DMG, open it, and drag Casement Host to Applications. The app and DMG are signed, notarized, and stapled by Apple.
- **Windows, Intel/AMD:** download `Casement-Host-Setup-x64.exe` and choose Install.
- **Windows, ARM:** download `Casement-Host-Setup-arm64.exe`. ARM64 is cross-built; it has not been exercised on ARM hardware.

Saved pairings and settings stay in place. Windows packages remain unsigned at the executable/installer level; the updater manifest is signed with the existing Casement update key. Checksums accompany the downloads. The Apple client’s 1.1 beta is delivered separately through TestFlight.
