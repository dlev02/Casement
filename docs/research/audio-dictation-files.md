# Audio, remote dictation, and file transfer: research and design

Research date: 2026-09-22. Scope: Mac → iPad audio ("hear the Mac"), iPad microphone → Mac dictation,
and file transfer, for the Vantage host (macOS 26+, unsandboxed, Developer ID) and client
(iPadOS/iOS 26+). No app code was changed for this report.

**How this was verified.** API names, availability, and header comments come from the **Xcode 27.0
(27A266a) `MacOSX27.0.sdk` and `iPhoneOS27.0.sdk`** under `/Applications/Xcode.app`. Codec, Speech,
MacWhisper, and Tailscale behaviour was checked with small throwaway probes in the session scratchpad
on Drew's Mac (Apple M3 Max, macOS 27, MacWhisper 14.8.1, Tailscale 1.102.4) and in the booted iOS 26.5
simulator. Nothing in the repo was built or run.

> Status legend: ✅ verified in SDK headers or by a local probe · 🧪 measured on this Mac ·
> 📄 Apple docs/WWDC · 🌐 third-party source · ⚠️ inferred or uncertain; needs an on-device check

---

## 0. Summary of recommendations

### What "remote audio" means

"Remote audio" means **hearing the Mac's sound on the iPad**: notification chimes, a video you started
on the Mac, a call, VoiceOver. The host captures the Mac's audio output, compresses it, sends it over
the same Tailscale connection as the video, and the iPad plays it. Screens 5 and Jump both offer it.
It works the other way too: the iPad microphone can become a microphone on the Mac. That second
direction is what remote dictation with MacWhisper needs.

### Headline verdicts

1. **Remote dictation: build a Dictate button in two stages.**
   - **Stage 1: transcribe on the iPad** with the iOS 26 `SpeechAnalyzer` + `SpeechTranscriber`. It
     shows a live preview and sends the final text through the existing `textInput` path. It needs no
     host changes and keeps working when the Mac is busy. (§B.1)
   - **Stage 2: transcribe on the Mac with MacWhisper, using Drew's own models.** MacWhisper 14.8.1
     ships a CLI (`mw`, inside the app bundle) that transcribes a file through the running app with
     the model selected there. Drew's current selection is Large v3 Turbo. 🧪 Warm latency was
     **~2.1 s for a 16 s clip** with Large v3 Turbo and **0.83 s** with Parakeet v3. The flow: the
     iPad streams 16 kHz PCM while Drew holds the button, the host writes a WAV file, runs
     `mw transcribe`, and types the result. This gets MacWhisper quality with **no virtual audio
     device, no hotkey injection, and no clipboard side effects**. (§B.4)
2. **The virtual microphone route (BlackHole + MacWhisper's push-to-talk hotkey) works but is the
   fragile option.** MacWhisper can select an input device (✅ its binary has "Select the input device
   to record audio from") and has push-to-talk (✅ "Dictation Push to Talk"). Jump Desktop already
   installs this kind of loopback microphone on this Mac. Build it only if Drew wants the iPad
   microphone available to *every* Mac app (calls, voice memos, ChatGPT voice). (§B.3)
3. **Hear the Mac: feasible, medium effort.** Capture with ScreenCaptureKit
   (`capturesAudio`, 48 kHz stereo). Encode **Opus** (✅ the AudioToolbox encoder exists on macOS 27;
   ✅ the encoder and decoder exist in the iOS 26.5 simulator) in 10 ms packets. Send them as a new
   binary message kind. On the iPad, play through `AVAudioEngine` with a ~60 ms adaptive jitter
   buffer. Expected latency is ~70–120 ms on a good path. (§A)
4. **Muting the Mac's speakers while streaming is not possible with ScreenCaptureKit, but it is
   possible with Core Audio process taps.** ✅ `CATapDescription.muteBehavior = CATapMutedWhenTapped`
   (macOS 14.2+). The trade-off is a separate "system audio recording" permission prompt
   (`NSAudioCaptureUsageDescription`). (§A.6)
5. **File transfer: use Taildrop now and build our own later only if needed.** No public API lets a
   third-party iOS app drive Taildrop. ✅ The Mac side *is* scriptable: `tailscale file cp <file>
   drews-ipad-pro:` works, and `--targets` lists the iPad. So "Send to iPad" in the host menu costs
   almost nothing. For iPad → Mac, the system share sheet already contains Tailscale. A native
   transfer feature should use a **second authenticated connection**. The protocol already has an
   unused `attachMedia(sessionToken)` message for this. Effort is M–L. (§C)
6. **Protocol rule for all of this:** `Frame.Header.decode` **throws `unknownKind`** on any kind it
   doesn't know, and `MessageChannel` then tears down the session. New message kinds must be
   **gated by a capability**: an optional field in `HostCapabilities`/`Hello`, and neither side
   sends a new kind the peer didn't advertise. Keep `VantageProtocol.version` at 2. (§D)

### Recommended build order

| # | Piece | Effort | Why this order |
|---|---|---|---|
| 0 | Device test: does the system keyboard's dictation mic reach `RemoteKeyboardField`? | XS | Free if it works. Settles open question #19 in `input.md` |
| 1 | **Dictate panel, on-iPad engine** (`SpeechAnalyzer`, live preview, Send/Cancel) | **M** | Solves "stop round-tripping through ChatGPT" with zero host work |
| 2 | **"Transcribe on Mac" engine** (mic PCM upload → `mw transcribe` → text) with a macOS `SpeechAnalyzer` fallback | **M** | MacWhisper-quality dictation. Reuses the Stage 1 UI |
| 3 | Host menu "Send to iPad…" via `tailscale file cp`, plus "Send to Mac" through the share sheet | **S** | Covers most file needs for almost no code |
| 4 | **Mac audio on iPad** (SCK audio → Opus → AVAudioEngine) | **M** | The "remote audio" feature. Independent of dictation |
| 5 | Mute Mac while streaming (Core Audio tap replaces SCK audio) | **S–M** | Extra TCC prompt. Only if Drew wants it |
| 6 | Native file transfer over a second connection (drag and drop, Files picker, resumable) | **M–L** | Low priority. Taildrop and Blip cover it |
| 7 | Virtual microphone (BlackHole) + MacWhisper hotkey, or our own AudioServerPlugIn | **L** / **XL** | Only for "iPad mic as a Mac mic for any app" |

---

## A. Mac → iPad audio ("hear the Mac")

### A.1 Capture: ScreenCaptureKit system audio

✅ From `MacOSX27.0.sdk/.../ScreenCaptureKit.framework/Headers/SCStream.h`:

| Symbol | Availability | Header text / notes |
|---|---|---|
| `SCStreamConfiguration.capturesAudio` | macOS 13.0 | "specifies whether the audio will be captured. By default audio is not captured." |
| `.sampleRate` | macOS 13.0 | "Default is set to 48000." |
| `.channelCount` | macOS 13.0 | "Default is set to two." |
| `.excludesCurrentProcessAudio` | macOS 13.0 | "whether to exclude audio from current process. Default is set to NO." Set **YES** so the host never captures its own sounds |
| `SCStreamOutputType.audio` | macOS 13.0 | "wrapping an audio buffer list. The format of the audio buffer is based on sampleRate and channelCount" |
| `SCStreamOutputType.microphone` / `captureMicrophone` | macOS 15.0 | Mac mic. Not needed |
| `SCStreamErrorFailedToStartAudioCapture` (-3818) | macOS 13.0 | Handle it: audio fails independently of video |

The header lists iOS 27 availability for these too, because SCK came to iOS 27. That doesn't matter
here: capture happens on the Mac.

**Design notes**

- **Permission:** audio capture rides on the **Screen Recording** grant the host already needs. There
  is no new prompt. ✅ (no separate audio key exists on `SCStreamConfiguration`) 📄 WWDC22-10156.
- **Use a separate `SCStream` for audio.** `HostSession` tears down and rebuilds `ScreenCapture`
  on display switches and viewport changes. If audio shares that stream, it drops out on every
  resize. Build the audio stream with the same display filter but a tiny, slow video config
  (e.g. 2×2 at `minimumFrameInterval` = 1 s). Add only an `.audio` output and ignore `.screen`.
  ⚠️ SCK is widely reported to log "stream output NOT found. Dropping frame" when no `.screen`
  output is attached. That noise is harmless, but adding a no-op `.screen` output avoids it.
- **What gets captured:** with a display filter, ⚠️ audio from all applications is included,
  regardless of which display their windows are on. Audio follows the filter's *applications*, not
  its pixels. Audio also appears to be captured before the output device, so it keeps working when
  the Mac plays to AirPods. Both points need a check on the host.
- **Buffer format:** Float32, non-interleaved, at the configured rate. ⚠️ Buffer size isn't
  documented. Read `CMSampleBufferGetNumSamples` and repacketize into fixed 10 ms (480-frame) blocks
  before encoding. Don't assume a callback size.
- Timestamps: use `CMSampleBufferGetPresentationTimeStamp` (host clock) as the capture time. This
  matches `VideoFrame.captureNanos` semantics.

### A.2 Encoding: what the OS actually ships

🧪 Probe of `kAudioFormatProperty_EncodeFormatIDs` on this Mac (macOS 27):

```
encoders: aac  aace(ELD) aacf aacg aach aacl(LD) aacp alac alaw apac flac ilbc ima4 lpcm opus ulaw
```

🧪 The same probe inside the **iOS 26.5 simulator** lists `opus` as both an encoder and a decoder, and
AAC-ELD as a decoder. The simulator is only indicative, so ⚠️ confirm on the iPad. Apple has shipped
Opus in AudioToolbox on iOS for years, so the risk is low.

🧪 `AudioConverterNew` from Float32 PCM, reading back the converter's properties:

| Codec | Rate / ch | Frames per packet | Packet duration | Encoder priming (`leadingFrames`) | Max packet |
|---|---|---|---|---|---|
| Opus | 48 kHz / 2 | 480 (requested) | **10 ms** | 312 (6.5 ms) | 1276 B |
| Opus | 48 kHz / 2 | 960 | 20 ms | 312 | 1276 B |
| Opus | 16 kHz / 1 | 320 | 20 ms | 104 | 750 B |
| AAC-ELD | 48 kHz / 2 | 480 | 10 ms | 240 (5 ms) | 1536 B |
| AAC-ELD | 48 kHz / 2 | 512 | 10.7 ms | 256 | 1536 B |
| AAC-ELD | 16 kHz / 1 | 480 | 30 ms | 255 | 768 B |

Gotchas found by the probe:
- **Opus defaults to 2.5 ms packets** (`mFramesPerPacket` 120 at 48 kHz) unless you set
  `mFramesPerPacket` explicitly in the destination ASBD. Always set 480 (10 ms) or 960 (20 ms).
- The Opus encoder's default `kAudioConverterEncodeBitRate` reads back as `0xFFFFFC18` (−1000,
  `OPUS_AUTO`). Setting 96 000 (stereo) or 24 000 (mono) is honoured.
- Supported Opus encode rates are exactly 8, 12, 16, 24, and 48 kHz.

**Recommendation: Opus, 48 kHz stereo, 10 ms packets, 96–128 kbps.** AAC-ELD at 480 frames is just
as fast (5 ms priming against Opus's 6.5 ms), so either works. Opus wins on bitrate efficiency, a
10 ms frame at any bitrate, and a clean path to UDP later (built-in packet-loss concealment). Use
`AVAudioConverter` (the Swift wrapper) on both sides. The Opus decoder needs the encoder's
`AudioStreamBasicDescription`, sent once in an `audioConfig` control message. Opus in AudioToolbox
needs no magic cookie. ⚠️ Confirm by round-tripping a decode on device.

Bandwidth: 128 kbps plus framing (8 B header + ~16 B packet header per 10 ms) is about 147 kbps.
That is negligible next to the multi-megabit video stream.

### A.3 Latency budget (good Wi-Fi / direct tailnet path)

| Stage | Estimate | Basis |
|---|---|---|
| SCK audio callback granularity | 10–20 ms | ⚠️ measure |
| Repacketize to 10 ms + Opus lookahead | 10 + 6.5 ms | 🧪 |
| Encode | < 1 ms | ⚠️ |
| Network (one way, direct WireGuard) | 3–30 ms | `tailscale.md` |
| TCP head-of-line behind a video keyframe | 0–130 ms spikes | ⚠️ derived: a 500 KB IDR at 30 Mbps ≈ 133 ms |
| Jitter buffer (adaptive target) | 40–80 ms | design choice |
| Decode | < 1 ms | ⚠️ |
| iPad output (IOBufferDuration 5 ms + hardware) | 10–20 ms | ⚠️ |
| **Total, built-in speakers** | **~70–120 ms** typical | |
| AirPods / Bluetooth A2DP | +150–250 ms | 🌐 typical figures; nothing we can do |

The video path runs about 50–100 ms glass-to-glass, so audio lands roughly in sync. **Don't
hard-sync A/V.** Video uses `DisplayImmediately` and has no presentation clock. Holding video back
for audio, or audio for video, adds latency to both for no benefit in a desktop app.

**The TCP head-of-line problem is the real risk.** All messages share one `NWConnection`, and
`sendDetached` has no priority. An IDR queued ahead of audio delays the audio. Options, cheapest first:
1. Accept it: size the jitter buffer adaptively (grow on underrun, shrink slowly), so the occasional
   IDR causes at most one glitch before the buffer adapts.
2. Carry audio on the second connection that §C.3 introduces (`attachMedia`). That removes the
   socket-level queueing, though both still share the WireGuard tunnel's bottleneck.
3. Later: UDP datagrams for audio. Opus is loss-tolerant. Out of scope for now.

Start with (1). Move audio to (2) once the second connection exists for files.

### A.4 Wire format

New binary kind (host → client; the ≥100 range, next to `videoFrame = 100`, `cursorPosition = 101`):

```
audioPacket = 102
payload: sequence u64 | captureNanos u64 | frameCount u16 | opusPacket (rest)
```

New JSON control kinds (see §D for the full table):
- `audioConfig` (host → client): `{ codec: "opus", sampleRate: 48000, channels: 2, framesPerPacket: 480, bitrate: 128000 }`.
  Sent before the first `audioPacket` and whenever the config changes.
- `audioRequest` (client → host): `{ enabled: Bool, muteMacOutput: Bool? }`. Audio is **off until the client asks**, so an
  old client never receives kind 102.

### A.5 iPad playback

**Recommended: `AVAudioEngine` + `AVAudioSourceNode` pulling from a jitter/ring buffer.**
Decode each Opus packet with `AVAudioConverter` into Float32 48 kHz PCM, push into a lock-free ring
buffer, and let the source node's render block pull 5 ms at a time. This gives direct control over:
- buffer depth (adaptive target 40–80 ms; start playback at the target, not at the first packet),
- **clock drift.** The Mac's and iPad's sample clocks drift apart by tens of ppm, and over a long
  session the buffer slowly fills or drains. Correct it by dropping or duplicating a single frame
  when depth leaves the target band, or by nudging an `AVAudioUnitVarispeed` rate by ±0.1%,
- underrun behaviour (fade to silence instead of a click).

**Alternative: `AVSampleBufferAudioRenderer` + `AVSampleBufferRenderSynchronizer`** (✅ iOS 11+,
`AVSampleBufferAudioRenderer.h`). It accepts compressed Opus/AAC `CMSampleBuffer`s and decodes
internally, which means less code. But it is timeline playback: "The audio in the sample buffer is
rendered at the sample buffer's output presentation timestamp, as interpreted by the timebase"
(header). You have to manage the synchronizer's rate and time mapping yourself, and
`delaysRateChangeUntilHasSufficientMediaData` (iOS 14.5) adds startup delay. ✅ Note that in the
27 SDK, `addRenderer:` is `AVF_DEPRECATED_FOR_SWIFT_ONLY` in favour of
`sampleBufferReceiver()` + `addReceiver(_:)` (`AVSampleBufferRenderSynchronizer.h`). This path is
fine for an A/V-synced media player. For a live, drift-prone remote stream the engine path is
simpler to make low-latency. ⚠️ If the engine path is too much code, prototype this one first.

**`AVAudioSession` on the iPad**

| Situation | Category / mode / options |
|---|---|
| Hearing the Mac only | `.playback`, mode `.default`, options `[.mixWithOthers]` (don't stop Drew's music unless he asks). `.playback` ignores the silent switch, which is correct for an explicit "Mac audio" toggle |
| Dictating (mic on) while Mac audio plays | `.playAndRecord`, options `[.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers]` |
| Echo | ✅ `setPrefersEchoCancelledInput(_:)` is iOS 18.2+, **"only available on certain 2024 or later iPhone models"** (`AVAudioSession.h`), with `.playAndRecord` + `.default` mode. Otherwise voice processing on the input node (`setVoiceProcessingEnabled`, iOS 13+). **Simplest: duck or pause Mac audio while the Dictate button is held** |

Set `setPreferredIOBufferDuration(0.005)`. Handle `interruptionNotification` (a phone call pauses
audio; resume on `.shouldResume`) and `routeChangeNotification` (AirPods in or out: reset the jitter
target).

Background: without `UIBackgroundModes` → `audio`, playback stops when the app backgrounds. That's
consistent with today's behaviour, where the session stops when backgrounded. Adding the background
audio mode would keep the TCP session alive while Mac audio plays. That's a real behaviour change
with App Review implications, so treat it as a separate decision.

### A.6 Muting the Mac while streaming

**ScreenCaptureKit cannot do this.** No SCK property touches the Mac's output (✅ `SCStream.h`), and
SCK captures audio before the output device.

**Options:**

1. **Core Audio process taps (recommended if Drew wants it).** ✅ `CoreAudio/CATapDescription.h`:
   ```
   CATapMuted            "Audio is captured by the tap but no audio is sent from the process to the audio hardware"
   CATapMutedWhenTapped  "... until the tap is read by another audio client. For the duration of the
                          read activity on the tap no audio is sent to the audio hardware."
   ```
   `AudioHardwareCreateProcessTap` is ✅ macOS 14.2+ (`AudioHardwareTapping.h`). Create a global tap
   with `initStereoGlobalTapButExcludeProcesses:[hostPID]` and `muteBehavior =
   CATapMutedWhenTapped`, wrap it in a private aggregate device (`kAudioAggregateDeviceTapListKey`,
   `kAudioAggregateDeviceTapAutoStartKey`), and read it with an IOProc. The Mac's speakers go silent
   **only while Vantage is reading**, so a crash or disconnect unmutes automatically. ✅ macOS 26 adds
   `bundleIDs` and `processRestoreEnabled` to the description.
   - Cost: a new TCC category. 📄 The first time the aggregate device starts, macOS prompts for system
     audio recording permission. It needs **`NSAudioCaptureUsageDescription`** in the host's
     Info.plist ([Apple: NSAudioCaptureUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nsaudiocaptureusagedescription),
     [Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)).
     🌐 The prompt only appears for a properly signed binary, and a macOS 26 gotcha: the IOProc
     dispatch queue must be non-nil or the block silently never registers
     ([DGR Labs, 2026](https://dgrlabs.co/blog/2026-04-25-capturing-system-audio-on-macos-in-2026.html)).
   - If you build this, **use the tap for all audio capture** and drop SCK audio. That way one path
     handles both "hear" and "mute".
   - ⚠️ Whether a *global* tap with `MutedWhenTapped` silences every process (including system
     sounds) needs a test.
2. **Mute the output device** (`kAudioDevicePropertyMute` / volume 0 on the default output). ⚠️ This
   should not affect SCK capture, since SCK captures before the device, but it changes a user-visible
   setting. A crash leaves the Mac muted, so the host must restore it on launch.
3. **Route Mac output to a null device** (BlackHole as the default output). Heavy-handed. Avoid.

### A.7 Effort

**M (about 3–4 focused days):** audio SCStream + repacketizer + Opus encoder (S), wire kinds +
capability + config (S), client decode + jitter buffer + engine + session handling (M), control-strip
toggle and per-device "Play Mac audio" setting (S). The mute option (tap-based capture) adds S–M.

---

## B. iPad microphone → Mac (remote dictation)

Drew's baseline today: dictate into the Claude/ChatGPT app, copy, paste into Vantage. Anything we
build must beat that on quality and taps. Four options, then the staged plan.

### B.0 Does the system keyboard's dictation mic already work in `RemoteKeyboardField`?

`RemoteKeyboardView` adopts only `UIKeyInput` (✅ `Vantage/UI/RemoteKeyboardField.swift`).
`input.md` §B.3 already found that **dictation is undocumented for bare `UIKeyInput`**. The
documented hooks (`insertDictationResult(_:)`, `dictationRecordingDidEnd()`) are on `UITextInput`,
and Apple warns that "only a small subset of the available keyboards and languages are available"
to `UIKeyInput` adopters. That is open question #19 there.

Even if the mic key appears, since iOS 16 dictation **revises text as you speak** by replacing words
it already inserted. 🌐 A developer reports `replaceRange:withText:` stopped being called on custom
text views in iOS 16, with `insertDictationResult` arriving only when dictation ends
([Apple forums 746678](https://developer.apple.com/forums/thread/746678)). With a buffer-less
responder that forwards every `insertText` straight to the Mac, revisions either get lost or come
through as extra text. ⚠️ **Test on the iPad.** If it works acceptably, it's a free fallback. Either
way, a dedicated Dictate panel that sends **only final text** is the robust design.

### B.1 Option 1: on-device transcription on the iPad (iOS 26 Speech framework)

✅ Exact API, from `iPhoneOS27.0.sdk/.../Speech.swiftmodule/arm64e-apple-ios.swiftinterface` (all
`@available(anyAppleOS 26, *)` unless noted; everything is watchOS-unavailable):

| Type | Role |
|---|---|
| `actor SpeechAnalyzer` | Drives analysis. `init(modules:options:)`, `start(inputSequence:)`, `analyzeSequence(_:)`, `prepareToAnalyze(in:)`, `finalizeAndFinishThroughEndOfInput()`, `cancelAndFinishNow()`, `volatileRange` |
| `class SpeechTranscriber` | Apple's new long-form ASR model. `init(locale:preset:)`. Presets `.transcription`, `.transcriptionWithAlternatives`, `.timeIndexedTranscriptionWithAlternatives`, `.progressiveTranscription`, `.timeIndexedProgressiveTranscription`. `ReportingOption`: `.volatileResults`, `.alternativeTranscriptions`, `.fastResults`. `static var isAvailable` (hardware gate) |
| `class DictationTranscriber` | The older keyboard-dictation model. Presets `.phrase`, `.shortDictation`, `.progressiveShortDictation`, `.longDictation`, `.progressiveLongDictation`, `.timeIndexedLongDictation`. `TranscriptionOption`: `.punctuation`, `.emoji`, `.etiquetteReplacements`. `ContentHint`: `.shortForm`, `.farField`, `.atypicalSpeech` |
| `class SpeechDetector` | Voice-activity detection module (useful for auto-stop) |
| `class AssetInventory` | `status(forModules:)` → `.unsupported/.supported/.downloading/.installed`. `assetInstallationRequest(supporting:)` → `AssetInstallationRequest.downloadAndInstall()` (with `progress`). `reserve(locale:)`, `release(reservedLocale:)`, `maximumReservedLocales` |
| `AnalysisContext.contextualStrings` | Custom vocabulary hints ("Vantage", "Tailscale", names) |
| `AnalyzerInputConverter` | **iOS 27 only.** Converts arbitrary buffers to the analyzer format. On 26, use `AVAudioConverter` |
| `CaptureInputSequenceProvider`, `AssetInputSequenceProvider` | **iOS 27 only.** Ready-made mic/file input plumbing |
| `SpeechAnalyzer.Options.ignoresResourceLimits` | **iOS 27 only** |
| `SFSpeechError.Code.insufficientResources` | Thrown past the ~2-analyzer cap (Axiom `ios-ml.md`) |

Result shape: each `Result` has `text: AttributedString`, `range: CMTimeRange`, and
`resultsFinalizationTime`. The extension property `isFinal` separates **volatile** results (fast
guesses that get replaced) from **final** ones. The UI shows volatile text dimmed and appends final
text. **Only final text is ever sent to the Mac.**

🧪 Probes on this Mac (macOS 27; the iOS framework is the same API, so locale lists likely match
⚠️):
- `SpeechTranscriber.isAvailable == true`. It supports **45 locales** (en_US/GB/AU/CA/IN/IE/NZ/SG/ZA,
  de, es, fr, it, ja, ko, pt, zh, yue, many Indic). `DictationTranscriber` supports **54**
  (it adds ar, ca, cs, da, el, fi, he, hr, hu, id, ms, nb, nl, pl, ro, ru, sk, sv, th, tr, uk, vi).
- **Native analyzer format for both: 16 kHz mono Int16** (`availableCompatibleAudioFormats`
  → 16000/8000 Hz, 1 ch, `pcmFormatInt16`). This decides the uplink codec (§B.6).
- `AssetInventory.status(forModules:)` returned `.supported` for en-US even though `en_US` appears in
  `installedLocales`. ⚠️ Status seems to be per-app, so the app must still reserve and install. Build
  an explicit "Download speech model" step with progress.
- `maximumReservedLocales == 5`.
- Preset contents: `.progressiveTranscription` = `{fastResults, volatileResults}`.
  `.progressiveLongDictation` = `{punctuation}` + `{volatileResults}`. `.shortDictation` carries the
  `.shortForm` hint.
- 🧪 Accuracy and speed on a 15.9 s TTS clip containing "pull request", "Vantage", and "codec":

  | Engine | Time | Errors |
  |---|---|---|
  | `SpeechTranscriber` `.transcription` | 0.39 s | "pool request", "vantage" |
  | `DictationTranscriber` `.longDictation` | 0.55–0.76 s | "measure agency", "pool request", "audio Kodak", lost punctuation |
  | MacWhisper Large v3 Turbo (`mw`) | 2.1 s warm | **none** |

  `DictationTranscriber` with `.shortDictation` returned **empty text** for a 4.9 s file (the
  `.shortForm` hint); `.longDictation` worked. Use the long or progressive-long presets for prose.
- **Authorization:** both transcribers ran from an unbundled CLI with
  `SFSpeechRecognizer.authorizationStatus() == .notDetermined`, with no prompt and no crash. That
  matches 🌐 reports that `SpeechAnalyzer` needs only microphone permission
  ([Blake Crosley](https://blakecrosley.com/blog/speech-framework-vs-sfspeechrecognizer)).
  Axiom's `ios-ml.md` says both frameworks need `NSSpeechRecognitionUsageDescription`. **Ship both
  usage strings anyway**. It's free, and ⚠️ iOS app-sandbox enforcement may differ from a macOS CLI.

**Engine choice on the iPad:** `SpeechTranscriber(locale:, preset: .progressiveTranscription)`
when `SpeechTranscriber.isAvailable` and the locale is supported. Otherwise fall back to
`DictationTranscriber(..., preset: .progressiveLongDictation)` with
`AnalysisContext.contextualStrings[.general] = [app and Mac names, "Tailscale", …]`.
🌐 Only `DictationTranscriber` honours contextual strings.

**Mic plumbing on iOS 26:** `AVAudioEngine.inputNode.installTap` → `AVAudioConverter` to the format
from `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` (✅ swiftinterface; a
`considering naturalFormat:` overload also exists) or the module's
`availableCompatibleAudioFormats` → `AsyncStream<AnalyzerInput>` → `analyzer.start(inputSequence:)`.
On iOS 27, `CaptureInputSequenceProvider` does this for you. Axiom warns that the convenience
constructor reconfigures the app's default `AVAudioSession`, which clashes with Mac-audio playback
(§A.5). Prefer building your own tap.

**Verdict:** best latency (live preview, final text ~0.3 s after release), works offline and with the
Mac unreachable, and needs no host work. Quality is noticeably below Whisper Large on names and
jargon. Good for Stage 1.

### B.2 Option 2: stream the mic to the host and transcribe with macOS `SpeechAnalyzer`

Same API on macOS 26 (✅ the probes above ran on macOS). The host is unsandboxed and needs no mic
permission because it never opens a microphone; it analyses buffers it receives. The host feeds the
received PCM into an `AsyncStream<AnalyzerInput>`. It can send volatile results back for the preview
and type final results itself.

**Verdict:** no quality gain over Option 1. It is the *same* Apple model, now on the Mac, and it adds
network dependence. Its one use is as the **host-side fallback for Option 4** when MacWhisper isn't
installed. Don't build it as a user-facing engine of its own.

### B.3 Option 3: virtual microphone on the Mac + MacWhisper's own dictation

**What MacWhisper offers** (MacWhisper 14.8.1, `com.goodsnooze.MacWhisper`, direct-download
Sparkle build at `/Applications/MacWhisper.app`):
- ✅ Input device choice: the binary contains *"Select the input device to record audio from"*,
  `_selectedMicrophoneInput`, *"Successfully set input device."*, and *"Default input device did
  change"*. It can pin a device or follow the system default. The public docs don't mention it
  ([Dictation doc](https://docs.macwhisper.com/article/14-how-to-use-the-dictation-feature)).
- ✅ Push-to-talk and toggle: *"Dictation Push to Talk"*, *"Press and hold the dictation key to
  dictate and release when you're done"*, *"You can also change the button behaviour to toggle
  instead of push to talk in dictation settings."*
- ✅ Hotkey mechanism: it links sindresorhus' **KeyboardShortcuts** (Carbon `RegisterEventHotKey`)
  **and** calls `CGEventTapCreate` (probably for a modifier-only hold key) and `CGEventPostToPid`.
- ✅ Text insertion is **via the pasteboard**: *"Dictation delay before restoring pasteboard
  contents"*, *"Could Not Paste Dictation, Copied to Pasteboard."*
- 📄 Dictation needs **MacWhisper Pro** and the non-App-Store build (dictation doc).

**Plumbing**

1. iPad streams mic PCM (§B.6) to the host.
2. Host plays it into the **output side of a loopback device**. MacWhisper reads the **input side**.
   - **BlackHole** ([GitHub](https://github.com/ExistentialAudio/BlackHole)): an AudioServerPlugIn,
     "no kernel extensions", installs to `/Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver` (pkg or
     `brew install blackhole-2ch`), needs admin plus `sudo killall -9 coreaudiod`, claims "zero
     additional driver latency", **GPL-3.0**. Commercial bundling needs a licence from Existential
     Audio. For Drew's personal use, having him install it himself is fine. Vantage must not
     bundle it.
   - Select the device: ✅ `AUAudioUnit.setDeviceID(_:)` (macOS-only, `AUAudioUnit.h`) on
     `engine.outputNode.auAudioUnit`, or `kAudioOutputUnitProperty_CurrentDevice` (✅ `= 2000`,
     `AudioUnitProperties.h`) on the output AudioUnit. Find BlackHole by UID with
     `kAudioHardwarePropertyTranslateUIDToDevice`.
   - **Prior art on this Mac:** ✅ Jump Desktop installed `JumpAudioMic.driver`
     (`com.p5sys.jump.audio.driver.mic`, team `2HCKV38EEC`). It shows up as **"Jump Desktop
     Microphone", 8 in / 8 out, Transport: Virtual**, the same loopback pattern with no mach-service
     IPC declared. That's how a commercial remote-desktop app forwards the client mic.
3. MacWhisper's input is either set to BlackHole once, or left on "system default" while the host
   switches the **default input device** to BlackHole during a remote session and restores it
   afterwards (`kAudioHardwarePropertyDefaultInputDevice`). ⚠️ Whether MacWhisper follows a
   mid-session default change needs a test. The log string suggests it does.
4. The client's Dictate button sends MacWhisper's push-to-talk key **down** on press and **up** on
   release through the existing `keyEvent` path. `InputInjector.releaseAll()` on disconnect already
   ends a stuck hold.

**Risks**
- ⚠️ **Hotkey delivery.** Vantage posts at `.cgSessionEventTap` (`input.md`). A `CGEventTap`
  created at `kCGHIDEventTap` sits *upstream* of that and never sees our events. Session and
  annotated-session taps and Carbon hotkeys should. Which one MacWhisper uses for a modifier-only
  hold key is unknown, so **test with Drew's actual key**.
- **Clipboard bounce.** MacWhisper pastes through `NSPasteboard` and then restores it.
  `ClipboardBridge` polls `changeCount` every 0.5 s (✅ `ClipboardBridge.swift`), so the transcript,
  and possibly the restored old contents, get pushed to the iPad clipboard. Mostly harmless but
  surprising. Suppress the sync while remote dictation is active.
- **Latency.** MacWhisper transcribes after release (Large v3 Turbo ~2 s, §B.4). This is no faster
  than Option 4, and it adds real-time audio streaming requirements (jitter buffer on the Mac side,
  and underruns show up as dropouts in the "mic").
- Local use: if MacWhisper is pinned to BlackHole, Drew's at-desk dictation breaks until he switches
  back. The default-device swap avoids that but touches a global setting (restore on quit and crash).

**Our own AudioServerPlugIn instead of BlackHole** (✅ `CoreAudio/AudioServerPlugIn.h`): a CFPlugIn
bundle in `/Library/Audio/Plug-Ins/HAL/*.driver`, loaded by a **sandboxed** host process
("may only read files in its bundle… may communicate with other processes" only if it lists them in
`AudioServerPlugIn_MachServices`). Installing it needs admin rights and a `coreaudiod` restart. The
simplest version is a loopback device like BlackHole or Jump, so it needs no IPC: the host writes the
output side like any other device. This is **XL** if done properly: C, real-time-safe code, clock
and timestamp handling, an installer or privileged helper, notarization, and a Developer ID signed
plugin. `AudioDriverKit` exists but needs Apple-granted DriverKit entitlements and a system-extension
approval, which is more work still. Only worth it if Vantage becomes a product.

**Verdict:** works, and it is the only option that makes the iPad a *general* Mac microphone.
For dictation specifically it is the most fragile option and no faster than §B.4. Defer (build-order
#7).

### B.4 Option 4: send the clip as a file to MacWhisper (**recommended Mac engine**)

What MacWhisper exposes for automation:

| Surface | Finding |
|---|---|
| URL scheme | ✅ `macwhisper://` is registered (`CFBundleURLTypes`). The only route string in the binary is `macwhisper://reopenWindow`, so **no transcribe URL** |
| App Intents / Shortcuts | ✅ `Metadata.appintents` declares one action: **`TranscribeAudioIntent` "Transcribe Audio"** (parameter `audioFile`, `openAppWhenRun: false`). Usable with `shortcuts run`, but only through a user-built shortcut |
| AppleScript | ✅ No `.sdef`, no `NSAppleScriptEnabled` |
| **CLI `mw`** | ✅ Ships **inside the bundle** at `/Applications/MacWhisper.app/Contents/MacOS/mw`. It can optionally be installed to `/usr/local/bin/mw` from Settings → Advanced → Command-Line Tool. 📄 "talks to the running MacWhisper app over a local socket, so it uses the exact same engines, models, and settings you've configured", and launches the app if it's not running ([mw docs](https://docs.macwhisper.com/article/57-macwhisper-command-line-tool)) |

✅ `mw help transcribe` (14.8.1): `mw transcribe [--model engine:id] [--language xx|auto]
[--persist] [--stream] [--format txt|srt|vtt|json|csv|md|html|avid] … <paths>`. The transcript goes
to **stdout**. `--stream` emits segments as they finalize (single input). `--persist` saves to
history. Leave it off so dictations stay out of MacWhisper's history. 📄 `txt` output doesn't need
Pro. ✅ `mw models list` on Drew's Mac shows the selection **▸ `whisperkit:openai_whisper-large-v3-v20240930`
(Large v3 Turbo)**, plus `parakeet-pro:nvidia_parakeet-v3`, `apple:en-US`, and OpenAI cloud models.
A `--model` override applies to that run only (✅ the selection was unchanged afterwards).

🧪 **Measured on this M3 Max** (15.9 s, 16 kHz mono Int16 WAV; MacWhisper already running):

| Model | Cold (first call) | Warm | Output |
|---|---|---|---|
| Large v3 Turbo (Drew's default) | 10.8 s | **2.08–2.12 s** | Perfect, including "Vantage" and "pull request" |
| Parakeet v3 | 6.1 s | **0.83 s** | Perfect wording, slightly different punctuation |
| `apple:en-US` | — | 1.05 s | "pool request" |
| Large v3 Turbo, 4.9 s clip | — | 2.18 s | Fixed overhead dominates short clips |

🧪 **Built-in Parakeet (FluidAudio 0.16.1, Parakeet TDT 0.6B v3, int8 encoder)**, run through the
host's own `HostTranscriber` → `ParakeetRuntime` on a 14.7 s `say` clip ("pull request", "Vantage",
"codec", "Parakeet", "Neural Engine"): download 491.5 MB (~85 s incl. first load); first-ever load
in a new app compiles for the ANE in **18.5 s** (36 MB cache in `~/Library/Caches/<bundle id>`),
later process launches load + warm in **0.41 s**; warm transcription **0.13–0.14 s**. Output
matched MacWhisper word for word except lower-case "vantage" (MacWhisper Large v3 Turbo: 11.8 s
cold / 2.14 s warm, perfect; Apple SpeechAnalyzer: 0.35–0.73 s, "pool request", "Codex",
"scheduled a"). Chosen over WhisperKit for speed and size (no license or Swift 6 blockers).

**Flow**

1. Drew holds (or toggles) **Dictate**. The iPad captures 16 kHz mono and **streams it while he
   speaks** (`micAudio` packets), so the upload has finished by the time he lets go. Optionally, the
   on-iPad `SpeechAnalyzer` runs at the same time purely for a live preview.
2. On release, the client sends `dictationControl{ action: commit, id, engine: macWhisper }`.
3. The host writes `…/Caches/Vantage/dictation-<id>.wav` (✅ 16 kHz Int16 is a format `mw` accepts;
   🧪 used above), runs `mw transcribe --language en <wav>` via `Process` (the same pattern as
   `TailscaleCLI.run`), reads stdout, **deletes the WAV**, and sends
   `dictationResult{ id, text, isFinal: true, engine }`.
4. The client shows the final text in the panel, replacing the preview, with **Send** (types it via
   the existing `textInput` → `InputInjector.typeText`), **Send + Return**, **Edit**, and **Cancel**.
   An "auto-send" setting skips the review for trusted use.
5. Fallbacks: `mw` missing, MacWhisper not installed, or a non-zero exit → the host runs macOS
   `SpeechAnalyzer` on the same WAV (0.4 s, §B.1) and labels the result "Apple". Timeout at ~20 s.

**Why this beats Option 3:** same MacWhisper models and quality, no audio driver install, no
default-device juggling, no hotkey injection, no clipboard bounce. Text is typed by our injector,
which already handles Secure Input refusal (`HostStatus.isSecureInputActive`). Latency equals
MacWhisper's own post-release latency, because MacWhisper dictation also transcribes after release.

**Caveats:** ⚠️ The first call after MacWhisper launches pays the model load (10.8 s cold). The host
can warm it with a 0.5 s silent clip when a session starts. That's cheap, but only do it when
dictation is enabled. `mw` requires MacWhisper to be running in the logged-in session. The host runs
there too, so that's fine. `mw`'s socket protocol is private to MacWhisper. The *CLI* is the
documented surface, so pin to it and parse `mw version` for diagnostics.

**Near-live variant (later):** split on pauses with `SpeechDetector` (or a simple energy VAD) and
send each utterance as its own clip, so transcription pipelines behind speech. Parakeet v3 at ~0.8 s
warm makes this feel close to live.

### B.5 Permission strings

| Target | Key | Proposed text | Needed for |
|---|---|---|---|
| Vantage (iOS) | `NSMicrophoneUsageDescription` | "Vantage uses the microphone when you dictate text to your Mac." | Any mic capture (the app crashes without it) |
| Vantage (iOS) | `NSSpeechRecognitionUsageDescription` | "Vantage turns your speech into text on this device before sending it to your Mac." | Belt and braces for `SpeechAnalyzer` (§B.1) |
| VantageHost (macOS) | `NSAudioCaptureUsageDescription` | "Vantage Host captures your Mac's sound so you can hear it on your iPad." | Only if Core Audio taps are used (§A.6) |
| VantageHost | *(none)* | — | SCK audio uses the Screen Recording grant. Receiving and transcribing mic audio opens no device. Playing into BlackHole is output, not input |

The client already sets `INFOPLIST_KEY_NSLocalNetworkUsageDescription` and `…NSFaceIDUsageDescription`
through build settings (✅ `project.pbxproj`). Add the two new keys the same way.

### B.6 Uplink audio format for speech

| Choice | Bitrate | Pros | Cons |
|---|---|---|---|
| **PCM16, 16 kHz mono** | 256 kbps | Exactly the Speech analyzer's native format (🧪) and Whisper's input rate. Lossless. Zero codec latency or code. The WAV is trivial to write | 256 kbps is ~2–5% of the video stream. Fine |
| Opus 16 kHz mono, 24–32 kbps | ~30 kbps | ✅ encoder verified (320-frame / 20 ms, 104 frames priming). Good on bad cellular links | Lossy artifacts can cost a little ASR accuracy. Decode step on the host |
| AAC-ELD 16 kHz mono | 24 kbps | ✅ available | 30 ms packets at 16 kHz (🧪). No advantage over Opus |

**Recommendation: PCM16 16 kHz mono, 20 ms packets (640 B)** for v1. Add Opus later only if Drew
dictates over poor cellular links. Capture at the hardware rate and convert with `AVAudioConverter`
on the iPad, so the host receives exactly what it writes to disk.

Binary kind (client → host, the ≥120 range next to `pointerEvent = 120`):
```
micAudio = 123
payload: dictationID (16 B UUID) | sequence u32 | format u8 (0 = pcm16le16k) | samples (rest)
```

### B.7 UI sketch: Dictate in the control strip

```
Control strip (expanded):  [⌃][⌥][⌘][⇧] | [esc][⇥][←][↑][↓][→] | [🔍][▦][🔑] | [🎙][⌨︎][•••]
Compact pill:              [🎙][⌨︎][⌄]
```

- Add a **mic button** (`mic` / `mic.fill`) next to `keyboardButton` in both `actions` and
  `compact` (✅ `ControlStrip.swift` puts `keyboardButton` in both). Dictation is used about as often
  as the keyboard.
- **Gesture: hold to talk, tap to toggle.** A press longer than ~300 ms is push-to-talk (release
  commits). A quick tap enters toggle mode (tap again to commit). This matches MacWhisper's two
  modes without needing a setting. VoiceOver: a single action, "Start dictation" / "Stop
  dictation".
- **Dictation panel** (a glass card anchored above the strip; it doesn't cover the Mac's centre):
  ```
  ┌──────────────────────────────────────────────┐
  │ ● Listening… 0:07          On iPad ▾ / MacWhisper ▾ │
  │ Please move the meeting to Thursday at three │  ← final text: primary colour
  │ and send the upd…                            │  ← volatile: secondary, animated
  │ ▁▂▅▇▅▂▁ (level meter)                        │
  │ [Cancel]            [Send ⏎]   [Send]        │
  └──────────────────────────────────────────────┘
  ```
  Transcribing on the Mac → "Transcribing on Mac…" spinner, then the final text replaces the
  preview. Editable before Send (a plain `TextField`). Send types the text. **Send ⏎** types it and
  presses Return, which is the common chat and terminal case.
- Engine picker per saved device: **On iPad** (default) / **MacWhisper on Mac** (shown only when the
  host reports it) / **Apple on Mac**. Stored in `SessionPreferences`.
- When `HostStatus.isSecureInputActive` is set, refuse Send with the existing explanation, and offer
  **Copy** instead so the text isn't lost.
- Duck Mac audio (§A) while the mic is live. Haptic on start and stop. Auto-stop after ~2 s of
  silence in toggle mode (`SpeechDetector`) as an option.
- iPhone: the same button. The panel docks above the keyboard area.

Prior art: Screens 5 has `Show Dictation`, `Listening…`, `Transcript`, and "insert text directly on
the remote or Send to Remote Clipboard" (`product-and-host-lifecycle.md` §1.10). Offering **Send to
Mac clipboard** as a secondary action costs nothing, since the clipboard message already exists.

### B.8 Effort

- Stage 1 (on-iPad engine + panel + control-strip button + asset download UI + permissions): **M**,
  about 3–4 days.
- Stage 2 (mic streaming + host WAV + `mw` runner + Apple fallback + capability + result message):
  **M**, about 2–3 days on top of Stage 1, which already provides the UI and mic capture.
- Option 3 with BlackHole: **L** (real-time Mac-side playback, device management, hotkey testing,
  clipboard suppression). Our own HAL plugin: **XL**.

---

## C. File transfer

### C.1 Can a third-party app drive Taildrop?

| Surface | Finding |
|---|---|
| **macOS CLI** | ✅ `tailscale file cp <files...> <target>:` (flags `--name`, `--targets`, `--verbose`). ✅ `tailscale file cp --targets` on Drew's Mac lists `drew-pc`, **`drews-ipad-pro`**, and `drews-iphone-16-pro`. The host already shells out to this binary (`TailscaleCLI.candidatePaths` → `/Applications/Tailscale.app/Contents/MacOS/Tailscale`), and `whois` gives it the connected iPad's name. **So "Send to iPad" from the host is a one-line `Process` call.** Files land in the Tailscale app on iOS: a notification opens them in Files 📄 ([Taildrop docs](https://tailscale.com/docs/features/taildrop)) |
| macOS LocalAPI | Works, but the CLI is the stable surface (`tailscale.md` §1.4) |
| **iOS LocalAPI** | ❌ tailscaled runs inside the Tailscale app's sandboxed Network Extension. No IPC or LocalAPI is exposed to other apps (`tailscale.md`: quad100 serves self-identity only). **No public API** |
| iOS Shortcuts | 📄 Tailscale ships a **"Send File"** Shortcuts action ([docs](https://tailscale.com/docs/features/mac-ios-shortcuts)). Vantage can't call it directly. A user-built shortcut can be launched with `shortcuts://run-shortcut?name=…`, but passing a file into it is clumsy |
| iOS share sheet | 📄 "Share menu → Tailscale → device". Vantage can simply present `UIActivityViewController` with the file. The user picks Tailscale, then the Mac. Zero integration |
| PeerAPI `PUT /v0/put/<name>` | 🌐 Undocumented node-to-node Taildrop endpoint. TailSync (iOS) sends to it directly and "probes likely PeerAPI ports" ([TailSync](https://github.com/SohelIslamImran/TailSync)). Auth is whois on the source IP (`tailscale.md` §1.5). It works because traffic from the iPad's tunnel carries its tailnet identity. **Internal API, may change. Don't depend on it** |
| Limits | 📄 Taildrop is **alpha**, "limited to sending files between your own personal devices", and cannot target tagged nodes. Received files on macOS go to `~/Downloads` |

**Cheap path (build-order #3, S):**
- Host menu bar → **"Send File to iPad…"** (`NSOpenPanel`) → `tailscale file cp <url> <peer-name>:`
  in the background, with progress from `--verbose` and a completion notification. Works even
  without an active Vantage session.
- iPad session menu → **"Send File to Mac…"** → `UIDocumentPickerViewController` → share sheet with the
  file (the user taps Tailscale → Mac). Or tell Drew to use Blip. Worth doing only if a single tap
  saves time.

### C.2 Blip privacy (for comparison)

- 🌐 Blip "connects devices directly whenever possible… If a direct connection isn't possible, your
  data is securely routed through our encrypted relay network". Transfers are "end-to-end
  encrypted with a mutually authenticated connection (mTLS over TLS 1.3)… (not even us)" (search
  snippet of [blip.net/security](https://blip.net/security); the page itself returned 403 to the
  fetcher).
- 🌐 In the July 2025 HN launch thread, co-founder `tomazsh`: "When a direct connection isn't possible,
  files travel through our servers". E2EE was then "already supported for transfers between iOS and
  Mac devices". Team member `iamcalledrob` described the relay as "something closer to Tailscale
  DERP" ([HN 44648772](https://news.ycombinator.com/item?id=44648772)). Commenters asked "with whose
  key?", and the founders didn't answer key management or CA questions in the visible thread
  ([BigGo summary](https://biggo.com/news/202507230125_Blip_File_Transfer_Debate)).
- ⚠️ Inference: with mTLS, Blip almost certainly runs the certificate authority that identifies
  devices. The content is E2E encrypted, but **you trust Blip's identity infrastructure** not to
  issue a man-in-the-middle certificate. Relays see metadata (sizes, timing, device pairs).
  Taildrop and a native Vantage transfer stay inside the WireGuard tunnel, between keys only Drew's
  devices hold. Tailscale's coordination server distributes WireGuard public keys, so the trust
  model is similar in kind, but Drew already trusts Tailscale for Vantage.
- Practical verdict: Blip is fine for Drew's files between his own devices. Taildrop is strictly
  more private and needs no extra account.

### C.3 Native design over Vantage's own channel

**Transport: a second TCP connection per session.** Don't put file chunks on the main stream.
`sendDetached` has no backpressure or priority, so a 256 KB chunk at 20 Mbps is about 100 ms of
head-of-line blocking for video and input. The protocol already has the hook:
`AuthResult.sessionToken` ("Opaque token used by the media connection to attach to this session")
and `MessageKind.attachMedia = 60` (✅ `ControlMessages.swift`, `MessageKind.swift`). Today the host
always sends `sessionToken: nil` (✅ `HostSession.swift:101`), and no code handles `attachMedia`.
Design:
1. The host generates a 32-byte random token per session and returns it in `AuthResult` when the
   client advertises `fileTransfer`.
2. The client opens connection #2 to the same host and port and sends `attachMedia{sessionToken}`
   as its **first** message. The host checks the peer IP is the same tailnet node as connection #1
   (whois) and binds the connection to that `HostSession`. Tokens are single-use, expire with the
   session, and are compared in constant time.
3. Use `NWParameters` for #2 with `serviceClass = .background` (it tags DSCP; mostly moot inside
   WireGuard, but harmless). Later, the same connection can carry audio (§A.3).

**Messages** (on connection #2; capability-gated per §D):

| Kind | Dir | Encoding | Fields |
|---|---|---|---|
| `fileOffer = 80` | either | JSON | `id: UUID, name, byteCount: UInt64, modified: Date?, uti: String?` |
| `fileAccept = 81` | receiver | JSON | `id, resumeOffset: UInt64` (0 = fresh) or `rejected: reason` |
| `fileChunk = 103 (h→c) / 124 (c→h)` | sender | binary | `id (16 B) | offset u64 | bytes` (256 KiB, well under `Frame.maxPayloadLength` 32 MiB) |
| `fileComplete = 82` | sender | JSON | `id, sha256: Data` |
| `fileResult = 83` | receiver | JSON | `id, ok, savedName?, error?` |
| `fileCancel = 84` | either | JSON | `id` |

- **Backpressure:** awaited `MessageChannel.send` (`.contentProcessed`) with a window of 4 chunks
  (1 MiB) in flight. `NWConnection` then paces to the tunnel. Also: when the host's
  `AdaptiveController` sees rising RTT during a transfer, it will cut video bitrate. That's
  acceptable, and arguably correct. Optionally cap the file rate at ~70% of recent throughput.
- **Resumability:** the receiver writes `…/<id>.partial` plus a sidecar `{name, byteCount, received}`.
  On reconnect, the sender re-offers the same `id`, and the receiver answers `resumeOffset =
  received`. Chunks are written at explicit offsets, so duplicates are idempotent. SHA-256 is
  verified at the end (incrementally, while writing). Partial files expire after 24 h.
- **Destinations:**
  - Mac: `~/Downloads` (the host is unsandboxed). Uniquify names ("Report 2.pdf"). Set the quarantine
    attribute: add `LSFileQuarantineEnabled = YES` to the host Info.plist, or set
    `com.apple.quarantine` explicitly, so Gatekeeper treats received apps and scripts like browser
    downloads ⚠️. Post a notification with "Show in Finder".
  - iPad: the app's `Documents/Received` with `UIFileSharingEnabled` +
    `LSSupportsOpeningDocumentsInPlace`, so files appear in **Files → On My iPad → Vantage** (the
    same as Screens' `Screens › Downloads`). Offer a share sheet on completion.
- **Entry points:**
  - iPad **Files picker** (`UIDocumentPickerViewController`, multiple selection) from the session
    menu. Smallest to build.
  - **Drag and drop onto the remote view** (`UIDropInteraction` on `RemoteInteractionView`, or
    `.onDrop` on the SwiftUI container). Accept `public.item` and upload to `~/Downloads`. Dropping
    "at the cursor into a Finder window" is Screens-level polish and out of scope.
  - **"Send to Mac" from other apps without a share extension:** declare `CFBundleDocumentTypes`
    for `public.data` with `LSHandlerRank = Alternate`. Vantage then shows in the share sheet's app
    row ("Open in Vantage"), receives the file URL, and queues it for the connected Mac (or the last
    Mac, connecting on demand). A real **share extension** would need the device identity and
    catalog shared through an App Group or keychain access group. `CLAUDE.md` notes the personal
    team can't sign App Groups, so **defer the extension until the paid team exists**.
  - **Host menu bar "Send to iPad…"**: sends over the live session if one exists. Otherwise it falls
    back to Taildrop (§C.1).
  - Remote → iPad by dragging a file off the Mac's screen needs drag detection on the Mac (Screens
    requires macOS 14+ for this). Out of scope.
- **UI:** a Transfers popover (per-file progress, cancel, "Show"), plus a guard when disconnecting
  mid-transfer ("Files are still transferring…"), mirroring Screens' strings in
  `product-and-host-lifecycle.md` §1.9.
- **Background (iPad):** a foreground-only transfer is fine for v1. `BGContinuedProcessingTask`
  (iOS 26) is the modern way to let a user-started upload finish after backgrounding. ⚠️ Check its
  constraints before promising it.

### C.4 Effort (honest)

| Piece | Effort |
|---|---|
| Taildrop "Send to iPad" (host) + share-sheet "Send to Mac" (client) | **S** (~½ day) |
| Second connection + `attachMedia` binding + token | S–M |
| Offer/accept/chunk/complete protocol + tests (loopback mock host, like the existing client tests) | M |
| Resumability + hashing + partial cleanup | S–M |
| Client UI: picker, drop target, document types, Transfers popover, Files-app visibility | M |
| Host UI: Send to iPad, notifications, Downloads naming, quarantine | S |
| **Total, native transfer** | **M–L, about 5–7 days** to be solid. Given Blip and Taildrop, **low value per day** |

---

## D. Protocol additions (consolidated)

All additions are **capability-gated**. `Frame.Header.decode` throws `FrameError.unknownKind` for
any unknown raw kind (✅ `Frame.swift`), and the session dies. The host also rejects any
`protocolVersion` mismatch (✅ `HostSession.handshake`). So keep `version = 2` and add optional
fields:

```swift
// Hello (client → host), optional so old hosts decode it
var features: ClientFeatures?        // { macAudio: Bool, dictation: Bool, fileTransfer: Bool }
// HostCapabilities (host → client), optional
var audio: Bool?                     // SCK or tap audio available
var dictationEngines: [String]?      // ["apple", "macwhisper"] — "macwhisper" iff mw is found and `mw version` succeeds
var fileTransfer: Bool?
```

| Kind | Raw | Dir | Enc | Purpose |
|---|---|---|---|---|
| `audioRequest` | 63 | c→h | JSON | enable/disable Mac audio, mute preference |
| `dictationControl` | 64 | c→h | JSON | `begin{id, engine, locale, format}` / `commit{id}` / `cancel{id}` |
| `audioConfig` | 73 | h→c | JSON | codec, rate, channels, frames per packet |
| `dictationResult` | 74 | h→c | JSON | `{id, text, isFinal, engine, error?}` |
| `fileOffer`…`fileCancel` | 80–84 | both | JSON | §C.3 |
| `audioPacket` | 102 | h→c | bin | Opus packets |
| `fileChunk` (h→c) | 103 | h→c | bin | §C.3 |
| `micAudio` | 123 | c→h | bin | PCM16 16 kHz dictation audio |
| `fileChunk` (c→h) | 124 | c→h | bin | §C.3 |

As built (Mac audio): `audioConfig` also carries `bitrate` and an optional `unavailable` reason
(capture failed, no permission), sent instead of packets; `audioPacket` is
`sequence u64 | captureNanos u64 | frameCount u16 | opus`.

The root `Package.swift` test target lists client sources one by one (`CLAUDE.md`). New
`Model`/`Net` files for dictation and transfer must be added there, or the loopback regression tests
won't see them. Add loopback tests for: dictation round-trip against a stub `mw`, and file offer →
resume → hash verify.

**Privacy and security notes:** mic audio and transcripts are sensitive. Log them only with
`privacy: .private`. Delete WAVs right after transcription. Never pass `--persist`. Only accept
`micAudio` between a `begin` and a `commit`/`cancel` for a known id, and cap clip length (e.g.
5 min = 9.6 MB at 256 kbps). Host-side typing goes through the same `InputInjector` rules and Secure
Input check as `textInput`.

---

## E. Open questions to settle on hardware

1. Does the keyboard dictation mic appear in `RemoteKeyboardField`, and what do its `insertText` and
   `deleteBackward` calls look like during live revision? (B.0)
2. iPad: `SpeechTranscriber.isAvailable`, the en-US asset download size and time, and whether
   `AssetInventory` status reaches `.installed` after `reserve` + install. (B.1)
3. Is iPad on-device `SpeechTranscriber` accuracy on real (not TTS) speech good enough for Stage 1
   to satisfy Drew, or does he go straight to MacWhisper? (B.1, B.4)
4. Does `mw transcribe` stay ~2 s warm while MacWhisper sits idle for hours, or does it unload the
   model (the cold cost was 10.8 s)? Is a keep-warm ping needed? (B.4)
5. SCK audio: callback buffer size, whether a display filter captures all apps' audio including
   ones whose windows are on another display, and whether capture continues with AirPods as output.
   (A.1)
6. Does iOS decode AudioToolbox Opus on device (confirmed only in the 26.5 simulator)? (A.2)
7. Does a global Core Audio tap with `CATapMutedWhenTapped` silence every process's output? (A.6)
8. Do CGEvents posted at `.cgSessionEventTap` trigger MacWhisper's push-to-talk key? (B.3)

---

## Sources

**SDK headers (Xcode 27.0, 27A266a)**
- `MacOSX27.0.sdk/System/Library/Frameworks/ScreenCaptureKit.framework/Headers/SCStream.h`, `SCError.h`, `SCRecordingOutput.h`
- `MacOSX27.0.sdk/System/Library/Frameworks/CoreAudio.framework/Headers/CATapDescription.h`, `AudioHardwareTapping.h`, `AudioHardware.h`, `AudioServerPlugIn.h`
- `MacOSX27.0.sdk/System/Library/Frameworks/AudioToolbox.framework/Headers/AUAudioUnit.h`, `AudioUnitProperties.h`
- `iPhoneOS27.0.sdk/System/Library/Frameworks/Speech.framework/Modules/Speech.swiftmodule/arm64e-apple-ios.swiftinterface`
- `iPhoneOS27.0.sdk/System/Library/Frameworks/AVFoundation.framework/Headers/AVSampleBufferAudioRenderer.h`, `AVSampleBufferRenderSynchronizer.h`
- `iPhoneOS27.0.sdk/System/Library/Frameworks/AVFAudio.framework/Headers/AVAudioSession.h`, `AVAudioSessionTypes.h`, `AVAudioIONode.h`

**Local probes (scratchpad, not committed)**: AudioToolbox encoder/decoder enumeration and
`AudioConverter` property readback (macOS 27 and the iOS 26.5 simulator); `SpeechTranscriber` and
`DictationTranscriber` locale, format, asset, and preset queries plus file transcription (macOS 27);
the MacWhisper 14.8.1 bundle (`Info.plist`, `Metadata.appintents/extract.actionsdata`, binary strings,
`mw help`, `mw models list`, timed `mw transcribe`); `/Library/Audio/Plug-Ins/HAL` and
`system_profiler SPAudioDataType`; `tailscale file cp --help` / `--targets` (Tailscale 1.102.4).

**Apple**
- [NSAudioCaptureUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nsaudiocaptureusagedescription)
- [Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
- [Meet ScreenCaptureKit, WWDC22-10156](https://developer.apple.com/videos/play/wwdc2022/10156/)
- [UIKeyInput](https://developer.apple.com/documentation/uikit/uikeyinput); [Forums 746678: dictation in custom text views since iOS 16](https://developer.apple.com/forums/thread/746678)

**MacWhisper**
- [How to use the Dictation feature](https://docs.macwhisper.com/article/14-how-to-use-the-dictation-feature)
- [MacWhisper Command-Line Tool](https://docs.macwhisper.com/article/57-macwhisper-command-line-tool)
- [How to use the Global feature](https://docs.macwhisper.com/article/16-global)

**Audio drivers**
- [ExistentialAudio/BlackHole](https://github.com/ExistentialAudio/BlackHole)

**Tailscale**
- [Taildrop](https://tailscale.com/docs/features/taildrop)
- [macOS and iOS Shortcuts](https://tailscale.com/docs/features/mac-ios-shortcuts)
- [TailSync (third-party PeerAPI client)](https://github.com/SohelIslamImran/TailSync)

**Blip**
- [Blip security page](https://blip.net/security) (via search snippet; direct fetch returned 403)
- [HN launch thread 44648772](https://news.ycombinator.com/item?id=44648772)
- [BigGo news summary of the P2P/privacy debate](https://biggo.com/news/202507230125_Blip_File_Transfer_Debate)

**Third-party technical write-ups**
- [DGR Labs: Capturing system audio on macOS in 2026](https://dgrlabs.co/blog/2026-04-25-capturing-system-audio-on-macos-in-2026.html)
- [Blake Crosley: SpeechAnalyzer vs SFSpeechRecognizer](https://blakecrosley.com/blog/speech-framework-vs-sfspeechrecognizer)
- Axiom skills `axiom-ai/skills/ios-ml.md` (SpeechAnalyzer resource cap, iOS 27 input providers)
