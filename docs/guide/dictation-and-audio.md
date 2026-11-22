# Dictation and the computer's sound

Part of the project guide; [`CLAUDE.md`](../../CLAUDE.md) has the naming, layout and repo rules this assumes.

- **Dictation** (`Vantage/Dictation`, `VantageHost/Dictation`, design in
  `docs/research/audio-dictation-files.md` §B/§D): the strip's mic button (hold to talk, tap to
  toggle) opens `DictationPanel`. Its header is the status and clock on the left and, on the
  right, History (a clock), Pause or Resume, and Stop; the engine's name shows only once there is
  text and only when it says something (the Mac's engine, or this device's Parakeet), never
  while recording (Drew: "On this iPhone" beside Stop was clutter). "On this iPad" runs `SpeechAnalyzer` (`LiveTranscriber`,
  downloads the locale model via `AssetInventory`); "On the Mac (MacWhisper)" streams 16 kHz PCM16
  as `micAudio` (123) between `dictationControl` (64) begin/commit, and the host writes a temp WAV,
  runs `mw transcribe --language xx`, deletes the WAV, and answers `dictationResult` (74), falling
  back to macOS SpeechAnalyzer. All three kinds are capability-gated: the client says
  `Hello.features.dictation`, the host lists `HostCapabilities.dictationEngines`, and the client
  uses the Mac only when that list contains `macwhisper` (older hosts drop the session on unknown
  kinds). Text arrives as `textInput`; the host types up to 16 UTF-16 units and pastes anything
  longer (`ClipboardBridge.paste`: this-Mac-only, transient-marked, ⌘V, the old clipboard back
  after 1.5 s unless something was copied meanwhile, never synced to the client). Never go back to
  typing long text: a burst of Unicode key events drops keys in Chromium and Electron apps (a
  98.7 s dictation lost letters mid-word; a 1,111-character burst kept only 32 in Chrome). Never log transcripts except `.private`.
  **Startup**: the Mac route sends `begin` and opens the mic as soon as mic permission is known;
  the on-iPad preview prepares alongside and attaches when ready, fed from the 16 kHz uplink with
  the audio so far replayed. Never make the Mac route wait for `LiveTranscriber.make` again: its
  first call per launch can take many seconds on a device (the old 20 s "Getting ready…"). `make`
  shares one in-flight preparation per locale, and a cancelled attempt leaves its transcriber as a
  spare. Stage timings log as "dictation start (…)" and "speech transcriber …" (category
  `dictation`). **Clip end**: the mic stays open `captureTail` (400 ms) after stop while the panel
  already says Transcribing; `MicrophoneCapture.stop()` drains the `AudioResampler`s with
  end-of-stream (a 48→16 kHz converter holds ~30 ms); the host appends 0.5 s of silence before any
  engine (`HostTranscriber.paddedForTranscription`). Tests:
  `Tests/HostDictationTests` (stub `mw`; `VANTAGE_TEST_REAL_MW=1` runs real MacWhisper and Apple on
  `say` speech).
  **Built-in Parakeet** (optional, off by default): Casement Host → Settings → Dictation toggles
  `ParakeetModel` (`VantageHost/Parakeet`, FluidAudio 0.16.x, Parakeet TDT v3 on Core ML). Turning it on downloads ~490 MB to
  `~/Library/Application Support/Vantage Host/Models/parakeet-tdt-0.6b-v3` (Remove deletes it and
  the ~40 MB Core ML cache); nothing touches the network while it's off, and loading uses
  `AsrModels.loadLocal`. The host advertises `parakeet` only while it's on and downloaded
  (`BuiltInSpeechEngines.shared`), warms it at launch/after download (first-ever load compiles
  for the ANE, ~18 s; later ~0.4 s), and a clip that arrives mid-warm-up waits ≤20 s, then falls
  back. **Which engine is the Mac's choice**: host Settings → Dictation → Engine
  (`dictation.engine`, `HostTranscriber.preferredEngineKey`; empty = Automatic = MacWhisper →
  Parakeet → Apple). `availableEngines()` lists that one first, and the client's only choice is
  "On the Mac" or "On this device" (`DictationEnginePreference`; an old saved `parakeet` decodes
  to the default `.mac`): `DictationRoute` takes the host's first engine whenever it has
  MacWhisper or Parakeet. The host tries the client's `DictationControl.engine`, then Settings'
  choice, then Automatic's order (`HostTranscriber.order(requested:preferred:)`); the result names
  the engine and the panel labels it. Settings rows put values and buttons on the trailing edge
  (the Parakeet model's state, size and Download/Cancel/Remove share one row). `ParakeetRuntime` sits behind
  `BuiltInSpeechEngine`, which the SPM host tests stub (the root package never builds FluidAudio).
  `--open-settings dictation` (DEBUG) opens the host's Settings in a window for screenshots. Debug: `-VantageDictationFixture listening|paused|review|macTranscribing|macReview|failed|download`
  shows the panel without the mic; `-VantageDictationSpeak "text"` sends TTS audio through the whole
  Mac path in the simulator against a real host (a synthetic host has had no dictation since the
  2026-11-07 session split, so there it reports "No Clip Engine"), or through
  this device's Parakeet when the route resolves there (`-vantage.dictationEngine iPad` with its
  model installed).
  **Pause and Resume** (`DictationController.pause()`/`resume()`, `Phase.paused`): Pause freezes
  the clock (`elapsedBeforePause`, `elapsed(at:)`), closes the microphone after the same
  `captureTail` as Stop (so Mac audio comes back and the mic indicator goes out), and keeps
  everything else open: the transcript, the uplink stream, the on-device analyzer, and on the
  Mac route the Mac's open clip (no audio arrives, so its five-minute cap doesn't run). Resume
  starts a new `MicrophoneCapture` into the same stream and analyzer (`openMicrophone()`; a
  stopped capture has flushed its converters and can't restart). Stop, Send and Send + Return
  work from Paused; a strip tap or ⌃⌥⌘D while paused resumes; a lost connection treats Paused
  like Listening. Opening the history pauses a live recording. Pause and Resume with a real
  microphone still need a device check (fixtures only so far).
  **Dictation History** (`Model/DictationHistory.swift`, `UI/DictationHistoryView.swift`): the
  last 30 texts sent or copied (`DictationHistory.shared`, added in the model's `deliver`,
  `resendDictation` and `dictationCopied`; a repeat moves to the top), in
  `Application Support/Vantage/dictation-history.json` with complete file protection on iOS,
  left out of backups, never synced, never logged. The panel's clock and the session menu's
  Dictation History… (under Files & Clipboard on a phone; Session menu on the Mac) open the
  sheet: Copy and Send per row (Send types it again and is dimmed while the computer can't take
  typing). Settings → Controls → Save Dictation History (`vantage.dictationHistory`, on by
  default) hides both entry points when off and deletes the file; Clear History… asks first. A
  process without the app's bundle id (the package tests) writes a scratch file instead.
  **Parakeet on this device** (`Vantage/Dictation/OnDeviceParakeet.swift`, iOS, iPadOS and macOS):
  the same Parakeet v3 as the host's, for dictation that stays on the device (a PC, a Mac with
  only Apple's engine, or "On this iPad"). `DictationRoute.resolve(…hasOnDeviceParakeet:)` returns
  `.onDeviceParakeet` in place of `.iPad` while `OnDeviceSpeechEngines.parakeet` is set, which
  `OnDeviceParakeet` does only when the model is installed and Use Parakeet is on. The route
  records like the Mac one (16 kHz uplink into `localClip`, Apple's live preview attached when
  Speech is already authorized) and transcribes when listening stops; if Parakeet fails, the
  preview's text is used, else the panel says so. Settings → Controls → "On This iPad" holds
  one row (size, Download / Cancel / Remove; Download asks first on cellular or a hotspot) and,
  once installed, Use Parakeet (`vantage.onDeviceParakeet`). Nothing touches the network until
  Download (`AsrModels.download`, Hugging Face, resumes from the bytes on disk); the model lives
  in `Application Support/Vantage/Models/parakeet-tdt-0.6b-v3`, left out of backups; Remove
  deletes it and Core ML's compiled cache. After a download it is loaded once (Core ML's
  compile), and from then on `OnDeviceParakeetRuntime` loads it when a dictation starts
  (`prepare()`), waits up to 45 s for a clip, and lets it go two minutes after it was last
  wanted or on a memory warning, so it holds no memory between dictations. The dictation
  controller only knows the `OnDeviceSpeechEngine` protocol: the root package never builds
  FluidAudio, and the visionOS app leaves it out (FluidAudio declares macOS and iOS only, and
  its bundled `NemoTextProcessing` binary has no visionOS slice), so the client's FluidAudio
  build file carries `platformFilters = (ios, macos, )` and everything Parakeet sits behind
  `#if canImport(FluidAudio)`. Keep that filter unless visionOS has been built and tried.
  **The package's default trait is off** (`traits = ( );` on its package reference in the
  project file, which Xcode 26.4 and later read): `NemoTextProcessing` is a text-normalization
  engine for FluidAudio's text-to-speech that speech recognition never calls, and it added
  8.4 MB to the iPhone app (Release binary 26.5 MB with it, 18.1 MB without) and as much to
  Casement Host. Never turn it back on for dictation. What's left of FluidAudio costs the
  client about 4.3 MB of code plus a 1 MB text-to-speech lexicon bundle it copies in, unused.
  A build folder made before the trait went off fails once on a missing
  `CNemoTextProcessing/module.modulemap`: delete that configuration's products and
  intermediates and build again. Checked in
  the iPhone simulator with the host's model files copied in (this Mac's network filter keeps a
  simulator app from Hugging Face, so the download there ended in the "didn't finish" row):
  synthesized speech came back from Parakeet, and Remove deleted the files. The download on a
  device, memory on an older iPhone, and the Mac client's copy are still unchecked.
- **Mac audio** (design in `docs/research/audio-dictation-files.md` §A/§D): host `AudioCapture`
  (its own SCK stream, not the video one, so resizes don't drop it; audio only, 2×2 video to a
  no-op `.screen` output, own process excluded) → `AudioRepacketizer` (fixed 480-frame/10 ms
  blocks; a timestamp jump starts a new timeline) → `AudioEncoder` (Opus via `AVAudioConverter`,
  `mFramesPerPacket` 480, 128 kbps, own serial queue) → `sendDetached`. Kinds: `audioRequest` (63,
  c→h), `audioConfig` (73, h→c; `unavailable` carries a user-facing reason), `audioPacket` (102,
  `seq u64 | captureNanos u64 | frameCount u16 | opus`). Gated both ways: the client sends
  `audioRequest` only when `HostCapabilities.audio == true`, the host answers only a client with
  `Hello.features.macAudio`, and audio is off until asked. Client: `ClientSession.setMacAudio`
  (re-asks on every reconnect) → `MacAudioPlayer` (decode queue → `AudioJitterBuffer`, a lock-free
  SPSC ring pulled by an `AVAudioSourceNode`; target 40–80 ms, +10 ms per late underrun, −4 ms per
  10 s clean; a host pause (timeline jump) isn't counted; one-frame stretch/squeeze outside target
  ±15 ms; bursts > target+90 ms cut back with a crossfade (a skip); a backlog that size found
  before playback starts begins at the target instead (`startTrims`); fades on dry-out). `.playback` +
  `.mixWithOthers`; `DictationController.onMicrophoneActive` pauses output before the mic takes
  `.playAndRecord` and resumes after it lets go. `AudioOutputSetup` activates (and deactivates) the
  session and starts the engine on its own queue; never move that back onto the main actor: every packet
  reaches the player through it, so the 100–200 ms start queued the Mac's first audio into a
  burst that landed just after playback began and was cut back with an audible skip. A stop
  during a start, and the mic taking over, wait for that queue, so the session never changes
  under the mic. A Windows host (1.3+) sends the same kinds; the client names the toggle after the
  host ("PC Audio") and gates it on `HostCapabilities.audio` only. Per Mac or PC: `SavedDevice.playMacAudio`
  (`DeviceStore.setPlayMacAudio`); strip item `macAudio` + session-menu toggle; a failure shows
  `MacAudioNotice` and the toggle retries. `ControlStripLayout.upgradeSavedLayouts` moves layouts
  saved as an older standard (the editor saves the full list even on Reset) to the new one once;
  add to `standardHistory` whenever the standard gains a control. Stats log every 10 s (`audio`
  category, both sides). Debug: `-VantageMacAudio 1|0` overrides the saved choice and adds an
  invisible `session.macAudioStats` element (`latency` is the smoothed depth the buffer steers
  by) for `SessionUITests.testMacAudioToggleStreamsTheMacsSound`;
  the synthetic host streams a −18 dBFS two-note chime (`SyntheticAudioSource`). Some simulators
  can't reach CoreAudio ("there is no system object", engine start −10851); DEBUG simulator builds
  then play into `NullAudioOutput` so the rest of the path still runs. Out of scope on purpose:
  muting the Mac (needs a Core Audio process tap and its own TCC prompt), background audio (a
  separate decision: `UIBackgroundModes` audio would keep the session alive and has App Review
  implications), and UDP. Still needs hardware: real SCK audio, AirPods, drift over hours.
