# Virtual display research — matching a Mac workspace to an iPad Pro 11" viewport

Research date: 2026-09-21
Host under test: Apple M3 Max MacBook Pro, macOS 27.0 (build 26A5421a), BetterDisplay 5.0.5 (build 53492, Pro active)
Target client: M4 iPad Pro 11" — 2420×1668 px @ 264 ppi → **1210×834 pt @2x**

Everything marked **[verified locally]** was executed read-only on this Mac during research. Everything else is cited in [Sources](#sources).

---

## Summary and recommendation

**Use BetterDisplay for v1, behind a protocol, and keep a direct `CGVirtualDisplay` backend as the v2 path.** Do not start with raw `CGVirtualDisplay`.

Reasoning:

1. **The target configuration already works on this exact Mac.** A BetterDisplay virtual screen named `iPad Pro 11` is live right now at exactly 1210×834 pt / 2420×1668 px, backing scale 2.0, 60 Hz, and it is the main display. **[verified locally]** There is no research risk left on "can macOS do this" — it is done.

2. **BetterDisplay is itself a `CGVirtualDisplay` client.** `nm -u` on the app binary shows `_OBJC_CLASS_$_CGVirtualDisplay` and `_OBJC_CLASS_$_CGVirtualDisplayDescriptor`. **[verified locally]** So BetterDisplay is not doing anything you could not do — it is doing the same thing with several years of edge-case handling (mode-list synthesis, EDID/flexible scaling, mirror arbitration, arrangement persistence, reconnect-after-sleep) that you would otherwise have to rebuild.

3. **Raw `CGVirtualDisplay` has two currently-documented landmines that directly hit this use case** (both measured by the `go-macos/virtualdisplay` maintainers on macOS 26.6.2, Apple Silicon):
   - *Mode change makes the display un-removable.* Once you switch a virtual display into a mode, releasing the `CGVirtualDisplay` object no longer removes it; it persists until the creating **process** exits. Our whole feature is "restore on disconnect", so this is a direct hit.
   - *A process that queries CoreGraphics about displays **before** creating a virtual one can never obtain a `CGDisplayMode` for the display it then creates.* Our app must enumerate displays to snapshot state, so this is also a direct hit.

   Both are survivable — you put the virtual display in a **separate short-lived helper process** that does no CG display enumeration before creation, and you kill the helper to tear the display down. But that is real architecture, and it is the architecture BetterDisplay already ships.

4. **The BetterDisplay CLI is too slow to be the hot path.** Measured round-trip for a trivial `get`: **2.33 s / 2.52 s / 2.93 s**. **[verified locally]** The `betterdisplaycli` Homebrew "binary" is a one-line shell wrapper that `exec`s the full app bundle binary as a client, so every call pays app-launch cost. The `betterdisplay://` URL scheme via `open -g` measured **0.44 s** **[verified locally]**, and the HTTP integration on port 55777 would be milliseconds — but HTTP is **currently disabled** on this Mac (connection refused). **Enable HTTP integration and drive BetterDisplay over `http://localhost:55777/…`, not over the CLI.**

**Recommended shape:**

```
protocol WorkspaceProvider {
    func activate(pointSize: CGSize, scale: CGFloat, refreshHz: Int) async throws -> CGDirectDisplayID
    func deactivate() async throws
}
```

- `BetterDisplayProvider` — HTTP on `localhost:55777`, virtual screen pre-created and reused, `connected=on/off` to attach/detach. Ship this.
- `CGVirtualDisplayProvider` — XPC helper process, private API, zero dependencies. Build second, gate behind a preference, use it as the fallback when BetterDisplay is not installed.

Do **not** plan to ship on the Mac App Store with either backend: `CGVirtualDisplay` is private API, and shelling out to/controlling another app is also a problem.

---

## 1. BetterDisplay integration surface

### 1.0 What changed, and what the CLI actually is

- The Homebrew `betterdisplaycli` cask installs a **shell wrapper**, not a separate binary:
  ```
  $ cat /opt/homebrew/Caskroom/betterdisplay/4.1.1/betterdisplay.wrapper.sh
  #!/bin/bash
  exec '/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay' "$@"
  ```
  **[verified locally]** Note the Caskroom path still says `4.1.1` while the installed app is 5.0.5 — the wrapper is version-independent because it just execs whatever is in `/Applications`. **The CLI is the app binary run in client mode. The app must be running.**
- BetterDisplay 5.x exposes **five** integration methods, individually toggleable in *Settings → Application → Integration*: command line, custom URL scheme, HTTP, notification-based, and macOS Shortcuts (App Intents). **[verified locally, from `betterdisplaycli help`]**
- Signing: the app ships with only `com.apple.security.cs.allow-jit` and `com.apple.security.network.client` entitlements. **[verified locally]** No private entitlement is involved; `CGVirtualDisplay` needs none.
- There is a `Contents/MacOS/BetterDisplayHelper` and a `Contents/Library/LaunchDaemons` privileged helper (`BetterDisplay.PrivilegedHelperProtocol` appears in the binary) **[verified locally]** — used for DDC/EDID work, not needed for virtual screens.

Authoritative grammar (from the app's own `help`, which is far more complete and current than the GitHub wiki):

```
BetterDisplay operation [operation] [-parameter[=value]] [-parameter[=value]]
betterdisplaycli   operation [operation] [--parameter[=value]] …     # single or double hyphen both work
BetterDisplay://operation[/operation]?param=value&param=value        # x-callback-url supported
http://<host>:55777/command/?param=value&param=value                 # port configurable, optional token=
```

**Operations:** `perform`, `set`, `get`, `toggle`, `feed`, `create`, `discard`, `help`, `exit`, `clear`.
Operations can be combined, e.g. `set … get …` to set-and-read-back.

**Identifiers:** `tagID`, `UUID`, `displayID`, `name`, `nameLike`(`n`), `originalName`, `originalNameLike`, `productName`, `productNameLike`, `vendor`, `model`, `serial`, `alphanumericSerial`, `yearOfManufacture`, `weekOfManufacture`, `registryLocation`, `type`/`deviceType` (`Display` | `VirtualScreen` | `DisplayGroup`), plus the dynamic selectors `displayWithMouse`, `displayWithFocus`, `displayWithMainStatus`, `displayWithNonMainStatus`. Target-side variants for `mirror`/`moveTo`/`stream`/`pip`: `targetTagID`, `targetUUID`, `targetDisplayID`, `targetName`(`targetN`), `targetNameLike`, `targetOriginalName`, `targetOriginalNameLike`, `targetSelf`.

> Note the docs say `nameLike`, not `-namelike`. Matching is case-insensitive so `-namelike=` also works, but prefer `-nameLike=`.

### 1.1 (a) List displays with identifiers and current mode

```bash
betterdisplaycli get -identifiers
```

**Parsing gotcha [verified locally]:** the output is a **comma-separated sequence of JSON objects with no enclosing array**. `json.load()` fails with `Extra data`. You must wrap it:

```swift
let wrapped = "[" + rawOutput.trimmingCharacters(in: .whitespacesAndNewlines) + "]"
let devices = try JSONDecoder().decode([BDDevice].self, from: Data(wrapped.utf8))
```

Actual output on this Mac **[verified locally]**, abridged:

```json
{
  "UUID" : "37D8832A-2D66-02CA-B9F7-8F30A301B230",
  "alphanumericSerial" : "",
  "deviceType" : "Display",
  "displayID" : "1",
  "model" : "41049",
  "name" : "Built-in Display",
  "originalName" : "Color LCD",
  "productName" : "Color LCD",
  "registryLocation" : "IOService:/AppleARMPE/arm-io@10F00000/AppleH15IO/disp0@84000000/IOMobileFramebufferShim",
  "serial" : "4251086178",
  "tagID" : "2",
  "vendor" : "1552",
  "weekOfManufacture" : "0",
  "yearOfManufacture" : "0"
},{
  "UUID" : "FC8A2389-3B8D-4DAD-BE9A-C5026197056A",
  "alphanumericSerial" : "",
  "deviceType" : "VirtualScreen",
  "displayID" : "30",
  "model" : "54424",
  "name" : "iPad Pro 11",
  "originalName" : "iPad Pro 11",
  "productName" : "iPad Pro 11",
  "registryLocation" : "",
  "serial" : "815271905",
  "tagID" : "153",
  "tagID (Display)" : "154",
  "tagID (VirtualScreen)" : "153",
  "vendor" : "2198",
  "weekOfManufacture" : "0",
  "yearOfManufacture" : "0"
},{
  "deviceType" : "DisplayGroup",
  "name" : "Default Group",
  "tagID" : "-1001"
}
```

**Critical modelling detail:** a virtual screen is **two devices** in BetterDisplay's model — a `VirtualScreen` object (the definition, `tagID 153`) and the `Display` it produces when connected (`tagID 154`). Identifying by `-tagID=153` can therefore match both and return two values (observed: `get -tagID=153 -connected` → `on,on`). **[verified locally]** Pin your queries with `-type=Display` or `-type=VirtualScreen` when it matters, or use the `tagID (Display)` value for display-side features.

Mode/geometry is *not* in `-identifiers`; query it separately (see 1.7).

### 1.2 (b) Create a virtual screen at a given pixel size / name / PPI, with a HiDPI 2× mode

Grammar (from `help`): *"`create` — Create a device. You need to specify `type=VirtualScreen`. You can add other `set` operation parameters to configure the virtual screen or alter its identifiers from default."*

Virtual-screen configuration parameters (complete list from `help`) **[verified locally]**:

| Parameter | Meaning |
|---|---|
| `virtualScreenName` | display name |
| `virtualScreenSerial` / `virtualScreenVendorNumber` / `virtualScreenModelNumber` | synthetic EDID identity |
| `aspectWidth` / `aspectHeight` | aspect base; generated modes are integer multiples of this |
| `sizeInch` | physical diagonal → drives reported PPI / `sizeInMillimeters` |
| `multiplierStep` | step between generated multiples |
| `limitMultiplierSize`, `multiplierMinWidth`, `multiplierMinHeight`, `multiplierMaxWidth`, `multiplierMaxHeight` | bounds on generated modes |
| `useResolutionList` | use an explicit list instead of generated multiples |
| `resolutionList` | `WIDTHxHEIGHT,[WIDTHxHEIGHT,…]` |
| `virtualScreenHiDPI` | expose HiDPI (2×) variants in the mode list |
| `flipped` | mirror the image (teleprompter) |

**The exact recipe for this project** (this is effectively what already exists here):

```bash
betterdisplaycli create \
  -type=VirtualScreen \
  -name="Vantage iPad Pro 11" \
  -virtualScreenName="Vantage iPad Pro 11" \
  -sizeInch=11 \
  -aspectWidth=605 -aspectHeight=417 \
  -useResolutionList=on \
  -resolutionList=1210x834,1331x917,1452x1001,1573x1084 \
  -virtualScreenHiDPI=on
```

Note the semantics: **`resolutionList` entries are POINT sizes, and `virtualScreenHiDPI=on` synthesizes the 2× pixel-backed variant of each.** The live config here is `aspectWidth=605, aspectHeight=417, sizeInch=11, useResolutionList=on, resolutionList=[[1210,834],[1331,917],[1452,1001],[1573,1084]], virtualScreenHiDPI=on, multiplierStep=1, limitMultiplierSize=off` **[verified locally]**, and the resulting mode list contains `1210x834 HiDPI 60Hz 8bpc` (currently selected) plus a plain `2420x1668 60Hz 8bpc` LoDPI mode.

Full `get -tagID=153 -displayModeList` output on this Mac **[verified locally]** (abridged to the relevant entries):

```
 6 - 1210x834 HiDPI 60Hz 8bpc Current
 7 - 1210x834 60Hz 8bpc
10 - 1331x917 HiDPI 60Hz 8bpc Default Native
15 - 1452x1001 HiDPI 60Hz 8bpc
17 - 1573x1084 HiDPI 60Hz 8bpc
21 - 2420x1668 60Hz 8bpc
22 - 2662x1834 60Hz 8bpc Native
28 - 605x417 HiDPI 60Hz 8bpc Unsafe
```

`aspectWidth=605 / aspectHeight=417` is exactly 2420×1668 ÷ 4; `sizeInch=11` yields a reported physical size of **230.2 × 158.7 mm** (= 11.01" diagonal) **[verified locally via `CGDisplayScreenSize`]**, which is what makes macOS's own PPI heuristics agree that 2× is the right default.

There is **no `dummy` device type** in BetterDisplay 5.x. The only `create`-able type is `VirtualScreen`; a "dummy"/headless display is just a virtual screen you do not stream from.

### 1.3 (c) Set a specific resolution + HiDPI mode by identifier; arbitrary sizes; "flexible" scaling

```bash
# by BetterDisplay tagID
betterdisplaycli set -tagID=154 -resolution=1210x834 -hiDPI=on -refreshRate=60

# by name (case-insensitive substring)
betterdisplaycli set -nameLike="iPad Pro 11" -resolution=1210x834 -hiDPI=on

# by macOS displayID
betterdisplaycli set -displayID=30 -resolution=1210x834 -hiDPI=on

# set-and-verify in one call
betterdisplaycli set -tagID=154 -resolution=1210x834 -hiDPI=on get -resolution -hiDPI

# or by mode index from displayModeList
betterdisplaycli set -tagID=154 -displayModeNumber=6

# favorites (Pro): record once, recall instantly — useful for restore
betterdisplaycli set -tagID=154 -saveFavoriteMode=1
betterdisplaycli set -tagID=154 -favoriteMode=1
```

**Are arbitrary sizes like 1210×834@2x possible? Yes — proven on this machine.** `CGDisplayCopyDisplayMode(30)` reports `points=1210x834 pixels=2420x1668 @60Hz scale=2.0`. **[verified locally]**

Two distinct BetterDisplay mechanisms produce "arbitrary" modes, and they are different things:

- **Virtual screen resolution list** (what we use). You literally enumerate the point sizes you want at creation time. The virtual display's EDID/mode table is synthesized to contain exactly those, plus HiDPI twins. This is the clean path and is deterministic.
- **"Flexible scaling"** (*Pro*, a per-display setting, not a virtual-screen setting). This injects additional scaled-resolution entries into a **physical** display's mode list so you can pick non-standard "looks like" sizes on hardware that macOS would otherwise restrict. In the app it appears as *"Enable flexible scaling, create custom scaled resolutions, modify native and default resolutions, change display name and role, override display EDID"* and *"Customize Flexible Scaling Resolution Range"* / *"Configure flexible scaling for …"*. **[verified locally from app binary strings]** Caveats surfaced in the app's own UI strings: *"Using 8K+ virtual screens might cause stability issues. Flexible scaling needs to be reapplied."* and *"all displays with the same vendor and model number are affected by the changes"*.
  Evidence it is active on this Mac: the **built-in** display (normally 3024×1964) now advertises `1210x834 pt ← 2420x1668 px` modes at 47/48/50/59/60/120 Hz with `ioFlags 0x200003`, i.e. injected non-stock entries. **[verified locally]** That is what lets the built-in mirror the virtual screen pixel-for-pixel.

There is no CLI verb literally named "flexible virtual screen"; you get flexibility either by listing the modes you want at `create` time (virtual screens) or by enabling flexible scaling (physical displays).

### 1.4 (d) Connect / disconnect a virtual screen without discarding it

```bash
betterdisplaycli set -tagID=153 -connected=off     # detach; definition persists
betterdisplaycli set -tagID=153 -connected=on      # re-attach
betterdisplaycli toggle -tagID=153 -connected
betterdisplaycli get   -tagID=153 -connected
```

Persistence is confirmed: `defaults read pro.betterdisplay.BetterDisplay` contains `virtualScreenTagIDs = "[153]"`, `"customName@VirtualScreen:153" = "iPad Pro 11"`, `"resolutionList@VirtualScreen:153" = "[[1210,834],…]"`, `"hiDPI@VirtualScreen:153" = 1`, `"connected@VirtualScreen:153" = 0`, `"wasEverConnected@VirtualScreen:153" = 1`. **[verified locally]** So the definition is stored in the app's preferences and `connected` is just a runtime attach flag.

**This is the key ergonomic win over raw `CGVirtualDisplay`:** create the virtual screen once, at install time; thereafter the session start/stop is a single `connected=on` / `connected=off`. No un-removable-display problem, no helper process.

Destroy it for real (only during uninstall):

```bash
betterdisplaycli discard -type=VirtualScreen -tagID=153
```

> `discard` **with no identifiers discards every discardable device with no confirmation and no undo.** Always pass identifiers. Also: there is **no `discardAll` parameter** — that appears in some third-party write-ups but `betterdisplaycli help -discardAll` falls through to generic help. **[verified locally]**

### 1.5 (e) Privacy curtain on the physical display

Options, weakest to strongest:

```bash
# 1. Software dim to black (gamma-table based; instant, reversible, no reconfiguration)
betterdisplaycli set -tagID=2 -softwareBrightness=0%
betterdisplaycli set -tagID=2 -softwareBrightness=100%

# 2. Combined (hardware backlight + software) — actually turns the backlight down
betterdisplaycli set -tagID=2 -combinedBrightness=0%

# 3. Hardware backlight off (external DDC displays only, not the internal panel)
betterdisplaycli set -nameLike=Dell -hardwareBacklight=off

# 4. Software-disconnect the panel entirely (Pro)
betterdisplaycli set -tagID=2 -connected=off
betterdisplaycli perform -disconnectAllButMain     # Pro; disconnect everything except main
betterdisplaycli perform -connectAllDisplays       # Pro; restore
```

Options 1–2 are the safe default. Option 4 is the real curtain — and if the virtual screen is main, `perform -disconnectAllButMain` is a one-liner that leaves the Mac running with *only* the iPad's workspace attached.

Caveat straight from the help text: *"`connected` — Connects or disconnects a display or virtual screen. For displays, **connection management capable connection and Pro is required**."* Whether the **internal** panel of an Apple Silicon MacBook qualifies is **not verified here** — see Open Questions. Empirically it is reported to work on Apple Silicon MacBooks when at least one other display is present, which is satisfied while the virtual screen is connected.

Also relevant for an actual privacy/curtain product: Apple's own Screen Sharing curtain (what Screens 5 calls "Curtain Mode") is a different mechanism entirely and survives the login window; BetterDisplay's dimming does not.

### 1.6 (f) Set the main display

```bash
betterdisplaycli set -tagID=154 -main=on
betterdisplaycli get -tagID=154 -main               # -> true
betterdisplaycli get -displayWithMainStatus -identifier=name
betterdisplaycli set -tagID=154 -protectAsMain=on   # Pro: pin main across reconfigurations
```

Help text: *"`main` — Sets a display as a main display (**unsetting is only possible by designating another display as main**)."* So "restore" means explicitly re-designating the built-in as main, not clearing a flag.

Arrangement control:

```bash
betterdisplaycli set -tagID=154 -placement=0x0                     # logical-pixel origin in global space
betterdisplaycli set -tagID=154 -moveTo=right -targetTagID=2       # Pro; relative placement
betterdisplaycli get -tagID=154 -placement
```

`moveTo` accepts `topLeftCorner, topLeft, top, topRight, topRightCorner, leftTop, left, leftBottom, rightTop, right, rightBottom, bottomLeftCorner, bottomLeft, bottom, bottomRight, bottomRightCorner`.

Mirroring:

```bash
betterdisplaycli set -tagID=2 -mirror=on -targetTagID=154   # mirror built-in onto the virtual screen
betterdisplaycli set -tagID=2 -mirror=off
betterdisplaycli get -tagID=2 -mirror
```

### 1.7 (g) Query current mode and geometry

```bash
betterdisplaycli get -tagID=154 -resolution        # 1210x834
betterdisplaycli get -tagID=154 -hiDPI             # on
betterdisplaycli get -tagID=154 -refreshRate       # 60Hz
betterdisplaycli get -tagID=154 -placement         # 0x0
betterdisplaycli get -tagID=154 -main              # true
betterdisplaycli get -tagID=154 -connected         # on
betterdisplaycli get -tagID=154 -mirror            # on
betterdisplaycli get -tagID=154 -displayModeList
betterdisplaycli get -tagID=154 -refreshRateList
betterdisplaycli get -tagID=154 -displayInformation
betterdisplaycli get -tagID=154 -EDIDReport
betterdisplaycli get -proAvailable                 # on
```

All of the above were run on this Mac; the values shown in the comments are the actual returns. **[verified locally]**

Other useful non-display-specific operations: `perform -reconfigure` (re-detect displays), `perform -restartApp`, `get -sidecarList`, `set -sidecarConnected=on -specifier=<name|UUID>`, `set -appMenu=on`, `get -installedColorProfileURLs`.

### 1.8 (h) Settings prerequisites, licensing, and transport choice

- **Integration must be enabled per-method** in *Settings → Application → Integration*. On this Mac: CLI **on** and URL scheme **on**; **HTTP is off** — `curl http://localhost:55777/...` returns connection refused and `lsof -nP -iTCP -sTCP:LISTEN` shows no BetterDisplay listener. **[verified locally]**
- **The app must be running.** The CLI is the app binary in client mode; there is no daemon-less path.
- **Pro:** `get -proAvailable` → `on` here. Per the wiki's free/Pro table, basic virtual-screen creation and CLI access are free, while *custom virtual screen configurations*, *HDR and high-refresh-rate virtual screens*, *display connection and disconnection*, *mirroring configuration and protection*, *custom scaled-resolution editing*, and *flexible HiDPI scaling* are Pro. In practice **this project needs Pro**: `connected` on a physical display, `disconnectAllButMain`, `rotation`, `favoriteMode`, `protect*`, and `stream` are all Pro-gated. The CLI itself is free but *"operations that control Pro features still require Pro."*
- **Transport latency, measured [verified locally]:**

  | Transport | Round trip | Returns a value? |
  |---|---|---|
  | `betterdisplaycli get …` | **2.33–2.93 s** | yes (stdout) |
  | `open -g "betterdisplay://get?…"` | **0.44 s** | only via x-callback-url |
  | `curl http://localhost:55777/…` | not measured (disabled) | yes (HTTP body) |

  **Recommendation: turn on HTTP integration, set a token, and use `URLSession` against `http://127.0.0.1:55777/`.** This removes ~2.5 s from every state transition and gives you a synchronous body to parse. Set the token in Settings and pass `&token=…`.
- **Return codes / output:** the CLI writes plain text to stdout (`on`, `1210x834`, `true`, `60Hz`) and only `-identifiers`, `-EDIDReport`, `-displayModeList` etc. produce structured-ish output. There is no global `--json` flag. `-identifiers` is the only JSON producer and it needs array-wrapping (see 1.1). Exit status was `0` for all successful calls here; **treat a hang as the failure mode** — see the warning below.
- **⚠️ The CLI blocks forever on malformed arguments.** During this research every invocation was wrapped as `perl -e 'alarm 8; exec @ARGV' betterdisplaycli …`. In app code, use `Process` with an explicit watchdog that `terminate()`s after ~5 s. (GNU `timeout` is not installed on this Mac.) This alone is a strong argument for the HTTP transport, where `URLSession` timeouts are trivial.

---

## 2. Doing it without BetterDisplay: private `CGVirtualDisplay`

### 2.1 The header

This is the reverse-engineered header used by DeskPad, verbatim from `DeskPad/CGVirtualDisplayPrivate.h`:

```objc
#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@class CGVirtualDisplayDescriptor;

@interface CGVirtualDisplayMode : NSObject
@property(readonly, nonatomic) CGFloat refreshRate;
@property(readonly, nonatomic) NSUInteger width;
@property(readonly, nonatomic) NSUInteger height;
- (instancetype)initWithWidth:(NSUInteger)arg1 height:(NSUInteger)arg2 refreshRate:(CGFloat)arg3;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@property(nonatomic) unsigned int hiDPI;
- (instancetype)init;
@end

@interface CGVirtualDisplay : NSObject
@property(readonly, nonatomic) NSArray *modes;
@property(readonly, nonatomic) unsigned int hiDPI;
@property(readonly, nonatomic) CGDirectDisplayID displayID;
@property(readonly, nonatomic) id terminationHandler;
@property(readonly, nonatomic) dispatch_queue_t queue;
@property(readonly, nonatomic) unsigned int maxPixelsHigh;
@property(readonly, nonatomic) unsigned int maxPixelsWide;
@property(readonly, nonatomic) CGSize sizeInMillimeters;
@property(readonly, nonatomic) NSString *name;
@property(readonly, nonatomic) unsigned int serialNum;
@property(readonly, nonatomic) unsigned int productID;
@property(readonly, nonatomic) unsigned int vendorID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)arg1;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)arg1;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property(retain, nonatomic) dispatch_queue_t queue;
@property(retain, nonatomic) NSString *name;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int serialNum;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int vendorID;
@property(copy, nonatomic) void (^terminationHandler)(id, CGVirtualDisplay*);
- (instancetype)init;
- (nullable dispatch_queue_t)dispatchQueue;
- (void)setDispatchQueue:(dispatch_queue_t)arg1;
@end

NS_ASSUME_NONNULL_END
```

Newer builds of the descriptor also carry **colour primaries and white point** properties (`redPrimary`/`greenPrimary`/`bluePrimary`/`whitePoint`); `hidpi-mirror` sets sRGB primaries explicitly. These are optional.

### 2.1b The classes still exist in macOS 27 — proven from the SDK

The strongest available evidence that this API has not been removed in macOS 27. The **macOS 27.0 SDK** (`MacOSX27.0.sdk`, from Xcode-beta) ships a CoreGraphics linker stub whose Objective-C class list contains all four classes, while the public headers contain **zero** occurrences of "Virtual". **[verified locally]**

```
$ SDK=$(xcrun --sdk macosx --show-sdk-path)     # …/MacOSX27.0.sdk
$ grep -rn "Virtual" "$SDK/System/Library/Frameworks/CoreGraphics.framework/Headers/"
(no output — no public header)

$ grep -oE '[A-Za-z_$.]*[Vv]irtual[A-Za-z_$.]*' \
      "$SDK/System/Library/Frameworks/CoreGraphics.framework/Versions/A/CoreGraphics.tbd" | sort -u
CGVirtualDisplay
CGVirtualDisplayDescriptor
CGVirtualDisplayMode
CGVirtualDisplaySettings
_CGVirtualDisplaySettingsRefreshDeadlineNone
_kCGDisplayIsVirtualDevice
_kCGSVirtualDisplay
_kCGSVirtualDisplayCommunicatorPID
_kCGSVirtualDisplayInfoDictionary
_kCGSVirtualDisplayModelID
_kCGSVirtualDisplayOwnerPID
_kCGSVirtualDisplayOwnerUID
_kCGSVirtualDisplaySerial
_kCGSVirtualDisplayVendorID
_cglsGetVirtualScreen
```

Three things worth acting on:

- **`_CGVirtualDisplaySettingsRefreshDeadlineNone`** implies modern `CGVirtualDisplaySettings` has a `refreshDeadline` property that DeskPad's 2021-era header does not model. Harmless to omit, but it confirms the class shape has drifted — which is exactly the drift that produces the *"class CGVirtualDisplaySettings does not respond to `setModes`"* failure mode the Go package guards against. **Verify selectors at runtime; do not trust the vintage header.**
- **`_kCGDisplayIsVirtualDevice`** is a display-info key you can use to *detect* virtual displays (yours and other apps') without guessing from the name. Useful for "is BetterDisplay's screen already up?".
- **`_kCGSVirtualDisplayOwnerPID` / `_kCGSVirtualDisplayCommunicatorPID`** confirm the system tracks a virtual display's owning process — consistent with the observed "display persists until the creating process exits" behaviour in §2.4, and further justification for the helper-process design.

### 2.2 How DeskPad uses it from Swift

Add the header above to the target and reference it from `<Target>-Bridging-Header.h`. No framework to link — the classes live in CoreGraphics and are resolved as ordinary Objective-C classes. DeskPad's setup:

```swift
let descriptor = CGVirtualDisplayDescriptor()
descriptor.setDispatchQueue(DispatchQueue.main)
descriptor.name = "DeskPad Display"
descriptor.maxPixelsWide = 5120
descriptor.maxPixelsHigh = 2160
descriptor.sizeInMillimeters = CGSize(width: 1600, height: 1000)
descriptor.productID = 0x1234
descriptor.vendorID  = 0x3456
descriptor.serialNum = 0x0001

let display = CGVirtualDisplay(descriptor: descriptor)

let settings = CGVirtualDisplaySettings()
settings.hiDPI = 1
settings.modes = [
    CGVirtualDisplayMode(width: 5120, height: 1440, refreshRate: 60),
    CGVirtualDisplayMode(width: 5120, height: 2160, refreshRate: 60),
    // … 13 more …
]
display.applySettings(settings)
// display.displayID is now a live CGDirectDisplayID
```

**Safer alternative to a bridging header:** resolve everything through `NSClassFromString` + `NSSelectorFromString` and verify with `class_getInstanceMethod` before any message send. This is what `go-macos/virtualdisplay` does (`Available()` checks all four classes and every selector, returning `ErrUnavailable` naming the first missing one). It means a future macOS that renames a selector degrades to "no virtual display" instead of crashing. Given this is private API, **do this**, not the bridging header.

### 2.3 The rules that actually matter for a 1210×834@2x display

These are hard-won and are the difference between working and not:

1. **`modes` entries are PIXEL dimensions.** `hiDPI = 1` makes macOS *advertise* a half-point Retina twin of each mode. So to get 1210×834 pt @2x you declare a **2420×1668** mode and set `hiDPI = 1`.
2. **The virtual display runs the *first* entry in `settings.modes` as its preferred mode.** Order matters — put the mode you want at index 0.
3. **HiDPI twins are only synthesized for a *rich* mode list whose top mode matches `maxPixelsWide`/`maxPixelsHigh`.** A single-mode settings array will **not** get a 2× variant. Set `maxPixelsWide/High` to the largest mode you declare, and declare several modes.
4. **macOS refuses @2x modes when the short axis is under 526 points** (1052 px). Measured rejections: 374×666, 390×694, 400×711, 420×747, 480×853, 500×889, 512×910, 520×925, 524×932. Measured acceptances: 526×935, 528×939, 530×942, 540×960, 588×1278, 640×1138. Adjusting `sizeInMillimeters` or `maxPixelsWide/High` does **not** move the threshold. **Our 834-point short axis clears this comfortably**, but a rotated/portrait iPad mini profile would not.
5. **`sizeInMillimeters` must be plausible for the pixel count** or macOS's PPI heuristic will not choose 2× as default. For 11" 2420×1668 use **≈230.2 × 158.7 mm** — exactly what the live BetterDisplay screen reports. **[verified locally]**
6. **Vary `productID` per requested geometry.** macOS caches per-EDID mode preferences; reusing the same vendor/product/serial across different resolutions makes stale preferences stick. `hidpi-mirror` derives `productID` from the requested resolution for this reason.
7. **Lifetime is tied to the object and the process.** Releasing the `CGVirtualDisplay` removes the display — *unless* you have changed its mode (see below). `terminationHandler` fires if something else tears it down.

### 2.4 The two macOS 26/27 landmines

Measured by the `go-macos/virtualdisplay` maintainers on **macOS 26.6.2 (25G83), Apple Silicon M4 Max**:

- **Mode changes make displays un-removable.** *"Once a virtual display is switched into a different mode … releasing its `CGVirtualDisplay` object no longer removes it."* It persists until the creating process exits. Their package deliberately does **not** enter Retina modes for this reason: *"Setting `HiDPI` makes macOS advertise Retina modes — half the points, the same pixels [but] the package does not switch into Retina modes because doing so creates an un-removable display."*
- **CoreGraphics will not report modes for displays the creating process made,** *if that process queried CoreGraphics about displays first*: *"If a process asks CoreGraphics about displays before creating a virtual one, it can never obtain a `CGDisplayMode` for that new display."* Other processes are unaffected.

**Architectural consequence: put the virtual display in a dedicated XPC/launchd helper process that does no `CGGetOnlineDisplayList`/`CGDisplayCopyAllDisplayModes` call before `applySettings:`. Tear the display down by terminating the helper.** Your main app does the snapshotting and mode-setting; the helper only owns the display's lifetime. This is the only clean way to guarantee the "restore on disconnect" contract.

Also on macOS 26: `opendisplay` #213 reports **virtual display resolution falling back to 1280×720** for an iPad 10th-gen profile (expected 1180×820 pt / 2360×1640 px) — panel-size negotiation failing in the `CGVirtualDisplay` path while Sidecar handles the same panel correctly. Open, no fix. That failure mode is exactly what our feature would hit. Note the reporter's own diagnosis: *"CGVirtualDisplay itself was reported to work fine when tested with BetterDisplay creating a virtual screen that appeared correctly in System Settings"* — i.e. the API is fine, the caller's mode-list construction is what fails. Rules 1–6 above are the fix.

DeskPad's own tracker has no macOS 26/27-broken issue as of this research; the notable recent one is **#61 "Can't be in Clam Shell mode"** (Jan 2026, open, no maintainer response): closing the lid with a physical external display attached produces *"100s of tiny copies shrinking into the bottom left"*. See §4.

### 2.5 Entitlements, distribution, and visibility

- **No entitlements are required.** BetterDisplay — which uses these exact classes **[verified locally via `nm -u`]** — ships with only `com.apple.security.cs.allow-jit` and `com.apple.security.network.client`. **[verified locally]** Developer ID + notarisation is enough.
- **Mac App Store is out.** Review rejects private API. (Instantiating via `NSClassFromString` avoids *linking* private symbols but does not make it allowed.)
- **There is no public alternative.** The only sanctioned route to a synthetic display is a DriverKit driver extension requiring an Apple-granted entitlement.
- **Visibility to capture APIs:** the created display is an ordinary `CGDirectDisplayID`. It appears in `CGGetActiveDisplayList`/`CGGetOnlineDisplayList`, in `NSScreen.screens`, in `SCShareableContent.displays`, and in brightness/arrangement UI. **[verified locally on the BetterDisplay-created display: `CGGetActiveDisplayList` → id 30, `CGDisplayIsBuiltin` false, `CGDisplayIsActive` true]**
- **Refresh rate:** `CGVirtualDisplayMode` takes an arbitrary `CGFloat refreshRate`; 60 and 120 both work in the wild (`Froststrap/virtualdisplay` creates a 240 Hz virtual display). The BetterDisplay screen here is 60 Hz; BetterDisplay gates *"HDR and high-refresh-rate virtual screens"* behind Pro.

### 2.6 Honest evaluation

| | BetterDisplay | Raw `CGVirtualDisplay` |
|---|---|---|
| Works today at 1210×834@2x | **Yes, verified on this Mac** | Needs rules 1–6 right; #213 shows it's easy to get wrong |
| Dependency | Third-party app + Pro licence must be installed & running | None |
| Create/teardown | `connected=on/off`, definition persists | Un-removable after mode change → needs helper process |
| Latency per op | 2.5 s CLI / 0.44 s URL / ms over HTTP | microseconds |
| Mirroring, arrangement, main, curtain | All built in and Pro-tested | You implement each with `CGConfigureDisplay*` |
| Survives macOS updates | waydabber ships fixes fast | You own the breakage |
| Failure mode | CLI hangs / app not running | Selector rename → crash unless you guard |
| App Store | N/A (controlling another app) | Rejected |

**Verdict: BetterDisplay removes more risk than it adds for v1, but it is a hard runtime dependency on a paid third-party app.** If Vantage is meant to be self-contained, the `CGVirtualDisplay` backend is genuinely feasible — budget for the helper-process architecture and the six mode-list rules, and treat it as a two-week task, not an afternoon.

---

## 3. Workspace behaviour: getting windows onto the new display

Creating the display does nothing to existing windows. Four strategies:

### 3.1 Make the virtual display main (recommended)

Menu bar and all *new* windows follow the main display. On macOS, **main = the display whose origin is (0,0)**; you change it by translating the whole arrangement in one atomic transaction.

```swift
var cfg: CGDisplayConfigRef?
CGBeginDisplayConfiguration(&cfg)
// Move every display so the target lands at (0,0)
let target = CGDisplayBounds(virtualID).origin
for id in onlineDisplays {
    let b = CGDisplayBounds(id)
    CGConfigureDisplayOrigin(cfg, id,
                             Int32(b.origin.x - target.x),
                             Int32(b.origin.y - target.y))
}
CGCompleteDisplayConfiguration(cfg, .permanently)   // or .forSession
```

Options: `kCGConfigureForAppOnly`, `kCGConfigureForSession`, `kCGConfigurePermanently`. Use `.forSession` for something you intend to undo, `.permanently` only if you want it to survive logout.

BetterDisplay equivalent: `set -tagID=154 -main=on` (plus `-protectAsMain=on` to pin it).

Trade-off: existing windows stay where they were. Combine with 3.4 if you need them moved.

### 3.2 Mirror the built-in into the virtual display (what this Mac is doing now)

This is the Jump Desktop / BetterDisplay-recommended pattern for remote desktop, and it is the current live configuration here.

**Measured state on this Mac [verified locally]:**

```
ONLINE displays: 2 -> [30, 1]
  id=30 builtin=false active=true  main=true  mirrorsDisplay=0  bounds=(0,0,1210,834)
  id=1  builtin=true  active=false main=false mirrorsDisplay=30 bounds=(0,0,1210,834)

ACTIVE displays: 1
  id=30  1210x834 pt / 2420x1668 px @60Hz  scale=2.0  inMirrorSet=true inHWMirrorSet=true
         physSizeMM=(230.2, 158.7)
```

The **virtual screen is the hardware mirror master** and the built-in is the slave, forced to the same 1210×834 logical geometry (which is why BetterDisplay injected 1210×834@2x modes into the built-in's mode list — see §1.3).

```swift
CGBeginDisplayConfiguration(&cfg)
CGConfigureDisplayMirrorOfDisplay(cfg, builtInID, virtualID)   // built-in mirrors virtual
CGConfigureDisplayWithDisplayMode(cfg, virtualID, wantedMode, nil)
CGCompleteDisplayConfiguration(cfg, .forSession)
// undo:
CGConfigureDisplayMirrorOfDisplay(cfg, builtInID, kCGNullDirectDisplay)
```

BetterDisplay: `set -tagID=2 -mirror=on -targetTagID=154`.

Pros: every existing window is already "on" the iPad's workspace — nothing to move. The local user sees what the iPad sees. Cheap and instantaneous to undo.
Cons: the local screen is not private (opposite of a curtain), and the built-in runs at a non-native logical size so local text is slightly soft. Also, the built-in's physical aspect (3:2, 3024×1964) differs from the iPad's, so you get letterboxing on one of them.

**⚠️ ScreenCaptureKit interaction — important.** A display that is a **mirror secondary** is not active and is **omitted from `SCShareableContent.displays` entirely** — it does not appear wrong, it vanishes. `CGGetActiveDisplayList` excludes it too; only `CGGetOnlineDisplayList` shows it. Our local measurement confirms this exactly (active list = `[30]`, online = `[30, 1]`). Consequences:

- Always enumerate with **`CGGetOnlineDisplayList`** when hunting for mirror relationships to break; code that scans only the active list cannot find the mirroring display.
- If macOS auto-mirrors your new virtual display (it does this when it classifies the display as a TV and restores a saved "Mirror Entire Screen" arrangement — asynchronously, **seconds after creation**), your virtual display becomes the *secondary* and disappears from ScreenCaptureKit. `opendisplay` PR #126 fixes this with a guard that detaches on a ≤2 s tick, then waits up to **15 s** for SCK to re-list (guard ≤2 s + SCK re-list ≈2 s, which blew past their previous 5 s window).
- **Design rule: after creating/attaching the display, poll `SCShareableContent` until your `displayID` appears, with a 15 s budget, and actively break any mirror set in which your display is the secondary.**

### 3.3 Disconnect the built-in ("headless" workspace)

```bash
betterdisplaycli set -tagID=154 -main=on
betterdisplaycli perform -disconnectAllButMain      # Pro
# restore:
betterdisplaycli perform -connectAllDisplays
```

With the virtual screen as the only attached display, macOS relocates all windows onto it — which is precisely the desired "workspace" semantics — and the built-in panel goes dark (true curtain). This is the strongest option and the one that most resembles Jump Desktop's behaviour (*"Once virtual displays are engaged Jump will replace the host's physical monitors with virtual monitors"*).

Risks: window positions are mangled by the reflow and macOS's own restore-on-reconnect is imperfect; and if the virtual display goes away while the built-in is disconnected you can be left with no display at all. **Always re-connect before discarding the virtual screen, and add a watchdog that calls `perform -connectAllDisplays` if the session dies.**

Whether the *internal* panel of an Apple Silicon MacBook is "connection management capable" is unverified here — see Open Questions.

### 3.4 Move existing windows with the Accessibility API (fallback)

If you want windows relocated without disconnecting anything:

```swift
// Requires Accessibility (TCC) permission — AXIsProcessTrustedWithOptions
let app = AXUIElementCreateApplication(pid)
var windows: CFTypeRef?
AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
for w in (windows as! [AXUIElement]) {
    var p = CGPoint(x: targetX, y: targetY)
    let v = AXValueCreate(.cgPoint, &p)!
    AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v)
    var s = CGSize(width: 1210, height: 800)
    AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString,
                                 AXValueCreate(.cgSize, &s)!)
}
```

Gotchas: AX coordinates are **top-left origin, global**, unlike `NSScreen.frame` which is bottom-left origin — convert. Full-screen (Spaces) windows cannot be moved this way. Some apps clamp or ignore position sets. Requires an explicit user grant and a TCC prompt. Treat this as a "tidy up" pass after 3.1, not as the primary mechanism.

### 3.5 What the commercial apps actually do

- **Jump Desktop (Fluid Remote Desktop).** *Displays → Virtual Monitor*, choose **up to 4** virtual displays; *"Once virtual displays are engaged Jump will replace the host's physical monitors with virtual monitors."* They state virtual displays *"support arbitrary resolutions and can match your local display layout perfectly."* Separately, *"Match Display Resolution"* resizes the remote desktop as the client window changes, and on connect *"Jump Desktop tries its best to switch the resolution of the remote computer to match the aspect ratio of the device you're connecting from."* On iPad there is a manual override: pill icon → tool icon → *Display Resolution* → turn off *Match iPad* and enter a custom resolution. Their KB has a dedicated article for *"Black bars on the side of the screen or desktop not fill iPad Pro 11" screen"* — i.e. this exact aspect-matching problem is a known support burden, and the pre-virtual-display community workaround was to define the mode with SwitchResX.
- **Screens 5 (Edovia).** *Installed and running on this Mac* **[verified locally]**, alongside `screensharingd`. No virtual display; it rides Apple's VNC/Screen Sharing and offers **Curtain Mode**, which masks the remote Mac's display and *"ensures that Curtain Mode is activated, even after surpassing the macOS Login Window"* — something no user-space virtual display can do. It also lets you pick which display to view on multi-screen Macs and remembers the choice per session.
- **Duet / Luna / Astropad** historically used `CGVirtualDisplay`; modern versions vary.

**Takeaway for Vantage:** the differentiator is *exact* geometry matching (1210×834@2x, not "best effort aspect ratio"), which is achievable and which Jump explicitly does not guarantee.

---

## 4. Snapshotting and restoring state

### 4.1 What to snapshot

Before activating, record per online display:

```swift
struct DisplaySnapshot {
    let displayID: CGDirectDisplayID
    let uuid: CFUUID                    // CGDisplayCreateUUIDFromDisplayID — stable across reboots
    let mode: CGDisplayMode             // CGDisplayCopyDisplayMode
    let bounds: CGRect                  // CGDisplayBounds → origin
    let isMain: Bool                    // CGDisplayIsMain
    let mirrorsDisplay: CGDirectDisplayID  // CGDisplayMirrorsDisplay (0 = not mirroring)
    let rotation: Double                // CGDisplayRotation
}
```

**Key by UUID, not `displayID`.** `displayID` is not stable — BetterDisplay's own help says so (*"This ID might change from time-to-time"*), and here the virtual screen is `displayID 30` this session. Use `CGDisplayCreateUUIDFromDisplayID` / `CGDisplayGetDisplayIDFromUUID`.

> **Swift gotcha [verified locally by `swiftc -typecheck` on macOS 27]:** `CGDisplayCreateUUIDFromDisplayID` and `CGDisplayGetDisplayIDFromUUID` are **not** in the CoreGraphics Swift overlay. `import CoreGraphics` alone fails with *"cannot find 'CGDisplayCreateUUIDFromDisplayID' in scope"*. You must also `import ColorSync`. Every other function in this section (`CGBeginDisplayConfiguration`, `CGConfigureDisplayOrigin`, `CGConfigureDisplayWithDisplayMode`, `CGConfigureDisplayMirrorOfDisplay`, `kCGNullDirectDisplay`, `CGCompleteDisplayConfiguration` with `.permanently`/`.forSession`/`.forAppOnly`, `CGCancelDisplayConfiguration`, `CGDisplayRotation`, `CGDisplayMirrorsDisplay`, `CGDisplayIsAsleep`) type-checks from plain `import CoreGraphics`.

Restore in **one** transaction, and restore mirroring *first* (breaking mirror sets changes which displays are active):

```swift
var cfg: CGDisplayConfigRef?
CGBeginDisplayConfiguration(&cfg)
for s in snapshots { CGConfigureDisplayMirrorOfDisplay(cfg, s.displayID, s.mirrorsDisplay) }
for s in snapshots { CGConfigureDisplayWithDisplayMode(cfg, s.displayID, s.mode, nil) }
for s in snapshots { CGConfigureDisplayOrigin(cfg, s.displayID, Int32(s.bounds.minX), Int32(s.bounds.minY)) }
CGCompleteDisplayConfiguration(cfg, .permanently)
```

`CGCancelDisplayConfiguration(cfg)` aborts a pending transaction. Register `CGDisplayRegisterReconfigurationCallback` to observe changes you did not cause (BetterDisplay links it too **[verified locally]**).

BetterDisplay shortcut for the same thing: `set -tagID=N -saveFavoriteMode=1` before, `set -tagID=N -favoriteMode=1` after (Pro, 5 slots). Cheap and robust, but it only covers mode — not origin, main, or mirroring.

### 4.2 Clamshell (lid closed)

Apple's documented clamshell requirement is AC power + an external display + an external keyboard/mouse. **A virtual display does not reliably satisfy it**, and the evidence is negative:

- DeskPad issue **#61 "Can't be in Clam Shell mode"** (Jan 2026, open, unanswered): with a physical external monitor attached and the lid closed, *"all hell breaks loose on the display, shows 100s of tiny copies shrinking into the bottom left."*
- No source found in this research confirms that a purely virtual display keeps an Apple Silicon MacBook awake with the lid shut.

**Plan for this explicitly.** The reliable lever is:

```bash
sudo pmset -a disablesleep 1      # allow lid-closed operation with no external display
sudo pmset -a disablesleep 0      # revert
pmset -g | grep -i SleepDisabled  # verify
```

`disablesleep` requires root, persists across reboots until reverted, and is a big hammer.

**This Mac is already in that state [verified locally]:**

```
$ pmset -g
System-wide power settings:
 SleepDisabled		1
Currently in use:
 sleep         0 (sleep prevented by xcodebuild, powerd, Screens 5, caffeinate,
                  screensharingd, ChatGPT, coreaudiod, Claude)
 displaysleep  0 (display sleep prevented by caffeinate)
```

So `pmset disablesleep` is already 1 here and clamshell should already be permitted — but note **Screens 5 and `screensharingd` are running** (`/Applications/Screens 5.app` is installed and live **[verified locally]**). Vantage must not assume it is the only thing holding power assertions or reconfiguring displays, and should read `pmset -g` rather than blindly setting it (and must not clear a `SleepDisabled` the user set for their own reasons). Safer, non-root, process-scoped alternatives:

```bash
caffeinate -dimsu -w $PPID        # -d display, -i idle, -m disk, -s AC-system, -u user-active
```

or programmatically `IOPMAssertionCreateWithName` with `kIOPMAssertionTypeNoDisplaySleep` / `kIOPMAssertPreventUserIdleDisplaySleep` (display) vs `kIOPMAssertionTypeNoIdleSleep` / `kIOPMAssertPreventUserIdleSystemSleep` (system), or `ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled], reason:)`. **None of these override the lid switch** — only `pmset disablesleep` does.

Recommendation: require the lid open for v1, detect `CGDisplayIsAsleep`/lid state, and surface a clear UI affordance that offers to run the `pmset` change with an explicit admin prompt rather than doing it silently.

### 4.3 Display sleep and capture

If the physical display sleeps while the virtual display is the capture source, the virtual framebuffer should keep compositing — but this was **not verified here** and there are reports of framebuffers freezing. Hold a `kIOPMAssertPreventUserIdleDisplaySleep` assertion for the duration of a session; it is cheap and removes the question.

### 4.4 Login window, lock, and fast user switching

- User-space virtual displays (both BetterDisplay's and raw `CGVirtualDisplay`) belong to a **logged-in user session**. They do not exist at `loginwindow`, and they go away on logout. Fast user switching moves to another session where your process is not running.
- ScreenCaptureKit stops delivering meaningful content when the screen is locked.
- This is the one place where Apple's own Screen Sharing wins outright — Screens 5 advertises Curtain Mode that survives *"even after surpassing the macOS Login Window"*, because it is implemented in Apple's `screensharingd`, not in a user app.
- **Design rule: treat lock/logout as end-of-session. Tear the workspace down and restore on `NSWorkspace.sessionDidResignActiveNotification` / `com.apple.screenIsLocked`.**

---

## 5. macOS 26/27 first-party alternatives — none are public

- **No public API creates a display — confirmed against the macOS 27.0 SDK itself.** `grep -rn "Virtual" CoreGraphics.framework/Headers/` returns nothing, and no framework in `MacOSX27.0.sdk/System/Library/Frameworks` exposes a virtual-display header. The only files matching `VirtualDisplay` are linker stubs (`CoreGraphics.tbd`, `CoreDisplay.tbd`, `IOKit.tbd`, `QuartzCore.tbd`) plus unrelated HID headers. **[verified locally — see §2.1b]** The only Apple-sanctioned route to a synthetic display is a **DriverKit driver extension**, which needs an Apple-granted entitlement that is not generally available.
- **Screen Sharing "High Performance" mode** (macOS 14+) can add a virtual display for a remote session, but it is a feature of Apple's Screen Sharing app and `screensharingd`. There is no public API or documented CLI to create that display for your own app.
- **Sidecar** has no public API. `SidecarCore` / `sidecarrelay` are private. BetterDisplay's `get -sidecarList` and `set -sidecarConnected=on -specifier=<name|UUID>` **[verified locally, `sidecarList` returned empty]** are wrappers over that private surface, not over anything public.
- **`CGDisplayStream` is deprecated**; ScreenCaptureKit is the supported replacement and is what you should build on. `SCShareableContent.displays` does enumerate virtual displays (subject to the mirror-secondary caveat in §3.2). For exact-pixel capture set `SCStreamConfiguration.width`/`.height` to **2420 × 1668**, `captureResolution = .best`, `scalesToFit = false`, `pixelFormat = kCVPixelFormatType_32BGRA` (or `420v`/`420f` for a video encoder), and `minimumFrameInterval` to your target.
- **No new public virtual/headless-display API was announced at WWDC 2025 or WWDC 2026,** and the macOS 27.0 SDK header grep above independently confirms none shipped.
- **The private classes survive into macOS 27** — all four are still in the CoreGraphics stub's Objective-C class list. **[verified locally]** That is good news for the `CGVirtualDisplay` backend's near-term viability, but it is not a promise; see §2.1b on the `refreshDeadline` drift.

Practical consequence: there is no way to avoid either a private API or a third-party dependency. Choose which one you want to own.

---

## Open questions / verify on this Mac

1. **Does `set -tagID=2 -connected=off` actually disconnect the internal MacBook panel** on this M3 Max under macOS 27, and does `perform -connectAllDisplays` restore it cleanly? (Help says *"connection management capable connection and Pro is required"* — unverified for the internal panel.) **Test with the virtual screen connected and main, and have a recovery path ready.**
2. **Does the un-removable-after-mode-change bug apply to BetterDisplay's virtual screens?** i.e. does `set -tagID=153 -connected=off` genuinely remove the CG display, or only detach it logically? Check `CGGetOnlineDisplayList` before/after.
3. **Enable HTTP integration** (Settings → Application → Integration), set a token, and re-measure latency for `set -connected=on`. Expect <50 ms vs the measured 2.5 s CLI.
4. **Does the *creating process* mode-reporting bug bite us?** Write a 30-line harness: create a `CGVirtualDisplay`, then try `CGDisplayCopyAllDisplayModes` on its `displayID` from the same process, both with and without a prior `CGGetOnlineDisplayList` call.
5. **Clamshell:** with only the virtual screen connected and the built-in disconnected, close the lid on AC power. Does the Mac stay awake? Does the virtual display keep compositing? Does `SCStream` keep delivering frames?
6. **Does `SCShareableContent` list display 30 right now,** while it is the hardware mirror master? (Requires Screen Recording TCC, so not run during this read-only research.)
7. **120 Hz:** the current virtual screen is 60 Hz only. Determine whether a 120 Hz virtual screen (Pro feature *"HDR and high-refresh-rate virtual screens"*) is worth it given iPad ProMotion, and whether it survives macOS 27.
8. **Orientation:** portrait iPad = 1668×2420 px → 834×1210 pt. Short axis 834 pt still clears the 526-pt @2x floor, so a portrait profile is viable. Verify BetterDisplay's `rotation` (Pro) vs simply declaring a second resolution list entry.
9. **What is `ioFlags 0x200003`** on the built-in's injected 1210×834 modes? (Standard bits: `0x1` valid, `0x2` safe, `0x4` default, `0x2000000` native. `0x200000` is unidentified — likely a BetterDisplay/flexible-scaling marker.) Non-blocking, but worth knowing before filtering modes by flags.
10. **Is the existing `iPad Pro 11` virtual screen (tagID 153) something Vantage should adopt or replace?** Adopting it avoids a `create` call entirely; replacing it gives Vantage a clean, uniquely-named device it fully owns. Recommend: create `Vantage iPad Pro 11` with its own vendor/model/serial so the two never collide.

---

## Sources

**Verified locally on this Mac (read-only):** `betterdisplaycli help`, `betterdisplaycli get -identifiers`, `get -displayModeList`, per-feature `get` queries, `defaults read pro.betterdisplay.BetterDisplay`, `codesign -d --entitlements`, `nm -u`, `strings`, `system_profiler SPDisplaysDataType`, `pmset -g`, `lsof -nP -iTCP -sTCP:LISTEN`, `swiftc -typecheck` against the macOS 27 SDK, header/stub greps over `MacOSX27.0.sdk`, and two small Swift harnesses using `CGGetActiveDisplayList` / `CGGetOnlineDisplayList` / `CGDisplayCopyAllDisplayModes` / `CGDisplayScreenSize`.

No virtual screens were created or discarded and no display settings were changed during this research.

**BetterDisplay**
- [BetterDisplay wiki home](https://github.com/waydabber/BetterDisplay/wiki)
- [Integration features, CLI](https://github.com/waydabber/BetterDisplay/wiki/Integration-features,-CLI)
- [List of free and Pro features](https://github.com/waydabber/BetterDisplay/wiki/List-of-free-and-Pro-features)
- [BetterDisplay repository](https://github.com/waydabber/BetterDisplay)
- [betterdisplay.pro/integration](https://betterdisplay.pro/integration)

**CGVirtualDisplay implementations and reverse-engineered headers**
- [Stengo/DeskPad — `CGVirtualDisplayPrivate.h`](https://github.com/Stengo/DeskPad/blob/main/DeskPad/CGVirtualDisplayPrivate.h)
- [Stengo/DeskPad — `ScreenViewController.swift`](https://github.com/Stengo/DeskPad/blob/main/DeskPad/Frontend/Screen/ScreenViewController.swift)
- [DeskPad issue #61 — "Can't be in Clam Shell mode"](https://github.com/Stengo/DeskPad/issues/61)
- [DeskPad issue #66 — VirtualDisplayKit SPM fork](https://github.com/Stengo/DeskPad/issues/66)
- [go-macos/virtualdisplay](https://github.com/go-macos/virtualdisplay) and [pkg.go.dev docs](https://pkg.go.dev/github.com/go-macos/virtualdisplay) — the un-removable-display and mode-reporting caveats, macOS 26.6.2 test notes
- [pasky/hidpi-mirror](https://github.com/pasky/hidpi-mirror) — preferred-mode-is-first rule, rich-mode-list requirement, productID variation, `claimMain()`
- [Froststrap/virtualdisplay](https://github.com/Froststrap/virtualdisplay) — 240 Hz virtual display
- [trsdn/OpenPromptr](https://github.com/trsdn/OpenPromptr), [ovlerfork/Lumen-Fusion](https://github.com/ovlerfork/Lumen-Fusion), [crazyathlete220-stack/oldmac-display](https://github.com/crazyathlete220-stack/oldmac-display)
- [Hacker News — "It's a private API CGVirtualDisplay, but mostly well reverse engineered"](https://news.ycombinator.com/item?id=45201767)

**macOS 26/27 behaviour**
- [opendisplay #213 — macOS 26 virtual display falls back to 1280×720](https://github.com/peetzweg/opendisplay/issues/213)
- [opendisplay #292 — macOS refuses @2x modes under 526 points on the short axis](https://github.com/peetzweg/opendisplay/issues/292)
- [opendisplay PR #126 — virtual display hidden from ScreenCaptureKit by the TV mirror default](https://github.com/peetzweg/opendisplay/pull/126)
- [rustdesk #26 — CGDisplayStream broken for virtual displays](https://github.com/rophy/rustdesk/issues/26)
- [Apple Developer Forums — CGSetDisplayTransferByTable broken on Tahoe 26.4 RC](https://developer.apple.com/forums/thread/819331)

**Apple documentation**
- [SCShareableContent](https://developer.apple.com/documentation/screencapturekit/scshareablecontent)
- [Capturing screen content in macOS](https://developer.apple.com/documentation/ScreenCaptureKit/capturing-screen-content-in-macos)
- [Meet ScreenCaptureKit — WWDC22](https://developer.apple.com/videos/play/wwdc2022/10156/)
- [Take ScreenCaptureKit to the next level — WWDC22](https://developer.apple.com/videos/play/wwdc2022/10155/)
- [A look at ScreenCaptureKit on macOS Sonoma — Nonstrict](https://nonstrict.eu/blog/2023/a-look-at-screencapturekit-on-macos-sonoma/)

**Commercial remote-desktop behaviour**
- [Jump Desktop — Using the Display menu and virtual displays in Fluid sessions](https://support.jumpdesktop.com/hc/en-us/articles/45768818796813-General-Using-the-Display-menu-and-virtual-displays-in-Fluid-sessions)
- [Jump Desktop — Virtual Displays changelog](https://changelog.jumpdesktop.com/virtual-displays-pbTZC)
- [Jump Desktop — Black bars on iPad Pro 11"](https://support.jumpdesktop.com/hc/en-us/articles/360041534252-Fluid-Black-bars-on-the-side-of-the-screen-or-desktop-not-fill-iPad-Pro-11-screen)
- [Jump Desktop — Fluid Remote Desktop](https://support.jumpdesktop.com/hc/en-us/articles/216423983-General-Fluid-Remote-Desktop)
- [Jump Desktop — How do I prevent Jump from changing my screen resolution?](https://support.jumpdesktop.com/hc/en-us/articles/360036955511-How-do-I-prevent-Jump-from-changing-my-screen-resolution)
- [Full resolution Jump Desktop on iPad Pro 11" using SwitchResX — storck.io](https://storck.io/posts/jump-desktop-ipad-pro-11-inch-full-screen/)
- [Screens 5 — 9to5Mac overview (Curtain Mode)](https://9to5mac.com/2023/12/07/screens-5-mac-iphone-ipad-vnc-remote-desktop/)
- [Screens 5 on the App Store](https://apps.apple.com/us/app/screens-5-vnc-remote-desktop/id1663047912)
