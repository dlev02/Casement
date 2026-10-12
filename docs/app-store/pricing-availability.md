# Content rights, pricing, availability, and other App Information

## Content rights

App Store Connect › App Information › Content Rights: **"No, it does not contain, show, or
access third-party content."**

Casement has no content of its own beyond its UI. What it shows is the user's own computer, and
what it reads from Tailscale is the user's own device list, using the user's own key. Neither is
third-party content in Apple's sense (licensed media, data feeds, someone else's catalog). If you
want to be conservative, "Yes, and I have the rights" is also truthful for the same reason, and
changes nothing else. All artwork (icon, screenshots of made-up desktops from
`docs/images/source/`) is original. BetterDisplay, MacWhisper, Tailscale, and Windows are named
only to describe compatibility.

## Price

**Free** (the 0.00 price point, USD base). No in-app purchases, subscriptions, or pre-order. The
App Store says "Free" plus the in-app purchase line only when IAPs exist, so it'll just say Free.
Paid Apps agreement and banking aren't needed for a free app with no IAP. The Free Apps
agreement is enough.

## Availability

**Recommendation: every storefront except China mainland.** Make it available on all three
platforms (iPhone/iPad, Mac, Apple Vision Pro, where visionOS is sold).

| Territory | Decision | Why |
| --- | --- | --- |
| **China mainland** | **Exclude** | (1) Since 2024 every new app in the China mainland storefront needs an ICP Filing Number (MIIT) entered in App Store Connect, which an individual outside China can't practically get. (2) Casement depends on Tailscale, and **Tailscale isn't on the China mainland App Store** (iTunes lookup for `io.tailscale.ipn.ios`, country `cn`: 0 results, 2026-10-11), so the app couldn't work there. (3) VPN-adjacent apps get extra scrutiny there. Casement isn't a VPN: it doesn't use `NEVPNManager` or create tunnels, so Guideline 5.4 doesn't apply. But its value depends on one. |
| Russia, Belarus | Include (your call) | Tailscale's iOS app isn't in those storefronts either (`ru`, `by`: 0 results), so iPhone and iPad users there can't use Casement without other means. Tailscale for Mac is a direct download, so the Mac app can still work. Free apps are still distributed there. Excluding them avoids "doesn't work" reviews; including them costs nothing. |
| Everywhere else | Include | Tailscale is on the store in every other storefront checked (us, gb, de, fr, in, ae, sa, tr, eg, pk, vn, id, kz, ua, br, jp, kr, hk, tw, mo). |

Other settings:

- **Pre-orders**: no.
- **Make available on Apple Vision Pro**: yes. It's a native visionOS build, not the iPad app,
  so this is automatic.
- **Mac App Store availability of the iPhone/iPad app**: not applicable. The Mac version is a
  native macOS build of the same bundle id (`SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = NO`), shipped
  as its own macOS platform version.
- **Distribution method**: Public.
- **Universal purchase**: automatic, since iOS, macOS, and visionOS share one bundle id and app
  record.

## EU: Digital Services Act trader status

Required before the app can be offered in the EU (App Store Connect › Business, or the app's
App Information page). It's a self-assessment:

- **Non-trader**: fits a free, open-source project made by an individual, not as a business, with
  no IAP. Nothing extra is shown on the product page.
- **Trader**: if you act as a business. Your legal name, address, phone, and email are then shown
  on the EU product page.

The voluntary Ko-fi donations (outside the app) don't by themselves make an app commercial, but
this is your call, not legal advice. If you're unsure, choose non-trader for now and revisit if
Casement ever earns money through the store.

## Other App Information fields

| Field | Value |
| --- | --- |
| Primary language | English (U.S.) |
| Bundle ID | `me.drewlevinson.casement` |
| SKU | `CASEMENT2026` (set when the record was created; internal, never shown, can't change) |
| User Privacy Choices URL | none (no data collected) |
| License agreement | Apple's standard EULA. TERMS.md says the GPL governs the source code and Apple's EULA covers App Store copies. No custom EULA is needed. |
| Routing app coverage | not applicable |
| Game Center | off |
