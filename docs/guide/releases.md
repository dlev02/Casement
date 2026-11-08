# App Store, releases and versions

Part of the project guide; [`CLAUDE.md`](../../CLAUDE.md) has the naming, layout and repo rules this assumes.

- **In the app**: About links Source Code, Privacy Policy, and Report a Problem (`AppInfo`
  `githubURL`/`privacyURL`/`supportURL`; the repo has been public since 2026-10-11). The
  Ko-fi donation link lives only on GitHub: App Review guideline 3.1.1 rejects in-app links that
  take money outside in-app purchase, so never add it to the app.
- **App Store readiness**: `Vantage/PrivacyInfo.xcprivacy` declares UserDefaults (CA92.1), file
  timestamps (C617.1, 3B52.1: `FileTransferEngine`'s partials and user-picked files), disk space
  (E174.1: the free-space check before a receive), and system boot time (35F9.1: uptime clocks for
  latency); the widget's declares UserDefaults. Add a category whenever code starts using another
  required-reason API. `ITSAppUsesNonExemptEncryption = NO` (both Vantage configs): all crypto is
  Apple's (CryptoKit, CommonCrypto for the ARD login) and used for authentication and integrity.
  Vantage Host can't be on the Mac App Store (unsandboxed, CGEvent injection); it ships as a
  notarized Developer ID download.
- **Releases and versions**: version numbers live only in the pbxproj (`MARKETING_VERSION` and
  `CURRENT_PROJECT_VERSION` per target; the client and widget share one pair, the host has its
  own) and a bump is its own commit ("Set build N for the App Store"). The client ships through
  App Store Connect (one universal record for iOS, macOS and visionOS; TestFlight first): the
  listing, review notes, privacy answers, screenshot sets and the `asc` metadata files are in
  `docs/app-store/` (`README.md` is the index; `python3 -I docs/app-store/check-lengths.py`
  counts every limited field). Casement Host ships on GitHub Releases tagged `host-x.y`
  (notarized Mac DMG and zip plus the Windows Setup files and zips, with SHA-256 checksums; `v1.0` was the first). From
  1.4 a Windows release also needs its signed `windows-update.json` and `.sig` (see Updates in [windows-host.md](windows-host.md))
  and a Mac release its signed `appcast.xml`, which `scripts/make-mac-release.sh <version>` makes along with
  the DMG, zip and checksums (see Host updates in [mac-host.md](mac-host.md)). It notarizes with the App Store Connect API key in
  `ASC_PRIVATE_KEY_PATH`, `ASC_KEY_ID` and `ASC_ISSUER_ID` (`--throwaway` makes a test run of any version).
  Device delivery logs go in `docs/testing/<date>.md`. `.github/workflows/issue-fix.yml`
  hands each new bug report (or an issue labelled `fix-this`) to Drew's "Bug report to draft
  PR" routine, which may open a draft PR from `fix/issue-<n>`; nothing there merges.
