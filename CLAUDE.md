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
  that the key is trusted. The listener also rejects any peer outside Tailscale's CGNAT/ULA ranges.
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
  the iPad viewport (behind a protocol so `CGVirtualDisplay` can replace it later).

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
open -n .deriveddata/Build/Products/Debug/VantageHost.app --args --synthetic-capture --pairing-code 246810
xcrun simctl launch <sim> com.benjaminlevinson.vantage -VantageAutoConnect 127.0.0.1 -VantagePairingCode 246810
```

`--synthetic-capture` streams a rendered test pattern and never touches ScreenCaptureKit, so the
whole encode → transport → decode → display path runs without Screen Recording access. Synthetic mode
disables real input, clipboard access, and host commands, and uses a separate trust store. Host synthetic
and fixed-code arguments are DEBUG-only. Quit the synthetic host before a real-device test. Client debug
flags (`-VantageSeedSamples 1`, `-VantageSeedHost`, `-VantageAutoConnect`, `-VantagePairingCode`)
are DEBUG-only. Read unified logs with `/usr/bin/log show --info --debug` (a shell function shadows
`log` in Drew's profile).

## Reboot, lock screen, and login window (what is and isn't possible)

- **Reboot**: enable "Start Vantage Host at login" (Settings → Reboot). After login the host relaunches
  and the client reconnects on its own (it retries for ~10 minutes and again when foregrounded).
- **FileVault** is on for this Mac and auto-login is off, so a cold boot waits at the pre-boot unlock
  screen. Tailscale is not running there; nothing user-space can pass it. macOS 26+ can unlock over
  SSH from the local network only (Remote Login is enabled here).
- **Lock screen / login window**: Secure Event Input blocks synthesized keyboard events from every
  third-party app, so typing a password remotely is impossible. The host detects lock and
  secure-input state (`LockMonitor`) and the client shows a banner. The only shipping technique
  is bridging through Apple's `screensharingd` (enabled on this Mac, ARD auth type 30); that is a
  future subproject (see `docs/research/input.md` A.1b), not built.

## Known v1 limitations

- Software-keyboard Backspace and Return send virtual key events; other text uses Unicode input.
  Hardware behavior still needs a physical-device check.
- File transfer is not implemented; clipboard carries text, RTF, and PNG images both ways.
- Virtual-display provisioning is wired but falls back to the main display if BetterDisplay's CLI
  isn't available. Live capture/input on a real display is still unverified pending the two TCC
  grants; the synthetic path is verified end to end.
