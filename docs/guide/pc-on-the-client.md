# Windows hosts on the client

Part of the project guide; [`CLAUDE.md`](../../CLAUDE.md) has the naming, layout and repo rules this assumes.

- **Windows hosts on the client**: what the host runs is `ClientSession.hostPlatform` in a session,
  else `SavedDevice.platform` (from `os`; "Windows" = PC, anything else a Mac). `DeviceStore.recordPlatform`
  stores what a session or the list's availability probe heard (`recordPlatforms`, nil from an old
  host = Mac), so the list shows the `pc` symbol and a PC's settings before it is next opened;
  `TailscaleDevicesSheet` adds PCs as "Windows" (`TailscaleDevice.Platform.isSupported` = Mac or
  Windows). **Names**: every user-facing string naming the host goes through `HostNoun`
  ("Mac"/"PC", `the`, `thePossessive`, …): pairing prompt, `MacScreenNote`, lock banner (a locked PC
  says "Unlock it at the PC, or sign in with Remote Desktop"; no password button), session menu,
  Transfers, `FileLink` failures, device list and Mac detail, the Mac app's Session ▸ PC submenu
  and toolbar. App Intents still say Mac; widgets and the control say "Mac or PC". **Shortcuts**: the strip's shortcut items are
  slots (`HostShortcut.forItem`): spotlight = ⌘Space / Search (Win S, kVK 0x01 + ⌘), missionControl
  = ⌃↑ / Task View (Win Tab), applicationWindows = ⌃↓ / Switch Apps (Alt Tab, 0x30 + ⌥),
  showDesktop = F11 / Win D; `startMenu` (the Windows key alone: 0x37 down and up) and
  `taskManager` (Ctrl Shift Esc: 0x35 + ⌃⇧) exist for a PC only. The Windows host maps ⌘ to the
  Windows key literally, so shortcuts are sent as written. `StripItem.label(for:)`/`detail(for:)`/
  `symbol(for:)` name an item per host (nil = any host, for the default editor);
  `keycapText(for:)` draws a PC's modifiers as "ctrl"/"alt"/"win"; strip modifiers are always sent
  as labelled. `StripItem.unavailable(on:)` joins `unavailableHere` with what the host can't use
  (a Mac: Start, Task Manager; a PC: Type Password) for the strip and the per-device
  editor; the default editor shows everything. Both standards gained Start and Task Manager
  (`standardHistory`, `macStandardHistory`). **Audio and display fitting** are gated on what the
  host advertises, not its platform: a PC (Casement Host 1.3+) sends `HostCapabilities.audio` and
  answers `audioRequest` like a Mac, so the strip item, session menu and Mac menu bar show "PC
  Audio" (`label(for:)`; dimmed with `MacAudioToggle.unavailableReason` on a host without audio),
  and the Mac client's detail pane has Play PC Audio (`SavedDevice.playMacAudio`). The Edit sheet's
  `useVirtualDisplay` toggle shows for a PC as "Fit the PC's display to this screen": the same
  `SelectDisplay.useVirtualDisplay` + `fitViewport`, which the Windows host answers by switching the
  display mode (`canManageVirtualDisplay`) and restoring it afterwards. **Mac-only features** a PC
  hides: Type Password and saved passwords, Log In with Screen Sharing
  (`ScreenSharingPassword.canLogIn`), home address, codec choice; dictation on the PC falls back to
  this device since a PC advertises no `dictationEngines`. Sleep Display and Lock stay. **⌘ acts as Ctrl** (`SavedDevice.commandSendsControl`, nil = on; Edit sheet toggle
  for a PC): `KeyRemap` swaps 0x37↔0x3B, 0x36↔0x3E and the ⌘/⌃ bits for keyboard keys only (the
  iPad's hardware keyboard in `InputController.key(hidUsage:)` + `RemoteInteractionView.heldModifiers`,
  the Mac client through `KeyTranslator`, where a PC uses its own setting instead of Settings' Swap ⌘
  and ⌃, and ⌘V paste-through watches for Ctrl+V); strip modifiers and shortcuts never go through it.
  Test: `KeyRemapTests`. Checked against the Windows synthetic host's input log (`--input-log`):
  every PC shortcut and remapped ⌘/⌃ key arrives as the scan codes above.
