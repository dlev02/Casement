# App Review: notes, Guideline 4.2.7, and risks

Drafted 2026-10-11 against the working tree at `a694c86` plus uncommitted changes. Line numbers
are from that tree.

## Notes for Review (paste into App Store Connect › App Review Information › Notes)

Limit: 4,000 bytes. `check-lengths.py` counts the block below. Attach the demo video (and, if you
like, a PDF of the setup steps) under Attachment. Contact fields: set in App Store Connect
on each platform's version (the team's review contact, the same as its other app; kept out of this
repo). Sign-in: leave "Sign-in required" off; there
is no account.

<!-- notes:start -->
```text
Casement is a remote desktop client. It shows and controls the user's own Mac or Windows PC, which runs my free companion app, Casement Host. The two connect directly over the user's own Tailscale network. There is no account, sign-in, or server of mine, so no demo account applies.

DEMO VIDEO
The attached video (about one minute, recorded in the iPad simulator against a test copy of Casement Host streaming a sample desktop) shows adding a Mac, pairing with the six-digit code, the Mac's screen, moving and clicking the pointer, the control strip and keyboard button, a file arriving from the Mac, and disconnecting.

WHY A LIVE TEST NEEDS SETUP
The app connects only to a computer running Casement Host, and Casement Host accepts connections only from Tailscale addresses (100.64.0.0/10 and fd7a:115c:a1e0::/48). Without a host the app opens to an empty device list with Add from Tailscale and Add Manually.

TO TEST IT LIVE (about 10 minutes, one Mac)
1. On a Mac with macOS 26 or later, download Casement Host from https://github.com/dlev02/Casement/releases and open it. It appears in the menu bar. Allow Screen Recording and Accessibility when it asks (its menu has a button for each).
2. Install Tailscale (free) on that Mac and on the test device (Tailscale is on the App Store) and sign in to the same Tailscale account on both.
3. In Casement, tap +, then Add Manually, and enter the Mac's Tailscale address (100.x.y.z, shown in Tailscale's menu) or its Tailscale machine name.
4. In Casement Host's menu, choose Pair a Device. Type the six-digit code into Casement.
5. The Mac's screen appears. Try the control strip, Send File, Mac Audio, and Dictate (microphone button).
The Mac version of Casement can connect to Casement Host on the same Mac at that Mac's own Tailscale address. It opens in View Only, so the session doesn't control itself.

WHAT CASEMENT DOES AND DOESN'T DO
- It mirrors the whole desktop of a computer the user owns and has set up. It isn't a mirror of specific software or a cloud service, has no store or catalog, and never browses, sells, or launches software.
- No in-app purchases, subscriptions, ads, analytics, tracking, or accounts. It's free and open source (GPL-3.0).
- Microphone and Speech Recognition are used only for dictation, after the user taps the microphone. Local Network is used to reach the user's computers. Face ID, Touch ID, or Optic ID is used only for the optional app lock.
- Add from Tailscale is optional. It lists the user's own Tailscale devices using a read-only API key the user creates in Tailscale's admin console and pastes in; the key stays in the Keychain. Add Manually works without it.
- Type Password and Log In with Screen Sharing type the user's saved Mac password through macOS's built-in Screen Sharing on the user's own Mac (port 5900), for the lock screen and password fields, where macOS blocks synthetic keystrokes.
- Encryption: the app uses only Apple's CryptoKit and CommonCrypto, for device authentication and integrity checks. The connection itself is protected by Tailscale's WireGuard tunnel.

LINKS
Source code: https://github.com/dlev02/Casement
Casement Host downloads: https://github.com/dlev02/Casement/releases
Privacy policy: https://github.com/dlev02/Casement/blob/main/PRIVACY.md

I'm happy to answer questions or walk through a live session on a call.
```
<!-- notes:end -->

Before pasting, confirm that every link loads signed out: the repo is private today, and all four
GitHub URLs return 404 (checked 2026-10-11). Also confirm the Releases page has a notarized
Casement Host build. The Mac self-connection paragraph rests on `ThisMac.isHost` (CLAUDE.md,
"Same Mac") and hasn't been tried with a Release build. Check it once, or delete the paragraph.

## Guideline 4.2.7 (Remote Desktop Clients)

**Scope.** 4.2.7 opens with: if your remote desktop app *mirrors specific software or services
rather than acting as a generic mirror of the host device*, it must meet (a) to (e). Casement is
a generic mirror: it streams the whole display (ScreenCaptureKit on the Mac, the desktop on
Windows) and forwards all input. Strictly, then, (a) to (e) don't apply. Casement still meets
every one of them except the LAN wording in (a), and the review notes say "generic mirror" up
front so the reviewer doesn't go looking for them.

| Sub-point (paraphrased) | How Casement meets it | Evidence |
| --- | --- | --- |
| **(a)** Connect only to a user-owned host (a personal computer or a dedicated game console), with host and client on a local, LAN-based network. | The host is the user's own Mac or PC running Casement Host, which the user installs and grants Screen Recording and Accessibility. Every client must pair with a code shown on that computer. The network is the user's private Tailscale tailnet, a WireGuard overlay that acts like a LAN between the user's own devices but isn't literally a LAN. Because Casement is a generic mirror, the LAN wording doesn't bind; if a reviewer pushes, say that a tailnet is a private network of the user's own devices, the way a home VPN is. | `VantageHost/Net/TailscaleListener.swift:59` (accepts Tailscale addresses only), `Packages/VantageCore/Sources/VantageCore/Transport/NetworkParameters.swift:30-62` (100.64.0.0/10, fd7a:115c:a1e0::/48), `VantageHost/Net/TrustStore.swift:29` (10-minute codes), `:78` (`consumePairingCode`, burned after 5 misses) |
| **(b)** Software in the client runs and renders entirely on the host, and the client uses no APIs or platform features beyond what streaming needs. | Everything runs on the host. The client decodes H.264/HEVC frames into `AVSampleBufferDisplayLayer` and sends input events back. The extras (files, clipboard, audio, dictation) serve the remote session and run on public APIs. No code is downloaded or run on the client. | `Vantage/Video/` (decode and display), `Vantage/Input/`, `Packages/VantageCore/Sources/VantageCore/Wire` (data-only protocol); grep for `dlopen`, `NSClassFromString`, `JavaScriptCore`, `WKWebView`: no hits |
| **(c)** All account creation and management starts on the host. | Casement has no accounts. Trust is managed on the host: Casement Host shows the pairing code, lists paired devices, and removes them, which also ends their sessions. The only credential in the client is the user's own optional Tailscale key, for the user's own Tailscale account, created in Tailscale's console. | `HostController.revoke` / `HostSession.endIfClient` (CLAUDE.md, Auth), `Vantage/Net/TailscaleAPI.swift:181-210` (read-only GET plus the OAuth token call) |
| **(d)** The client UI doesn't resemble iOS or an App Store view, has no store-like interface, and can't browse, pick, or buy software the user doesn't already own. Transactions inside mirrored software don't need IAP if the host processes them. | The client's UI is a device list, a settings screen, and the remote picture with a control strip. There's no catalog, launcher, or purchase flow. StoreKit isn't imported anywhere in the client. | grep `import StoreKit` / `SKStoreReview` in `Vantage/`, `Shared/`: no hits |
| **(e)** No thin clients for cloud-based apps. | Casement has no cloud and no server of mine. It connects only to computers the user adds, which run the user's own copy of Casement Host. | `PRIVACY.md` "What goes over the network"; client network calls are limited to `MessageChannel`/`NWConnection` to user-added hosts, `ScreenSharingTyper` to the user's Mac on port 5900, and `TailscaleAPI` to `api.tailscale.com` |

## App Review risks, ranked

1. **Name (resolved by the rename, residual risk low).** The app was called Porthole until
   2026-10-11, when a different developer's **"Porthole: Remote Desktop"** (TRD Ventures LLC,
   `net.trdventures.porthole`, id 6815382240, $9.99, released 2026-09-29) turned out to be the same
   kind of app. It is now **Casement**, and "Casement: Remote Desktop" is reserved in App Store
   Connect (app id 6821765234). `naming.md` has the checks behind the choice: no US App Store app
   and no live US trademark named Casement on 2026-10-11, but an unlaunched iPhone mood-board app
   called "Casement" (casement.app) exists. Get a professional trademark clearance before
   announcing. Every user-facing string, the repo name, the Host apps, and the screenshots must say
   Casement before submission: a store name that doesn't match the installed app's name is a 2.3.8
   / 4.1 flag.
2. **2.1 / reviewer can't reach a host.** A reviewer with only an iPad sees an empty list. The
   mitigations are the demo video on real devices (Apple accepts video when an app needs other
   hardware), the 10-minute live-test steps, and a public, working Releases page with a notarized
   Host. Make sure the video shows pairing, input, files, audio, dictation, and the Mac and
   Vision Pro apps.
3. **4.2.3(i): needs another app on the same device.** Casement can't work without the Tailscale
   app on the iPhone or iPad, because Release hosts refuse every non-Tailscale address, including
   the LAN. Remote-desktop clients needing a host on the *computer* is normal; needing a third-party
   VPN app on the *device* is less common. Mitigations: describe Tailscale as the private network
   (like a VPN configuration), not an app dependency; make the app send people to Tailscale's App
   Store page when it isn't installed (see "Changes before submission"). If this becomes a
   rejection, the fix is an opt-in "Allow connections from my local network" setting in Casement
   Host (RFC 1918 and link-local addresses, still paired), so the app works on a home network
   without Tailscale.
4. **Every link in the app, the metadata, and the review notes is 404 today.** The repo is
   private: `github.com/dlev02/Casement`, `/blob/main/PRIVACY.md`, `/issues`, and `/releases` all
   return 404. That breaks the privacy policy URL (5.1.1(i)), the support URL (1.5), the About
   links (2.1), and the Host download. Make the repo public and publish a Host release before
   submitting.
5. **visionOS has no app icon.** CLAUDE.md says the layered `.solidimagestack` doesn't exist yet,
   and `Vantage/Assets.xcassets` has only `AppIcon.appiconset` (iOS universal plus Mac sizes).
   Upload validation for a visionOS build will fail without it. Either add it or leave visionOS
   out of 1.0.
6. **2.1 / 2.3.1: widgets that can never show a Mac.** The widget and the Control Center control
   read `DeviceCatalog` through the App Group `group.com.benjaminlevinson.vantage`. No target has
   that entitlement today (the project has no `.entitlements` for `Vantage` or `VantageWidgets`),
   so a store build's widget always says "No Macs yet" (`Shared/ConnectWidgetView.swift:123`).
   With the paid team, add the App Groups capability to both targets, or drop widgets from the
   description and screenshots.
7. **2.1 / 2.2: user-facing text written for a sideloaded copy.** `Vantage/Model/CloudSync.swift:39`
   tells App Store users "The device list itself waits on an App Store build — this copy of
   Casement isn't signed for iCloud storage." On an App Store build without the iCloud key-value
   entitlement, that reads as unfinished and points at a future build. Add the iCloud Key-Value
   Storage capability (CLAUDE.md, iCloud sync) or reword it. The README the About › Source Code
   link opens says "Casement is in **beta**" and "For now you build it yourself". Update it before
   the repo goes public.
8. **3.1.1: donation links one tap away.** The app has no Ko-fi link (grep: no hits). The README
   (Ko-fi badge and paragraph) and `.github/FUNDING.yml` are linked from About › Source Code, and
   About › Website opens drewlevinson.me (no donation link found there on 2026-10-11). Since
   May 2025, 3.1.1(a) no longer bans external purchase links in the **US** storefront, and a
   source-code link that happens to show a sponsor badge is common for open-source apps, so this
   is low risk. Keep Ko-fi out of the app and the metadata, as CLAUDE.md says. The drafted
   metadata contains no donation link.
9. **4.1 / 2.3: name versus bundle on the Mac.** The Mac App Store installs `Vantage.app`
   (`PRODUCT_NAME = $(TARGET_NAME)`, `project.pbxproj:476, 528`). The menu bar says Casement
   through `Vantage/en.lproj/InfoPlist.strings`, but Finder, Launchpad, and /Applications can show
   "Vantage" unless `LSHasLocalizedDisplayName` is set. A reviewer comparing the store name with
   the installed app may flag the mismatch. Check a Release Mac build in /Applications. Fix either
   by adding `INFOPLIST_KEY_LSHasLocalizedDisplayName = YES` or by setting `PRODUCT_NAME = Casement`
   for the app target only, with `PRODUCT_MODULE_NAME = Vantage` (data is keyed by bundle id, so
   nothing is orphaned).
10. **2.5.1 (low): an undocumented URL scheme.** `Vantage/UI/TransfersView.swift:366` opens Files
    with `shareddocuments://`, which is widely used but not documented. `VantageApp.swift:14`
    registers the AppKit default `NSFullScreenMenuItemEverywhere`, which is harmless. No private
    frameworks or selectors were found (grep for `dlopen`, `dlsym`, `NSClassFromString`,
    `NSSelectorFromString`, `_UI`, `@_silgen_name`, `objc_msgSend`: no hits in the client).
11. **2.3.10 / 2.3.7 (low): other platforms and trademarks in metadata.** Windows is a desktop OS
    and "specific, approved interactive functionality", so naming it is fine (Jump Desktop and
    Windows App do the same). Keep real Windows logos and other mobile platforms out of
    screenshots, keep "Tailscale", "Windows", "VNC", and "RDP" out of keywords (Casement doesn't
    speak VNC or RDP), and keep the trademark line at the end of the description.
12. **Support URL (low).** GitHub Issues needs a GitHub account to post. Apple asks that the
    support URL lead to a way to contact you. Issues usually passes; a short support page with an
    email address is the safe fallback.

### What the user-facing string sweep found

- `Vantage` in the client's user-facing strings: none. The hits are comments
  (`SharedFileInbox.swift:5`, `FileTransferCenter.swift:6`, `ConnectToMacIntent.swift:4, 15`) and
  on-disk paths (`Shared/DeviceCatalog.swift:81, 85`). Siri phrases use `.applicationName`.
  The Files app shows the folder under the display name, Casement.
- "beta", "TestFlight", "coming soon", "lorem", "Xcode", "sideload", "personal team", "App Store"
  in code that isn't a comment: one hit, `Vantage/Model/CloudSync.swift:39` (above).
- Debug-only UI in Release: every `-Vantage…` launch flag goes through `ClientOptions.value(for:)`,
  `MacSessionOptions.flag(_:)`, or an explicit `#if DEBUG`, which return nil or false in Release
  (`Vantage/Model/ClientOptions.swift:24-100`, `Vantage/Mac/RemoteSessionNSRepresentable.swift:66-78`,
  `Vantage/Transfer/FileTransferController.swift:132-145`). The Tailscale fixture, sample devices,
  `-VantageOpenScreen`, and the probes don't exist in Release. Fixture names such as
  "drew@example.com" exist only in DEBUG.
- Placeholder content: the widget gallery preview uses "Studio Mac" / "studio.example.ts.net"
  (`VantageWidgets/VantageWidgets.swift:53-54`), which is fine as a gallery placeholder.
- Copy that names only the Mac where a PC also works: `NSLocalNetworkUsageDescription` "Casement
  connects to your Mac over your private Tailscale network." (`project.pbxproj:454, 506`), and
  the widget's "Connect to Mac" / "One tap to your Mac" (`VantageWidgets/VantageWidgets.swift:22-23,
  87-91`). Not a rejection risk; "your Mac or PC" is more accurate.
