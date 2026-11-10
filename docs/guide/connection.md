# Connections, pairing and the host's display

Part of the project guide; [`CLAUDE.md`](../../CLAUDE.md) has the naming, layout and repo rules this assumes.

- **Auth**: Ed25519 device identities in Keychain, both ways (a synthetic host's lives in a key
  file of its own instead: Headless end-to-end testing in [testing.md](testing.md)). The client's `hello` carries a
  nonce; the host answers a challenge with its own nonce and `hostSignature` over both nonces and
  both keys (`AuthTranscript.hostBytes`), and the client checks it before signing anything or
  sending a pairing code (`HostIdentityCheck`): the host must prove it holds the key it names, and
  that key must be the one remembered for the saved device from its first connection
  (`SavedDevice.hostPublicKey`, recorded by the session screen and files-only sessions through
  `DeviceStore.recordHostKey`; Edit Computer shows the fingerprint and offers Forget Identity after a
  reinstall, and the list shows "Identity changed"). The client then signs
  `AuthTranscript.clientBytes`, which also binds the connection's purpose (screen, probe, files), so
  a signature made for an availability check can't open a screen and one made for one host is
  useless at another; the host derives the purpose from the hello (`AuthPurpose`). A client without
  a nonce (older builds) still signs the older `vantage-auth-v1` transcript, which hosts accept; a
  host without a signature (older Casement Host) is refused with "Update Casement Host". Any change
  here updates the Swift and C# sides and the golden vectors (`helloProbe`, `challengeSigned`).
  The host side of all this (version check, the transcript the device's build signs, signature
  checks, the pairing code's accepted/wrong/run-out answers and the second each miss costs, the
  availability check, files-only sessions, the Screen Recording refusal, and the capabilities to
  advertise) is one module, `SessionAdmission` (VantageCore `Identity`): `begin(hello:)` makes the
  challenge, `Pending.finish` judges the answer into a session kind or a refusal, and the pairing
  code's own rules are `PairingCodes` beside it. `HostSession` only sends what it says, and the
  client tests' mock hosts (`MockHost` in `ClientSessionTests`) run the same module, so there is
  one copy of the host's rules in Swift; `SessionAdmissionTests` cover pairing, the five-miss burn,
  purpose binding, older clients and files-only sessions. Trust reaches it as `PairingAuthority`.
  First connection needs a 6-digit pairing code shown on the Mac; after
  that the key is trusted. The Mac keeps trusted keys in the Keychain (`TrustStore`, moved once from
  `vantage.trustedClients` in defaults), since any program this user runs can rewrite defaults;
  synthetic hosts keep theirs in a defaults suite of their own. iOS names every device "iPad"/"iPhone", so a paired device still
  called that takes its tailnet machine name (`TrustStore.adoptTailnetName`; iOS peers report
  Hostname "localhost", so `TailscaleCLI.deviceName` uses ComputedName, e.g. "drew-ipad-pro"),
  and Casement Host → Settings → Devices can rename it (`TrustStore.rename`). A pairing code expires after 10 minutes and is burned after 5 wrong
  guesses (`PairingCodes`, kept by `TrustStore`); each miss also costs the peer a second. The listener
  rejects any peer outside Tailscale's CGNAT/ULA ranges; loopback is accepted only in DEBUG builds.
  Revoking a device (`HostController.revoke`) also ends whatever it has open: each of its sessions
  sends `disconnect` ("This device was removed from the Mac.") and tears down
  (`HostSession.endIfClient`), as the Windows host's `RevokeAsync` does. Teardown closes the
  connection first, and everything the receive loop awaits (a curtain request, a display change, a
  capture start) checks the session is still streaming afterwards, so a request in flight when the
  device was removed can't leave a curtain holder or a capture behind for a dead session (a start
  that finishes after the teardown stops the capture it made itself: the teardown's stop ran
  before ScreenCaptureKit had a stream to stop); the client shows "The Mac
  ended the session." and doesn't reconnect.
  The host names its OS in `Challenge.hostPlatform` and `HostCapabilities.platform` (`HostPlatform`,
  a string wrapper: `macos`, `windows`, unknown values still decode; nil from older hosts means a
  Mac). The client keeps it as `ClientSession.hostPlatform` (from the challenge, then the
  capabilities) and `HostAvailabilityStore.platforms`. DEBUG host `--platform windows|macos`
  overrides what it sends, to try the client against a pretend PC.
- **Virtual display**: `VirtualDisplayManager` provisions a BetterDisplay virtual screen sized to
  the iPad viewport (behind a protocol so `CGVirtualDisplay` can replace it later). It is opt-in
  per saved device (`SavedDevice.useVirtualDisplay` → `SelectDisplay.useVirtualDisplay`; a PC
  gets the same toggle as "Fit the PC's display to this screen", and its host switches display
  mode instead). The
  default path streams the main display immediately; never put BetterDisplay's CLI back on the
  connect path unconditionally — on Drew's Mac it answers "Failed." to everything and the old
  15 s poll made every connect take 16 s. When the toggle is on, a connected non-built-in display
  whose point size already matches the viewport is reused without touching the CLI.
- **Tailscale account**: `TailscaleAccount` (client) talks read-only to `api.tailscale.com`
  (`GET /api/v2/tailnet/-/devices`) with either an API access token or an OAuth client
  (`client_credentials` at `/api/v2/oauth/token`, tokens cached ~1 h). Tailscale has no end-user
  sign-in for third-party apps, so the user pastes a key from the admin console; it lives in the
  Keychain. `TailscaleAccountScreen` offers the two key kinds as separate pages (`TailscaleOAuthSetup`, `TailscaleTokenSetup`); the fixture also accepts any key there so sign-in can be exercised. `TailscaleDevicesSheet` lists Macs and PCs (probed with `HostAvailabilityProbe`) and greys out
  other platforms. Debug flags: `-VantageTailscaleFixture 1` serves a fictional tailnet,
  `-VantageOpenTailscaleDevices 1` opens the picker on launch (`-VantageTailscaleJustAdded 1` adds
  its Studio Mac and Drew-PC, showing the "Next Step" pairing rows, which name Casement Host's
  button through `HostNoun.pairingCommand`/`pairingInstruction`),
  `-VantageOpenScreen settings|controls|security|help|about|tailscale|tailscaleOAuth|tailscaleToken|addDevice|controlStrip|controlStripMac|controlStripPC|editPC|transfers` presents one
  screen as a sheet for screenshots (AXe taps don't reach this app in the simulator; swipes do;
  `controlStripMac` edits the first saved Mac and `controlStripPC`/`editPC` the first PC, so pair
  them with `-VantageSeedSamples 1`, which includes one PC).
- **Host environment** (`HostEnvironment`, `VantageHost/Engine`): everything platform-specific a
  `HostSession` needs (displays and capture, the video encoder, display power and status, input,
  clipboard, sound, Curtain, dictation, tailnet names, the receive folder, a clock) comes through one struct of
  protocols, chosen once in `HostController.makeEnvironment` (the composition root): the real Mac
  (`MacHostEnvironment`: ScreenCaptureKit, `PowerManager`, `LockMonitor`, `InputInjector`,
  `ClipboardBridge`, `ScreenCurtain`, `HostTranscriber`, `TailscaleCLI`) or the synthetic
  stand-ins (`SyntheticHostEnvironment`: `FakeDisplay`, the test pattern, the chime, no input or
  clipboard). The session never reads `HostOptions` or a singleton, so the Windows host's
  `HostEnvironment` and the Mac's have the same shape, and `HostSessionTests` (root
  `xcrun swift test`) drive the real session over loopback on the synthetic environment. A new
  platform dependency goes behind a protocol here, with a synthetic adapter, never straight into
  the session. Pairing and trust reach the session as `HostTrust` (`TrustStore` on a real host).
- **Capture lifecycle** (`CaptureLifecycle`, `VantageHost/Engine`; the Windows host's session runs
  the same machine): everything that keeps a picture coming for a screen session lives in one pure
  module, events in and decisions out, with the caller's clock on every event. Events: the device
  asked for a selection; a capture started, failed or stopped; a frame arrived; the status monitor
  changed (lock, secure input, display sleep); Wake (also Retry) or Sleep Display; the displays
  changed; a 250 ms tick. Decisions: start capture on these targets (the display it was on first,
  keeping its codec, then the device's own choice; synthetic displays only the latter), stop it,
  send a `HostStatus` (only when it differs from the last one sent, as the Windows host does), wake
  or sleep the display, re-read the status, begin monitoring, request a keyframe (a wake with
  capture still running), or log a note. It also answers whether input may reach the screen.
  `HostSession.dispatch` feeds it and executes the decisions (`apply`, `execute`), runs the ticks
  while `wantsTicks` (`syncTicker`), and keeps only what is platform-bound: the capture and encoder
  objects, the wait for ScreenCaptureKit to list displays after a wake, and DEBUG
  `--capture-fails-for`. A start replaces whatever was running: from the moment the lifecycle asks
  for one, nothing counts as running until it reports back, so a restart whose every target fails
  (the displays changed, the old capture is gone) enters the watchdog like any other lost picture
  rather than hiding behind a capture that no longer exists, and while the picture is lost every
  start is a recovery attempt, whoever asked for it (the clock, Wake/Retry, a state or display
  change, a request that waited behind a start): the next wait is counted from when that attempt
  ended, not began (a start that takes seconds to fail doesn't use the wait up, and a deadline set
  before it can't retry the moment it fails), with each kind's own delay rule (the clock doubles
  it, Wake/Retry starts it over, a state or display change keeps it). A frame that arrives while a
  start is still under way is credited to the target being tried (`captureAttemptBegan` marks each
  one), so a capture of a still screen that framed before `start` returned isn't stopped by the
  no-frame rule, and a frame from a target that then failed is no credit to the one tried next.
  In the session, `stopCapture` detaches the capture, encoder and pacer before it awaits the
  capture's stop (a ScreenCaptureKit stop can take a while), so a replacement started meanwhile (a
  wake during Sleep Display's stop) is never cleared by the older stop, which stops only what it
  detached; frame, encoder and stall callbacks carry the capture epoch they were made in and are
  ignored after it. A start that finds itself detached, or the session closed, once its capture
  comes up stops that capture itself (the stop that detached it found no stream yet) and leaves
  a replacement's fields alone. Rules below are the module's; `CaptureLifecycleTests` check them with a
  fake clock and frame source, `HostSessionTests` over loopback.
- **Keeping the picture moving** (`VideoPacer`, `VantageHost/Engine`; the Windows host's
  `VideoPipeline` is the same design): one encode in flight and the latest frame wins, a still frame
  is skipped unless a keyframe is due, and the encoder's answer to every frame keeps the count
  honest. The encoder (`VideoEncoder`, made through `HostEnvironment.makeVideoEncoder`) puts the
  parameter sets on every keyframe, and the pacer sends `videoConfig` only when they differ from
  the ones it last sent, so the configuration follows what the device actually received: an
  encode written off before its answer came can't take the only copy with it, as the Windows
  pipeline's `_configSent` check guarantees there. Every encode carries a number and the encoder's answer carries it back: an answer from an
  encode already written off (silent for over a second) is dropped, picture and accounting alike,
  so it can't free the slot of the encode that replaced it or put a stale frame on the wire. The
  write-off doesn't wait for the next changed frame (still frames and ScreenCaptureKit's idle
  callbacks never reach the encoder): the pacer names the encode in flight and its deadline
  (`outstanding`), the session's stall watch calls `encodeTimedOut` then, and a timeout for an
  encode already answered does nothing. A changed frame waiting behind an encode stays pending
  through still frames that follow it; they refresh the picture, not the need to send it.
  `VideoPacerTests` cover these on a fake encoder.
- **Display sleep** (`PowerManager`/`DisplayPower`, `LockMonitor`, `HostSession`, through
  `HostPowerControl` and `HostStatusMonitor`, decided by `CaptureLifecycle`): while the
  display sleeps, ScreenCaptureKit lists no displays and stops any stream (SCStreamError -3815,
  "Failed to find any displays or windows to capture"). Never end a session because capture
  can't start (that was the reconnect loop): capture waits, `HostStatus.isDisplayAsleep` (optional;
  nil from older hosts) tells the client, and capture restarts with a keyframe when the display
  wakes (NSWorkspace screensDid*, a 1 s poll, the controller's restart; one start at a time, a
  request made meanwhile takes over afterwards; the asleep notice stops the capture at once rather
  than waiting for ScreenCaptureKit, so nothing encoded before the sleep arrives after the wake,
  and a wake that finds capture still running asks for a keyframe instead). The
  injector, power assertion, and status monitor live for the session, not the capture. Connecting
  wakes a sleeping display before listing displays; input while asleep wakes it (≤ 1/s) instead
  of being delivered (releases still are), except for 2 s after Sleep Display; the Wake command
  always wakes. Waking is `IOPMAssertionDeclareUserActivity(kIOPMUserActiveLocal)` re-using one
  assertion id (Remote lights the display on macOS 27 too; a fresh id per call leaked an assertion
  every time). On Drew's Mac display sleep also posts `com.apple.screenIsLocked` + Secure Input
  even with screen lock off; both clear on wake. **Awake but no picture** (capture won't start;
  once seen after a wake, when SCK listed no displays for 10+ s): the lifecycle's watchdog
  retries (0.5 s doubling to 5 s) for the whole session, logs every attempt as "capture
  unavailable for N s: <reason>; trying again" with the panel state (category `session`),
  re-declares local activity when CGDisplayIsAsleep or an empty active-display list says the panel
  is off (IOKit has no display power state on Apple silicon), watches every capture start and
  treats one with no frame in 5 s as failed (armed on every start as the Windows host does, not
  only after a failure), and after 3 s sets `HostStatus.isScreenUnavailable` (optional), cleared on
  the first frame back. Wake doubles as Retry (restarts capture at once). Client: `MacScreenNote`
  (last frame dimmed, glass note, Wake/Retry button, tap anywhere) shows "The Mac's display is
  asleep" or "Waiting for the Mac's screen…", never a frozen frame without a word; the lock
  banner hides only while asleep. `ClientSession`
  resets its reconnect backoff only once the host answers the stream request or the connection
  lasted 10 s, and idle video never triggers a reconnect. Debug: host `--display-asleep` (with
  `--synthetic-capture`: the pretend display, `FakeDisplay`, starts asleep; sleep and wake
  commands flip it, and its capture stops when it sleeps as ScreenCaptureKit's does; a synthetic
  host never reads the real Mac's display power, so a test host on a Mac whose screen is off still
  behaves) and
  `--capture-fails-for <s>` (each session's capture fails that long from its first stream
  request). Tests: `CaptureLifecycleTests` (the rules on a fake clock), `HostSessionTests` (the
  Mac session over loopback: sleep and wake, a missing picture), `DisplaySleepSessionTests`,
  `HostStatusTests` (VantageCore),
  `SessionUITests.testSleepDisplayShowsAsleepStateAndWakes` (synthetic host with
  `--display-asleep`; `TEST_RUNNER_VANTAGE_SYNTHETIC_HOST=127.0.0.1:<port>` and
  `TEST_RUNNER_VANTAGE_TEXT_SIZE=<content size category>` override the defaults),
  `testMissingPictureIsExplainedUntilFramesReturn` (synthetic host with `--capture-fails-for 6`,
  default 127.0.0.1:47822, `TEST_RUNNER_VANTAGE_UNAVAILABLE_HOST` overrides).
