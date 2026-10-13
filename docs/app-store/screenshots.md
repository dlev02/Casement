# Screenshot plan

## Sizes (App Store Connect screenshot specifications, read 2026-10-11)

1 to 10 screenshots per size, `.png` or `.jpg`, no alpha. Every screenshot must show the real app
in use (2.3.3): no title-only art, no splash or login screens, nothing from another platform's
app. Captions or a frame are allowed if the app is still the subject.

| Platform | Upload | Pixels | Capture on | Notes |
| --- | --- | --- | --- | --- |
| iPhone | **6.9" (Dynamic Island, large)** | 1320 × 2868 portrait / 2868 × 1320 landscape (1290 × 2796 and 1260 × 2736 are also accepted) | iPhone 17 Pro Max or 18 Pro Max simulator. The local "Vesper Screens iPhone 17 Pro Max" sim captures exactly 1320 × 2868 (measured). | Apple's page names the **6.3" (Dynamic Island, medium)** size as the required iPhone set, at 1206 × 2622 or 1179 × 2556. It falls back to scaled large-display shots, so a 6.9" set alone should satisfy it. If App Store Connect still asks, recapture the same shots on the iPhone 18 Pro simulator. |
| iPad | **13"** | 2752 × 2064 landscape (or 2064 × 2752 portrait; 2732 × 2048 also accepted) | iPad Pro 13-inch (M4/M5) simulator; measured 2064 × 2752 portrait | Required because the app runs on iPad. Use landscape: a remote desktop is landscape. |
| Mac | **16:10** | 2880 × 1800 (or 2560 × 1600, 1440 × 900, 1280 × 800) | A Debug Mac build on this Mac, window captured and placed on a 2880 × 1800 canvas | Required for the Mac version. |
| Apple Vision Pro | **3840 × 2160** | 3840 × 2160 only | "Vantage Vision Pro" simulator (visionOS 27) | Required for the visionOS version. Check the simulator's capture size (`xcrun simctl io <sim> screenshot`). If it isn't 3840 × 2160, place the capture on a 3840 × 2160 canvas without stretching it. |

App previews (video) are optional. If you make one from the review demo video, it has to be 15
to 30 seconds at the device's preview resolution, with landscape for Mac and visionOS.

## Staging: the shared setup

Everything below uses Debug builds (the flags don't exist in Release) and made-up desktops, never
a real one (CLAUDE.md, "Headless end-to-end testing").

```sh
# 1. Render the made-up desktops at the target's size (examples).
"Google Chrome" --headless=new --force-device-scale-factor=2 --window-size=1376,1032 \
  --screenshot=/tmp/mac-ipad.png "file://$PWD/docs/images/source/mac-desktop.html"      # 2752x2064, iPad 13"
"Google Chrome" --headless=new --force-device-scale-factor=2 --window-size=1434,660 \
  --screenshot=/tmp/mac-iphone.png "file://$PWD/docs/images/source/mac-desktop.html"    # 2868x1320, iPhone landscape
"Google Chrome" --headless=new --force-device-scale-factor=2 --window-size=1376,1032 \
  --screenshot=/tmp/pc-ipad.png "file://$PWD/docs/images/source/pc-desktop.html"

# 2. A synthetic host streaming that picture (Debug VantageHost; never port 47820).
open -n ".deriveddata/Build/Products/Debug/Casement Host.app" --args --synthetic-capture \
  --synthetic-image /tmp/mac-ipad.png --port 47821 --pairing-code 246810 --exit-after 1800
#    A PC: add --platform windows and use pc-ipad.png. Mac audio: the synthetic host streams a chime.

# 3. Launch the client against it.
xcrun simctl launch <sim> me.drewlevinson.casement \
  -VantageAutoConnect 127.0.0.1:47821 -VantagePairingCode 246810
```

Other flags: `-VantageSeedSamples 1` (My Mac, Office Mac, MacBook Air, Drew's PC),
`-vantage.availabilityChecks NO` (otherwise the seeded `*.example.ts.net` hosts show as offline),
`-VantageOpenScreen settings|controls|security|help|about|tailscale|tailscaleOAuth|tailscaleToken|addDevice|controlStrip|controlStripMac|controlStripPC|editPC|transfers|widgets`,
`-VantageTailscaleFixture 1 -VantageOpenTailscaleDevices 1`,
`-VantageDictationFixture listening|review|macTranscribing|macReview|failed|download`,
`-VantageDropHint 1`, `-VantageMacAudio 1`, and `-VantageSendTestFile <bytes> -VantageSlowFiles <ms>`
to keep a transfer moving on screen. Use the appearance and text size the shot calls for:
`TEST_RUNNER_…` variables exist for UI tests; for manual shots, use `xcrun simctl ui <sim>
appearance dark|light`. On the Mac, add `-VantageAllowSelfControl 1`, or a session against a
loopback host shows "You're viewing this Mac from itself" (`RemoteSessionScreen.swift:145, 946`).
Also add `-ApplePersistenceIgnoreState YES -VantageReadOnlyDevices 1` so Drew's real saved list
is never overwritten.

Before capturing: set the status bar with `xcrun simctl status_bar <sim> override --time 9:41
--batteryState charged --batteryLevel 100 --cellularBars 4`, close the debug pairing prompt, and
check that no fixture shows a real name, address, or email (the Tailscale fixture uses
`example.ts.net` addresses and `drew@example.com`). That's acceptable, but "Drew-PC" can be
swapped for something neutral.

## iPad 13" (6 shots, landscape)

| # | Caption | Screen | Staging |
| --- | --- | --- | --- |
| 1 | **Your Mac, right on your iPad.** | Session on the made-up Mac desktop, full control strip open in a corner | Synthetic host with `mac-ipad.png`, `-VantageAutoConnect …`. Open the strip. |
| 2 | **Your Windows PC, too.** | Session on the PC desktop: Start, Task View, and Task Manager in the strip, ctrl/alt/win keycaps | Host with `--platform windows` and `pc-ipad.png` |
| 3 | **Files go both ways, and keep going.** | Session with the transfer capsule ("Sending 3 of 12", percent, time left) | `-VantageSendTestFile 400000000 -VantageSlowFiles 1500`, captured mid-run. Or the Transfers sheet: `-VantageOpenScreen transfers`. |
| 4 | **Speak, and Casement types.** | Dictation panel over the session, showing a transcript (review state) | `-VantageDictationFixture macReview` (labels the Mac's engine) |
| 5 | **All your computers in one place.** | Device list with Macs and a PC, availability dots, and a transfer badge on one row | `-VantageSeedSamples 1 -vantage.availabilityChecks NO` (or real synthetic hosts on two ports, which give live "Available" dots) |
| 6 | **Make the controls yours.** | Control strip editor with the live scaled preview | `-VantageOpenScreen controlStripMac` with `-VantageSeedSamples 1` |

## iPhone 6.9" (5 shots)

| # | Caption | Orientation | Screen | Staging |
| --- | --- | --- | --- | --- |
| 1 | **Your computer, in your pocket.** | Landscape (2868 × 1320) | Session with the collapsed strip pill | Host with `mac-iphone.png` |
| 2 | **All your computers in one place.** | Portrait | Device list | `-VantageSeedSamples 1 -vantage.availabilityChecks NO` |
| 3 | **Finds them on your tailnet.** | Portrait | Add from Tailscale picker: Macs and a PC, a Linux box and an iPad greyed out | `-VantageTailscaleFixture 1 -VantageOpenTailscaleDevices 1` |
| 4 | **Speak, and it types.** | Landscape | Dictation panel over the session | `-VantageDictationFixture review` |
| 5 | **Files, both ways.** | Portrait | Transfers sheet with a multi-file summary | `-VantageOpenScreen transfers` |

Mixing orientations in one set is allowed, but the product page shows every shot at its own
shape. If the mix looks uneven, make all of them portrait and drop shot 1's landscape session in
favor of the portrait device list.

## Mac 2880 × 1800 (5 shots)

Capture the window only (Shift-Cmd-4, Space, then click; or `screencapture -l <windowid>`), then
place it on a 2880 × 1800 neutral or desktop-colored canvas. The README's `mac-client.png` and
`mac-pc-session.png` show the look but are only 1400 and 1600 px wide, so retake them.

| # | Caption | Screen | Staging |
| --- | --- | --- | --- |
| 1 | **Every computer gets its own window.** | Session window on the made-up Mac, the Mac's name as title, its size as subtitle, toolbar visible | Mac Debug build, `-vantage.savedDevices '<hex>'` pointing at `127.0.0.1:47821`, `-VantageAllowSelfControl 1` |
| 2 | **Control a Windows PC from your Mac.** | Session on the PC with the strip showing Start and Task Manager | Host with `--platform windows` |
| 3 | **Your computers, at a glance.** | Main window: sidebar of Macs and a PC, detail pane with Connect | `-vantage.savedDevices`, `-vantage.availabilityChecks NO` |
| 4 | **Move files without opening the screen.** | Transfers sheet with a run of files | `-VantageOpenScreen transfers` |
| 5 | **Your shortcuts go through.** | Settings › Controls (Send Keyboard Shortcuts, Swap ⌘ and ⌃, Dictation) | `-vantage.mac.settingsTab controls`, then ⌘, |

## Apple Vision Pro 3840 × 2160 (4 shots)

The simulator can't take input from AXe or XCUITest (CLAUDE.md, visionOS), so launch with flags
that open what you need, and place windows with the simulator's own controls.

| # | Caption | Screen | Staging |
| --- | --- | --- | --- |
| 1 | **Your Mac, as big as you like.** | A session window keeping the Mac's shape, with the control strip ornament below | "Vantage Vision Pro" sim, `-VantageAutoConnect 127.0.0.1:47821 -VantagePairingCode 246810` |
| 2 | **Several computers side by side.** | Two session windows (a Mac and a PC) plus the device list | Two synthetic hosts (47821 Mac, 47822 `--platform windows`); open the second from the list |
| 3 | **Look and pinch to click.** | Session with the strip ornament, close up | Same as 1 |
| 4 | **All your computers in one place.** | Device-list window | `-VantageSeedSamples 1 -vantage.availabilityChecks NO` |

## Checks before uploading

- Exact pixel sizes: `sips -g pixelWidth -g pixelHeight *.png`.
- No alpha: `sips -s format jpeg` or flatten.
- No debug UI (probes, fixture banners, pairing prompts), no real names or addresses, and no
  Android or other mobile-platform imagery.
- The PC desktop source (`docs/images/source/pc-desktop.html:48`) draws a four-square Start
  glyph. It's a plain shape, not Microsoft's logo artwork; keep it that way.
- If the app is renamed, retake every screenshot: the name appears in the UI (About, prompts).
- The `screenshot-validator` agent (axiom) can check a finished set for size, placeholders, and
  debug artifacts.
