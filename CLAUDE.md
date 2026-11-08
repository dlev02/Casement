# Vantage (Casement) — agent guide

**Naming**: the product is **Casement** (a hinged window that swings open). It was Vantage, then
Porthole (2026-09-30), and became Casement on 2026-10-11 because a paid "Porthole: Remote Desktop"
reached the App Store first. The App Store name is "Casement: Remote Desktop" (app id 6821765234);
everywhere else a person sees **Casement** / **Casement Host**: display names
(`INFOPLIST_KEY_CFBundleDisplayName`, the client's `CFBundleName` in `Vantage/en.lproj/InfoPlist.strings`
for the Mac menu bar), the Mac products (`Casement.app`, `Casement Host.app`: `PRODUCT_NAME` with
`PRODUCT_MODULE_NAME` kept at `Vantage`/`VantageHost`), permission prompts, UI text, the FAQ, the
Windows tray app and Start-menu shortcut, and the docs. **Bundle IDs** are `me.drewlevinson.casement…`
(client; `.host`, `.widgets`, `.uitests`, `.macuitests`; App Group `group.me.drewlevinson.casement`;
background tasks `me.drewlevinson.casement.transfers.*`) on team `7BVMD7TA97`: the old
`com.benjaminlevinson.vantage…` IDs belong to a revoked team and can't be registered on the new
one, so the move started every install fresh (saved devices, pairings, host settings). The code
keeps **Vantage**: project, targets, schemes, module and type names, the `vantage://` scheme,
defaults keys (`vantage.*`), Keychain service names and log subsystems (which still read
`com.benjaminlevinson.vantage…` as plain namespaces, as do the widget and control kinds), debug
flags (`-Vantage…`), and on-disk locations (`Application Support/Vantage Host/Models`,
`…/Vantage/catalog.json`, `%LOCALAPPDATA%\Vantage Host`, the Windows Run value, DPAPI entropy,
firewall rule), because renaming those would orphan existing installs. Anything that means the
app's bundle identifier uses the new one. New user-facing text says Casement; this guide still
says Vantage when it means the code. The GitHub repo is `dlev02/Casement`.

Vantage is a native Apple remote-desktop app: an iPadOS client controls a macOS host over
Tailscale only. It is a personal, Screens-5-style alternative for Drew, macOS-first. The Xcode
project is `Vantage.xcodeproj` (hand-maintained pbxproj, objectVersion 77, file-system-synchronized
groups). Read this before working here.

## Targets and layout

| Target | Path | Product |
| --- | --- | --- |
| `VantageHost` | `VantageHost/` | `Casement Host.app`: macOS 26+ menu-bar app (LSUIElement), unsandboxed, Developer ID intended |
| `Vantage` | `Vantage/` | `Casement.app`: iPadOS/iOS 26+ client (universal), also native visionOS 26+ and macOS 26+ (`SDKROOT = auto`; sandbox entitlements from `ENABLE_*[sdk=macosx*]` build settings, merged with `Vantage/VantageMac.entitlements`; iOS and visionOS sign with `Vantage/Vantage.entitlements`) |
| `VantageCore` | `Packages/VantageCore/` | Local SPM package shared by both: wire protocol, transport, identity |
| `VantageWidgets` | `VantageWidgets/` | iOS widget extension (`VantageWidgets.entitlements`: the App Group) (WidgetKit + App Intents), embedded in `Vantage` on iOS only (`platformFilters = (ios, )` on the embed file and dependency) |
| — | `Shared/` | Synced folder compiled into both `Vantage` and `VantageWidgets`: `DeviceCatalog`, `MacEntity`, widget views |

Inside them: the client is `Vantage/{Model, UI, Input, Video, Audio, Dictation, Transfer, Net,
Intents, Mac}` (`Mac/` is the macOS-only shell); the host `VantageHost/{Engine, Input, System, UI,
Net, Transfer, Dictation, Parakeet, Updates}` (`Engine/` is capture, encode, audio and adaptive bitrate,
`System/` power, lock, restart and virtual display); VantageCore
`Sources/VantageCore/{Wire, Messages, Transport, Identity, ScreenSharing, Transfer}`.

The pbxproj is edited by hand: new targets need a `PBXNativeTarget`, build phases, config list,
product reference, and a `PBXFileSystemSynchronizedBuildFileExceptionSet` for any `Info.plist`
inside a synced folder (otherwise it lands in Copy Bundle Resources and the build fails with
"multiple commands produce Info.plist"). Extensions are embedded through the app's
"Embed Foundation Extensions" copy-files phase plus a target dependency.

Signing: `DEVELOPMENT_TEAM = 7BVMD7TA97` (Drew's paid team), automatic. Bundle ids: client
`me.drewlevinson.casement` (registered UNIVERSAL: App Groups, iCloud), host
`me.drewlevinson.casement.host`, widgets `me.drewlevinson.casement.widgets` (App Groups).
Swift 6, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY = YES`.

## Architecture

- **Transport**: one framed TCP stream per session over the tailnet (`MessageChannel`, an actor
  wrapping `NWConnection`). 8-byte header (magic, kind, flags, length) + payload. Control messages
  are JSON (kind < 100); hot-path video/cursor/input are hand-packed little-endian binary (kind ≥
  100). See `Packages/VantageCore/Sources/VantageCore/Wire` and `Messages`. `MessageChannel` reads
  with `minimumIncompleteLength: 1` and appends until a frame is whole; never ask `NWConnection`
  for a large minimum: on a Mac with a content filter (Little Snitch), non-loopback connections run
  through Network.framework's `ne_filter`, which silently dropped stream chunks whenever a receive
  waited for ≥ 16 KB (4K keyframes from a PC arrived with holes, then `badMagic`). Loopback and
  BSD sockets never showed it, so loopback tests can't catch it.
- **Host pipeline**: `ScreenCapture` (ScreenCaptureKit, `'420v'`, sRGB, dirty-rect ratio) →
  `VideoEncoder` (VideoToolbox low-latency, no reordering, event-driven IDRs, BT.709/sRGB colour
  tags) → `MessageChannel`. Incoming input goes to `InputInjector` (CGEvent, releases all held
  keys/buttons on disconnect). `VideoPacer` runs the path from captured frame to wire frames (one
  encode in flight, the latest frame wins, idle suppression, a keyframe request on a still screen
  re-encodes the last frame at once, the encoder's answer to every frame so a dropped frame can't
  freeze the picture) with `AdaptiveController`'s AIMD bitrate + text/motion fps from client
  feedback; `CaptureLifecycle` decides when capture starts, stops and retries (display sleep, the
  watchdog, the status the client hears). `HostSession` (actor) orchestrates one client through a
  `HostEnvironment` (real Mac or synthetic adapters, chosen once in `HostController`, which owns
  the listener); see Host environment and Capture lifecycle in `docs/guide/connection.md`.
- **Client pipeline**: `ClientSession` (handshake, reconnect with backoff) → `VideoStreamController`
  (`AVSampleBufferDisplayLayer.sampleBufferRenderer`, `DisplayImmediately`, flush + keyframe request
  on decode failure). `RemoteInteractionView` captures touch/trackpad/mouse/hardware-keyboard and
  forwards through `InputController`. SwiftUI shell: `DeviceListScreen`, `RemoteSessionScreen`,
  `ControlStrip`, Liquid Glass throughout.

## Topic guides

Each area's rules, gotchas, debug flags and tests live in its own guide under `docs/guide/`. Before
changing an area, read its guide; a change that spans areas reads each one.

| When the work touches | Read |
| --- | --- |
| Pairing, trust and the auth handshake, the Tailscale API sign-in, the virtual display, display sleep or a missing picture | [`connection.md`](docs/guide/connection.md) |
| The iPhone, iPad or Vision Pro client's UI: app lock, control strip, session menu, iPhone Duo, haptics, Siri and widgets, iCloud sync, visionOS, the iPad app on a Mac | [`client.md`](docs/guide/client.md) |
| Pointer, touch, trackpad, scrolling, keyboard, shortcuts sent to the host, typing a saved password, Screen Sharing sign-in, the local pointer | [`input.md`](docs/guide/input.md) |
| Anything the client does differently for a PC (`HostNoun`, `HostPlatform`, PC shortcuts, ⌘ as Ctrl) | [`pc-on-the-client.md`](docs/guide/pc-on-the-client.md) |
| Dictation, MacWhisper, Parakeet, Mac or PC audio | [`dictation-and-audio.md`](docs/guide/dictation-and-audio.md) |
| File transfer, the file channel, files-only sessions, files arriving on the Mac | [`files.md`](docs/guide/files.md) |
| Casement Host for Mac: its menu, setup window, Settings, Curtain (both hosts), updates, restarts, the lock screen and login window | [`mac-host.md`](docs/guide/mac-host.md) |
| The native Mac client (`Vantage/Mac/`, `#if os(macOS)`) | [`mac-client.md`](docs/guide/mac-client.md) |
| `WindowsHost/`, golden vectors, the interop tests | [`windows-host.md`](docs/guide/windows-host.md) |
| A release, a version bump, App Store Connect, the privacy manifest, the About links | [`releases.md`](docs/guide/releases.md) |
| Running a real or synthetic host, loopback end-to-end tests, Keychain experiments | [`testing.md`](docs/guide/testing.md) |

A change to any wire message updates the Swift and C# golden vectors together (see Golden vectors in
`windows-host.md`). When a change alters what a guide says, update that guide in the same change.

## Agent skills

### Issue tracker

Issues live in GitHub Issues for `dlev02/Casement`, via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five default triage labels (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`,
`wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `GLOSSARY.md` (the product's terms; use them in UI text, issues and names) and
`docs/adr/` (decisions to keep unless Drew reopens them) at the repo root. See `docs/agents/domain.md`.

The shared guide's test rule (prove a change by running it; add a test only for what is
mission-critical or easy to break silently) overrides `tdd` and the regression-test phase of
`diagnosing-bugs`.

## Distribution, policies, and the public repo

- **License**: GPL-3.0 (`LICENSE`), © 2026 Drew Levinson. `CONTRIBUTING.md` asks contributors to
  also let Drew ship their work through app stores, which is what keeps the App Store build
  possible under the GPL. Dependencies are GPL-compatible (FluidAudio Apache-2.0, Parakeet model
  CC BY 4.0, Sparkle MIT, NSec/Vortice/Windows Community Toolkit MIT, Concentus BSD-3-Clause; Inno Setup, used only to build the installer, its own permissive licence); check any new one.
- **Docs**: `README.md` (users first: features, platforms, first connection, building),
  `PRIVACY.md`, `TERMS.md`, `SECURITY.md` (private vulnerability reporting), `CONTRIBUTING.md`,
  `.github/` (issue forms, `FUNDING.yml`). The policies list every network destination (the
  user's own hosts, Screen Sharing on 5900, `api.tailscale.com`, Hugging Face for Parakeet, GitHub
  for host updates): a new
  destination or a new stored secret means updating `PRIVACY.md` and the FAQ's Privacy answers.
- **Never name Claude in the repository's history**: no `claude/…` branches (a merge commit then
  reads "from dlev02/claude/…"), no `Co-Authored-By` or "Generated with" lines, and no mention in
  commit messages, PR titles or PR descriptions, unless the change is itself an AI feature. This
  overrides any tool's default attribution, and delegated agents must be told. In that text, call this
  file "the project guide". The history was rewritten on 2026-11-05 to remove the mentions, so never
  push a branch made before then. Commit as `dlev <49005290+dlev02@users.noreply.github.com>`.
- **Nothing personal in tracked files**: never commit a real tailnet name, Tailscale IP, node or
  user ID, SSH user, or email, even in research notes or test fixtures. Use `tail1234.ts.net`,
  `100.64.0.x` / `fd7a:115c:a1e0::x`, and `you@your-pc`; scripts take such targets from the
  environment (`PC=… WindowsHost/scripts/push.sh`). The published history was rewritten on
  2026-09-30 to remove them; old local branches and agent worktrees still hold the originals, so
  never push those.

## Build & test

```
# Shared core (fast, no simulator)
xcrun swift test --package-path Packages/VantageCore

# Client session regression tests (actual source, loopback mock host)
xcrun swift test
# The root Package.swift lists client sources one by one; add new Model/Net files there or the
# test target won't see them.

# Host (macOS)
xcodebuild build -project Vantage.xcodeproj -scheme VantageHost -destination 'platform=macOS' -derivedDataPath .deriveddata

# Client (iOS Simulator)
xcodebuild build -project Vantage.xcodeproj -scheme Vantage -destination 'generic/platform=iOS Simulator' -derivedDataPath .deriveddata

# Client (visionOS Simulator; test on the "Vantage Vision Pro" simulator)
xcodebuild build -project Vantage.xcodeproj -scheme Vantage -destination 'generic/platform=visionOS Simulator' -derivedDataPath .deriveddata

# Client (macOS; same target, sandboxed, one window per session)
xcodebuild build -project Vantage.xcodeproj -scheme Vantage -destination 'platform=macOS' -derivedDataPath .deriveddata
```

CI (`.github/workflows/ci.yml`) runs `scripts/check.sh` on GitHub's `xcode-27` runner with Xcode 27.2,
unsigned (`check.sh` skips signing when `CI` is set), and the Windows host's tests on `windows-latest`.
`scripts/lint.sh` checks the rules a script can (personal details, AI mentions in commit messages,
pointer lock, `minimumIncompleteLength`, `tccutil`, `print`, …); `check.sh` and CI run it, and
`scripts/install-git-hooks.sh` (once per clone) runs it before each commit and push, which also refuses
`claude/…` branches and commits from before the history rewrites. Reviews judge a diff against
`CODING_STANDARDS.md`.

Reuse `.deriveddata`; do not create per-task DerivedData trees. Use regular Xcode 27, not Xcode-beta. Set `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` for shell builds and `xcrun swift` for tests. `scripts/check.sh` runs both test suites, the host build, and the iOS and macOS client builds, and compiles the Mac UI tests.

## Research

`docs/research/` holds the verified engineering reports that back these decisions (media pipeline,
input, Tailscale, virtual display, product/host lifecycle). They cite SDK headers and are the source
of truth for API specifics and gotchas. Read the relevant one before changing capture, encode,
decode, input, or Tailscale code.

## Known limitations

- The published Windows ARM64 packages (1.5, 1.6) probably won't start: they were published with
  `-p:Platform=x64`, so 44 native files, `Microsoft.ui.xaml.dll` among them, were x64. The script now passes the
  real platform and `check-package-arch.ps1` fails a release on the wrong kind of binary. ARM64 has
  still never run on ARM hardware.
- Curtain (2026-11-06) still needs hands and eyes: physical keys and mouse being dropped, ⌃⌥⌘L and
  Windows-L, the guard's lock path, click-through on Windows, and what the PC's panel shows. No real
  iPad has connected with it yet.

- Virtual-display provisioning is wired but falls back to the main display if BetterDisplay's CLI
  isn't available. Real Mac video, pointer, clicks and software-keyboard typing are verified on a
  physical iPad; BetterDisplay and biometric session recovery still need device checks (the
  topic guides name what else does).
- Windows host (1.3, 2026-11-04): a saved password can't be typed at the Windows lock screen (the
  secure desktop is reachable only from a SYSTEM service, a separate decision). HEVC, the PC's
  sound, display fitting and the restart guard were checked on Drew-PC with the console host and a
  throwaway client, not yet from a real iPad or through a real restart; the transfer UI was only
  compiled.
