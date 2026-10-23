# App Store submission kit: Casement

> **Snapshot:** this folder records how Casement 1.0 was prepared for the App Store in October 2026, before submission. Statuses and IDs below reflect that moment; 1.0 (build 2) was submitted for review on 2026-10-12 for iOS, macOS and visionOS.

Everything App Store Connect asks for, for the Casement client (formerly Porthole; code name
Vantage): one app record shared by iOS/iPadOS, macOS, and visionOS, with universal purchase.
English (U.S.) only. Drafted 2026-10-11 for Porthole, rewritten for Casement the same day and
pushed to App Store Connect as drafts (nothing submitted).

## The app record

| | |
| --- | --- |
| App | **Casement: Remote Desktop**, app id `6821765234` |
| Bundle id | `me.drewlevinson.casement` (UNIVERSAL). The project still builds `com.benjaminlevinson.vantage`; uploads need the new id, signed by the team that owns this record (`7BVMD7TA97`, not `PMX23WPLM5`). |
| SKU / primary language | `CASEMENT2026` / English (U.S.) |
| Versions (1.0, PREPARE_FOR_SUBMISSION) | iOS `61814775-bfbf-4882-8d86-4d1aac06a447`, macOS `8d9dd5fc-19da-4191-bf31-c315eb2d5f25`, visionOS `3e01bde7-cbe0-4497-af2a-6acc4b74788d` |
| App info | `f334eea8-33ae-46df-b2bf-ab6389a5c705` |

## Files

| File | What's in it |
| --- | --- |
| [`metadata.md`](metadata.md) | Name, subtitle, promotional text, keywords and why, description notes, What's New, URLs, copyright, categories |
| [`metadata/`](metadata) | The canonical `asc` files: `app-info/en-US.json` (name, subtitle, privacy policy URL) and `version/1.0/en-US.json` (description, keywords, promotional text, support and marketing URLs). Pushed to all three platforms. |
| [`app-privacy.json`](app-privacy.json) | The App Privacy declaration for `asc web privacy` (Data Not Collected) |
| [`privacy-nutrition-label.md`](privacy-nutrition-label.md) | Why Data Not Collected is right, with code evidence; Accessibility Nutrition Labels |
| [`age-rating.md`](age-rating.md) | Every questionnaire answer (2025 version) and the Unrestricted Web Access reasoning |
| [`export-compliance.md`](export-compliance.md) | Why `ITSAppUsesNonExemptEncryption = NO` is right and where it's set |
| [`app-review.md`](app-review.md) | Review notes (3,266 of 4,000 bytes), the Guideline 4.2.7 check, ranked App Review risks, the user-facing string sweep |
| [`pricing-availability.md`](pricing-availability.md) | Content rights, Free, territories (exclude China mainland), EU trader status, other App Information fields |
| [`screenshots.md`](screenshots.md) | Required sizes for iPhone, iPhone Duo, iPad, Mac, and Vision Pro, shots with captions, and the debug flags that stage each one |
| [`screenshots/`](screenshots) | The uploaded sets, one folder per display type; `iphone-duo/frames/` has the page, captures and script that make the iPhone Duo set |
| [`naming.md`](naming.md) | The rename research that chose Casement |
| [`check-lengths.py`](check-lengths.py) | Counts every limited field: `python3 -I docs/app-store/check-lengths.py` |

## At a glance

| Field | Value |
| --- | --- |
| Name | `Casement: Remote Desktop` (24 of 30) |
| Subtitle | `Control Mac & PC, privately` (27 of 30) |
| Keywords | `screen,sharing,computer,access,viewer,anywhere,keyboard,mouse,trackpad,file,transfer,private,laptop` (99 of 100 bytes) |
| Category | Utilities, then Productivity |
| Price | Free (USD 0, base territory United States), no IAP |
| Availability | 174 territories; China mainland off; available in new territories |
| App Privacy | Data Not Collected (applied, not yet published) |
| Age rating | 4+ (every answer None/No; Unrestricted Web Access: No) |
| Content rights | Does not contain, show, or access third-party content |
| Encryption | `ITSAppUsesNonExemptEncryption = NO` (in the build; nothing to set in App Store Connect) |
| Copyright | `2026 Drew Levinson` (each platform's version) |
| Support / Marketing / Privacy URL | `github.com/dlev02/Casement/issues`, `github.com/dlev02/Casement`, `…/blob/main/PRIVACY.md` (404 until the repo is public) |
| Review contact | Set on each version (the team's contact; kept out of this repo). Demo account: not required. |

## Counts (2026-10-11)

```
$ python3 -I docs/app-store/check-lengths.py
OK  name                    24 / 30 chars
OK  subtitle                27 / 30 chars
OK  promotionalText        169 / 170 chars
OK  description           3245 / 4000 chars
OK  keywords                99 / 100 bytes
OK  alt subtitle 1          24 / 30 chars
OK  alt subtitle 2          26 / 30 chars
OK  whatsNew (1.0.1+)      140 / 4000 chars
OK  review notes          3266 / 4000 bytes
keyword issues: none (13 terms)

$ asc metadata validate --dir docs/app-store/metadata --output table
metadata  info  no issues
```

## State in App Store Connect (read back 2026-10-11)

| What | Where | Read-back |
| --- | --- | --- |
| macOS and visionOS 1.0 versions | added beside iOS | `asc versions list --app 6821765234` shows all three, PREPARE_FOR_SUBMISSION |
| Name, subtitle, privacy policy URL | app info en-US | `asc metadata pull` matches `metadata/app-info/en-US.json` |
| Description, keywords, promo text, support and marketing URLs | each platform's version, en-US | `asc metadata pull` per platform: every field matches `metadata/version/1.0/en-US.json` |
| Copyright | each version | raw API: `copyright = "2026 Drew Levinson"` on IOS, MAC_OS, VISION_OS |
| Categories | app info | primary UTILITIES, secondary PRODUCTIVITY |
| Content rights | app | DOES_NOT_USE_THIRD_PARTY_CONTENT |
| Age rating | app info | every field NONE/false, override NONE; app info shows FOUR_PLUS |
| Price | price schedule | manual price USD 0.0 (proceeds 0.0), base territory USA |
| Availability | app | 175 territories: 174 available, CHN not; availableInNewTerritories true |
| App Privacy | web | one usage, DATA_NOT_COLLECTED; re-plan empty; **published: false** |
| Review details | each version | first and last name, email, and phone (same as the team's other app), demo account not required, notes equal to the block in `app-review.md` (3,266 bytes) |

`asc validate` per platform now reports only the expected blockers: no build attached, no
screenshots (both come later), plus an info note that App Privacy's publish state can't be checked
through the public API.

## Still to do

Needs a person:

1. **EU trader status (DSA).** All 27 EU storefronts show `TRADER_STATUS_NOT_PROVIDED`; the team's
   other app shows the same, so it isn't set at the account level. The Account Holder declares it
   in App Store Connect › Business (trader or non-trader; a trader's address, phone, and email are
   shown on EU product pages). See `pricing-availability.md`. It's a legal self-assessment.
2. **Publish App Privacy** when ready (not public until the app is released):
   `asc web privacy publish --app 6821765234 --confirm`.
3. **Trademark clearance** for Casement (`naming.md`) before announcing.

Blockers before submitting, in order:

1. **Make the repo public and publish a notarized Casement Host release** (Mac and Windows) at
   `github.com/dlev02/Casement/releases`. Privacy policy, support, marketing, About links, the
   review notes, and the Host download all point at GitHub. Then
   `asc metadata validate --dir docs/app-store/metadata --check-urls`.
2. **Builds** for all three platforms with bundle id `me.drewlevinson.casement`, attached to each
   version (`asc versions attach-build`). The app must say Casement everywhere a person sees it.
3. **Screenshots** for iPhone, iPad, Mac, and Vision Pro (`screenshots.md`).
4. **visionOS app icon.** The layered `.solidimagestack` doesn't exist yet. Add it, or delete the
   visionOS version (`asc versions delete --version-id 3e01bde7-cbe0-4497-af2a-6acc4b74788d`) and
   ship 1.0 without it.
5. **App Group for widgets** on the new bundle id (`Shared/DeviceCatalog.swift:15` still says
   `group.com.benjaminlevinson.vantage`), on the `Vantage` and `VantageWidgets` targets. If it
   isn't added, delete the sentence "On iPhone and iPad, Home Screen widgets and a Control Center
   control." from the description and push again.
6. **Demo video** on real devices (pairing, input, files, audio, dictation, Mac and Vision Pro),
   attached under App Review Information on each version. The review notes already say "The
   attached video shows…"; if there's no video, delete that paragraph and push the notes again
   (`asc review details-update`).

Changes in the app (file:line):

| Where | Change | Why |
| --- | --- | --- |
| `Vantage/Model/CloudSync.swift:39` | Reword "The device list itself waits on an App Store build — this copy of Porthole (now Casement) isn't signed for iCloud storage.", or add the iCloud Key-Value Storage capability so the case never appears. | It would show in the App Store build itself and reads as unfinished (2.1/2.2). |
| `Vantage/UI/DeviceListScreen.swift:305-308` | Add a "Get Casement Host" link (to `…/releases`) to the empty state. | A reviewer or new user without a host otherwise has nowhere to go (2.1, 4.2.3). |
| `Vantage/Net/TailscaleReachability.swift:35-38` | When `tailscale://` doesn't open, open Tailscale's App Store page (`https://apps.apple.com/app/id1470499037`). | Today "Open" does nothing if Tailscale isn't installed on iPhone, iPad, or Vision Pro. |
| `Vantage.xcodeproj/project.pbxproj:454, 506` | `NSLocalNetworkUsageDescription`: "…connects to your Mac…" → "…connects to your Mac or PC…". | Accuracy; a PC works too. |
| `Vantage.xcodeproj/project.pbxproj:476, 528` | Add `INFOPLIST_KEY_LSHasLocalizedDisplayName = YES`, or set `PRODUCT_NAME = Casement` (keep `PRODUCT_MODULE_NAME = Vantage`). Check a Release Mac build in /Applications. | The Mac App Store installs `Vantage.app`; Finder and Launchpad may show "Vantage" while the store says Casement. |
| `VantageWidgets/VantageWidgets.swift:22-23, 87-91` (optional) | "Connect to Mac" / "One tap to your Mac" → mention PCs too. | Accuracy. |
| `README.md:41` (repo, not the app) | Replace "Porthole is in **beta**. For now you build it yourself…" with App Store and Releases links. | About › Source Code opens it; a reviewer reading "beta" invites 2.2. |

Optional, if App Review raises 4.2.3: an opt-in "Allow connections from my local network" in
Casement Host (today `VantageHost/Net/TailscaleListener.swift:59` accepts Tailscale addresses
only in Release), so the client works on a home network without the Tailscale app.

## Re-pushing

```sh
python3 -I docs/app-store/check-lengths.py
asc metadata validate --dir docs/app-store/metadata --output table
for p in IOS MAC_OS VISION_OS; do
  asc metadata push --app 6821765234 --version 1.0 --platform $p --dir docs/app-store/metadata --dry-run --output table
  asc metadata push --app 6821765234 --version 1.0 --platform $p --dir docs/app-store/metadata
done
# Review notes, after editing the block in app-review.md (once per version id above):
asc review details-create --version-id VERSION_ID --notes "$(cat notes.txt)" --if-exists update
```

## Sources

- Apple: [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) (4.2.7, 4.2.3, 2.3.10, 3.1.1(a));
  [Age ratings values and definitions](https://developer.apple.com/help/app-store-connect/reference/age-ratings-values-and-definitions/);
  [Set an app age rating](https://developer.apple.com/help/app-store-connect/manage-app-information/set-an-app-age-rating);
  [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/).
- App Store listings and ratings: iTunes Search/Lookup API (US and other storefronts), 2026-10-11.
- Press coverage of the 2025 age-rating overhaul: [Michael Tsai](https://mjtsai.com/blog/2025/07/28/updated-age-ratings-in-app-store-connect/), [Sonar](https://trysonar.app/blog/app-store-age-rating).
