# Casement Host for Windows

Part of the project guide; [`CLAUDE.md`](../../CLAUDE.md) has the naming, layout and repo rules this assumes.

## Windows host

`WindowsHost/` is a Windows host for the same client, in C# on .NET 10 (LTS), speaking the wire
protocol in `docs/research/windows-host-protocol.md` (the Swift code wins where they differ).
`WindowsHost/README.md` has the layout and the remote-PC workflow. The .NET SDK is at `~/.dotnet`,
not on `PATH`: `export DOTNET_ROOT=$HOME/.dotnet PATH=$HOME/.dotnet:$PATH DOTNET_CLI_TELEMETRY_OPTOUT=1`
(always opt out of telemetry: Drew's firewall flags the SDK and test runner calling home).

- `src/Vantage.Protocol` (cross-platform, builds and tests on the Mac): `Wire/`, `Messages/`
  (records with the Swift key names, a source-generated JSON context, converters for
  `DisplaySelection` `_0`, `KeyModifiers` as a number, 2001-based dates, uppercase UUIDs),
  `Transport/FramedConnection` (one writer; control lane, then a video lane that refuses whole
  P-frames past 2 queued frames or 2 MB and announces when it drains so the session forces an
  IDR, then a bulk lane for chunks and clipboard; keepalive 5/2/3), `Auth/` (NSec Ed25519, the
  111-byte transcript, fingerprints, `PairingCodes`, file-backed trust and identity stores over
  `IProtectedStorage`), `Files/` (`FileTransferEngine`, `FileNames` with the Windows rules,
  `AttachTokenRegistry`), `Video/` (Annex-B ↔ AVCC/HVCC, parameter sets and IDR detection for
  H.264 and HEVC, chosen by `VideoCodec`; the codec-less overloads are H.264), `Adaptive/`,
  `Input/` (`WindowsInputTranslator`: kVK → set-1 scan codes, chords, held state, scroll
  remainder, point → virtual-desktop pixels; only `IInputInjector` calls `SendInput`), and
  `Host/` (`HostListener`, `HostSessionCore`, the session's modules named below, and the platform
  interfaces: `IScreenSource`, `IVideoEncoderFactory`, `IInputSink`, `IClipboard`,
  `IHostStatusSource`, `IPowerControl`, `IPeerDirectory`, `IFileStore`).
- `src/Vantage.SyntheticHost`: the real session logic with a looping pre-encoded clip
  (`assets/test-clip/clip-1600x1000.h264`, IDR every 30 frames; a keyframe request jumps to the
  next one), a JSONL input log (wire events plus the Windows events the translator would inject),
  an in-memory clipboard, and the Mac DEBUG host's flags (`--port`, `--pairing-code`,
  `--exit-after`, `--display-asleep`, `--capture-fails-for`, `--send-file-on-connect`,
  `--receive-folder`, `--log-input-events`) plus `--platform windows|macos`, `--input-log`,
  `--clipboard-text` (sent at stream start), `--state-dir` (trust store; default
  `$TMPDIR/VantageSynthetic/WindowsHostState`), `--pairing-code-rearm <s>`, `--cursor-shapes`, `--admin-apps-blocked`, and `--no-audio`
  (it otherwise offers the Mac synthetic host's −18 dBFS chime as the PC's sound). Loopback is always
  allowed. **A fixed pairing code works like the Mac's: one pairing uses it up** (and five misses
  burn it); `--pairing-code-rearm 3` shows it again 3 s later, which the interop suite needs.

- **Admission** (`Host/SessionAdmission`, the Mac's `HostSession.handshake`): one module turns
  `hello` + trust + pairing code + host identity into the `challenge` (`Challenge(peerTailnetName)`),
  then the `authenticate` into an `AdmissionVerdict` (`Judge`: version, the signature over the
  transcript the device chose, pairing accepted/incorrect/expired with `Delay` for the 1 s pause and
  the five-miss burn in `PairingCodes`, then a `SessionKind`: availability check, files-only, or
  screen, or `Denied` when capture isn't supported or a files-only hello takes no files) and writes
  the `authResult{ok}` for what was admitted (`Accept(kind, token, displays)`: readiness, the
  files-only capabilities, or the full set). `HostSessionCore.HandshakeAsync` only exchanges the
  messages, does the whois and the display wake, and sets itself up as what it was admitted as.
  Every message is built exactly as before: `GoldenVectorTests` and the interop suite hold it to
  that. Tests: `SessionAdmissionTests` (a code that ran out), with `HostListenerTests` for pairing,
  burning, probes, version mismatches, purpose binding and files-only over loopback.
- **Capture lifecycle** (`Host/CaptureSupervisor`, the Mac's rules in `HostSession`): one module
  keeps a picture coming for a screen session. Events go in (`DeviceAsked`, `Started`,
  `StartFailed`, `CaptureStopped`, `FrameArrived`, `StatusChanged`, `SleepAsked`/`WakeAsked`,
  `AdmitsInput`, `Tick`) and `CaptureStep`s come out (`Start` a target, `Stop` a capture that
  never framed, `SendStatus`, `WakeDisplay`, `WakeDisplayAndWait`, `ForceKeyframe`), which
  `HostSessionCore.ApplyAsync` runs in order on the session queue, reporting each start's outcome
  back. It holds what the device wants, one start at a time with a pending takeover, the display's
  sleep state (learned from the events, so it lags a change the session hasn't relayed yet), the
  input-while-asleep rule (releases go through; other input wakes the display at most once a second
  and is dropped, none of it in the 2 s after Sleep Display), the retry schedule (0.5 s doubling to
  5 s while the display is awake, each wait counted from the end of the attempt before it, so a
  start that takes seconds to fail doesn't use the wait up, whether the clock, Wake/Retry (which
  starts the backoff over) or a change of host state began it; `isScreenUnavailable` after 3 s) and
  the 5 s no-frame rule.
  `WantsTicks` says when the session must tick it every 250 ms. A restart tries the display it was
  on first, **keeping the codec it streamed** (as the Mac does; it used to choose again), then the
  device's own `selectDisplay`. It does no I/O, so `CaptureSupervisorTests` drive it on a
  `FakeTimeProvider` (sleep and wake, the backoff and the notice, started but no frames);
  `HostListenerTests.SleepingDisplayIsReportedAndWakeBringsThePictureBack` and
  `MissingPictureIsExplainedUntilFramesReturn` still prove the wiring over loopback.
- **Video pipeline** (`Host/VideoPipeline`, one per capture): captured frame → `videoConfig` and
  `videoFrame` on the connection's video lane (`IVideoLane`, which `FramedConnection` implements).
  It owns the adaptive controller (frame rate and max QP to the capture and encoder, bitrate from
  `qualityFeedback` and backlog, the input hold), idle suppression (`HostSessionCore.IdleDirtyRatio`,
  never over a due keyframe), latest frame wins with one encode in flight, keyframes when due
  (start, `requestKeyframe`, a dropped P-frame, output that didn't parse) and only once the lane
  has drained, Annex-B → AVCC/HVCC with the parameter sets pulled out, `videoConfig` before an IDR
  whose sets changed, no frame before the first `videoConfig`, and P-frames dropped while the lane
  is backed up. `videoFrame.sequence` carries on across captures (`NextSequence`). The encoder's
  one-callback-per-encode rule is no longer load-bearing: an encode with no word back within 1 s
  (`EncodeStallLimit`, on the session's `TimeProvider`) is given up on and a keyframe forced, so a
  lost callback can't leave one frame "in flight" and the picture frozen for good (the Mac host had
  that bug). Every `EncodeAsync` carries an `encodeId` and the sink call that answers it
  (`OnFrame`, `OnFrameSkipped`) carries it back, so an answer from an encode already given up on
  is dropped without touching the encode that replaced it, its timer or its keyframe (Media
  Foundation reports an abandoned input as skipped about a second later, right when the
  replacement is in flight), and an encode that never answers at all shifts nothing. A stall
  timeout acts only when it was armed for the encode still in flight and that encode's deadline
  has passed; one already queued behind the answer that finished its encode does nothing. A forced
  keyframe that comes back skipped makes the next encode an IDR again. The
  session only makes the encoder and hands it over. **Quality presets** (`selectDisplay.quality`,
  the Mac's numbers in `QualityProfile.For`): Balanced (`auto`) 30/60 fps, max QP 32 text / 44
  motion; Fluid (`motion`) 60 fps always, 36/44, no idle pass; Sharp Text (`text`) 30/60, 28/38,
  bitrate floor 6 Mbit/s; `maximum` (not offered) 24/34, floor 10 Mbit/s. A `selectDisplay` that
  differs from the running one only in `quality` changes it in place (`CaptureSupervisor.QualityChanged`,
  `VideoPipeline.SetQuality`): no new capture or `streamConfig`. **Idle sharpening**: a still screen
  sends nothing, so the soft frame motion's ceiling left would stay; every encode other than the
  pass itself arms a 300 ms timer (`IdleSharpenDelay`), and when it runs out with nothing in flight
  or pending the last frame is encoded once more as a P-frame under the preset's idle ceiling (24
  Balanced, 20 Sharp Text, 18 `maximum`); the next encode puts the mode's ceiling back first. The
  ceiling now reaches the encoder just before an encode, not when the mode flips. Scrolling re-arms
  it every frame, so it costs nothing while the screen moves; on the Mac a 2560×1600 text refine
  near QP 24 cost ~0.2–0.6 MB once and lifted luma PSNR by 3–9 dB. Whether `AVEncVideoMaxQP` takes effect
  mid-stream on NVENC, Quick Sync and AMF is unchecked. Tests: `VideoPipelineTests` (scripted encoder
  that holds chosen encodes, fake clock: a lost answer, a late answer, a timeout queued behind an
  answer, the idle pass), with `HevcSessionTests`, `HostListenerTests.StreamStartsWithStatusConfigThenAnIdr…`
  and `DisplayFittingTests.AQualityChangeAloneDoesNotRestartTheStream` over loopback.
- **Scroll signs** (`WindowsInputTranslator.Scroll`): the Mac host's. Lines: WHEEL = +deltaY,
  HWHEEL = −deltaX; continuous deltas arrive negated, so WHEEL = −deltaY, HWHEEL = +deltaX. Until
  2026-11-22 continuous deltas took the line signs and trackpad scrolling ran backwards from every
  client (`MacTrackpadAndWheelScrollTheSameWay`).
- **Scroll momentum**: an iPad flick glides on a PC as on a Mac. `HostSessionCore` wraps the input
  sink in `MomentumInputSink`, which plays `ScrollMomentum` (the Mac's numbers: 1/60 s frames,
  0.998 per ms, ≥ 60 pt/s to start, ends under 10 pt/s or at 3 s) as momentum scrolls through the
  translator's wheel conversion, ticking on the session's `TimeProvider` and queue (frames due by
  the clock, so Windows' 15.6 ms timer doesn't slow it). The next scroll, a button press,
  `releaseAll` and teardown end it. The synthetic host's input log shows the frames (`momentum`).
  Tests: `ScrollMomentumTests`, `HostListenerTests.FlickGlidesUntilTheSessionEnds`.
- **Long text is pasted**: a `textInput` over 16 UTF-16 units (dictation, a paste from the iPad)
  goes through the clipboard as on the Mac, since Electron/Chromium apps and some games drop
  `KEYEVENTF_UNICODE` bursts; 16 or fewer are typed. `ClipboardPaster` (one per listener) calls
  `IClipboard.WriteForPaste` (one clipboard open: save every memory-block format,
  `ClipboardFormats.CanSave`, then the text marked out of Win+V history, cloud clipboard and
  clipboard managers), sends `PasteChord` (V with Control: Ctrl 1D, V 2F through the translator),
  and after 1.5 s (the Mac's `pasteRestoreDelay`, on the session's `TimeProvider`) calls
  `RestoreAfterPaste`, which puts the saved formats back only while the sequence number is still
  the paste's (a copy made meanwhile wins). Pastes in a row keep the first one's saved clipboard;
  stopping the listener restores at once. Neither write reaches the client (the window owns the
  clipboard after both; never a "skip the next change" flag). A clipboard another app holds falls
  back to typing, logged once. The synthetic host's input log shows `pasteWrite`, the chord's two
  `key` entries (`key 1D down`, `key 2F down`, …) and `pasteRestore`. Tests: `ClipboardPasteTests`,
  `ClipboardFormatsTests`, `HostListenerTests.LongTextIsPastedAndTheClipboardComesBackUnheard`.
- **Transfers on the PC** (the Mac's menu Files section and ring): `HostTransferList`
  (`Platform/Files/HostTransfers.cs`, UI thread only) keeps a `HostTransfer` per id from the
  listener's `FileSendQueued` (a send waiting its turn), `FileTransfer` and `FileTransferPaused`;
  speed and time left are the Mac's `record` (≥ 0.5 s samples, 0.6 old + 0.4 new), and
  `HostTransferText` words everything as the Mac does ("12.4 MB of 48.0 MB · 6.20 MB/s · 5 sec
  left", "Paused at 45% · resumes when Drew's iPad reconnects", "Received from Drew's iPad · in
  Downloads"; sizes 1,024-based and cut like Explorer's). The listener reports a send's `Finished`
  itself (the engine's is lost when the connection closes under it) and a cut-off send or receive
  as `FileTransferPaused` instead of a failure, so no "Couldn't send" notification; the next
  `Started` with that id carries the row on, and one not back by `ResumesBefore` (1 h) fails then.
  `CancelTransfer` also forgets a paused send and deletes a paused receive's partial. The tray icon
  becomes a ring with an arrow while files move (`TrayGlyph`, drawn per update at the taskbar's
  size into a DIB for `CreateIconFromResourceEx`, 24 steps, cached; down if anything arrives;
  paused files left out), the tooltip and the panel's status say "Receiving Report.pdf, 45%";
  the menu lists the newest 5 (name: detail, Cancel ⟨file⟩, Show ⟨file⟩ in folder) plus Open
  Receive Folder; the panel's Transfers card (newest 4) and Settings › Files (all, Cancel All with
  a confirmation) share `TransferRows`. Finished rows stay 60 s; the app redraws progress at most
  every 250 ms. Tests: `HostTransferListTests`, `TrayGlyphTests`, `TrayMenuModelTests`,
  `HostListenerTests.ACutOffSendIsPausedNotFailed…`, `CancellingAPausedSendForgetsIt`.
- The Windows platform, CLI and WinUI app (`src/Vantage.Host.Windows*`) are built on the PC.
- **Host UI on Windows** (`src/Vantage.Host.Windows`): one design language, Windows 11 Settings' and
  Quick Settings', never a Mac app ported over. **Settings window**: Mica across the whole window
  (NavigationView's rounded content panel is made transparent in `App.xaml`: a card on a panel on a
  window was the box in a box); `PageShell` is every page's frame (a title that stays put above a
  scrolling column, left-aligned, ≤ 1000 wide); rows are `SettingsCard`/`SettingsExpander`
  (CommunityToolkit, MIT), label and description on the left, control on the trailing edge, 4
  between cards, 24 above a section heading, and `CardStyle` only for free-form content (the code,
  transfer rows). The pane is adaptive (names from 900 wide, icons from 640, overlay below; minimum
  window 560 × 480). Buttons use sentence case; the remote device is "device", never "iPad"; no
  settings search (about ten settings on four pages don't need it). **Tray panel**: one surface,
  flat on the acrylic, with an edge-to-edge footer band; no cards. Show pairing code is the accent
  button only while nothing is paired, then a plain row beside Paired devices; `Fit` measures the
  client area (the window's border isn't part of it) and caps at the screen, with the body
  scrolling above the footer. **Pairing** lives on Devices, with the tray as the fast path;
  `PairingPanel` is shared by both and carries the name to add the PC by; a code that runs out or
  is dismissed with Done is withdrawn (`PairingCodes.Withdraw`), so a dead code never shows. Lists
  are rebuilt only when what they show changes, since `StateChanged` fires several times a second
  while files move and a new row would drop keyboard focus. **Looking at it**: a composed WinUI
  window copies off this PC's screen as black (PrintWindow too, and the build before this one), so
  DEBUG flags render the XAML in-process (no backdrop, frame or flyouts): `--synthetic --capture
  out.png --open-settings general|devices|files|display|about` or `--open-panel`, plus
  `--preview-state empty|one|many|transfers|pairing|problem`, `--window-size WxH`, `--pane-closed`,
  `--expand`, `--theme light|dark` (`PreviewFixtures.cs`: made-up devices and a made-up tailnet).
  `--synthetic` copies register under their own instance key, so they run beside the installed host.
- **Updates** (`Platform/Updates`, `Protocol/Updates`; our own, not Velopack, because the install
  folder must keep its path: the Run value, administrator task, firewall rule, shortcut and tray
  choice all name it). `HostUpdater` fetches `windows-update.json` and `.sig` from
  `releases/latest/download/` (`ReleaseFeed`). A manifest counts only with an Ed25519 signature
  (`UpdateSignature`, domain-separated) from `ReleasePublicKeyHex`, a zip only with the signed SHA-256
  and size, and a staged copy only if its exe says it's the version on offer; only a strictly newer
  version is offered (`UpdateVersion.IsNewer`), and a release without a manifest means nothing's on
  offer. **The private key** is `%USERPROFILE%\.casement\update-signing-key` on the PC, outside the
  repo; lose it and every installed copy needs a manual download. The zip unpacks to `<install>.update`,
  and `UpdateInstaller` swaps: the host starts the staged exe with `--finish-update <pid>` and waits for
  its `swapper-running` file before quitting (`StartSwapAsync`), so a release too broken to run
  leaves the host up; a running exe can't replace itself, so the swapper renames the install to
  `.old`, copies itself in, starts it, and waits ≤ 120 s for the new host to delete `pending`
  (`MarkHealthy`, once it got as far as listening). No word: back to `.old`, and `skip-version` skips
  that version until Try again. The target folder comes from where the swapper is (it must sit in a
  `.update` folder), never from the command line. `UpdatePolicy`: first check 2 min after launch, then
  every 24 h, none while `InstallUpdatesAutomatically` is off; an unattended install needs no
  sessions, file channels, active transfers, pairing code or open window for 5 min (a device that just
  dropped is usually reconnecting). Debug builds don't update unless given a feed. UI: General ›
  Updates (`UpdateRow` has every state's wording) and a Restart row in the tray panel, which sends
  anyone connected to Settings to confirm. Release files: `scripts/make-release.ps1 -Version x.y`
  (zips, checksums, signed manifest; bump the csproj first), uploaded to `host-x.y`; a draft is
  invisible to `releases/latest`. Debug: `--preview-update
  uptodate|checking|downloading|ready|manual|failed|rolledback`; `--update-feed URL --update-key HEX
  --update-soon` runs it for real against a test feed. Tests: `UpdateManifestTests`, `HostUpdaterTests`.
- **Administrator apps**: UIPI drops input a non-elevated process sends to an elevated window, and
  `SendInput` still reports success; Task Manager is always elevated on Windows 11. Before a press,
  `SendInputInjector` checks the target (`ElevatedWindows`: the root window under a click, or the
  foreground one for a key; its process's `TokenElevation`) and raises `ElevatedWindowBlocked`, which
  the app turns into a notification while a screen session is up. The device hears it too:
  `capabilities.canControlAdminApps` says whether input reaches such apps (the host is elevated or
  the desktop helper is connected, asked as each session is admitted; null from synthetic hosts and
  Macs), and `BlockedAppChanged` follows each press (the app's title when it went to an elevated
  window, null once one reaches an ordinary window; moves, scrolls and releases change nothing),
  which `SessionStatusMonitor.SetBlockedAdminApp` turns into `hostStatus.blockedAdminApp` while the
  session is unlocked and no secure desktop is up. The client words the banner and asks before
  sending Task Manager to a host that can't control it. The synthetic host's `--admin-apps-blocked`
  says false and pretends Ctrl+Shift+Esc opened Task Manager (key presses then report it, a click
  clears it). Start at login (the Run value) is turned on once at the first launch of a Release
  build (`StartAtLoginSettled`).
- **Casement Host Service** (ADR 0006; `src/Vantage.Host.Windows.Service` → `CasementHostService.exe`,
  `Platform/DesktopHelper`, `Protocol/DesktopHelper`): General › Control administrator prompts and
  apps runs `CasementHostService.exe install` from the host's folder as administrator
  (`HelperInstall.RunElevatedAsync`; one UAC prompt at the PC). That copies it to
  `%ProgramFiles%\Casement Host Service`, makes an Ed25519 key (seed in `%ProgramData%\Casement Host
  Service\helper.key`, SYSTEM and Administrators only, no inheritance; public half `helper.pub` beside the
  exe), registers the LocalSystem service `CasementHostService` (auto start, restart on failure) with
  `sc.exe`, and deletes the old elevated task. `uninstall` (the switch off, or the Inno uninstaller's
  `RemoveDesktopService`, Windows asking only when the service exists) stops and deletes it and both
  folders. `HostService` keeps one `helper` process (`HelperLauncher`: its own token duplicated with
  `TokenSessionId` set, `CreateProcessAsUser` on `winsta0\default`) in the console session while
  `WTSQueryUserToken` says someone is signed in to it, and none otherwise (so never at the sign-in screen
  after a restart); a helper that exits within 10 s backs off 2× up to 1 min. The helper
  (`SecureDesktopHelper`) serves `\\.\pipe\CasementHostDesktop-<session>`: DACL SYSTEM + the session's
  user (read/write, not create-instance), one instance, `FirstPipeInstance`, and it refuses a client from
  another session or that isn't `VantageHost.exe`/`VantageHostCli.exe`. The host (`HelperClient`,
  retrying every 3 s while the service is installed) sends `HelperHello` with a nonce and trusts only a
  `HelperWelcome` signed over `HelperProof.Transcript(session, nonce)` with `helper.pub`'s key, so
  something squatting on the name gets nothing. Then the helper reports the input desktop (Default,
  Winlogon = secure, Other) on change; input goes to it (`SendInputInjector`: while the secure desktop
  has the input, and from a press aimed at an elevated window until one lands elsewhere; it injects on
  a thread `SetThreadDesktop`'d to the input desktop, through the same `InputBatch` as the host); and
  `WindowsScreenSource` starts `HelperCaptureStream` instead of WGC while the secure desktop is up (a
  switch either way ends the running capture, so the supervisor restarts the right one, ~0.5 s). The
  helper's `DesktopDuplicator` is DXGI desktop duplication on a thread on the input desktop: the whole
  screen first, then dirty and moved rects, copied off one staging texture and cut into ≤ 8 MB messages
  (`HelperFrames.Split`, only the last `IsLastPart`); the host paints them with `UpdateSubresource` onto
  a canvas and hands the encoder a pooled copy. The pointer isn't in those frames (devices that draw
  their own still show it). While it's connected `SessionStatusMonitor` reports no secure desktop and
  `hostStatus.controlsSecureDesktop`, so the device drops the "unlock it at the PC" banner. Both sides
  refuse another `HelperPipe.Version`; an installed service is only replaced by turning the switch off
  and on (not by the host's updater yet). Logs: `%ProgramData%\Casement Host Service\{install,service,helper}.log`.
  Published single-file, self-contained and partially trimmed (~13 MB) by `scripts/publish-service.ps1`,
  which `publish.ps1` and `make-release.ps1` call, into the host's folder. Users of the old task
  (`HostSettings.ControlAdminApps`, `AdminLaunch`, `Program.ShouldRelaunchElevated`) keep it until they
  turn the switch off and on; the relaunch is skipped once the service is installed. Test:
  `HelperPipeTests` (the pipe format). Live checks on the PC: see the status line below.
- **Installer** (`installer/CasementHost.iss`, Inno Setup 6.6+; `scripts/make-installer.ps1`, called by
  `make-release.ps1`): `Casement-Host-Setup-x64.exe`/`-arm64.exe` keep the same names every release so the
  READMEs can link `releases/latest/download/`; the zips stay, because the signed manifest points the
  updater at them. Per-user, no UAC, always `%LOCALAPPDATA%\Programs\Casement Host` (a folder the updater
  can replace). The uninstaller lives in `Casement Host Uninstall` beside it, since a swap replaces the
  whole install folder and would delete one inside, and uninstall removes the folder as a whole
  because it can hold files Setup never recorded. Setup stops a running copy (`taskkill`; one running as
  administrator can't be, so it says to Quit) and repoints an existing Run value, but never creates one:
  the host's first launch does. The last page lists the steps to connect and offers Tailscale's download
  only if it isn't installed. `InstallRegistration.SyncVersion` keeps Installed apps' version right after a
  self-update. Never change the script's `AppGuid`: it's how a new Setup finds the old copy, and
  `InstallRegistration.KeyPath` names it too. `-TestInstall` builds a copy with its own name, shortcut and Run
  value, so the script can be tried on a PC with the real host. Tests: `InstallRegistrationTests`.
- **Finding the host again** (a copy from the zip has no Start menu entry otherwise): a Release launch writes `Casement Host.lnk`
  into the user's Start menu Programs folder (`StartMenuShortcut`, `IShellLinkW` through built-in
  COM interop; rewritten when the folder moved, so Start › "Casement" opens the running copy's
  window through the single-instance redirect). The first time the settings window is closed, a
  notification says the host is still running and where its icon is (`AppController.OnWindowHidden`,
  `HostSettings.TrayHintShown`). Windows 11 hides a new tray icon behind the ^ and offers no API
  to promote it; Explorer keeps that choice per executable in `HKCU\Control Panel\NotifyIconSettings\<id>`
  (`ExecutablePath`, `IsPromoted`) and applies a change at once, so General › Show the icon next to
  the clock reads and writes that value (`TrayIconVisibility`; undocumented, so no entry means the
  switch is disabled, never an error). The app's version in logs and About is
  `WindowsHostRuntime.AppVersion` (the informational version), not the protocol's `HostVersion`.
- **Restart guard** (the Mac's `RestartGuard`; `Desktop/RestartGuard.cs`, pure `RestartGuardPolicy`):
  Windows has no veto, so while a screen session is up the guard registers a block reason
  (`ShutdownBlockReasonCreate` on `MessageWindow`, a hidden top-level window: message-only ones
  never get `WM_QUERYENDSESSION`) naming the device ("Drew's iPad is connected through Casement
  Host. …", or "2 devices …") and answers `WM_QUERYENDSESSION` FALSE, so an interactive sign-out,
  restart or shutdown (Windows Update's too) stops on Windows' "This app is preventing restart"
  screen, where the person at the PC cancels or goes ahead. `ENDSESSION_CRITICAL` (`shutdown /f`)
  and `ENDSESSION_CLOSEAPP` (an installer) are never held. `SetProcessShutdownParameters(0x3FF)` asks
  the host first. On `WM_ENDSESSION` TRUE the runtime logs the kind (restart, sign-out
  for `ENDSESSION_LOGOFF`, close-app), stops the listener (waiting ≤ 4 s of Windows' ~5) and the
  app quits. Never send `disconnect` there: connections just drop, as on the Mac, so the iPad keeps
  retrying and reconnects once the host is back after sign-in. The runtime wires it (`Listener.Changed` →
  `Update`), so the console host has it too; synthetic runs never make one. General › Ask before
  restarting while a device is connected (`HostSettings.AskBeforeRestart`, on by default). Settings
  with a non-false default (`AskBeforeRestart`, `NotifyOnArrival`, `AfterArrival`) are `set`, not
  `init`: the source-generated reader gives an `init` property the file lacks `default`. Tests:
  `RestartGuardTests` (incl. `SettingsMissingFromTheFileKeepTheirDefaults`). The real messages and the restart screen still need a check on the PC.
- **HEVC** (the Mac's `preferredCodec ?? .hevc`): `MfVideoEncoder` (was `MfH264Encoder`) encodes
  H.264 or HEVC with the same MFT plumbing and low-latency settings; HEVC is `MFVideoFormat_HEVC`,
  Main 8-bit 4:2:0 (`eAVEncH265VProfile_Main_420_8`), no CABAC switch. `MediaFoundationEncoderFactory`
  probes once (`MFTEnum2`, any adapter) and advertises `[hevc, h264]` when the PC has an HEVC
  encoder, else `[h264]`; Windows ships no software HEVC encoder, so a failure on the capture GPU
  makes `Create` throw, `HostSessionCore` falls back to H.264 for that stream, and the factory stops
  offering HEVC. `HostSessionCore.ChooseCodec`: the client's `preferredCodec` if the host has it
  (and the client's `supportedCodecs` lists it), else the host's first; `streamConfig` and
  `videoConfig` name what was chosen, HEVC's `parameterSets` are `[VPS, SPS, PPS]` from the IDR (or
  `MF_MT_MPEG_SEQUENCE_HEADER`), and IRAP slices (16–21) count as keyframes. `--codec h264|hevc`
  offers and streams only that codec; About shows "NVIDIA HEVC Encoder MFT (hardware)". The
  synthetic host stays H.264. Checked on the RTX 5070 Ti at 3840 × 2160, 40 Mbps CBR: in-band
  AUD/VPS/SPS/PPS on every IDR, two IDR_W_RADL slices, TRAIL_R P-frames, Main profile, High tier,
  level 5.1 (NVIDIA ignores the ICodecAPI profile and B-frame keys, as for H.264; the media type
  sets them). Tests: `HevcVideoTests`, `HevcSessionTests`, `NalUnitsTests`, `EncoderNameTests`. An
  iPad decoding the PC's HEVC still needs a device check.
- **Dirty regions before 24H2** (the Mac's SCK dirty rects): WGC reports dirty rectangles only
  from Windows 11 24H2 (build 26100, `DirtyRegionMode.ReportOnly`); older Windows used to say 1.0
  for every frame, so `AdaptiveController` never chose text mode and idle frames were never skipped.
  There `WgcCaptureStream` runs `FrameComparer` instead: a compute shader (`Gpu/FrameCompare.hlsl`,
  embedded, compiled once at runtime with Vortice.D3DCompiler, `cs_5_0`) compares each delivered
  frame with the last in 32 × 32 blocks, writes the changed pixels into its own R32_UINT copy of
  the previous frame (no extra full-frame copy) and one byte per block (8 KB at 4K) to a ring of 8
  staging textures. The capture thread only queues it and flushes; `CapturedTexture.DirtyRatio`
  reads the map when the core first asks (`DO_NOT_WAIT` polls for 4 ms, then waits; 1 if the slot
  was reused). Pure rules in `FrameChange`: no changed block = exactly 0 (the core skips it), else
  the changed share but at least 0.0005 (a caret blink at 4K–8K stays above `IdleDirtyRatio`);
  alpha is ignored; the first frame is 1. Every sequence on the shared context holds
  `GpuDevice.LockContext()`. `--dirty-regions native|compare|none` (default native, which falls
  back to compare; `run-dev.ps1 -DirtyRegions`); the log says `dirty regions compare`, then
  `dirty compare on …` every 10 s, and the session logs each `video mode text|motion` change; the
  Display page shows the source. Checked on the RTX 5070 Ti at 3840 × 2160 with compare forced: a
  window repainting the same pixels at 10 Hz sent no frames (76 identical frames skipped; `none`
  sent all of them), a 10 Hz counter went to text mode at ~18 KB/s with ratios 0.0005–0.003,
  readback 0.2 ms mean; WGC here sends nothing at all for a truly still screen. Tests:
  `FrameChangeTests`, `FrameComparerGpuTests` (skipped without a D3D11 device; prints the 4K cost,
  ~0.65 ms per frame with a synchronous readback). A real 22H2/23H2 or Windows 10 PC is unchecked.
- **Display fitting** (the Mac's virtual display; Windows has none without a signed Indirect Display
  Driver): `selectDisplay{fitViewport, useVirtualDisplay: true}` switches the main display's mode and
  scale. **Scale** (`DisplayScales`): Windows App (RDP) makes its own session at the device's pixels
  and scale (`RdpCoreTS` event 168 on Drew-PC: an iPad at 2420×1570; a Mac session running at 192 DPI),
  which is why its taskbar looks right on an iPad; a mode alone gave 2560×1600 at 100%, far smaller.
  `DisplayScales.Choose` picks the step giving the desktop about the device's own points (floor 1024×720
  points), through the undocumented `DisplayConfigSetDeviceInfo` type -4. The value is relative to the
  mode's recommended scale; the registry keeps one per monitor and mode, but the live value carries
  across a mode change, so restore sets it before the mode (the other order flashed 225% in the user's
  own mode for ~95 ms), checks it after, and `display-restore.txt` lets the next launch undo a crash
  (`FailFast` left the 4K mode at 225%; recovery took 158 ms). Checked on the PG32UCDM with a throwaway
  client: an 11" iPad's 1210×834@2 gets 2048×1536 at 175% (1170×878 points, taskbar 84 px; a 13" gets
  150%), frames keep coming across the scale change, and mode and scale come back. Other windows can
  move across the change, as with any mode switch. The mode rule below now floors at the viewport in
  points, and a portrait viewport keeps the current mode, so the older 2560×1600 example is superseded.
  Parsec and Sunshine do. `HostEnvironment.DisplayFitter` (`IDisplayFitter`, null on synthetic hosts)
  is `Capture/DisplayFitter.cs`: `ChangeDisplaySettingsEx(name, mode, CDS_FULLSCREEN)` (temporary,
  never in the registry; Windows put the mode back by itself when the host was killed), restore =
  `ChangeDisplaySettingsEx(name, null, 0)`; one session holds a display, a second streams what's there
  (`Busy`). `DisplayModes.Choose` (pure, `DisplayModesTests`): candidates ≥ 1280×720, ≤ the native
  mode, and ≥ viewport points × the display's scale; keep the current mode when its shape is within
  1% of the viewport's; else the best coverage (letterboxed fraction), ties by pixel count nearest
  viewport × device scale; switch only for ≥ 5% more coverage (portrait devices and 16:9 phones keep
  the mode). `Host/DisplayChoice` (one per session) owns display choice and fitting: `Wanted(select)`
  remembers whether the device wants the display fitted, `ChooseAsync(select)` (with capture
  stopped) lists the displays, fits or restores the mode as wanted, waits ≤ 1 s for the new size
  so `streamConfig` reports the new mode, then `LayoutSettle` (600 ms) more so windows and the
  taskbar have redrawn at the new mode and scale before capture starts (the device used to watch
  the desktop rearrange itself), and picks the display (by id, else the main one);
  `CaptureSizedForOldMode` drives the retry below; `StopFitting`/`RestoreNow` serve
  `restoreDisplays` and `RestoreAtEnd` teardown; `HostListener.StopAsync` calls `RestoreAll`.
  **Holds belong to the device** (`Host/DisplayHolds`, one per listener in front of the fitter, which
  sees one owner per client key fingerprint): a session of the same device takes the hold over
  (the same viewport is `Unchanged`, no switch; no `Busy` while the old session hasn't noticed its
  connection died), and a session that ends without a goodbye (no `disconnect` from the device, not
  ended by the host) lets go after `ReconnectGrace` (10 s) unless the device fits it again, so a
  dropped connection's reconnect doesn't switch the PC back and forth. A goodbye, `restoreDisplays`
  and listener stop restore at once; another device asking during a grace ends it first. Casement's
  `ClientSession.disconnect()` sends no `disconnect` message, so closing a session from Casement
  also waits out the grace. A
  refit comes from the `selectDisplay` Casement resends when its viewport changes
  (`ClientSession.updateViewport`); **`viewportChanged` only forces a keyframe**, as on the Mac (no
  client sends it; the 500 ms `ScheduleRefit` path and `IDisplayFitter.WouldChange` are gone).
  Right after a change WGC can still size a new capture for the old mode: the start retries until
  the size matches (≤ 2 s), and a capture's stop callback carries its start's generation so a
  replaced one's late stop is ignored. `canManageVirtualDisplay` follows
  `HostSettings.AllowDisplayFitting` (Display page switch, default on). Checked on the 4K PG32UCDM: a
  1376×1032@2 viewport got 2560×1600 (2048×1536 is listed but too small at 150%), Windows dropped the
  scale to 100% in that mode (2560×1600 points), frames arrived at 2560×1600 within ~0.9 s, and
  `restoreDisplays` brought back 3840×2160 at 150%. Tests: `DisplayFittingTests` (fake fitter; the
  grace on a `FakeTimeProvider`). The 600 ms settle is a guess, not measured on Drew-PC.
- **The PC's sound** (the Mac's Mac audio, same wire: `audioRequest` 63 → `audioConfig` 73, then
  `audioPacket` 102 every 10 ms; Opus 48 kHz stereo, 480-frame packets, 128 kbps). `HostEnvironment.Audio`
  (`IAudioSource`, null = none) delivers 10 ms `AudioBlock`s; `HostSessionCore` advertises
  `capabilities.audio` only while `UnavailableReason` is null (to every client, like the Mac), answers
  `audioRequest` only from a client with `features.macAudio`, posts `audioConfig` and starts capture
  on the first `enabled: true` (a failed start adds `audioConfig.unavailable` with the source's
  reason), stops on `enabled: false`, teardown, or the source's `onStopped` (then `unavailable`).
  `Protocol/Audio`: `AudioRepacketizer` (the Mac's rules: the sample count is the clock, a buffer more than
  15 ms off it or flagged discontinuous pads the partial block with silence and starts a new
  timeline), `SilenceGate` (process loopback keeps delivering digital silence where SCK and endpoint
  loopback deliver nothing: after 500 ms of blocks under −90 dBFS it holds blocks back, so
  `captureNanos` jumps and the client sees a pause, not endless quiet packets), `PcmConverter` (any
  WASAPI layout to 48 kHz stereo float; −3 dB fold-down, linear resampling as a fallback only),
  `AudioStreamEncoder` (Concentus, the managed libopus port, on its own loop; a bounded queue of 50
  blocks so the capture thread never waits; sequence continuous across pauses; stats every 10 s in
  `Vantage.Audio`: packets/s, kbps, bytes/packet, ms/encode, silent blocks held back, timeline
  restarts), `SyntheticAudioSource`/`ChimeSynth` (the Mac's chime). Packets go on the control lane
  through `FramedConnection.PostAudio` (~180 B each: never behind a P-frame or a 256 KiB chunk, and
  refused past 50 queued so a stalled socket drops sound instead of delaying it). Platform
  `Audio/`: `WasapiAudioSource` probes once (30 s retry after a failure) and opens process loopback
  (`ActivateAudioInterfaceAsync` on `VAD\Process_Loopback`, `EXCLUDE_TARGET_PROCESS_TREE` for the
  host's PID, 48 kHz float asked for), else the default render endpoint's loopback (48 kHz float
  through `AUTOCONVERTPCM`, else the mix format through `PcmConverter`); `WasapiLoopbackCapture` is
  one MTA thread on the WASAPI event (20 ms timeout), `qpcPosition` × 100 as `captureNanos` (now
  minus the packet when flagged or missing), and reopens on an `IMMNotificationClient` default-device
  change or an invalidated device (backing off to 4 s, ~8 s in all, then `onStopped`). All COM is by
  vtable (`WasapiInterop.cs`, callbacks through `NativeCallbackObject`). `--audio auto|process|endpoint|off`
  (`run-dev.ps1 -Audio`). Checked on Drew's PC (default output a SteelSeries Sonar virtual device)
  with SAPI speech: `audioConfig` 13 ms after the request, 100.3 packets/s, 159 bytes a packet
  (3–261), every step 10 ms except two 250 ms jumps at sentence breaks (the gate), 0 packets in the
  2.5 s of silence before speech, decoded RMS ~0.02 while speaking, 0.1–0.3 ms per encode; process
  loopback's timestamps jump 25–50 ms as a render stream starts or stops (logged as a timeline
  restart, inside the gate's silence). Tests: `AudioRepacketizerTests`, `SilenceGateTests`,
  `PcmConverterTests`, `AudioEncodingTests` (layout bytes, JSON keys, Opus round trip),
  `FramedConnectionAudioTests`, `AudioSessionTests` (gated both ways, config/unavailable, restarts
  from 0, stops on disconnect); opt-in `AudioLiveTests` (`VANTAGE_LIVE_PC_AUDIO=1`; the PC speaks).
  An iPad hearing a PC still needs a device check (and the client to show Mac Audio for a PC).

```
cd WindowsHost && dotnet test --solution Vantage.Windows.slnx     # 470+ tests, incl. listener end to end; 3 opt-in live ones skip
dotnet WindowsHost/src/Vantage.SyntheticHost/bin/Debug/net10.0/Vantage.SyntheticHost.dll --port 47862 \
  --pairing-code 246810 --pairing-code-rearm 3 --display-asleep --clipboard-text "from the PC" \
  --input-log /tmp/in.jsonl --state-dir "$(mktemp -d)"
VANTAGE_INTEROP_HOST=127.0.0.1:47862 VANTAGE_INTEROP_INPUT_LOG=/tmp/in.jsonl \
  VANTAGE_INTEROP_CLIPBOARD_TEXT="from the PC" xcrun swift test --filter WindowsHostInteropTests
```

**Golden vectors**: `WindowsHost/tests/golden/{swift,csharp}/<name>.frame`, the same 45 messages
defined in `Packages/VantageCore/Tests/VantageCoreTests/WireGoldenVectorTests.swift` and
`WindowsHost/tests/Vantage.Protocol.Tests/GoldenVectorTests.cs`. Each side decodes the other's
(JSON compared key for key after canonicalising, binary byte for byte);
`VANTAGE_WRITE_GOLDEN=1` rewrites a side's files (the Swift wire encoder sorts JSON keys, so only
messages that changed show up in the diff). A change to any message must update both lists.
**Interop harness**: `Tests/ClientSessionTests/WindowsHostInteropTests.swift` (opt-in,
`.serialized`) drives the real `ClientSession` and raw channels against a running Windows host:
pairing, burning, probe, version mismatch, the stream decoded with VideoToolbox (a PNG is written,
`VANTAGE_INTEROP_PNG`), keyframe requests answered < 100 ms, exact pong, input and clipboard in the
input log, sleep/wake status, attach tokens (single use, same address: ::1 ≠ 127.0.0.1), and
files resuming after a cut both ways (`VANTAGE_INTEROP_FILE_BYTES`; host → client needs a second
host with `--send-file-on-connect` named by `VANTAGE_INTEROP_FILES_HOST` and
`VANTAGE_INTEROP_SEND_FILE`: the listener re-offers an interrupted send under the same id when that
device reattaches). The unchanged `LiveHostFilesTests` and `SessionUITests` (hosts via
`TEST_RUNNER_VANTAGE_TEST_HOST` with `--send-file-on-connect`, `…_SYNTHETIC_HOST` with
`--display-asleep`, `…_UNAVAILABLE_HOST` with `--capture-fails-for 6`) also run against it; the
Mac-audio UI test runs against it with either `--platform` (the toggle reads "PC Audio" for a PC;
unchecked on the Mac so far). Use ports ≥ 47860 and never 47820.
