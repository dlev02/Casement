# Casement Host for Mac

Part of the project guide; [`CLAUDE.md`](../../CLAUDE.md) has the naming, layout and repo rules this assumes.

- **Host menu** (`HostMenuView`, building blocks in `HostMenuComponents.swift`): one design
  language, System Settings' (the "linked devices" pattern: hero, one prominent button, inset
  grouped rows with coloured rounded-square icons). Hero: a laptop glyph on a glow of the status
  colour (the connected device beside it with `ConnectionDots` running between), the computer
  name, one status line with the state word coloured (Ready / Connected to ⟨name⟩ / Offline /
  Can't accept connections; Connected only once a screen session has signed in, via
  `HostSession`'s `onStreaming` → `HostController.connectedDevices`, so availability checks never
  flash it). Pair a Device (help/VoiceOver say Show Pairing Code, the name the iPad's prompt and
  the Windows host use) is a full-width `.glass` button under the hero until something has paired,
  then the last row of Devices; the pairing panel opens in its place and carries the tailnet name
  with Copy (an iPad without a Tailscale key can't list the tailnet, so it adds the Mac by name)
  above the code. Then a Needs Attention section only when something does (permissions, Tailscale, a failed
  listener; the row's action is a small glass capsule, `RowAction`), Devices (a "Paired with
  ⟨name⟩" row for 8 s, connected devices, and Paired Devices, which opens in place
  (`menu.showsPairedDevices`): `PairedDeviceRow`s, connected first then newest, at most 5, then
  "Show All N in Settings…"; Remove appears under the pointer and asks again in place with a red
  Remove), Files (`HostFilesSection`: Send File to ⟨iPad⟩…, Received Files, transfers), and a
  footer with the version and two round glass buttons: Settings (⌘,) and More (Restart Safely…,
  Quit; ⌘Q also works through a hidden button). More is a glass `Button` that pops an `NSMenu`:
  a SwiftUI `Menu` draws its own label on macOS and drops the glass. Controls are glass; the
  grouped sections are not. Don't mix in other languages (Control Center tiles, glass cards on the
  glass window, iOS avatars): that was tried and read as no style at all. Paired devices keep their
  hardware model (`TrustedClient.model`, nil for older pairings) for `DeviceSymbol`; older ones
  are guessed from the name. **Pairing**: the button turns into a panel with the digits, a live countdown
  (`pairingCodeExpiresAt`), New Code and Done; Done withdraws the code
  (`TrustStore.cancelPairingCode`) and the controller clears it when its 10 minutes end, so the
  menu never shows a dead code. Screenshots: `--open-menu` (on glass, since the real item often
  hides behind the notch), `--appearance light|dark`.
- **Host setup window** (`HostSetup`/`SetupView` in `UI/SetupWindow.swift`): one compact window,
  six numbered steps that turn into green checks (Screen Recording, Accessibility, Start at Login,
  notifications, Tailscale, Pair a Device with the pairing panel inline) and a progress bar. It
  opens under the menu bar icon at launch until it has been closed once (`setup.completed`),
  whenever Screen Recording or Accessibility is missing at launch, when either goes missing later
  (`HostController.onRequiredPermissionLost`, a 15 s background check), and from More › Set Up
  Casement Host…. Start at Login is on by default there and applied when the window closes.
  Synthetic hosts never open it. Permissions are checked live (`HostPermission`); Allow… asks
  macOS and opens the permission's list, and once asked but still missing the UI says to remove
  Casement Host with − and add it again (a stale TCC entry from another signature, e.g. a Debug
  build: the switch looks on but `AXIsProcessTrusted()` is false). Never run `tccutil` from the
  app. `--open-setup` (DEBUG) shows it as a preview that saves nothing.
- **Curtain** (`curtainRequest` 65, `curtainStatus` 75; gated on `HostCapabilities.curtain`, and a
  client with `Hello.features.curtain` is told of one already up and takes it on): the computer's
  panels go black and its physical input stops; the picture stays the real desktop. Per device,
  `SavedDevice.curtain` (`DeviceStore.setCurtain`, Edit sheet, session menu, optional strip item,
  Mac menu ⌃⌥⌘B); a failure comes back as `unavailable`. **Mac**: `ScreenCurtain` (one per Mac, up
  while any session wants it): a shielding-level black window per screen, left out of the picture
  by window ID (`CurtainWindows`, `ScreenCapture.makeFilter`, `refreshFilter`; measured: luma 0.90
  excluded, 0 included), and `InputBlocker`, an active tap at `.cghidEventTap` on its own thread,
  which drops everything physical; the host posts at the session tap, past it. A device turning it
  off lifts it. Otherwise it never comes down onto the desktop: `reconnectGrace` (60 s) after the
  last device goes the Mac locks, then it lifts; ⌃⌥⌘L at the keyboard does the same at once; quitting
  locks; and `CurtainGuard`, a second copy of the host, locks the Mac if the host dies (killing a
  host with the curtain up therefore locks the Mac). A client on the same Mac is refused.
  **Windows**: `Desktop/ScreenCurtain.cs`: one topmost black window over the virtual screen with
  `WDA_EXCLUDEFROMCAPTURE` and click-through, low-level hooks dropping non-injected input. A locked
  PC can't be unlocked from a device, so the curtain waits with nobody connected, and comes down when
  the PC locks (Windows-L, Ctrl+Alt+Del's Lock); `CurtainGuard` locks if the host dies; unattended
  updates wait while it's up. Checked on Drew-PC with a throwaway client: affinity reads back 0x11,
  WGC still sees the desktop under it, 102 frames in 1.8 s while up, 0 windows and guards after. Limits:
  the pointer still draws over a Mac's curtain; on Windows the curtain is z-band 1 while Start and Search
  are band 6 and a firewall prompt's dim band 4, so those can draw above it
  (`MagSetFullscreenColorEffect` with a zero matrix succeeds unelevated and capture still sees the real
  desktop, the likely stronger cover, but nobody has looked at the panel under it yet); hooks get nothing while an elevated
  window is in front unless the host is elevated; the computer's speakers still play. Debug: DEBUG
  host `--allow-self-curtain` (real capture and input, throwaway identity, no Keychain) lets a
  client on the same Mac raise it. Never run a real non-synthetic Debug host without it from a shell
  when you can avoid it: reading the Keychain raises a prompt on Drew's screen.
- **Host Settings** (`HostSettingsView` and its tabs): one convention, System Settings'. Each tab is
  its own view, and bodies never ask another process anything: `SMAppService.status` read while
  drawing was over half of every tab switch, so `LoginItem` keeps a copy and refreshes it off the
  main thread; `ParakeetModel` checks the disk when its state changes. A row
  says what it is, with at most one short line under it saying what it does; anything longer is
  the section's footer (`Footer`), never a text row inside the section; values and buttons sit on
  the trailing edge, and a button names what it does in the current state (Allow…, Turn On…,
  Show Them…, Settings…; Screen Recording/Accessibility say Allowed or offer Allow…; Remote
  Login/Screen Sharing say On or offer Turn On…). Removing a paired device asks first.
- **Host updates** (`VantageHost/Updates`; Sparkle 2, linked into the host target only, never the client):
  the Windows host's rules on Sparkle's machinery. `UpdatePolicy` (pure, `HostUpdateTests`): first check 2 min
  after launch, then every 24 h, an hour after a failure, none at all while Install Updates Automatically
  (`updates.installAutomatically`, on by default) is off; an unattended install needs no sessions, file
  channels, active transfers, pairing code or open window (menu, Settings, setup), all clear for 5 min,
  counted from when a device last went away too (`HostController.lastConnectionEndedAt`; availability checks
  don't count). `UpdateRow` has every state's wording. `HostUpdater` is Sparkle's `SPUUserDriver` and
  delegate, so Sparkle never shows a window, and the schedule is ours (`SUEnableAutomaticChecks` false, then
  `checkForUpdatesInBackground`): a background update ends in
  `updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)`, whose block waits for the policy, an
  asked-for one in `showReady(toInstallAndRelaunch:)`. Quitting with a background update staged installs it
  without relaunching. A copy that can't replace itself (translocated, read-only volume, unwritable folder:
  `canReplaceItself`) only reads the feed (`checkForUpdateInformation`), so it never asks for a password, and
  offers Download…. A latest release with no `appcast.xml` (a 404) counts as up to date. **Keys**: the public
  half is `SUPublicEDKey` in `VantageHost/Info.plist`, from the build setting `CASEMENT_UPDATE_PUBLIC_KEY`; the
  private half is in Drew's login Keychain (service `https://sparkle-project.org`, account `ed25519`), read by
  `generate_appcast`, and is never printed or copied into the repo. Sparkle can't take a key at run time, so a
  test key goes on the xcodebuild line. `SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction` sign the feed
  and check the download before unpacking it; `SUSignedFeedFailureExpirationInterval` 0 removes Sparkle's 20-day
  way out of a bad feed signature, so a lost key means every copy needs a download by hand, as on Windows.
  Sparkle compares `CFBundleVersion`, so every release raises `CURRENT_PROJECT_VERSION`; hosts before 1.4 have
  no updater and need one download by hand. UI: General › Updates, and an Update section in the menu when one
  is waiting; restarting with a device connected or files moving asks first (`UpdateRow.restartWarning`).
  Debug: nothing runs on a Debug or synthetic host without `--update-feed URL`; `--update-soon` skips the waits,
  `--update-check-now` checks as if asked, `--update-restart-when-ready` presses the button, `--preview-update
  uptodate|checking|downloading|preparing|ready|installing|manual|failed|off|none` shows a state with no
  updater behind it. A relaunch loses the command line, so a DEBUG host also reads arguments from
  `casement-host-test-arguments` beside its bundle; without it a relaunched test copy would come up as a real
  host on 47820. Sparkle writes `SU*` keys to the host's real defaults domain even from a test copy (same bundle
  id), so remove them after a test. An update test host (`--synthetic-capture` + `--update-feed`) uses a
  throwaway identity and stays out of the Keychain.

## Reboot, lock screen, and login window (what is and isn't possible)

- **Reboot**: enable "Start Casement Host at login" (Settings → Reboot). After login the host relaunches
  and the client reconnects on its own (it retries for ~10 minutes and again when foregrounded).
- **Restart guard**: `RestartGuard` (host) inspects the quit Apple event's `kAEQuitReason`; while a
  device is connected, a restart/shutdown/logout (including Software Update's) gets a confirmation
  alert and `.terminateCancel` aborts it. `sudo reboot` and panics can't be caught. Toggle in host
  Settings → Reboot. The Windows host can only hold a restart on Windows' own
  restart screen (see Restart guard in [windows-host.md](windows-host.md)); a forced one goes ahead.
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
  shortcuts and password in [input.md](input.md)). That also works at a logged-out login window if the Mac is
  reachable, but not at FileVault pre-boot.
