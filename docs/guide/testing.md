# Running hosts and the app end to end

Part of the project guide; [`CLAUDE.md`](../../CLAUDE.md) has the naming, layout and repo rules this assumes.

## Running for real

The host needs two TCC grants the first time: Screen Recording and Accessibility (for CGEvent). The
menu-bar UI surfaces both with buttons. Tailscale must be running on both devices. Unattended access
(login-window capture, FileVault reboot recovery) is deliberately out of scope for v1 — see the
research notes.

**Keychain experiments**: use a throwaway item in the login Keychain, never change an item's access
rules (`kSecAttrAccess` in an update raises a system dialog even with interaction off), and never
kill a process stuck on a prompt: that crashed `securityd`, and its restart locked the login Keychain
until the password was entered again. Results from a keychain made with `security create-keychain`
don't carry over: there another program's overwrite was readable by the owner, while in the login
Keychain it wasn't.

## Headless end-to-end testing (no permissions needed)

Build the host for a test run with the plain `xcodebuild build … -scheme VantageHost` (team
signing). A host built unsigned (`CODE_SIGNING_ALLOWED=NO`, what `CI=1 scripts/check.sh` does) is
ad-hoc signed, so a real host reading its identity from the login Keychain
(`HostController.loadIdentity`) raises a password prompt on the Mac and the process sits in
`SecItemCopyMatching` forever, listening on nothing; never kill one (see Keychain experiments
above), answer the prompt. A synthetic host never touches the Keychain: its identity is a key file
of its own, `~/Library/Application Support/Vantage Host/Synthetic/device-identity`
(`SyntheticHostEnvironment.loadOrCreateIdentity`, mode 0600 in a 0700 folder, made on the first
launch and kept, so a device that saved a synthetic host keeps matching it; delete the file to give
it a new identity), so an unsigned synthetic host streams with no prompt. Hosts launched together
(the UI tests start several) take turns through `device-identity.lock` beside it and link a
privately written temporary file into place, so they all come up with the one identity and none
overwrites another's; an existing file is checked before it's trusted (a regular file of the
user's, 32 bytes, mode 0600: a drifted mode is put back, anything else replaced, and the
`controller` log says which). Synthetic hosts used the real host's Keychain identity before
(2026-11-09), so a simulator that connected to one earlier keeps refusing with "identity has
changed" until that saved identity is gone: choose Forget Identity on the saved computer (Edit
Computer), or uninstall Casement from that simulator (`xcrun simctl uninstall <sim>
me.drewlevinson.casement`, which the UI tests reinstall) so its saved devices go with it.
`codesign -dv` on a host that will run for real should say `TeamIdentifier=7BVMD7TA97`.
Only the host is ever built unsigned: the simulator app keeps its device identity in the
simulator's Keychain, which an unsigned app can't use, so every launch would be a new, unpaired
device and the tests would fail with "Incorrect pairing code"; run `xcodebuild test -scheme
VantageUITests` without `CODE_SIGNING_ALLOWED=NO` (simulator signing is ad hoc and never touches
the Mac's Keychain), uninstall the app from the simulator first, and start fresh hosts, since a
fixed pairing code is used up by one pairing.

The Mac session itself is also covered without a simulator: `HostSessionTests` (root `xcrun swift test`)
run the real `HostSession` over loopback on the synthetic environment (pairing, the stream's first
messages and keyframe, display sleep and wake, a missing picture), the way the Windows host's
`HostListenerTests` run its session; `CaptureLifecycleTests` and `VideoPacerTests` check the two
modules behind it on a fake clock, frame source and encoder (the retry backoff, the no-frame
rule, a restart whose targets all fail, a frame delivered during a start and one from a target
that then failed, a restart during recovery that takes its time to fail, a dropped frame, a
keyframe on a still screen, a stalled encode under still frames, a late answer from a written-off
encode, a pending frame kept through still frames) in milliseconds, and `VideoPacerTests` runs the
real VideoToolbox encoder once, to show the decoder configuration still reaches the device when
the first encode was written off; `HostSessionTests` also shapes the synthetic screen like
ScreenCaptureKit where a race needs it (`TestHost(stopDelay:)`: a capture whose first stop takes
a while, with a wake meanwhile, to show the replacement survives; `startDelay:`: a capture still
starting when the device is removed, to show it is stopped once it exists; `frameLimit:` with
`lostAnswer:`: a still screen and an encoder answer that never comes, to show the session's stall
watch alone brings the picture back). `SyntheticIdentityFileTests` launch the identity file's
read-or-create 32 times at once and check the repairs above.

The simulator cannot route to the Mac's Tailscale interface, so test over loopback (the host accepts
loopback peers in addition to tailnet peers):

```
open -n ".deriveddata/Build/Products/Debug/Casement Host.app" --args --synthetic-capture --port 47821 --pairing-code 246810
xcrun simctl launch <sim> me.drewlevinson.casement -VantageAutoConnect 127.0.0.1:47821 -VantagePairingCode 246810
```

`--synthetic-capture` streams a rendered test pattern and never touches ScreenCaptureKit, so the
whole encode → transport → decode → display path runs without Screen Recording access.
`--synthetic-image <png>` (DEBUG) streams that picture instead, and the pretend display takes the
picture's size at 2x (a 2752 × 2064 picture fills a 13" iPad in landscape). The README screenshots
use it with the made-up desktops in `docs/images/source/` (HTML, rendered with headless Chrome:
`"Google Chrome" --headless=new --force-device-scale-factor=2 --window-size=1376,1032
--screenshot=out.png file://…/mac-desktop.html`); never screenshot a real desktop for the README.

To test against the **real** host (display capture + CGEvent input) from the simulator, launch the
Debug host with `--pairing-code 246810` and no `--synthetic-capture`, then auto-connect the
simulator to `127.0.0.1`. The simulator's identity is trusted after the first pairing. To verify
clicks without touching anything on the desktop, build `scripts/click-target.swift` (`swiftc -O`)
and run it: it floats an orange window at CG 400–700 × 300–500 and prints every pointer event it
receives; a tap in the simulator in Trackpad mode clicks at the display centre, inside that window.
Drive the simulator with Axiom's `xcui tap -x -y` (the `--label` matcher does not resolve SwiftUI
rows here). Host timing is logged as "stream setup took N ms" in the `session` category, and every
click as "pointer down/up" in the `input` category. A synthetic host runs
`HostSession` on `SyntheticHostEnvironment` (see Host environment in [connection.md](connection.md)):
a pretend display, the test pattern and a chime, no input, clipboard, curtain, dictation or
tailnet, nothing that reads the real Mac's display power or permissions, a separate trust
store, and its own identity file (above). Host synthetic
and fixed-code arguments are DEBUG-only. The debug-only `--port 47821` override allows isolated tests alongside the normal host on 47820; quit the synthetic host afterward, or launch it with `--exit-after <seconds>` (DEBUG) so it quits by itself. Client debug
flags (`-VantageSeedSamples 1`, `-VantageSeedHost`, `-VantageAutoConnect`, `-VantagePairingCode`)
are DEBUG-only. Read unified logs with `/usr/bin/log show --info --debug` (a shell function shadows
`log` in Drew's profile).
