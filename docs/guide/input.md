# Input: pointer, touch, keyboard and passwords

Part of the project guide; [`CLAUDE.md`](../../CLAUDE.md) has the naming, layout and repo rules this assumes.

- **Software keyboard**: `SoftwareKeyboardMode` (Unicode Text or Keystrokes). Keystrokes maps
  characters through `CharacterKeyMap` (US layout) to real key events; unmapped characters fall
  back to Unicode text. Held ⌘/⌥/⌃ from the control strip always route through keystrokes.
- **Input routing** (`RemoteInteractionView`): finger and Pencil gestures go through gesture
  recognizers restricted by `allowedTouchTypes`; trackpad/mouse input goes through
  `touchesBegan/Moved/Ended`, diffing `UIEvent.buttonMask` so right- and middle-button drags work.
  Indirect pointers and the Pencil always position absolutely regardless of the touch mode; the
  touch mode only governs fingers. Wheel/trackpad scrolling uses two dedicated pan recognizers
  (continuous vs discrete) — never put `allowedScrollTypesMask` back on the movement pan, it turns
  scrolling into pointer motion. A flick's momentum is the host's job (`ScrollMomentum`): the
  iPad ends a scroll with `ended` + momentum `began` + velocity; the host posts `ended` alone, then
  momentum began/continue/end frames at 60 Hz decaying 0.998 per ms (UIScrollView's rate) in whole
  pixels; it needs ≥ 60 pt/s, stops under 10 pt/s or after 3 s, and the next scroll, a click or
  `releaseAll` ends it (`ScrollMomentumTests`). **Natural Scrolling** stays one per-computer toggle, the
  only inversion the client applies (`SavedDevice.naturalScroll`), but until the person changes it in
  Edit Computer (`naturalScrollChosen`) each connection copies the computer's own setting: a Mac
  host reads `com.apple.swipescrolldirection` (absent = on) per session and sends it as
  `HostCapabilities.naturalScroll` (`DeviceStore.adoptHostNaturalScroll`). A PC sends nothing.
  Whether the iPad's own Trackpad & Mouse setting stacks with it still needs a device check.
  Pencil squeeze/double-tap map to `PencilAction` (Settings → Controls).
  **Three-finger swipes** (iPhone and iPad, where fingers act as a trackpad: Trackpad mode and the
  iPhone Duo's `TrackpadSurface`; never Direct Touch or visionOS): a three-finger pan recognizer
  that `gestureRecognizerShouldBegin` only lets start there and while Settings → Controls →
  Three-Finger Swipes is on (`vantage.threeFingerSwipes`, default on, read by
  `ScreenSessionModel` into `InputController.threeFingerSwipes`). `TrackpadSwipeTracker` (pure,
  `Input/TrackpadSwipe.swift`) turns one drag into at most one swipe: 60 pt along an axis that
  leads the other by 1.6×, so a three-finger tap that slides (still a middle-click: the pan
  beginning is what fails the tap) or a diagonal drag sends nothing. `HostShortcut.forSwipe`
  maps it the way each platform's own trackpad does, the picture following the fingers: left =
  the next Space (⌃→ with Fn, hot key 81) or desktop (Ctrl Win →), right = the previous one (⌃←,
  hot key 79; Ctrl Win ←), up = Mission Control / Task View, down = the app's windows / Show
  Desktop (Win D, what three fingers down does on a Windows touchpad). `InputController.swipe`
  sends it as a chord for `hostPlatform`, which the model keeps current. The view returns
  `editingInteractionConfiguration = .none`, or iPadOS's own three-finger undo, redo and copy
  gestures take the fingers. The recognizer needs real fingers: the simulator has no three-finger
  input, so the gesture itself is unverified until tried on a device.
  **Edges**: every absolute position goes through `PointerMapping` (pure, `PointerMappingTests`):
  past or within `edgeSnap` (2 pt) of the picture's edge lands on the Mac's outermost row/column,
  and an edge position within `cornerSnap` (16 pt) of a corner lands in the corner. macOS reveals
  a hidden Dock/menu bar or fires a hot corner only there (one move onto the bottom row shows the
  Dock in ~0.16 s; 3 pt short never does — `LiveDockEdgeTests`, opt-in, real host), and the iPad
  pointer stops 1 pt short of the screen edge. The hover handler uses only `.began`/`.changed`:
  iPadOS ends the hover when the pointer leaves the view or is pushed into a screen edge (it takes
  it for its own Dock/menu bar), and the end reports (0, 0) — following it threw the Mac's pointer
  to the top-left, which is why a Bluetooth mouse couldn't show the Dock. The mapping is computed
  from `InputController.viewSize` + `displayPointSize` on every use (a rect stored at layout time
  kept the default display's shape). Cancelled pans/long presses release in place. UI test:
  `PointerEdgeUITests` (`hover()` to each edge; `-VantagePointerProbe 1` exposes the last Mac
  position as `session.pointerProbe`'s value). **Pointer lock is off on purpose**: the session's
  SwiftUI presentation controller never consults a child's `prefersPointerLocked`
  (`childViewControllerForPointerLock` is nil), so locking would mean presenting the session from
  UIKit; it also needs `GCMouse` deltas the simulator can't produce and a full-screen scene. Don't
  add `prefersPointerLocked = true` back: if SwiftUI ever honoured it, UIKit hover stops and no
  mouse would move the Mac's pointer.
- **Trackpad & Keyboard** (input-only session; the Mac's menu in the list, iOS only, Macs only):
  `ClientFeatures.inputOnly` → `SessionAdmission.Kind.inputOnly` (signed as `.screen`, so an older
  host sees a screen session waiting for a display and the client hangs up when
  `HostCapabilities.inputOnlySessions` is missing). The host needs only Accessibility: no display
  list, capture, video, audio or curtain (`selectDisplay`, `audioRequest`, `curtainRequest` are
  ignored), but input, text, dictation and the clipboard work, and input wakes a sleeping display.
  Its injector `followPointer()`s: clicks and scrolls land where the Mac's pointer is, and
  `PointerAction.moveBy` (3) moves it by deltas across every display (`clampToScreens`; within a
  gesture it counts from its own last position, after a 100 ms pause from the system's). The client
  shows `TabletopDeck` full screen (trackpad, on-screen Mac keyboard, or both; the strip on top), its
  `TrackpadSurface` takes the hardware keyboard, and `InputController.relativeOnly` sends `moveBy`
  with `acceleratedGain` (sensitivity up to 4× for fast flicks). An iPad's own trackpad or mouse
  doesn't drive it (that needs pointer lock, see above).
- **Apple Pencil canvas** (`stylusEvent` 125, gated on `HostCapabilities.stylus`): with a host that
  offers it, `RemoteInteractionView.stylusEnabled` takes the Pencil off the tap, pan and long-press
  recognizers and sends every coalesced touch (`event.coalescedTouches`, up to 240 Hz) as a
  `StylusEvent`: phase (hover/down/move/up/leave), display point, `force / maximumPossibleForce`,
  `altitudeAngle`, `azimuthAngle(in:)` and the tap count (double-tap still double-clicks). Hover
  comes from the Pencil hover recognizer; a stroke's end, or hover ending, sends `leave` 0.4 s later
  unless the Pencil comes back. The host (`InputInjector.injectStylus`) posts a tablet proximity
  event on entry, then mouse events with subtype tablet point, `mouseEventPressure`,
  `tabletEventPointPressure`, `tabletEventTiltX/Y` (`StylusEvent.tilt`: lean × cos/sin azimuth) and
  one device ID, and proximity exit on `leave` or `releaseAll`. Squeeze and double-tap actions are
  unchanged. Needs a check with a real Pencil and drawing apps (Photoshop, Affinity, Krita):
  whether they need tablet x/y fields or vendor proximity fields too, and the tilt signs.
- **120 Hz** (audited 2026-11-22): pointer updates go out as each pan/hover/touch callback fires,
  one `sendDetached` per event, `TCP_NODELAY` on, no throttle on either side; the host's injector
  posts from its own user-interactive queue, off the session actor. ProMotion iPhones ran the app at
  60 Hz until `CADisableMinimumFrameDurationOnPhone` (Info.plist), which halves pointer update rate
  there; iPads are 120 Hz anyway. The Pencil sends its coalesced samples; fingers and trackpads send
  the latest position per frame, which is what the Mac shows.
- **Mac shortcuts and password**: `HostShortcut` (`Vantage/Model/HostShortcut.swift`; `MacShortcut`
  is a typealias) sends system-default chords; for a Mac (⌘Space, ⌃↑, ⌃↓, F11). The host posts keys the way a Mac keyboard does
  (`KeyboardSequencer`): a chord's modifiers go down first as their own flagsChanged keys (with
  the left/right device bit) and come up after the key, and arrow/function/navigation keys carry
  Fn (arrows and the keypad also the keypad bit). macOS stores its shortcuts with those bits
  (`com.apple.symbolichotkeys` 32/33 = ⌃↑/⌃↓ with Fn, 0x840000; 36 = F11 with Fn): without them
  Mission Control, App Exposé and Show Desktop never fired. Never drop the Fn bits; the client
  also sends `.function` on those shortcuts for older hosts. ⌘Space: Spotlight's hot key and
  Carbon hot keys (Alfred and co.) answer injected keys, but Raycast only answers a physical
  keyboard (session tap, HID tap, HID-state source, device bits and human timing all fail; it runs
  a HID-level tap plus its own IOHID listener), so while Spotlight's shortcut (hot key 64) is off and
  Raycast is running the host opens `raycast://` instead (`SearchShortcut`). That's a heuristic:
  Raycast keeps its hotkey out of readable defaults (only `initialSpotlightHotkey`), so if something
  else ever owns ⌘Space while Spotlight's is off and Raycast runs, the button still opens Raycast. Keys stay on
  `.cgSessionEventTap`: a HID-tap post buys nothing and runs through every other app's HID tap.
  `--log-input-events` (DEBUG host) logs each key event reaching the session with its flags
  (listen-only tap; text keys typed on the Mac itself are logged without a key code). Tests:
  `HostInputTests` (in `xcrun swift test`), `MacShortcutTests`. A PC's shortcuts: see
  [pc-on-the-client.md](pc-on-the-client.md).
  `DeviceSecrets` keeps one Mac password (and optional account name) per computer in the
  Keychain (when-unlocked class; see iCloud sync in [client.md](client.md) for the names it's kept
  under); the key button types it plus Return through the host
  (`TypePasswordDecision` picks the route; `ScreenSessionModel.typePassword` acts on it). Before a
  saved password is typed anywhere (the key button, the banner's Unlock / Approve, Log In from the
  list, showing it in Edit Computer) `PasswordConfirmation` asks for Face ID, Touch ID or Optic ID with
  the passcode as fallback (`.deviceOwnerAuthentication`; Settings → Privacy & Security → Require
  Face ID to Type Passwords, `vantage.confirmPasswordTyping`, default on; a device with no passcode
  types straight away). A password just typed into the sheet isn't asked about again. In the list,
  Face ID is the confirmation, so Log In skips its dialog where Face ID is asked. **Unlock and
  Approve**: while a Mac reports a locked screen or Secure Event Input, `HostStatusBanner` carries a
  button (`HostUnlockOffer`): "Unlock with Face ID" / "Approve with Face ID" types through Screen
  Sharing; without a saved password or account name it reads "Save Password…" / "Add Account
  Name…" and opens the password sheet. What's saved is read when the session starts, when the host
  status changes and after saving, not on every redraw. `-VantageHostStatus locked|secure` (DEBUG)
  shows a synthetic host's status as locked or secure, and `-VantageSkipPasswordConfirmation 1`
  skips the prompt (simulators). The Unlock path with a real Mac still needs a device check. When
  `HostStatus` reports Secure Event Input or a locked screen, it instead signs in to the Mac's own
  Screen Sharing (`ScreenSharingTyper` in VantageCore: RFB 3.889, ARD auth type 30 — DH with a
  256-bit exponent over the server's 4096-bit prime, MD5, AES-128-ECB — then KeyEvents only, no
  framebuffer) directly at `<device.host>:5900` and types there; screensharingd is exempt from
  Secure Input. Shifted characters get an explicit Shift_L. The live handshake test is opt-in:
  `VANTAGE_LIVE_SCREEN_SHARING=1 xcrun swift test --package-path Packages/VantageCore` (a bogus
  account, expects a clean rejection). A real sign-in still needs a device check.
- **Local pointer** (a PC; the Remote Desktop model): the client says `Hello.features.localCursor`;
  a host with `HostCapabilities.cursorShapes` (the Windows host: `ICursorSource`,
  `WindowsCursorSource` polls `GetCursorInfo` at 120 Hz and draws a new handle on black and white
  through `CursorImage`, inverting cursors such as the I-beam become black with a white edge)
  captures without the pointer (`CaptureRequest.IncludesCursor`, WGC `IsCursorCaptureEnabled`)
  and sends `cursorShape` on change plus `cursorPosition` for visibility. The client draws it at
  its own pointer position the moment input is sent (`InputController.localCursor`; iOS a
  `CALayer` in `RemoteInteractionView`, the Mac client an `NSCursor`), sized with the picture
  (`LocalCursor.drawScale`). A Mac host can't (no public API for the system cursor's image), so
  its pointer stays in the video and the client keeps hiding its own. Debug: Windows synthetic host
  `--cursor-shapes` cycles an arrow, an inverting I-beam and hidden every 2 s.
