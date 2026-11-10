# Casement

Casement lets a person see and control their own Mac or Windows PC from an iPhone, iPad, Mac or Apple Vision Pro, over their own Tailscale network and nothing else. Terms use the words the apps show; the code's older name is noted where it differs (the code still says Vantage, see [ADR-0003](docs/adr/0003-code-keeps-the-vantage-names.md)).

## The two apps

**Casement**:
The app on iPhone, iPad, Mac and Vision Pro that shows a computer's screen and sends it input. Code name: `Vantage`.
_Avoid_: Vantage, Porthole, the client (in anything a person reads)

**Casement Host**:
The app on the controlled computer, a menu-bar app on a Mac and a tray app on Windows, that streams the screen, takes input and moves files. Code name: `VantageHost`, `WindowsHost`.
_Avoid_: Vantage Host, server, agent, helper

**Computer**:
A Mac or PC that someone controls with Casement, the desktop or laptop at the other end, running Casement Host. Text people read names it by platform where it can (**the Mac**, **the PC**, never "Windows machine"). Code and the project guides call it the host.
_Avoid_: host (outside the name Casement Host), device, machine, server

**Device**:
The iPhone, iPad, Mac or Vision Pro in the person's hand (or on their face) running Casement. A Mac can be either: the MacBook controlling the Studio Mac is the device, the Studio Mac the computer.
_Avoid_: client (in anything a person reads), computer

**Saved computer**:
A computer in Casement's list, with its address, name and per-computer choices (control strip, sound, Curtain, display fitting). Code name: `SavedDevice`.
_Avoid_: saved device, host entry, bookmark

**Paired device**:
A device that a computer's Casement Host trusts, after one pairing. Casement Host lists them as Paired Devices.
_Avoid_: client, trusted client (in anything a person reads)

## Connecting

**Tailnet**:
The person's own Tailscale network. Casement connects only to computers on it ([ADR-0001](docs/adr/0001-tailscale-only.md)).
_Avoid_: VPN, network, LAN

**Pairing**:
The one-time step where a device proves itself to a computer by entering the pairing code the computer shows; afterwards the computer trusts that device's key.
_Avoid_: sign-in, login, linking

**Pairing code**:
The six-digit code Casement Host shows while pairing. It runs out after ten minutes and is used up by one pairing.
_Avoid_: PIN, password

**Host identity**:
The key a computer proves it holds on every connection, remembered from the first one. A different key shows as "Identity changed" until the person chooses Forget Identity.
_Avoid_: fingerprint (that is how the identity is displayed), certificate

**Admission**:
What Casement Host decides when a device connects: refused (an older protocol, a bad signature, no or a wrong pairing code), or admitted as an availability check, a files-only session or a screen session, which the connection then runs as. Code name: `SessionAdmission` on Windows, the handshake in `HostSession` on the Mac.
_Avoid_: login, authentication (one step of it), handshake (the messages, not the decision)

**Availability check**:
A short connection Casement makes to see whether a saved computer is reachable and what it is, without opening its screen. Code name: probe.
_Avoid_: ping, status check

**Screen session**:
A connection that shows a computer's screen and sends it input. With a current Casement Host, ending one doesn't stop files already moving.
_Avoid_: stream, remote session, connection (when files-only sessions are also in play)

**Files-only session**:
A connection that moves files to or from a computer without opening its screen.
_Avoid_: background session, file session

**File channel**:
The second connection beside a session that carries files, so a large file never holds up the screen or the pointer.
_Avoid_: media channel, bulk connection

## In a screen session

**Screen**:
What the person sees and controls in a session: the computer's desktop as Casement shows it ("the Mac's screen").
_Avoid_: picture, video, stream, remote display

**Display**:
A physical or virtual panel attached to the computer, such as a Mac's built-in display or a PC's monitor. A display can sleep or be fitted; the screen is what Casement shows of it.
_Avoid_: screen (for the panel itself), monitor (unless it really is one)

**Control strip**:
The floating row of buttons over the screen (shortcuts, keyboard, dictation, files, sound) that docks in a corner and can be rearranged per computer. Code name: `ControlStrip`.
_Avoid_: session controls, toolbar, dock, palette

**Session menu**:
The menu at the end of the control strip with everything else a session can do.
_Avoid_: more menu, overflow menu

**Touch mode**:
How fingers on the screen act: **Trackpad** moves the pointer like a laptop trackpad, **Direct Touch** clicks where the finger lands. A mouse, a trackpad and the Pencil always point where they are.
_Avoid_: input mode, pointer mode

**View Only**:
A session that shows the screen and sends no input.
_Avoid_: read-only, spectator mode

**Fit the display**:
Making the computer's display match the shape of the device's screen for the session, then putting it back: a virtual display on a Mac, a change of display mode and scale on a PC.
_Avoid_: resize, match resolution

**Curtain**:
While a device is connected, the computer's displays go black and its own keyboard and mouse stop working, so nobody at the computer sees or interrupts the session. The screen in Casement stays the same.
_Avoid_: privacy screen, blackout, screen lock

**Mac Audio / PC Audio**:
The computer's sound, played on the device during a session.
_Avoid_: sound streaming, remote audio

**Dictation**:
Speaking into the device to type on the computer, transcribed either on the device or on the Mac.
_Avoid_: voice input, speech-to-text

**Type Password**:
Typing a password saved on the device into that computer, through Screen Sharing when the Mac's lock screen or a password field blocks ordinary typing.
_Avoid_: autofill, password manager

## Files

**Transfer**:
One file moving between a device and a computer, in either direction. One cut off by a lost connection is **paused** and resumes where it stopped.
_Avoid_: upload, download, job

**Run of files**:
The files sent or received together since the last time nothing was moving, shown as one summary ("Sending 3 of 12").
_Avoid_: batch, queue

**Receive folder**:
Where a computer saves files that arrive: Downloads unless the person chose another folder.
_Avoid_: inbox, drop folder

## On the computer

**Setup window**:
Casement Host's first-run checklist of what it needs (Screen Recording, Accessibility, Tailscale, a paired device), which reopens when a step goes missing.
_Avoid_: onboarding, wizard

**Restart guard**:
Casement Host holding a restart, shutdown or sign-out while a device is connected, so the person at the computer can cancel it.
_Avoid_: shutdown blocker

**Restart Safely**:
Restarting a FileVault Mac so it skips the unlock screen at startup and reaches the login window, where Log In with Screen Sharing can sign in.
_Avoid_: auth restart, remote reboot

## Building and testing

**Synthetic host**:
A debug copy of Casement Host that streams a test pattern and never touches the real displays, keyboard or Keychain, for tests and screenshots.
_Avoid_: mock host (that is a test double inside the test suites), fake host

**Golden vectors**:
Recorded wire messages that the Swift code (Casement and Casement Host for Mac) and Casement Host for Windows' C# code must each read and write the same way, so every computer speaks one protocol.
_Avoid_: fixtures, snapshots
