# Vantage

A native remote desktop for controlling your Mac from an iPad or iPhone over Tailscale.

**Private development preview.** The macOS host and iPadOS/iOS client are implemented. Windows hosting is not implemented. This is source code for local builds, not a signed installer or an App Store release. Basic real-Mac video, pointer control, and software-keyboard typing are user-verified on a physical iPad; see the [verification report](docs/testing/2026-09-22.md) for remaining checks.

## What it does

- Streams a Mac display using ScreenCaptureKit and hardware HEVC or H.264 encoding.
- Supports touch, trackpad-style gestures, hardware keyboards, and an on-screen command strip that adapts to iPad and iPhone widths.
- Collapses the session toolbar to a compact keyboard control; drag it between all four corners, with your position remembered.
- Offers Automatic, Light, and Dark appearance in organized settings.
- Checks saved hosts for authenticated availability and required Mac permissions without capturing desktop previews.
- Pairs a client using a six-digit code, then remembers its device identity.
- Shares text, rich text, and PNG clipboard content. Sending the iPad clipboard is an explicit action.
- Reconnects after a dropped connection and immediately when returning to an open session from another app.
- Offers start-at-login on the Mac and an optional device-authentication lock on the client.
- Uses coordinated Vantage icons on Mac, iPad, and iPhone, with a Windows `.ico` ready for future packaging.
- Can request a virtual display through BetterDisplay's CLI, with a main-display fallback. This integration still needs a live test.

## Requirements

| Component | Requirement |
| --- | --- |
| Mac host | macOS 26 or later, an unlocked logged-in session |
| Client | iPadOS 26 or iOS 26 or later |
| Network | Tailscale connected on both devices in the same tailnet, with access to TCP port 47820 |
| Build tools | Regular Xcode 27; verified with build 27A266a |
| Signing | Your own development team for physical-device installation |
| Optional | BetterDisplay and its CLI for viewport-sized virtual displays |

Vantage uses its own protocol. It does not connect to Windows RDP, VNC, or Apple's built-in Screen Sharing service.

## Build

Open `Vantage.xcodeproj` in **regular Xcode**. Select your development team for both targets if needed; preserve bundle identifiers for an existing installation.

Or build from the repository root:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild build -project Vantage.xcodeproj -scheme VantageHost \
  -destination 'platform=macOS' -derivedDataPath .deriveddata
xcodebuild build -project Vantage.xcodeproj -scheme Vantage \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath .deriveddata
```

The products are `.deriveddata/Build/Products/Debug/VantageHost.app` and `.deriveddata/Build/Products/Debug-iphonesimulator/Vantage.app`. To install on an actual iPad or iPhone, select that device as the `Vantage` scheme's run destination in Xcode and build/run with your signing team.

## First connection

1. Connect Tailscale on the Mac and iPad/iPhone. Complete any pending Tailscale sign-in on the client.
2. Launch **Vantage Host** on the Mac. It lives in the menu bar, rather than opening a normal window.
3. Use its **Grant Screen Recording** and **Grant Accessibility (input)** buttons. Approve Vantage Host in **System Settings → Privacy & Security → Screen & System Audio Recording / Accessibility**. Reopen the same host build after approving if macOS requests it.
4. In the client, choose **Add Device**. Enter the Mac's Tailscale IP or MagicDNS name, a display name, and port **47820**. Pasted `host:port` addresses are also accepted; the pasted port takes precedence. Save, then tap the Mac's card or row to connect.
5. Select the device. In the Mac menu, choose **Show pairing code**, then enter that code in the client and tap **Pair**. A code is consumed once; generate another for each new device.
6. In a session, use **Session Options** for touch mode, **Send Clipboard to Mac**, or **Disconnect**. The keyboard button opens or closes software input; its **Done** button dismisses it.

Drag either the expanded toolbar or its compact control to move it to a top or bottom corner. Tap the chevron to collapse or expand. Settings separates Appearance, Controls, Connection, and Privacy & Security. An **Available** host has answered an authenticated probe and reports both Mac permissions granted; older hosts show **Host online** until updated. Checks run only while the device list is visible.

Optional: enable **Start Vantage Host at login** in the host's **Settings → Reboot** tab. The Mac must still finish login after a restart.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Cannot connect / reconnecting | Tailscale is connected on both devices, the host is running, the address and port are correct, and tailnet policy permits the connection. Close remains available while retrying. |
| Pairing prompt returns | Generate a fresh code on the Mac. Verify all six digits; codes are single use. |
| Screen Recording error | Approve the host on the Mac, reopen it, and choose Retry on the client. |
| Video works but input does not | Approve Accessibility for the exact host build. Check whether the Mac is locked or a secure field is focused. |
| Mac rebooted and is unreachable | Log in locally. Vantage cannot unlock FileVault at pre-boot or type at the login window. |
| Virtual screen not created | Confirm BetterDisplay's CLI is available. Vantage falls back to the main display. |
| Simulator cannot reach the Tailscale address | Use the loopback synthetic check below. Simulator behavior does not establish physical tailnet connectivity. |

## Development checks

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcrun swift test --package-path Packages/VantageCore
xcrun swift test
```

The first suite checks wire encoding, identities, geometry, and real loopback transport. The root package compiles actual client source and tests pairing, bad-code retry, reconnect and foreground recovery, canceled handshakes, authenticated availability probes, address parsing, and toolbar docking. It also stress-tests four concurrent synthetic renderers.

For a permission-free video check, build both debug targets, start a simulator, and substitute its ID for `SIMULATOR_ID`:

```sh
open -n .deriveddata/Build/Products/Debug/VantageHost.app \
  --args --synthetic-capture --port 47821 --pairing-code 246810
xcrun simctl install SIMULATOR_ID .deriveddata/Build/Products/Debug-iphonesimulator/Vantage.app
xcrun simctl launch SIMULATOR_ID com.benjaminlevinson.vantage \
  -VantageAutoConnect 127.0.0.1:47821 -VantagePairingCode 246810
```

The debug-only port override keeps the test host separate from the normal host on port 47820. Synthetic mode renders a moving test pattern and does not capture the desktop, inject input, apply host commands, or read/write the real clipboard. Its paired-device records are separate from normal host records. The fixed code and synthetic launch arguments are debug-only. **Quit the test host after testing. Use the normal host on port 47820 for your real desktop.**

With that synthetic host running, native UI tests cover availability, appearance selection, toolbar collapse/expansion and dragging, and returning from the Home Screen:

```sh
xcodebuild test -project Vantage.xcodeproj -scheme VantageUITests \
  -destination 'platform=iOS Simulator,id=SIMULATOR_ID' \
  -derivedDataPath .deriveddata -parallel-testing-enabled NO
```

## Architecture and boundaries

```text
Mac: ScreenCaptureKit → VideoToolbox → VantageCore framed TCP
                                           ↕ Tailscale
Client: AVSampleBufferDisplayLayer ← VantageCore
          touch / keyboard / clipboard → Mac
```

- `VantageHost/`: menu-bar app, screen capture, encoder, input injection, permissions, and host lifecycle.
- `Vantage/`: SwiftUI client, saved devices, connection lifecycle, rendering, and input.
- `Packages/VantageCore/`: protocol, Ed25519 identity, network transport, and core tests.
- `Tests/ClientSessionTests/`: actual-client loopback regression tests.
- [Icon sources](brand/README.md): approved artwork and cross-platform exports.
- [Research](docs/research/README.md): engineering notes and source references.
- [Agent guide](CLAUDE.md): repository conventions and implementation notes.

Encryption is supplied by Tailscale's tunnel; Vantage's TCP stream does not add TLS. The host accepts tailnet addresses and local loopback, then requires device authentication/pairing. Use it only on a trusted tailnet. This preview has not had a comprehensive security audit; host identity pinning and expiring/rate-limited pairing should be reviewed before broader distribution.

Known limits: no Windows host, file transfer, remote audio, login-window control, or FileVault pre-boot access. Physical keyboard/trackpad behavior, clipboard, BetterDisplay provisioning, sleep/wake, and launch-at-login still need device testing. Distribution packaging is unfinished.
