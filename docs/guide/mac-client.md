# The native Mac client

Part of the project guide; [`CLAUDE.md`](../../CLAUDE.md) has the naming, layout and repo rules this assumes.

## macOS client

The `Vantage` target also builds a native, sandboxed Mac app (`Vantage/Mac/`, plus `#if os(macOS)`
branches). `ContentView` is iOS/visionOS only; the Mac starts at `MacRootView`.

- **Windows** (`VantageApp.swift`): `Window("Casement", id: "main")` holds the device list, one
  only, so ⌘N means Add Mac…; `.defaultLaunchBehavior(.presented)` so it's there at every launch
  (stale saved window state once opened the app with no window at all), and it takes every link
  and opened file (`handlesExternalEvents(matching: ["*"])`). Each Mac connects in its own
  `WindowGroup(id: "session", for: UUID.self)` window (`SessionWindow`: `.commandsRemoved()`,
  restoration off, `handlesExternalEvents(matching: [])` so a link never opens an empty one).
  `MacAppDelegate`: closing the last window doesn't quit (sessions and files outlive the list),
  the Dock icon brings the list back, becoming active opens a pending connection and retries
  files, and launch starts `MacTransferActivity`. `Settings { MacSettingsView }` and
  `Window("Casement Help", id: "help")`.
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
  (PC ▸ Start/Search/Task View/Switch Apps/Show Desktop/Task Manager/… for a PC)
  Screen/Wake Display, Customize Control Strip…, Disconnect ⌃⌥⌘W); View adds Hide/Show Control Strip ⌃⌥⌘C,
  Actual Size ⌃⌥⌘0, Full Screen ⌃⌥⌘F, Sort Macs By; Help › Casement Help. Session shortcuts all
  hold ⌃⌥⌘, the one chord a capturing session leaves to Vantage. Items read
  `@FocusedValue(\.sessionCommands)` (the session publishes `SessionCommands` with
  `focusedSceneValue`, since its AppKit view holds focus) and `\.selectedMac` (the list); they're
  dimmed when they don't apply, never hidden. `SidebarCommands`, `ToolbarCommands`.
- **Session window**: `WindowAspectMatcher` (macOS) resets `contentAspectRatio` for the current
  width on every resize, with the toolbar's height added (the ratio covers the content view under
  the toolbar); the first time a display is known it fits the window to the display point for
  point, or as large as `visibleFrame` allows; nothing in full screen. `SessionWindowShape`
  provides Actual Size and Full Screen. Title = the Mac's name, subtitle "W × H · View Only".
  Toolbar: View Only, Send Keyboard Shortcuts, a Mac menu (the shortcuts including App Switcher
  ⌘Tab, Sleep Display, Lock Mac), Send File, Disconnect (`session.toolbar.disconnect`). The session
  publishes `.focusedSceneValue(\.sessionCommands, …)`. It suspends on `NSWorkspace.willSleep`
  and retries on `didWake`, never on scene background.
- **Input** (`RemoteInteractionNSView`): hosts `video.displayLayer` (flipped, layer-backed,
  `acceptsFirstMouse` false) and overrides the raw mouse, drag and `scrollWheel` methods on
  purpose: recognizers don't give per-button downs, ups and drags, `clickCount`, or scroll
  phases. Pointing is always absolute through `PointerMapping`; drags that leave the view keep
  arriving and pin to the Mac's edge. Buttons 2/3/4 are middle, back and forward, and ⌃-click
  stays a left click with ⌃. `mouseMoved` is skipped while the point hit-tests to a SwiftUI
  overlay; the cursor is blank over the picture only while input is on.
  `NSTextInputClient.insertText` types Character Viewer and emoji text; `keyDown` never calls
  `interpretKeyEvents`. `sendsInput` = connected, not View Only, and not `AppLock.shared.isLocked`.
  DEBUG: `-VantagePointerProbe 1` gives `session.pointerProbe`'s value; `-VantageKeyProbe 1` gives
  `session.keyProbe`'s label (macOS doesn't report a plain element's value to UI tests), the last
  8 keys sent ("0xc down command").
- **Keyboard** (`KeyboardCapture`; pure `KeyTranslator`, `KeyCapturePolicy`): a local `NSEvent`
  monitor sees keys before the menu bar. It acts only when the session window is key, the session
  view has focus and input is on; a text field keeps its typing, and host-stamped events are
  swallowed. Policy: with Send keyboard shortcuts on (`MacKeyboardSettings.captureShortcutsKey`,
  the default) everything goes to the Mac except ⌃⌥⌘ chords; off, ⌘Q, ⌘W, ⌘H, ⌥⌘H, ⌘M, ⌘,,
  ⌘`/⇧⌘` and ⌃⌘F stay local, judged on the keys as pressed before any swap. `KeyTranslator`
  sends modifiers as keys of their own, left or right from the device bits; each Caps Lock change
  is one tap, Fn/Globe is never sent, a release or repeat without a press is dropped, and Swap ⌘
  and ⌃ is `swapCommandControlKey`. ⌘V first sends `ClipboardSync.changedPayload()` (the host
  writes it before it reads the ⌘V; see Clipboard). Everything held is released on resign-key,
  app deactivate, window close, capture off, View Only, lock and teardown. In full screen while
  capturing, `presentationOptions` swap auto-hide for `.hideDock`, `.hideMenuBar`,
  `.disableProcessSwitching`; AppKit resets them ~0.1 s after `didEnterFullScreen`, so they're
  re-applied at 0.15, 0.4 and 1 s, and restored on resign-key, capture off, lock or exit. Tests:
  `KeyTranslatorTests`, `KeyCapturePolicyTests`, `SessionInputUITests` (needs Automation Mode).
- **Scrolling** (`ScrollTranslator`): precise deltas go as `-scrollingDelta`, wheel lines as
  `+scrollingDelta`; the host negates continuous deltas only (`InputInjector.postScroll`), so the
  posted event equals the local one, already corrected for this Mac's natural-scrolling setting
  (the per-Mac Natural Scrolling toggle is hidden on macOS). `NSEventPhase` bits aren't wire
  values: may-begin and stationary are dropped, as is an end or cancel without a began; momentum
  passes through; wheels send whole lines with the fraction carried, and a change of direction
  starts from zero. Test: `ScrollTranslatorTests`.
- **Same Mac**: every host-posted event carries `VantageProtocol.injectedEventMarker` in
  `.eventSourceUserData` (`InputInjector.post`) and the client drops those events
  (`NSEvent.isFromVantageHost`). `ThisMac.isHost` (loopback, a local tailnet address, or the
  host's name equal to this Mac's computer name) shows the "You're viewing this Mac from itself"
  banner and starts in View Only; `-VantageAllowSelfControl 1` keeps input on. DEBUG hosts leave
  the client (`AudioCapture.clientBundleIDs`: `me.drewlevinson.casement`, and the old
  `com.benjaminlevinson.vantage`) out of video capture for a loopback peer. Test:
  `InjectedEventMarkerTests`.
- **Settings** (`MacSettingsView`, ⌘,): tabs General (appearance), Controls, Connection, Privacy &
  Security (`hand.raised`), each a grouped form in its own `NavigationStack`; the last tab is remembered
  (`vantage.mac.settingsTab`, also an argument-domain flag for screenshots). Each tab sizes the
  window to its content (`SettingsPage`, 160–620 pt, longer tabs scroll), as Apple's apps do. It is
  the only settings UI on the Mac: any in-app Settings button is a `SettingsLink`/`openSettings`,
  never the iPad's `SettingsScreen` list (which also hides Help & FAQ and About there). The iPad
  build installed on an Apple silicon Mac ("Designed for iPad", runs from a `Wrapper/` bundle) is
  an iOS app and still shows the iPad screens; `#if os(macOS)` never reaches it. Controls on the Mac:
  Keyboard (`vantage.mac.captureShortcuts`, default on; `vantage.mac.swapCommandControl`, default
  off; `MacKeyboardSettings` has the keys), Dictation, Control Strip; no touch, trackpad,
  on-screen keyboard, Pencil, or haptics. Privacy & Security says "Require Touch ID" and has no
  iCloud sync toggle yet: the Mac build now carries the key-value entitlement, but synced Keychain
  secrets in the sandboxed Mac app haven't been tried, so the section stays iOS/visionOS-only. Add Computer hides Natural Scrolling (the Mac's own
  mouse settings apply). Help swaps the touch answers for Mac ones (`HelpScreen.controllingTheMac`).
  About isn't a tab: Casement › About Casement (`CommandGroup(replacing: .appInfo)`) opens
  `Window("About Casement")` (`MacAboutWindow`) showing `AboutScreen`.
- **Mac look** (HIG pass, 2026-09-30): words that name a gesture use `LocalDevice.tap` ("click" on
  the Mac) and `LocalDevice.this`; "this Mac" always means the local machine, so the remote one is
  named (`device.name`, `HostNoun`). Buttons sitting on a glass card (dictation panel, screen
  note, pairing prompt, connection overlay) use `.onCard`/`.onCardProminent` (`PlatformGlass.swift`:
  bordered on the Mac and visionOS, glass on iOS), never glass on glass. On the Mac the strip's
  buttons are 36 pt with a hover highlight and plain (not interactive) glass; every strip button
  has a `.help` tag. The detail pane has one large prominent button (Connect); the sidebar's
  Tailscale banner is a flat fill, not glass. View has one full-screen item: `VantageApp.init`
  registers `NSFullScreenMenuItemEverywhere = false` (the app delegate is too late) and ours reads
  Enter/Exit Full Screen from `SessionWindowShape.isFullScreen`. ⌫ in the sidebar removes the
  selected Mac (`.onDeleteCommand`, same confirmation as the menu's Remove).
  Accessibility on every platform: the remote picture is one element, "Screen of ⟨name⟩"
  (`.allowsDirectInteraction` on iOS so VoiceOver users' touches reach the host; a group on the
  Mac); banners (host status, Mac audio, password sent, reconnecting, pairing errors) are combined
  and announced; content behind the Mac's lock curtain is hidden from VoiceOver.
- **App lock**: `AppLock.shared` locks on `com.apple.screenIsLocked`, display sleep, system sleep,
  and a fast-user switch away, and asks again when `com.apple.screenIsUnlocked` arrives with Vantage
  in front or when it next becomes active. `appLockCurtain()` lays `LockOverlay` over every Mac
  window root and every device-list sheet (sheets are windows of their own); the views stay
  alive, so sessions stay connected. Never swap a Mac window's view for the lock: that
  disconnects the session. The session's input capture must also ignore input while locked.
- **Control strip**: shown as on iPad. The Mac's default is `ControlStripLayout.macStandard`
  (Start, Spotlight, Mission Control, Application Windows, Show Desktop, Task Manager, Type Password, Send Clipboard,
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
  it outlived the write and swallowed the user's next copy. `apply` returns only once the write is
  done and `HostSession` awaits it before reading the next message: ⌘V paste-through sends the
  clipboard and then the key on one stream, and a key posted before a large clipboard was written
  pasted the old one. Tests: `HostClipboardTests` (`applyReturnsOnlyOnceTheClipboardIsWritten`). Both hosts keep what a password manager marks as private on the computer
  (`ClipboardBridge.privateMarkers`, `ClipboardFormats.IsPrivate`): it never reaches a client.
- **Audio and dictation**: the host's `AudioCapture` always leaves the client app
  (`AudioCapture.clientBundleIDs`, the new and the old bundle ID) out of the audio filter, so a Mac connected to itself doesn't
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
  `-ApplePersistenceIgnoreState YES`, and `-VantageReadOnlyDevices 1` so a session's bookkeeping
  never saves the overridden list over the real one) rather than editing it, and quit a build with
  `pkill -f <its path>`: `tell application id … to quit` can quit another checkout's copy.
- **UI tests** (`Tests/VantageMacUITests`, target and shared scheme `VantageMacUITests`, which
  also builds `VantageHost`): `MacShellUITests` (connect opens a window of its own, the Session
  menu follows the key window, ⌘, opens Settings) and `SessionInputUITests` (pointer edges in full
  screen, ⌘Q goes to the Mac). The scheme's test pre-action runs `scripts/mac-ui-test-hosts.sh
  start`: the `VantageHost` built beside the tests, from its executable, synthetic, on 47856 and
  47857 (pairing code 246810); the post-action stops them. The tests can't start hosts
  themselves: the macOS UI test runner is sandboxed, so a host it spawns can't listen, and one it
  opens through LaunchServices (by bundle id or `NSWorkspace.openApplication`) loses its
  arguments, which once left argument-less real hosts fighting the live one on 47820.
  `SyntheticHost.address` waits for the listener; `TEST_RUNNER_VANTAGE_TEST_HOST` /
  `TEST_RUNNER_VANTAGE_INPUT_HOST=127.0.0.1:<port>` point a suite at another host. Tests launch
  with `-ApplePersistenceIgnoreState YES` and argument-domain settings, which pin a setting for
  the launch (a settings tab passed that way can't be changed by clicking). A session window
  covers the device list, so a test checks the list's state before connecting rather than trying
  to bring the list back. Needs Automation Mode, approved once by an admin (`automationmodetool
  enable-automationmode-without-authentication`); `scripts/check.sh` only builds them.
