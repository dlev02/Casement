# Vantage media pipeline research — ScreenCaptureKit → VideoToolbox → iPad

**Scope.** macOS host (macOS 26/27, Apple Silicon) captures a display and streams H.264/HEVC to an iPadOS 26/27 client (M4 iPad Pro 11", ProMotion) over Tailscale. Deployment floor macOS 26 / iPadOS 26. Toolchain: Xcode 27.0, Swift 6.4.

**Verification basis.** All API names, availability annotations, and header comments quoted below were read out of the **macOS 27.0 SDK** and **iphoneos 27.0 SDK** shipped with Xcode 27.0 (`Xcode-beta.app/.../MacOSX27.0.sdk`) on this machine, unless a source URL is given. Anything I could not verify is explicitly marked **UNVERIFIED** or **UNCERTAIN**.

> Status legend: ✅ verified in SDK headers or Apple docs · 📄 from Apple docs/WWDC · 🌐 from third-party report · ⚠️ uncertain / needs on-device measurement

---

## 0. Summary of recommendations

### Capture (macOS host)

1. **Pixel format: `'420v'` (`kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`).** ScreenCaptureKit does the RGB→YCbCr conversion in the WindowServer/GPU path, so you hand VideoToolbox exactly the biplanar surface its media engine wants — no CPU pass, no `vImage`, no intermediate pool. Apple explicitly recommends YUV420 for the encode path and BGRA only for on-screen preview (WWDC22-10155). Pair it with an explicit `colorMatrix` and `colorSpaceName` (see §3.4 colour).
2. **`minimumFrameInterval = CMTime(value: 1, timescale: 60)`** to start. The SDK header states you may set `kCMTimeZero` to capture at the display's native refresh rate — do not do that for a remote-desktop host; you want a hard cap you control.
3. **`queueDepth = 5`.** Apple's docs say the default/minimum is **3** and "don't exceed eight". The SDK *header comment* contradicts the docs and says the default is 8. Treat 5 as the tuned value (it is what Apple's own sample uses) and measure. **This is the single most latency-relevant capture knob** because VideoToolbox retains your source `CVPixelBuffer` until the encode completes — the encoder is *inside* your surface-return budget.
4. **`showsCursor = true`.** Compositing the cursor client-side is now a dead end on macOS 26/27 (see §1.5) — Apple deprecated `NSCursor.currentSystemCursor` with the message "Use ScreenCaptureKit … `showsCursor`", and it is documented to become permanently `nil`. Burn the cursor into the stream and accept the cursor latency; add a *local* predicted cursor on the iPad drawn on top if you want the pointer to feel instant.
5. **Use `SCFrameStatus` to gate encoding.** `.complete` → encode. `.idle` / `.blank` / `.suspended` → do not encode, but run a keepalive (see §1.3). `.stopped` → tear down. Use `SCStreamFrameInfoDirtyRects` as a *cheap motion/complexity estimator* (drive bitrate and "text mode vs motion mode"), not as a delta-encode mechanism — Apple's hardware encoders take whole frames.
6. **Sign with a stable identity from day one** (Apple Development at minimum, Developer ID for distribution). Ad-hoc signing makes TCC re-prompt on *every rebuild* because the cdhash changes.
7. **Plan for the monthly re-authorisation prompt.** It is still present in macOS 26. The only two real mitigations are adopting `SCContentSharingPicker`, or the managed entitlement **`com.apple.developer.persistent-content-capture`** (macOS 14.4+, Boolean, must be requested from Apple via a form; scoped to VNC apps). Apply for the entitlement early — Vantage is exactly the described use case and approval is manual.

### Encode (macOS host) — see §2 for the full property table

8. Create the session with `kVTVideoEncoderSpecification_EnableLowLatencyRateControl = true`, then set `RealTime = true`, `AllowFrameReordering = false`, `MaxKeyFrameInterval` very large (rely on on-demand IDRs, not periodic ones), `ExpectedFrameRate = 60`, `MaximizePowerEfficiency = false`.
9. **H.264 High profile is the safe default; HEVC Main is the quality win.** For 4:2:0 screen content at a fixed bitrate HEVC buys roughly 30–50% bitrate at equal quality, but verify low-latency rate control support on your exact chip/OS before committing (§2). **4:4:4 is not available on Apple hardware encoders** — this is the hard constraint behind coloured-text fringing, and the practical answer is "more bitrate", not "better chroma".
10. **Do not periodically force IDRs.** Force one only on (a) session start, (b) client-signalled decode failure/packet loss, (c) resolution/format change. Periodic IDRs at 2.4K are the single largest bitrate spike and the main cause of visible "breathing".

### Decode + display (iPad client) — see §3

11. Start with **`AVSampleBufferDisplayLayer` + `sampleBufferRenderer` (iOS 17+) with `kCMSampleAttachmentKey_DisplayImmediately = true`** on every sample buffer. It is far less code than a hand-rolled decode+Metal path. Measure it against a manual `VTDecompressionSession` + `CAMetalLayer` path before shipping; the manual path is the escape hatch if the layer adds a frame.
12. **Colour must be signalled explicitly end-to-end** or you get washed-out or crushed output. Pick one lane and never deviate: `'420v'` (video range) + BT.709 matrix + sRGB/709 transfer, attached at capture, carried in the SPS VUI, and re-attached on the client when you rebuild the `CMFormatDescription` from parameter sets.

### Pacing (both sides) — see §4

13. **Bound in-flight frames to 1–2.** Capture callback → if an encode is outstanding and a newer frame arrives, drop the older one. Only the newest frame matters in a remote desktop.
14. **Client feeds back `{ receiveTime, decodeTime, renderQueueDepth, RTT, loss }` at ~4 Hz**; host drives bitrate and `minimumFrameInterval` from it.
15. **Two modes.** *Text mode*: 30 fps cap, low QP ceiling, high per-frame quality. *Motion mode*: 60 fps, higher QP ceiling. Switch on dirty-rect area/rate. This is the single highest-leverage quality decision for a desktop-streaming app and is corroborated by Multi's WebRTC screenshare write-up (they cap at 30 fps with `maintainResolution` and tighten the QP range).

### Biggest surprises

- **`queueDepth`'s documented default (3) contradicts the SDK header (8).**
- **Apple is actively closing off separate cursor capture.** `NSCursor.currentSystemCursor` is deprecated *with the explicit note that it will always return `nil` in a future macOS*, and on macOS 26 capturing the cursor window via `SCScreenshotManager` now fails outright.
- **ScreenCaptureKit + virtual displays is a known-buggy combination** (FB17797423) — SCStream can bind to the wrong framebuffer after any virtual-display reconfiguration, including Sidecar and DisplayLink, not just BetterDisplay.
- **Login-window capture is supported** since macOS 14.4 — but only from a **LaunchAgent** with `LimitLoadToSessionType = ["Aqua", "LoginWindow"]`, never from a daemon.
- **There are essentially no new `SCStreamConfiguration` keys in macOS 26 or 27.** The 26/27 additions are recording/clip/editor features, not capture-path features.

---

## 1. ScreenCaptureKit on macOS 26/27

### 1.1 `SCStreamConfiguration` — the keys that matter for a remote desktop

All availability below is read directly from `MacOSX27.0.sdk/System/Library/Frameworks/ScreenCaptureKit.framework/Headers/SCStream.h`.

| Property (Swift) | Type | Availability | Recommendation & notes |
|---|---|---|---|
| `width` / `height` | `Int` (`size_t`) | macOS 12.3 | **Pixels, not points.** Default on macOS is 1920×1080 — you *must* set these or you silently downscale a Retina display. Set to the display's true backing pixel size (see §1.2). |
| `minimumFrameInterval` | `CMTime` | macOS 12.3, **macOS-only** (`API_UNAVAILABLE(ios, tvos, visionos)`) | "the desired **minimum time in seconds between frame updates**… The default value is 1/60 … **Set this to `kCMTimeZero` to capture at display's native refresh rate.**" (verbatim from header). Use `CMTime(value: 1, timescale: 60)`; drive it down to 30 in text mode. |
| `pixelFormat` | `OSType` | macOS 12.3, **macOS-only** | Header lists the exact supported set (see §1.1.1). Use `'420v'`. |
| `queueDepth` | `Int` | macOS 12.3 | **Conflicting documentation.** Header: "If not set the default value is **8** frames… should not exceed 8 frames." Apple docs page for `queueDepth`: "By default, the system sets the queue depth to its **minimum value of three frames**… Don't exceed a queue depth of eight frames." Apple's own sample project uses **5**. Use 5 and log the real default at runtime. |
| `showsCursor` | `Bool` | macOS 12.3, macOS-only | Default `true`. Keep `true` (see §1.5). |
| `showMouseClicks` | `Bool` | macOS 15.0 | Draws a circle on click. Header: "This property currently applies when `pixelFormat` is set to `BGRA`." → **does nothing in a `'420v'` pipeline.** Nice-to-have you can't have. |
| `scalesToFit` | `Bool` | macOS 12.3, macOS-only | "For use for independent window capture. When true, the output scales up and down. When false, the output only scales down." Leave `false` for display capture. |
| `preservesAspectRatio` | `Bool` | macOS 14.0 | Default `true`. Keep `true` — with it false you get a stretched image when the iPad aspect differs. |
| `sourceRect` | `CGRect` | macOS 12.3, macOS-only | **In points, display logical coordinates.** Use for "stream only this region". |
| `destinationRect` | `CGRect` | macOS 12.3, macOS-only | **In pixels, display coordinate system.** Note the points/pixels asymmetry with `sourceRect` — a classic bug source. |
| `colorMatrix` | `CFString` | macOS 12.3, macOS-only | "Should only be used if your pixel format is `420v` or `420f`." Set explicitly (see §4 colour). |
| `colorSpaceName` | `CFString` | macOS 12.3, macOS-only | "If not set the output buffer uses the **same color space as the display**." → **Set it explicitly** or a P3 display gives you P3-primaried YCbCr that your client will decode as 709. |
| `captureResolution` | `SCCaptureResolutionType` | macOS 14.0 | `.automatic` / `.best` / `.nominal`. `.best` = full backing-store pixels; `.nominal` = 1× points. For a fidelity-first remote desktop use `.best` **or** set `width`/`height` yourself to the pixel size and leave it `.automatic`. |
| `capturesShadowsOnly` | `Bool` | macOS 14.0 | Irrelevant here (captures *only* window shadows). Leave `false`. |
| `ignoreShadowsDisplay` / `ignoreShadowsSingleWindow` | `Bool` | macOS 14.0 | Display-capture case: `ignoreShadowsDisplay = true` removes window drop shadows. Marginal bitrate win (shadows are soft gradients that cost bits). Cosmetically changes the image. |
| `ignoreGlobalClipDisplay` / `ignoreGlobalClipSingleWindow` | `Bool` | macOS 14.0 | Only meaningful for window capture ("captures that are partially off the screen will not be clipped"). N/A for display capture. |
| `shouldBeOpaque` | `Bool` | macOS 14.0 | Backs transparent regions with solid white. Irrelevant for display capture (desktop is already opaque). |
| `presenterOverlayPrivacyAlertSetting` | `SCPresenterOverlayAlertSetting` | macOS 14.0 | `.system` / `.never` / `.always`. **Only governs the Presenter Overlay privacy alert**, not the Screen Recording TCC prompt. Setting `.never` does **not** suppress the monthly re-authorisation nag. |
| `includeChildWindows` | `Bool` | macOS 14.2 | Default `true`. N/A for display capture. |
| `backgroundColor` | `CGColor` | macOS 12.3 | Default clear. Set to black so letterboxed regions compress to nothing. |
| `capturesAudio`, `sampleRate`, `channelCount`, `excludesCurrentProcessAudio` | — | macOS 13.0 | Available if you want host audio on the iPad. `excludesCurrentProcessAudio = true` prevents a feedback loop. |
| `captureMicrophone`, `microphoneCaptureDeviceID` | — | macOS 15.0 | N/A. |
| `captureDynamicRange` | `SCCaptureDynamicRange` | macOS 15.0 | `.sdr` (default) / `.hdrLocalDisplay` / `.hdrCanonicalDisplay`. Header: "**HDR capture is only supported with Apple Silicon Mac**, setting this property on Intel Mac will have no effect. HDR recording is not support yet, adding a recording output to a stream with `SCCaptureDynamicRangeHDR` set will fail." Leave `.sdr` for v1 (see §1.7). |
| `streamName` | `String?` | macOS 14.0 | Cosmetic; shows in system UI. Set it — it's what the user sees in the sharing indicator. |

#### 1.1.1 Supported `pixelFormat` values (verbatim from `SCStream.h`)

```
'BGRA': Packed Little Endian ARGB8888          (macOS, iOS)
'l10r': Packed Little Endian ARGB2101010       (macOS)
'420v': 2-plane "video" range YCbCr 4:2:0      (macOS, iOS)
'420f': 2-plane "full"  range YCbCr 4:2:0      (macOS, iOS)
'xf44': 2-plane "full"  range YCbCr10 4:4:4    (macOS)
'RGhA': 64-bit RGBA IEEE half-precision float  (macOS)
'x420': 2-plane "video" range YCbCr10 4:2:0    (macOS, iOS)
```

Note `'xf44'` — ScreenCaptureKit **can** hand you 10-bit 4:4:4. That does **not** mean VideoToolbox can encode it in hardware (it can't; see §2). It's only useful if you ever add a software/lossless path.

#### 1.1.2 The minimum-copy configuration

```swift
let cfg = SCStreamConfiguration()
cfg.width  = pixelWidth            // true backing pixels, see §1.2
cfg.height = pixelHeight
cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange   // '420v'
cfg.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2           // CFString, see note below
cfg.colorSpaceName = CGColorSpace.sRGB                              // kCGColorSpaceSRGB
cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
cfg.queueDepth = 5
cfg.showsCursor = true
cfg.preservesAspectRatio = true
cfg.capturesAudio = false
cfg.backgroundColor = CGColor.black
cfg.captureResolution = .best
```

**Colour-constant naming gotcha (verified in the SDK).** `SCStreamConfiguration.colorMatrix` takes one of the legacy CGDisplayStream matrix strings. In `CGDisplayStream.h` the *dictionary key* `kCGDisplayStreamYCbCrMatrix` is annotated `SCREEN_CAPTURE_OBSOLETE(10.8, 14.0, 15.0)` — i.e. **obsoleted in macOS 15** — but the three *value* constants are **not** annotated and remain usable:

```
kCGDisplayStreamYCbCrMatrix_ITU_R_709_2        → Swift: CGDisplayStream.yCbCrMatrix_ITU_R_709_2
kCGDisplayStreamYCbCrMatrix_ITU_R_601_4        → Swift: CGDisplayStream.yCbCrMatrix_ITU_R_601_4
kCGDisplayStreamYCbCrMatrix_SMPTE_240M_1995    → Swift: CGDisplayStream.yCbCrMatrix_SMPTE_240M_1995
```
(Swift names read out of `CoreGraphics.apinotes`.) For `colorSpaceName` use `CGColorSpace.sRGB` (`kCGColorSpaceSRGB`); `CGColorSpace.itur_709` and `CGColorSpace.displayP3` are the other realistic choices.

**Also verified: `CGDisplayStreamCreate` / `CGDisplayStreamCreateWithDispatchQueue` are `obsoleted=15.0`** (`SCREEN_CAPTURE_OBSOLETE(10.8, 14.0, 15.0)`, message "Please use ScreenCaptureKit instead."). There is no CGDisplayStream fallback available to you on macOS 26.

Why this is minimum-copy:

- `SCStreamOutputTypeScreen` sample buffers are documented in the header as "wrapping a `CMSampleBuffer` that is **backed by an IOSurface**". The conversion to `'420v'` happens on the WindowServer side ("ScreenCaptureKit supports hardware accelerated color space, color matrix, and pixel format conversion" — WWDC22-10155).
- `CMSampleBufferGetImageBuffer(sb)` gives you a `CVPixelBuffer` view onto that IOSurface.
- `VTCompressionSessionEncodeFrame(session, imageBuffer: pb, …)` accepts that buffer directly. The media engine reads the IOSurface. **Zero CPU copies of pixel data on the host.**
- If you pick `BGRA` instead, VideoToolbox must colour-convert every frame before encoding. Do not do it.

**The trap:** VideoToolbox retains the source `CVPixelBuffer` for the duration of the encode. That surface comes out of ScreenCaptureKit's pool of `queueDepth` surfaces. WWDC22-10155's rule is that your release time must be under `minimumFrameInterval × (queueDepth − 1)`; with `queueDepth = 5` at 60 fps that is ~66 ms of encode budget, which is generous, but if you *also* hold frames in an application-level queue you will stall the WindowServer and start dropping. Keep the encoder the only holder.

### 1.2 Enumerating displays; pixel size; virtual displays

```swift
let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
// or: SCShareableContent.current  (Swift async name for getShareableContentWithCompletionHandler:)
for d in content.displays {
    d.displayID   // CGDirectDisplayID
    d.width       // Int — POINTS
    d.height      // Int — POINTS
    d.frame       // CGRect — points, global coordinate space
}
```

**`SCDisplay` has no `scale` property** (verified — the class exposes exactly `displayID`, `width`, `height`, `frame`). `width`/`height` are documented in the header as "in **points**". To get real pixels:

```swift
let mode = CGDisplayCopyDisplayMode(d.displayID)
let px  = CGDisplayModeGetPixelWidth(mode)   // backing-store pixels
let pt  = CGDisplayModeGetWidth(mode)        // points
let scale = Double(px) / Double(pt)
```

Alternatively, after building the filter, `SCContentFilter.pointPixelScale: Float` (macOS 14+) and `SCContentFilter.contentRect: CGRect` (points) give the same information, and `SCShareableContent.infoForFilter(_:)` → `SCShareableContentInfo { style, pointPixelScale, contentRect }` (macOS 14+) does it without creating a stream.

**Capturing exactly one display:**

```swift
let filter = SCContentFilter(display: someDisplay, excludingWindows: [])
// filter.includeMenuBar defaults to YES for the `excluding` initializer (per header)
```

Use `excludingWindows: []` (not `includingWindows:`) so the desktop background and Dock are included — the `including` variant excludes both. If you want to hide Vantage's own window from the stream, use `SCContentFilter(display:excludingApplications:exceptingWindows:)` with your own `SCRunningApplication`.

**Virtual displays.** Anything that registers a `CGDirectDisplayID` — BetterDisplay's `CGVirtualDisplay`, DisplayLink, Sidecar — shows up in `SCShareableContent.displays` like a physical display. 🌐 **But there is a confirmed, unfixed bug:** after any virtual-display configuration change (connect/disconnect/reconfigure), a newly created `SCStream` can bind to the *wrong* framebuffer and stream the last-connected virtual screen's content despite a correctly-configured `SCContentFilter`. Reported against Sidecar, DisplayLink and `CGVirtualDisplay`; Apple's own Screen Sharing reportedly exhibits it too. Filed as FB17797423; Apple DTS's only response was "file a bug." The only known recovery is disconnecting and reconnecting all virtual displays.

**Implication for Vantage:** if you plan a "headless virtual display sized to the iPad" feature (a very natural thing for this app), budget real time for this. Mitigations to test: recreate the `SCStream` (not just `updateContentFilter`) on every `CGDisplayRegisterReconfigurationCallback` event, and validate the stream by comparing `SCStreamFrameInfoContentRect`/`ScreenRect` against the expected display frame. ⚠️ Unverified whether recreation is sufficient.

### 1.3 Idle frames, dirty rects, and when frames stop arriving

`SCFrameStatus` (from the header):

| Case | Header text |
|---|---|
| `.complete` | "new frame was generated" |
| `.idle` | "new frame was **not** generated because the display did not change" |
| `.blank` | "new frame was not generated because the display has gone blank" |
| `.suspended` | "new frame was not generated because updates have been suspended" |
| `.started` | "new frame that is indicated as the first frame sent after the stream has started" |
| `.stopped` | "the stream was stopped" |

**Does SCStream go silent when nothing changes?** No — it keeps calling back, but with `.idle`. 📄 Apple's docs for `SCFrameStatus.idle`: "A status that indicates the system didn't generate a new frame because the display didn't change." An Apple engineer confirmed the same wording on the forums. 🌐 Multiple third-party reports state that `.idle` callbacks may arrive **without a new `IOSurface`** attached, so `CMSampleBufferGetImageBuffer` can be `nil` — always nil-check before encoding.

⚠️ **Do not use "no callbacks for N ms" as a liveness/stall detector.** A completely static desktop and a wedged stream look identical from frame-arrival timing alone. This exact mistake has bitten multiple real projects. Use `SCStreamDelegate.stream(_:didStopWithError:)`, `SCStream.isCapturing` (new in macOS 27), and display sleep/wake notifications instead.

**Reading the attachments:**

```swift
guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
        as? [[SCStreamFrameInfo: Any]],
      let a = attachmentsArray.first,
      let rawStatus = a[.status] as? Int,
      let status = SCFrameStatus(rawValue: rawStatus)
else { return }

let displayTime  = a[.displayTime]  as? UInt64            // mach_absolute_time of WindowServer display
let contentRect  = a[.contentRect]  as? [String: Any]     // CGRect dictionary representation, POINTS
let contentScale = a[.contentScale] as? Double            // original content size → surface size
let scaleFactor  = a[.scaleFactor]  as? Double            // points → backing pixels, range [1, 4]
// ⚠️ dirtyRects element type is ambiguous — see note below
let dirty = a[.dirtyRects]                                // PIXELS
let screenRect   = a[.screenRect]   as? [String: Any]     // macOS 13.1+
let boundingRect = a[.boundingRect] as? [String: Any]     // macOS 14.0+
```

Availability of the `SCStreamFrameInfo` keys (verified): `.status`, `.displayTime`, `.scaleFactor`, `.contentScale`, `.contentRect` — macOS 12.3; `.dirtyRects` — macOS 12.3, **macOS-only**; `.screenRect` — macOS 13.1; `.boundingRect` — macOS 14.0, macOS-only; `.presenterOverlayContentRect` — macOS 14.2, macOS-only; `.videoOrientation` — **macOS 27.0 / iOS 27.0** (new).

📄 `dirtyRects` semantics (header, verbatim): "an array of rectangles that is the union of both rectangles that were **redrawn** and rectangles that were **moved**. This is an array of `CGRect` in `NSValue`. The `CGRect` elements are specified **in pixels**."

⚠️ **Element type is ambiguous and must be probed at runtime.** The header says `NSValue`-boxed `CGRect`; the other rect-valued attachments (`contentRect`, `screenRect`, `boundingRect`) are `CFDictionary` rect representations decoded with `CGRect(dictionaryRepresentation:)`. Write the accessor defensively:

```swift
func rects(_ any: Any?) -> [CGRect] {
    guard let arr = any as? [Any] else { return [] }
    return arr.compactMap { e in
        if let v = e as? NSValue { return v.rectValue }
        if let d = e as? NSDictionary { return CGRect(dictionaryRepresentation: d as CFDictionary) }
        return nil
    }
}
```
Log which branch fires the first time and then simplify.

Note also that the other rect attachments are in **points**, while `dirtyRects` is in **pixels** — do not mix them without applying `scaleFactor`.

**How to actually use dirty rects in this pipeline.** You cannot do partial-frame encoding — `VTCompressionSessionEncodeFrame` takes a whole picture, and the hardware encoder decides its own intra/inter partitioning. What dirty rects *are* good for:

1. **Skip encoding entirely** when `status == .complete` but `dirtyRects` is empty or negligible. Saves power and bandwidth on an idle desktop.
2. **Complexity/motion estimate** → drive the text-vs-motion mode switch and the bitrate target. `Σ area(dirtyRects) / frameArea` per second is a good scalar.
3. **Keyframe timing** → if the whole screen just changed (e.g. Space switch, full-screen app), that frame is going to be mostly intra anyway; it's a cheap moment to insert an IDR and reset drift.

**Forcing periodic frames.** Because idle produces no new surface, you need a keepalive so the client's decoder and your RTT measurement don't go stale:

- Preferred: a **host-side heartbeat packet** (not a video frame) carrying timestamps + stats. Costs nothing.
- If you need a real frame (e.g. after client-reported loss), re-encode the **last `.complete` pixel buffer** you retained, with `kVTEncodeFrameOptionKey_ForceKeyFrame`. Retaining exactly one last-good `CVPixelBuffer` outside the SCK pool costs one surface; copy it into your own `CVPixelBufferPool` rather than pinning a ScreenCaptureKit surface indefinitely.

### 1.4 Display sleep, lock screen, screensaver, login window

| State | Behaviour | Confidence |
|---|---|---|
| **Display sleep** | Frame delivery **stops**, and in naive implementations does **not** resume on wake — the stream stalls rather than erroring. 🌐 Two independent corroborations: Sunshine issue #5509 (macOS 26.6.1 / M1 Max, *AVFoundation* capture path) — "the capture session stops delivering sample buffers entirely… the client connection remains active but never receives another video frame. Waking the display does not resume streaming"; and OBS issue #8928 (macOS 13, *ScreenCaptureKit* path) — capture "freezes" after wake, fixed only by restarting the source. ⚠️ I did **not** find an authoritative Apple statement or a macOS 26-specific SCK test; assume you must rebuild the stream on wake and verify on device. | 🌐 medium-high |
| **Screen locked / screensaver** | 🌐 Capture returns **black frames** (this is what `SCFrameStatus.blank` is for). You cannot see through the lock screen. | 🌐 medium |
| **Login window (pre-login)** | **Supported from macOS 14.4 onward**, and only from an agent. 📄 Apple DTS (Quinn), forum thread 814152, verbatim: *"Daemons should not be messing around with GUI stuff, and that includes ScreenCaptureKit. The standard architecture for a screen sharing product is to have both a daemon and an agent"* … *"If you want your product to support the pre-login context, set your agent's `LimitLoadToSession` property to an array value containing both `Aqua` and `LoginWindow`."* … *"**IMPORTANT** In macOS 14.4 we fixed a bug that prevents you from using ScreenCaptureKit in the pre-login context (r. 121253782)."* | 📄 high |
| **Fast user switching / other session** | Your agent only sees its own session. | 📄 high |
| **HDCP / DRM-protected windows** | Rendered black in the capture. Expected and unfixable. | 🌐 high |

**Required host architecture** if Vantage should work when the Mac is unattended:

- `LaunchDaemon` (system domain): networking / Tailscale / connection brokering.
- `LaunchAgent` per GUI session with `LimitLoadToSessionType = ["Aqua", "LoginWindow"]`: owns `SCStream` and event injection. Talks to the daemon over XPC.

**Keeping the display awake.** For a remote-desktop host, hold an `IOPMAssertion` while a client is connected:
- `kIOPMAssertionTypePreventUserIdleDisplaySleep` — keeps the panel on (and thus the framebuffer live). This is what you want.
- `kIOPMAssertionTypeNoDisplaySleepAssertion` — legacy alias.
- `kIOPMAssertionTypePreventUserIdleSystemSleep` — system stays awake but the display may still sleep; **not sufficient on its own**.
Use `IOPMAssertionCreateWithName` / `IOPMAssertionRelease`. ⚠️ On Apple Silicon with the lid closed and no external display there is no framebuffer to capture regardless of assertions — verify on device.

**Regardless**, implement recovery: subscribe to `NSWorkspace.didWakeNotification` / `screensDidWakeNotification`, and `CGDisplayRegisterReconfigurationCallback`, and fully rebuild the `SCStream` on those events.

### 1.5 Cursor — this is now a constrained area

**Recommendation: `showsCursor = true`, composite host-side.** Reasons, in order of force:

1. ✅ **`NSCursor.currentSystemCursor` is deprecated in the macOS 27 SDK.** Verbatim from `NSCursor.h`:
   ```
   /// This property will always be `nil` in a future version of macOS.
   @property (class, readonly, nullable, strong) NSCursor *currentSystemCursor
     API_DEPRECATED("No longer recommended. Use ScreenCaptureKit to capture the screen. Use the
     `showsCursor` property on `SCStreamConfiguration` to control whether or not to include the
     cursor in the capture. Or, use `NSCursor.currentCursor` if needing to just get the current
     cursor for this application.", macos(10.6, API_TO_BE_DEPRECATED));
   ```
   (Swift spells this `NSCursor.currentSystem`.) Apple's *stated replacement for exactly this use case* is `showsCursor`.
2. `NSCursor.currentCursor` only ever returns **your own app's** cursor — useless for a remote desktop.
3. 🌐 On macOS 26, capturing the cursor window separately via `SCScreenshotManager` now fails with "Failed to start stream due to audio/video capture failure"; developers report this as an intentional lockdown (forum thread 819931, no Apple response).
4. 🌐 Off-main-thread `NSCursor` access is reported to trap on macOS 26 — if you do use it, marshal to the main thread.
5. There is **no new macOS 26/27 cursor API.** I grepped the whole of `NSCursor.h` for `macos(26` / `macos(27` — zero hits. `SCStreamFrameInfo` gained only `.videoOrientation` in 27.

**Private/SPI alternatives (documented here only so you can rule them in/out deliberately):** `CGSCurrentCursorSeed()`, `CGSGetCurrentCursorLocation()`, `CGSCopyCurrentCursorImage()` in the CoreGraphics SkyLight SPI. ⚠️ Undocumented, unstable across releases, and will be a problem for notarisation-adjacent scrutiny and any future Mac App Store path. **Not recommended.**

**Practical cursor design for Vantage:**
- Stream the cursor burned in (`showsCursor = true`).
- On the iPad, when the user moves a finger/trackpad, draw a **local predicted pointer** immediately at the touch location and fade it into the real one when the host frame catches up. This is how you get sub-frame-feeling pointer response without a cursor API.
- Send cursor *position* out-of-band cheaply from the host with `CGEventGetLocation(CGEventCreate(nil))` — that is public and works from a background agent — so the client can reconcile its predicted pointer.
- ⚠️ Cursor shape (I-beam vs arrow vs resize) will therefore only be conveyed pictorially at video latency. Accept it for v1.

### 1.6 Screen Recording TCC

**Checking and requesting:**

```swift
CGPreflightScreenCaptureAccess()   // Bool, macOS 10.15+, does NOT prompt
CGRequestScreenCaptureAccess()     // Bool, macOS 10.15+, prompts once
```
Header note (verbatim): *"A previously denied process is not re-prompted; the user must enable access in System Settings > Privacy & Security > Screen Recording. To check the current authorization without prompting, use `CGPreflightScreenCaptureAccess`."*

**Detecting denial through ScreenCaptureKit:** `SCShareableContent.getShareableContentWithCompletionHandler:` fails with `SCStreamError.Code.userDeclined` (**−3801**, domain `SCStreamErrorDomain`) when TCC has not granted access. `SCStream.startCapture` can also return `.userDeclined`/`.missingEntitlements` (−3803). Full code list (verified from `SCError.h`):

```
-3801 userDeclined                      -3813 noWindowList
-3802 failedToStart                     -3814 noDisplayList
-3803 missingEntitlements               -3815 noCaptureSource
-3804 failedApplicationConnectionInvalid-3816 removingStream
-3805 failedApplicationConnectionInterrupted
-3806 failedNoMatchingApplicationContext-3817 userStopped
-3807 attemptToStartStreamState         -3818 failedToStartAudioCapture   (13.0)
-3808 attemptToStopStreamState          -3819 failedToStopAudioCapture    (13.0)
-3809 attemptToUpdateFilterState        -3820 failedToStartMicrophoneCapture (15.0)
-3810 attemptToConfigState              -3821 systemStoppedStream         (15.0)
-3811 internalError                     -3822 insufficientStorage         (27.0, NEW)
-3812 invalidParameter                  -3823 notSupported                (27.0, NEW)
```

Practical detection pattern: call `SCShareableContent.current` at launch; if it throws `.userDeclined`, you are not authorised. Note that `SCShareableContent.getCurrentProcessShareableContentWithCompletionHandler:` (Swift: `SCShareableContent.currentProcess`, macOS 14.4+) returns *redacted* content **without** TCC consent — useful for a "can I see anything at all?" probe that never prompts.

**Persistence across rebuilds.** 🌐 TCC keys the grant on the app's **designated requirement**; ad-hoc-signed builds have no stable DR, so TCC identifies them by **cdhash** and every rebuild is a new app with no grant. Apple DTS's phrasing: *"macOS tracks code identity using the code's designated requirement. Ad hoc signed code does not include a stable DR, and thus macOS is unable to tell that version N+1 of your app is the 'same code' as version N."*
→ **Sign Vantage with an Apple Development certificate during development and Developer ID for distribution, from the first commit.** This single change removes a daily papercut.

**The monthly re-authorisation prompt.**
- Introduced in macOS 15.0 as **weekly**; 🌐 reduced to **monthly (30 days)** before release after developer complaints, with 15.1 relabelling the button "Continue To Allow".
- 🌐 Still present in macOS 26 with no user-facing setting to disable it.
- It is a property of the **Screen Recording TCC service** (`kTCCServiceScreenCapture`), not of a particular API. It fires for ScreenCaptureKit as well as the deprecated `CGDisplayStream` / `CGWindowListCreateImage` paths. Apple's framing was that the deprecated capture technologies were the problem, but the re-auth applies to the *grant*.
- **`presenterOverlayPrivacyAlertSetting` does not affect it.** Different alert.
- **Mitigation A — `SCContentSharingPicker`.** 📄/🌐 Apple's stated direction is that migrating to ScreenCaptureKit **plus** `SCContentSharingPicker` avoids the recurring alert, because the user re-grants through a trusted system picker each session instead of through a TCC dialog. For Vantage this is a real UX cost (the host user must pick the display), but it is the only non-managed path. Consider offering it as a mode.
- **Mitigation B — `com.apple.developer.persistent-content-capture`.** ✅ Apple docs, verbatim: *"A Boolean value that indicates whether a Virtual Network Computing (VNC) app needs persistent access to screen capture."* Platform: **macOS 14.4+**. Discussion: *"The Persistent Content Capture entitlement enables VNC apps to view and record the screen. Before your app can use this entitlement, request permission to use it by submitting the [request] form. After receiving permission from Apple to use this entitlement, add it to your app's profile in Xcode."* Request form: `https://developer.apple.com/contact/request/persistent-content-capture/`. **Vantage is literally the described use case — apply early, approval is manual and slow.** ⚠️ Apple has never publicly confirmed in writing that it suppresses the 30-day re-auth; that is the widely-reported developer understanding, not a documented guarantee.
- **Mitigation C — MDM.** 🌐 A PPPC configuration profile scoped to the `ScreenCapture` service and your bundle ID, delivered by an MDM, suppresses the re-auth. Cannot be applied locally. Irrelevant for a personal app unless you enrol your own Mac.

**Info.plist.** ⚠️ **`NSScreenCaptureUsageDescription` is not a documented Apple key** — I checked `developer.apple.com/documentation/bundleresources/information-property-list/nsscreencaptureusagedescription` and it 404s, and it does not appear in Apple's Information Property List reference. Many third-party posts (and at least one macOS 26 bug report) insist it is required. Adding it is harmless and costs nothing, so **add it**, but do not rely on it as the fix if TCC misbehaves. What *is* corroborated for macOS 26: 🌐 the app must be a **proper `.app` bundle** — bare signed executables no longer appear in System Settings → Privacy & Security → Screen & System Audio Recording at all.

### 1.7 What's actually new in macOS 26 / 27 (and whether you care)

Grepped the entire ScreenCaptureKit header set for `macos(26` / `macos(27`. Complete list:

| Symbol | Version | Relevant to Vantage? |
|---|---|---|
| `SCStreamConfigurationPreset.captureHDRRecordingPreservedSDRHDR10` | macOS 26.0 | No (recording) |
| `SCScreenshotManager` rework — `SCScreenshotConfiguration`, `SCScreenshotOutput`, `captureScreenshot(contentFilter:configuration:)`, `captureScreenshot(rect:configuration:)` | macOS 26.0 | Marginal — useful for a connection-preview thumbnail |
| `SCContentFilter.isMicrophoneEnabled` | macOS 27.0 | No |
| `SCStreamFrameInfo.videoOrientation` | macOS 27.0 | No (macOS displays don't rotate mid-stream) |
| **`SCStream.isCapturing`** | macOS 27.0 | **Yes** — a real state property instead of tracking it yourself; good for the liveness problem in §1.3. But it's 27-only and your floor is 26. |
| `SCClipBufferingOutput` + `addClipBufferingOutput(_:)` / `removeClipBufferingOutput(_:)` (rolling ~15 s replay buffer) | macOS 27.0 | No |
| `SCRecordingEditor` (system recording preview/trim UI) | macOS 27.0 | No |
| `SCRecordingOutputConfiguration.mixesAudioWithMicrophone` | macOS 27.0 | No |
| `SCStreamError.insufficientStorage` (−3822), `.notSupported` (−3823) | macOS 27.0 | Handle in your error switch |

**Headline: there are no new capture-path or latency-related `SCStreamConfiguration` keys in macOS 26 or 27.** Everything new is recording, clips, editing, or the iOS 27 port. Design against the macOS 14/15 surface and you lose nothing.

**`SCRecordingOutput`** (macOS 15+): writes the stream to a file. Irrelevant for live streaming, and note the header warns that updating the stream configuration during recording stops the recording. Do not add one.

**`SCContentSharingPicker`** (macOS 14+): relevant only as the TCC-nag mitigation discussed above. On macOS it is optional; on iOS 27 it is the *only* way to get a filter.

**HDR.** `captureDynamicRange = .hdrLocalDisplay` / `.hdrCanonicalDisplay` (macOS 15+, Apple Silicon only) switches the output to a 10-bit format + wide colour space. For v1: **stay SDR.** HDR means `'x420'` 10-bit, HEVC Main10, HDR metadata signalling to the iPad, and EDR-aware presentation on the client. It also roughly doubles the per-pixel data before compression. Revisit only after SDR is solid. `SCStreamConfiguration.streamConfiguration(with: .captureHDRStreamLocalDisplay)` gives you a pre-configured starting point if you do.

### 1.8 Reconfiguring a live stream

```swift
try await stream.updateConfiguration(newConfig)    // macOS 12.3+, macOS-only
try await stream.updateContentFilter(newFilter)    // macOS 12.3+, macOS-only
```
📄 Apple: *"After the stream starts, further changes to its configuration and content filter don't require restarting it."* This is your adaptive-fps mechanism — build a fresh `SCStreamConfiguration`, change only `minimumFrameInterval`, and push it.

Caveats:
- Errors surface as `.attemptToConfigState` (−3810) / `.attemptToUpdateFilterState` (−3809) if the stream is in the wrong state.
- ⚠️ Changing `pixelFormat`, `width`, or `height` mid-stream is *permitted by the API* but forces you to tear down and rebuild the `VTCompressionSession` and re-handshake the format description with the client. Treat geometry as immutable for the life of a connection (§4.4).
- Header warns that updating the configuration while an `SCRecordingOutput` is attached **stops the recording**. Irrelevant if you never attach one.
- ⚠️ Unverified: whether a config update introduces a one-frame hitch or a brief `.idle` gap. Measure before wiring it to a fast control loop; rate-limit updates to ≥1 s regardless.

---

## 4. Frame pacing & adaptive quality

This section is engineering-pattern synthesis rather than Apple API documentation; sources are named inline and in §Sources. Where a number is someone else's measurement I say whose.

### 4.1 The pipeline invariant: only the newest frame matters

A remote desktop is not a video player. There is no value in ever displaying a frame that has been superseded. Encode that as a hard invariant at three places:

**Host capture → encoder (bound in-flight to 1, maybe 2).**

```
on didOutputSampleBuffer(.screen):
    if status != .complete        -> return
    if imageBuffer == nil         -> return
    if dirtyArea ≈ 0              -> return            (idle suppression)
    if encodesInFlight >= maxInFlight:
        pendingFrame = frame                            (replace, do not queue)
        return
    encodesInFlight += 1
    encode(frame)
```
`maxInFlight = 1` gives the lowest latency and the cleanest "drop the old one" semantics; `2` lets the media engine pipeline and typically raises throughput at ~1 frame of added latency. Make it a runtime constant you can flip while measuring. Never build an unbounded queue — an unbounded queue converts a transient CPU spike into permanent added latency that never drains.

**Host encoder → network.** The encoder output callback should hand the NAL units straight to the transport. If the transport's send buffer is backed up beyond ~1 frame time, that is your signal to *lower the bitrate*, not to buffer. Over Tailscale/WireGuard on a LAN this is rare; over DERP relay it is not.

**Client network → decoder → display.** Same rule. If two frames arrive before you have displayed one, drop the older **unless it is a reference frame the newer one depends on** — which, with `AllowFrameReordering = false` and no B-frames, means "unless it's the only path to decoding the newer one". In an IPPP stream every P-frame references its predecessor, so you generally cannot skip decode; you *can* skip **presentation**. Decode both, present only the last. Decoding is cheap on an M4; presenting late is what costs you.

**Explicitly reject a jitter buffer.** 🌐 Multi's WebRTC screenshare write-up reports that setting `max_playout_delay` to zero — i.e. eliminating jitter-buffer smoothing — was worth **~90 ms at p50**, their largest single win after moving to P2P. For a LAN/Tailscale remote desktop the same logic applies: render on arrival. Accept visible jitter in exchange for responsiveness; users tolerate uneven pacing in a desktop far more than they tolerate lag.

### 4.2 Latency budget to design against

For 2420×1668 @ 60 fps on M-series → M4 iPad over Tailscale on a good LAN. These are **design targets, not measurements** — measure each on device and fill in the table in §5.

| Stage | Target | Notes |
|---|---|---|
| WindowServer → SCK callback | 2–8 ms | Partly a function of `queueDepth` and your release discipline |
| Idle/dirty-rect triage | <0.5 ms | Pure attachment reads |
| VT encode (submit → output callback) | 4–12 ms | Hardware, low-latency mode; see §2 |
| Packetise + transport | 1–5 ms LAN | Tailscale adds WireGuard crypto; direct path, not DERP |
| Client receive → decode complete | 3–10 ms | Hardware decode on M4 |
| Decode → on glass | 8–16 ms | One to two ProMotion vsyncs |
| **Glass-to-glass** | **25–55 ms** | Below ~50 ms feels "direct"; above ~80 ms feels remote |

Two structural points:

- **Encode + decode dominate**, exactly as the Hopp WebRTC latency study found ("encoding/decoding … the most computationally intensive step"). Everything you do to the network matters less than the encoder settings in §2.
- **At 60 fps you have 16.6 ms of budget per stage before you're adding a whole frame.** Anything that costs more than a frame interval should be provably worth a frame.

### 4.3 Client → host feedback channel

Send a small feedback packet at ~4 Hz (not per frame — per-frame feedback is noise and costs uplink):

```
struct ClientFeedback {
    var seq: UInt32                 // last frame sequence received
    var recvHostTime: UInt64        // host clock estimate when the frame was received
    var decodeMicros: UInt32        // mean decode time over the window
    var presentLagMicros: UInt32    // decode-complete → on-glass
    var framesDropped: UInt16       // presented-drops in the window
    var framesLost: UInt16          // never arrived / undecodable
    var pendingDisplayCount: UInt8  // renderer queue depth right now
    var rttMicros: UInt32           // from a ping/pong on the same channel
    var decodeErrors: UInt16        // VT errors / layer.status == .failed count
}
```

Derive on the host:

- **RTT + jitter** → transport health. Use a clock filter (host mach time ↔ client `CMClockGetHostTimeClock`) rather than raw deltas. `SCStream.synchronizationClock: CMClockRef?` (macOS 13+, verified in header) is the right host-side reference clock to timestamp against.
- **`pendingDisplayCount > 1` sustained** → the client cannot keep up. Lower fps before lowering bitrate (a 30 fps crisp desktop beats a 60 fps mushy one).
- **`framesLost > 0`** → (a) request an IDR via `kVTEncodeFrameOptionKey_ForceKeyFrame` immediately, (b) step bitrate down.
- **`decodeErrors > 0` or client reports `requiresFlushToResumeDecoding`** → client flushes, then host sends parameter sets + IDR. Never assume the client still has your SPS/PPS; re-send them with every IDR (cheap, tens of bytes).

**Control loop shape.** Use AIMD, not a PID:
- No loss, RTT stable, `pendingDisplayCount ≤ 1` for 2 s → **increase** target bitrate by ~10% (additive-ish), capped.
- Any loss event or RTT spike >1.5× baseline → **multiplicative decrease** to ~70% immediately, then hold for 2 s before probing up.
- Never oscillate faster than ~2 s; visible quality pumping is worse than a slightly conservative steady state.

`AverageBitRate` is settable mid-session (see §2) so this costs you nothing structurally.

### 4.4 Text mode vs motion mode

This is the biggest perceptual lever in a desktop-streaming app, and it is the thing generic video encoders get wrong.

Classify each frame from `Σ area(dirtyRects) / frameArea`, smoothed over ~500 ms:

| Signal | Mode | Encoder policy |
|---|---|---|
| < ~2% changed, low rate of change (reading, typing, code) | **Text** | Cap fps at 30 via `minimumFrameInterval`; tighten `MaxAllowedFrameQP` (lower ceiling → sharper text); spend the saved frame budget on per-frame quality; do not chase 60 |
| 2–25% changed (scrolling, window drag, terminal spew) | **Mixed** | 60 fps, moderate QP ceiling |
| > ~25% changed sustained (video, animation, games) | **Motion** | 60 fps, relax QP ceiling, let the rate controller smooth |

🌐 This mirrors what Multi concluded for WebRTC screenshare: they cap at **30 fps** with `degradationPreference = maintainResolution` ("prioritise text clarity over smooth motion; at 30 FPS maximum capture latency is 33 ms") and found that **tightening the QP range (from 8–52 down to 4–36) "turned out to be the most significant factor in the legibility"** of screen content. On Apple hardware the equivalent knobs are `kVTCompressionPropertyKey_MaxAllowedFrameQP` / `_MinAllowedFrameQP` (§2).

**Never scale resolution to save bits on text.** Downscaling 2420×1668 → 1210×834 destroys glyph legibility far faster than raising QP does. Hold native resolution; trade frame rate and QP. (`degradationPreference = maintainResolution` is precisely this principle expressed in WebRTC's vocabulary.)

**Corollary for the capture config:** `width`/`height` should be set once to the host display's native pixels and then left alone. Changing them means recreating the `VTCompressionSession` (§2) and re-handshaking the format description with the client — a visible hitch. Adapt with fps and bitrate, not geometry.

### 4.5 Recovery and keyframes

- **Never** set a short `MaxKeyFrameInterval`. A periodic IDR at 2.4K is a multi-hundred-kilobyte spike that causes a visible pulse and a latency bubble every interval. Set the interval effectively to infinity and drive IDRs by event.
- **IDR triggers:** stream start; client-reported loss or decode error; client-reported flush; resolution/format change; a dirty-rect event covering ~the whole screen (free, since the frame is intra-heavy anyway).
- **Long-term reference (LTR) frames** are the better tool if you can afford the complexity: the encoder keeps an acknowledged reference frame and, on loss, codes the next frame against the last *acked* LTR instead of sending a full IDR. VideoToolbox exposes this in the low-latency encoder (WWDC21-10158) — see §2 for the exact keys. This is how you get loss recovery without the IDR bandwidth spike, and it is a natural fit for a client feedback channel you already have. Treat it as a v2 optimisation.

### 4.6 Power

A 60 fps 2.4K capture+encode is not free on a laptop. Explicit policy:
- `kVTCompressionPropertyKey_MaximizePowerEfficiency = false` while a client is connected (you are buying latency with watts, deliberately).
- Idle suppression (§1.3) is the real power win — a static desktop should encode ~nothing.
- Drop to 30 fps and raise the QP ceiling automatically when the host is on battery below some threshold; surface it in the UI rather than doing it silently.
