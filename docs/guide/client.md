# The iPad, iPhone and Vision Pro client

Part of the project guide; [`CLAUDE.md`](../../CLAUDE.md) has the naming, layout and repo rules this assumes.

- **App lock** (Face ID, Settings → Privacy & Security): on iOS the view tree stays alive while
  locked and `LockCurtain` (in `ContentView.swift`) raises an opaque window above every sheet and
  cover. Never go back to swapping the root view for the lock screen: that dismissed open sheets
  and threw away half-typed input whenever the user switched apps (e.g. copying a Tailscale
  secret from Safari on iPhone). visionOS still swaps views. **How soon it locks**:
  `AppLockDelay` (Settings → Privacy & Security → Lock; iOS and visionOS; `vantage.appLockDelay`,
  default 15 minutes), timed from leaving the app on a `ContinuousClock` so sleep counts and changing
  the clock doesn't; locking the device locks it if the app is still running to hear so
  (`watchProtectedData`; a suspended app isn't, so don't promise it in the UI). While away inside the
  delay `isAway` keeps `LockCurtain` up, showing only `LockGlyph`, so the app switcher's snapshot
  never shows a computer's screen. The lock screen is the glyph and an Unlock button naming the
  biometry; the words are VoiceOver's only. `-VantageLockPreview 1` holds the lock screen without
  asking, for screenshots.
- **The iPad app on a Mac** ("Designed for iPad", e.g. a TestFlight install; `MacHostedIPadApp`,
  `ProcessInfo.isiOSAppOnMac`): not the native Mac app, but people do run it. Its scene goes to
  the background whenever the window leaves the screen (another Space, a full-screen app), so
  `AppLock` counts that as leaving under the same delay (with Immediately it asks on every swipe
  back), without the away cover. The device list drops its large title and bar
  background there (`MacHostedListBar`; the window's title bar already says Casement), and
  Casement › Settings… (⌘,) opens Casement's Settings in a sheet (`MacHostedSettingsCommand`)
  instead of macOS's generic settings window for iOS apps.
  The list's Grid/List is its own toolbar button beside Sort, and Settings → Appearance →
  Computer List.
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
  Settings → Controls → Customize Control Strip (default), the Edit Computer sheet's Controls row (saved
  with the sheet), and the session menu's Customize Control Strip… (writes the store live; the strip
  behind follows). Disconnect (`session.toolbar.disconnect`) is a standard item: immediate, no
  confirmation. VoiceOver reads an editor row as the control's name (label) and what it sends
  (value): the system reorder handle is named after the row's label ("Reorder Escape"), so a
  description folded into the label made it "Reorder Escape, Esc key" on iOS 27. Tests:
  `ControlStripLayoutTests`, `SessionUITests.testDisconnectButtonReturnsToDeviceList`,
  `testCustomizeControlsFromTheSession`, `testControlStripEditorScreens`.
- **Session menu** (`ControlStrip.sessionMenu`): `fullMenu` where both size classes are regular (iPad), `shortMenu` wherever either is compact (a phone), because a phone in landscape shows about seven rows and the full menu has over twenty: Touch, Mac/PC Audio, Curtain, Files & Clipboard ▸, Mac/PC ▸, Controls ▸, Disconnect. The rows are shared. One opening of the full menu on an iPhone ignored every swipe, showing a row highlight and a dimmed menu instead of scrolling (9 of 9 gestures; not reproducible on demand, cause unknown). `SessionUITests` that reach menu rows directly expect `fullMenu`, so run them on an iPad.
- **iPhone Duo tabletop** (`TabletopDeck.swift`, iOS 27.1): half-folded with the fold running
  across (the inner display in portrait; open flat in landscape the fold runs top to bottom), the
  session splits at the fold. `TabletopLayout` comes from the division reserved region
  (`GeometryProxy.reservedRegions(kind: .division)`, measured on the full-screen black background;
  the geometry callback fires on fold, so no hinge is read): the picture above, the strip plus
  `TabletopDeckMode` (trackpad, default; keyboard; both) below, a switch beside the strip, and
  Settings → Controls → Folded Like a Laptop (`vantage.tabletopLayout`, `vantage.tabletopDeck`).
  The viewport becomes the upper half, so a Virtual Display Mac fills it. `TrackpadSurface` is a
  `RemoteInteractionView` with no display layer (always relative, never sets `viewSize`). On the
  27.1 Duo simulator each half is about 669 × 455 pt; AXe taps don't reach it, the simulator
  tool's tap does.
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
- **Siri / Shortcuts / Spotlight / widgets**: `ConnectToMacIntent` (+ `VantageShortcuts` phrases
  like "Connect to ⟨Mac⟩ in Casement", from the display name) runs in-app and drops the id into `PendingConnection`;
  `ContentView` opens the session once the app is unlocked. Widgets tap through
  `vantage://connect/<uuid>` (URL scheme declared in `Vantage/Info.plist`, merged into the
  generated plist). Both read `DeviceCatalog`, a small JSON the store rewrites on every save
  (`Application Support/Vantage/catalog.json`, plus the App Group container
  `group.me.drewlevinson.casement`, which both the app and the widget extension are entitled to).
  A copy signed on a team without that group gets no container, and its widget shows "No
  computers yet"; the simulator ignores the entitlement, so verify widgets there with
  `-VantageOpenScreen widgets` (renders every family from the live catalog).
- **iCloud sync** (`CloudSync`): secrets flip between local and `kSecAttrSynchronizable` Keychain
  stores (`KeychainStore(synchronizable:)`), no entitlement needed. The device list goes through
  `NSUbiquitousKeyValueStore` with `updatedAt` last-writer-wins and tombstones, but only when the
  embedded provisioning profile carries `com.apple.developer.ubiquity-kvstore-identifier`
  (`$(TeamIdentifierPrefix)$(CFBundleIdentifier)`, in both client entitlements files; iCloud is
  enabled on the client's App ID). A build without a profile (the simulator, or another team's
  copy) reports `notEntitled` and keeps the list local. Sync is on by default: `DeviceStore.init`
  turns it on once (`CloudSync.shouldTurnOnByDefault`) when the person never chose, the build is
  entitled, and an iCloud account is signed in; never on the Mac. Turning it on pulls and merges
  before pushing, and an empty list is never pushed over iCloud's. The app lock and other settings
  stay per device on purpose.
- **visionOS** (native, not "Designed for iPad"): each session opens in its own `WindowGroup(id:
  "session", for: UUID.self)` window (`SessionWindow` in `ContentView.swift`; list and sessions share
  `DeviceStore.shared` / `AppLock.shared`), which `WindowAspectMatcher` reshapes to the Mac's display
  with uniform resizing. The `ControlStrip` lives in a bottom `.ornament`; there is no dock/corner or
  touch mode there. Look and pinch always points absolutely (tap = click, pinch-drag = drag, pinch
  and hold = right-click). Liquid Glass is unavailable: use `platformGlass(in:)`, and `.glass` /
  `.glassProminent` button styles map to bordered styles in `PlatformGlass.swift`. No Pencil
  interaction, haptics, keyboard accessory, Control Center controls, or widgets on visionOS. The
  visionOS app icon is the layered `AppIcon.solidimagestack` (see `brand/README.md`). The session window is
  `.windowStyle(.plain)`: a glass window's big corner radius cut off the Mac's Apple menu and
  clock, and insetting the picture left a glass border. The picture is the Mac's exact aspect with
  16 pt corners (`VisionSessionPicture`), like Mac Virtual Display; glass backs the window only while
  there's no picture (connecting, locked). Plain-style buttons get a capsule gaze highlight hugging
  their label, so rows and cards use `rowButtonStyle(in:)` (a custom style with its own
  `.hoverEffect` shape); device-list rows take zero `listRowInsets`, pad inside the button, and
  shape the highlight like their cell (square, with the section's 32 pt corners on the first and
  last rows), and a card's button spans the card. Both window roots opt into Look to Scroll
  (`scrollInputBehavior(.enabled, for: .look)`). The session menu stays a system `Menu`, which
  doesn't look-scroll: Drew prefers the system menu to a scrolling popover. No Appearance setting
  there (windows are always glass), and the lock says Optic ID. The simulator can't take
  AXe/xcui input, so pinch mapping still needs a headset check.
