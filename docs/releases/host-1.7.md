# Casement Host 1.7

## A picture that doesn't freeze

Now and then the picture from a computer would stop and stay stopped, even though everything else still worked. I traced it to a few places where Casement Host waited for an answer that sometimes never came, and fixed them on both the Mac and the PC:

- **A dropped frame no longer freezes the picture.** If the video encoder skipped a frame or answered late, the host could wait for it forever. Now it gives up after a second and sends a fresh frame.
- **A still screen answers at once.** When your device asks for a fresh picture and nothing on the computer is moving, the Mac now sends one straight away instead of waiting for something to change.
- **Waking the display works more reliably.** If the Mac's display woke while its picture was still shutting down, the new picture could be wiped out. That can't happen now.
- **A picture that never starts gets retried.** If capture starts but no picture comes, the Mac notices within five seconds and tries again, as the PC already did, and each retry waits its full time.
- **Removing a device mid-session** no longer leaves the Mac's displays black or Curtain up with nobody connected.

## Virtual displays that fit any screen

With **Virtual Display** on, a Mac host now makes the virtual display the size of your device's window in points. Before, it assumed a Retina screen, so a 1× external monitor got one too small and a 3× iPhone one too big. The next Casement update adds a switch to turn Virtual Display (or Fit Display for a PC) on and off during a session.

## Windows on ARM

The ARM package now ships ARM parts throughout. In 1.5 and 1.6 it held x64 components and probably wouldn't start. It still hasn't run on ARM hardware, so please [tell me](https://github.com/dlev02/Casement/issues) how it goes.

## Getting the update

Hosts running 1.4 or later update by themselves when nothing is connected, or you can check in **Settings → General → Updates**. Hosts older than 1.4 need a download by hand once.

- **Mac:** download the DMG, open it, and drag Casement Host to Applications. The app and DMG are signed, notarized, and stapled by Apple.
- **Windows, Intel/AMD:** download `Casement-Host-Setup-x64.exe` and choose Install.
- **Windows, ARM:** download `Casement-Host-Setup-arm64.exe` and choose Install.

Saved pairings and settings stay in place. Windows packages are not code-signed, so Windows may warn about an unknown publisher; the update manifest is signed with the existing Casement update key. Checksums accompany the downloads.
