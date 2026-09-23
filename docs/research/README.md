# Vantage research index

These reports were produced during the initial build (Sept 2026) and verified against the locally
installed macOS 27.0 and iPhoneOS 27.0 SDKs (Xcode 27, build 27A5228h). They are the source of truth
for API specifics; each flags uncertainty explicitly and lists sources.

| File | Covers | Key verdicts |
| --- | --- | --- |
| `media-pipeline.md` | ScreenCaptureKit capture, VideoToolbox encode, iPad decode/display, pacing | `'420v'` + BT.709/sRGB tags end to end; low-latency VT, no reordering, event-driven IDRs; `AVSampleBufferDisplayLayer` + `DisplayImmediately`; bound in-flight to 1; text vs motion mode from dirty-rect ratio |
| `input.md` | CGEvent injection (mouse/scroll/keyboard), iPad capture, HID→kVK table | Post to `.cgSessionEventTap`; unsandboxed host; full HID→virtual-key table; scroll phase/momentum fields; release all held input on disconnect |
| `tailscale.md` | Discovery, host networking, unattended access | No peer enumeration without OAuth (quad100 is self-only); host shells out to the `tailscale` CLI; `whois` is a strong auth primitive; iPad detects tailnet via a local 100.x interface; unattended reboot access is unsolved for a FileVault'd MacBook |
| `virtual-display.md` | BetterDisplay CLI, `CGVirtualDisplay`, workspace scaling | BetterDisplay for v1 (persistent definitions, connect/disconnect); `CGVirtualDisplay` private API survives into 27 as a v2 backend; a 1210×834@2x virtual screen already works on this Mac |
| `secure-input-and-reboot.md` | How Screens types passwords, keys-only RFB/ARD client, reboot survival with FileVault, restart interception | Screens is a VNC client to `screensharingd` (privileged, exempt from Secure Input); ARD type 30 still works on 27; client connects straight to `:5900` over Tailscale; `fdesetup authrestart` supported here; pre-boot needs SSH unlock via a subnet router |
| `audio-dictation-files.md` | Mac→iPad audio, iPad mic→Mac dictation, file transfer | MacWhisper's bundled `mw transcribe` CLI gives ~1–2 s MacWhisper-quality transcripts; on-iPad `SpeechTranscriber` for a no-Mac-change path; Opus works both sides; Taildrop has no iOS API but `tailscale file cp` works from the Mac |
| `product-and-host-lifecycle.md` | Screens 5 / Jump feature inventory, host lifecycle, power, locking | Feature checklist mirrored from Screens 5 strings; `SACLockScreenImmediate` still resolves; curtain-mode-by-CGEvent is impossible (Secure Input); prevent display sleep on AC; Tailscale can't wake a sleeping Mac |

The `media-pipeline.md` and `input.md` reports were partially completed when a session limit
interrupted their agents; the sections present are fully verified. Gaps (a couple of encode/latency
subsections) are noted inline and were filled from direct SDK header reads recorded in the build.
