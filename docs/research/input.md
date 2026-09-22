# Vantage — Input research (iPadOS 26/27 client → macOS 26/27 host)

> Research report, 2026-09-21. Target: M4 iPad Pro 11" + Apple Pencil Pro + Magic Keyboard / Logitech BT
> keyboard & mouse, controlling a macOS 27 host. Deployment floor macOS 26 / iPadOS 26.
> **No code was written for this report.** Symbols were verified against the locally installed
> **macOS 27.0 SDK** and **iPhoneOS 27.0 SDK** (Xcode 27.0, build 27A5228h) unless noted.
>
> Confidence markers used throughout: **[SDK]** = verified in local SDK headers ·
> **[APPLE]** = Apple docs / DTS statement · **[OSS]** = shipping open-source implementation ·
> **[COMMUNITY]** = forum/issue/PR report, plausible but unverified · **[ASSUMED]** = my inference,
> needs a device test.

---

## 0. Summary of recommendations

**Architecture**

1. **Ship the macOS host as a Developer ID–notarized, *unsandboxed* app.** Quinn (Apple DTS) states
   the *Post Event* privilege (`CGRequestPostEventAccess`) *is* App-Sandbox-compatible, but also says
   "I strongly recommend that [you] disable the App Sandbox while bringing up this feature."
   Mac App Store distribution is a real risk: there are documented Guideline 2.4.5 rejections for
   apps calling `CGEvent.post`. Plan for direct distribution. **[APPLE]**
2. **Request `CGRequestPostEventAccess()`, not Accessibility.** These are *separate* TCC services
   (`kTCCServicePostEvent` vs `kTCCServiceAccessibility`) that both surface under
   System Settings → Privacy & Security → Accessibility. You only need PostEvent for
   `CGEvent.post`. Keep `AXIsProcessTrustedWithOptions` only if you also want AX tree access
   (window enumeration, focused-element queries) — and that one really is sandbox-incompatible. **[APPLE]**
3. **Post to `.cgSessionEventTap`** (`kCGSessionEventTap`) for normal operation. It is what Quinn's
   own DTS sample uses and what Mac Mouse Fix ships. Use `.cghidEventTap` only if you specifically
   need events to be seen by lower-level session taps (e.g. third-party window managers like Swish),
   accepting that your own taps will see them too. **[APPLE][OSS]**
4. **Never target the login window / lock screen.** `CGEvent.post` does not work there and never has;
   the loginwindow session holds Secure Event Input and WindowServer drops synthesized events.
   The only shipping workaround is to proxy through Apple's own `screensharingd` over local RFB,
   which is fragile and unsupported. Design the product to require an already-unlocked session
   (or to hand off to Screen Sharing). **[COMMUNITY]**

**Mouse**

5. Use **absolute positioning**: `CGEvent(mouseEventSource:mouseType:mouseCursorPosition:mouseButton:)`
   with a point in *global display space* (origin = top-left of the main display, y grows downward),
   built from `CGDisplayBounds(displayID)` of the captured display. Do **not** use
   `CGWarpMouseCursorPosition` for normal movement — it moves the cursor without generating an event,
   so apps never see a `mouseMoved`, and it triggers a 0.25 s local-hardware-event suppression window
   by default. **[SDK]**
6. Always set `kCGMouseEventClickState` on down/up pairs (1/2/3) to get double- and triple-clicks;
   AppKit derives `NSEvent.clickCount` from this field, not from your event timing. Emit drag events
   (`leftMouseDragged` / `rightMouseDragged` / `otherMouseDragged`) while a button is held, not
   `mouseMoved`. **[SDK]**

**Scroll — the single biggest quality lever**

7. There are **two viable scroll strategies and they are mutually exclusive**; pick per-mode:
   - **Phased "trackpad gesture" scroll** — set `kCGScrollWheelEventIsContinuous = 1` plus
     `kCGScrollWheelEventScrollPhase` began(1)→changed(2)*→ended(4), and synthesize your own
     momentum tail with `kCGScrollWheelEventMomentumPhase` begin(1)→continue(2)*→end(3).
     Gets you rubber-band overscroll, swipe-between-pages, and Mail's swipe-to-mark. Best for
     two-finger touch scrolling and Magic Keyboard trackpad input.
   - **Phaseless continuous scroll** — `kCGScrollWheelEventIsContinuous = 1`, phase fields left at 0.
     This is what a real high-res wheel emits. Avoids spurious elastic bounce and avoids WebKit
     gesture-latching bugs that can *stall* JS-driven virtual lists (reported on Safari + Fastmail).
     Best for discrete wheel notches from a Bluetooth mouse.
   Expose this as a user setting; default phased for trackpad/touch, phaseless for wheel. **[OSS][COMMUNITY]**
8. Copy Mac Mouse Fix's field set — it is the most carefully reverse-engineered public reference:
   it writes *three* delta representations (line `11`/`12`, point `96`/`97`, 16.16 fixed-point
   `93`/`94`) **and** emits a companion **type-29 `NSEventTypeGesture` / subtype 6** event carrying
   the gesture vector. The gesture event is what makes Safari page-swipe and Mail swipe-actions work.
   Scroll-only apps will work without it; gesture-driven UI will not. **[OSS]**
9. **Natural scrolling almost certainly does *not* re-invert events you post** — the inversion happens
   in the HID→NX event pipeline before any tap. But there *is* a private field **137** =
   `NSEvent.isDirectionInvertedFromDevice`, which Mac Mouse Fix sets explicitly and which changes
   Mail's swipe-to-mark-unread direction. **Verify on device** and expose an "invert scroll" toggle
   regardless. **[ASSUMED]**

**Keyboard**

10. Send **HID usage codes from the iPad, translate to `kVK_*` on the Mac.** Do not send characters.
    `UIKey.keyCode` is literally the USB HID usage (page 0x07), so a static 256-entry table
    (§A.5 below) is all you need, and the host's own keyboard layout does the right thing for
    non-US layouts. **[SDK]**
11. **Modifiers need explicit `flagsChanged` events**, in the right order, *and* the correct
    `CGEventFlags` stamped on every subsequent key event. `CGEventCreateKeyboardEvent` does not
    infer them. **[SDK]**
12. Use `CGEventKeyboardSetUnicodeString` only for the software-keyboard / paste path, in
    **≤20 UTF-16 code units per event**, and understand that Terminal, VS Code, games, and
    virtualisers frequently ignore it and honour the virtual keycode instead (which is 0 =
    `kVK_ANSI_A` if you don't set one). **[APPLE][COMMUNITY]**

**Client (iPad)**

13. **`UIViewController.prefersPointerLocked` (iOS 14+) exists and is the right primitive** for
    trackpad mode — it is a *request*, observable via `UIScene.pointerLockState.isLocked`. See §B.
14. Keep both an absolute mode (touch, Pencil) and a relative mode (locked pointer / GCMouse deltas),
    switchable, because neither alone covers the hardware matrix.

**Uncertainties that must be resolved on hardware:** see §D.

---

## A. macOS host: input injection with CGEvent

### A.1 Permissions, sandboxing, and what actually gates `CGEvent.post`

macOS keeps **three independent TCC buckets** that all appear under
*System Settings → Privacy & Security → Accessibility* (or *Input Monitoring*):

| TCC service | API to check / request | What it gates | Sandbox-compatible? |
|---|---|---|---|
| `kTCCServicePostEvent` | `CGPreflightPostEventAccess()` / `CGRequestPostEventAccess()` **[SDK]**, macOS 10.15+ | `CGEvent.post`, `CGEventPostToPid` | **Yes** — per Quinn **[APPLE]** |
| `kTCCServiceListenEvent` ("Input Monitoring") | `CGPreflightListenEventAccess()` / `CGRequestListenEventAccess()` **[SDK]**, macOS 10.15+ | `CGEventTapCreate` in listen/filter mode | **Yes** — "I regularly test this" — Quinn **[APPLE]** |
| `kTCCServiceAccessibility` | `AXIsProcessTrustedWithOptions(_:)` with `kAXTrustedCheckOptionPrompt` **[SDK]**, macOS 10.9+ | AXUIElement tree access | **No** — "It's not possible for a sandboxed app to use the Accessibility privilege… DTS doesn't support folks using general accessibility APIs in sandboxed apps" **[APPLE]** |

Header text for the two CG pairs, verbatim from `CGEvent.h` **[SDK]**:

```c
/* Checks whether the current process already has event synthesizing access */
CG_EXTERN bool CGPreflightPostEventAccess(void) API_AVAILABLE(macos(10.15));
/* Requests event synthesizing access if absent, potentially prompting */
CG_EXTERN bool CGRequestPostEventAccess(void) API_AVAILABLE(macos(10.15));
```

**Key clarifications and contradictions to be aware of:**

- Quinn, forum thread 730441: *"You don't need the Accessibility privilege to post mouse events.
  There's a separate privilege called Post Event… This privilege is compatible with the App Sandbox.
  IMPORTANT: While that's true, and cool, I strongly recommend that [you] disable the App Sandbox
  while bringing up this feature."* His sample posts with `.cgSessionEventTap`. **[APPLE]**
- Apple's older *App Sandbox Design Guide* says the opposite for the general case: "Posting keyboard
  or mouse events using functions like `CGEventPost` offers a way to circumvent this restriction, and
  is therefore not allowed from a sandboxed app." Treat the archive doc as stale relative to Quinn's
  2023–2024 statements, but treat **App Review** as unpredictable — there are documented
  Guideline 2.4.5 rejections for `CGEvent.post` in Mac App Store submissions. **[COMMUNITY]**
- **Input Monitoring is not needed to post.** It is only needed if you also *tap* events (which a
  remote-desktop host generally shouldn't).
- **Recommendation:** unsandboxed, Developer ID + notarized, hardened runtime. Gate startup on
  `CGPreflightPostEventAccess()`; call `CGRequestPostEventAccess()` once, then poll/observe, because
  the grant requires a relaunch in practice.

#### A.1a macOS 26 (Tahoe) regression risk — WindowServer sender filtering

A community write-up reports that on macOS 26.5, WindowServer gained/strengthened a gate
(`CGXSenderCanSynthesizeEvents()`) that logs
`"Dropping mouse down event because sender's PID (899) isn't 0 or self (828)"` and silently drops
synthesized modifier-bearing events from **unsigned** processes, even when PostEvent TCC is granted.
Bare key events still reached the focused app; events targeting Carbon `RegisterEventHotKey`
listeners did not. **[COMMUNITY]** — I could not corroborate this in Apple documentation.

**Mitigation:** ship properly signed + notarized (the report is specifically about *unsigned*
daemons), and add an early self-test on first launch that posts a benign event to your own app and
verifies receipt, so the failure is diagnosable rather than a silent dead input path.

#### A.1b Login window, lock screen, Secure Event Input

- **`CGEvent.post` does not work at the login window.** Multiple long-standing unanswered Apple
  forum threads (62687, 724740, 720050) confirm screen capture works from a
  `LimitLoadToSessionType = LoginWindow` agent but event injection does not. **[COMMUNITY]**
- `EnableSecureEventInput()` (Apple TN2150) "bypasses all `CGEventTap`s" and blocks synthesized
  keyboard input. The login window holds it permanently; so do password fields in 1Password,
  Terminal's *Secure Keyboard Entry*, and any app that calls it. While held **by any process**,
  your synthesized *keyboard* events are dropped. Mouse events are generally unaffected. **[APPLE][COMMUNITY]**
- **What actually happens from the user's perspective:** keystrokes silently vanish. There is no
  error, no return code. `CGEvent.post` returns `void`. **[SDK]**
- **Detection:** `IsSecureEventInputEnabled()` (Carbon, `HIToolbox`) returns whether *any* process
  currently holds secure input. Poll it and show a UI banner ("The Mac is showing a secure text
  field; typing is blocked") rather than letting the user think the connection died. **[COMMUNITY]**
- The only shipping technique for login-window control is what the MeshCentral macOS agent fork does:
  detect `is_loginwindow()` and connect to the local `screensharingd` as an RFB client, letting
  Apple's own daemon (which holds the entitlement that bypasses SecureEventInput) perform the
  injection. Requires Screen Sharing enabled in System Settings so
  `com.apple.screensharing.agent` has ScreenCapture + PostEvent TCC. **[COMMUNITY]** Out of scope
  for v1; note it as a future option.

### A.2 Event source choice, idle timers, and sleep

```c
typedef CF_ENUM(int32_t, CGEventSourceStateID) {
  kCGEventSourceStatePrivate = -1,
  kCGEventSourceStateCombinedSessionState = 0,
  kCGEventSourceStateHIDSystemState = 1
};
```
**[SDK]** `CGEventTypes.h`

`CGEventSource.h` header comment, verbatim — note it calls out our exact use case **[SDK]**:

> The `kCGEventSourceStateCombinedSessionState` table reflects the combined state of all event
> sources posting to the current user login session. If your program is posting events from within a
> login session, you should use this source state when you create an event source.
>
> The `kCGEventSourceStateHIDSystemState` table reflects the combined state of all hardware event
> sources posting from the HID system. If your program is a daemon or a user space device driver
> interpreting hardware state and generating events, you should use this source state…
>
> **Very specialized applications such as remote control programs** may want to generate and track
> event source state independent of other processes. These programs should use the
> `kCGEventSourceStatePrivate` value…

**Recommendation:** use `.combinedSessionState`. Apple's "remote control programs → private"
guidance is aimed at programs that must *not* interfere with local state; a remote-desktop host
*should* share modifier/button state with the local keyboard and mouse, otherwise a physically-held
Shift on the Mac and a remotely-held Shift diverge. Private state also means
`CGEventSourceFlagsState`/`CGEventSourceKeyState` on the default tables won't reflect your input.
Keep `.privateState` as an escape hatch if you see cross-talk. **[ASSUMED]**

Useful state-query APIs on whichever table you pick **[SDK]**:

- `CGEventSourceKeyState(_ stateID:, _ key: CGKeyCode) -> Bool` — is a key currently down.
- `CGEventSourceFlagsState(_ stateID:) -> CGEventFlags` — current modifier flags.
- `CGEventSourceButtonState(_ stateID:, _ button: CGMouseButton) -> Bool`.
- `CGEventSourceSecondsSinceLastEventType(_ stateID:, _ eventType:)` with
  `kCGAnyInputEventType` (`(CGEventType)(~0)`) — the standard user-idle query.

Use these to **resynchronise on reconnect**: on session start, read `CGEventSourceFlagsState` and
`CGEventSourceKeyState` for all modifiers and force-release anything stuck. Stuck modifiers after a
dropped connection are the #1 bug in every remote-desktop client.

#### Idle timer / display sleep / screensaver

- Whether posted events reset the idle timer is **version- and source-dependent and I could not find
  an authoritative answer**. Empirically, events posted with a `.hidSystemState` source have been
  reported to update the HID idle timer; `.combinedSessionState` is less clear. **[ASSUMED]**
- **Don't rely on it.** Use Power Management explicitly:

| API | Use |
|---|---|
| `IOPMAssertionDeclareUserActivity(_ name: CFString, _ userType: IOPMUserActiveType, _ id: inout IOPMAssertionID)` **[SDK]**, 10.7.3+ | "causes the display to power on and postpone display sleep, up to the user's display sleep Energy Saver settings." Pass `kIOPMUserActiveRemote`. "No special privileges are necessary." Call it on every input burst (re-passing the returned ID). |
| `IOPMAssertionCreateWithName` / `…WithDescription` with `kIOPMAssertionTypePreventUserIdleDisplaySleep` **[SDK]** | Hold for the duration of a session if you want the display *guaranteed* awake. Heavier; shows in `pmset -g assertions`. |
| `IOPMDeclareNetworkClientActivity` **[SDK]** | Prevents *system* idle sleep for remote clients — but the header explicitly says: "If your remote clients require access to the framebuffer or the GPU, then this isn't the appropriate call for you. Please see `IOPMAssertionDeclareUserActivity` and pass in argument `kIOPMUserActiveRemote`." |

**Recommendation:** `IOPMAssertionDeclareUserActivity(…, kIOPMUserActiveRemote, &id)` on every input
event (cheap enough at input rates; it *is* an IPC and may block, so do it off the input hot path at
most ~1 Hz), plus a held `kIOPMAssertionTypePreventUserIdleDisplaySleep` assertion for the session if
the user enables "keep Mac awake". Note neither prevents the *screen lock* once it has engaged.

#### Local hardware event suppression (easy to trip over)

After you post an event, macOS suppresses local hardware events for **0.25 s by default**, and
during any synthetic mouse drag **[SDK]** (`CGEventSource.h`). If the user is sitting at the Mac,
their own mouse will feel dead while a remote session is streaming input.

```c
CGEventSourceSetLocalEventsSuppressionInterval(source, 0.0);   // recommended for us
CGEventSourceSetLocalEventsFilterDuringSuppressionState(
    source,
    kCGEventFilterMaskPermitAllEvents,     // = mouse | keyboard | systemDefined
    kCGEventSuppressionStateSuppressionInterval);
CGEventSourceSetLocalEventsFilterDuringSuppressionState(
    source, kCGEventFilterMaskPermitAllEvents,
    kCGEventSuppressionStateRemoteMouseDrag);
```
Masks **[SDK]**: `kCGEventFilterMaskPermitLocalMouseEvents = 1`,
`…PermitLocalKeyboardEvents = 2`, `…PermitSystemDefinedEvents = 4`.

### A.3 Mouse

#### Creation

```swift
CGEvent(mouseEventSource: CGEventSource?,
        mouseType: CGEventType,
        mouseCursorPosition: CGPoint,   // GLOBAL display coordinates
        mouseButton: CGMouseButton)     // ignored unless type is .otherMouse*
```
**[SDK]** Header notes: *"The current implementation of the event system supports a maximum of
thirty-two buttons. Mouse button 0 is the primary button… 1 is the secondary (right)… 2 is the
center button, and the remaining buttons are in USB device order."*

| Button | `CGMouseButton` | Down / Up / Drag event types |
|---|---|---|
| Left | `.left` (0) | `.leftMouseDown` / `.leftMouseUp` / `.leftMouseDragged` |
| Right | `.right` (1) | `.rightMouseDown` / `.rightMouseUp` / `.rightMouseDragged` |
| Middle | `.center` (2) | `.otherMouseDown` / `.otherMouseUp` / `.otherMouseDragged` |
| 4, 5 (back/forward) | `CGMouseButton(rawValue: 3/4)` | `.otherMouse*`, **and** set `kCGMouseEventButtonNumber` (field 3) to 3/4 |

Full `CGEventType` list (values are the `NX_*` constants) **[SDK]**: `.leftMouseDown`,
`.leftMouseUp`, `.rightMouseDown`, `.rightMouseUp`, `.mouseMoved`, `.leftMouseDragged`,
`.rightMouseDragged`, `.keyDown`, `.keyUp`, `.flagsChanged`, `.scrollWheel`, `.tabletPointer`,
`.tabletProximity`, `.otherMouseDown`, `.otherMouseUp`, `.otherMouseDragged`.

#### Coordinate space

- Global display space: **origin at the top-left of the *main* display, +y downward.** This is the
  "flipped" space; `CGEventGetUnflippedLocation` converts to AppKit's bottom-left space **[SDK]**.
- `CGDisplayBounds(displayID) -> CGRect` returns "the screen size and screen origin of `display` in
  global coordinates" **[SDK]**. For a secondary display to the left of the main one, `origin.x`
  is negative. For one above, `origin.y` is negative.
- **Mapping a captured display:** if you stream `SCDisplay` *D*, `SCDisplay.frame` is a `CGRect`
  **[SDK]** in the same global display space as `CGDisplayBounds`. Given a normalised point
  `(u, v) ∈ [0,1]²` from the iPad view:
  ```
  global = CGPoint(x: D.frame.minX + u * D.frame.width,
                   y: D.frame.minY + v * D.frame.height)
  ```
  Use **points, not pixels** — `CGDisplayBounds`/`SCDisplay.frame` are in points; your capture
  surface is in backing pixels (multiply by the scale factor for the pixel buffer, not for events).
- Clamp to the target display's rect *before* posting, or the pointer will silently walk onto an
  adjacent display. If you want the cursor free to roam the whole desktop (multi-display host,
  single-display client), clamp to the union of `CGDisplayBounds` over
  `CGGetActiveDisplayList` instead.

#### `CGWarpMouseCursorPosition` vs posting moves

| | `CGWarpMouseCursorPosition(_:)` / `CGDisplayMoveCursorToPoint(_:_:)` | Posting `.mouseMoved` |
|---|---|---|
| Generates an event? | **No** — "without generating events" / "No events are generated as a result of the move" **[SDK]** | Yes |
| App sees hover/tracking? | No, until the next real event | Yes |
| Triggers suppression interval? | Yes (warp counts as a posted Quartz operation for suppression purposes) **[ASSUMED]** | Yes |
| Good for | *Resyncing* the hardware cursor after a big jump; pairing with `CGAssociateMouseAndMouseCursorPosition(false)` for relative-only modes | **Everything normal** |

**Recommendation:** post `.mouseMoved`/`.*Dragged` events for all motion. Use
`CGWarpMouseCursorPosition` only once, at session start or after a mode switch, to snap the physical
cursor to where the client thinks it is. A known pitfall is that after a warp the OS can still
report the *old* location for one event; set `CGEventSetLocation` explicitly on every event you post
rather than relying on the current cursor position.

`CGAssociateMouseAndMouseCursorPosition(false)` decouples cursor from mouse so "all events received
by your application have a constant absolute location but contain mouse delta (change in X and Y)
data" **[SDK]** — that's for *reading* local input in a game; not what we want for injection.

#### Click count (double / triple click)

`kCGMouseEventClickState` (field **1**): *"A click state of 1 represents a single click. A click
state of 2 represents a double-click. A click state of 3 represents a triple-click."* **[SDK]**

The host must track click sequences itself (position within slop radius + within
`NSEvent.doubleClickInterval`) and stamp the counter. Sequence for a double-click:

```
down(clickState:1) up(clickState:1) down(clickState:2) up(clickState:2)
```
Both the down *and* the matching up must carry the same value. Also set `kCGMouseEventNumber`
(field 0) to the same value on a matching down/up pair — header: *"Matching mouse-down and mouse-up
events will have the same event number."* **[SDK]**

Better still: **do the click-count detection on the iPad**, where you already have the gesture
recognizer's `UITapGestureRecognizer.numberOfTapsRequired` / `UITouch.tapCount` and no network
jitter, and send an explicit `clickCount` in the wire protocol. Network RTT will otherwise push
real double-clicks past `doubleClickInterval`.

#### Other useful mouse fields **[SDK]**

| Field | Const | Use |
|---|---|---|
| 0 | `kCGMouseEventNumber` | pair down/up |
| 1 | `kCGMouseEventClickState` | click count |
| 2 | `kCGMouseEventPressure` | 0…1; set 1.0 on down, 0.0 on up. Pencil pressure can drive this |
| 3 | `kCGMouseEventButtonNumber` | required for buttons ≥ 3 |
| 4 / 5 | `kCGMouseEventDeltaX/Y` | relative delta since last move — **set these**; some apps (games, 3D viewports, Terminal mouse reporting) read deltas, not positions |
| 7 | `kCGMouseEventSubtype` | `kCGEventMouseSubtypeDefault` (0) / `…TabletPoint` (1) / `…TabletProximity` (2) |
| 170/171 | `kCGEventUnacceleratedPointerMovementX/Y` | unaccelerated delta; set alongside 4/5 for games |

**Pencil / tablet passthrough:** if you want pressure-sensitive drawing on the host (Procreate-style
apps, Photoshop), set `kCGMouseEventSubtype = kCGEventMouseSubtypeTabletPoint` and fill the
`kCGTabletEvent*` fields (`kCGTabletEventPointPressure`, `…PointX/Y/Z`, `…TiltX/TiltY`,
`…Rotation`, `…DeviceID`). This is a significant differentiator vs Screens/Jump and maps
naturally from `UITouch.force`, `.altitudeAngle`, `.azimuthAngle(in:)`, and Pencil Pro `rollAngle`.
Untested — flag as a stretch goal. **[ASSUMED]**

### A.4 Scroll

#### The two creators

```c
CGEventRef CGEventCreateScrollWheelEvent(CGEventSourceRef, CGScrollEventUnit units,
                                         uint32_t wheelCount, int32_t wheel1, ...);
CGEventRef CGEventCreateScrollWheelEvent2(CGEventSourceRef, CGScrollEventUnit units,
                                          uint32_t wheelCount,
                                          int32_t wheel1, int32_t wheel2, int32_t wheel3);  // 10.13+
```
**[SDK]** Use `…Event2` — the variadic version is a Swift-import hazard.
Header: *"`kCGScrollEventUnitPixel` will produce an event that most applications interpret as a
smooth scrolling event… The scale between [pixel and line] is about 10 pixels per line by default.
The scale can be altered… using `CGEventSourceSetPixelsPerLine`."*

`wheel1` = vertical, `wheel2` = horizontal, `wheel3` = unused in practice. Sign convention: positive
`wheel1` scrolls content **up** (i.e. the classic "scroll wheel away from you") — verify on device.

#### Enums (exact values, from `CGEventTypes.h` **[SDK]**)

```c
typedef CF_ENUM(uint32_t, CGScrollEventUnit) { kCGScrollEventUnitPixel = 0, kCGScrollEventUnitLine = 1 };

typedef CF_ENUM(uint32_t, CGScrollPhase) {
    kCGScrollPhaseBegan = 1, kCGScrollPhaseChanged = 2, kCGScrollPhaseEnded = 4,
    kCGScrollPhaseCancelled = 8, kCGScrollPhaseMayBegin = 128
};
typedef CF_ENUM(uint32_t, CGMomentumScrollPhase) {
    kCGMomentumScrollPhaseNone = 0, kCGMomentumScrollPhaseBegin = 1,
    kCGMomentumScrollPhaseContinue = 2, kCGMomentumScrollPhaseEnd = 3
};
```

> ⚠️ **Gotcha: `CGScrollPhase` ≠ `NSEventPhase`.** AppKit's `NSEventPhase` is
> `None=0, Began=0x1, Stationary=0x2, Changed=0x4, Ended=0x8, Cancelled=0x10, MayBegin=0x20` **[SDK]**
> — a *different* bit layout. WindowServer translates. Always write **CG** values into field 99/123,
> never NSEventPhase values. Conversely, when reading a tap, translate the other way.
> `kIOHIDEventPhaseBits` (IOKit) happens to match the CG values, which is why Mac Mouse Fix uses
> IOKit constants interchangeably there. **[OSS]**

#### The field set

| # | Constant | Type | Notes |
|---|---|---|---|
| 88 | `kCGScrollWheelEventIsContinuous` | int | "non-zero when the scrolling data is pixel-based and zero when line-based" **[SDK]**. Maps to `NSEvent.hasPreciseScrollingDeltas`. **Set to 1 for anything trackpad-like.** |
| 11 / 12 | `kCGScrollWheelEventDeltaAxis1/2` | int (lines) | vertical / horizontal, integer lines |
| 96 / 97 | `kCGScrollWheelEventPointDeltaAxis1/2` | int (points) | pixel deltas → `NSEvent.scrollingDeltaY/X` |
| 93 / 94 | `kCGScrollWheelEventFixedPtDeltaAxis1/2` | 16.16 fixed | "fixed-point 16.16 signed integer format. If this key is passed to `CGEventGetDoubleValueField`, the fixed-point value is converted to a double" **[SDK]**. i.e. write `Int64(lines * 65536)` via the *integer* setter. |
| 99 | `kCGScrollWheelEventScrollPhase` | `CGScrollPhase` | |
| 123 | `kCGScrollWheelEventMomentumPhase` | `CGMomentumScrollPhase` | |
| 100 | `kCGScrollWheelEventScrollCount` | int | rdar://11259169; number of discrete notches coalesced |
| 14 | `kCGScrollWheelEventInstantMouser` | int | "should be ignored by the Inkwell subsystem" |
| 173 | `kCGScrollWheelEventMomentumOptionPhase` | int | undocumented |
| 175–178 | `kCGScrollWheelEventAcceleratedDeltaAxis1/2`, `…RawDeltaAxis1/2` | int | "Raw and accelerated scroll wheel deltas" — set by the driver, not needed for injection |
| **137** | *(private)* | int | `NSEvent.isDirectionInvertedFromDevice`. Not in the SDK header; Mac Mouse Fix sets it and notes "Will flip direction of unread swiping in Mail" **[OSS]** |

Mac Mouse Fix's exact writes, for reference **[OSS]**
(`Helper/Core/Touch/GestureScrollSimulator.m`):

```objc
CGEventRef e22 = CGEventCreate(NULL);
CGEventSetIntegerValueField(e22, 55, 22);   // event type = NSEventTypeScrollWheel
CGEventSetIntegerValueField(e22, 88, 1);    // kCGScrollWheelEventIsContinuous
CGEventSetIntegerValueField(e22, 137, invertedFromDevice ? 1 : 0);
CGEventSetIntegerValueField(e22, 11, lineIntY);   CGEventSetIntegerValueField(e22, 96, pointY);
CGEventSetIntegerValueField(e22, 93, fixedScrollDelta(lineY));
CGEventSetIntegerValueField(e22, 12, lineIntX);   CGEventSetIntegerValueField(e22, 97, pointX);
CGEventSetIntegerValueField(e22, 94, fixedScrollDelta(lineX));
CGEventSetIntegerValueField(e22, 99, phase);       // CGScrollPhase
CGEventSetIntegerValueField(e22, 123, momentumPhase);
CGEventPost(kCGSessionEventTap, e22);
```
with `line = point / 10` (matching `CGEventSourceGetPixelsPerLine`'s default of 10), then
`lineInt = |v| ≤ 1 ? signedCeil(v) : signedFloor(v)` — *"I think this algorithm is exactly how the
Apple Trackpad driver gets the rounded line deltas."* **[OSS]**

#### The companion gesture event (type 29) — required for swipe/overscroll UI

Mac Mouse Fix also emits, for every non-momentum frame **[OSS]**:

```objc
CGEventRef e29 = CGEventCreate(NULL);
CGEventSetIntegerValueField(e29, 55, 29);    // NSEventTypeGesture
CGEventSetIntegerValueField(e29, 110, 6);    // subtype = kIOHIDEventTypeScroll
CGEventSetDoubleValueField (e29, 116, dxGesture);   // gesture vector = point * 1.67
CGEventSetDoubleValueField (e29, 119, dyGesture);
CGEventSetIntegerValueField(e29, 132, phase);
CGEventPost(kCGSessionEventTap, e29);
```
Fields 55/110/116/119/132 are **private and undocumented**. Author's note: the 1.67 scale
*"makes click and drag to swipe between pages in Safari appropriately easy to trigger."*
He posts the type-22 event *after* the type-29 event and notes that ordering removed a stutter.
**[OSS] [COMMUNITY — private API, could break in any macOS release.]**

If you don't want private-field risk, omit the type-29 event. You lose Safari back/forward swipe and
Mail swipe actions but keep normal scrolling, overscroll bounce and momentum.

#### Recommended phase sequences

**Phased trackpad-style (touch / trackpad input):**

| Step | phase (99) | momentum (123) | deltas | notes |
|---|---|---|---|---|
| finger down, no motion yet | `mayBegin` (128) | 0 | **0** | optional; real trackpad emits it |
| first motion | `began` (1) | 0 | **non-zero** | ⚠️ a zero delta on `began` makes the whole gesture no-op in some consumers **[COMMUNITY]** and triggers WebKit latching **[COMMUNITY]** |
| motion | `changed` (2) | 0 | non-zero | ~8–16 ms cadence |
| finger up | `ended` (4) | 0 | **0** | |
| momentum | `undefined` (0) | `begin`(1), then `continue`(2)×N, then `end`(3) | decaying | If you send *nothing* after `ended`, Xcode and Finder collection views invent their own momentum but Safari does not — so synthesize it for consistency **[OSS]** |
| cancel (two fingers lifted with no scroll) | `cancelled` (8) | 0 | 0 | |

Invariant from MMF: **exactly one of phase/momentumPhase is non-zero at a time**
(`assert(phase == kIOHIDEventPhaseUndefined || momentumPhase == kCGMomentumScrollPhaseNone)`). **[OSS]**

**Phaseless continuous (mouse wheel):** `isContinuous = 1`, fields 99 and 123 left at 0, deltas set.
This is what native high-resolution wheels emit. **[COMMUNITY]**

**Legacy line scroll (fallback):** `isContinuous = 0`, `units = .line`, `wheel1 = ±1` per notch,
no phases. Guaranteed to work everywhere; feels terrible.

#### Which apps honour synthesized phases?

Reported behaviour, all **[OSS]/[COMMUNITY]**, none Apple-documented:

- **Safari / WebKit** — honours phases; enables rubber-band and page-swipe. **Downside:** WebKit
  *latches* a gesture stream to the view under the cursor at `began`, and a `began` with zero delta
  can starve JS wheel-handler-driven virtual lists (reproduced on Fastmail's mailbox list: "stopped
  scrolling entirely"). Also gives you elastic bounce on what the user thinks is a plain wheel.
- **Xcode** — honours phases; **invents its own momentum** if you stop after `ended` without sending
  momentum events.
- **Finder (icon/collection views)** — same self-momentum behaviour as Xcode; also *ignores
  zero-delta events* when computing initial momentum speed.
- **Apple Mail** — honours the type-29 gesture events for swipe-to-mark-unread; direction is
  affected by field 137.
- **Brave / Chromium** — phases produce visible elastic overscroll on wheel input, which users
  perceive as a bug.
- **Terminal / iTerm** — mostly indifferent; iTerm reacts to pixel deltas.
- **iPhone Mirroring on macOS 26** — reportedly *discards plain synthetic scroll-wheel events
  entirely* and requires the full phased gesture with non-zero `began` delta. **[COMMUNITY]** Useful
  signal that Apple is tightening scroll synthesis in the 26 cycle.

#### Natural scrolling

- The user setting is the global `com.apple.swipescrolldirection` boolean (`NSGlobalDomain`);
  `true` = natural. Changing it via `defaults write` only takes effect after logout. **[COMMUNITY]**
- **On the *capture* side** (irrelevant to us, but the classic confusion): events reaching a
  `CGEventTap` are *already inverted* — hence `NSEvent.isDirectionInvertedFromDevice`, whose doc says
  *"deltaX/Y and scrollingDeltaX/Y are automatically inverted for NSEventScrollWheel events according
  to the user's preferences… This method allows you to determine when the event has been inverted and
  compensate by multiplying -1 if needed."* **[SDK]**
- **On the *injection* side (ours):** the inversion is applied in the HID→NX pipeline before the
  event exists as a Quartz event, so a `CGEvent` you construct and post should pass through
  **unmodified**. **[ASSUMED — this is the single most important thing to verify on device.]**
- Regardless: the iPad has its *own* natural-scroll setting (Settings → General → Trackpad & Mouse →
  Natural Scrolling) which *does* affect the deltas UIKit hands you. So two independent inversions
  are in play. **Design for it:** normalise to a canonical "content moves with finger" convention on
  the client, send that, and let the host apply exactly one inversion based on an explicit
  user-visible toggle. Do **not** try to read either OS setting and be clever.

### A.5 Keyboard

#### Creation and the modifier protocol

```swift
CGEvent(keyboardEventSource: CGEventSource?, virtualKey: CGKeyCode, keyDown: Bool)
```
**[SDK]** Header, verbatim: *"All keystrokes needed to generate a character must be entered,
including SHIFT, CONTROL, OPTION, and COMMAND keys. For example, to produce a 'Z', the SHIFT key must
be down, the 'z' key must go down, and then the SHIFT and 'z' key must be released."* The sample it
gives is four `CGEventCreateKeyboardEvent` calls with `kVK_Shift` (56 = 0x38) and `kVK_ANSI_Z` (6).

**Do modifiers need `flagsChanged`? Yes — and the header's own sample is subtly incomplete.**

- `CGEventCreateKeyboardEvent` with a modifier's virtual keycode produces a **`keyDown`/`keyUp`**
  event, not a `flagsChanged`. Many apps (AppKit text views, Terminal, games reading raw NSEvents)
  watch `flagsChanged` and `NSEvent.modifierFlags`, so a bare `keyDown(kVK_Shift)` is not enough.
- `CGEventSource.h` confirms the semantic: *"Modifier keys produce `kCGEventFlagsChanged` events,
  not `kCGEventKeyDown` events, and do so both on press and release."* **[SDK]**

**Correct sequence to type ⌘⇧A:**

```
1. e = CGEvent(keyboardEventSource: src, virtualKey: kVK_Command, keyDown: true)
   e.type  = .flagsChanged
   e.flags = [.maskCommand]                        → post
2. e = CGEvent(… virtualKey: kVK_Shift, keyDown: true)
   e.type  = .flagsChanged
   e.flags = [.maskCommand, .maskShift]            → post
3. e = CGEvent(… virtualKey: kVK_ANSI_A, keyDown: true)
   e.flags = [.maskCommand, .maskShift]            → post      // keyDown, flags stamped
4. e = CGEvent(… virtualKey: kVK_ANSI_A, keyDown: false)
   e.flags = [.maskCommand, .maskShift]            → post      // keyUp, same flags
5. e = CGEvent(… virtualKey: kVK_Shift, keyDown: false)
   e.type = .flagsChanged; e.flags = [.maskCommand] → post     // cumulative remainder
6. e = CGEvent(… virtualKey: kVK_Command, keyDown: false)
   e.type = .flagsChanged; e.flags = []            → post
```

Rules that fall out of this:
- Flags on `flagsChanged` events are **cumulative state after the transition**, not a delta.
- Every `keyDown`/`keyUp` must carry the currently-held flag set; otherwise `⌘C` becomes plain `C`.
- Release modifiers in reverse order of press (cosmetic, but matches hardware).
- Left/right variants share the device-independent mask bit. `CGEventFlags` **[SDK]** has no
  left/right distinction (`kCGEventFlagMaskShift` etc.); the distinction is only in the virtual
  keycode you post (`kVK_Shift` 0x38 vs `kVK_RightShift` 0x3C). Apps that care read
  `NSEvent.keyCode`. Send the correct side.

`CGEventFlags` **[SDK]**:

| Swift | C | Meaning |
|---|---|---|
| `.maskAlphaShift` | `kCGEventFlagMaskAlphaShift` (`NX_ALPHASHIFTMASK`) | Caps Lock **is on** |
| `.maskShift` | `kCGEventFlagMaskShift` | |
| `.maskControl` | `kCGEventFlagMaskControl` | |
| `.maskAlternate` | `kCGEventFlagMaskAlternate` | Option |
| `.maskCommand` | `kCGEventFlagMaskCommand` | |
| `.maskHelp` | `kCGEventFlagMaskHelp` | |
| `.maskSecondaryFn` | `kCGEventFlagMaskSecondaryFn` (`NX_SECONDARYFNMASK`) | **Fn / Globe** |
| `.maskNumericPad` | `kCGEventFlagMaskNumericPad` | set on keypad-origin key events |
| `.maskNonCoalesced` | `kCGEventFlagMaskNonCoalesced` | mouse/pen moves not coalesced |

#### Caps Lock

Two distinct things:
1. **The flag.** `kCGEventFlagMaskAlphaShift` on every event while caps is engaged. Set this
   yourself from the client's tracked caps state. This alone makes typing behave.
2. **The physical LED / system lock state.** Posting `keyDown/keyUp` for `kVK_CapsLock` (0x39)
   generally does **not** toggle the system caps-lock state, because the toggle lives in the HID
   layer below Quartz. Toggling it for real requires `IOHIDManager` /
   `IOHIDSetModifierLockState(handle, kIOHIDCapsLockState, on)` on an
   `IOServiceMatching(kIOHIDSystemClass)` connection — which requires root on modern macOS.
   **[COMMUNITY]**

**Recommendation:** track caps on the client, stamp `.maskAlphaShift`, and additionally translate
letters yourself if caps is on (i.e. send Shift-less uppercase via the flag, not by faking Shift).
Do not try to move the host's physical caps state.

#### Fn / Globe

- `kCGEventFlagMaskSecondaryFn` exists and can be stamped. **[SDK]**
- `kVK_Function = 0x3F` exists. **[SDK]** There is *no* HID usage for it in
  `UIKeyboardHIDUsage` (page 0x07 has no Fn; USB puts it at page 0x01 usage 0x97). Chromium's table
  notes `Mac#003f kVK_Function` as an unmapped TODO. **[OSS]**
- On the client side iPadOS reserves Globe for its own shortcuts, so you will most likely never
  see it (see §B). Offer Fn as an **on-screen modifier toggle** in the shortcut bar instead, which
  just sets `.maskSecondaryFn` on the next key. Whether the host honours a synthesized Fn flag for
  e.g. Fn+F1 → F1-as-function-key is **unverified**.

#### Key repeat

`kCGKeyboardEventAutorepeat` (field **8**): *"non-zero when this is an autorepeat of a key-down, and
zero otherwise."* **[SDK]** `CGEventSource.h` adds: *"Key autorepeat events are not counted"* by
`CGEventSourceCounterForEventType`.

**Recommendation:** generate repeats on the **host**, not the client — a network-driven repeat stream
is jittery and a dropped key-up leaves a key stuck repeating forever. On host key-down, start a timer
using the system settings
(`NSUserDefaults.standard.double(forKey: "InitialKeyRepeat")` and `"KeyRepeat"`, both in units of
1/60 s, from `NSGlobalDomain`), post `keyDown` with field 8 = 1 at that cadence, cancel on key-up or
on connection loss. Add a hard watchdog that releases all held keys after N seconds of silence.

#### Unicode text injection

```c
void CGEventKeyboardSetUnicodeString(CGEventRef, UniCharCount stringLength, const UniChar *);
```
**[SDK]** Header: *"By default, the system translates the virtual key code in a keyboard event into a
Unicode string based on the keyboard ID in the event source. This function allows you to manually
override this string. **Note that application frameworks may ignore the Unicode string in a keyboard
event and do their own translation based on the virtual keycode and perceived event state.**"*

Practical constraints:

- **~20 UTF-16 code units maximum per event** — widely reported, including a Qt forum thread whose
  workaround is to chunk. **[COMMUNITY]** Chunk to 16 to be safe.
- The common recipe is `CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)` +
  `keyboardSetUnicodeString`, then a matching `keyDown: false`. **Virtual key 0 is `kVK_ANSI_A`**,
  so any consumer that reads the keycode and ignores the string types a burst of `a`. Documented
  failure mode in QEMU's Cocoa UI and reported against virtualisers generally. **[COMMUNITY]**
  Quicksilver's fix was to *also* assign a plausible keycode per character. **[OSS]**
- **Terminal.app** honours the Unicode string for printable text but does its own translation for
  control sequences; **Xcode**, **Electron apps**, and **games** are unreliable.
- Emoji and anything outside the BMP need surrogate pairs; count UTF-16 units, not Characters.

**Recommendation:** two paths.
- *Physical keyboard path* — HID usage → `kVK_*` → `CGEvent(keyboardEventSource:virtualKey:keyDown:)`
  with flags. **Never** set a Unicode string here. This is layout-correct and universally honoured.
- *Software-keyboard / dictation / emoji / paste path* — chunked
  `CGEventKeyboardSetUnicodeString` with a best-effort keycode, plus a "use clipboard paste instead"
  fallback setting for long text (write to `NSPasteboard`, post ⌘V, restore). Surface the limitation
  in the UI.

#### Media keys and other system-defined events

Volume/brightness/play keys are **not** Quartz keyboard events. They are
`NSEventTypeSystemDefined` (`NX_SYSDEFINED` = 14) with
`subtype = NX_SUBTYPE_AUX_CONTROL_BUTTONS` (**8**) **[SDK]** and the key type packed into `data1`.
`CGEventSource.h` confirms: *"The volume, brightness, and CD eject keys on some keyboards… do not
generate key up or key down events."* **[SDK]**

`NX_KEYTYPE_*` values from `IOKit/hidsystem/ev_keymap.h` **[SDK]**:

| Constant | Value | | Constant | Value |
|---|---|---|---|---|
| `NX_KEYTYPE_SOUND_UP` | 0 | | `NX_KEYTYPE_EJECT` | 14 |
| `NX_KEYTYPE_SOUND_DOWN` | 1 | | `NX_KEYTYPE_VIDMIRROR` | 15 |
| `NX_KEYTYPE_BRIGHTNESS_UP` | 2 | | `NX_KEYTYPE_PLAY` | 16 |
| `NX_KEYTYPE_BRIGHTNESS_DOWN` | 3 | | `NX_KEYTYPE_NEXT` | 17 |
| `NX_KEYTYPE_CAPS_LOCK` | 4 | | `NX_KEYTYPE_PREVIOUS` | 18 |
| `NX_KEYTYPE_HELP` | 5 | | `NX_KEYTYPE_FAST` | 19 |
| `NX_KEYTYPE_MUTE` | 7 | | `NX_KEYTYPE_REWIND` | 20 |
| `NX_KEYTYPE_NUM_LOCK` | 10 | | `NX_KEYTYPE_ILLUMINATION_UP` | 21 |
| `NX_KEYTYPE_CONTRAST_UP` | 11 | | `NX_KEYTYPE_ILLUMINATION_DOWN` | 22 |
| `NX_KEYTYPE_CONTRAST_DOWN` | 12 | | `NX_KEYTYPE_ILLUMINATION_TOGGLE` | 23 |
| `NX_KEYTYPE_LAUNCH_PANEL` | 13 | | `NX_KEYTYPE_MENU` | 25 |

Injection recipe (the long-standing community pattern; `data1` encoding is **not** Apple-documented):

```swift
func postMediaKey(_ keyType: Int32, down: Bool) {
    let flags = NSEvent.ModifierFlags(rawValue: UInt(down ? 0xA00 : 0xB00))
    let data1 = Int((Int(keyType) << 16) | ((down ? 0xA : 0xB) << 8))
    guard let ev = NSEvent.otherEvent(with: .systemDefined,
                                      location: .zero,
                                      modifierFlags: flags,
                                      timestamp: 0,
                                      windowNumber: 0,
                                      context: nil,
                                      subtype: 8,           // NX_SUBTYPE_AUX_CONTROL_BUTTONS
                                      data1: data1,
                                      data2: -1)?.cgEvent else { return }
    ev.post(tap: .cgSessionEventTap)
}
```
Post down then up. Reference implementations: `MediaKeyTap` (Swift). **[OSS][COMMUNITY]**

Note the SDK also defines `NX_SUBTYPE_AUX_MOUSE_BUTTONS` (7) for extra-button state, with
`misc.L[0]` = changed-button bitmask and `misc.L[1]` = current state bitmask. **[SDK]**

Also useful: `kVK_VolumeUp` (0x48), `kVK_VolumeDown` (0x49), `kVK_Mute` (0x4A) exist as *virtual
keycodes* **[SDK]** — some apps respond to them, but the system volume HUD does not. Prefer the
system-defined path.

### A.5b USB HID usage → macOS virtual keycode table (US ANSI)

Generated by joining `UIKeyConstants.h` (iPhoneOS 27.0 SDK) **[SDK]**, `HIToolbox/Events.h`
(MacOSX 27.0 SDK) **[SDK]**, and cross-checked against Chromium's
`ui/events/keycodes/dom/dom_code_data.inc` "Mac" column **[OSS]** — a table Apple's own WebKit
engineers effectively co-maintain, and the most battle-tested public HID↔kVK mapping.

`—` means **no macOS virtual keycode exists**; those keys cannot be injected via
`CGEventCreateKeyboardEvent` at all.

| HID | `UIKeyboardHIDUsage` (Swift) | kVK | `kVK_*` name |
|---|---|---|---|
| 0x04 | `.keyboardA` | 0x00 | `kVK_ANSI_A` |
| 0x05 | `.keyboardB` | 0x0B | `kVK_ANSI_B` |
| 0x06 | `.keyboardC` | 0x08 | `kVK_ANSI_C` |
| 0x07 | `.keyboardD` | 0x02 | `kVK_ANSI_D` |
| 0x08 | `.keyboardE` | 0x0E | `kVK_ANSI_E` |
| 0x09 | `.keyboardF` | 0x03 | `kVK_ANSI_F` |
| 0x0A | `.keyboardG` | 0x05 | `kVK_ANSI_G` |
| 0x0B | `.keyboardH` | 0x04 | `kVK_ANSI_H` |
| 0x0C | `.keyboardI` | 0x22 | `kVK_ANSI_I` |
| 0x0D | `.keyboardJ` | 0x26 | `kVK_ANSI_J` |
| 0x0E | `.keyboardK` | 0x28 | `kVK_ANSI_K` |
| 0x0F | `.keyboardL` | 0x25 | `kVK_ANSI_L` |
| 0x10 | `.keyboardM` | 0x2E | `kVK_ANSI_M` |
| 0x11 | `.keyboardN` | 0x2D | `kVK_ANSI_N` |
| 0x12 | `.keyboardO` | 0x1F | `kVK_ANSI_O` |
| 0x13 | `.keyboardP` | 0x23 | `kVK_ANSI_P` |
| 0x14 | `.keyboardQ` | 0x0C | `kVK_ANSI_Q` |
| 0x15 | `.keyboardR` | 0x0F | `kVK_ANSI_R` |
| 0x16 | `.keyboardS` | 0x01 | `kVK_ANSI_S` |
| 0x17 | `.keyboardT` | 0x11 | `kVK_ANSI_T` |
| 0x18 | `.keyboardU` | 0x20 | `kVK_ANSI_U` |
| 0x19 | `.keyboardV` | 0x09 | `kVK_ANSI_V` |
| 0x1A | `.keyboardW` | 0x0D | `kVK_ANSI_W` |
| 0x1B | `.keyboardX` | 0x07 | `kVK_ANSI_X` |
| 0x1C | `.keyboardY` | 0x10 | `kVK_ANSI_Y` |
| 0x1D | `.keyboardZ` | 0x06 | `kVK_ANSI_Z` |
| 0x1E | `.keyboard1` | 0x12 | `kVK_ANSI_1` |
| 0x1F | `.keyboard2` | 0x13 | `kVK_ANSI_2` |
| 0x20 | `.keyboard3` | 0x14 | `kVK_ANSI_3` |
| 0x21 | `.keyboard4` | 0x15 | `kVK_ANSI_4` |
| 0x22 | `.keyboard5` | 0x17 | `kVK_ANSI_5` |
| 0x23 | `.keyboard6` | 0x16 | `kVK_ANSI_6` |
| 0x24 | `.keyboard7` | 0x1A | `kVK_ANSI_7` |
| 0x25 | `.keyboard8` | 0x1C | `kVK_ANSI_8` |
| 0x26 | `.keyboard9` | 0x19 | `kVK_ANSI_9` |
| 0x27 | `.keyboard0` | 0x1D | `kVK_ANSI_0` |
| 0x28 | `.keyboardReturnOrEnter` | 0x24 | `kVK_Return` |
| 0x29 | `.keyboardEscape` | 0x35 | `kVK_Escape` |
| 0x2A | `.keyboardDeleteOrBackspace` | 0x33 | `kVK_Delete` |
| 0x2B | `.keyboardTab` | 0x30 | `kVK_Tab` |
| 0x2C | `.keyboardSpacebar` | 0x31 | `kVK_Space` |
| 0x2D | `.keyboardHyphen` | 0x1B | `kVK_ANSI_Minus` |
| 0x2E | `.keyboardEqualSign` | 0x18 | `kVK_ANSI_Equal` |
| 0x2F | `.keyboardOpenBracket` | 0x21 | `kVK_ANSI_LeftBracket` |
| 0x30 | `.keyboardCloseBracket` | 0x1E | `kVK_ANSI_RightBracket` |
| 0x31 | `.keyboardBackslash` | 0x2A | `kVK_ANSI_Backslash` |
| 0x32 | `.keyboardNonUSPound` | 0x2A * | `kVK_ANSI_Backslash` (ISO key left of Return) — see ISO note |
| 0x33 | `.keyboardSemicolon` | 0x29 | `kVK_ANSI_Semicolon` |
| 0x34 | `.keyboardQuote` | 0x27 | `kVK_ANSI_Quote` |
| 0x35 | `.keyboardGraveAccentAndTilde` | 0x32 | `kVK_ANSI_Grave` |
| 0x36 | `.keyboardComma` | 0x2B | `kVK_ANSI_Comma` |
| 0x37 | `.keyboardPeriod` | 0x2F | `kVK_ANSI_Period` |
| 0x38 | `.keyboardSlash` | 0x2C | `kVK_ANSI_Slash` |
| 0x39 | `.keyboardCapsLock` | 0x39 | `kVK_CapsLock` |
| 0x3A | `.keyboardF1` | 0x7A | `kVK_F1` |
| 0x3B | `.keyboardF2` | 0x78 | `kVK_F2` |
| 0x3C | `.keyboardF3` | 0x63 | `kVK_F3` |
| 0x3D | `.keyboardF4` | 0x76 | `kVK_F4` |
| 0x3E | `.keyboardF5` | 0x60 | `kVK_F5` |
| 0x3F | `.keyboardF6` | 0x61 | `kVK_F6` |
| 0x40 | `.keyboardF7` | 0x62 | `kVK_F7` |
| 0x41 | `.keyboardF8` | 0x64 | `kVK_F8` |
| 0x42 | `.keyboardF9` | 0x65 | `kVK_F9` |
| 0x43 | `.keyboardF10` | 0x6D | `kVK_F10` |
| 0x44 | `.keyboardF11` | 0x67 | `kVK_F11` |
| 0x45 | `.keyboardF12` | 0x6F | `kVK_F12` |
| 0x46 | `.keyboardPrintScreen` | — | no kVK. Map to ⌘⇧3 / ⌘⇧4 instead |
| 0x47 | `.keyboardScrollLock` | — | no kVK |
| 0x48 | `.keyboardPause` | — | no kVK |
| 0x49 | `.keyboardInsert` | 0x72 | `kVK_Help` (macOS maps Insert *and* Help to 0x72) |
| 0x4A | `.keyboardHome` | 0x73 | `kVK_Home` |
| 0x4B | `.keyboardPageUp` | 0x74 | `kVK_PageUp` |
| 0x4C | `.keyboardDeleteForward` | 0x75 | `kVK_ForwardDelete` |
| 0x4D | `.keyboardEnd` | 0x77 | `kVK_End` |
| 0x4E | `.keyboardPageDown` | 0x79 | `kVK_PageDown` |
| 0x4F | `.keyboardRightArrow` | 0x7C | `kVK_RightArrow` |
| 0x50 | `.keyboardLeftArrow` | 0x7B | `kVK_LeftArrow` |
| 0x51 | `.keyboardDownArrow` | 0x7D | `kVK_DownArrow` |
| 0x52 | `.keyboardUpArrow` | 0x7E | `kVK_UpArrow` |
| 0x53 | `.keypadNumLock` | 0x47 | `kVK_ANSI_KeypadClear` |
| 0x54 | `.keypadSlash` | 0x4B | `kVK_ANSI_KeypadDivide` |
| 0x55 | `.keypadAsterisk` | 0x43 | `kVK_ANSI_KeypadMultiply` |
| 0x56 | `.keypadHyphen` | 0x4E | `kVK_ANSI_KeypadMinus` |
| 0x57 | `.keypadPlus` | 0x45 | `kVK_ANSI_KeypadPlus` |
| 0x58 | `.keypadEnter` | 0x4C | `kVK_ANSI_KeypadEnter` |
| 0x59 | `.keypad1` | 0x53 | `kVK_ANSI_Keypad1` |
| 0x5A | `.keypad2` | 0x54 | `kVK_ANSI_Keypad2` |
| 0x5B | `.keypad3` | 0x55 | `kVK_ANSI_Keypad3` |
| 0x5C | `.keypad4` | 0x56 | `kVK_ANSI_Keypad4` |
| 0x5D | `.keypad5` | 0x57 | `kVK_ANSI_Keypad5` |
| 0x5E | `.keypad6` | 0x58 | `kVK_ANSI_Keypad6` |
| 0x5F | `.keypad7` | 0x59 | `kVK_ANSI_Keypad7` |
| 0x60 | `.keypad8` | 0x5B | `kVK_ANSI_Keypad8` |
| 0x61 | `.keypad9` | 0x5C | `kVK_ANSI_Keypad9` |
| 0x62 | `.keypad0` | 0x52 | `kVK_ANSI_Keypad0` |
| 0x63 | `.keypadPeriod` | 0x41 | `kVK_ANSI_KeypadDecimal` |
| 0x64 | `.keyboardNonUSBackslash` | 0x0A | `kVK_ISO_Section` — "On Apple ISO keyboards, this is the section symbol (§/±)" **[SDK]** |
| 0x65 | `.keyboardApplication` | 0x6E | `kVK_ContextualMenu` |
| 0x66 | `.keyboardPower` | — | no kVK |
| 0x67 | `.keypadEqualSign` | 0x51 | `kVK_ANSI_KeypadEquals` |
| 0x68 | `.keyboardF13` | 0x69 | `kVK_F13` |
| 0x69 | `.keyboardF14` | 0x6B | `kVK_F14` |
| 0x6A | `.keyboardF15` | 0x71 | `kVK_F15` |
| 0x6B | `.keyboardF16` | 0x6A | `kVK_F16` |
| 0x6C | `.keyboardF17` | 0x40 | `kVK_F17` |
| 0x6D | `.keyboardF18` | 0x4F | `kVK_F18` |
| 0x6E | `.keyboardF19` | 0x50 | `kVK_F19` |
| 0x6F | `.keyboardF20` | 0x5A | `kVK_F20` |
| 0x70–0x73 | `.keyboardF21`…`.keyboardF24` | — | **macOS has no kVK for F21–F24.** Drop or remap. |
| 0x74 | `.keyboardExecute` | — | |
| 0x75 | `.keyboardHelp` | 0x72 † | `kVK_Help` (Chromium leaves this unmapped; macOS note M1 says Help→0x72) |
| 0x76 | `.keyboardMenu` | — | (≠ `.keyboardApplication`) |
| 0x77–0x7E | `.keyboardSelect`…`.keyboardFind` | — | |
| 0x7F | `.keyboardMute` | 0x4A | `kVK_Mute` — prefer the system-defined path |
| 0x80 | `.keyboardVolumeUp` | 0x48 | `kVK_VolumeUp` — prefer the system-defined path |
| 0x81 | `.keyboardVolumeDown` | 0x49 | `kVK_VolumeDown` — prefer the system-defined path |
| 0x82–0x84 | `.keyboardLockingCapsLock/NumLock/ScrollLock` | — | legacy, never emitted by Apple keyboards |
| 0x85 | `.keypadComma` | 0x5F | `kVK_JIS_KeypadComma` |
| 0x86 | `.keypadEqualSignAS400` | — | |
| 0x87 | `.keyboardInternational1` | 0x5E | `kVK_JIS_Underscore` (JIS ろ / Brazilian /?) |
| 0x88 | `.keyboardInternational2` | — | JIS Hiragana/Katakana — no kVK |
| 0x89 | `.keyboardInternational3` | 0x5D | `kVK_JIS_Yen` |
| 0x8A | `.keyboardInternational4` | — | JIS 変換 Henkan — no kVK |
| 0x8B | `.keyboardInternational5` | — | JIS 無変換 Muhenkan — no kVK |
| 0x8C–0x8F | `.keyboardInternational6`…`9` | — | |
| 0x90 | `.keyboardLANG1` (`.keyboardHangul`, `.keyboardKanaSwitch`) | 0x68 | `kVK_JIS_Kana` (かな) |
| 0x91 | `.keyboardLANG2` (`.keyboardHanja`, `.keyboardAlphanumericSwitch`) | 0x66 | `kVK_JIS_Eisu` (英数) |
| 0x92 | `.keyboardLANG3` (`.keyboardKatakana`) | — | |
| 0x93 | `.keyboardLANG4` (`.keyboardHiragana`) | — | |
| 0x94 | `.keyboardLANG5` (`.keyboardZenkakuHankakuKanji`) | — | |
| 0x95–0x98 | `.keyboardLANG6`…`9` | — | |
| 0x99–0xA4 | `.keyboardAlternateErase` … `.keyboardExSel` | — | |
| **0xE0** | `.keyboardLeftControl` | 0x3B | `kVK_Control` |
| **0xE1** | `.keyboardLeftShift` | 0x38 | `kVK_Shift` |
| **0xE2** | `.keyboardLeftAlt` | 0x3A | `kVK_Option` |
| **0xE3** | `.keyboardLeftGUI` | 0x37 | `kVK_Command` |
| **0xE4** | `.keyboardRightControl` | 0x3E | `kVK_RightControl` |
| **0xE5** | `.keyboardRightShift` | 0x3C | `kVK_RightShift` |
| **0xE6** | `.keyboardRightAlt` | 0x3D | `kVK_RightOption` |
| **0xE7** | `.keyboardRightGUI` | 0x36 | `kVK_RightCommand` |
| *(none)* | — | 0x3F | `kVK_Function` — Fn; no page-0x07 HID usage exists |

\* HID 0x32 is the ISO "Non-US #" key left of Return. Chromium leaves it unmapped (`INTL_HASH` is
commented out). Apple ISO keyboards actually report that physical key as HID **0x31** and macOS gives
`kVK_ANSI_Backslash` (0x2A). Mapping 0x32 → 0x2A is a safe defensive default. **[ASSUMED]**

† Chromium maps HID 0x49 (Insert) → 0x72 and leaves HID 0x75 (Help) unmapped, but its own note M1
says *"OS X maps USB 0x070049 [Insert] as well as USB 0x070075 [Help] to scan code 0x72 kVK_Help."*
**[OSS]**

#### ISO / JIS caveats

1. **Physical position, not legend.** HID usages are positional (`UIKeyConstants.h`: *"One example is
   the Y key on a North American keyboard. In Germany this is typically Z. Rather than changing the
   keyboard firmware… the vendor uses the Y Usage on both"* **[SDK]**). Since the *host* applies its
   own layout to the `kVK_*` code, a German iPad keyboard + German Mac layout "just works" if you
   forward usages. This is the whole argument for the HID-forwarding design.
2. **ISO extra key.** ISO keyboards have one more key than ANSI, between Left Shift and Z: HID 0x64,
   `kVK_ISO_Section` (0x0A), § / ± on Apple ISO. ANSI keyboards never emit it.
3. **ISO vs ANSI Backslash.** ANSI's `\|` is HID 0x31 → 0x2A. On ISO the key in that position is
   `#~`/`*'` and still HID 0x31 → 0x2A; HID 0x32 is the theoretical "Non-US #" that Apple hardware
   doesn't emit.
4. **JIS.** Yen (0x89→0x5D), ろ/underscore (0x87→0x5E), かな (0x90→0x68), 英数 (0x91→0x66) all map.
   変換/無変換 (0x8A/0x8B) have **no** macOS virtual keycode — a JIS iPad keyboard cannot drive
   those on the host via `CGEventCreateKeyboardEvent`. Fall back to posting
   `kVK_JIS_Kana`/`kVK_JIS_Eisu` or to the Unicode-string path.
5. **`CGEventSourceSetKeyboardType(_:_:)`** **[SDK]** lets you stamp the keyboard type ID on your
   source (ANSI/ISO/JIS). Set it to match the host's physical keyboard if you see wrong characters;
   leaving it at the default (`CGSDefaultKeyboardID`) is usually correct.

### A.6 Tap location: `kCGHIDEventTap` vs `kCGSessionEventTap` vs `kCGAnnotatedSessionEventTap`

```c
typedef CF_ENUM(uint32_t, CGEventTapLocation) {
  kCGHIDEventTap = 0, kCGSessionEventTap, kCGAnnotatedSessionEventTap
};
void CGEventPost(CGEventTapLocation tap, CGEventRef event);
void CGEventPostToPid(pid_t pid, CGEventRef event);          // 10.11+
```
**[SDK]** Header: *"This function posts the specified event immediately before any event taps
instantiated for that location, and the event passes through any such taps."*

| Location | Semantics | Use for us |
|---|---|---|
| `.cghidEventTap` | Lowest point in the Quartz pipeline; the event is seen by *every* session's taps and by all session-level filters. Gets you compatibility with third-party input utilities (Swish, BetterTouchTool, window managers). | Optional "maximum compatibility" mode. Costs: your own taps see your events; higher chance of loops. |
| `.cgSessionEventTap` | Posted into the current login session. **Default choice** — Quinn's sample and Mac Mouse Fix both use it. | **Default.** |
| `.cgAnnotatedSessionEventTap` | Per-application dispatch point; used with `CGEventPostToPid` to build routing policies (header: *"makes it possible for an application to establish an event routing policy, for example, by tapping events at the `kCGAnnotatedSessionEventTap` location and then posting the events to another desired process"*). | Only if you ever implement "send input to one app only". |

`CGEventPostToPid(pid, event)` is interesting for a future "control one window" mode, but the target
app must be able to receive events that aren't at the cursor position; results are inconsistent.
**[ASSUMED]**

</content>
</invoke>

---

## B. iPadOS client: input capture

### B.1 Pointing devices (Magic Keyboard trackpad, Bluetooth mouse)

#### The Info.plist key you must set

`UIApplicationSupportsIndirectInputEvents = true`. With it, pointer clicks arrive as
`UITouch.TouchType.indirectPointer` and trackpad pinch/rotate arrive as real transform events;
without it, clicks are delivered as `.direct` touches and gestures are simulated touches.
WWDC20 session 10094 is explicit: *"This key is not required to enable pointer interactions, button
clicking, scroll input, or trackpad gestures. All of those work with or without the key."* — but you
want the *indirect* representation so you can tell a finger from a cursor. **Moonlight sets it.**
**[APPLE][OSS]**

#### Hiding the system cursor

```swift
// UIPointerInteractionDelegate
func pointerInteraction(_ interaction: UIPointerInteraction,
                        styleFor region: UIPointerRegion) -> UIPointerStyle? {
    return .hidden()          // ObjC: +[UIPointerStyle hiddenPointerStyle]
}
```
Header: *"Hides the pointer when hovering over the current region."* **[SDK]**
Moonlight does exactly this, unconditionally, with the comment *"Always hide the mouse cursor over
our stream view."* **[OSS]**

The cursor still exists and still moves — you keep getting location updates — it is only not drawn.
Region scoping matters: return a `UIPointerRegion` covering **only** the video rect from
`pointerInteraction(_:regionFor:defaultRegion:)`, so the pointer reappears normally over your
toolbar/chrome. Moonlight recomputes the letterboxed video rect on every region request
("This logic mimics what iOS does with `AVLayerVideoGravityResizeAspect`") and updates the remote
cursor position from there when no buttons are held. **[OSS]**

`UIPointerRegionRequest` gives you `location: CGPoint` and `modifiers: UIKeyModifierFlags` **[SDK]** —
so the region callback is a legitimate, high-frequency absolute-position source.

#### Pointer lock — yes, iPadOS has it

```objc
// UIViewController (UIPointerLockSupport)
@property (readonly) BOOL prefersPointerLocked            API_AVAILABLE(ios(14.0));
@property (readonly, nullable) UIViewController *childViewControllerForPointerLock;
- (void)setNeedsUpdateOfPrefersPointerLocked;
// UIScene (PointerLockState)
@property (readonly, nullable) UIPointerLockState *pointerLockState;   // .isLocked, KVO-able
UIKIT_EXTERN NSNotificationName const UIPointerLockStateDidChangeNotification;  // .didChangeNotification
UIKIT_EXTERN NSString *const UIPointerLockStateSceneUserInfoKey;
```
**[SDK]** — `UIPointerLockState.h`, `UIViewController.h`, iOS 14+, unavailable on tvOS/watchOS.

Header comment on `UIPointerLockState.locked`: *"The status of the pointer lock for this scene as
determined by the system. **The preferred pointer lock value specified by a view controller is only a
request, which may or may not be honored.** This property is key-value observable…"* **[SDK]**

WWDC20 session 10094 states the conditions: **the app must be full screen and foreground-active on
iPadOS** (frontmost application on Mac Catalyst). **[APPLE]** Practically that means pointer lock
will *not* engage in Split View, Slide Over, or (presumably) a non-full-screen Stage Manager window —
**verify the Stage Manager / iPadOS 26 windowing behaviour on device.**

When locked, the system cursor disappears and you are expected to consume **relative deltas via
GameController's `GCMouse`**, not UIKit touches.

**Moonlight's hard-won lesson — read this before designing:** **[OSS]**
```objc
- (BOOL)prefersPointerLocked {
    // Pointer lock breaks the UIKit mouse APIs, which is a problem because
    // GCMouse is horribly broken on iOS 14.0 for certain mice. Only lock
    // the cursor if there is a GCMouse present.
    return [GCMouse mice].count > 0;
}
```
and in `StreamView.m`: *"It would be nice to just use GCMouse on iOS 14+ and the older API on iOS 13
but unfortunately that isn't possible today. GCMouse doesn't recognize many mice correctly, but UIKit
does. We will register for both and ignore UIKit events if a GCMouse is connected."* Every UIKit
pointer handler starts with `if ([GCMouse current] != nil) { return; }`.

**Recommendation: implement both paths, exactly like Moonlight.**
- UIKit path (absolute) = default; works with Magic Keyboard trackpad and any mouse.
- `GCMouse` path (relative) + `prefersPointerLocked` = "trackpad/gaming mode", enabled only when
  `GCMouse.mice` is non-empty, toggled by an explicit user action (Jump Desktop uses `⌘⇧P`).
- Observe `UIPointerLockState.didChangeNotification` and fall back gracefully if the request is
  refused; never assume `prefersPointerLocked == true` means locked.

#### GCMouse (GameController)

```objc
GAMECONTROLLER_EXPORT NSString *const GCMouseDidConnectNotification     API_AVAILABLE(ios(14.0));
GAMECONTROLLER_EXPORT NSString *const GCMouseDidDisconnectNotification  API_AVAILABLE(ios(14.0));
GAMECONTROLLER_EXPORT NSString *const GCMouseDidBecomeCurrentNotification;
GAMECONTROLLER_EXPORT NSString *const GCMouseDidStopBeingCurrentNotification;
@interface GCMouse : NSObject <GCDevice>          // +mice, +current, .mouseInput

typedef void (^GCMouseMoved)(GCMouseInput *mouse, float deltaX, float deltaY);
@interface GCMouseInput
@property (copy, nullable) GCMouseMoved mouseMovedHandler;
@property (readonly) GCDeviceCursor *scroll;                       // x/y axes
@property (readonly) GCDeviceButtonInput *leftButton;
@property (readonly, nullable) GCDeviceButtonInput *rightButton;
@property (readonly, nullable) GCDeviceButtonInput *middleButton;
@property (readonly, nullable) NSArray<GCDeviceButtonInput *> *auxiliaryButtons;   // X1, X2, …
```
**[SDK]** — `GameController/GCMouse.h`, `GCMouseInput.h`, iOS 14+ / macOS 11+.

Moonlight registers `mouseMovedHandler`, `leftButton`/`middleButton`/`rightButton`
`.pressedChangedHandler`, `auxiliaryButtons[0]`/`[1]` for X1/X2, and `scroll.xAxis`/`scroll.yAxis`
`valueChangedHandler` in `ControllerSupport.m`. **[OSS]**

Caveats: `rightButton`, `middleButton`, and `auxiliaryButtons` are all **nullable** — a device may
report fewer buttons than it physically has. Moonlight's comment that "GCMouse doesn't recognize many
mice correctly" is from iOS 14; **whether generic Bluetooth mice and the Magic Keyboard trackpad are
now reliably surfaced as `GCMouse` on iPadOS 26/27 is unverified and must be tested with the actual
Logitech mouse.** **[ASSUMED]**

There is also `GCKeyboard.coalesced` / `GCKeyboardInput` with
`GCKeyboardValueChangedHandler = (GCKeyboardInput, GCControllerButtonInput, GCKeyCode, Bool) -> Void`
— explicit per-key down/up, side-distinguished (`GCKeyLeftControl` vs `GCKeyRightControl`),
layout-independent, bypassing the responder chain entirely. **[APPLE]** It is the closest thing
iPadOS has to a raw HID keyboard stream and is worth prototyping as an alternative to
`pressesBegan`. Unknown: whether it receives keys SpringBoard consumes (almost certainly not), and
whether it delivers repeat.

#### Mouse buttons through UIKit

```objc
typedef NS_OPTIONS(NSInteger, UIEventButtonMask) {
    UIEventButtonMaskPrimary   = 1 << 0,
    UIEventButtonMaskSecondary = 1 << 1
} NS_SWIFT_NAME(UIEvent.ButtonMask) API_AVAILABLE(ios(13.4));
/// Raw format of: 1 << (buttonNumber - 1);  .button(1) == .primary, .button(2) == .secondary
UIKIT_EXTERN UIEventButtonMask UIEventButtonMaskForButtonNumber(NSInteger buttonNumber)
    NS_SWIFT_NAME(UIEventButtonMask.button(_:));
@property (readonly) UIEventButtonMask buttonMask;      // on UIEvent
@property (readonly) UIKeyModifierFlags modifierFlags;  // on UIEvent
```
**[SDK]** — `UIEvent.h`.

- Only `.primary` and `.secondary` are *named*, but the mask is an `NSInteger` bitfield, so
  **button 3 (middle) and beyond are representable** via `.button(3)`, `.button(4)`, `.button(5)`.
- **Middle click IS delivered** to third-party apps: Moonlight maps `UIEventButtonMaskForButtonNumber(3)`
  to its middle button. Side buttons X1/X2 are handled by Moonlight **only via `GCMouse.auxiliaryButtons`**,
  not via `buttonMask` — strong evidence that UIKit does *not* deliver buttons 4/5 to apps.
  **[OSS] — verify.**
- There is **no `buttonMask` on `UITouch`** — it is on `UIEvent`. The shipping pattern (Moonlight)
  is to diff `event.buttonMask` against a stored `lastMouseButtonMask` in
  `touchesBegan/Moved/Ended` and synthesize press/release transitions yourself. **[OSS]**
- Moonlight also normalises an OS difference: *"iOS 14 includes the released button in the buttonMask
  for the release event, while iOS 13 does not."* Re-verify this on iPadOS 26/27. **[OSS]**
- Canonical secondary-click test from WWDC20 **[APPLE]**:
  ```swift
  let secondaryClick = event.buttonMask == .secondary
  let controlClick   = event.buttonMask == .primary && event.modifierFlags == .control
  ```
  `UIGestureRecognizer.buttonMaskRequired` lets a recognizer demand a specific button.
- Motion **while a button is held** does *not* come through `pointerInteraction(_:regionFor:…)`;
  Moonlight handles it in `touchesMoved:` specifically *"to properly support drags while the middle,
  X1, or X2 mouse buttons are held down."* **[OSS]**

#### Hover / continuous location

```objc
@interface UIHoverGestureRecognizer : UIGestureRecognizer
@property (readonly) CGFloat zOffset              API_AVAILABLE(ios(16.1));
- (CGFloat)azimuthAngleInView:(nullable UIView *)view      API_AVAILABLE(ios(16.4));
- (CGVector)azimuthUnitVectorInView:(nullable UIView *)view API_AVAILABLE(ios(16.4));
@property (readonly) CGFloat altitudeAngle        API_AVAILABLE(ios(16.4));
@property (readonly) CGFloat rollAngle            API_AVAILABLE(ios(17.5));
```
**[SDK]**

- Fires for **both** indirect pointer and Pencil hover. Separate them with `allowedTouchTypes`:
  Moonlight uses a dedicated recognizer with `allowedTouchTypes = @[@(UITouchTypePencil)]` for
  stylus hover, and gets pointer position from the `UIPointerInteraction` region callback instead. **[OSS]**
- `zOffset` doc: *"This value is `1` at the maximum distance from the screen and approaches `0` as the
  pointing device gets closer… This value is `0` for devices that don't support `zOffset`."*
  ⚠️ **`0` means both "touching" and "unsupported"** — you cannot use `zOffset == 0` as a hover test.
  Same "0 if unsupported" semantics for `altitudeAngle`, `azimuthAngle(in:)` and `rollAngle`. **[SDK/APPLE]**
- ⚠️ The `UIHoverGestureRecognizer` **class-level documentation is stale**: it still says *"On iOS,
  this class doesn't recognize gestures."* That text predates iPadOS 13.4 pointer support and Pencil
  hover, and is contradicted by the per-property docs and Apple's own Pencil-hover sample. Treat it
  as iPhone-only. **[APPLE — contradictory docs]**
- `UITouch.Phase.regionEntered` / `.regionMoved` / `.regionExited` are the touch-level equivalents
  and, per Apple, *"don't always align with the `state` property of a `UIHoverGestureRecognizer`.
  States of the hover gesture recognizer only apply within the context of the gesture's view, whereas
  the touch states apply within the window."* **[APPLE]**

**Recommendation:** for absolute pointer position use `UIPointerInteraction`'s
`regionForRequest:defaultRegion:` (Moonlight's approach) as the primary channel; add a
`UIHoverGestureRecognizer` restricted to `.pencil` for Pencil hover; use `touchesMoved:` for
button-held drags. Sampling rate is whatever the device delivers (120 Hz on ProMotion) — **unverified
whether hover/pointer events are coalesced; check `event.coalescedTouches(for:)` on device.**

#### Scroll capture

```objc
typedef NS_ENUM(NSUInteger, UIScrollType) {
    UIScrollTypeDiscrete,    // "Discrete scrolls originate from devices like a scroll wheel mouse"
    UIScrollTypeContinuous,  // "Continuous scrolls originate from devices like trackpads"
} API_AVAILABLE(ios(13.4));
typedef NS_OPTIONS(NSInteger, UIScrollTypeMask) {
    UIScrollTypeMaskDiscrete   = 1 << UIScrollTypeDiscrete,
    UIScrollTypeMaskContinuous = 1 << UIScrollTypeContinuous,
    UIScrollTypeMaskAll        = …
};
@property UIScrollTypeMask allowedScrollTypesMask;   // on UIPanGestureRecognizer, iOS 13.4+
```
**[SDK]** — `UIPanGestureRecognizer.h`. Note it is a property on the *pan recognizer*, not on the event.

**There is no per-update "which scroll type produced this?" accessor.** The shipping technique —
Moonlight's — is to install **two separate pan recognizers** on the same view, each restricted to one
mask, and let the routing tell you the type: **[OSS]**

```objc
discrete.allowedTouchTypes      = @[@(UITouchTypeIndirectPointer)];
discrete.allowedScrollTypesMask = UIScrollTypeMaskDiscrete;      // → LiSendScrollEvent(±1) notches
continuous.allowedTouchTypes      = @[@(UITouchTypeIndirectPointer)];
continuous.allowedScrollTypesMask = UIScrollTypeMaskContinuous;  // → high-res, normalized by bounds
// both: maximumNumberOfTouches = 0
```
Moonlight also sign-flips horizontal scroll: *"Direction is reversed from vertical scrolling."*

- `translation(in:)` / `velocity(in:)` are in **points** of the given view's coordinate space, same as
  a finger pan. For a discrete wheel notch, one notch produces a fixed translation step — treat it as
  `±1 notch`, not as points. **Measure the actual per-notch value on the Logitech mouse.** **[ASSUMED]**
- **UIKit does NOT add momentum/deceleration to a bare `UIPanGestureRecognizer`.** Deceleration is a
  `UIScrollView` behaviour (`decelerationRate`, `.normal` / `.fast`), not a gesture behaviour.
  So a plain pan gives you the raw trackpad delta stream and *stops* when the fingers lift. **[ASSUMED —
  no Apple statement found, but consistent with the API surface: `UIPanGestureRecognizer` has no
  deceleration API at all.]**
- **The momentum-harvesting trick:** if you want iPadOS-native momentum curves to drive the host's
  momentum scroll, put an invisible `UIScrollView` with a huge `contentSize` under (or over) the
  stream, set `showsVerticalScrollIndicator = false`, `isDirectionalLockEnabled` as desired,
  and observe `scrollViewDidScroll(_:)` deltas plus
  `scrollViewWillBeginDecelerating` / `scrollViewDidEndDecelerating` to know when you are in
  momentum. Re-centre `contentOffset` each frame so it never hits a boundary. Then map:
  drag → CG phase began/changed/ended; deceleration → CG momentum begin/continue/end.
  **This is the cleanest way to get Apple's own momentum curve onto the Mac.** **[ASSUMED — worth
  prototyping; none of the reference apps do it, they all synthesize momentum host-side or not at all.]**
- Gesture state for a wheel: the recognizer does go `.began → .changed… → .ended`, but a single notch
  can produce a degenerate began/ended pair. Do not rely on wheel `.began` meaning "gesture start".
  **Verify.** **[ASSUMED]**
- **Natural scrolling on iPad** (Settings → General → Trackpad & Mouse → Natural Scrolling) is applied
  *before* your app sees the deltas, and there is **no public API to read the setting**. Combined with
  the host-side setting, you can have two inversions. See §A.4 — normalise on the client, expose one
  toggle.

#### Absolute vs relative, and the cursor escaping the view

There is no way to *prevent* the pointer leaving your view except pointer lock. The shipping designs:

| Product | Technique |
|---|---|
| **Moonlight** | `UIPointerRegion` scoped to the video rect (pointer regains normal appearance outside); `preferredScreenEdgesDeferringSystemGestures = .all` so an accidental edge swipe doesn't kill the stream; `prefersPointerLocked` only when a `GCMouse` exists |
| **Jump Desktop** | Explicit **Mouse Pointer Lock** toggle, `⌘⇧P`, iPadOS 14+ with a physical mouse; plus an edge-dwell escape ("Park the pointer at the top edge of the screen for a moment to reveal [the iPadOS menu bar]") |
| **Screens** | Treats edges as *host* affordances: a straight-line edge swipe pushes the *remote* cursor to the corresponding remote edge (Dock / menu bar / Hot Corners). Historical bugs — "cursor could move out of the remote display area when trackpad mode is enabled", "Hot Corners trigger when cursor was out of bounds" — are a warning to clamp aggressively |
| **Apple (Universal Control)** | A deliberate, resisted, *previewed* **edge push-through**: "the other device shows the pointer beginning to push through to its screen"; user-visible setting "Push through the edge of a display…" |

**Recommendation:** default to absolute mapping with the pointer hidden and the region scoped to the
video rect. Offer pointer lock as an explicit mode with a visible indicator and a documented escape
(`⌘⇧P`-style, plus a long two-finger hold). For leaving the view in absolute mode, copy Universal
Control: require a deliberate, resisted edge push with visual feedback rather than an instant escape.

### B.2 Hardware keyboard

#### The press API

`UIResponder.pressesBegan/pressesChanged/pressesEnded/pressesCancelled(_:with:)`, each taking
`Set<UIPress>` and `UIPressesEvent?`. Apple: *"Generally, responders that handle press events should
override all four of these methods,"* and each default implementation *"forwards the message up the
responder chain"* — so call `super` for anything you don't consume. **[APPLE]**

`UIPress` → `key: UIKey?`, `phase`, `type: UIPress.PressType`, `force`, `timestamp`, `responder`,
`window`, `gestureRecognizers`. `UIKey` (iOS 13.4+) has exactly four data properties:
`keyCode: UIKeyboardHIDUsage`, `modifierFlags: UIKeyModifierFlags`, `characters: String`,
`charactersIgnoringModifiers: String`. **[APPLE]**

> ⚠️ **`pressesChanged` is NOT key repeat.** Apple: *"UIKit calls this method when an analog value
> associated with a button or thumbstick changes."* It is a game-controller concept. **[APPLE]**

> ⚠️ **Duplicate presses are expected.** Apple Frameworks Engineer, Sept 2025:
> *"It is expected in some cases to get two different presses and two
> `pressesBegan|Changed|Ended|Cancelled` callbacks… **Only one of the presses should have the `key`
> property set**… The other one should have the `key` property be `nil` and instead have a `type`
> set."* **Filter with `presses.compactMap(\.key)`.** **[APPLE]**

> ⚠️ **`pressesCancelled` is your stuck-modifier guard.** Apple: it fires on *"a system interruption…
> anything that causes the application to become inactive or causes the view handling the press events
> to be removed from its window."* On cancel — and on backgrounding, and on disconnect — synthesize
> key-up for every key you believe is held. **[APPLE]**

Gesture recognizers see presses first (`UIGestureRecognizer.pressesBegan(_:with:)`,
`UIGestureRecognizerDelegate.gestureRecognizer(_:shouldReceive press:)`) even though they aren't in
the responder chain. **[APPLE]**

#### Modifiers, left/right, Caps Lock

- `UIKeyboardHIDUsage` has side-distinct cases: `.keyboardLeftControl` (0xE0) … `.keyboardRightGUI`
  (0xE7), plus `.keyboardCapsLock` (0x39). Apple documents the raw values as USB HID usages. **[APPLE][SDK]**
- **Modifier-only presses are delivered** as `UIPress` with a `key` carrying the side-specific
  `keyCode` — Moonlight's shipping switch maps `LeftShift → VK_LSHIFT 0xA0`, `RightShift → 0xA1`,
  `LeftControl → 0xA2`, `RightControl → 0xA3`, `LeftAlt → 0xA4`, `RightAlt → 0xA5`,
  `RightGUI → 0x5C`, and `CapsLock`, and it `assert(0)`s on anything unhandled, so those paths are
  live. **[OSS]**
- `UIKey.modifierFlags` is a **per-press snapshot** with **no left/right distinction**:
  `.alphaShift` (Caps Lock), `.shift`, `.control`, `.alternate`, `.command`, `.numericPad`.
  **There is no `.function` / `.globe` flag.** **[APPLE]**
- `UIGestureRecognizer.modifierFlags` (iOS 13.4+) gives held modifiers during a gesture — use it for
  Shift-drag / Cmd-click passthrough. **[APPLE]**
- **Caps Lock lock-state:** no query API. Track the toggle yourself from `.alphaShift` appearing in
  subsequent `UIKey.modifierFlags`. Blink documents the resulting user-visible failure: *"Caps Lock
  may be in an unexpected state when you leave and re-enter Blink due to the limitations of iOS
  development."* **[COMMUNITY]**

#### Key repeat

- **For `UIKeyCommand`, repeat is real and now controllable (iOS 26+).** Verified in the SDK **[SDK]**:
  ```objc
  // UIMenuElement.h
  typedef NS_ENUM(NSInteger, UIMenuElementRepeatBehavior) {
      UIMenuElementRepeatBehaviorAutomatic = 0,
      UIMenuElementRepeatBehaviorRepeatable,
      UIMenuElementRepeatBehaviorNonRepeatable,
  } API_AVAILABLE(ios(26.0)) NS_SWIFT_NAME(UIMenuElement.RepeatBehavior);
  // UIMenuLeaf.h  (UIAction, UIKeyCommand conform)
  /// Menu leaves can repeatedly perform their primary actions on prolonged interactions,
  /// such as by holding down their keyboard shortcut.
  @property (nonatomic) UIMenuElementRepeatBehavior repeatBehavior;
  ```
  Per-responder override hook is `- (void)validateCommand:(UICommand *)command` (iOS 13+) **[SDK]** —
  WWDC25 session 243's "validateCommand" is this selector, not a new symbol.
- **For raw `pressesBegan`, Apple has never documented repeat**, and Apple's own WWDC20 sample is
  level-triggered (`pressesBegan` → start, `pressesEnded` → stop). **[APPLE]**
- **Recommendation: don't depend on it either way.** Send discrete down/up on the wire and generate
  repeat on the macOS host (§A.5), which also matches host key-repeat settings.

#### What iPadOS swallows, and what you can reclaim

`UIKeyCommand.wantsPriorityOverSystemBehavior` (iOS 15+, default `false`). Apple, verbatim:
*"In iOS 15 and later, the system delivers physical keyboard events to the **text input or focus
systems first**. If those systems don't handle the keyboard input, the system delivers the events to
your app's key commands… If the value of this property is `true`, the system reverses that order…
If your app links against iOS 14 SDK or earlier, your app retains [the old] behavior."* **[APPLE]**

> **Read that precisely: it arbitrates against *text input and focus*, not against SpringBoard.**
> Nothing in Apple's wording claims it can reclaim shell shortcuts.

| Combo | Reachable by the app? | Notes |
|---|---|---|
| Tab / Shift-Tab / arrows | **Yes, with `wantsPriorityOverSystemBehavior = true`** | Documented iOS 15 regression + fix in forum 687666 **[APPLE/COMMUNITY]** |
| Esc | **Yes**, ordinary app key (`UIKeyCommand.inputEscape`, `.keyboardEscape`). UIKit will use it to dismiss sheets if you don't consume it. The 2024 M4 Magic Keyboard has a physical Esc. **[APPLE]** |
| ⌘Tab (app switcher) | **No** | SpringBoard **[APPLE for existence, COMMUNITY for non-interceptability]** |
| ⌘Space (Spotlight) | **No** | SpringBoard |
| ⌘⇧3 / ⌘⇧4 (screenshot) | **No** | SpringBoard |
| **Globe + anything** | **No** | iPadOS 26 assigns Globe-A (Dock), Globe-⇧A (App Library), Globe-C (Control Center), **Globe-H (Home)**, Globe-M (Menu Bar), Globe-N (Lock Screen), Globe-E (Emoji), Globe-D (Dictation), Globe-F (full screen), ⌃-Globe-arrows (window tiling) **[APPLE]** |
| ⌘H | **Probably yes now** — Home moved to **Globe-H** on modern iPadOS. Verify. |
| Brightness / volume / media keys | **No** | Consumed below the app |
| ⌘Q | n/a | **iPadOS has no app-quit shortcut** |

**Globe key itself:** Moonlight has a magic constant:
```objc
case 669: // "Globe" or "Language" key on most Apple branded iPad keyboards
    keyCode = 0x1B; // Escape, "which is missing from most Apple branded iPad keyboards"
```
669 = 0x29D, **outside the HID keyboard page and not a documented `UIKeyboardHIDUsage` case**.
**[OSS]** Whether it still arrives on iPadOS 26/27 — and whether it arrives when Globe is *not*
remapped in Settings — is unverified. Note Moonlight's remap is now obsolete on the 2024 Magic
Keyboard, which has a real Esc.

#### Key-command plumbing, and why to avoid it

- `UIResponder.keyCommands: [UIKeyCommand]?` — *"applied to the entire responder chain… UIKit walks
  the responder chain looking for an object that implements the corresponding action method."* **[APPLE]**
- `UIViewController.addKeyCommand(_:)` / `removeKeyCommand(_:)`. **[APPLE]**
- **Set `allowsAutomaticLocalization = false` and `allowsAutomaticMirroring = false`** on every
  command. The first *"determines whether the system automatically remaps keyboard shortcuts based on
  the keyboard layout"*; the second swaps inputs on RTL. Neither is wanted in a passthrough app. **[APPLE]**
- On iPadOS 26 the menu bar is a first-class surface (*"a swipe from the top reveals your app's full
  menu even without a hardware keyboard"*), so every `UIKeyCommand` you install into the main menu
  becomes user-visible clutter and appears in the ⌘-hold HUD. **[APPLE]**

**Recommendation:** use raw `pressesBegan/Ended` on the stream surface for everything, and register
only a handful of local `UIKeyCommand`s (disconnect, toggle keyboard, toggle pointer lock, toggle
toolbar) — all under a distinctive prefix so they can't collide with passthrough. Screens uses
**⇧⌃⌘** as its universal client-shortcut prefix; copy that. **[COMMUNITY]**

Also worth stealing from Screens: *"System shortcuts will now be sent to the remote computer **only
when the cursor is within the connection window**"* — focus-scoped passthrough. **[COMMUNITY]**
And Jump Desktop's bug to avoid: holding ⌘ to show their macro help sheet blocked ⌘-click, ⌘-drag,
and ⌘-scroll passthrough.

#### Layouts: send scancodes, not characters

`UIKey.characters` = *"the text value of the key combined with any active modifier keys"*;
`charactersIgnoringModifiers` = *"without modifier keys."* Both are layout-dependent by construction;
`keyCode` is the layout-independent physical position. **[APPLE]**

Moonlight sends **layout-independent scancodes** (HID usage → Win32 VK) and ignores `characters`
entirely on the hardware path. **[OSS]**
Screens documents the same split explicitly: *"Screens sends keystrokes, not characters… the keyboard
layout selected on the **remote computer** determines how those keystrokes are interpreted"*, with a
separate **Unicode** mode for non-Mac hosts and all virtual keyboards. **[COMMUNITY]**
RustDesk is the cautionary tale: it forces character/keysym Legacy mode on mobile, producing
systematic symbol mis-mapping for non-US layouts, with no mode selector in the iOS UI. **[COMMUNITY]**

**There is no supported API to read the active *hardware* keyboard layout on iPadOS.**
`TISCopyCurrentKeyboardInputSource` is macOS-only. `UITextInputMode.activeInputModes` /
`UIResponder.textInputMode` describe *software* keyboard language modes, not physical layout. **[APPLE]**
The one useful adjacent signal is `UITextInputContext.isHardwareKeyboardInputExpected` (plus
`isDictationInputExpected`, `isPencilInputExpected`). **[APPLE]**

#### Synthesizing / intercepting presses

`UIApplication.sendEvent(_:)` can be overridden — Apple: *"If your app must handle incoming events
before the system does — **a very rare situation**… you must dispatch it by calling
`[super sendEvent:event]`."* **[APPLE]** Useful only as a single global choke point to forward every
press regardless of first responder. **You cannot synthesize presses**: `UIPress` / `UIPressesEvent`
have no public initializer and `UIKey` has only `init(coder:)`. And interception happens *after*
SpringBoard has taken its cut, so it recovers nothing.

#### Blink Shell — evidence of where the UIKit ceiling is (do not copy)

Blink runs a hidden `WKWebView` as its key-capture surface so it can read W3C `KeyboardEvent`
(`code`, `repeat`, full modifier state) that UIKit doesn't expose. It **swizzles `WKContentView`**
via an obfuscated class lookup, with the comment *"We know this is not cool. but it is only way to fix
WkWebView — our radars: FB9628179, webkit.org/b/230360"*, to force
`smartDashesType`/`smartQuotesType`/`autocorrectionType`/`spellCheckingType` off,
`autocapitalizationType = .none`, `smartInsertDeleteType = .no`, and
`writingToolsBehavior = .none`. It also registers `UIKeyCommand(input: "", modifierFlags: flags)`
(empty input, modifiers only) to observe modifier press/release, paired with a **private** `upAction`
selector. **[OSS]** Cite as evidence; do not ship any of it.

### B.3 Software keyboard for remote text entry

#### `UIKeyInput` vs full `UITextInput`

`UIKeyInput` is three members — `insertText(_:)`, `deleteBackward()`, `hasText` — and Apple warns:
*"**Only a small subset of the available keyboards and languages are available to classes that adopt
this protocol.**"* **[APPLE]**

Everything you lose with bare `UIKeyInput` **[APPLE]**:
- **Marked text / multistage input is impossible.** Apple: *"Multistage text input is a requirement
  when the language is ideographic and the keyboard is phonetic."* No CJK IME, no dead-key accents.
- No caret, no selection UI, no text-range geometry (all `UITextInput` responsibilities).
- **Dictation is undocumented for `UIKeyInput`.** The documented dictation hooks
  (`insertDictationResult(_:)`, `UIDictationPhrase`, `dictationRecordingDidEnd()`) are all on
  `UITextInput`. **Must test.**
- Emoji: **[ASSUMED]** the emoji keyboard inserts plain Unicode so it should flow through
  `insertText(_:)`; no Apple statement confirms it.

**Recommendation:** implement **full `UITextInput`** over a small sentinel buffer. You get marked text
(so you can forward only *committed* text to the host and render composition locally), caret
geometry, and the documented dictation path. The cheap alternative — Moonlight's — is a `UITextField`
subclass with autocorrect off, plus an override of `editingInteractionConfiguration` returning
`UIEditingInteractionConfigurationNone` *"to suppress the Undo menu that appears with a 3 finger
tap."* **[OSS]** Steal that override regardless.

#### The empty-buffer backspace problem

Return `hasText = true` unconditionally (or keep a real non-empty sentinel string with the caret at
the end and re-seed after every edit) so the system keeps routing `deleteBackward()` to you. **[COMMUNITY]**
Separately, leave `enablesReturnKeyAutomatically = false` (the default) — Apple: *"If you set it to
`true`, the keyboard disables the Return key when the text entry area contains no text."* **[APPLE]**

#### Traits to disable — full list

All on `UITextInputTraits` unless noted; all confirmed **[APPLE]**:

| Property | Set to |
|---|---|
| `autocorrectionType` | `.no` |
| `autocapitalizationType` | `.none` |
| `spellCheckingType` | `.no` |
| `grammarCheckingType` | `.no` |
| `smartQuotesType` | `.no` |
| `smartDashesType` | `.no` |
| `smartInsertDeleteType` | `.no` (otherwise it auto-deletes/inserts spaces around cut/paste) |
| `inlinePredictionType` (iOS 17+) | `.no` (default is `.default`) |
| `writingToolsBehavior` (iOS 18+) | `.none` (cases `.none`/`.default`/`.complete`/`.limited`) |
| `mathExpressionCompletionType` (iPadOS 18+) | `.no` (Math Notes autocompletion) |
| `keyboardType` | `.asciiCapable` |
| `isSecureTextEntry` | `false` (true suppresses copy and can block screen recording) |
| `conversationContext` | `nil` (Smart Replies hook) |
| `textContentType` | unset (avoid AutoFill heuristics) |
| `enablesReturnKeyAutomatically` | `false` |

Plus `UIResponder.textInputContextIdentifier` — returning a stable string makes UIKit *"track the
current text input mode for the responder"*, so the user's chosen input language persists. **[APPLE]**

#### Shortcuts bar as the modifier bar

`UIResponder.inputAssistantItem: UITextInputAssistantItem` — Apple: *"On iPad, the shortcuts bar above
the keyboard contains typing suggestions and other controls… **The shortcuts bar isn't available on
iPhone.**"* It has `leadingBarButtonGroups`, `trailingBarButtonGroups` (`[UIBarButtonItemGroup]`), and
`allowsHidingShortcuts` (*"When `false`, the shortcuts bar remains visible while the keyboard is
visible. Default is `true`."*). *"When there's not enough space for all of the items, UIKit collapses
each group of items down to a single representative item."* Setting both arrays to `[]` hides the
shortcuts but **not** the typing suggestions. **[APPLE]**

**Confirmed: the shortcuts bar survives when the software keyboard hides for a hardware keyboard, and
can collapse to the floating pill.** Apple enumerates it as a distinct keyboard state: *"**The
shortcuts bar (available with an external attached keyboard):** Is always `awayFrom` the top edge and
`near` the bottom edge; **Can be `near` the leading or trailing edge when in a collapsed state.**"* **[APPLE]**

**Recommendation (Blink's architecture, which is right):** branch on whether a hardware keyboard is
attached — put Esc / Ctrl / Alt / Cmd / Tab / arrows / F-keys in the **shortcuts bar** when it is, and
in a full `inputAccessoryView` toolbar when it isn't. **[OSS]**

Modifier-button semantics to copy from Screens: *"Single tap: Creates a momentary press that releases
after keyboard or mouse action. Double tap: Locks the key in the pressed state. **Locked keys are
underlined.**"* Plus Screens 5.8.4: *"Modifier keys (hardware keyboard and toolbar) are now
synchronized."* **[COMMUNITY]** RealVNC does the same double-tap-to-lock. Moonlight's overlay uses
sticky toggle buttons carrying raw keycodes (Windows `0x5B`, Esc `0x1B`, Tab `0x09`, Shift `0xA0`,
Ctrl `0xA2`, Alt `0xA4`, Delete `0x2E`). **[OSS]**

#### Keyboard geometry

Use `UIView.keyboardLayoutGuide` (`UIKeyboardLayoutGuide: UITrackingLayoutGuide`), **not**
`keyboardWillShow` notifications — the notification behaviour with a hardware keyboard attached is
undocumented and historically buggy. **[APPLE]**

- `followsUndockedKeyboard` — default `false`; *"To follow all keyboard anchors even when undocked or
  floating, set [it] to `true`."*
- `keyboardDismissPadding` for the scroll-to-dismiss touch area.
- ⚠️ *"Constraints that use the keyboard layout guide's anchors directly **don't activate and
  deactivate automatically.** To get the full tracking behavior… use `setConstraints(_:activeWhenNearEdge:)`
  and `setConstraints(_:activeWhenAwayFrom:)`."*
- *"If the floating keyboard is available, but not over the app, the `keyboardLayoutGuide` behaves as
  if the keyboard is in a dismissed state."*
All **[APPLE]**.

### B.4 Touch modes and Apple Pencil

#### Touch types and routing

`UITouch.TouchType`: `.direct` (screen contact), `.indirect` (no screen contact),
`.pencil`, `.indirectPointer` (*"a button-based, indirect input device… from button press to button
release"*). `.stylus` is deprecated in favour of `.pencil`. **[APPLE]**

`UIGestureRecognizer.allowedTouchTypes: [NSNumber]` and `requiresExclusiveTouchType` — the latter:
*"When `true`, the gesture recognizer automatically ignores new touches whose type doesn't match the
type of the initial touch."* **[APPLE]**

**The clean way to avoid touch-pan vs pointer-scroll conflicts is `allowedTouchTypes`, not
simultaneity rules:** a two-finger pan restricted to `[.direct]` for finger scroll, and separate pans
restricted to `[.indirectPointer]` for wheel/trackpad scroll, all with
`requiresExclusiveTouchType = true`. Moonlight does the `.indirectPointer` half; the `.direct` half is
the obvious complement. **[OSS]**

Set **`cancelsTouchesInView = false`** on every recognizer over the stream surface, or recognition
will unbind the raw touch stream from your view. Apple: *"If a gesture recognizer recognizes its
gesture, it unbinds the remaining touches of that gesture from their view."* Related:
`delaysTouchesBegan`, `delaysTouchesEnded`, `require(toFail:)`,
`gestureRecognizerShouldBegin(_:)`, `gestureRecognizer(_:shouldReceive touch:)`. **[APPLE]**

`gestureRecognizer(_:shouldRecognizeSimultaneouslyWith:)` — *"returning `true` is guaranteed to allow
simultaneous recognition; returning `false`… is **not** guaranteed to prevent [it] because the other
gesture recognizer's delegate may return `true`."* UIKit only calls it for pairs on the same view. **[APPLE]**

**Undocumented but necessary:** kill iPadOS's own three-finger copy/paste/undo HUD. Moonlight's
technique, in `gestureRecognizerShouldBegin:` **[OSS]**:
```objc
// Disable the 3 finger tap gestures that trigger the copy/paste/undo toolbar on iOS 13+
return gestureRecognizer.name == nil || ![gestureRecognizer.name hasPrefix:@"kbProductivity."];
```
Also set `preferredScreenEdgesDeferringSystemGestures = .all` so an edge swipe doesn't yank the user
out of the session on the first try. **[OSS]**

#### Two touch modes — concrete constants from Moonlight

**Absolute / "direct touch"** (`AbsoluteTouchHandler.m`) **[OSS]**:
- `LONG_PRESS_ACTIVATION_DELAY 0.650 s`, `LONG_PRESS_ACTIVATION_DELTA 0.01` (normalized),
  `DOUBLE_TAP_DEAD_ZONE_DELAY 0.250 s`, `DOUBLE_TAP_DEAD_ZONE_DELTA 0.025`.
- Touch down → reposition cursor + press left **immediately**, *except* inside the double-tap
  deadzone ("Don't reposition for finger down events within the deadzone. This makes double-clicking
  easier"). Copy this — it is the single biggest feel improvement for tap-to-click.
- Long press → release left, press right. On touch up release both.
- Multi-finger is ignored here; pinch-zoom/pan are handled by an enclosing `UIScrollView`
  (`minimumNumberOfTouches = 2`, `maximumZoomScale = 10`) created **only** in absolute mode.

**Relative / "trackpad"** (`RelativeTouchHandler.m`) **[OSS]**:
- Motion scaled to a fixed 1280×720 reference before being sent as deltas.
- Movement < 5 px is not a "confirmed move".
- One-finger tap-and-hold 0.650 s → left button **held** (drag lock).
- **Two-finger tap with no movement → right click**, with a deliberate `usleep(100 ms)` between press
  and release *"to simulate a real button press."* Same 100 ms for left click. **Do this
  server-side instead** (hold the button for 100 ms on the host) so you don't block the client.
- Two-finger vertical drag → `LiSendHighResScrollEvent((avg.y - last.y) * 10)`.
- Dropping 2 fingers → 1 re-syncs the anchor and forces `touchMoved = true` *"so we don't send a left
  mouse click if the user right clicks without moving their other finger."* Real-world edge case —
  copy it.

#### Gesture vocabulary: what everyone agrees on

| Gesture | Screens 5 | Jump | Moonlight | Microsoft | RealVNC | bVNC | RustDesk |
|---|---|---|---|---|---|---|---|
| Tap | left click | left click | left click | left click | left click | left click | left click |
| Double tap | double click | double click | — | — | double click | — | — |
| **Two-finger tap** | **right click** | **right click** | right click (relative mode) | **right click** | **right click** | **right click** | **right click** |
| Long press | *(1-finger hold → drag)* | right click | right click (absolute mode) | right click | — | — | **right click** |
| **Three-finger tap** | **middle click** | show/hide keyboard | show/hide keyboard | — | **middle click** | **middle click** | — |
| Two-finger drag | scroll (V+H) | scroll | scroll | scroll | scroll | scroll | **canvas pan** |
| Three-finger drag | Mission Control shortcuts | pan | — | — | — | — | **scroll** |
| Pinch | local zoom | local zoom | local zoom | **local** zoom | local zoom | local zoom | local zoom |

**Two conventions are effectively universal: two-finger tap = right-click, and three-finger tap =
middle-click.** The conflict is that Moonlight, Jump, and Microsoft all reserve three-finger tap for
*show keyboard*. **You cannot have both.** Screens resolves it by putting the keyboard on a persistent
toolbar and keeping three-finger tap for middle click — that is the better answer for a Mac-host app,
because middle click matters (Xcode, browsers, terminal paste).

**Best idea to steal (Screens):** *colored hold indicators.* One-finger hold → **blue** → left drag;
two-finger hold → **red** → right-click drag; three-finger hold → **green** → middle-click drag. The
app tells you which button is armed *before* you commit to the drag. **[COMMUNITY]**

**Second best idea (Screens):** edge and corner swipes that move the *remote* cursor to the
corresponding remote edge/corner — reveals the Dock, the menu bar in full-screen apps, and triggers
macOS Hot Corners. And three-finger swipes that send **keyboard shortcuts** rather than trackpad
gestures (up = ⌃↑ Mission Control, down = ⌃↓ App Windows, left/right = ⌃←/⌃→ Spaces), reading the
user's actual configured shortcuts via a host helper. **[COMMUNITY]**

**Microsoft's table has one subtlety worth copying**: an explicit per-gesture column for *"Touch
gesture sent to remote session: Yes/No"*, and *"You can also include SHIFT and ALT modifiers with
touch gestures that are sent to a remote session."* **[COMMUNITY]**

#### Apple Pencil

Geometry, all **[APPLE]** unless noted:
- `UIEvent.coalescedTouches(for:)` — *"touches received by the system but not delivered in the last
  event"*; `predictedTouches(for:)` for latency hiding. Send coalesced samples to the host for
  smooth ink; discard predicted.
- `UITouch.force` / `maximumPossibleForce` — *"The force reported by Apple Pencil is measured **along
  the axis of the pencil**. If you want a force perpendicular to the device, you need to calculate
  this value using the `altitudeAngle`."* Also *"estimated at first, and may not always be updated"* —
  check `estimatedPropertiesExpectingUpdates` and correlate late corrections via
  `estimationUpdateIndex` in `touchesEstimatedPropertiesUpdated(_:)`.
- `altitudeAngle` — 0 rad = parallel to surface, π/2 = perpendicular.
- `azimuthAngle(in:)` — 0 rad when the cap end points along +x; *"It is more expensive to get the
  azimuth angle (as opposed to the azimuth unit vector)"* → use `azimuthUnitVector(in:)` in the hot path.
- **`UITouch.rollAngle`** — *"the current barrel-roll angle of Apple Pencil… For models that don't
  support barrel-roll angle data, the value of this property is `0`."* **This is the Pencil Pro
  barrel-roll API and it lives on `UITouch`, not on `UIPencilInteraction`.**
- `preciseLocation(in:)` / `precisePreviousLocation(in:)` — ⚠️ *"Do not use the returned point for hit
  testing."* Hit-test with `location(in:)`, send `preciseLocation(in:)` to the host.
- `majorRadius` / `majorRadiusTolerance` for finger contact size.

Moonlight's pencil pipeline, as a concrete reference **[OSS]**: `UITouchTypePencil` is intercepted
first in `touchesBegan/Moved` and sent as a dedicated pen event with normalized position,
pressure `= (force / maximumPossibleForce) / sin(altitudeAngle)`, rotation from azimuth, tilt from
altitude; hover via a `UIHoverGestureRecognizer` restricted to `.pencil` using `zOffset`.

**Pencil Pro squeeze and double-tap** — `UIPencilInteraction`, all **[APPLE]**:
```swift
func pencilInteraction(_ i: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap)
func pencilInteraction(_ i: UIPencilInteraction, didReceiveSqueeze s: UIPencilInteraction.Squeeze)
// deprecated: pencilInteractionDidTap(_:)
```
- `Tap` → `timestamp`, `hoverPose`. `Squeeze` → `phase`, `hoverPose`. `hoverPose` is `nil` *"if Apple
  Pencil isn't close enough to the screen to detect a hover, or if the device doesn't support hover."*
- `UIPencilInteraction.Phase`: `.began`, `.changed`, `.ended`, `.cancelled` — *"`ended`: A continuous
  gesture on the pencil ended, **or a discrete gesture on the pencil recognized**."*
- `UIPencilHoverPose`: `location`, `altitudeAngle`, `azimuthAngle`, `azimuthUnitVector`, `rollAngle`,
  `zOffset`.
- Class properties: `UIPencilInteraction.preferredTapAction`, `.preferredSqueezeAction`,
  `.prefersHoverToolPreview`, `.prefersPencilOnlyDrawing`.
- **`UIPencilPreferredAction` complete case list:** `.ignore`, `.switchEraser`, `.switchPrevious`,
  `.showColorPalette`, `.showInkAttributes`, **`.showContextualPalette`**, `.runSystemShortcut`.
- ⚠️ **If the user's preference is `.runSystemShortcut`, the squeeze never reaches your delegate.**
  Never gate a required feature on squeeze.
- Apple's canonical handler shape:
  ```swift
  if UIPencilInteraction.preferredSqueezeAction == .showContextualPalette, squeeze.phase == .ended,
     let anchor = squeeze.hoverPose?.location { presentContextualPalette(atLocation: anchor) }
  ```

Screens maps squeeze/double-tap to a user-chosen action from: toggle toolbar, **right click**,
**middle click**, or expand/collapse the floating toolbar — and with the Carousel toolbar style the
toolbar appears *at the Pencil tip.* Screens also uses **Pencil Pro hover to move the remote cursor
without touching.** Both are good. **[COMMUNITY]**

**Suppress Scribble** on the stream surface (`UIScribbleInteraction`, `UIIndirectScribbleInteraction`)
so Pencil strokes go to the host rather than into iPadOS handwriting. **[APPLE]**

iOS 26 Pencil additions are minimal: a new `UIResponder.toolPickerVisibility` and a reed-pen tool in
PencilKit. Nothing relevant here. **[COMMUNITY]**

### B.5 Haptics — the answer is not `UIImpactFeedbackGenerator`

- **The iPad body has no Taptic Engine.** `UIImpactFeedbackGenerator` /
  `UINotificationFeedbackGenerator` / `UISelectionFeedbackGenerator` do nothing to the device
  itself. Since 2024, iPad haptics come only from **Apple Pencil Pro** and the **M4 Magic Keyboard
  trackpad**. **[COMMUNITY]**
- **`UICanvasFeedbackGenerator` is the supported route.** Apple: *"creates haptics to indicate events
  on a drawing canvas… **When using Apple Pencil Pro with a compatible iPad, this type of feedback can
  provide a tactile response.**"* Two methods only: `alignmentOccurred(at:)` and `pathCompleted(at:)`.
  Init with `UICanvasFeedbackGenerator(view:)`; call `prepare()` on gesture `.began`. **[APPLE]**
  SwiftUI equivalents: `.sensoryFeedback(.alignment, trigger:)`, `.pathComplete`.
- Gating (Apple, Pencil haptics article): plays only *"on devices with haptic hardware,"* *"when the
  app is running in the foreground,"* and *"when the system Haptics setting is on."* **[APPLE]**
- iOS 17.5+ added a view-scoped `UIImpactFeedbackGenerator(view:)` and
  `impactOccurred(intensity:at:)` — apparently so impact feedback can be routed to Pencil Pro /
  trackpad. **Whether that actually fires the Pencil Pro or the M4 Magic Keyboard trackpad on the
  target hardware is unverified.** **[ASSUMED]**
- There is **no arbitrary-waveform Pencil haptic API**; Core Haptics does not target the Pencil.

**Recommendation:** don't design click feedback around haptics. Use a short click sound (respecting
the silent switch and a user setting) plus a visual cursor pulse. Try
`UICanvasFeedbackGenerator.pathCompleted(at:)` on click-with-Pencil as a bonus and measure whether
users notice.

### B.6 Staying awake, and backgrounding

- **`UIApplication.shared.isIdleTimerDisabled`** — Apple: *"You should set this property only if
  necessary and should be sure to reset it to `false` when the need no longer exists… The only apps
  that should disable the idle timer are mapping apps, games, or programs where the app needs to
  continue displaying content when user interaction is minimal."* A remote session watching a build
  run fits the last clause. **Scope it to an active session, not app lifetime.** **[APPLE]**
- **Backgrounding is a hard wall.** Apple: *"the system calls your app delegate's
  `applicationDidEnterBackground(_:)` method. **That method has five seconds** to perform any tasks and
  return. Shortly after that method returns, the system puts your app into the suspended state."* **[APPLE]**
- **`beginBackgroundTask(withName:expirationHandler:)`** buys a finite, *unspecified* extension —
  Apple does **not** promise 30 s; ~30 s is the observed figure, not a contract. Query
  `UIApplication.backgroundTimeRemaining`. *"If you don't call `endBackgroundTask(_:)` for each task
  before time expires, the system kills the app."* Must be called **before** entering background. **[APPLE]**
- **No background mode keeps a plain TCP/QUIC socket alive for a remote-desktop app.** Continuous
  background execution is granted only to audio, location, VoIP via PushKit + CallKit, external
  accessory, and `NEAppPushProvider` (special entitlement). A remote-desktop client fits none.
  `UIBackgroundModes: voip` without a real CallKit call is an App Review rejection, not a workaround.
  `BGAppRefreshTask` / `BGProcessingTask` are opportunistic and cannot hold a live stream. **[COMMUNITY]**

**Design implication — and this is a correctness issue, not just a UX one:** treat backgrounding as
disconnect. On `sceneDidEnterBackground`: take a background-task assertion, send a clean teardown
that **releases every held key and mouse button** on the host, then tear down. Same discipline on
`pressesCancelled`, on `touchesCancelled`, and on socket loss. The host should also run an
independent watchdog (§A.2) that force-releases all modifiers and buttons after N seconds of silence.

---

## C. Reference behaviours to emulate

### Screens 5 (Edovia) — the closest analogue to what Vantage should be
- Two virtual-cursor modes, **remembered per session** (5.0.5): Touch Mode (absolute, "positions the
  remote cursor based on where you tap") and Trackpad Mode (relative, "drag your finger anywhere…
  independently of your finger's position").
  <https://help.edovia.com/en/screens-5/features/cursor-control-modes-and-other-gestures>
- Gesture table is **identical in both modes**: tap = click, double-tap = double-click, two-finger tap
  = secondary click, three-finger tap = middle click, two-finger swipe = scroll (vertical *and*
  horizontal); one/two/three-finger touch-and-hold → **blue / red / green** indicator → left / right /
  middle drag.
- **Edge and corner swipes** move the *remote* cursor to that edge/corner (Dock, menu bar, macOS Hot
  Corners). **Three-finger swipes send keyboard shortcuts**, not gestures (⌃↑ Mission Control, ⌃↓ App
  Windows, ⌃←/⌃→ Spaces), reading the user's real shortcut config via the Screens Connect helper.
- Toolbar in three styles — **docked / floating / carousel** — with keyboard, Esc, Tab, arrows,
  Home/End, PgUp/PgDn, F-keys, "Type User Password", Actions. Modifier semantics: *"Single tap:
  momentary press that releases after keyboard or mouse action. Double tap: locks the key in the
  pressed state. **Locked keys are underlined.**"* Hardware and toolbar modifiers are synchronized (5.8.4).
  <https://help.edovia.com/en/screens-5/features/ios-toolbar>
- Client shortcuts all use a **⇧⌃⌘ prefix** so they can't collide with passthrough (⇧⌃⌘R screenshot,
  ⇧⌃⌘C disconnect, ⇧⌃⌘⌫ Ctrl-Alt-Del, ⇧⌃⌘P type password, …).
  <https://help.edovia.com/en/screens-5/features/keyboard-shortcuts-ipados-visionos>
  Passthrough is **focus-scoped**: *"System shortcuts will now be sent to the remote computer only when
  the cursor is within the connection window"* (5.1.2).
- Keyboard modes: **Keystrokes** (scancodes; "the keyboard layout selected on the remote computer
  determines how those keystrokes are interpreted") vs **Unicode** (for non-Mac hosts and all virtual
  keyboards). Key repeat with customizable delay/interval (5.8.5).
  <https://help.edovia.com/en/screens-5/features/keyboard-support>
- Pointing devices: left/right/double-click, drag, scroll — but **scroll requires Magic Mouse 2,
  Magic Trackpad 2, or Magic Keyboard**, and *"iPadOS reserves three-finger gestures"* on the Magic
  Trackpad, so those must be done on the display.
  <https://help.edovia.com/en/screens-5/features/pointing-devices-support>
- Apple Pencil: always absolute; **Pencil Pro hover moves the cursor without touching**; squeeze /
  double-tap is user-assignable to toggle toolbar, **right click**, **middle click**, or expand the
  floating toolbar; with Carousel the toolbar appears at the Pencil tip. No pressure forwarding.
  <https://help.edovia.com/en/screens-5/features/pencil-support>
- **Curtain Mode** (blank the host's physical display) requires **Remote Management**, not Screen
  Sharing; Mac hosts only; cannot activate at the login window.
  <https://help.edovia.com/en/screens-5/features/curtain-mode>
- Historical bugs that are direct warnings: *"cursor could move out of the remote display area when
  trackpad mode is enabled"* and *"Hot Corners could trigger when cursor was out of bounds"* — clamp.
  <https://releasenotes.edovia.com/screens-for-ios>

### Jump Desktop (iOS)
- **Fluid** is their own protocol: *"share your screen at 60fps while using only 1/10th of the
  bandwidth compared to… RDP and VNC"*, E2E encrypted, audio, adaptive quality, clipboard, multi-monitor.
  <https://support.jumpdesktop.com/hc/en-us/articles/216423983-General-Fluid-Remote-Desktop>
- Touch modes: **Standard**, **Locked Screen** (no zoom, three-finger pan), **Pen** (*"movement of the
  mouse cursor is done with the equivalent of the left mouse button held down"* — for capacitive styli).
  <https://support.jumpdesktop.com/hc/en-us/articles/216423623-iPad-Input-methods>
- Gestures: right click = **long tap OR two-finger tap**; left drag = *"2 quick taps and drag (don't
  lift your finger up after the 2nd tap — like on a trackpad)"*; scroll = two-finger vertical swipe;
  **three-finger tap = show/hide keyboard**. No middle-click gesture documented.
  <https://support.jumpdesktop.com/hc/en-us/articles/216423503-Getting-Started-Jump-Desktop-Controls-and-Gesture-Reference>
- **Mouse Circle** — a magnifier-style precision affordance: *"Tap and slide inside the circle for
  precision mouse positioning and clicking."* Their documented answer to window-edge resizing.
- **Trackpad (Gaming) gesture profile** gives pointer lock + relative deltas; **Mouse Pointer Lock**
  (iPadOS 14+, physical mouse) toggles with **⌘⇧P**, with configurable pointer acceleration/speed.
  <https://changelog.jumpdesktop.com/jump-desktop-for-ios-9.6.8-46Ul2g>
- **Keypads** — auxiliary on-screen keypads (arrows, numpad, F-keys); iPad opens via three-finger tap
  or keyboard icon, iPhone has four keypads swiped between.
  <https://support.jumpdesktop.com/hc/en-us/articles/216423643-Keyboard-Input>
- Physical keyboard: *"the physical keyboard works like a regular computer's keyboard. Shortcuts like
  Alt+Tab or Alt+Cmd just work… even the Esc key… **All keyboard keys and shortcut combinations
  work.**"* (Marketing overstatement — but it signals the bar.) **Macros** for compact keyboards,
  revealed by holding ⌘.
  <https://support.jumpdesktop.com/hc/en-us/articles/216423543-iOS-Physical-Keyboard-Support-and-Macros>
- Bug to avoid: the ⌘-hold macro sheet blocked ⌘-click / ⌘-drag / ⌘-scroll passthrough.
- Edge escape: *"Park the pointer at the top edge of the screen for a moment to reveal [the iPadOS
  menu bar]."* <https://changelog.jumpdesktop.com/>

### Moonlight iOS — the best open-source reference (read the code)
<https://github.com/moonlight-stream/moonlight-ios>
- `Limelight/Limelight-Info.plist` → `UIApplicationSupportsIndirectInputEvents = true`.
- `Limelight/Input/StreamView.m` — `UIPointerInteraction` + `hiddenPointerStyle`; video-rect-scoped
  `UIPointerRegion`; dual UIKit/`GCMouse` pointer paths; two `UIPanGestureRecognizer`s split by
  `allowedScrollTypesMask`; `pressesBegan/Ended`; three-finger tap → keyboard; `kbProductivity.`
  gesture suppression; `preferredScreenEdgesDeferringSystemGestures = .all`; Pencil pressure/tilt/
  hover.
- `Limelight/ViewControllers/StreamFrameViewController.m` — `prefersPointerLocked` gated on
  `GCMouse.mice.count > 0`; the zoom `UIScrollView` (absolute mode only).
- `Limelight/Input/KeyboardSupport.m` — the HID→VK table, the Globe (`case 669`) hack, the
  unichar→VK+synthetic-Shift path for the soft keyboard.
- `Limelight/Input/AbsoluteTouchHandler.m` / `RelativeTouchHandler.m` — the constants quoted in §B.4.
- `Limelight/Input/ControllerSupport.m` — `GCMouse` registration.
- `Limelight/Input/KeyboardInputField.m` — hidden text field + `inputAccessoryView` toolbar with
  sticky modifiers; `editingInteractionConfiguration = none` to kill the three-finger Undo menu.
- Docs gesture list: <https://github.com/moonlight-stream/moonlight-docs/wiki/Setup-Guide>

### RustDesk / bVNC / RealVNC — short
- **RustDesk** (`flutter/lib/mobile/widgets/gesture_help.dart`): Touch vs Mouse mode; long tap =
  right click in both; **three-finger vertical = scroll, two-finger = canvas pan** (the inverse of
  everyone else); explicit `Relative mouse mode` checkbox. Known iPad defect: attaching an external
  keyboard forces mouse mode into touch mode (<https://github.com/rustdesk/rustdesk/issues/13011>).
  Its mobile client is locked to character/keysym "Legacy" mode, producing systematic symbol
  mis-mapping on non-US layouts (<https://github.com/rustdesk/rustdesk/issues/14107>) — the strongest
  argument in this whole report for scancode forwarding.
- **bVNC Pro**: *"One finger tap left-clicks, two-finger tap right-clicks, and three-finger tap
  middle-clicks"*; *"Right and middle-drag and drop if you don't lift the first finger that tapped."*
  <https://apps.apple.com/us/app/bvnc-pro-vnc-screen-sharing/id1506461202> ·
  <https://github.com/iiordanov/remote-desktop-clients>
- **RealVNC Viewer**: Mouse mode positions the cursor *"offset from under your finger so you can always
  see it"* — a genuinely good touch-precision trick. Two-finger tap = right, three-finger tap =
  middle. Touch-panel mode has **no right-click gesture at all**. Virtual keyboard has a scrolling key
  bar; *"Double tap a modifier key … to hold that key down."* And: *"**If a hardware keyboard is
  detected, the virtual keyboard is not displayed. However, tapping the keyboard icon will still open
  the scrolling key bar.**"* Toolbar auto-minimizes after 20 s unless tapped to lock.
  <https://help.realvnc.com/hc/en-us/articles/360018541231-Using-RealVNC-Viewer-for-Mobile-to-control-a-remote-device>
  Current regression worth watching: Bluetooth/physical keyboard broken on iOS/iPadOS 26 —
  <https://help.realvnc.com/hc/en-us/articles/30601109296413>

### Microsoft Windows App on iPad — the canonical documented gesture table
<https://learn.microsoft.com/en-us/windows-app/input-keyboard-mouse-touch-pen>
- Two modes, verbatim: **Direct touch** — *"where you tap on the screen is the equivalent to clicking a
  mouse in that position. **The mouse pointer isn't shown on screen.**"* **Mouse pointer** — *"The
  mouse pointer is shown on screen. When you tap the screen and move your finger, the mouse pointer
  moves."*
- Their table has a column most people miss — *"Touch gesture sent to remote session: Yes/No."* Only
  pinch-zoom is **No** (local). *"You can also include SHIFT and ALT modifiers with touch gestures that
  are sent to a remote session."*
- Mouse-pointer mode: cursor = one-finger drag; left click = tap; left drag = **double-tap and hold,
  then drag**; right click = **two-finger tap or one-finger tap-and-hold**; right-click drag =
  double-tap and hold with two fingers, then drag; scroll = two-finger hold then drag.
- Keyboard: ⌘C/X/V/A/Z/F mapped to Windows equivalents; *"The Option key to the right of the space bar
  on an Apple keyboard equals the Alt Gr in Windows"*; **⌥⌘9 toggles between Windows and iPadOS
  behaviour** for European layouts — an excellent escape hatch pattern. Restriction:
  *"Third-party software keyboards aren't supported."*
- Their **scancode vs Unicode** write-up (macOS/Android/Quest tabs of the same page) is the clearest
  public treatment of the tradeoff.

### Apple's own conventions
- **HIG, Pointing devices** — *"The iPadOS pointing system gives people an additional way to interact
  with apps and content — **it doesn't replace touch**."* And, in direct tension with what we want:
  *"**Avoid redefining systemwide trackpad gestures.** Even in a game that uses app-specific gestures
  in a custom way, people expect systemwide gestures to be available."* Also *"Let people use the
  pointer to reveal and hide controls that automatically minimize or fade out"* — the native
  justification for edge-dwell toolbars. Pointer magnetism is applied to lift and highlight but
  deliberately **not** hover, because *"adding magnetism could be jarring and might make people feel
  that they've lost control of the pointer."*
  <https://developer.apple.com/design/human-interface-guidelines/pointing-devices>
- **WWDC20 10093 "Build for the iPadOS pointer"** — `UIPointerInteraction`, `UIPointerStyle`,
  `UIPointerRegion`, shape constraints (`.verticalBeam(length:)` + `constrainedAxes`), free behaviour
  in scroll views / text views / `UIDragInteraction` / `UIContextMenuInteraction`.
  <https://developer.apple.com/videos/play/wwdc2020/10093/> ·
  <https://developer.apple.com/documentation/UIKit/enhancing-your-ipad-app-with-pointer-interactions>
- **WWDC20 10094 "Handle trackpad and mouse input"** — pointer locking requirements, `allowedScrollTypesMask`,
  `buttonMaskRequired`, the secondary-click test, and the `UIApplicationSupportsIndirectInputEvents`
  semantics. <https://developer.apple.com/videos/play/wwdc2020/10094/>
- **Universal Control** — Apple's own answer to "how does the cursor leave a remote surface" is a
  deliberate, resisted, **previewed edge push-through** ("the other device shows the pointer beginning
  to push through to its screen"), behind a named user setting. Copy this model.
  <https://support.apple.com/en-us/102459>
- **Sidecar** — the **Sidebar** is a persistent on-screen modifier strip (⌘ ⌥ ⌃ ⇧ plus menu-bar and
  Dock toggles), justifying a permanent modifier bar as an Apple-blessed pattern. Note:
  *"**Beginning with iPadOS 27 and macOS 27, Sidecar offers greatly expanded support for using touch
  to interact with Mac windows and menus on iPad.**"* — worth studying for gesture vocabulary Apple
  itself has now chosen. <https://support.apple.com/en-us/102597>

---

## D. Open questions / verify on device

Ordered by how much a wrong answer would cost.

**Host (macOS 27)**
1. **Does the host's "natural scrolling" setting invert scroll deltas we *post*?** (§A.4) Test: post a
   fixed `+wheel1` with natural scrolling on and off and observe direction. Also determine whether
   field 137 changes anything for a posted (not captured) event.
2. **Does the macOS 26/27 WindowServer `CGXSenderCanSynthesizeEvents` gate affect a signed, notarized,
   PostEvent-granted app?** (§A.1a) Test: post a modifier-bearing key event and a mouse-down from the
   release build; check `log stream --predicate 'process == "WindowServer"'` for "Dropping … event
   because sender's PID".
3. **Phased vs phaseless scroll, per app.** Build a test harness that posts both and measure feel in
   Safari, Chrome, Xcode, Finder (icon + list), Mail, Terminal, iTerm, Figma, and a WebKit virtual
   list. Specifically check: does phased cause elastic bounce on wheel input; does a zero-delta
   `began` stall WebKit; does Xcode/Finder self-momentum when you stop after `ended`.
4. **Is the private type-29 `NSEventTypeGesture` event (fields 55/110/116/119/132) still honoured on
   macOS 27?** (§A.4) Without it, no Safari page-swipe / Mail swipe-actions.
5. **Does posting with `.combinedSessionState` vs `.hidSystemState` reset the idle timer / prevent the
   screensaver?** Measure with `CGEventSourceSecondsSinceLastEventType(.hidSystemState, kCGAnyInputEventType)`
   and `ioreg -c IOHIDSystem | grep HIDIdleTime`. (§A.2)
6. **Does a synthesized `.maskSecondaryFn` flag actually make the host treat F1 as Fn-F1?**
7. **`kCGMouseEventClickState` on down *and* up — confirm `NSEvent.clickCount` reads 2/3 correctly**
   in a test AppKit app and in Finder.
8. **Does `CGEventSourceSetLocalEventsSuppressionInterval(source, 0)` actually restore local
   mouse responsiveness during an active remote drag?** (§A.2)
9. **Secure Event Input detection** — does `IsSecureEventInputEnabled()` reliably flip when Terminal's
   Secure Keyboard Entry is on and when a password field is focused in Safari / 1Password?
10. **Tablet-subtype passthrough** — does setting `kCGMouseEventSubtype = .tabletPoint` plus
    `kCGTabletEventPointPressure` produce pressure-sensitive strokes in Procreate/Photoshop on the
    host? (Stretch goal; likely yes, unverified.)

**Client (iPadOS 27)**
11. **Does `prefersPointerLocked` engage under Stage Manager / windowed iPadOS 26–27?** WWDC20 said
    "full screen and foreground-active" for iPadOS 14. iPadOS 26 windowing may have changed this.
    Observe `UIScene.pointerLockState.isLocked`.
12. **Does `GCMouse` see the Logitech Bluetooth mouse, and does it see the Magic Keyboard trackpad?**
    And are `rightButton` / `middleButton` / `auxiliaryButtons` non-nil for that mouse? (Moonlight's
    "GCMouse is horribly broken for certain mice" comment is from iOS 14.)
13. **Are mouse buttons 4/5 (side buttons) delivered via `UIEvent.buttonMask` at all**, or only via
    `GCMouse.auxiliaryButtons`? Moonlight's code implies only the latter.
14. **Does iOS 26/27 still include the released button in `buttonMask` on the release event?**
    (Moonlight normalises an iOS 13 vs 14 difference here.)
15. **Does raw `pressesBegan` repeat while a key is held on iPadOS 27?** Design so it doesn't matter,
    but measure.
16. **Which shortcuts can `wantsPriorityOverSystemBehavior = true` actually reclaim on iPadOS 27?**
    Do an empirical sweep: ⌘Tab, ⌘Space, ⌘H, ⌘⇧3/4, Globe-*, Esc, media keys, ⌃↑/↓.
17. **Does Globe still arrive as raw `keyCode` 669**, and does it arrive when Globe is *not* remapped
    in Settings?
18. **Does `GCKeyboard` receive keys SpringBoard consumes?** (Almost certainly not, but it's the only
    remaining lever if `pressesBegan` is insufficient.) Does it deliver repeat?
19. **Does dictation reach a bare `UIKeyInput` responder via `insertText(_:)`?** If not, full
    `UITextInput` is mandatory, not merely recommended.
20. **What does the predictive/autocorrect strip do over a sentinel-buffer `UIKeyInput`?**
21. **What is one Logitech wheel notch worth in `translation(in:)` points** with
    `allowedScrollTypesMask = .discrete`? And does the recognizer produce a clean `.began`/`.ended`
    per notch?
22. **Does `UIImpactFeedbackGenerator(view:)` + `impactOccurred(intensity:at:)` fire Apple Pencil Pro
    or M4 Magic Keyboard trackpad haptics**, or is `UICanvasFeedbackGenerator` the only route?
23. **Are pointer/hover events coalesced at 120 Hz on the M4 iPad Pro**, and is
    `event.coalescedTouches(for:)` populated for `.indirectPointer` touches?
24. **Does the `kbProductivity.` gesture-name suppression trick still work on iPadOS 27?**
25. **Is there any iPadOS 27 change to `UIPointerLockState` / indirect input?** Nothing turned up in
    the iOS 27 UIKit round-ups, but they are community write-ups, not release notes.

**Design questions to settle before building**
26. Three-finger tap: **middle click** (Screens, RealVNC, bVNC) or **show keyboard** (Moonlight, Jump,
    Microsoft)? Recommend middle click + persistent toolbar for the keyboard.
27. Do we forward Pencil pressure/tilt to the host as tablet events (§A.3), and is that a v1 feature?
28. Do we implement Screens-style edge/corner swipes that drive the *remote* Dock / menu bar / Hot
    Corners? They solve a real problem (reaching the menu bar with the iPad's own menu bar in the way).

---

## Sources

**Apple SDK headers** (macOS 27.0 SDK / iPhoneOS 27.0 SDK, Xcode 27.0 build 27A5228h) — primary,
quoted verbatim throughout:
`CoreGraphics/CGEvent.h`, `CGEventTypes.h`, `CGEventSource.h`, `CGRemoteOperation.h`,
`CGDirectDisplay.h`; `IOKit/hidsystem/ev_keymap.h`, `IOLLEvent.h`; `IOKit/pwr_mgt/IOPMLib.h`;
`ApplicationServices/HIServices/AXUIElement.h`;
`Carbon/HIToolbox/Events.h`; `AppKit/NSEvent.h`; `ScreenCaptureKit/SCShareableContent.h`;
`UIKit/UIKeyConstants.h`, `UIKey.h`, `UIKeyCommand.h`, `UIMenuElement.h`, `UIMenuLeaf.h`,
`UIResponder.h`, `UIEvent.h`, `UIPanGestureRecognizer.h`, `UIPointerInteraction.h`,
`UIPointerStyle.h`, `UIPointerLockState.h`, `UIViewController.h`, `UIHoverGestureRecognizer.h`,
`UIPencilInteraction.h`; `GameController/GCMouse.h`, `GCMouseInput.h`.

**Apple documentation & DTS**
- Post Event vs Accessibility privilege, sandbox compatibility, sample code — Quinn, DTS:
  <https://developer.apple.com/forums/thread/730441>
- Accessibility vs Input Monitoring in sandboxed apps — Quinn, DTS:
  <https://developer.apple.com/forums/thread/780626>
- TN2150 *Using Secure Event Input Fairly*:
  <https://developer.apple.com/library/archive/technotes/tn2150/_index.html>
- CGEvent.post and App Review Guideline 2.4.5: <https://developer.apple.com/forums/thread/820594>
- CGEvent at the login window (unanswered): <https://developer.apple.com/forums/thread/62687> ·
  <https://developer.apple.com/forums/thread/724740> · <https://developer.apple.com/forums/thread/720050>
- Duplicate `UIPress` callbacks — Apple Frameworks Engineer, Sept 2025:
  <https://developer.apple.com/forums/thread/799219>
- `wantsPriorityOverSystemBehavior` and the iOS 15 Tab/arrow regression:
  <https://developer.apple.com/forums/thread/687666> ·
  <https://developer.apple.com/documentation/uikit/uikeycommand/wantspriorityoversystembehavior>
- No background mode for a remote-desktop socket: <https://developer.apple.com/forums/thread/717396>
- `UIKey` / `UIKeyboardHIDUsage` / `UIKeyModifierFlags` / `UIPress`:
  <https://developer.apple.com/documentation/uikit/uikey> ·
  <https://developer.apple.com/documentation/uikit/uikeyboardhidusage> ·
  <https://developer.apple.com/documentation/uikit/uikeymodifierflags> ·
  <https://developer.apple.com/documentation/uikit/uipress>
- `UIKeyInput` / `UITextInput` / `UITextInputTraits` / `UITextInputAssistantItem` /
  `UITextInputContext`:
  <https://developer.apple.com/documentation/uikit/uikeyinput> ·
  <https://developer.apple.com/documentation/uikit/uitextinput> ·
  <https://developer.apple.com/documentation/uikit/uitextinputtraits> ·
  <https://developer.apple.com/documentation/uikit/uitextinputassistantitem> ·
  <https://developer.apple.com/documentation/uikit/uitextinputcontext>
- Keyboard layout guide state matrix:
  <https://developer.apple.com/documentation/uikit/adjusting-your-layout-with-keyboard-layout-guide>
- Touch/Pencil: <https://developer.apple.com/documentation/uikit/leveraging-touch-input-for-drawing-apps> ·
  <https://developer.apple.com/documentation/uikit/adopting-hover-support-for-apple-pencil> ·
  <https://developer.apple.com/documentation/uikit/uitouch/force> ·
  <https://developer.apple.com/documentation/uikit/uitouch/rollangle> ·
  <https://developer.apple.com/documentation/uikit/uihovergesturerecognizer/zoffset>
- `UIPencilInteraction` family: <https://developer.apple.com/documentation/uikit/uipencilinteraction> ·
  <https://developer.apple.com/documentation/uikit/uipencilpreferredaction> ·
  <https://developer.apple.com/documentation/uikit/uipencilhoverpose>
- Haptics: <https://developer.apple.com/documentation/uikit/uicanvasfeedbackgenerator> ·
  <https://developer.apple.com/documentation/ApplePencil/playing-haptic-feedback-in-your-app>
- Idle timer / background: <https://developer.apple.com/documentation/uikit/uiapplication/isidletimerdisabled> ·
  <https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time>
- `GCKeyboard`: <https://developer.apple.com/documentation/gamecontroller/gckeyboard>
- WWDC20 10093 <https://developer.apple.com/videos/play/wwdc2020/10093/> ·
  WWDC20 10094 <https://developer.apple.com/videos/play/wwdc2020/10094/> ·
  WWDC20 10109 <https://developer.apple.com/videos/play/wwdc2020/10109/> ·
  WWDC25 243 <https://developer.apple.com/videos/play/wwdc2025/243/> ·
  WWDC25 285 <https://developer.apple.com/videos/play/wwdc2025/285/>
- HIG Pointing devices: <https://developer.apple.com/design/human-interface-guidelines/pointing-devices>
- iPad keyboard shortcuts (Globe-*): <https://support.apple.com/en-us/102393>
- Universal Control: <https://support.apple.com/en-us/102459> · Sidecar: <https://support.apple.com/en-us/102597>

**Open source**
- Mac Mouse Fix `Helper/Core/Touch/GestureScrollSimulator.m` (and `GestureScrollSimulator_old_.m`) —
  the reference synthetic-trackpad-scroll implementation:
  <https://github.com/noah-nuebling/mac-mouse-fix>
- Moonlight iOS — `Limelight/Input/{StreamView.m, KeyboardSupport.m, AbsoluteTouchHandler.m,
  RelativeTouchHandler.m, ControllerSupport.m, KeyboardInputField.m}`,
  `Limelight/ViewControllers/StreamFrameViewController.m`, `Limelight/Limelight-Info.plist`:
  <https://github.com/moonlight-stream/moonlight-ios> ·
  <https://github.com/moonlight-stream/moonlight-docs/wiki/Setup-Guide>
- Chromium `ui/events/keycodes/dom/dom_code_data.inc` — the cross-validated USB HID ↔ macOS keycode
  table used to build §A.5b:
  <https://chromium.googlesource.com/chromium/src/+/main/ui/events/keycodes/dom/dom_code_data.inc>
- Blink Shell `KB/Native/Views/KBWebViewBase.m`, `KB/Native/Model/KeyCode.swift`,
  `Blink/SmarterKeys/SmarterTermInput.swift`: <https://github.com/blinksh/blink>
- Scroll Reverser: <https://pilotmoon.com/scrollreverser/> · LinearMouse:
  <https://github.com/linearmouse/linearmouse>
- MediaKeyTap (system-defined media key events): <https://github.com/the0neyouseek/MediaKeyTap>
- RustDesk `flutter/lib/mobile/widgets/gesture_help.dart`: <https://github.com/rustdesk/rustdesk> ·
  issues <https://github.com/rustdesk/rustdesk/issues/13011>,
  <https://github.com/rustdesk/rustdesk/issues/14107>
- bVNC / remote-desktop-clients: <https://github.com/iiordanov/remote-desktop-clients>
- MeshCentral macOS agent (login-window injection via `screensharingd`):
  <https://github.com/stanelie/meshcentral-mac-agent>

**Community reports (treat as leads, not facts)**
- macOS 26 `CGXSenderCanSynthesizeEvents` / three TCC buckets:
  <https://www.nick-liu.com/posts/tahoe-hotkey-dead-end/>
- Phased vs phaseless synthetic scroll, and the macOS 26 iPhone Mirroring case:
  <https://github.com/AprilNEA/OpenLogi/pull/1157> · <https://github.com/ShawnPana/phone-harness/pull/52>
- Natural scrolling and captured-vs-posted scroll deltas:
  <https://github.com/feschber/lan-mouse/issues/451>
- `CGEventKeyboardSetUnicodeString` 20-character limit:
  <https://forum.qt.io/topic/46579/cgeventkeyboardsetunicodestring-will-only-process-up-to-20-characters>
- Virtual-key-0 text injection typing a burst of "a":
  <https://github.com/omacom/try-omarchy/issues/222> ·
  <https://github.com/quicksilver/Quicksilver/pull/1827>
- Secure Input held system-wide by other apps:
  <https://www.1password.community/1password-at-work-58/secure-input-blocking-other-apps-event-taps-25015>
- iOS 26 / 27 UIKit round-ups: <https://ikyle.me/blog/2026/whats-new-in-uikit-ios-27> ·
  <https://mjtsai.com/blog/2026/06/18/uikit-in-ios-27/> ·
  <https://www.swiftjectivec.com/ios-26-notable-uikit-additions/> ·
  <https://sebvidal.com/blog/whats-new-in-uikit-26/>
- iPad haptics hardware: <https://www.nutrient.io/blog/haptic-feedback-across-ipad-and-iphone/>
- Product docs cited inline in §C (Edovia, Jump Desktop, RealVNC, Microsoft Learn).
