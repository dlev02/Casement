# Connections, pairing and the host's display

Part of the project guide; [`CLAUDE.md`](../../CLAUDE.md) has the naming, layout and repo rules this assumes.

- **Auth**: Ed25519 device identities in Keychain, both ways. The client's `hello` carries a
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
  First connection needs a 6-digit pairing code shown on the Mac; after
  that the key is trusted. The Mac keeps trusted keys in the Keychain (`TrustStore`, moved once from
  `vantage.trustedClients` in defaults), since any program this user runs can rewrite defaults;
  synthetic hosts keep theirs in a defaults suite of their own. iOS names every device "iPad"/"iPhone", so a paired device still
  called that takes its tailnet machine name (`TrustStore.adoptTailnetName`; iOS peers report
  Hostname "localhost", so `TailscaleCLI.deviceName` uses ComputedName, e.g. "drew-ipad-pro"),
  and Casement Host → Settings → Devices can rename it (`TrustStore.rename`). A pairing code expires after 10 minutes and is burned after 5 wrong
  guesses (`TrustStore.consumePairingCode`); each miss also costs the peer a second. The listener
  rejects any peer outside Tailscale's CGNAT/ULA ranges; loopback is accepted only in DEBUG builds.
  Revoking a device (`HostController.revoke`) also ends whatever it has open: each of its sessions
  sends `disconnect` ("This device was removed from the Mac.") and tears down
  (`HostSession.endIfClient`), as the Windows host's `RevokeAsync` does; the client shows "The Mac
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
  (IOKit has no display power state on Apple silicon), watches every capture start and treats one
  with no frame in 5 s as failed (`HostSession.noFrameLimit`, armed on every start as the Windows
  host does, not only after a failure), and after 3 s sets `HostStatus.isScreenUnavailable` (optional), cleared on the
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
