# Casement Host 1.8

Host 1.8 goes with Casement 1.2 (9). Most of that build's new features need it.

## Sharper text, and a picture that arrives fitted

- **Quality presets.** Your device can now ask for Fluid, Balanced or Sharp Text, and change its
  mind mid-session without the stream restarting.
- **Text sharpens when the screen stops.** A still screen used to keep whatever softness the last
  moving frame left. Now, a moment after things stop, the host sends one more, sharper pass.
- **Fit Display settles first.** The host waits for the fitted mode before sending the picture, and
  a PC keeps the fitted mode through a brief reconnect instead of switching back and forth.

## Mac: local network, Trackpad & Keyboard, Pencil

- **Local network connections** (Settings > General, off by default): a device you've already
  paired can connect over your own network or a cable, without Tailscale. The Mac accepts private
  and link-local addresses only and Casement encrypts the connection itself. New devices still pair
  over Tailscale.
- **Trackpad & Keyboard sessions:** an iPhone or iPad can drive the Mac's pointer and keyboard with
  no picture. These need Accessibility only, not Screen Recording.
- **Apple Pencil:** pressure and tilt arrive as pen-tablet events.
- The Mac tells your device how its Natural Scrolling is set.

## PC: administrator prompts and apps

Windows doesn't let an ordinary app click on Task Manager, an installer, or a "Do you want to allow
this app" prompt. Two changes:

- **Casement says so.** When an administrator app is in front, your device shows why clicks aren't
  landing, and asks before opening Task Manager.

![The banner on iPad](images/host-1.8-admin-banner.png)

- **Control administrator prompts and apps** (Settings > General, off by default). Turning it on
  installs Casement Host Service after one Windows permission prompt at the PC. With it, a paired
  device can see and answer administrator prompts, use Task Manager, and unlock the lock screen
  with your PIN. It never signs in after a restart. Turning it off, or uninstalling Casement Host,
  removes it. It replaces the older "start elevated" task. What it can and can't protect against is
  in [SECURITY.md](../../SECURITY.md).

**This service is new and has not yet run on a real PC**: it builds and its tests pass, but
installing it, answering a prompt and unlocking haven't been tried on hardware. If you turn it on,
please [tell me](https://github.com/dlev02/Casement/issues) how it goes.

- **Trackpad scrolling** from a Mac or iPad now goes the right way on a PC.

## Getting the update

Hosts running 1.4 or later update by themselves when nothing is connected, or you can check in
**Settings → General → Updates**. An update doesn't replace an installed Casement Host Service:
turn the setting off and on again to get the new one.
