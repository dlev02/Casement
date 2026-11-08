# Coding standards

The standard a diff is reviewed against, by `/code-review` or anyone reading a pull request.
Implementation details live in the project guide; this file holds the judgement calls a reviewer makes.

## How to review a diff

1. **Area rules.** For every area the diff touches, open its guide from the Topic guides table in
   `CLAUDE.md`. Each "never", "always" and "don't" there is a standard. Cite the guide and the rule.
   A diff that changes what a guide describes and leaves the guide alone is a finding.
2. **Cross-cutting rules.** Apply every section below to the whole diff.
3. **Leave the mechanical rules to `scripts/lint.sh`.** CI and the git hooks run it: personal details,
   AI mentions in commit messages, `print`, pointer lock, `minimumIncompleteLength`, `tccutil`,
   `kSecAttrAccess`, Ko-fi in the app, `Host.current()` in the client. Report a rule here only when a
   diff gets around the script. A judgement call that turns out to be mechanical belongs in the script.
4. **Decisions.** A change that contradicts an ADR in `docs/adr/` says so and why it's worth reopening.

## Words people read

- **Glossary.** UI text, help, errors, issues and code names use `GLOSSARY.md`'s terms:
  - the **device** is what the person holds; the **computer** is the Mac or PC they control;
  - say **Casement Host** (never "the host" on its own), **control strip**, **screen**, **display**;
  - name a computer by platform through `HostNoun`, and the local device through `LocalDevice`
    ("tap" on iOS, "click" on the Mac, "this iPad" or "this Mac").
- **Copy.** Each screen carries its own meaning. A tagline, helper line or secondary label added to
  explain a layout is a finding; fix the layout, hierarchy or name instead. Required setup steps,
  accessibility labels, and errors that explain a recoverable failure keep their words.
- **Errors** say what happened and what to do next, in the computer's name ("Update Casement Host on
  the PC"). A message that only says something failed is a bug.
- **English only for now** (ADR-0002). Text stays localisable: SwiftUI string literals or
  `String(localized:)`, and whole sentences rather than sentences joined from fragments.
- **Voice.** Docs, release notes and commit messages are in Drew's first person ("I"), with plain,
  changelog-style commit titles.

## Apple interfaces: iPhone, iPad, Mac, Vision Pro

- **Native first.** SwiftUI and system components, following the HIG. UIKit and AppKit only where
  SwiftUI can't (the input views, the display layer), bridged the way the existing code bridges them.
  For design questions reach for Axiom (`axiom-design` for the HIG, Liquid Glass and SF Symbols).
- **Liquid Glass.** Controls float on glass; content doesn't.
  - One glass surface per control: buttons on a glass card use `.onCard` / `.onCardProminent`.
  - One prominent action per screen.
  - A shape that changes morphs (one `glassEffectID`) rather than swapping.
  - visionOS has no Liquid Glass: use `platformGlass(in:)` and `rowButtonStyle(in:)`.
- **Colour.** System semantic colours and the system accent; colour carries meaning (green ready,
  orange needs attention, red destructive). The brand palette (plum and lavender for Casement, slate
  for Casement Host) belongs to the icons and store art, per `brand/README.md`. A new hard-coded
  colour needs a reason in the diff.
- **Type and size.** Dynamic Type text styles. Layouts hold at accessibility sizes: rows wrap rather
  than truncate.
- **Every platform the view reaches.** A change to a shared view is judged on each platform it
  reaches:
  - iPhone, where either size class is compact (the short session menu);
  - iPad;
  - iPhone Duo, half folded, when the screen session is involved;
  - the native Mac app: Settings at ⌘,, every action in the menu bar, items dimmed rather than hidden;
  - the iPad app on a Mac;
  - visionOS: ornaments, gaze highlights shaped like their cell, Look to Scroll.
  `#if os(…)` carries layout; behaviour lives in shared code.
- **Accessibility.**
  - Every control has a label.
  - The remote screen is one element ("Screen of ⟨name⟩").
  - Banners are combined and announced; VoiceOver hears one announcement per event, never per
    progress tick.
  - Reduce Motion gets opacity instead of movement.
- **Motion and feedback.**
  - Springs match the surrounding code.
  - Haptics name a moment from `Haptic` (latch, snap, success…) and never play for pointer motion,
    scrolling, typing or plain taps.
- **Settings** (Casement Host on Mac and Windows, and Casement's own):
  - a row says what it is, with at most one short line beneath it;
  - anything longer goes in the section footer;
  - values and buttons sit on the trailing edge;
  - a button names what it does in the current state (Allow…, Turn On…).

## Windows interfaces

- **Windows 11's own language** (Settings and Quick Settings), never a Mac design ported over:
  - WinUI 3 with the Community Toolkit's `SettingsCard` / `SettingsExpander`;
  - Mica on the window, the tray panel flat on acrylic, no card on a card;
  - sentence-case buttons, label on the left and control on the trailing edge, 4 between cards and
    24 above a heading.
- **Lists** rebuild only when what they show changes, so keyboard focus survives a busy transfer.
- **Checking it.** A change to the window or panel is checked with the DEBUG `--capture` render; a
  screenshot of a composed WinUI window comes out black.

## Shape of the code

- **Deep modules.** Speak `codebase-design`'s vocabulary. New behaviour goes into the module that
  owns it: a screen session's rules into the session model, capture into the capture lifecycle
  module, the handshake into admission. It doesn't go into a SwiftUI view or a session actor. A
  pass-through layer that fails the deletion test is a finding.
- **Concurrency** (Swift 6, default MainActor; `axiom-concurrency`):
  - work is off the main actor only where it says so (`nonisolated`, `@concurrent`, its own queue);
  - nothing blocking runs on an actor or the main thread (subprocesses, DNS, `DispatchQueue.main.sync`);
  - every `Task` has an owner that cancels it at teardown;
  - an actor re-checks its state after each `await` before acting on it.
- **Both hosts.** A change to screen session behaviour on one host is made on the other host too, or
  the pull request says why not.
- **The wire.** A wire change updates the Swift and C# sides together, the golden vectors on both
  sides, and `docs/research/windows-host-protocol.md`.
- **Older peers keep working.** New behaviour is gated on what the peer advertises (`Hello.features`,
  `HostCapabilities`), never on a guessed version. Decoding tolerates unknown values. A missing
  optional means the old behaviour.
- **Saved state survives** (ADR-0003). Defaults keys, Keychain services, on-disk paths and the
  `vantage://` scheme keep their names. A new stored field decodes from data saved without it. Saved
  layouts and choices migrate (`standardHistory`, `upgradeSavedLayouts`) rather than reset.
- **Lean.** Events over polling; work proportional to what changed (reconfigure only on a change);
  nothing allocated or logged per frame on the video, audio or input paths. A media feature sizes its
  images before they're stored or sent.
- **Package lists.** A new client Model, Net, Input, Audio or Transfer file is listed in the root
  `Package.swift`, or the tests can't see it.

## Security and privacy

- **Tailscale only** (ADR-0001). The listener accepts only tailnet ranges (loopback in DEBUG). No new
  listener, port, relay or discovery.
- **Authentication.**
  - Transcripts change only by a new version that older peers still negotiate.
  - The host proves its key before the client signs anything or sends a pairing code.
  - A signature is bound to its purpose (screen, probe, files).
  - The pairing code expires, and burns after five misses.
- **Secrets** live in the Keychain (when-unlocked), never in defaults, logs, URLs, command-line
  arguments or temp files. Transcripts, clipboard contents and passwords log only as `.private`.
- **The clipboard.** The Mac client reads it only on the person's action. What a password manager
  marks private never leaves the computer.
- **Input.** Every held key and button is released on every way a session ends.
- **Files.**
  - Names are sanitised.
  - A file is written to a partial and renamed, never written in place.
  - Downloads on the Mac are quarantined.
  - Sizes are checked before writing.
- **New outside contact.** A new network destination or stored secret updates `PRIVACY.md`, the
  FAQ's privacy answers and `docs/app-store/privacy-nutrition-label.md` in the same change. A newly
  used required-reason API updates `PrivacyInfo.xcprivacy`.
- **Nothing personal** in tracked files, including test fixtures and research notes.

## Diagnostics

- Swift logs through `os.Logger` with the project's subsystem and the area's category (`files`,
  `dictation`, `session`, `input`, …); C# through `ILogger`.
- Every boundary that can fail logs what it touched, the status or error code, and how long it took.
- A fallback taken is logged.
- A bug that the logs couldn't explain gets the missing logging in the same fix.

## Updates, releases and distribution

- **Signatures stay checked.** Both hosts' updates are signed (Sparkle's EdDSA feed and download
  checks on the Mac; the signed manifest and zip hash on Windows). A diff never relaxes a signature
  check, never adds a way around it, and never puts a private key near the repo.
- **Unattended installs** follow `UpdatePolicy` on both hosts: nobody connected, nothing moving, no
  window open, for five minutes.
- **Versions.**
  - A version bump is its own commit.
  - Every host release raises `CURRENT_PROJECT_VERSION` on the Mac or the csproj version on Windows.
  - The client and widget share one version pair.
- **The App Store.**
  - Metadata stays within limits (`python3 -I docs/app-store/check-lengths.py`).
  - Review notes stay true to the build.
  - App Services and capabilities match what the code uses (an App Service missing on the App ID
    only fails at run time).
  - Donations stay off the app and its metadata.
- **Windows packaging.**
  - The per-user installer keeps its `AppGuid`.
  - The uninstaller lives outside the install folder.
  - The release script's architecture check passes.
- **Downloads outside a store** keep a one-gesture install (the DMG on the Mac, `Setup.exe` on
  Windows) and the updater from the first release on.

## Tests

- **Proof by running.** A change is proved by running it: the build, the app, the synthetic host, the
  interop suite. Interface and interaction changes are proved by looking at them.
- **Tests guard what's easy to break silently:** wire formats and golden vectors, authentication, file
  transfer and other data loss, parsers, and a bug that came back once. One focused test file per
  new deep module, through its interface.
- **Findings for the reviewer:**
  - a test that restates the diff;
  - a wire, authentication or data-loss change without one;
  - an existing test weakened to pass.

## Docs and history

- **Guides.** The guide for an area changes in the same commit as the behaviour it describes. A new
  term goes into `GLOSSARY.md`, and a hard-to-reverse decision into an ADR.
- **Commits.**
  - Author and committer `dlev <49005290+dlev02@users.noreply.github.com>`.
  - Titles a person using the app would understand.
  - No AI attribution.
  - In commit text, `CLAUDE.md` is "the project guide".
