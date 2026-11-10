# File transfer

Part of the project guide; [`CLAUDE.md`](../../CLAUDE.md) has the naming, layout and repo rules this assumes.

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
  both, and files queued without a screen fail with "Update Casement Host…". Files land in
  `Documents/Received` (`UIFileSharingEnabled` +
  `LSSupportsOpeningDocumentsInPlace`: Files › On My iPad › Casement). Entry points: strip item
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
  session; and "Open in Casement" from other apps (`CFBundleDocumentTypes`
  public.data/public.content, rank Alternate → `onOpenURL` → `SharedFileInbox` copies it out,
  then the open session queues it, or it goes files-only to the most recent Mac, whose row shows
  it; a Mac known to predate files-only sessions is opened instead; waits for Face ID). Disconnect never asks on a current Mac: the screen goes and the
  files keep moving; the device list then shows them on the Mac's row/card
  (`DeviceTransferBadge`, "Sending 3 of 12 · 45% · 2 min", tap → Transfers; also the context menu's
  Transfers…). Only an older Mac, which would stop them, gets "Files are still transferring.
  Disconnect anyway?". **In the background** (iOS; `TransferBackgroundActivity`): a run of files
  that starts in the foreground and is ≥ 32 MB or > 20 files submits one `BGContinuedProcessingTask`
  (`me.drewlevinson.casement.transfers.<UUID>`, registered just before submitting on the main
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
