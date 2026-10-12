# App Privacy (nutrition label)

**Answer: "No, we do not collect data from this app"**, which shows as **Data Not Collected**.
No tracking. No Privacy Choices URL is needed.

This was checked against the code on 2026-10-11, not assumed from PRIVACY.md. Apple defines
"collect" as transmitting data off the device in a way that lets **you (the developer) or your
third-party partners** access it for longer than it takes to serve the request in real time.
Casement sends nothing to the developer and has no partners (no SDKs). Everything that leaves the
device goes to the user's own computers or, at the user's request, to the user's own Tailscale
account.

## Evidence

### No third-party SDKs in the App Store app

- The `Vantage` target's only package dependency is the local `VantageCore` package
  (`project.pbxproj`: the `packageProductDependencies` of the `Vantage` target list only
  `VantageCore`). `Packages/VantageCore/Package.swift` has no dependencies.
- The only remote package, FluidAudio (Parakeet dictation), is linked into `VantageHost` only,
  which isn't on the App Store. It isn't in `Vantage` or `VantageWidgets`.
- grep across `Vantage/`, `VantageWidgets/`, `Shared/`, and `Packages/` for Firebase, Crashlytics,
  Sentry, Amplitude, Mixpanel, TelemetryDeck, Segment, AppCenter, Bugsnag, PostHog, MetricKit /
  `MXMetricManager`, `ASIdentifierManager` / `advertisingIdentifier`, `ATTrackingManager`,
  `identifierForVendor`, SKAdNetwork / AdAttributionKit, `CLLocation`, Contacts, and
  `PHPhotoLibrary`: **no hits**.
- `Vantage/PrivacyInfo.xcprivacy`: `NSPrivacyTracking = false`, `NSPrivacyTrackingDomains = []`,
  `NSPrivacyCollectedDataTypes = []`. The widget's manifest is the same.

### Everything that touches the network (client)

| Code | Destination | What and why | Counts as collection? |
| --- | --- | --- | --- |
| `Packages/VantageCore/.../Transport/MessageChannel.swift` (`NWConnection`), used by `Vantage/Net/ClientSession.swift`, `Vantage/Net/HostAvailability.swift`, `Vantage/Transfer/FileLink.swift` | The user's own computers running Casement Host, at addresses the user added, port 47820, over Tailscale | The session: video from the host; input, clipboard, files, dictation audio, and the device's public key and name to the host | No. It goes to the user's own device, not to the developer or a partner. |
| `Packages/VantageCore/.../ScreenSharing/ScreenSharingTyper.swift` | The user's own Mac, port 5900 (macOS Screen Sharing) | The saved Mac account name and password, only when the user taps Type Password or Log In with Screen Sharing | No (user's own device) |
| `Vantage/Net/TailscaleAPI.swift:181-210` (`URLSession`) | `api.tailscale.com`: `GET /api/v2/tailnet/-/devices`, and `POST /api/v2/oauth/token` for OAuth clients | The user's own Tailscale key or OAuth client, only after the user pastes one into Add from Tailscale. The returned device list stays on the device (cached in memory). | No. The user is authenticating to their own account with a service they chose, like a mail client signing in to the user's mail server. Tailscale isn't the developer's partner and gets nothing from Casement beyond the request itself. |
| `Link`s and `openURL` (`SettingsScreen.swift:36-39, 296`, `TailscaleAccountScreen.swift:124, 186`, `TailscaleReachability.swift:37-43`) | GitHub, drewlevinson.me, Tailscale's admin console, `tailscale://` | They open in Safari or the Tailscale app. Casement sends nothing itself. | No |

grep for `URLSession`, `URLRequest`, `NWConnection`, `WKWebView`, `SFSafariViewController`, and
`http(s)://` across the client found nothing else: no update check, no telemetry, no remote
config. The only hard-coded URLs are in the table above.

### Things that look like data but stay on the device

- Saved computers, settings, and the device-catalog JSON for widgets: UserDefaults and
  Application Support.
- The device identity key (Ed25519), the Tailscale key, and Mac passwords: Keychain. Optional
  iCloud Keychain sync is Apple's end-to-end-encrypted service, so the developer can't read it.
  Data synced by the user's own iCloud isn't "collected" by the developer.
- Dictation audio is transcribed on the device (SpeechAnalyzer) or sent to the user's own
  computer, and isn't kept.
- Logs use `os.Logger`. Transcripts are `.private` (CLAUDE.md, Dictation) and nothing is
  uploaded.
- Crash reports and analytics that users opt into in iOS Settings are Apple's and aren't declared
  by the developer.

### Casement Host (not on the App Store)

The label covers only the App Store app. For consistency with PRIVACY.md: the host downloads the
Parakeet model from Hugging Face only when the user turns it on, uses `tailscale whois` locally,
and sends nothing to the developer.

## In App Store Connect

`app-privacy.json` (next to this file) is the canonical declaration for `asc web privacy`. It was
applied to app 6821765234 on 2026-10-11 (one usage, `DATA_NOT_COLLECTED`; a re-plan shows no
changes) but **not published**. App Store Connect needs the answers published before submission;
for an app that isn't on sale yet, publishing changes nothing public until release:

```sh
asc web privacy plan --app 6821765234 --file docs/app-store/app-privacy.json   # expect no adds/deletes
asc web privacy publish --app 6821765234 --confirm
asc web privacy pull --app 6821765234                                          # publishState.published: true
```

## Keep it true

If any of these are ever added, the label and PRIVACY.md must change: a crash reporter or
analytics SDK, MetricKit payloads sent anywhere, a relay or server of ours, a feedback form that
posts somewhere, or a new network destination (CLAUDE.md: "a new destination or a new stored
secret means updating PRIVACY.md and the FAQ's Privacy answers").

## Related fields

- **Privacy Policy URL**: https://github.com/dlev02/Casement/blob/main/PRIVACY.md. It must be
  public before submitting; today it returns 404.
- **Privacy manifest** (required-reason APIs): already present. It declares UserDefaults CA92.1,
  file timestamp C617.1 and 3B52.1, disk space E174.1, and system boot time 35F9.1. Xcode's
  Generate Privacy Report on the archive should show no undeclared categories. Check once on the
  Release archive.
- **Accessibility Nutrition Labels** (optional for now, shown on the product page): Casement has
  real work behind VoiceOver (the remote picture is one labeled element with direct interaction;
  banners are announced), Larger Text (rows wrap at accessibility sizes), Dark Interface, and
  Reduced Motion (the transfer capsule fades only). Declare only what you've checked on each
  platform with the common tasks: connect, use the control strip, send a file. Leave out
  Sufficient Contrast, Captions, and Audio Descriptions unless they've been audited.
