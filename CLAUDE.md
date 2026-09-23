# Vantage — agent guide

Vantage is a native Apple remote-desktop app: an iPadOS client controls a macOS host over
Tailscale only. It is a personal, Screens-5-style alternative for Drew, macOS-first. The Xcode
project is `Vantage.xcodeproj` (hand-maintained pbxproj, objectVersion 77, file-system-synchronized
groups). Read this before working here.

## Targets and layout

| Target | Path | Product |
| --- | --- | --- |
| `VantageHost` | `VantageHost/` | macOS 26+ menu-bar app (LSUIElement), unsandboxed, Developer ID intended |
| `Vantage` | `Vantage/` | iPadOS/iOS 26+ client (universal) |
| `VantageCore` | `Packages/VantageCore/` | Local SPM package shared by both: wire protocol, transport, identity |

Signing: `DEVELOPMENT_TEAM = PMX23WPLM5` (Drew's team; the only non-revoked cert on this Mac).
Bundle ids: host `com.benjaminlevinson.vantage.host`, client `com.benjaminlevinson.vantage`.
Swift 6, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY = YES`.

## Architecture

- **Transport**: one framed TCP stream per session over the tailnet (`MessageChannel`, an actor
  wrapping `NWConnection`). 8-byte header (magic, kind, flags, length) + payload. Control messages
  are JSON (kind < 100); hot-path video/cursor/input are hand-packed little-endian binary (kind ≥
  100). See `Packages/VantageCore/Sources/VantageCore/Wire` and `Messages`.
- **Auth**: Ed25519 device identities in Keychain. Host challenges with a nonce; client signs a
  domain-separated transcript. First connection needs a 6-digit pairing code shown on the Mac; after
  that the key is trusted. A pairing code expires after 10 minutes and is burned after 5 wrong
  guesses (`TrustStore.consumePairingCode`); each miss also costs the peer a second. The listener
  rejects any peer outside Tailscale's CGNAT/ULA ranges; loopback is accepted only in DEBUG builds.
- **Host pipeline**: `ScreenCapture` (ScreenCaptureKit, `'420v'`, sRGB, dirty-rect ratio) →
  `VideoEncoder` (VideoToolbox low-latency, no reordering, event-driven IDRs, BT.709/sRGB colour
  tags) → `MessageChannel`. Incoming input goes to `InputInjector` (CGEvent, releases all held
  keys/buttons on disconnect). `AdaptiveController` runs AIMD bitrate + text/motion fps from client
  feedback. `HostSession` (actor) orchestrates one client; `HostController` owns the listener.
- **Client pipeline**: `ClientSession` (handshake, reconnect with backoff) → `VideoStreamController`
  (`AVSampleBufferDisplayLayer.sampleBufferRenderer`, `DisplayImmediately`, flush + keyframe request
  on decode failure). `RemoteInteractionView` captures touch/trackpad/mouse/hardware-keyboard and
  forwards through `InputController`. SwiftUI shell: `DeviceListScreen`, `RemoteSessionScreen`,
  `ControlStrip`, Liquid Glass throughout.
- **Virtual display**: `VirtualDisplayManager` provisions a BetterDisplay virtual screen sized to
  the iPad viewport (behind a protocol so `CGVirtualDisplay` can replace it later). It is opt-in
  per saved device (`SavedDevice.useVirtualDisplay` → `SelectDisplay.useVirtualDisplay`). The
  default path streams the main display immediately; never put BetterDisplay's CLI back on the
  connect path unconditionally — on Drew's Mac it answers "Failed." to everything and the old
  15 s poll made every connect take 16 s. When the toggle is on, a connected non-built-in display
  whose point size already matches the viewport is reused without touching the CLI.
- **Tailscale account**: `TailscaleAccount` (client) talks read-only to `api.tailscale.com`
  (`GET /api/v2/tailnet/-/devices`) with either an API access token or an OAuth client
  (`client_credentials` at `/api/v2/oauth/token`, tokens cached ~1 h). Tailscale has no end-user
  sign-in for third-party apps, so the user pastes a key from the admin console; it lives in the
  Keychain. `TailscaleDevicesSheet` lists Macs (probed with `HostAvailabilityProbe`) and greys out
  other platforms. Debug flags: `-VantageTailscaleFixture 1` serves a fictional tailnet,
  `-VantageOpenTailscaleDevices 1` opens the picker on launch.
- **Software keyboard**: `SoftwareKeyboardMode` (Unicode Text or Keystrokes). Keystrokes maps
  characters through `CharacterKeyMap` (US layout) to real key events; unmapped characters fall
  back to Unicode text. Held ⌘/⌥/⌃ from the control strip always route through keystrokes.

## Build & test

```
# Shared core (fast, no simulator)
xcrun swift test --package-path Packages/VantageCore

# Client session regression tests (actual source, loopback mock host)
xcrun swift test

# Host (macOS)
xcodebuild build -project Vantage.xcodeproj -scheme VantageHost -destination 'platform=macOS' -derivedDataPath .deriveddata

# Client (iOS Simulator)
xcodebuild build -project Vantage.xcodeproj -scheme Vantage -destination 'generic/platform=iOS Simulator' -derivedDataPath .deriveddata
```

Reuse `.deriveddata`; do not create per-task DerivedData trees. Use regular Xcode 27, not Xcode-beta. Set `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` for shell builds and `xcrun swift` for tests. `scripts/check.sh` runs both test suites and both builds.

## Running for real

The host needs two TCC grants the first time: Screen Recording and Accessibility (for CGEvent). The
menu-bar UI surfaces both with buttons. Tailscale must be running on both devices. Unattended access
(login-window capture, FileVault reboot recovery) is deliberately out of scope for v1 — see the
research notes.

## Research

`docs/research/` holds the verified engineering reports that back these decisions (media pipeline,
input, Tailscale, virtual display, product/host lifecycle). They cite SDK headers and are the source
of truth for API specifics and gotchas. Read the relevant one before changing capture, encode,
decode, input, or Tailscale code.

## Headless end-to-end testing (no permissions needed)

The simulator cannot route to the Mac's Tailscale interface, so test over loopback (the host accepts
loopback peers in addition to tailnet peers):

```
open -n .deriveddata/Build/Products/Debug/VantageHost.app --args --synthetic-capture --port 47821 --pairing-code 246810
xcrun simctl launch <sim> com.benjaminlevinson.vantage -VantageAutoConnect 127.0.0.1:47821 -VantagePairingCode 246810
```

`--synthetic-capture` streams a rendered test pattern and never touches ScreenCaptureKit, so the
whole encode → transport → decode → display path runs without Screen Recording access.

To test against the **real** host (display capture + CGEvent input) from the simulator, launch the
Debug host with `--pairing-code 246810` and no `--synthetic-capture`, then auto-connect the
simulator to `127.0.0.1`. The simulator's identity is trusted after the first pairing. To verify
clicks without touching anything on the desktop, build `scripts/click-target.swift` (`swiftc -O`)
and run it: it floats an orange window at CG 400–700 × 300–500 and prints every pointer event it
receives; a tap in the simulator in Trackpad mode clicks at the display centre, inside that window.
Drive the simulator with Axiom's `xcui tap -x -y` (the `--label` matcher does not resolve SwiftUI
rows here). Host timing is logged as "stream setup took N ms" in the `session` category, and every
click as "pointer down/up" in the `input` category. Synthetic mode
disables real input, clipboard access, and host commands, and uses a separate trust store. Host synthetic
and fixed-code arguments are DEBUG-only. The debug-only `--port 47821` override allows isolated tests alongside the normal host on 47820; quit the synthetic host afterward. Client debug
flags (`-VantageSeedSamples 1`, `-VantageSeedHost`, `-VantageAutoConnect`, `-VantagePairingCode`)
are DEBUG-only. Read unified logs with `/usr/bin/log show --info --debug` (a shell function shadows
`log` in Drew's profile).

## Reboot, lock screen, and login window (what is and isn't possible)

- **Reboot**: enable "Start Vantage Host at login" (Settings → Reboot). After login the host relaunches
  and the client reconnects on its own (it retries for ~10 minutes and again when foregrounded).
- **Restart guard**: `RestartGuard` (host) inspects the quit Apple event's `kAEQuitReason`; while a
  device is connected, a restart/shutdown/logout (including Software Update's) gets a confirmation
  alert and `.terminateCancel` aborts it. `sudo reboot` and panics can't be caught. Toggle in host
  Settings → Reboot.
- **FileVault** is on for this Mac and auto-login is off, so a cold boot waits at the pre-boot unlock
  screen. Tailscale (the standalone System Extension variant here) only starts after login; nothing
  user-space can pass pre-boot. macOS 26+ can unlock over SSH (`man apple_ssh_and_filevault`), which
  from afar needs a Tailscale subnet router on the home LAN. `fdesetup authrestart` works here for
  planned restarts: **Restart Safely** (`SafeRestart`, host menu / Settings → Reboot / a button in
  the restart guard) prompts for the password, runs `fdesetup authrestart -delayminutes -1
  -inputplist` via `do shell script … with administrator privileges` (plist fed through a FIFO in
  a 0700 temp dir, never argv or disk), then asks loginwindow for a normal restart with a
  `kAERestart` Apple event (entitlement `com.apple.security.automation.apple-events` +
  `NSAppleEventsUsageDescription`); if that's refused the user restarts from the Apple menu. Only
  the wrong-password path has been exercised; a real staged restart still needs a check. See
  `docs/research/secure-input-and-reboot.md` §5.
- **Login window**: `SavedDevice.homeAddress` (optional LAN IP) + device-list "Log In with Screen
  Sharing" (`ScreenSharingPassword.logIn`) types the password via screensharingd, trying the
  tailnet host then the home address, which is reachable pre-login only through a Tailscale subnet
  router on the home LAN.
- **Lock screen / password fields**: Secure Event Input blocks CGEvent keystrokes from every
  third-party app. The host detects lock and secure-input state (`LockMonitor`) and the client shows
  a banner; the key button then types the saved password through Apple's `screensharingd` (see Mac
  shortcuts and password above). That also works at a logged-out login window if the Mac is
  reachable, but not at FileVault pre-boot.

## Known v1 limitations

- Software-keyboard Backspace and Return send virtual key events; other text uses Unicode input.
  Hardware behavior still needs a physical-device check.
- File transfer is not implemented; clipboard carries text, RTF, and PNG images both ways.
- Virtual-display provisioning is wired but falls back to the main display if BetterDisplay's CLI
  isn't available. Drew verified real Mac video, pointer/clicks, and software-keyboard typing on the physical iPad.
  Clipboard, hardware keyboard, BetterDisplay, and biometric session recovery still need device checks.
