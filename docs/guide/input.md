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
  `releaseAll` ends it (`ScrollMomentumTests`). Pencil squeeze/double-tap map to `PencilAction` (Settings → Controls).
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
  `DeviceSecrets` keeps one Mac password (and optional account name) per saved-device UUID in the
  Keychain (when-unlocked class); the key button types it plus Return through the host. When
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
