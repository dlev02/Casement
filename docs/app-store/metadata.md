# Metadata: one app record for iOS, macOS, and visionOS

The client is one target, `Vantage`, with one bundle id. In App Store Connect that is
**"Casement: Remote Desktop"**, app id `6821765234`, bundle id `me.drewlevinson.casement`
(registered as UNIVERSAL), SKU `CASEMENT2026`, primary language English (U.S.). The project still
builds `com.benjaminlevinson.vantage` until the rename lands; the first upload must use the new
bundle id. One record carries three platforms (iOS, macOS, visionOS) with universal purchase, free.
App-level fields (name, subtitle, privacy policy URL, categories, age rating, App Privacy, content
rights, price, availability) are shared. Each platform has its own App Store version (1.0) with its
own description, keywords, URLs, promotional text, copyright, review details, and screenshots, so
the version file below is pushed once per platform.

English (U.S.) only. The text uses U.S. spelling ("color"), unlike the README.

## Canonical files (asc layout)

| File | Fields |
| --- | --- |
| `metadata/app-info/en-US.json` | `name`, `subtitle`, `privacyPolicyUrl` |
| `metadata/version/1.0/en-US.json` | `description`, `keywords`, `marketingUrl`, `promotionalText`, `supportUrl` |

`whatsNew` is left out on purpose: App Store Connect doesn't take What's New for an app's first
version. The draft below is for 1.0.1.

```sh
asc metadata validate --dir docs/app-store/metadata --output table
asc metadata validate --dir docs/app-store/metadata --check-urls   # once the repo is public
for p in IOS MAC_OS VISION_OS; do
  asc metadata push --app 6821765234 --version 1.0 --platform $p --dir docs/app-store/metadata --dry-run --output table
done
```

The README's "State in App Store Connect" section says what has been pushed.

## Name

**`Casement: Remote Desktop`** (24 of 30). On the device the app is just "Casement"; in the
description and everywhere else the product is "Casement", and the companion is "Casement Host".

Why the rename: a different developer's **"Porthole: Remote Desktop"** (TRD Ventures LLC,
`net.trdventures.porthole`, $9.99, Utilities, iPhone and iPad, getporthole.app) went live on
2026-09-29 and is also a Mac remote-desktop app that recommends Tailscale. Two remote-desktop apps
called Porthole would have invited user confusion and a 4.1 / 5.2 complaint. `naming.md` has the
shortlist and the checks behind Casement (a hinged window that opens outward). Get a professional
trademark clearance (USPTO plus EUIPO/UKIPO) before announcing.

"Remote Desktop" in the name puts the two most-searched words for this kind of app into the
most heavily weighted field, so neither is repeated in the subtitle or keywords.

## Subtitle

**`Control Mac & PC, privately`** (27 of 30). No word from the name (casement, remote, desktop).
It indexes "control", "mac", and "pc", and says the pitch (private, your own network). It's
app-level, so it shows on the iPhone, iPad, Mac, and Vision Pro listings alike: that's why it names
what you control (Mac & PC) rather than the device you control it from ("from iPhone" would be
wrong on the Mac App Store).

Alternatives, all counted by `check-lengths.py`: `Your Mac & PC, privately` (24),
`Private access to Mac & PC` (26). The brief's example "Private, from iPhone to Mac & PC" is 32
characters, over the limit, and names one device.

## Promotional text (170)

> Control your Mac or Windows PC from iPhone, iPad, Mac, or Apple Vision Pro, privately over your own Tailscale network. Free and open source, with no account or tracking.

169 characters. You can change it at any time without a new review.

## Keywords (100 bytes)

`screen,sharing,computer,access,viewer,anywhere,keyboard,mouse,trackpad,file,transfer,private,laptop`

99 bytes, 13 terms. How they were chosen:

- None repeats a word from the name or subtitle. Apple indexes those already, so "casement",
  "remote", "desktop", "control", "mac", and "pc" are left out. ("private" isn't "privately";
  keep it, since stemming isn't guaranteed.)
- No spaces after commas, and singular forms only (Apple matches plurals).
- No competitor names or trademarks (Screens, Jump, TeamViewer, AnyDesk, Tailscale, Windows,
  WireGuard, iPad, iPhone, Vision Pro), per Guideline 2.3.7.
- No "vnc" or "rdp": Casement doesn't speak either protocol, so they would be misleading (2.3.1).
- Changed from the Porthole draft: `control` moved to the subtitle; `mirror` dropped (searches for
  "screen mirror" mean phone-to-TV mirroring, the wrong audience); `anywhere` and `laptop` added
  ("access my laptop from anywhere").
- The same set goes to all three platforms. Per-platform tweaks are possible later (each
  platform's version has its own keywords): on the Mac, `window` for `trackpad`; on visionOS,
  `spatial` for `trackpad`.

## Description

The full text is in `metadata/version/1.0/en-US.json` (3,245 of 4,000). Plain text, "•" bullets,
no emoji or hype. It names Casement Host and where to get it (`github.com/dlev02/Casement/releases`),
says it's free and open source, and contains no donation link. Notes:

- It names the Casement Host download and Tailscale up front, because the app does nothing without
  them (2.3.1 and 4.2.3).
- The same text goes to all three platforms, so the iOS-only features are qualified: "On iPhone
  and iPad, Home Screen widgets and a Control Center control." Those work only once the App Group
  entitlement is added for the new bundle id (see app-review.md, risk 6). If that isn't done, delete
  that sentence.
- It doesn't claim device-list sync over iCloud, which needs the iCloud Key-Value Storage
  capability. It claims iCloud Keychain sync for passwords, which works today.
- It ends with the trademark line from `TERMS.md`.

## What's New (1.0.1 onward; not used for 1.0)

> Welcome to Casement. Control your Mac or Windows PC from iPhone, iPad, Mac, and Apple Vision Pro, privately over your own Tailscale network.

For later releases, use the `release-notes` skill (plain-English, changelog style).

## URLs

| Field | Value | Where it's set |
| --- | --- | --- |
| Support URL | https://github.com/dlev02/Casement/issues | each platform's version localization |
| Marketing URL | https://github.com/dlev02/Casement | each platform's version localization |
| Privacy Policy URL | https://github.com/dlev02/Casement/blob/main/PRIVACY.md | app info localization (shared) |

The repo is private until just before submission, so all three return 404 today; they must load
signed out before you submit (`asc metadata validate --check-urls`). The app's About links must
use the same URLs (`Vantage/UI/SettingsScreen.swift`, `AppInfo`). Consider a support page with an
email address as well (app-review.md, risk 12).

## Copyright

`2026 Drew Levinson`, set on each platform's version (`asc versions update --copyright`). The Mac
`NSHumanReadableCopyright` already says "© 2026 Drew Levinson". The seller name the store shows
comes from the developer account, not this field.

## Categories

| | Category | Why |
| --- | --- | --- |
| Primary | **Utilities** | Where people look for remote-desktop and network tools: Screens 5, AnyDesk, Tailscale. It also matches `LSApplicationCategoryType = public.app-category.utilities` in the build. |
| Secondary | **Productivity** | Reaching your own computer's apps and files from anywhere. Jump Desktop, Windows App, and Splashtop pick Business, but Casement is personal and has no business features. |

## Character and byte counts

Run `python3 -I docs/app-store/check-lengths.py`. The output is in README.md.
