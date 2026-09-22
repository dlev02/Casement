# Vantage — Product & Host Lifecycle Research

**Scope:** Product feature vocabulary to mirror (Screens 5, Jump Desktop), engine-adjacent lessons from RustDesk on macOS, and the concrete macOS APIs for an unattended personal host app (macOS 27 host + iPadOS 27 client, Tailscale-only transport).

**Date:** 2026-09-21
**Research host:** macOS 27.0 (build 26A5421a), SDK `MacOSX27.0.sdk`, Xcode 27 beta.
**Local artifacts inspected read-only:** `/Applications/Screens 5.app` (v5.9.2, build 10304, `com.edovia.screens.5`, built against macOS 27 SDK), `/Applications/RustDesk.app`, `/Library/LaunchDaemons/com.carriez.RustDesk_service.plist`, `/Library/LaunchAgents/com.carriez.RustDesk_server.plist`, live `pmset -g assertions`.

---

## Summary

Nine things worth internalizing before any code gets written:

1. **Screens 5's vocabulary is a ready-made spec.** Its `Localizable.strings` (1,218 keys) enumerates every setting name, gesture description, and toolbar section. Section 1 reproduces it verbatim. Copying the *terminology* is most of the "feels like Screens" work — "Virtual Cursor Mode", "On-Screen Touch-and-Hold Drag Delay", "Cursor Tracking Speed", "Carousel", "Interactive Toolbar", "Use Shared Clipboard", "Keep Mac Awake".
2. **Screens' Tailscale integration is read-only metadata, not transport.** It asks for a Tailnet ID plus an OAuth **client secret** (`tskey-client-…`) scoped to `Devices: Read`, and uses it purely to populate a device list. The actual connection is still VNC/SSH to the `100.x` address. Devices must be linked **per client device**; shared devices are not supported. Vantage can do dramatically better here by using the local `tailscaled` state (or LocalAPI) instead of a cloud OAuth credential.
3. **Curtain Mode is not reproducible by a third-party app.** Edovia is explicit: "Curtain Mode requires **Remote Management** to be enabled on the remote Mac. It does not work with Screen Sharing." It's an ARD/`screensharingd` privilege. Vantage's equivalent must be *display-blanking-by-lock* (see §4.4), and it should be named something honest like "Private Session".
4. **RustDesk uses exactly the architecture Apple DTS recommends for login-window access** — and it's installed on this Mac, so I read the plists. A root **LaunchDaemon** (`com.carriez.RustDesk_service`, `KeepAlive: true`) plus a **global LaunchAgent in `/Library/LaunchAgents`** (`com.carriez.RustDesk_server`) with `LimitLoadToSessionType = ["LoginWindow", "Aqua"]` and `ProcessType = Interactive`. That agent placement is the *only* way to get a GUI-capable process before login, and it requires root install — i.e. an installer or `SMAppService.daemon` + privileged helper, not a plain sandboxed app.
5. **Login-window capture is effectively closed to us anyway.** Apple DTS's position on the forums is that daemons must not talk to the WindowServer; ScreenCaptureKit fails at the login window with no graphical context and no TCC session to prompt in. Third parties who do this (AnyDesk, TeamViewer) use the pre-login agent *and* `com.apple.developer.persistent-content-capture`, an Apple-gated entitlement documented as being "for VNC apps". **Verdict for a personal app: don't. Use auto-login on a dedicated host, or macOS 26+'s SSH FileVault unlock as the reboot recovery story.**
6. **Screens itself takes a deprecated power assertion.** Live on this Mac: `pid 8216(Screens 5): NoIdleSleepAssertion named: "Remote access is enabled"`. `kIOPMAssertionTypeNoIdleSleep` has been deprecated since 10.7. Vantage should use `kIOPMAssertPreventUserIdleSystemSleep` while idle-but-reachable, and `IOPMAssertionDeclareUserActivity(_, kIOPMUserActiveRemote, _)` on remote input — that last one is purpose-built for remote clients that need the framebuffer/GPU.
7. **Tailscale cannot wake a sleeping Mac.** WoL is a layer-2 magic packet; Tailscale is layer 3. Bonjour Sleep Proxy / Wake on Demand likewise depends on local multicast + WoL. `pmset womp 1` only helps from the same L2 segment. The only real answer is *don't let it sleep while on AC*, plus an optional always-on LAN helper.
8. **iPadOS paste rules cut one way only.** *Writing* `UIPasteboard` is silent; *reading* triggers the "pasted from" banner or the Allow Paste prompt unless it happens behind a `UIPasteControl`. Reading *metadata* (`detectPatterns`, item type lists) is silent. This asymmetry dictates the clipboard-sync design: remote→local can be automatic, local→remote should be explicit or metadata-gated.
9. **`SACLockScreenImmediate` still resolves on macOS 27.0** — I verified via `dlopen`/`dlsym` on `/System/Library/PrivateFrameworks/login.framework`. It's private. The public-ish alternatives (`pmset displaysleepnow`, screen saver engine) depend on user settings. And CGEvent injection into the lock screen is blocked by Secure Event Input, so "lock remotely then unlock remotely by typing the password" **does not work**.

---

## 1. Screens 5 feature inventory (checklist to mirror)

Source hierarchy for this section: Edovia's published docs at `help.edovia.com/en/screens-5/*`, plus verbatim strings extracted from `Screens 5.app/Contents/Resources/en.lproj/{Localizable,Main,ConnectionWindow,WhatsNew}.strings`. Quoted strings in `code` are exact app strings; the key name is given where useful.

### 1.1 Library / connection list

**Sections (the sidebar, `STR_SECTION_VISIBILITY` — "At least one section must remain visible."):**

| Section | App string | Notes |
|---|---|---|
| Links | `Links` / `Recent Links` | "Connections opened from links (like vnc://) or Screens Assist appear here automatically." Formerly "Recents". |
| Nearby | `Nearby` | Bonjour discovery. `No Nearby Computers Found`, `Still Searching…` |
| Screens Connect | `Screens Connect` | Their relay/port-mapping service |
| Tailscale | `Tailscale` | See §1.2 |
| Custom Connections | `Custom Connections` | Manual host/port/URL |

Section visibility is user-configurable ("Hide Unused Sidebar Sections" — *"Easily declutter your interface by hiding sections you don't use."*).

**View & ordering:**
- `List` / `Grid`, menu items `as List` / `as Grid` (`STR_AS_LIST`, `STR_AS_GRID`).
- `Sort Sections` (`STR_WN_ITEMS_SORT`) — *"Now, you have the capability to sort section items by name, last connection, and other criteria."* Observable criteria in strings: name, `Last Connected`, `Connection Count`.
- **Custom Grid Ordering** (5.9): *"Arrange connections in any order you like by simply dragging them around the grid."*
- **Groups**: `Create New Group`, `New Group`, `Rename Group`, `Delete Group`, `Move to Group`, `Group Name`, `No Groups Available`, `New %@ Group`. Deleting a non-empty group prompts: *"This group contains items. What do you want to do with them?"* → `Delete All Items` or keep. Groups apply to Screens Connect, Tailscale, and Custom Screens items.
- **Search**: unified search ("Tab Bar & Unified Search"), `Start typing to search for a computer.`
- `Show Badges in Tab View`, `Allow Tabs When Opening Connections`, `Follow System Settings` (tab behavior).
- Import/Export: `Import…`, `Export…`, `Import Archive`, `Import from Clipboard`, `Import from Files…`, `Restore Backup`, automatic backups.

**Status indicators:** *"Screens now conducts regular connection tests to ensure more accurate status indicators."* Stale hosts warn: *"This computer hasn't updated its status for **%d days**."* States seen: `Connected`, `Not Connected`, `Disconnected`, `Connecting…`, `Authenticating…`.

### 1.2 Tailscale integration — exact setup steps

Documented at `/en/screens-5/connecting-anywhere/tailscale`. Available since **Screens 5.3**.

1. Create a Tailscale account; install Tailscale on the hosts *and* on each Apple client device.
2. In the Tailscale admin console: **Settings → General**, copy the **Tailnet ID**.
3. **Settings → Trust credentials → Credential**, choose **OAuth**, name it (e.g. "Screens 5"), under **Devices** select **Read** for Core permissions, generate, and copy the **Client Secret** (`tskey-client-…`).
4. In Screens: Tailscale section → **Link Account…** → paste Tailnet ID + Client Secret. Devices populate automatically.

What it shows and its limits (from strings + docs):
- `Link your Tailscale account to access computers on your Tailscale network. If needed, [set up Tailscale] on this device and the computers you want to access. Your devices will appear here automatically.`
- `Ensure that Tailscale is running and connected to access your computers.`
- `Tailscale is not detected. Please ensure it is installed and running on this device.` (there is a whole troubleshooting article: *Tailscale is not detected on the source device*)
- Error strings: `Invalid Tailscale Access Token.`, `Invalid Tailscale Client Secret.`, `Access denied to the Tailscale account.`, `Tailscale Error`
- `Service Status` row (`STR_TAILSCALE_SERVICE_STATUS`)
- **Hide and Rename Tailscale Devices**: *"You can now hide unnecessary devices or rename them."*
- Docs caveats: *"The Tailscale app must be running on that device. By default, Tailscale only starts after you log in"*; **shared devices are not supported**; **you must link the account on each device you use**; Tailscale requires macOS 11+.

**No documented per-device online/offline dot or OS icon** beyond what the generic connection status test provides. The OAuth device list would carry `os` and `lastSeen`, so Screens *could* show them; the strings don't prove it does.

> **Vantage implication.** Requiring a cloud OAuth secret is the weak point of Screens' integration and the source of its "not detected"/"invalid secret" support load. Reading the local Tailscale daemon's state gives online status, OS, tags, and `100.x`/MagicDNS names with zero credentials — and works offline from the control plane.

### 1.3 Per-connection settings

Screens 5.9 moved most of these from app-wide to **per-computer** (`Per-Computer Connection Settings`: *"More connection settings can now be configured individually for each computer"*). App-level values act as defaults: `Default Settings` — *"These default options can be set per computer once connected."*

**Item settings tabs:** `General Info`, `Authentication`, `Secure Connection`, `Controls`, `Display`, `When Disconnecting`.

#### Cursor / pointer (`Controls > Cursor`)
| Setting | String key | Values / notes |
|---|---|---|
| `Virtual Cursor Mode` | `STR_MOUSE_CONTROL_MODE` | `Touch` / `Trackpad`. Touch = *"mimics iOS device interaction, enabling effortless remote cursor control through intuitive taps."* Trackpad = *"precise manual control of the remote cursor via familiar gestures."* |
| `Cursor Tracking Speed` | `STR_CURSOR_TRAKING_SPEED` | Adjustable in connection settings *and* on the fly during a session (5.9) |
| `On-Screen Touch-and-Hold Drag Delay` | `STR_ON_SCREEN_DRAG_DELAY` | 5.9; "on-screen drag gestures are now faster and customizable" |
| `Use Fallback Cursor` | `STR_FALLBACK_CURSOR` | *"Displays a standard arrow cursor when the remote computer hides its cursor."* |
| `Hide Local Cursor` / `Use Local Cursor` | `SFM_*` | Session toggle |
| `Hand Cursor` | — | Cursor shape |

#### Scrolling (`Controls > Scrolling`)
| Setting | Values |
|---|---|
| `Scrolling Speed` (`STR_PC_SCROLLING_SPEED`) | `Very Slow`, `Slow`, `Normal`, `Fast`, `Very Fast` — added 5.9 for PC connections ("Smoother Scrolling on PCs") |
| `Use Momentum Scrolling` | *"Uses your Mac's natural scrolling momentum. Disable if needed for compatibility with some apps."* |

#### Keyboard (`Controls > Keyboard`)
| Setting | Values / notes |
|---|---|
| `Keyboard Input Mode` / `Input Mode` | `Keystrokes` (Mac only, default — raw macOS virtual key codes + modifiers), `Unicode` (sends characters, bypasses remote layout; auto-used for non-Mac), `Legacy` (10.14 Mojave and earlier). On Mac↔Mac in Unicode mode, Screens switches to Keystrokes for Option combos. |
| Separate `Hardware` vs `Software` keyboard input modes | `STR_HARDWARE_KEYBOARD_INPUT_MODE` / `STR_SOFTWARE_KEYBOARD_INPUT_MODE` — 5.7 added "input mode selection for both keyboards" |
| `Use Classic Mappings` | `STR_ENABLE_LEGACY_KEYBOARD` |
| `Send System Shortcuts to Remote Computer` | `STR_SEND_SYSTEM_SHORTCUTS`. Notable 5.x change: *"System shortcuts are now applied locally when the cursor is outside the rendering view, eliminating the need to click out of the window."* |
| `Delay Until Repeat` | `STR_KEY_REPEAT_DELAY_UNTIL_INTERVAL` |
| `Default Modifier Keys` / `Modifier Button` | Default modifier selectable: `Command`, `Control`, `Option/Alt`, `Shift`, `Fn Key`. Two interaction policies: `Tap activates, long-press expands` vs `Tap expands, long-press activates`. |
| `Fn Key` support | Added for Mac targets; add via **Settings › Controls › Toolbars** |

**External keyboard caveat (documented troubleshooting):** iPadOS/visionOS **Full Keyboard Access** intercepts Space/Return/Tab/arrows at the system level — *"Screens may not receive essential key input (e.g. Space, Return, Function keys)"*. Edovia's recommendation is to turn Full Keyboard Access off. Also: `⌘-\` is used as an in-app App Switcher shortcut "bypassing iOS limitations".

#### Clipboard (`Clipboard Settings`)
- `Use Shared Clipboard` (on by default) — bidirectional automatic sync: *"anything you copy on either device is automatically transferred to the other clipboard over the network."*
- Manual: `Send Clipboard` / `Get Clipboard` (`Send to Remote Clipboard`).
- Types: Mac↔Mac supports rich text, plain text, images, URLs (unsupported → falls back to plain text). Windows/Linux/Pi: plain text only, server-dependent.
- Notifications: `Clipboard Sync` / `Clipboard content sent to "%@"` / `Clipboard content received from "%@"` / `Could not send clipboard`.
- No direction-limiting switch is documented — it's on/off plus manual verbs.

#### Display (`Display`)
- `Display Selection`, `All Displays`, `Select Display %d`, `Display %d: %d x %d`, `(Main)`, `Remember Selected Display` (default on).
- Shortcuts: `Shift-Control-0` = all displays, `Shift-Control-1/2/3` = specific display.
- PC/VNC: display selection via port 5901/5902/5903, server-dependent.
- `Mirror to External Display` (AirPlay support returned in 5.9: *"Stream the connected computer's display to a TV or other AirPlay-compatible display."*)
- Caveat article: *Multiple Displays Arrangement* — cursor can get stuck on a particular display; fix by changing the primary display / arrangement.

#### Quality & scaling
| Setting | Values |
|---|---|
| `Use Adaptive Quality` | `Always On` / `Only When Connecting Remotely` / `Never`. Mac-only. Progressive-JPEG-style multi-pass refinement. Footnote: *"Adaptive Quality uses Very High color depth, so the Color Depth setting does not apply."* and *"When connecting remotely, Adaptive Quality uses Very High color depth. Color Depth applies to local connections."* |
| `Color Depth` | `Low` (8-bit, added 5.9 for PC), `High`, `Very High`; also `Thousands` / `Millions` |
| `Image Quality` / `Image Compression Quality` | TightVNC JPEG quality; PC default 4 on a 1–9 scale |
| Compression / display scaling | `Always On` / `Only When Connecting Remotely` / `Never`; scales remote screen to 50% (2560×1440 → 1280×720) |
| `Scaling`, `Initial Scaling Mode`, `Turn Scaling On/Off`, `Desktop Scaling Quality` | Session + per-connection |
| `Preferred Codecs` | *"Codecs are used based on their order."* (PC connections; 5.x "Codec Selection") |

Explicitly **not** supported: *"Screens cannot change the resolution of your remote Mac's display"* — no virtual-display / resolution matching. This is Jump's clear advantage (§2).

#### Curtain Mode & privacy
- `Use Curtain Mode`, `Toggle Curtain Mode`, `Curtain Mode On/Off`, `Unable to Enable Curtain Mode`.
- Requirement string: `Curtain Mode is available only when Remote Management is enabled on the remote Mac.` Docs: *"It does not work with Screen Sharing."*
- Behavior: *"people in front of the remote Mac will see a locked or blank display instead of your session."*
- Limits: won't activate at the login screen (Screens retries after login); headless Macs may skip it; multi-display flicker/restore issues; may cancel on-disconnect actions; a known Chrome interaction bug; a "Curtain Mode Persists After Disconnection" article.
- Detection: *"Screens now detect Curtain Mode activation, ensuring your remote Mac's display remains protected from prying eyes."*
- Related: `Lock Screen` (`Locks the remote display to keep your session private.`), `Screen locked by %@`, `Lock Message`.
- Session sharing prompt: *"Someone is currently using the display on "%2$@". How would you like to connect?"* → control vs `Connect in Observe Mode`.
- `Observe` / `Control` modes: `Switch to Observe Mode`, `Switch to Control Mode`, `Start in Observe Mode`, `Control or Observe Screen`.

#### On-disconnect (`When Disconnecting`)
`Do Nothing`, `Lock Screen` (shows Login Window), `Log Out User`, `Send Ctrl-Alt-Del`, and Hot Corners: `Top-Left / Top-Right / Bottom-Left / Bottom-Right Hot Corner`. Caveat: Curtain Mode may cancel these.

#### Session/host power
- `Keep Mac Awake` — *"Prevent your Mac from sleeping. The display can still sleep."* **Implemented with the deprecated `NoIdleSleepAssertion`** (observed live: `pid 8216(Screens 5): NoIdleSleepAssertion named: "Remote access is enabled"`).
- `Disable Device Idle Timer` — *"Prevents your device from locking or sleeping while connected to a computer."* (client side)

### 1.4 Gestures (iPhone/iPad) — full documented list

Identical in Touch and Trackpad modes except cursor movement:

| Gesture | Action | Indicator |
|---|---|---|
| Tap (1 finger) | `Left Click` | — |
| Double-tap (1 finger) | `Double Click` | — |
| Tap (2 fingers) | `Secondary Click` (right-click) | — |
| Tap (3 fingers) | `Middle Click` | — |
| Tap + drag (1 finger) | `Move Cursor` (Trackpad mode) | — |
| Tap + drag (2 fingers) | `Scroll` (vertical/horizontal) | — |
| Touch-and-hold (1 finger) then move | `Drag` | **blue** signal |
| Touch-and-hold (2 fingers) then move | `Secondary Click Drag` | **red** indicator |
| Touch-and-hold (3 fingers) then move | `Middle Click Drag` (5.9+) | **green** indicator |
| Pinch (2 fingers) | `Zoom` on remote desktop | — |
| Double-tap (2 fingers) | `Toggle Toolbar Visibility` (docs also cite toggle fullscreen) | — |
| Swipe inward from an edge | `Show Dock` / move cursor to that remote edge (reveals Dock, menu bar) | — |
| Swipe inward from a corner | `Hot Corners` | — |
| 3-finger swipe up | Mission Control (`⌃↑`) | — |
| 3-finger swipe down | Application Windows (`⌃↓`) | — |
| 3-finger swipe right | Move left a Space | — |
| 3-finger swipe left | Move right a Space | — |

Settings: `Prevents pinching to zoom in or out` (a lock-zoom option), `Three-Finger Swipe Gestures` toggle.

**Vision Pro variants** (useful as a model for a "pointer abstraction layer"): pinch = left click, double pinch = double click, pinch-and-hold = drag (blue), two-hand pinch + rotate = secondary click, two-hand pinch + hold = right-drag (red), two-hand pinch + move = scroll, pinch + move hand = move cursor.

**Mouse/trackpad hardware** (`Trackpad & Mouse`): *"Use your hardware trackpad or mouse to control your remote computer just as if you were sitting right in front of it."* 5.9 added right-button drags via mouse/trackpad and middle-button drags via mouse.

### 1.5 Apple Pencil

- `Apple Pencil` section under **Settings › Controls › Apple Pencil**.
- Two configurable gestures: `Squeeze` and `Double Tap`. Actions: `None`, `Toggle Toolbar Visibility`, `Right Click (Secondary Click)`, `Middle Click`, `Expand or Collapse Toolbar` (*"This action will only be triggered if the toolbar style is set to Floating."*).
- `Tap with Apple Pencil to perform a left click.`
- `Scribble with Apple Pencil to drag windows, files, select text, and more.`
- `Hover Apple Pencil Pro to move the cursor.` — *"With Apple Pencil Pro, you can also move the cursor by hovering over the display for even greater precision."*
- 5.9: *"Interact with remote elements more intuitively using Apple Pencil—just tap or drag directly without positioning the cursor."*
- Carousel toolbar appears **at the Pencil tip** when squeeze/double-tap is bound to toolbar visibility.
- `Apple Pencil gestures work seamlessly alongside other control modes and their respective gestures.`

### 1.6 Session toolbar

**Styles** (`STR_TOOLBAR_STYLE`):
- `Docked` — *"maintains a fixed position at the bottom of the screen, ensuring it is constantly expanded"* (iPhone landscape: left side).
- `Floating` — iPad only; *"you can easily relocate the toolbar to any of the display four corners by swiping, and it also offers the flexibility to expand or collapse as needed."* Collapsed: tap-and-hold the chevron for a quick menu.
- `Carousel` — free-floating circular toolbar, both platforms; draggable with finger or Pencil; *"works best with Trackpad Cursor Mode."*
- iPhone also has a `Compact Toolbar` that "expands to show more controls without scrolling".

**Visibility:** `Toolbar Visibility` = `Show` / `Hide` / `Hide on Hardware Input`; `Expand Toolbar By Default`; `Show Leading Toolbar` / `Hide Left Toolbar`; two-finger double-tap toggles.

**Customization** (`Toolbar Customization`, Settings › Controls › Toolbars): `Add Buttons…`, `Available Buttons`, `Toolbar Buttons`, spacers, `Button Size` (`Small` / `Default` / `Large` / `Extra Large`), keyboard button `Position` = `Leading` / `Trailing`. Footer: *"Unless otherwise noted, all buttons are available on all supported operating systems."*

**Button catalog by section** (from `STR_TBT_SECTION_*` and `STR_BTN_*`):

| Section | Contents |
|---|---|
| `Modifiers` | `Shift`, `Control`, `Option`, `Command` / `Command/Super`, `Fn Key`, `Modifiers Menu` |
| `Keys` (System Keys) | `Escape`/`Esc`, `Tab`, `Return`, `Spacebar`, `Delete`, `Delete Forward`, `Insert` |
| `Arrows` | arrow keys |
| `Navigation` | `Home`, `End`, `Page Up`, `Page Down` |
| `F-Keys` | `F-Keys Menu` |
| `Characters` | Backslash, etc. |
| `Edit` | `Cut`, `Copy`, `Paste`, `Paste and Match Style`, `Undo`, `Redo`, `Select All`, `Edit Menu` |
| `Commands` | `Commands Menu`, `App Commands`, `Desktop Commands`, `System Commands`, `Other Commands` |
| `Desktop` | `Mission Control`, `Application Windows`, `Desktop`, `Move Left a Space`, `Move Right a Space` |
| `System` | `Force Quit…`, `Lock Screen`, `Log Out User…`, `Ctrl-Alt-Delete`, `Spotlight`/`Spotlight/Find` |
| `Security` | `Type User Password` |
| `Controls` (in-app) | `Toggle Keyboard`, `Toggle Toolbar`, `Toggle Scaling`, `Toggle Curtain Mode`, `Clipboard Sharing`, `Display Selection`, `File Transfers`, `Grab Screenshot`, `Show Dictation`, `Close Connection`, `Interaction Mode` |
| `Layout` | spacers |

**Keyboard shortcuts (iPad / Vision Pro)** — all `⇧⌃⌘`-prefixed to avoid colliding with passthrough:

| Action | Shortcut |
|---|---|
| Grab Screenshot (iPad) | `⇧⌃⌘R` |
| Close Connection | `⇧⌃⌘C` |
| Mission Control | `⇧⌃⌘↑` |
| Application Windows | `⇧⌃⌘↓` |
| Move Left a Space | `⇧⌃⌘←` |
| Move Right a Space | `⇧⌃⌘→` |
| Minimize (iPad) | `⇧⌃⌘M` |
| Hide | `⇧⌃⌘H` |
| Hide Others | `⇧⌃⌥⌘H` |
| Close (iPad) | `⇧⌃⌘W` |
| Quit | `⇧⌃⌘Q` |
| Force Quit | `⇧⌃⌘⎋` |
| Lock Screen (iPad) | `⇧⌃⌘S` |
| Log Out User (iPad) | `⇧⌃⌘U` |
| Ctrl-Alt-Del | `⇧⌃⌘⌫` |
| Type User Password | `⇧⌃⌘P` |
| Spotlight Search | `⇧⌃⌘Space` |
| Backslash (iPad) | `⇧⌃⌘\` |
| Insert (iPad) | `⇧⌃⌘\|` |
| App Switcher (in-app) | `⌘\` |
| Select display | `⇧⌃0` (all), `⇧⌃1/2/3` |

### 1.7 Security

- `Lock Screens` (`STR_LOCK_SCREENS`) with a `Delay` sub-setting (`STR_LOCK_SCREENS_DELAY`). Footers: mobile — *"Protects your connections using Face ID, Touch ID or your device passcode by locking Screens when not in use."*; Mac — *"…using Touch ID, Apple Watch or your user password…"*. `Unlock Screens`, `Unlock the app to show its content`.
- `Automatic Unlocking` — *"Screens now features automatic unlocking when utilizing Face ID or Touch ID."*
- Biometric gate on `Type User Password` specifically: `Require Authentication`, reasons `Type the Mac user password` and `Change the Type User Password setting`.
- `Secure Connection` = SSH tunnel. `Screens will use an SSH tunnel for both local and remote connections` vs `…for remote connections only`; `Enable for Local Connections`; `Enable Remote Login to Secure Connections`.
- SSH keys: `Syncable SSH Keys`, `Authenticate with Key:`, `OpenSSH`, `OpenSSH Encrypted`, `RSA Encrypted`, `EDCSA Encrypted`, passphrase prompts, `screens-ssh://` URL scheme.
- Host key pinning: `The authenticity of host "%@" cannot be established.`, `The %1$@ %2$@ fingerprint is: %3$@`, `Last Accepted Fingerprint`, `Approve`/`Reject`, biometric gate (`Authentication for fingerprint acceptance…`). *"Screens now lets you accept or reject the fingerprint provided by the remote computer."*
- Auth types: `Mac Guest User`, `Mac Guest User (Observe)`, `VNC Password`, username+password, `TLS Authentication`, `Secure Key Authentication`.
- Account: `Two-Factor Authentication` for the Screens Connect account; sign in with Apple or Google; `Erase All Content and Settings`.

### 1.8 Reconnect behavior

- `Reconnect Automatically` (`STR_AUTO_RECONNECT`) — *"Screens will automatically reconnect if the connection is closed during a session or when the app is launched."*
- UI: `Reconnecting…`, `Reconnecting in %d seconds…`, manual `Reconnect` button.
- 5.8.10: "faster reconnection detection".

### 1.9 File transfer

- Drag & drop both directions: drag from **Files**, Numbers, or another app onto the remote screen to upload; drag from the Mac's screen to download.
- Downloads land in **Files › On My [Device] › Screens › Downloads**.
- Requirements: downloads need **macOS 14 Sonoma+** on the host; uploads work back to **macOS 10.10**.
- Background: 5.7 *"File transfers now continue seamlessly in the background, even after leaving Screens"* (iOS/iPadOS 26), though the iPad article still warns transfers may be interrupted by switching away and resume on return.
- UI surface: a `File Transfers` panel in the connection window with `Sent and Received Files`, per-transfer `Upload`/`Download` rows, `Preparing to Upload…`, `Transferring…`, `%1$@ of %2$@`, `Completed`/`Failed`/`Cancelled`, `Clear`. Disconnect guard: *"Files are currently being transferred. Closing the connection now will cancel the transfers."*
- Per-connection `Allow File Transfers` toggle (5.8, Mac connections).
- Known issue on iPadOS 27: uploads may fail in Windowed Apps / Stage Manager; workaround is Full Screen Apps.

### 1.10 Other notable surfaces

- **Dictation** (`Show Dictation`, `Listening…`, `Transcript`): speak → insert text directly on the remote or `Send to Remote Clipboard`. Toggle in Settings › Controls › Toolbars.
- **Widgets / Siri / Shortcuts**: Quick Connect widget; App Intent `Connect to Computer with Screens` with a `Group` property; `When enabled, connections started from widgets and Siri open in a new window.`
- **Menu Bar** on iPadOS 26+: *"Quickly access commands and shortcuts from the new Menu Bar."* On Mac, `Show Screens in the Menu Bar`.
- **Notifications**: `Show Notifications` master toggle (*"Are the notifications too annoying? You can disable them in the app settings."*).
- **Diagnostics**: `Save Diagnostics Report…`, `Logs & Analytics Data…`, `Send Crash Reports Automatically`, `Diagnostic & Usage Data`, *"This data stays on your device and is only shared with Edovia if included in a support request."*
- **Settings organization (app level)**: `General`, `Controls` (→ `Cursor`, `Scrolling`, `Keyboard`, `Toolbars`, `Apple Pencil`), `Security`, `Clipboard`, `Backups`, `Privacy`, `Advanced`, `Sidebar`/`Section Visibility`, account sections.
- **URL schemes**: `screens://`, `screensxpress://`, `screens-ssh://`, `vnc://`, `ssh://`, `rdp://`, `x-screens://`, plus `guest`, `observe`, `ssh-key` parameters.

---

## 2. Jump Desktop (iPad + Jump Desktop Connect)

> Note: `support.jumpdesktop.com` returns HTTP 403 to non-browser clients (verified via both WebFetch and `curl` with a browser UA), so this section leans on search-result extracts and `changelog.jumpdesktop.com`, which is fetchable. Treat specific numbers as "documented by the vendor" rather than as verbatim quotes where noted.

### 2.1 Fluid Remote Desktop protocol claims

- **Target frame rate: 60 fps by default.** "By default Fluid tries to target 60 frames per second (fps) for a smooth experience."
- **Bandwidth claim:** Fluid "can share your screen at 60fps while using only 1/10th of the bandwidth when compared to traditional protocols like RDP and VNC."
- **Codecs:** H.264 historically; **Fluid 2.0 uses H.265 (HEVC)**, claimed "~50% bandwidth saving compared to traditional H.264 at equivalent quality."
- **Hardware encode/decode:** "Fluid supports hardware-accelerated encoding and decoding"; modern Macs and iPads have "dedicated media processing units that Fluid fully utilizes to reduce CPU usage, latency, and heat." (i.e. VideoToolbox both ends.)
- **Multi-monitor hardware acceleration scaling:** RC 4 (2026-08-17) raised hardware acceleration support from 2 to "up to 6 × 4K monitors."

### 2.2 Dynamic frame rate control (user-facing tuning)

From the changelog entry *Dynamic Frame Rate Control For Fluid*:
- Users can "adjust how quickly Fluid will send display updates [to the] remote computer" while connected; the system "will automatically adjust the frame rate dynamically."
- Default 60 fps; selectable **30 fps**, which "roughly cuts the bandwidth and cpu requirements in half."
- Access on Mac: **Remote → Framerate**.
- Rationale: "quite useful when you want to save CPU or bandwidth."

There is also a **Live Fluid Connection Statistics** overlay (support article `4423458049165`) exposing real-time session metrics — the exact metric list could not be retrieved (403), but the existence of a first-class stats HUD is the relevant product signal.

### 2.3 Virtual display / automatic iPad scaling (the recent RC notes)

This is Jump's headline advantage over Screens, and it moved recently:

| Build | Date | Note |
|---|---|---|
| RC 1 | 2026-07-04 | iOS display UI redesigned with **"Single Virtual Display"** and **"Host Displays"** options; *"Single Virtual Display now enables Retina automatically."* |
| RC 4 | 2026-08-17 | Hardware acceleration extended to "up to 6 x 4K monitors" (was 2) |
| RC 6 | 2026-08-26 | Fixed virtual displays on Windows 10 |
| RC 7 | 2026-08-27 | **Single Virtual Display preset now automatically optimizes scaling** — *"Mac desktops render at sharp Retina resolution and Windows desktops match your device's screen density"*; the preset *"automatically picks the best scaling for the host."* |

Supporting behavior documented elsewhere: when connecting with Fluid, Jump "tries to switch the resolution of the remote computer to match the aspect ratio of the device you're connecting from." Jump Desktop Connect exposes a **"Match iPad"** virtual-display resolution option plus a custom resolution entry (in-session: top pill icon → tool icon → **Display Resolution**), and a documented way to **prevent** Jump from changing screen resolution. Known rough edges: 4:3 iPad Pro 13" aspect handling, black bars on 11" iPad Pro, blurry output under Display Zoom / "More Space".

> **Vantage implication.** "Remote desktop that exactly matches my iPad's logical resolution at Retina scale, created on demand, torn down on disconnect" is the single highest-value differentiator available, and Jump has only just gotten it right. On macOS 27 a host-created virtual display is the mechanism; Screens explicitly refuses to do it.

### 2.4 iPad input methods and toolbar

Jump documents **three** iPad input methods (article `216423623`):
- **Standard** — "the basic elements associated with a traditional multi-touch user interface: pinch or spread two points to zoom in or out and tap to click."
- **Pen** — "movement of the mouse cursor is done with the equivalent of the left mouse button held down, as though you've triggered a left mouse drag"; suited to a stylus for fine positioning.
- **Trackpad** — "turns the entire iPad screen into a trackpad": one-finger tap = click, two-finger tap = right-click, two-finger drag = scroll, double-tap-and-hold-drag = drag.

Additional: a **Trackpad Gaming** gesture profile (wrench icon); long-tap as an alternate right-click; two-finger pinch zoom; full external Bluetooth mouse/trackpad support since iOS 13.4. In-session UI is a **top "pill" control** that opens a tool/settings sheet (Display Resolution, etc.) — a different idiom from Screens' bottom/floating toolbar.

Recent iOS-side fixes in the same RC series: keyboard blocking input, external display blackness, session zoom, cursor locking, and a fix for "dragging a remote window near the top of the screen pulling Jump out of full screen on iPadOS 26."

### 2.5 Takeaways for Vantage

- Ship a **stats HUD** (fps, bitrate, RTT, codec, decode time) from day one — both competitors have one and it is how you debug a codec pipeline in the field.
- Offer **frame-rate presets, not just a quality slider**: 60 / 30 with dynamic adaptation, because that halves bandwidth *and* host CPU.
- Prefer **HEVC** with H.264 fallback; both ends are Apple silicon with VideoToolbox.
- **Virtual display sized to the client** is the feature to build early, not late.

---

## 3. RustDesk on macOS — what's worth knowing

We are not using its engine, but its macOS integration is the best available worked example of the platform constraints.

### 3.1 Capture API

RustDesk's macOS capture path uses **ScreenCaptureKit where available, with legacy `CGDisplayStream` as fallback**. (Its audio service is documented as "CoreAudio/ScreenCaptureKit on macOS".) It does *not* rely on `CGWindowListCreateImage` for the video path — that API is a per-frame synchronous snapshot and is wholly unsuitable for a 60 fps stream; it is also deprecated in favour of `SCScreenshotManager`.

**For Vantage:** ScreenCaptureKit only. `SCStream` + `SCStreamConfiguration` with `minimumFrameInterval`, `queueDepth`, `showsCursor`, `pixelFormat`, `captureDynamicRange`, and per-frame `SCStreamFrameInfoDirtyRects` (macOS-only, and exactly what you want for delta encoding). Note from the macOS 27 SDK: `SCStream.isCapturing` is new in macOS 27, and `SCStreamConfigurationPresetCaptureHDRRecordingPreservedSDRHDR10` arrived in 26.

### 3.2 Codecs

RustDesk supports **VP8, VP9, AV1, H.264, H.265**. Software paths are libvpx (VP8/VP9) and libaom (AV1); hardware paths go through its `hwcodec` layer over FFmpeg, which on macOS means `h264_videotoolbox` / `hevc_videotoolbox`. A recurring, well-documented failure mode: FFmpeg detects the VideoToolbox encoders but RustDesk's internal `hwcodec` probe does not, or HEVC init fails with VideoToolbox error `-12900` — so users silently fall back to VP9/software and blame the app for being slow.

**For Vantage:** using `VTCompressionSession` directly (no FFmpeg/hwcodec probe layer) removes an entire class of bug. Still, *log and surface* the negotiated codec — RustDesk's biggest support burden here is that the fallback is invisible.

### 3.3 Privacy mode on macOS

macOS uses a single native call (`MacSetPrivacyMode`) that runs synchronously, with **no virtual-display manipulation** — unlike Windows, which has three implementations (`SetWindowDisplayAffinity`, a magnifier-based virtual display, and physical display replacement). Architecturally it's a pluggable trait in `src/privacy_mode.rs`. Community discussion (rustdesk#10909) shows macOS privacy mode is the weakest of the three platforms.

**For Vantage:** there is no supported macOS API that blanks the physical panel while a remote session continues. The realistic options are (a) lock the screen and accept that the remote session then sees the lock screen too, (b) drive display brightness to zero via a private/IOKit path, or (c) create a virtual display, make it primary, and stream *that* while the physical display shows an idle desktop. (c) is the only approach that is both honest and effective, and it composes with the virtual-display work from §2.3.

### 3.4 Login-window / unattended access — the actual launchd layout

Verified by reading the plists installed on this Mac:

**`/Library/LaunchDaemons/com.carriez.RustDesk_service.plist`** (root daemon):
```
Label                       com.carriez.RustDesk_service
ProgramArguments            /bin/sh -c /Applications/RustDesk.app/Contents/MacOS/service
RunAtLoad                   true
KeepAlive                   true
ThrottleInterval            1
WorkingDirectory            /Applications/RustDesk.app/Contents/MacOS/
StandardOutPath             /tmp/rustdesk_service.out
StandardErrorPath           /tmp/rustdesk_service.err
AssociatedBundleIdentifiers com.carriez.rustdesk
```

**`/Library/LaunchAgents/com.carriez.RustDesk_server.plist`** (global agent — note: **LaunchAgents**, not LaunchDaemons):
```
Label                       com.carriez.RustDesk_server
ProgramArguments            /Applications/RustDesk.app/Contents/MacOS/RustDesk --server
LimitLoadToSessionType      ["LoginWindow", "Aqua"]
ProcessType                 Interactive
RunAtLoad                   true
KeepAlive                   { AfterInitialDemand: false, SuccessfulExit: false }
ThrottleInterval            1
WorkingDirectory            /Applications/RustDesk.app/Contents/MacOS/
AssociatedBundleIdentifiers com.carriez.rustdesk
```

So: **yes**, RustDesk answers the question in the brief — it installs a root LaunchDaemon *and* a pre-login-capable LaunchAgent with `LimitLoadToSessionType` including `LoginWindow`. This matches exactly what Apple DTS describes as the built-in Screen Sharing architecture: "a launchd daemon to handle networking and general state management, and a launchd agent to do GUI work on the daemon's behalf… the agent should have `LimitLoadToSessionType` set to `Aqua` and `LoginWindow`." In the pre-login context the agent starts as **root**; when a user logs in, that instance is terminated and a new one launches as that user.

Both files are root-owned in `/Library/…`, i.e. they require an admin authorization at install time. RustDesk's docs frame this as "Install RustDesk Service"; AnyDesk does the same thing (`/Library/LaunchDaemons/com.philandro.anydesk.Helper.plist`, installed via "Install AnyDesk Service" → admin password → "Install Helper").

### 3.5 Known macOS pain points

- **Three separate TCC permissions:** Accessibility ("lets RustDesk control keyboard and mouse input"), Screen Recording ("lets RustDesk capture the local display"), and **Input Monitoring** (newly required "after macOS changed its security API for capturing local input events").
- **Permissions break after updates.** The official remedy is to remove the app from the Privacy pane with `–`, re-add with `+` from `/Applications`, and reboot; or `tccutil reset ScreenCapture com.carriez.RustDesk` followed by a reboot. Because TCC keys on the code-signing identity and path, an app that replaces its binary in place (Sparkle-style) can lose grants.
- **Sequoia's recurring screen-recording nag** is the reason `com.apple.developer.persistent-content-capture` exists; without it a capture app re-prompts periodically.
- **Hardware encoder detection** (§3.2) silently degrading to software.
- **Scroll feel** — RustDesk's scroll on macOS is widely reported as steppy/inverted-feeling because it synthesizes discrete wheel events rather than continuous/momentum phases. Screens explicitly added `Use Momentum Scrolling` and a five-step `Scrolling Speed` to fix precisely this. **For Vantage: emit `CGEvent` scroll wheel events with `kCGScrollEventUnitPixel` and proper momentum phases, and expose a speed multiplier.**
- **Fast User Switching** breaks sessions (rustdesk#13869).

---

## 4. macOS host app lifecycle for unattended personal use

### 4.1 Launch at login & staying alive

**Recommended stack for Vantage's host:**

| Need | API | Notes |
|---|---|---|
| Menu-bar-only app, no Dock icon | `LSUIElement = true` in Info.plist (or `NSApp.setActivationPolicy(.accessory)`) | Standard for a background host |
| Launch the app itself at login | `SMAppService.mainApp.register()` (macOS 13+) | Simplest; appears in System Settings → General → Login Items |
| Restart after a crash | `SMAppService.agent(plistName:)` + a plist in `Contents/Library/LaunchAgents/` with `KeepAlive` | `SMAppService.mainApp` gives no crash supervision; launchd's `KeepAlive` does |
| Show the user where to manage it | `SMAppService.openSystemSettingsLoginItems()` | Pair with `.status` (`.enabled` / `.requiresApproval` / `.notFound` / `.notRegistered`) |

**Bundled-agent rules (macOS 13+):**
- Plist path: `YourApp.app/Contents/Library/LaunchAgents/<name>.plist`; daemons go in `Contents/Library/LaunchDaemons/`.
- The plist **`Label` must match the filename** (minus `.plist`), and `plistName:` you pass is the filename.
- Use **`BundleProgram`** (a path *relative to the app bundle*) rather than `Program`/`ProgramArguments` with an absolute path, so the job survives the app moving.
- The helper executable must be code-signed with the same Team ID; the bundle must be in a location the system trusts (`/Applications` for daemons).
- `register()` on an agent is user-level and needs no admin authorization. `SMAppService.daemon(plistName:)` *does* prompt for admin approval.

**Can a LaunchAgent use ScreenCaptureKit and post CGEvents? Yes — with conditions.**
- A LaunchAgent loaded into the user's **Aqua** session runs inside that GUI session, has a WindowServer connection, and can therefore drive `SCStream` and `CGEventPost` normally. This is the same context a regular app runs in.
- **TCC prompting from an agent is the catch.** A faceless agent can trigger the Screen Recording / Accessibility prompts, but the resulting UI is attributed to the *responsible* process, and a `LSUIElement`/faceless process can present a prompt the user never sees (no Dock icon to bounce, no window to front). The practical pattern used by everyone shipping this: **do all permission acquisition from the visible app** (which shares the agent's Team ID and, if the agent is a bundled `BundleProgram`, is generally attributed to the containing app bundle), then let the agent inherit the grant. Provide deep links: `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture` and `…?Privacy_Accessibility`.
- Check, don't guess: `CGPreflightScreenCaptureAccess()` / `CGRequestScreenCaptureAccess()` and `AXIsProcessTrustedWithOptions`.
- If the agent runs in the **LoginWindow** session type, none of this holds — see §4.2.

**`com.apple.developer.persistent-content-capture`:** documented as "A Boolean value that indicates whether a Virtual Network Computing (VNC) app needs persistent access to screen capture." It is what stops macOS 15+ from periodically re-nagging for Screen Recording. It is **request-only via an Apple form**, aimed at VNC/screen-sharing products, and not something to count on for a personal app. Plan for the periodic prompt, or ship Developer ID and accept it.

### 4.2 Login-window access — feasibility verdict

**What would actually be required**, based on Apple DTS guidance and what shipping products do:

1. A **root LaunchDaemon** in `/Library/LaunchDaemons` for networking and state (no WindowServer access — Apple DTS: applications "should not connect to the window server from a launchd daemon").
2. A **global LaunchAgent** in `/Library/LaunchAgents` with `LimitLoadToSessionType = ["LoginWindow", "Aqua"]` and `ProcessType = Interactive` to do the GUI/capture work. In the pre-login session it runs as **root**; at login it is killed and relaunched as the user. This is a **pre-login agent**, the path Apple explicitly recommends over daemon-side WindowServer access.
3. Root installation of both (installer package, or `SMAppService.daemon` + `SMJobBless`-style privileged helper + admin authorization).
4. Probably `com.apple.developer.persistent-content-capture`, plus TCC grants that *cannot be prompted for* at the login window (no user session → no prompt). In practice this means MDM/PPPC profiles, which is an enterprise-only path.
5. Even then, forum reports are that ScreenCaptureKit at the login window "fails to initialize citing a lack of graphical context," and that `loginwindow` lives in a restricted Mach bootstrap namespace a System-domain daemon cannot bridge natively.

**How the reference apps handle it:**

| Product | Approach |
|---|---|
| **Screens Connect** | Does **not** provide login-window control. Its docs say plainly that FileVault "might prevent you from connecting to your Mac, especially since a user may need to physically log in before the Remote Management service can start," and recommend disabling FileVault or using `sudo fdesetup authrestart`. Screens' Curtain Mode also "won't activate while the login screen is displayed… Screens automatically retries after login." |
| **Jump Desktop Connect** | Installs a system service; same broad category as RustDesk/AnyDesk. |
| **RustDesk** | LaunchDaemon + `LoginWindow`+`Aqua` global LaunchAgent (plists reproduced in §3.4). |
| **AnyDesk** | `/Library/LaunchDaemons/com.philandro.anydesk.Helper.plist`, installed via "Install AnyDesk Service" with an admin password; documented as enabling use "when the computer has just restarted and is not logged in." |
| **Apple Screen Sharing** | The canonical daemon + `Aqua`/`LoginWindow` agent split that DTS describes. |

**Verdict for Vantage (a personal app): skip login-window support.** It is a root-install, entitlement-gated, MDM-shaped problem with an unreliable capture story. Instead:

**Recommended posture — auto-login, no FileVault, on a dedicated host.**
- If the Mac is a physically secured, dedicated always-on machine (Mac mini at home), **enable auto-login and turn FileVault off**. The Mac reaches the desktop unattended after any reboot, your LaunchAgent loads into Aqua, ScreenCaptureKit and CGEvent both work, TCC grants persist. Pair it with "require password immediately after screen saver begins" so the screen is still locked for anyone physically present, and let Vantage's own auth gate the remote session.
- If FileVault is non-negotiable (laptop, travels, shared space), accept that the Mac is unreachable between boot and first unlock, and use the recovery story below.

**"The Mac was rebooted" recovery story:**

macOS 26 Tahoe added exactly the escape hatch for this. Apple's *What's new for enterprise in macOS Tahoe 26* states: **"FileVault can now be unlocked over `ssh` after a restart if Remote Login is enabled and a network connection is available."** (See also the `apple_ssh_and_filevault(7)` man page.) Mechanically: a limited SSH stack runs in the **pre-boot** environment; you `ssh` in with the Mac's local username and password, the data volume unlocks, macOS **briefly disconnects the SSH session** while it mounts the data volume and starts the remaining services, then finishes booting normally.

**Network caveats that matter here — read carefully:**
- The pre-boot environment's networking is deliberately minimal. On Apple silicon with macOS 26+, FileVault pre-boot networking supports **Ethernet (open/unauthenticated)** or **Wi-Fi with a previously-joined open or WPA2-PSK network**. Enterprise 802.1X, captive portals, and WPA3-only networks are out.
- **Tailscale is not running in pre-boot.** `tailscaled` is a normal launchd daemon on the booted system; the pre-boot SSH stack has no VPN. So the FileVault unlock must come over the **LAN** or over a router-level/subnet-router VPN path that does not depend on the Mac itself. The common working recipe is a **Tailscale subnet router** on a separate always-on device (Raspberry Pi, NAS, router) advertising the LAN subnet — you connect to the tailnet, reach the Mac's LAN IP through the subnet router, unlock over SSH, and the Mac then brings up its own Tailscale.
- Practical sequence to document for the user:
  1. Reach the LAN via a subnet router (or be on the LAN).
  2. `ssh user@<mac-lan-ip>` → enter account password → volume unlocks → session drops.
  3. Wait ~20–40 s; `tailscaled` starts; the Mac reappears on the tailnet.
  4. Vantage's LaunchAgent is loaded by then (Aqua session after auto-login, or after you log in).
- For planned reboots from an existing session, `sudo fdesetup authrestart` remains the cleanest: it stashes the unlock key in memory for exactly one restart, so the Mac comes back up without any pre-boot interaction.

### 4.3 Sleep, wake, and "stay available"

**Power assertions (exact SDK semantics, `IOPMLib.h`, macOS 27 SDK):**

| Constant | Behavior (from the header) |
|---|---|
| `kIOPMAssertPreventUserIdleSystemSleep` (a.k.a. `kIOPMAssertionTypePreventUserIdleSystemSleep`) | "will prevent the system from sleeping due to a period of idle user activity. The display may dim and idle sleep… but the system may not idle sleep. The system may still sleep for lid close, Apple menu, low battery, or other sleep reasons. **This assertion has no effect if the system is in Dark Wake.**" |
| `kIOPMAssertPreventUserIdleDisplaySleep` | "Prevents the display from dimming automatically… If the display is already off, this assertion does not light up the display… While the display is prevented from dimming, the system cannot go into idle sleep. No effect in Dark Wake." |
| `kIOPMAssertionTypePreventSystemSleep` | **"Deprecated in 10.9. This assertion is not supported in any OS X releases. Do not use it."** |
| `kIOPMAssertionTypeNoIdleSleep` | **Deprecated in 10.7.** Use `PreventUserIdleSystemSleep`. *(This is nonetheless what Screens 5 uses today — see below.)* |
| `kIOPMAssertionTypeNoDisplaySleep` | **Deprecated in 10.7.** Use `PreventUserIdleDisplaySleep`. |
| `kIOPMAssertNetworkClientActive` | "Keeps the system awake while OS X serves active network clients… keeps the system awake in dark or full wake, as long as the system is on AC power. On battery, this assertion can prevent system from going into idle sleep… **If your remote clients require access to the framebuffer or the GPU, then this isn't the appropriate call for you.**" |
| `kIOPMAssertPreventDiskIdle` | Keeps disks spun up; does not prevent system sleep. |

**Two functions that matter more than the raw assertions:**

```
IOReturn IOPMAssertionDeclareUserActivity(CFStringRef AssertionName,
                                          IOPMUserActiveType userType,   // kIOPMUserActiveLocal | kIOPMUserActiveRemote
                                          IOPMAssertionID *AssertionID);   // 10.7.3+
IOReturn IOPMDeclareNetworkClientActivity(CFStringRef AssertionName,
                                          IOPMAssertionID *AssertionID);   // 10.9+
```

`IOPMAssertionDeclareUserActivity` "causes the display to power on and postpone display sleep, up to the user's display sleep Energy Saver settings," needs no privileges, and takes `kIOPMUserActiveRemote` for exactly our case. `IOPMDeclareNetworkClientActivity` is a timed wrapper around `NetworkClientActive` — but the header explicitly routes framebuffer/GPU-needing remote clients back to `DeclareUserActivity(kIOPMUserActiveRemote)`.

**Recommended Vantage policy:**
- **Idle but reachable (no client connected):** hold `kIOPMAssertPreventUserIdleSystemSleep` *only while on AC* (see power-source detection below). Name it something the user will recognise in `pmset -g assertions`, e.g. `"Vantage: host is reachable"`, and set `kIOPMAssertionHumanReadableReasonKey` + `kIOPMAssertionLocalizationBundlePathKey` so it localizes nicely in the Activity Monitor Energy tab.
- **Client connected:** additionally call `IOPMAssertionDeclareUserActivity(… , kIOPMUserActiveRemote, &id)` on remote input, re-calling periodically with the returned ID. This is the correct way to keep the framebuffer alive for a remote user, and it respects the user's own display-sleep preference rather than pinning the display on forever.
- **On battery:** release the idle assertion and let the Mac sleep. Surface this as a setting mirroring Screens' `Keep Mac Awake` — *"Prevent your Mac from sleeping. The display can still sleep."*

**`caffeinate` equivalence:** `caffeinate -i` = `PreventUserIdleSystemSleep`; `-d` = `PreventUserIdleDisplaySleep`; `-s` = prevent system sleep, "valid only when system is running on AC power"; `-m` = `PreventDiskIdle`; `-u` = declare user activity. With no flags it prevents idle sleep. Everything `caffeinate` does is `IOPMAssertionCreateWithName`; there is no reason to shell out.

**Observed on this Mac (live `pmset -g assertions`), useful as calibration:**
```
pid 8216(Screens 5): NoIdleSleepAssertion named: "Remote access is enabled"
pid 82845(caffeinate): PreventUserIdleSystemSleep / PreventUserIdleDisplaySleep "caffeinate command-line tool"
pid 429(powerd): PreventUserIdleSystemSleep "Powerd - Prevent sleep while display is on"
```
Screens is using the 10.7-deprecated type. It still works (launchd/powerd map the legacy string), but Vantage should use the modern constant.

**Clamshell (MacBook hosts):** Apple's closed-display mode requires **all three** of: an external display recognized by macOS (connected and awake *before* the lid closes), **AC power** (clamshell does not work on battery), and an external keyboard/mouse (USB or Bluetooth). Two escape hatches:
- `sudo pmset -a disablesleep 1` — a system-wide sleep disable that ignores lid state. (This Mac currently shows `SleepDisabled 1`.) Blunt, requires admin, and thermally risky in a bag.
- A **virtual display** (BetterDisplay, or your own CoreDisplay/virtual-display path) can satisfy the "external display" requirement without physical hardware on some configurations — this is worth prototyping, since it also serves §2.3.
- Even in clamshell, macOS's idle timer keeps running; you still need the power assertion.

**Wake on LAN / `pmset womp`:** `pmset -a womp 1` enables "Wake for network access" (System Settings → Battery/Power Adapter → Options → **Always**). This Mac shows `womp 1`, `tcpkeepalive 1`, `powernap 1`. Edovia's own article on this only tells users to set "Wake for network access" to **Always** and to keep the Mac on power; it says nothing about Power Nap, Bonjour Sleep Proxy, WoL packets, or VPNs.

**Can Tailscale traffic wake a sleeping Mac? No.** Wake-on-LAN is a **layer-2** magic frame; Tailscale is a **layer-3** overlay and cannot carry it, even with subnet routing. Bonjour Sleep Proxy / Wake on Demand depends on local mDNS multicast plus WoL and therefore has the same boundary. There is one nuance worth stating precisely: macOS's own `tcpkeepalive`/Wake on Demand can wake a Mac for an **incoming TCP connection on the local link** (or via a sleep proxy on the LAN), which is why `vnc://` over LAN sometimes "just works" — but a Tailscale/WireGuard session is a UDP tunnel terminated by a userspace daemon that is not running while asleep, so there is nothing for the sleep proxy to proxy.

**Verdict:** for a Tailscale-only product, the answer is **prevent sleep while on AC** (assertion policy above) and optionally document an always-on LAN helper (Pi/NAS on the tailnet) that can send the magic packet on demand. Don't promise wake-over-Tailscale.

**Detecting AC power** (`IOKit.ps`):
- Cheapest check: `IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() != nil` → adapter attached.
- Full enumeration: `IOPSCopyPowerSourcesInfo()` → `IOPSCopyPowerSourcesList(blob)` → `IOPSGetPowerSourceDescription(blob, source)` and read `kIOPSPowerSourceStateKey` (`kIOPSACPowerValue` / `kIOPSBatteryPowerValue`), `kIOPSIsChargingKey`, `kIOPSCurrentCapacityKey`.
- Change notifications: `IOPSNotificationCreateRunLoopSource(callback, context)` added to the run loop — this is the correct "power source changed" hook. (`NSWorkspace` has `willSleepNotification` / `didWakeNotification` / `screensDidSleepNotification` / `screensDidWakeNotification` / `sessionDidBecomeActiveNotification` / `sessionDidResignActiveNotification` on `NSWorkspace.shared.notificationCenter`, which you also want — but it has no power-source notification.)
- Handle the no-battery case (desktops report an AC-only source or none).

### 4.4 Locking the Mac programmatically, and what the lock screen means for capture

**What works on macOS 26/27, ranked:**

| Method | Public? | Behavior | Verdict |
|---|---|---|---|
| `SACLockScreenImmediate()` in `/System/Library/PrivateFrameworks/login.framework` | **Private** | Immediate lock to the login window regardless of screen-saver/security prefs | Works. **Verified present on macOS 27.0 (26A5421a)** via `dlopen` + `dlsym` — `SACLockScreenImmediate`, `SACScreenSaverStartNow`, and `SACScreenSaverIsRunning` all resolve; `SACLockScreen` does not. App Store submission would reject it; fine for Developer ID. Load via `dlopen`/`dlsym`, never link. |
| `pmset displaysleepnow` | Public CLI | Sleeps the display; **locks only if** "Require password … after sleep or screen saver begins" is set to *immediately* | Unreliable; depends on the user's setting |
| `open -a ScreenSaverEngine` / `SACScreenSaverStartNow()` | CLI / private | Starts the screen saver; same password-delay dependency | Same caveat |
| `CGSession -suspend` (`/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession`) | Undocumented CLI | Fast-user-switch to login window | **Reported broken since Big Sur**; don't use |
| `NSWorkspace` | Public | **No lock API exists.** | — |
| `AppleScript` / `SystemEvents` "Lock Screen" menu | Public-ish | Requires Automation TCC grant + the menu item present | Fragile |

**Recommendation:** ship `SACLockScreenImmediate` via `dlopen`, with `pmset displaysleepnow` as a fallback, and detect lock state via the distributed notifications `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` on `DistributedNotificationCenter.default()`.

**Does ScreenCaptureKit keep capturing while the lock screen is up?**

Two distinct situations, and the distinction is the whole ballgame:

1. **Screen locked, user still logged in, your process in the Aqua session.** The Aqua session and its WindowServer connection persist behind the lock screen, so an already-running `SCStream` generally keeps delivering frames — of the **lock screen**, not the desktop. So a remote user would see the lock UI. Empirically this is also where things get flaky (frames may stop or go blank depending on display sleep), so treat it as unreliable and handle `SCStreamDelegate` errors + restart.
2. **Logged out / at the login window.** Different session entirely; see §4.2 — not available to us.

**Can you type the password in remotely to unlock? No.** `loginwindow` enables **Secure Event Input** whenever the lock screen appears, which disables all third-party `CGEventTap`s and blocks synthetic keystroke delivery into the secure field. (There's a well-known corollary bug where `loginwindow` *leaks* secure input state and breaks event taps system-wide even after unlock.) So the "lock the remote display for privacy, then unlock it remotely by typing the password" flow is **not implementable**.

**Design consequence for Vantage's privacy feature.** Don't call it Curtain Mode and don't tie it to the lock screen. The workable design is:
- **Private Session** = create a virtual display sized to the iPad, make it the active/primary target, stream only that, and leave the physical display showing a neutral state (or asleep). Reversible in software, no TCC/lock-screen interaction, and it reuses the virtual-display work.
- **Lock on disconnect** = `SACLockScreenImmediate` as a *When Disconnecting* action, mirroring Screens' `Lock Screen`. Make clear in the UI that reconnecting after this will require physical or password-manager-assisted unlock (or auto-login on reboot).

### 4.5 Clipboard sync

**macOS side (`NSPasteboard`):**
- There is **no notification or KVO** for pasteboard changes. Polling `NSPasteboard.general.changeCount` is the only option.
- **Interval:** a fixed 0.5 s timer is ~7,200 wakeups/hour and is bad for battery. Use **adaptive polling**: ~0.25–0.5 s while a client session is active and the app is foreground-equivalent, back off to 2–5 s when idle/on battery, and **stop entirely** when no session is connected. Better still, drive polling off your existing session tick rather than a separate `Timer`.
- **Thread safety:** `-[NSPasteboard changeCount]` and `declareTypes:owner:` walk `_NSPasteboardOwnersCollection`, which AppKit mutates from the main thread on ownership changes. **Poll on the main thread** (or a single serial queue that also owns all pasteboard access). Background-thread polling is a documented crash source.
- **Loop avoidance:** after you *write* to the pasteboard from a remote update, immediately record the resulting `changeCount` as your "last seen" value and skip that generation. Additionally stamp your own writes with a private UTI (e.g. `com.vantage.origin` carrying a session UUID) so echoes are identifiable even if `changeCount` races.
- **Respect transient/concealed markers.** Per nspasteboard.org conventions, skip items bearing `org.nspasteboard.TransientType`, `org.nspasteboard.ConcealedType` (password managers), or `org.nspasteboard.AutoGeneratedType`. Syncing a 1Password clipboard entry to a remote device would be a real security bug.
- **Types to support, in priority order:**
  - `public.utf8-plain-text` (P0)
  - `public.rtf` / `public.html` (P1 — Screens documents rich text for Mac↔Mac)
  - `public.png`, `public.tiff` (P1 — size-cap these, e.g. 8 MB, and downscale/re-encode)
  - `public.file-url` (P2 — on macOS this is a *reference*; sending the URL alone is useless cross-device. Either resolve it and hand off to the file-transfer channel, or skip it.)
  - `public.url` (P2)

**iPadOS side (`UIPasteboard`) — the asymmetric rules:**
- **Writing is silent.** `UIPasteboard.general.string = …` produces no banner. So **remote → iPad** clipboard sync can be fully automatic.
- **Reading is not.** Any read of `UIPasteboard.general` contents from a foreground app triggers the system's "*YourApp pasted from OtherApp*" banner, and since iOS 16 may show an **Allow Paste / Don't Allow** alert when the source app differs.
- **Metadata reads are silent.** `numberOfItems`, `hasStrings` / `hasImages` / `hasURLs`, `contains(pasteboardTypes:)`, and `detectPatterns(for:completionHandler:)` do **not** trigger the banner. You can therefore detect *that* the clipboard changed and what kind of thing it holds without prompting.
- **`UIPasteControl` reads without any prompt.** A system-drawn paste button grants one-time access with no banner and no alert.

**Recommended Vantage design:**
- Remote → iPad: automatic, silent.
- iPad → remote: default to a **`UIPasteControl` in the session toolbar** ("Send Clipboard"), which is prompt-free and reads as an intentional user action. Offer an opt-in "Automatic clipboard sync" that accepts the banner, with copy explaining why the banner appears.
- Mirror Screens' vocabulary: `Use Shared Clipboard`, `Send Clipboard`, `Get Clipboard`, plus its notification strings.
- Note that `UIPasteboard.changedNotification` only fires for changes made by your own app in modern iOS; don't rely on it for cross-app detection — poll `changeCount` (silent) instead.

### 4.6 Menu bar app + SwiftUI Settings on macOS 26/27

**Structure:**
```swift
@main struct VantageHostApp: App {
    var body: some Scene {
        MenuBarExtra("Vantage", systemImage: "display.and.arrow.down") {
            HostStatusView()          // .window style → arbitrary SwiftUI
        }
        .menuBarExtraStyle(.window)   // vs .menu

        Settings { SettingsView() }   // macOS 11+
    }
}
```
- `MenuBarExtra` is macOS 13+. `.menuBarExtraStyle(.menu)` (default) renders a real `NSMenu` — only menu-ish content works, and SwiftUI controls are heavily restricted. `.menuBarExtraStyle(.window)` renders a popover-style panel and supports arbitrary SwiftUI (charts, toggles, a live stats HUD). **Use `.window`.**
- `isInserted:` binding lets the user hide the icon from Settings.
- Set `LSUIElement`. Note: with `LSUIElement`, `Settings` scene + `⌘,` still works, but the app is `.accessory` and won't come forward on its own.

**The Settings-window trap (this is a real, current bug — budget time for it):**
- `SettingsLink` (macOS 14+) is the sanctioned way to open Settings from a menu, but from a `MenuBarExtra` it frequently opens the window **behind** other apps or not at all, because the app isn't "active." The documented workaround is `SettingsLink`'s custom initializer (`SettingsLink { Label(...) } preAction: { NSApp.activate(ignoringOtherApps: true) } postAction: { ... }`) — that's what the third-party `SettingsAccess` package exists to provide.
- `@Environment(\.openSettings)` (macOS 14+) requires an existing SwiftUI render tree to resolve against; from a faceless menu-bar app it can silently do nothing. It is reported working on macOS 15 but **not working on macOS 26**.
- **Defensive pattern:** call `NSApp.activate(ignoringOtherApps: true)` first, then try `openSettings()`; if the Settings window doesn't appear within a run-loop turn, fall back to `NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)` (macOS 14+) and then the legacy `showPreferencesWindow:`. Then bring it forward explicitly by finding it in `NSApp.windows` and calling `makeKeyAndOrderFront(nil)` + `orderFrontRegardless()`. Verify on 27 early — the selector names have changed once already.

**Liquid Glass in menu bar apps (macOS 26/27):**
- The menu bar itself and `MenuBarExtra(.window)` panels pick up the system Liquid Glass material automatically when the app is built against the macOS 26+ SDK. Building against the new SDK is the opt-in; `UIDesignRequiresCompatibility` (Info.plist) is the temporary opt-out.
- For custom chrome inside the panel use SwiftUI's `.glassEffect(...)` / `GlassEffectContainer` and `.buttonStyle(.glass)` rather than hand-rolled `NSVisualEffectView`. In AppKit, `NSGlassEffectView` / `NSGlassEffectContainerView` are the equivalents.
- Practical notes: keep the panel's own background transparent and let the system material show through; don't stack glass on glass (nest via `GlassEffectContainer` instead); the menu bar is now translucent by default on 26+, so a monochrome, template-rendered `systemImage` is important for legibility over arbitrary wallpapers.
- Use SF Symbols with variable-value or `.symbolEffect` for state (connected / streaming / idle) rather than a colored dot.

---

## 5. Consolidated feature checklist (derived from Screens 5 / Jump) with priorities

Priority key: **P0** = required for "this replaces Screens for me"; **P1** = expected polish, first few releases; **P2** = nice-to-have / later.

### Connection library

| Feature | Screens 5 term | Jump | Priority | Notes |
|---|---|---|---|---|
| Tailscale device list from local daemon | `Tailscale` section | — | **P0** | Read `tailscaled` state; no cloud OAuth. Big differentiator |
| Online/offline status per device | connection tests | — | **P0** | Tailscale gives `Online` + `LastSeen` free |
| OS / device-type icon | — | — | **P1** | From tailnet `os` field |
| Rename / hide devices | "Hide and Rename Tailscale Devices" | — | **P1** | |
| List / Grid toggle | `as List` / `as Grid` | — | **P1** | |
| Sort by name / last connected / connection count | `Sort Sections` | — | **P1** | |
| Manual drag ordering | "Custom Grid Ordering" | — | **P2** | |
| Groups (create/rename/delete/move) | `Groups` | — | **P1** | |
| Search | unified search | — | **P0** | |
| Section visibility | `Section Visibility` | — | **P2** | Only if we have >1 section |
| Recents / links history | `Recent Links` | — | **P2** | |
| Import / export / backup | `Import Archive`, `Backups` | — | **P2** | |
| Quick Connect widget + App Intent | `Connect to Computer` | — | **P2** | Cheap once connections are modelled |

### Session: video

| Feature | Screens 5 term | Jump | Priority | Notes |
|---|---|---|---|---|
| HEVC + H.264 via VideoToolbox both ends | `Preferred Codecs` | Fluid 2.0 H.265 | **P0** | |
| 60 fps target with dynamic adaptation | — | "Dynamic Frame Rate Control", 60/30 | **P0** | Expose 60/30 preset |
| Adaptive quality / bitrate ladder | `Use Adaptive Quality` | — | **P0** | |
| Virtual display matched to iPad (Retina) | *not supported* | "Single Virtual Display", "Match iPad" | **P0** | Highest-value differentiator |
| Display selection / All Displays | `Display Selection`, `All Displays` | "Host Displays" | **P1** | |
| `Remember Selected Display` | same | — | **P1** | |
| Scaling on/off + initial mode | `Initial Scaling Mode`, `Toggle Scaling` | — | **P1** | |
| Live stats HUD (fps/bitrate/RTT/codec) | — | Live Fluid Connection Statistics | **P1** | Essential for our own debugging |
| Color depth options | `Color Depth`: Low/High/Very High | — | **P2** | Only meaningful for non-HEVC paths |
| HDR / P3 passthrough | — | — | **P2** | `SCCaptureDynamicRange` exists |
| AirPlay / external display mirroring | `Mirror to External Display` | — | **P2** | |

### Session: input

| Feature | Screens 5 term | Jump | Priority |
|---|---|---|---|
| Touch mode (tap-to-position cursor) | `Virtual Cursor Mode` → `Touch` | Standard | **P0** |
| Trackpad mode (relative cursor) | `Virtual Cursor Mode` → `Trackpad` | Trackpad | **P0** |
| Tap / double-tap / 2-finger tap (right) / 3-finger tap (middle) | as §1.4 | ~same | **P0** |
| Two-finger scroll with momentum + pixel-unit CGEvents | `Use Momentum Scrolling` | — | **P0** |
| Scroll speed (5 steps) | `Scrolling Speed` | — | **P1** |
| Cursor tracking speed (+ in-session adjust) | `Cursor Tracking Speed` | — | **P1** |
| Touch-and-hold drag with colored indicator (blue) | `Drag` | — | **P0** |
| Configurable hold-to-drag delay | `On-Screen Touch-and-Hold Drag Delay` | — | **P1** |
| 2-finger hold-drag = right-drag (red) | `Secondary Click Drag` | — | **P1** |
| 3-finger hold-drag = middle-drag (green) | `Middle Click Drag` | — | **P2** |
| Pinch to zoom + "lock zoom" option | `Zoom` / `Prevents pinching…` | pinch zoom | **P1** |
| Edge swipe → Dock / menu bar | `Show Dock` | — | **P1** |
| Corner swipe → Hot Corners | `Hot Corners` | — | **P2** |
| 3-finger swipes → Mission Control / Spaces | `Three-Finger Swipe Gestures` | — | **P1** |
| Hardware trackpad / mouse (indirect pointer) | `Trackpad & Mouse` | full mouse support | **P0** |
| Right-drag / middle-drag via hardware mouse | 5.9 additions | — | **P2** |
| Fallback cursor when remote hides it | `Use Fallback Cursor` | — | **P2** |
| Hide local cursor | `Hide Local Cursor` | — | **P2** |
| Apple Pencil tap = click, hover = move (Pencil Pro) | `Apple Pencil` | Pen mode | **P1** |
| Pencil squeeze / double-tap → configurable action | `Squeeze`, `Double Tap` | — | **P2** |

### Session: keyboard

| Feature | Screens 5 term | Priority |
|---|---|---|
| Hardware keyboard passthrough with modifiers | `Hardware Keyboard` | **P0** |
| Keystroke (virtual key code) input mode | `Keystrokes` | **P0** |
| Unicode input mode | `Unicode` | **P1** |
| `Send System Shortcuts to Remote Computer` toggle | same | **P0** |
| Local application of shortcuts when pointer is outside the render view | 5.x behavior | **P1** |
| `⇧⌃⌘`-prefixed in-app shortcut set | §1.6 table | **P1** |
| `⌘\` app switcher workaround | same | **P2** |
| Warn when Full Keyboard Access is on | troubleshooting article | **P1** — cheap, prevents a whole support category |
| Key repeat delay | `Delay Until Repeat` | **P2** |
| Fn key | `Fn Key` | **P2** |

### Session: toolbar & chrome

| Feature | Screens 5 term | Priority |
|---|---|---|
| In-session toolbar, docked bottom | `Docked` | **P0** |
| Floating toolbar, snap to 4 corners, expand/collapse | `Floating` | **P1** |
| Carousel (radial, follows Pencil tip) | `Carousel` | **P2** |
| Two-finger double-tap to toggle toolbar | `Toggle Toolbar Visibility` | **P1** |
| `Hide on Hardware Input` | same | **P1** |
| Customizable button set + spacers + size | `Toolbar Customization` | **P1** |
| Modifier keys, arrows, F-keys, system keys sections | `STR_TBT_SECTION_*` | **P1** |
| Commands menus (App / Desktop / System) | same | **P1** |
| `Type User Password` (biometric-gated) | same | **P1** |
| Screenshot / Save Screen Capture | `Grab Screenshot` | **P2** |
| Dictation → remote | `Dictation` | **P2** |

### Clipboard & files

| Feature | Screens 5 term | Priority |
|---|---|---|
| Shared clipboard (plain text, both directions) | `Use Shared Clipboard` | **P0** |
| Manual `Send Clipboard` / `Get Clipboard` (via `UIPasteControl`) | same | **P0** |
| Rich text + image types | "Improved Clipboard" | **P1** |
| Respect transient/concealed pasteboard markers | — | **P1** (security) |
| Clipboard sync notifications | `Clipboard Sync` | **P2** |
| Drag & drop file upload to remote | File Transfers | **P1** |
| Drag from remote → Files download | File Transfers | **P1** |
| Transfers panel with progress / cancel / clear | `File Transfers` | **P1** |
| Background continuation | 5.7 | **P2** |
| Per-connection `Allow File Transfers` | same | **P2** |

### Host, security, lifecycle

| Feature | Screens 5 term | Priority |
|---|---|---|
| Menu-bar host app, launch at login | `Show Screens in the Menu Bar` | **P0** |
| Keep Mac awake while reachable (AC only) | `Keep Mac Awake` | **P0** |
| `IOPMAssertionDeclareUserActivity(kIOPMUserActiveRemote)` during sessions | — | **P0** |
| Host-side permission onboarding (Screen Recording, Accessibility, Input Monitoring) | — | **P0** |
| Auto-reconnect with countdown | `Reconnect Automatically`, `Reconnecting in %d seconds…` | **P0** |
| Client app lock with Face ID + delay | `Lock Screens` + `Delay` | **P1** |
| Prevent client device sleep during session | `Disable Device Idle Timer` | **P1** |
| On-disconnect actions: lock / log out / nothing | `When Disconnecting` | **P1** |
| "Private Session" via virtual display | (Screens: `Curtain Mode`) | **P1** — our honest analogue |
| Observe (view-only) mode | `Observe` | **P2** |
| Session-in-use prompt when someone is at the Mac | `Someone is currently using the display…` | **P2** |
| Diagnostics report export | `Save Diagnostics Report…` | **P2** |
| `vantage://` URL scheme + Shortcuts action | `screens://` | **P2** |

---

## 6. Open questions

1. **Virtual display API on macOS 27.** Which path do we take — `CGVirtualDisplay` (private CoreGraphics, what BetterDisplay uses), a DriverKit/`DEXT` display driver, or something new in 26/27? This gates the single biggest differentiator (§2.3) and also the clamshell workaround (§4.3) and Private Session (§4.4). **Needs its own spike.**
2. **Does `SCStream` keep delivering frames across the lock screen on 27 in practice?** §4.4 reasons about it but it needs empirical testing: lock → observe frames; lock + display sleep → observe frames; fast user switch → observe.
3. **Can we get TCC Screen Recording attributed to the app bundle when capture runs in a bundled `BundleProgram` LaunchAgent?** If yes, one prompt from the visible app covers the agent. If no, the agent's first run will prompt invisibly. Test before committing to the agent architecture.
4. **Is `com.apple.developer.persistent-content-capture` obtainable for a small/personal Developer ID app?** Apple's form is aimed at VNC products. If not, how often does macOS 27 actually re-nag? Measure.
5. **Screens' Tailscale device list — does it surface online status and OS icons?** Strings don't prove it. Worth a 5-minute look at the running app's Tailscale section (read-only observation) before we design ours.
6. **Jump's support site is 403 to non-browsers.** The Fluid technical article and Live Statistics article weren't retrievable; if the exact stat list matters for HUD parity, fetch them through the `agent-browser` skill.
7. **Screens' `Lock Screens` delay values** — the exact menu options (Immediately / 1 min / 5 min / …) aren't in the strings file; they're likely generated. Check the running app if we want exact parity.
8. **Scroll fidelity target.** Does `CGEvent(scrollWheelEvent2Source:units:.pixel …)` plus momentum phase flags reproduce native trackpad feel in Safari/Xcode on 27, or do we need `kCGScrollWheelEventScrollPhase` / `kCGScrollWheelEventMomentumPhase` field manipulation? Prototype early — this is the #1 thing that makes remote desktops feel cheap.
9. **Pre-boot network + subnet router recovery path** — does the specific home network here (Wi-Fi security mode, router) satisfy macOS 26+'s pre-boot networking constraints? Needs one real test reboot with FileVault on before we document it as the recovery story.
10. **`openSettings` / `SettingsLink` on macOS 27** — confirm which of the fallbacks in §4.6 actually works on this build before designing Settings navigation around it.

---

## 7. Sources

**Edovia / Screens 5**
- [Screens 5 documentation index](https://help.edovia.com/en/screens-5)
- [★ Screens 5 Overview](https://help.edovia.com/en/screens-5/getting-started/basics)
- [Connect From Anywhere With Screens 5 And Tailscale](https://help.edovia.com/en/screens-5/connecting-anywhere/tailscale)
- [Cursor Control and Gestures on iPhone and iPad](https://help.edovia.com/en/screens-5/features/cursor-control-modes-and-other-gestures)
- [Interactive Toolbars (iPhone & iPad)](https://help.edovia.com/en/screens-5/features/ios-toolbar)
- [Toolbar Customization](https://help.edovia.com/en/screens-5/features/toolbar-customization)
- [Curtain Mode](https://help.edovia.com/en/screens-5/features/curtain-mode)
- [Adaptive Quality and Image Compression](https://help.edovia.com/en/screens-5/features/images-quality)
- [Clipboard Transfers](https://help.edovia.com/en/screens-5/features/clipboard)
- [Advanced Keyboard Settings](https://help.edovia.com/en/screens-5/features/advanced-keyboard-settings)
- [Available Keyboard Shortcuts for iPad and Vision Pro](https://help.edovia.com/en/screens-5/features/keyboard-shortcuts-ipados-visionos)
- [Apple Pencil Support](https://help.edovia.com/en/screens-5/features/pencil-support)
- [Display Selection](https://help.edovia.com/en/screens-5/features/display-selection)
- [File Transfers between an iPad and Mac](https://help.edovia.com/en/screens-5/features/file-transfers-ipad)
- [On-Disconnect Actions](https://help.edovia.com/en/screens-5/features/on-disconnect-actions)
- [Get your Mac to wake up for incoming connections](https://help.edovia.com/en/screens-5/how-to/wake-for-connections-mac)
- [Connecting to a headless Mac](https://help.edovia.com/en/screens-5/how-to/headless-mac)
- [Full Keyboard Access and External Keyboards (iPad & Vision Pro)](https://help.edovia.com/en/screens-5/troubleshooting/full-keyboard-access)
- [Initial Notes on iOS 27, iPadOS 27, macOS 27, and visionOS 27](https://help.edovia.com/en/screens-5/faq/os-27)
- [Screens 5 Release Notes](https://help.edovia.com/en/screens-5/faq/release-notes)
- Local bundle: `/Applications/Screens 5.app/Contents/Resources/en.lproj/{Localizable,Main,ConnectionWindow,WhatsNew}.strings` (v5.9.2 build 10304)

**Jump Desktop**
- [Jump Desktop changelog](https://changelog.jumpdesktop.com/)
- [Dynamic Frame Rate Control For Fluid](https://changelog.jumpdesktop.com/dynamic-frame-rate-control-for-fluid-4fsvks)
- [General: Fluid Remote Desktop](https://support.jumpdesktop.com/hc/en-us/articles/216423983-General-Fluid-Remote-Desktop) *(403 to non-browser clients; content via search extracts)*
- [Live Fluid Connection Statistics](https://support.jumpdesktop.com/hc/en-us/articles/4423458049165-Live-Fluid-Connection-Statistics) *(403)*
- [iPad: Input methods](https://support.jumpdesktop.com/hc/en-us/articles/216423623-iPad-Input-methods) *(403)*
- [Getting Started: Controls and Gesture Reference](https://support.jumpdesktop.com/hc/en-us/articles/216423503-Getting-Started-Jump-Desktop-Controls-and-Gesture-Reference) *(403)*
- [How do I prevent Jump from changing my screen resolution?](https://support.jumpdesktop.com/hc/en-us/articles/360036955511-How-do-I-prevent-Jump-from-changing-my-screen-resolution) *(403)*
- [Fluid: Black bars on the side of the screen…](https://support.jumpdesktop.com/hc/en-us/articles/360041534252-Fluid-Black-bars-on-the-side-of-the-screen-or-desktop-not-fill-iPad-Pro-11-screen) *(403)*

**RustDesk**
- [Mac – RustDesk Documentation](https://rustdesk.com/docs/en/client/mac/)
- [RustDesk Unattended Access: Setup Guide](https://rustdesk.com/blog/rustdesk-unattended-access-setup/)
- [macOS Platform – DeepWiki (rustdesk)](https://deepwiki.com/rustdesk/rustdesk/5.3-macos-platform)
- [Privacy Mode for macOS during remote control sessions (discussion #10909)](https://github.com/rustdesk/rustdesk/discussions/10909)
- [How to make macOS RustDesk client start at boot / login screen (discussion #7762)](https://github.com/rustdesk/rustdesk/discussions/7762)
- [macOS Auto-Start Service Setup (MDM) – wiki](https://github.com/rustdesk/rustdesk/wiki/macOS-Auto%E2%80%90Start-Service-Setup-(for-Remote---MDM-Deployment))
- [macOS VT HEVC -12900 (issue #13069)](https://github.com/rustdesk/rustdesk/issues/13069)
- [Hardware encoder not recognized on Mac (issue #12784)](https://github.com/rustdesk/rustdesk/issues/12784)
- [Fast User Switching freeze (discussion #13869)](https://github.com/rustdesk/rustdesk/discussions/13869)
- Local: `/Library/LaunchDaemons/com.carriez.RustDesk_service.plist`, `/Library/LaunchAgents/com.carriez.RustDesk_server.plist`

**Apple — lifecycle, power, capture, clipboard, UI**
- [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
- [Updating your app package installer to use the new Service Management API](https://developer.apple.com/documentation/servicemanagement/updating-your-app-package-installer-to-use-the-new-service-management-api)
- [Persistent Content Capture entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.persistent-content-capture)
- [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) · [Capturing screen content in macOS](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos)
- [Capturing screen buffer at macOS Login Window with ScreenCaptureKit and PrivilegedHelper (forums 814152)](https://developer.apple.com/forums/thread/814152)
- [Capture Screen pre-login context on macOS 15 (forums 768146)](https://developer.apple.com/forums/thread/768146)
- [loading SMAppService LoginWindow agent (forums 726864)](https://developer.apple.com/forums/thread/726864)
- [Keeping NSApplication during LoginWindow (forums 692831)](https://developer.apple.com/forums/thread/692831)
- [Programmatically lock screen in macOS Big Sur (forums 682918)](https://developer.apple.com/forums/thread/682918)
- [Technical Q&A QA1340 — Registering and unregistering for sleep and wake notifications](https://developer.apple.com/library/archive/qa/qa1340/_index.html)
- [kIOPMAssertionTypePreventUserIdleSystemSleep](https://developer.apple.com/documentation/iokit/kiopmassertiontypepreventuseridlesystemsleep)
- [MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra)
- [UIPasteControl](https://developer.apple.com/documentation/uikit/uipastecontrol)
- [What's new for enterprise in macOS Tahoe 26](https://support.apple.com/124963)
- [apple_ssh_and_filevault(7)](https://keith.github.io/xcode-man-pages/apple_ssh_and_filevault.7.html)
- [Manage login items and background tasks on Mac (Deployment guide)](https://support.apple.com/guide/deployment/manage-login-items-background-tasks-mac-depdca572563/web)
- Local SDK: `MacOSX27.0.sdk/System/Library/Frameworks/IOKit.framework/Headers/pwr_mgt/IOPMLib.h`, `…/ScreenCaptureKit.framework/Headers/SCStream.h`
- Local: `man caffeinate`, `man pmset`, live `pmset -g` / `pmset -g assertions`; `dlopen`/`dlsym` probe of `login.framework` on macOS 27.0 (26A5421a)

**Third-party technical writeups**
- [Programmatically lock the screen — Timac](https://blog.timac.org/2016/0605-programmatically-lock-the-screen/)
- [Showing Settings from macOS Menu Bar Items — Peter Steinberger](https://steipete.me/posts/2025/showing-settings-from-macos-menu-bar-items)
- [SettingsAccess (orchetect)](https://github.com/orchetect/SettingsAccess)
- [NSPasteboard.org — transient/concealed pasteboard conventions](https://nspasteboard.org/)
- [UIPasteboard's privacy change in iOS 16 — Sarunw](https://sarunw.com/posts/uipasteboard-privacy-change-ios16/)
- [Unlocking FileVault via SSH on macOS Tahoe — Der Flounder](https://derflounder.wordpress.com/2025/10/11/unlocking-filevault-via-ssh-on-macos-tahoe/)
- [You can finally manage Macs with FileVault remotely in Tahoe — Jeff Geerling](https://www.jeffgeerling.com/blog/2025/you-can-finally-manage-macs-filevault-remotely-tahoe/)
- [Tahoe FileVault: iCloud Keychain and SSH — Michael Tsai](https://mjtsai.com/blog/2025/09/22/tahoe-filevault-icloud-keychain-and-ssh/)
- [Sequoia Screen Recording Prompts and the Persistent Content Capture Entitlement — Michael Tsai](https://mjtsai.com/blog/2024/08/08/sequoia-screen-recording-prompts-and-the-persistent-content-capture-entitlement/)
- [Wake-on-LAN packet support (tailscale#306)](https://github.com/tailscale/tailscale/issues/306)
- [Making a Wake-on-LAN server using Tailscale, UpSnap, and Raspberry Pi](https://tailscale.com/blog/wake-on-lan-tailscale-upsnap)
- [Bonjour Sleep Proxy (Wikipedia)](https://en.wikipedia.org/wiki/Bonjour_Sleep_Proxy)
- [Moonlight FAQ (moonlight-docs wiki)](https://github.com/moonlight-stream/moonlight-docs/wiki/Frequently-Asked-Questions) · [Setup Guide](https://github.com/moonlight-stream/moonlight-docs/wiki/Setup-Guide)
- [Grant security permissions on macOS — AnyDesk](https://support.anydesk.com/docs/security-permissions-on-macos) · [AnyDesk Unattended Access](https://anydesk.com/en/features/unattended-access)
- [How to use a MacBook with the lid closed — Macworld](https://www.macworld.com/article/673295/how-to-use-macbook-with-lid-closed-stop-closed-mac-sleeping.html)
</content>
</invoke>
