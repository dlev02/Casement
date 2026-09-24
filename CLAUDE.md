# Vantage — agent guide

Vantage is a native Apple remote-desktop app: an iPadOS client controls a macOS host over
Tailscale only. It is a personal, Screens-5-style alternative for Drew, macOS-first. The Xcode
project is `Vantage.xcodeproj` (hand-maintained pbxproj, objectVersion 77, file-system-synchronized
groups). Read this before working here.

## Targets and layout

| Target | Path | Product |
| --- | --- | --- |
| `VantageHost` | `VantageHost/` | macOS 26+ menu-bar app (LSUIElement), unsandboxed, Developer ID intended |
| `Vantage` | `Vantage/` | iPadOS/iOS 26+ client (universal), also native visionOS 26+ and macOS 26+ (`SDKROOT = auto`; sandbox entitlements from `ENABLE_*[sdk=macosx*]` build settings) |
| `VantageCore` | `Packages/VantageCore/` | Local SPM package shared by both: wire protocol, transport, identity |
| `VantageWidgets` | `VantageWidgets/` | iOS widget extension (WidgetKit + App Intents), embedded in `Vantage` on iOS only (`platformFilters = (ios, )` on the embed file and dependency) |
| — | `Shared/` | Synced folder compiled into both `Vantage` and `VantageWidgets`: `DeviceCatalog`, `MacEntity`, widget views |

The pbxproj is edited by hand: new targets need a `PBXNativeTarget`, build phases, config list,
product reference, and a `PBXFileSystemSynchronizedBuildFileExceptionSet` for any `Info.plist`
inside a synced folder (otherwise it lands in Copy Bundle Resources and the build fails with
"multiple commands produce Info.plist"). Extensions are embedded through the app's
"Embed Foundation Extensions" copy-files phase plus a target dependency.

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
  The host names its OS in `Challenge.hostPlatform` and `HostCapabilities.platform` (`HostPlatform`,
  a string wrapper: `macos`, `windows`, unknown values still decode; nil from older hosts means a
  Mac). The client keeps it as `ClientSession.hostPlatform` (from the challenge, then the
  capabilities) and `HostAvailabilityStore.platforms`. DEBUG host `--platform windows|macos`
  overrides what it sends, to try the client against a pretend PC.
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
  Keychain. `TailscaleAccountScreen` offers the two key kinds as separate pages (`TailscaleOAuthSetup`, `TailscaleTokenSetup`); the fixture also accepts any key there so sign-in can be exercised. `TailscaleDevicesSheet` lists Macs (probed with `HostAvailabilityProbe`) and greys out
  other platforms. Debug flags: `-VantageTailscaleFixture 1` serves a fictional tailnet,
  `-VantageOpenTailscaleDevices 1` opens the picker on launch,
  `-VantageOpenScreen settings|controls|security|help|about|tailscale|tailscaleOAuth|tailscaleToken|addDevice|controlStrip|controlStripMac|transfers` presents one
  screen as a sheet for screenshots (AXe taps don't reach this app in the simulator; swipes do;
  `controlStripMac` edits the first saved Mac, so pair it with `-VantageSeedSamples 1`).
- **App lock** (Face ID, Settings → Privacy & Security): on iOS the view tree stays alive while
  locked and `LockCurtain` (in `ContentView.swift`) raises an opaque window above every sheet and
  cover. Never go back to swapping the root view for the lock screen: that dismissed open sheets
  and threw away half-typed input whenever the user switched apps (e.g. copying a Tailscale
  secret from Safari on iPhone). visionOS still swaps views.
- **Control strip motion** (`ControlStrip`, `ToolbarPlacement` in `SessionPreferences.swift`): the
  pill and the full strip share one glass surface that resizes; don't go back to two
  `glassEffectID` shapes, which swapped in a single frame instead of morphing. Dragging uses
  plain `@State` offset settled in the same spring as the corner change; the corner is the
  quadrant the strip's centre is thrown into, with a mostly-horizontal (or vertical) throw
  moving only along that axis. The strip moves with the finger, so a drag started on a button
  would also "tap" it on release: every strip button goes through `StripTapGuard`, and the mic
  cancels the dictation it began once the finger travels. Covered by `ToolbarDockTests` and
  `SessionUITests.testToolbarThrowsLandInTheIntendedCorner`.
- **Control strip layout** (`ControlStripLayout.swift`, `ControlStripEditor.swift`): the strip
  renders a `ControlStripLayout` (ordered `StripItem`s; each case carries label, symbol, detail,
  category) followed by the always-present session menu and collapse button. Separators go
  wherever the category changes; narrow widths wrap via `ViewThatFits` into 2–5 rows cut at those
  boundaries (`ControlStripLayout.rows`, most even split). The pill shows Dictate/Keyboard only if
  the layout has them. Default layout: `@AppStorage("vantage.controlStrip")` (JSON array via
  `RawRepresentable`); per Mac: `SavedDevice.controlStrip` (nil = default), set through
  `DeviceStore.setControlStrip`, which bumps `updatedAt` so it syncs with the list. Decoding drops
  unknown raw values and repeats, so a new case needs only its `StripItem` rows and a button in
  `ControlStrip.itemView`. The editor (live scaled preview, reorder, add/remove, reset) opens from
  Settings → Controls → Customize Controls (default), the Edit Device sheet's Controls row (saved
  with the sheet), and the session menu's Customize Controls… (writes the store live; the strip
  behind follows). Disconnect (`session.toolbar.disconnect`) is a standard item: immediate, no
  confirmation. VoiceOver reads an editor row as the control's name (label) and what it sends
  (value): the system reorder handle is named after the row's label ("Reorder Escape"), so a
  description folded into the label made it "Reorder Escape, Esc key" on iOS 27. Tests:
  `ControlStripLayoutTests`, `SessionUITests.testDisconnectButtonReturnsToDeviceList`,
  `testCustomizeControlsFromTheSession`, `testControlStripEditorScreens`.
- **Software keyboard**: `SoftwareKeyboardMode` (Unicode Text or Keystrokes). Keystrokes maps
  characters through `CharacterKeyMap` (US layout) to real key events; unmapped characters fall
  back to Unicode text. Held ⌘/⌥/⌃ from the control strip always route through keystrokes.
- **Input routing** (`RemoteInteractionView`): finger and Pencil gestures go through gesture
  recognizers restricted by `allowedTouchTypes`; trackpad/mouse input goes through
  `touchesBegan/Moved/Ended`, diffing `UIEvent.buttonMask` so right- and middle-button drags work.
  Indirect pointers and the Pencil always position absolutely regardless of the touch mode; the
  touch mode only governs fingers. Wheel/trackpad scrolling uses two dedicated pan recognizers
  (continuous vs discrete) — never put `allowedScrollTypesMask` back on the movement pan, it turns
  scrolling into pointer motion. Pencil squeeze/double-tap map to `PencilAction` (Settings → Controls).
  **Edges**: every absolute position goes through `PointerMapping` (pure, `PointerMappingTests`):
  past or within `edgeSnap` (2 pt) of the picture's edge lands on the Mac's outermost row/column,
  and an edge position within `cornerSnap` (16 pt) of a corner lands in the corner. macOS reveals
  a hidden Dock/menu bar or fires a hot corner only there (one move onto the bottom row shows the
  Dock in ~0.16 s; 3 pt short never does — `LiveDockEdgeTests`, opt-in, real host), and the iPad
  pointer stops 1 pt short of the screen edge. The hover handler uses only `.began`/`.changed`:
  iPadOS ends the hover when the pointer leaves the view or is pushed into a screen edge (it takes
  it for its own Dock/menu bar), and the end reports (0, 0) — following it threw the Mac's pointer
  to the top-left, which is why a Bluetooth mouse couldn't show the Dock. The mapping is computed
  from `InputController.viewSize` + `displayPointSize` on every use (a rect stored at layout time
  kept the default display's shape). Cancelled pans/long presses release in place. UI test:
  `PointerEdgeUITests` (`hover()` to each edge; `-VantagePointerProbe 1` exposes the last Mac
  position as `session.pointerProbe`'s value). **Pointer lock is off on purpose**: the session's
  SwiftUI presentation controller never consults a child's `prefersPointerLocked`
  (`childViewControllerForPointerLock` is nil), so locking would mean presenting the session from
  UIKit; it also needs `GCMouse` deltas the simulator can't produce and a full-screen scene. Don't
  add `prefersPointerLocked = true` back: if SwiftUI ever honoured it, UIKit hover stops and no
  mouse would move the Mac's pointer.
- **Haptics** (`Model/Haptic.swift` names the moments, `UI/Haptics.swift` plays them; iPhone
  only): call sites name what happened, never how it feels — `.latch`/`.unlatch` (a sticky
  modifier you tapped; one a key press clears stays quiet), `.start`/`.stop` (dictation's mic),
  `.snap` (the strip lands in a corner), `.press` (a long press grabs or clicks), `.secondaryClick`
  (two/three-finger tap), `.success`/`.warning`/`.error` (outcomes out of sight: reconnected, a
  dropped session via `ConnectionHaptics`, password typed through Screen Sharing, rejected
  pairing code, dictation failed). In a view use `.haptic(_:trigger:)` or `.haptic(trigger:) { old,
  new in Haptic? }` (SwiftUI `sensoryFeedback`); from a callback `Haptics.play(_:)` (e.g. a file
  received or sent: `Haptics.play(.success)`, a transfer failing: `.error`); from a UIKit view
  `ViewHaptics` (location-aware, `prepare()` on touch down). Never for pointer motion, scrolling,
  typing, plain taps/clicks, or real mouse/trackpad clicks. Settings → Controls → Haptics
  (`vantage.haptics`, on by default, shown on iPhone only); iPhone's System Haptics switch still
  wins. iPad has no Taptic Engine: the modifiers add nothing and no generators are made there;
  visionOS compiles them out. Debug: `-VantageForceHaptics 1` treats an iPad as capable,
  `-VantageHapticProbe 1` lists what played as `session.hapticProbe`'s value. Tests:
  `HapticTests` (connection rules), `HapticsUITests` (its synthetic host must not run
  `--send-file-on-connect`: a file arriving plays `.success`). Feel still needs an iPhone.
- **Mac shortcuts and password**: `MacShortcut` (`Vantage/Model/MacShortcut.swift`) sends
  system-default chords (⌘Space, ⌃↑, ⌃↓, F11). The host posts keys the way a Mac keyboard does
  (`KeyboardSequencer`): a chord's modifiers go down first as their own flagsChanged keys (with
  the left/right device bit) and come up after the key, and arrow/function/navigation keys carry
  Fn (arrows and the keypad also the keypad bit). macOS stores its shortcuts with those bits
  (`com.apple.symbolichotkeys` 32/33 = ⌃↑/⌃↓ with Fn, 0x840000; 36 = F11 with Fn): without them
  Mission Control, App Exposé and Show Desktop never fired. Never drop the Fn bits; the client
  also sends `.function` on those shortcuts for older hosts. ⌘Space: Spotlight's hot key and
  Carbon hot keys (Alfred and co.) answer injected keys, but Raycast only answers a physical
  keyboard (session tap, HID tap, HID-state source, device bits and human timing all fail; it runs
  a HID-level tap plus its own IOHID listener), so while Spotlight's shortcut (hot key 64) is off and
  Raycast is running the host opens `raycast://` instead (`SearchShortcut`). That's a heuristic:
  Raycast keeps its hotkey out of readable defaults (only `initialSpotlightHotkey`), so if something
  else ever owns ⌘Space while Spotlight's is off and Raycast runs, the button still opens Raycast. Keys stay on
  `.cgSessionEventTap`: a HID-tap post buys nothing and runs through every other app's HID tap.
  `--log-input-events` (DEBUG host) logs each key event reaching the session with its flags
  (listen-only tap; text keys typed on the Mac itself are logged without a key code). Tests:
  `HostInputTests` (in `xcrun swift test`), `MacShortcutTests`.
  `DeviceSecrets` keeps one Mac password (and optional account name) per saved-device UUID in the
  Keychain (when-unlocked class); the key button types it plus Return through the host. When
  `HostStatus` reports Secure Event Input or a locked screen, it instead signs in to the Mac's own
  Screen Sharing (`ScreenSharingTyper` in VantageCore: RFB 3.889, ARD auth type 30 — DH with a
  256-bit exponent over the server's 4096-bit prime, MD5, AES-128-ECB — then KeyEvents only, no
  framebuffer) directly at `<device.host>:5900` and types there; screensharingd is exempt from
  Secure Input. Shifted characters get an explicit Shift_L. The live handshake test is opt-in:
  `VANTAGE_LIVE_SCREEN_SHARING=1 xcrun swift test --package-path Packages/VantageCore` (a bogus
  account, expects a clean rejection). A real sign-in still needs a device check.
- **Display sleep** (`PowerManager`/`DisplayPower`, `LockMonitor`, `HostSession`): while the
  display sleeps, ScreenCaptureKit lists no displays and stops any stream (SCStreamError -3815,
  "Failed to find any displays or windows to capture"). Never end a session because capture
  can't start (that was the reconnect loop): capture waits, `HostStatus.isDisplayAsleep` (optional;
  nil from older hosts) tells the client, and capture restarts with a keyframe when the display
  wakes (NSWorkspace screensDid*, a 1 s poll, the controller's restart; one start at a time). The
  injector, power assertion, and status monitor live for the session, not the capture. Connecting
  wakes a sleeping display before listing displays; input while asleep wakes it (≤ 1/s) instead
  of being delivered (releases still are), except for 2 s after Sleep Display; the Wake command
  always wakes. Waking is `IOPMAssertionDeclareUserActivity(kIOPMUserActiveLocal)` re-using one
  assertion id (Remote lights the display on macOS 27 too; a fresh id per call leaked an assertion
  every time). On Drew's Mac display sleep also posts `com.apple.screenIsLocked` + Secure Input
  even with screen lock off; both clear on wake. **Awake but no picture** (capture won't start;
  once seen after a wake, when SCK listed no displays for 10+ s): a watchdog in `HostSession`
  retries (0.5 s doubling to 5 s) for the whole session, logs every attempt as "capture
  unavailable for N s: <reason>; <panel state>; trying again" (category `session`), re-declares
  local activity when CGDisplayIsAsleep or an empty active-display list says the panel is off
  (IOKit has no display power state on Apple silicon), treats a started capture with no frame in
  5 s as failed, and after 3 s sets `HostStatus.isScreenUnavailable` (optional), cleared on the
  first frame back. Wake doubles as Retry (restarts capture at once). Client: `MacScreenNote`
  (last frame dimmed, glass note, Wake/Retry button, tap anywhere) shows "The Mac's display is
  asleep" or "Waiting for the Mac's screen…", never a frozen frame without a word; the lock
  banner hides only while asleep. `ClientSession`
  resets its reconnect backoff only once the host answers the stream request or the connection
  lasted 10 s, and idle video never triggers a reconnect. Debug: host `--display-asleep` (a
  pretend display that starts asleep; sleep/wake commands work on synthetic hosts too) and
  `--capture-fails-for <s>` (each session's capture fails that long from its first stream
  request). Tests: `DisplaySleepSessionTests`, `HostStatusTests` (VantageCore),
  `SessionUITests.testSleepDisplayShowsAsleepStateAndWakes` (synthetic host with
  `--display-asleep`; `TEST_RUNNER_VANTAGE_SYNTHETIC_HOST=127.0.0.1:<port>` and
  `TEST_RUNNER_VANTAGE_TEXT_SIZE=<content size category>` override the defaults),
  `testMissingPictureIsExplainedUntilFramesReturn` (synthetic host with `--capture-fails-for 6`,
  default 127.0.0.1:47822, `TEST_RUNNER_VANTAGE_UNAVAILABLE_HOST` overrides).
- **Siri / Shortcuts / Spotlight / widgets**: `ConnectToMacIntent` (+ `VantageShortcuts` phrases
  like "Connect to ⟨Mac⟩ in Vantage") runs in-app and drops the id into `PendingConnection`;
  `ContentView` opens the session once the app is unlocked. Widgets tap through
  `vantage://connect/<uuid>` (URL scheme declared in `Vantage/Info.plist`, merged into the
  generated plist). Both read `DeviceCatalog`, a small JSON the store rewrites on every save
  (`Application Support/Vantage/catalog.json`, plus the App Group container
  `group.com.benjaminlevinson.vantage` when the entitlement exists). A personal team can't sign
  App Groups, so on Drew's sideloads the widget shows "No Macs yet" until the paid team adds the
  capability to both targets; the simulator ignores the entitlement, so verify widgets there with
  `-VantageOpenScreen widgets` (renders every family from the live catalog).
- **iCloud sync** (`CloudSync`): secrets flip between local and `kSecAttrSynchronizable` Keychain
  stores (`KeychainStore(synchronizable:)`), no entitlement needed. The device list goes through
  `NSUbiquitousKeyValueStore` with `updatedAt` last-writer-wins and tombstones, but only when the
  embedded provisioning profile carries `com.apple.developer.ubiquity-kvstore-identifier` — a
  personal team can't sign for it, so the capability is deliberately not in the project yet. Add
  the iCloud Key-Value Storage capability once a paid team is active and the list half turns on
  by itself.
- **Dictation** (`Vantage/Dictation`, `VantageHost/Dictation`, design in
  `docs/research/audio-dictation-files.md` §B/§D): the strip's mic button (hold to talk, tap to
  toggle) opens `DictationPanel`. "On this iPad" runs `SpeechAnalyzer` (`LiveTranscriber`,
  downloads the locale model via `AssetInventory`); "On the Mac (MacWhisper)" streams 16 kHz PCM16
  as `micAudio` (123) between `dictationControl` (64) begin/commit, and the host writes a temp WAV,
  runs `mw transcribe --language xx`, deletes the WAV, and answers `dictationResult` (74), falling
  back to macOS SpeechAnalyzer. All three kinds are capability-gated: the client says
  `Hello.features.dictation`, the host lists `HostCapabilities.dictationEngines`, and the client
  uses the Mac only when that list contains `macwhisper` (older hosts drop the session on unknown
  kinds). Text is typed through `textInput`. Never log transcripts except `.private`.
  **Startup**: the Mac route sends `begin` and opens the mic as soon as mic permission is known;
  the on-iPad preview prepares alongside and attaches when ready, fed from the 16 kHz uplink with
  the audio so far replayed. Never make the Mac route wait for `LiveTranscriber.make` again: its
  first call per launch can take many seconds on a device (the old 20 s "Getting ready…"). `make`
  shares one in-flight preparation per locale, and a cancelled attempt leaves its transcriber as a
  spare. Stage timings log as "dictation start (…)" and "speech transcriber …" (category
  `dictation`). **Clip end**: the mic stays open `captureTail` (400 ms) after stop while the panel
  already says Transcribing; `MicrophoneCapture.stop()` drains the `AudioResampler`s with
  end-of-stream (a 48→16 kHz converter holds ~30 ms); the host appends 0.5 s of silence before any
  engine (`HostTranscriber.paddedForTranscription`). Tests:
  `Tests/HostDictationTests` (stub `mw`; `VANTAGE_TEST_REAL_MW=1` runs real MacWhisper and Apple on
  `say` speech).
  **Built-in Parakeet** (optional, off by default): Vantage Host → Settings → Dictation toggles
  `ParakeetModel` (`VantageHost/Parakeet`, FluidAudio 0.16.x, Parakeet TDT v3 on Core ML; the
  package is linked into the host target only). Turning it on downloads ~490 MB to
  `~/Library/Application Support/Vantage Host/Models/parakeet-tdt-0.6b-v3` (Remove deletes it and
  the ~40 MB Core ML cache); nothing touches the network while it's off, and loading uses
  `AsrModels.loadLocal`. The host advertises `parakeet` only while it's on and downloaded
  (`BuiltInSpeechEngines.shared`), warms it at launch/after download (first-ever load compiles
  for the ANE, ~18 s; later ~0.4 s), and a clip that arrives mid-warm-up waits ≤20 s, then falls
  back. Engine order: the client's `DictationControl.engine`, then MacWhisper → Parakeet → Apple;
  the result names the engine and the panel labels it. Client: "On the Mac (Parakeet)" appears in
  Settings → Controls once a Mac has advertised it. `ParakeetRuntime` sits behind
  `BuiltInSpeechEngine`, which the SPM host tests stub (the root package never builds FluidAudio).
  `--open-settings dictation` (DEBUG) opens the host's Settings in a window for screenshots. Debug: `-VantageDictationFixture listening|review|macTranscribing|macReview|failed|download`
  shows the panel without the mic; `-VantageDictationSpeak "text"` sends TTS audio through the whole
  Mac path in the simulator (synthetic hosts advertise engines too, but never type).
- **Mac audio** (design in `docs/research/audio-dictation-files.md` §A/§D): host `AudioCapture`
  (its own SCK stream, not the video one, so resizes don't drop it; audio only, 2×2 video to a
  no-op `.screen` output, own process excluded) → `AudioRepacketizer` (fixed 480-frame/10 ms
  blocks; a timestamp jump starts a new timeline) → `AudioEncoder` (Opus via `AVAudioConverter`,
  `mFramesPerPacket` 480, 128 kbps, own serial queue) → `sendDetached`. Kinds: `audioRequest` (63,
  c→h), `audioConfig` (73, h→c; `unavailable` carries a user-facing reason), `audioPacket` (102,
  `seq u64 | captureNanos u64 | frameCount u16 | opus`). Gated both ways: the client sends
  `audioRequest` only when `HostCapabilities.audio == true`, the host answers only a client with
  `Hello.features.macAudio`, and audio is off until asked. Client: `ClientSession.setMacAudio`
  (re-asks on every reconnect) → `MacAudioPlayer` (decode queue → `AudioJitterBuffer`, a lock-free
  SPSC ring pulled by an `AVAudioSourceNode`; target 40–80 ms, +10 ms per late underrun, −4 ms per
  10 s clean; a host pause (timeline jump) isn't counted; one-frame stretch/squeeze outside target
  ±15 ms; bursts > target+90 ms cut back with a crossfade (a skip); a backlog that size found
  before playback starts begins at the target instead (`startTrims`); fades on dry-out). `.playback` +
  `.mixWithOthers`; `DictationController.onMicrophoneActive` pauses output before the mic takes
  `.playAndRecord` and resumes after it lets go. `AudioOutputSetup` activates (and deactivates) the
  session and starts the engine on its own queue; never move that back onto the main actor: every packet
  reaches the player through it, so the 100–200 ms start queued the Mac's first audio into a
  burst that landed just after playback began and was cut back with an audible skip. A stop
  during a start, and the mic taking over, wait for that queue, so the session never changes
  under the mic. Per Mac: `SavedDevice.playMacAudio`
  (`DeviceStore.setPlayMacAudio`); strip item `macAudio` + session-menu toggle; a failure shows
  `MacAudioNotice` and the toggle retries. `ControlStripLayout.upgradeSavedLayouts` moves layouts
  saved as an older standard (the editor saves the full list even on Reset) to the new one once;
  add to `standardHistory` whenever the standard gains a control. Stats log every 10 s (`audio`
  category, both sides). Debug: `-VantageMacAudio 1|0` overrides the saved choice and adds an
  invisible `session.macAudioStats` element (`latency` is the smoothed depth the buffer steers
  by) for `SessionUITests.testMacAudioToggleStreamsTheMacsSound`;
  the synthetic host streams a −18 dBFS two-note chime (`SyntheticAudioSource`). Some simulators
  can't reach CoreAudio ("there is no system object", engine start −10851); DEBUG simulator builds
  then play into `NullAudioOutput` so the rest of the path still runs. Out of scope on purpose:
  muting the Mac (needs a Core Audio process tap and its own TCC prompt), background audio (a
  separate decision: `UIBackgroundModes` audio would keep the session alive and has App Review
  implications), and UDP. Still needs hardware: real SCK audio, AirPods, drift over hours.

- **File transfer** (design in `docs/research/audio-dictation-files.md` §C/§D; no Taildrop, no
  Blip): a second TCP connection per session, the **file channel**. A client with
  `Hello.features.fileTransfer` gets a 32-byte `AuthResult.sessionToken` and
  `HostCapabilities.fileTransfer`; it opens connection #2 to the same host/port
  (`VantageNetwork.bulkParameters()`, `.background` service class) and sends `attachMedia{token}`
  first. `HostController.accept` reads every connection's first message: `hello` starts a
  `HostSession`, `attachMedia` goes through `AttachTokenRegistry` (VantageCore: constant-time
  compare, single use, same peer address, 60 s, revoked when the session ends) to
  `HostSession.attachFileChannel`; anything else is closed. **Files outlive the screen**: a
  host that says `HostCapabilities.filesOnlySessions` hands the attached channel to
  `HostController` (`fileChannels`), keeps it after its session ends (`HostFileChannel.sessionEnded`),
  and closes it only when the iPad does, when that iPad's key is revoked, or after 2 min with
  nothing moving (`detachedIdleLimit`). It also takes **files-only sessions**
  (`Hello.features.filesOnly` + `fileTransfer`): authenticate (pairing still required, no pairing
  code sent, no Screen Recording check, no whois), token, then `filesOnlyLoop` answers pings and
  ignores everything else, so no displays, capture, input, audio, clipboard, lock monitor, or
  power assertion ever start. They live in `HostController.fileSessions`, outside `status` and the
  restart guard. Kinds (file channel only): `fileOffer`
  80, `fileAccept` 81 (`resumeOffset`, or `rejected`), `fileComplete` 82 (SHA-256),
  `fileResult` 83, `fileCancel` 84, `fileChunkToClient` 103 / `fileChunkToHost` 124
  (`id 16 B | offset u64 | bytes`, 256 KiB). Both ends run `FileTransferEngine` (VantageCore): one
  send at a time per direction (FIFO), 4 chunks in flight through `MessageChannel.send(_:completion:)`,
  incremental SHA-256 on both sides, receives into a hidden `.vantage-<id>.partial` renamed to a
  Finder-style unique name (`FileNames.sanitize`/`uniqueURL`: last path component only, no
  control/bidi characters or leading dots, ≤ 200 UTF-8 bytes); the file channel uses
  `maxBufferedMessages` 64 so a slow disk pushes back through TCP; the receive loop sends its answers
  (accept, result) without waiting on the connection (`reply`, `sendDetached`), so two big files
  crossing never leave both loops waiting on full pipes. **Resume**: a lost connection
  keeps the receiver's partial; the sender re-offers the same `id` and the receiver answers
  `resumeOffset` = the partial's size after re-hashing it (a SHA-256 state can't be saved), the
  sender hashes that prefix from disk and streams the rest; both hashes run off the actor
  (`FileTransferEngine.hashPrefix`). Size and hash still gate the rename; a mismatch deletes the
  partial and the next attempt starts at 0. Cancels delete partials; untouched ones go after 24 h
  (`partialLifetime`). A new channel from the same sender takes over a partial an old, half-open
  channel still holds (`PartialClaims`). Old peers answer 0, which always worked. The client
  re-offers a cut-off send up to 10 times (`FileTransferController.maxInterruptions`) and shows it
  Paused meanwhile; a receive cut off waits an hour for the Mac to re-offer it. The host re-sends
  its interrupted sends when the same iPad (`HostFileChannel.clientKey`, the key fingerprint)
  attaches again within an hour (`HostTransfer.interruptedAt`/`resumeWindow`), and doesn't
  report a cut-off file as failed meanwhile: the menu row says "Paused at 45% · resumes when ⟨iPad⟩
  reconnects" (`HostTransferRow.detail`), the menu bar ring leaves it out (`StatusItemIcon.moving`),
  and its Finder/Dock progress is withdrawn (`FileArrivals.paused`) until `started` republishes it.
  A paused receive remembers its partial's folder (`ResumeFolders`, fed to the engine as
  `FileTransferConfiguration.partialDirectory`), so it resumes and is saved there even if
  Settings → Files changed the folder in between (`resumedPartialKeepsItsFolder`). One that
  never comes back fails after the hour like any other failure. Logs: "resuming a send/receive at N of M bytes
  (hashed … in X ms)". Host: `~/Downloads`
  (`NSDownloadsFolderUsageDescription`; macOS asks once), `com.apple.quarantine` set per file via
  `URLResourceValues.quarantineProperties` (not `LSFileQuarantineEnabled`, which would also
  quarantine dictation WAVs and the Parakeet model), what happens on arrival (next bullet), menu
  Files section with "Send File to ⟨iPad⟩…" (`NSOpenPanel`), progress and cancel. The iPad's name
  comes from `tailscale whois` (iOS only reports "iPad"). Synthetic hosts save to
  `$TMPDIR/VantageSynthetic/Received` and skip the arrival path. Client: transfers
  belong to the Mac, not the session: `FileTransferCenter.shared` keeps one `FileLink` per saved
  device (the session, the device list, and visionOS windows share it). A link carries a
  `FileTransferController` (`session.files`; queued files wait, one cut off by a drop resumes;
  `summary` sums up the current run of files; a send is settled by the task that sent it, and the
  engine's event stream can reach the controller later, so a start or progress for a send that
  isn't moving any more is ignored, `lateEventsDontReviveAFinishedSend`) and the channel: the screen session's token while
  one is connected (`screenDidConnect`/`screenDidDrop`/`screenDidEnd`), else a files-only session of
  its own (`FilesOnlySession.open`, primary kept open beside the channel) whenever work is queued
  or the channel drops under a screen; it closes 30 s after nothing is moving and no screen is up
  (`idleTimeout`), retries with backoff (16 tries, then the files fail with a reason). An older Mac
  (no `filesOnlySessions`) keeps the old rule: the channel goes with the screen, which reconnects
  both, and files queued without a screen fail with "Update Vantage Host…". Files land in
  `Documents/Received` (`UIFileSharingEnabled` +
  `LSSupportsOpeningDocumentsInPlace`: Files › On My iPad › Vantage). Entry points: strip item
  `sendFile` (standard, before Mac Audio; a hairline ring shows progress; dimmed on older hosts;
  long-press for Send Files… / Transfers…), session menu "Send File to Mac…" / "Transfers…"
  (always there), **`TransferCapsule`** (`TransferProgressViews.swift`): a glass capsule that appears
  by itself in the session as soon as a run of files starts ("Report.pdf" / "Sending 3 of 12",
  percent, what's left, time; tap → Transfers), turns into a checkmark (or "2 of 3 files moved")
  when the run ends, and leaves after 2.6 s (8 s with VoiceOver); a run of only received files
  leaves that to `ReceivedFileNotice`. It sits on the edge away from the strip (top while the
  strip docks at the bottom or is hidden, bottom while it docks at the top; top on visionOS), and
  keeps one identity through the done state (`shown` in state) so it morphs instead of swapping;
  Reduce Motion gets opacity only. VoiceOver hears one announcement per run, not per file. Drop
  onto the Mac's screen (`FileDropDelegate`,
  copies out of the drag into `tmp/Outbox`, "Drop to send to ⟨Mac⟩" hint), `ReceivedFileNotice`
  (Show / Share), `TransfersView` sheet (a run of several files gets a summary on top: "4 of 7
  files", one bar, "40% · 4.16 GB left · 2 min", and Cancel All with a confirmation; rows wrap
  instead of truncating at accessibility text sizes), **without the screen** from the device list: the Mac's
  context menu (and a VoiceOver action) "Send Files…" opens the Files picker for that Mac, and
  files dropped on its row or card go to it (accent "Drop to send" hint), both over a files-only
  session; and "Open in Vantage" from other apps (`CFBundleDocumentTypes`
  public.data/public.content, rank Alternate → `onOpenURL` → `SharedFileInbox` copies it out,
  then the open session queues it, or it goes files-only to the most recent Mac, whose row shows
  it; a Mac known to predate files-only sessions is opened instead; waits for Face ID). Disconnect never asks on a current Mac: the screen goes and the
  files keep moving; the device list then shows them on the Mac's row/card
  (`DeviceTransferBadge`, "Sending 3 of 12 · 45% · 2 min", tap → Transfers; also the context menu's
  Transfers…). Only an older Mac, which would stop them, gets "Files are still transferring.
  Disconnect anyway?". **In the background** (iOS; `TransferBackgroundActivity`): a run of files
  that starts in the foreground and is ≥ 32 MB or > 20 files submits one `BGContinuedProcessingTask`
  (`com.benjaminlevinson.vantage.transfers.<UUID>`, registered just before submitting on the main
  queue, wildcard in `BGTaskSchedulerPermittedIdentifiers`, `.queue` strategy; no background mode
  needed) that reports every Mac's run (`FileTransferCenter.overallSummary`) as bytes plus a
  title/subtitle ("Sending files to ⟨Mac⟩", "3 of 12 · 2 GB left · 4 min") and completes when the
  run ends. Expiry (the system, or the person stopping it in the Live Activity) pauses every link
  cleanly (`FileLink.pause`: channel closed, partials kept). Where the task isn't available (the
  simulator says "BGTaskScheduler is not available on this platform", Background App Refresh off,
  visionOS) backgrounding takes the ordinary `beginBackgroundTask` grace (~25–30 s), then the same
  pause. Returning to the foreground retries everything (`appDidBecomeActive` →
  `FileTransferCenter.retryAll`), which resumes from the partials. Checked in the simulator: 100 MB
  kept moving ~25 s after the app left, paused at 40.6 MB, and resumed there on return ("resuming a
  send at 40632320 … hashed the start in 24 ms"); the real continued-processing task and its Live
  Activity need a device. **Haptics** (iPhone, foreground; `Haptics.play`): each link's
  `FileTransferController.onFeedback` goes through `FileTransferCenter.onFeedback` (set in
  `ContentView`), so they play from the device list too: `.success` for a file received and once
  when a run of sends all went, `.error` for a real failure, never for a pause that will resume;
  the same one twice within a second plays once (`feedbackQuietPeriod`). Debug:
  `-VantageSendTestFile <bytes>` queues random bytes once the channel is up (without
  `-VantageAutoConnect`, on the first saved Mac from the device list, as if picked with Send
  Files…), `-VantageAutoConnect` opens its session once per launch, `-VantageSlowFiles <ms>`
  pauses before each chunk the app sends (`FileTransferConfiguration.chunkDelay`; keep it in the
  seconds for UI tests, since XCUITest waits for an idle app and steady progress never is), `-VantageDropHint 1`
  shows the hint, `-VantageOpenScreen transfers` shows the sheet with fixture rows, host
  `--send-file-on-connect <path>` sends a file to each client that attaches. Tests:
  `FileTransferTests` (VantageCore), `FileTransferSessionTests` (loopback `ClientSession` + mock
  host), `SessionUITests.testFilesMoveBothWays` (needs the synthetic host started with
  `--send-file-on-connect`), `testDisconnectKeepsFilesMovingAndTheListShowsThem`,
  `testSendFilesFromTheDeviceList`, `testTransferCapsuleAppearsOnItsOwn` (both docks; set
  `TEST_RUNNER_VANTAGE_UI_APPEARANCE=dark` / `TEST_RUNNER_VANTAGE_UI_TEXT_SIZE=UICTContentSizeCategoryAccessibilityL`
  for screenshots), `testDropHint`,
  `testTransfersSheetScreens`; resume in `FileTransferTests` (`interruptedFileResumesOnANewConnection`
  both ways, `resumedFileThatDoesntMatchIsRefusedThenSentWhole`, `newChannelTakesOverAPartialFromAStaleOne`)
  and `FileTransferSessionTests.interruptedUploadResumesWhereItStopped`; without the screen in
  `FileTransferSessionTests` (`transferKeepsGoingAfterTheSessionEnds`,
  `sendsFilesWithoutOpeningTheScreen`, `droppedFileChannelComesBackWithoutTheScreen`,
  `olderMacExplainsItNeedsTheScreenForFiles`, `olderMacsFileChannelEndsWithTheSession`,
  `filesOnlyNeedsAPairedMac`); long queues in `longQueueKeepsMovingWithFlatMemory` (1,500 files,
  one missing before its turn fails alone, footprint printed; 14 → 15 MiB here). **Many files**:
  a queue holds one small `Transfer` + `Source` per file; Files-picker URLs are opened
  (`startAccessingSecurityScopedResource`) only to read the size and again only while that file
  is sent, so thousands of picks never hold thousands of sandbox extensions; the next send is
  found from `nextSendHint` instead of rescanning the queue. UI tests take `TEST_RUNNER_VANTAGE_TEST_HOST=127.0.0.1:<port>` to
  use another synthetic host than 47821. Each engine logs
  "sent/received N bytes in M ms (X MiB/s)" (category `files`). Benchmark (opt in):
  `VANTAGE_BENCH_FILES=1 xcrun swift test --package-path Packages/VantageCore --filter FileTransferBenchmark`
  (2 GiB over loopback, prints MiB/s and peak footprint). Out of scope: a share extension (needs
  an App Group), folders, Taildrop, `UIBackgroundModes` (not needed for continued processing).
- **Files arriving on the Mac** (host, `VantageHost/Transfer`; the policy is `FileArrival.swift`,
  tested by `HostFileArrivalTests` in the root package): saved to `~/Downloads` or the folder
  chosen in Settings → Files (`HostFileStore.current` → `ReceiveFolder`: Downloads again while the
  choice is missing or read-only; read once per file channel, so a change applies from the next
  connection). `FileArrivals` batches arrivals (`ArrivalBatcher`: 1.5 s after the last file with
  nothing else coming in, or after 20 s behind a long one), then `ArrivalPlan` applies Settings →
  Files: a notification (default on; one per batch, QuickLook preview, Show in Finder selects the
  batch), then Do Nothing / **Show in Finder** (default, since Drew asked to be taken to the file;
  one window selecting the batch) / Open the File (`AutoOpen`: an allowlist of documents and media
  minus anything that runs code, installs, or points elsewhere; the rest, and batches over five,
  are shown in Finder and the notice says why). **Banners are muted while an iPad watches**: macOS
  holds banners while the screen is mirrored or shared unless "Allow notifications when mirroring
  or sharing the display" is on (off by default; `com.apple.ncprefs` → `dnd_prefs.dndMirrored`,
  read only by `SharingNotificationPreference`), and Vantage's ScreenCaptureKit capture counts as
  sharing: NotificationCenter logs "muted by display state (displayShared)" and the notification
  only lands in Notification Center. So while a session is connected and a banner wouldn't show,
  the host shows `ArrivalNotice`: a non-activating glass panel (never key, `.statusBar` level, all
  spaces) at the top right of the pointer's screen, which is where the iPad left the pointer, with
  Show in Finder; it pauses while hovered, leaves after 6 s, only fades with Reduce Motion, and is
  announced to VoiceOver. Settings → Files shows whether banners get through and opens
  Notification Settings; never change that system setting from code. **Progress**: while a file
  arrives, a `Progress` (file, downloading, cancellable) is published for its hidden
  `.vantage-<id>.partial`, so folder subscribers such as the Dock's Downloads stack see it (Finder
  hides the partial, and the partial-then-rename safety is unchanged), and each saved file posts
  `com.apple.DownloadFileFinished` so the stack bounces. The menu bar icon (`StatusItemIcon`)
  gains a progress ring with an arrow while files move (`StatusItemIcon.moving` decides which;
  VoiceOver hears "Receiving Report.pdf, 45%"), and the menu's Files section shows the receive
  folder and, per file, progress, speed and time left (`HostTransfer.record`), cancel and Show in
  Finder; a row's wording lives in `HostTransferRow.detail`, the send targets in
  `HostFilesSection.sendTargets`. Synthetic hosts skip all of it unless started with
  `--arrival-actions`. Debug: `--receive-folder <path>` (tests never touch the real Downloads),
  `--preview-arrival <path,…>` (the notice until closed), `--open-settings files`, `--open-menu`
  (the popover and the live menu bar icon in a window: on a crowded menu bar the item hides
  behind the overflow), `--appearance light|dark`; override settings without writing Drew's
  defaults with argument-domain flags such as `-files.afterArrival open -files.notify NO`.
- **visionOS** (native, not "Designed for iPad"): each session opens in its own `WindowGroup(id:
  "session", for: UUID.self)` window (`SessionWindow` in `ContentView.swift`; list and sessions share
  `DeviceStore.shared` / `AppLock.shared`), which `WindowAspectMatcher` reshapes to the Mac's display
  with uniform resizing. The `ControlStrip` lives in a bottom `.ornament`; there is no dock/corner or
  touch mode there. Look and pinch always points absolutely (tap = click, pinch-drag = drag, pinch
  and hold = right-click). Liquid Glass is unavailable: use `platformGlass(in:)`, and `.glass` /
  `.glassProminent` button styles map to bordered styles in `PlatformGlass.swift`. No Pencil
  interaction, haptics, keyboard accessory, Control Center controls, or widgets on visionOS. The
  visionOS app icon (a layered `.solidimagestack`) doesn't exist yet. The simulator can't take
  AXe/xcui input, so pinch mapping still needs a headset check.

## macOS client

The `Vantage` target also builds a native, sandboxed Mac app (`Vantage/Mac/`, plus `#if os(macOS)`
branches). `ContentView` is iOS/visionOS only; the Mac starts at `MacRootView`.

- **Windows** (`VantageApp.swift`): `Window("Vantage", id: "main")` holds the device list, one
  only, so ⌘N means Add Mac…; `.defaultLaunchBehavior(.presented)` so it's there at every launch
  (stale saved window state once opened the app with no window at all), and it takes every link
  and opened file (`handlesExternalEvents(matching: ["*"])`). Each Mac connects in its own
  `WindowGroup(id: "session", for: UUID.self)` window (`SessionWindow`: `.commandsRemoved()`,
  restoration off, `handlesExternalEvents(matching: [])` so a link never opens an empty one).
  `MacAppDelegate`: closing the last window doesn't quit (sessions and files outlive the list),
  the Dock icon brings the list back, becoming active opens a pending connection and retries
  files, and launch starts `MacTransferActivity`. `Settings { MacSettingsView }` and
  `Window("Vantage Help", id: "help")`.
- **Device list** (`MacRootView`): `NavigationSplitView`, sidebar `List(selection:)` of
  `MacSidebarRow` (a `Label`, so the symbol turns white on a selected row; `AvailabilityLabel`
  drops its orange on the accent fill via `backgroundProminence`; `DeviceTransferBadge`; drops go
  through `FileDropDelegate`), `.contextMenu(forSelectionType:primaryAction:)` so double-click and
  Return connect. Detail `MacDeviceDetail`: Connect (`.glassProminent`, default action), Send
  Files…, Transfers, Edit…, Log In with Screen Sharing, Play Mac Audio, what's saved. Selection is
  `@SceneStorage`. Availability checks run while the list is open (none at all, not "Checking…",
  while Settings › Connection turns them off). `DeviceActions` (in `DeviceListScreen.swift`) holds
  every sheet, picker, and confirmation the list can raise, shared by the iOS list and the Mac
  (`DeviceActions.shared`, so the menu bar reaches it from a session window); `DeviceMenu`,
  `AddDeviceMenu`, `DeviceSortPicker`, `DeviceListEmptyState`, `TailscaleBanner` are shared too.
- **Routing** (`MacWindowRouter`): holds an `openWindow` from the first window root (the list
  hands it over in its `.task`, before the root's `onAppear`), so Siri/Shortcuts/Spotlight
  (`PendingConnection`), `vantage://` links, and files opened in Vantage reach a session even with
  no window watching. Every Mac window root goes through `macWindowRoot()`: store, Tailscale state
  (`MacApp`; Settings and sessions are scenes of their own and `ConnectionSettings` crashes
  without it), appearance, the lock curtain, and the pending-connection watch.
- **Menu bar** (`MacCommands`): File › Add Mac… ⌘N, Add from Tailscale… ⇧⌘N, Connect to ⟨Mac⟩ ⌘O,
  Send Files…; Session (Send Keyboard Shortcuts to Mac ⌃⌥⌘K, View Only, Mac Audio ⌃⌥⌘A, Dictate
  ⌃⌥⌘D, Send File… ⌃⌥⌘U, Transfers… ⌃⌥⌘T, Send Clipboard ⌃⌥⌘V, Type Password ⌃⌥⌘P, Mac ▸
  Spotlight/Mission Control/Application Windows/Show Desktop/App Switcher (⌘Tab)/Sleep Display/Lock
  Screen/Wake Display, Customize Controls…, Disconnect ⌃⌥⌘W); View adds Hide/Show Controls ⌃⌥⌘C,
  Actual Size ⌃⌥⌘0, Full Screen ⌃⌥⌘F, Sort Macs By; Help › Vantage Help. Session shortcuts all
  hold ⌃⌥⌘, the one chord a capturing session leaves to Vantage. Items read
  `@FocusedValue(\.sessionCommands)` (the session publishes `SessionCommands` with
  `focusedSceneValue`, since its AppKit view holds focus) and `\.selectedMac` (the list); they're
  dimmed when they don't apply, never hidden. `SidebarCommands`, `ToolbarCommands`.
- **Settings** (`MacSettingsView`, ⌘,): tabs General (appearance), Controls, Connection, Privacy &
  Security, About, each a grouped form in its own `NavigationStack`; the last tab is remembered
  (`vantage.mac.settingsTab`, also an argument-domain flag for screenshots). Controls on the Mac:
  Keyboard (`vantage.mac.captureShortcuts`, default on; `vantage.mac.swapCommandControl`, default
  off; `MacKeyboardSettings` has the keys), Dictation, Session Controls; no touch, trackpad,
  on-screen keyboard, Pencil, or haptics. Privacy & Security says "Require Touch ID" and has no
  iCloud sync until the Mac is signed for it. Add Device hides Natural Scrolling (the Mac's own
  mouse settings apply). Help swaps the touch answers for Mac ones (`HelpScreen.controllingTheMac`).
- **App lock**: `AppLock.shared` locks on `com.apple.screenIsLocked`, display sleep, system sleep,
  and a fast-user switch away, and asks again when `com.apple.screenIsUnlocked` arrives with Vantage
  in front or when it next becomes active. `appLockCurtain()` lays `LockOverlay` over every Mac
  window root and every device-list sheet (sheets are windows of their own); the views stay
  alive, so sessions stay connected. Never swap a Mac window's view for the lock: that
  disconnects the session. The session's input capture must also ignore input while locked.
- **Control strip**: shown as on iPad. The Mac's default is `ControlStripLayout.macStandard`
  (Spotlight, Mission Control, Application Windows, Show Desktop, Type Password, Send Clipboard,
  Dictate; `platformStandard` picks it). `StripItem.unavailableHere` (`.keyboard` on the Mac) is
  skipped by `visibleItems()`/`hiddenItems()`, never removed: a layout synced from an iPad keeps
  its Keyboard button, and editor changes go through `replacingVisible(with:)`, which puts it
  back after the control it followed. The Mac editor reorders by dragging (grip on each row; no
  edit mode) and lets section footers wrap.
- **Clipboard**: the Mac client's `ClipboardSync` wraps `PasteboardSync(pasteboard:)` (injectable,
  NSPasteboard text/RTF/PNG, TIFF→PNG like the host); it reads only on user action
  (`currentPayload()` for Send Clipboard, `changedPayload()` for ⌘V paste-through, which reads
  nothing unless `changeCount` moved), because macOS 15.4+ asks before other programmatic reads. A
  payload equal to the last one synced is never written again while the pasteboard still holds
  it, nor sent again: client and host on one Mac share the pasteboard and would bounce it forever.
  Tests: `ClipboardSyncTests`. Host: `ClipboardBridge` touches the pasteboard only on the main
  thread (poll timer on `.main`; `currentPayload()` hops there from the session actor) and records
  its own write's change count in the same block. Never bring back a "suppress next change" flag:
  it outlived the write and swallowed the user's next copy. Tests: `HostClipboardTests`.
- **Audio and dictation**: the host's `AudioCapture` always leaves the Vantage client app
  (`com.benjaminlevinson.vantage`) out of the audio filter, so a Mac connected to itself doesn't
  echo. `MacAudioPlayer` on macOS has no audio session: the engine plays straight to the device,
  `AVAudioEngineConfigurationChange` restarts it on a device change, output latency comes from
  `outputNode.presentationLatency`, and output still pauses while dictation's mic is open. Live
  check (makes sound): `VANTAGE_LIVE_MAC_AUDIO=1 xcrun swift test --filter MacAudioPlayerLiveTests`.
  Dictation on macOS stops with what it heard on `AVAudioEngineConfigurationChange` (no
  interruptions there). `Failure.settings` opens `x-apple.systempreferences:…?Privacy_Microphone` /
  `Privacy_SpeechRecognition`. `LocalDevice.noun`/`.this`/`.symbol`/`.settingsApp` name the local
  device ("this Mac" on macOS); the enum cases keep their `iPad` names.
- **Identity, sandbox, files**: the Mac client names itself with `SCDynamicStoreCopyComputerName`
  and `sysctlbyname("hw.model")` (`MacComputer`, cached); never `Host.current()`, which can block
  on DNS. `DeviceCatalog` writes only Application Support on macOS; `CloudSync` looks for
  `Contents/embedded.provisionprofile` on the Mac. Received files go to `~/Downloads`
  (`URL.downloadsDirectory.resolvingSymlinksInPath()`), or DEBUG `-VantageReceiveFolder <path>`,
  and a test runner without the Vantage bundle id gets `$TMPDIR/VantageReceived`, so tests never
  touch the real Downloads. Show uses `NSWorkspace.activateFileViewerSelecting`. Finder drops
  carrying `public.file-url` are sent in place (`send([url], securityScoped: false)`); folders are
  skipped and other drops are still copied. `MacTransferActivity` holds a `.userInitiated`
  activity (no idle sleep) while files move and a `.userInitiatedAllowingIdleSystemSleep` one (no
  App Nap) while a screen session is up, and calls `FileTransferCenter.retryAll()` on
  `NSWorkspace.didWakeNotification`.
- **Shared container**: every checkout's Debug build has the same bundle id, so they share one
  sandbox container (saved Macs, defaults, window state). Test with argument-domain overrides
  (`-vantage.savedDevices '<hex of the JSON array>'`, `-vantage.availabilityChecks NO`,
  `-ApplePersistenceIgnoreState YES`) rather than editing it, and quit a build with
  `pkill -f <its path>`: `tell application id … to quit` can quit another checkout's copy.
- **UI tests** (`Tests/VantageMacUITests`, target `VantageMacUITests`, shared scheme of the same
  name, which also builds `VantageHost`): `MacShellUITests` starts its own synthetic host from the
  products folder on port 47856 (`TEST_RUNNER_VANTAGE_TEST_HOST=127.0.0.1:<port>` uses one
  already running) and covers `testConnectOpensTheMacInItsOwnWindow`,
  `testSessionMenuFollowsTheFocusedWindow`, `testSettingsOpensWithCommandComma`. macOS UI tests
  need Automation Mode approved once by an admin (`automationmodetool
  enable-automationmode-without-authentication`); until then `scripts/check.sh` only builds them
  (`build-for-testing`).

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

# Client (macOS; same target, sandboxed, one window per session; the session view is still a stub)
xcodebuild build -project Vantage.xcodeproj -scheme Vantage -destination 'platform=macOS' -derivedDataPath .deriveddata
```

Reuse `.deriveddata`; do not create per-task DerivedData trees. Use regular Xcode 27, not Xcode-beta. Set `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` for shell builds and `xcrun swift` for tests. `scripts/check.sh` runs both test suites, the host build, and the iOS and macOS client builds, and compiles the Mac UI tests.

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
and fixed-code arguments are DEBUG-only. The debug-only `--port 47821` override allows isolated tests alongside the normal host on 47820; quit the synthetic host afterward, or launch it with `--exit-after <seconds>` (DEBUG) so it quits by itself. Client debug
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
- Clipboard carries text, RTF, and PNG images both ways; files go over the file channel (above).
- Virtual-display provisioning is wired but falls back to the main display if BetterDisplay's CLI
  isn't available. Drew verified real Mac video, pointer/clicks, and software-keyboard typing on the physical iPad.
  Clipboard, hardware keyboard, BetterDisplay, and biometric session recovery still need device checks.
