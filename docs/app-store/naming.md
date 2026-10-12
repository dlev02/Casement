# Renaming Porthole: shortlist

**Decision (2026-10-11): Casement.** The App Store record "Casement: Remote Desktop" (app id 6821765234) is reserved. The rest of this file is the research behind the choice, kept as written.

Checked 2026-10-11. We have to rename because a paid app, **Porthole: Remote Desktop** (TRD Ventures LLC, $9.99), came out on the App Store on 2026-09-29 and does nearly the same thing. The new name has to work for a free, open-source, private remote desktop (iPhone, iPad, Mac, Vision Pro → your Mac or PC over your own Tailscale network), and as "NAME Host" for the Mac menu bar and Windows tray apps. It should feel premium and Apple-like, in the spirit of Screens, Halide, Things, Overcast and Tot.

## How each name was checked

- **App Store**: the iTunes Search API, US storefront, `entity=software` (iOS) and `entity=macSoftware`, limit 50. I looked at the results for an app whose name equals the candidate or starts with it.
- **Trademarks**: the USPTO's own search backend (tmsearch.uspto.gov), a word-mark phrase match on the candidate. I read every **live** mark it returned and flagged any in class 9 (software), 42 (software services) or 38 (telecoms). For a few names I also ran web searches ("NAME app", "NAME software"). This is a screen, not legal clearance: before filing, have someone run a full search that covers common-law use and the EU/UK registers.
- **Domains and GitHub**: `dig` on NAME.app and getNAME.app, a fetch of anything that answered, and `api.github.com/users/NAME`. These are signals, not blockers.
- **Fit**: whether "NAME Host" and "Connect to Studio in NAME" read well, whether it's easy to say and spell, and whether it promises nothing the app isn't (not a VPN, not a cloud service).

All finalists are 4–9 characters, which leaves at least 20 of the App Store's 30 characters for something like "NAME: Remote Desktop".

## Ranked shortlist

| # | Name | Meaning | App Store (iOS / Mac) | US trademarks (live, class 9/42) | Domains / GitHub | Verdict |
|---|---|---|---|---|---|---|
| 1 | **Casement** | A hinged window that swings open; open a window onto your own computer. | No app named or starting with "Casement" (8 iOS results, 0 Mac; none match). | **None.** The register holds only 5 CASEMENT marks, all dead (shirts, window hardware). | casement.app is taken by an **unlaunched iPhone/iPad mood-board app called "Casement"** ("Coming soon"). getcasement.com is parked. github.com/casement is an empty user. | **Minor risk.** The trademark register and the App Store are clear today, but a design app with the same name is about to ship and could claim the App Store name first. Reserve the name in App Store Connect now if you pick this one. |
| 2 | **Hither** | "To here": the faraway computer comes to you. | No app named "Hither." Nearby names: "Come-Hither" (Lifestyle, 0 ratings) and two "HiThere" apps. | **None in 9/42.** 3 live marks contain the word: Hither Hive (class 45), Hither & Yon (wine, 33), Hither & Wander (41). | hither.app and gethither.app have no DNS. github.com/hither is an empty user. | **Clear.** The cleanest name here. Downsides: it's archaic, and "come-hither" has a flirty ring. "Connect to Studio in Hither" reads a little oddly. |
| 3 | **Sidelight** | The narrow window beside a front door, and light that falls from the side. | No app named or starting with "Sidelight" (46 iOS / 14 Mac fuzzy results; none match). | **None.** 4 marks on file, all dead. | sidelight.app has no DNS (getsidelight.app resolves). github.com/sidelight is a user with 1 repo. | **Minor risk.** The record is clean, but the name echoes Apple's **Sidecar** (iPad as a Mac display), which sits right next to what this app does. Some reviewers and users may take it for a Sidecar add-on. |
| 4 | **Farpane** | An invented word: a pane of glass onto a faraway computer. | **No results at all** (0 iOS, 0 Mac). | **None.** The register has 0 records for it. | farpane.app and farpane.com have no DNS. github.com/farpane is free. The web has no uses of the word. | **Clear.** The most ownable name here: every handle is free. It's literal rather than evocative ("far" + "pane"), so it feels less premium than 1–3. |
| 5 | **Fenestra** | Latin for "window" (the root of "defenestrate"). | No remote or utility app. "Fenestra+ for PVC & Aluminium" (a quoting tool for window makers, 5 ratings) and "Fenestra Living" (Lifestyle). | **None in 9/42.** 2 live marks: class 21 and class 11 (heating/lighting). | fenestra.app is a live **AI architectural-rendering** product. github.com/fenestra is an empty user. A Rust GUI crate is also named `fenestra`, and a window-position utility is called **Fenestrae**. | **Minor risk.** The trademark register is clear, but the name is already used in software and design tools. It's also an anatomy term and harder to spell and say. |
| 6 | **Windeye** | The Old Norse "vindauga" ("wind-eye") that the English word "window" comes from. | No remote app. "Windeye: Mahjong Voyage" (Entertainment). | **None in 9/42.** WINDEYE: 1 dead record. WIND EYE: 1 live mark, not in 9/42. | windeye.app is live, titled **"Vindauga — Virtual Windows"** (the same etymology; the page is script-only and its content couldn't be read). Windar sells a "WindEye" lidar product. github.com/windeye is an active user (62 repos). | **Minor risk.** The origin story is good, but someone already runs a "virtual windows" product on windeye.app. People may also be unsure whether to say "wind" or "wined." |
| 7 | **Portlight** | The nautical name for a porthole window that opens. | No app named or starting with "Portlight" (44 / 31 fuzzy results; none match). | **None.** 2 records, both dead. | portlight.app has no DNS. github.com/portlight is a user with 1 repo. There's a homelab Docker tool called "port-light," and Portlight Strategies is a disaster-relief nonprofit. | **Risky (on fit, not on the record).** It's a near-synonym of the name we're leaving, so it looks like we're still tied to "Porthole: Remote Desktop," which is exactly the confusion the rename is meant to end. |
| 8 | **Lucarne** | French for a dormer window or skylight. | Small French apps: "Lucarne - Foot" (a game), "Lucarne Opposée" (news), "Lucarneo" (a photo frame). | **None.** The register has 0 records. | lucarne.app has no DNS, but **Lucarne, a free, private Mac photo editor (lucarneapp.com, Apple silicon)**, is active in the same indie-Mac niche. github.com/lucarne is a user. | **Minor risk.** The register is clean, but there's a same-named, privacy-first, free Mac app. English speakers won't know how to say it, and in French football slang it means the top corner of the goal. |

**Recommendation.** Pick **Casement** if you can reserve the App Store name now. It has the strongest window metaphor, sounds like a premium Mac app, and works as "Casement Host." If it's already gone, pick **Hither**, which is clear on every check. If an invented name you fully own matters more than how it sounds, **Farpane** is the fallback. In every case, get a professional trademark clearance (USPTO plus EUIPO/UKIPO) before you announce it.

Lookups to repeat before deciding: the USPTO and App Store searches for Haunt, Peer, Kite and Whence failed on network errors and were **not checked**. They were long shots anyway (see below).

## Brainstorm (about 85 names considered)

- **Window and opening**: Casement, Transom, Oriel, Skylight, Sash, Lunette, Fenestra, Fenster, Finestra, Ventana, Mado, Shoji, Lucarne, Windeye, Pane, Lattice, Dormer, Mullion, Fanlight, Sidelight, Clerestory, Jalousie, Embrasure, Cupola, Vitrine, Casemate, Portlight, Deadlight, Scuttle, Bullseye
- **Door and threshold**: Hatch, Wicket, Postern, Ostium, Keyhole, Threshold, Lintel, Doorstep, Foyer, Porch, Annex, Alcove, Atrium, Gable
- **View and sight**: Spyglass, Loupe, Lookout, Overlook, Vista, Sightline, Eyeline, Farsight, Purview, Fieldglass, Kenning, Halo, Lantern, Peer
- **Reach, distance and presence**: Hither, Thither, Whence, Yonder, Afar, Afield, Elsewhere, Otherside, Farside, Farpoint, Tether, Envoy, Tandem, Wield, Steer, Haunt, Kite, Ambit
- **Nautical and home**: Helm, Tiller, Davit, Sextant, Lodestar, Mooring, Homeport, Outrigger, Telltale, Bulkhead, Hearth, Homeward, Slipstream, Wayfarer, Porter
- **Invented and compound**: Farpane, Homepane, Nearpane, Telepane, Farlight, Glasswork, Longreach, Deskward, Mezzanine, Dovetail

## Notable rejections

| Name | Why it was cut |
|---|---|
| Oriel | Live class 9/42 mark **ORIEL** owned by Vibe, Inc., a maker of collaborative smart displays, covering "transmission of … images" ([SN 99361020](https://tsdr.uspto.gov/#caseNumber=99361020&caseType=SERIAL_NO&searchType=statusSearch)). Also ORIEL (Oriel, Inc., class 42 SaaS) and ORIEL AI. Too close to our field. |
| Transom | "Transom Note-Taker for Writers" is on the App Store (Void Media, whose 2013 TRANSOM filing for apps no longer shows as live), and a live class 42 TRANSOM mark belongs to Atlantic Public Media ([SN 78089297](https://tsdr.uspto.gov/#caseNumber=78089297&caseType=SERIAL_NO&searchType=statusSearch)). |
| Helm | "**Helm: Mac Remote Controller**" is already on the App Store (Utilities), alongside Helm for App Store Connect and Kubernetes Helm. Direct conflict. |
| Hearth | Live class 9 **HEARTH** mark for interactive touchscreens and whiteboard software, Hearth Display ([SN 98025624](https://tsdr.uspto.gov/#caseNumber=98025624&caseType=SERIAL_NO&searchType=statusSearch)). |
| Ambit | Live class 9 **AMBIT** mark for "downloadable VPN software" ([SN 90585230](https://tsdr.uspto.gov/#caseNumber=90585230&caseType=SERIAL_NO&searchType=statusSearch)). It would also suggest we're a VPN. |
| Lantern | "Lantern: Fast, Secure VPN" is on the App Store. It reads as a VPN, and the name has many software marks. |
| Tether | TP-Link Tether (160k ratings), the Tether (USDT) wallet, and 50+ live marks. |
| Skylight, Lookout, Envoy, Tandem, Halo, Vista, Pane, Lattice, Loupe, Hatch, Yonder, Afar, Elsewhere, Sightline, Overlook, Threshold, Porter, Steer | Crowded App Store namespaces, many live class 9/42 marks, or both. Lookout is a security company, Envoy a workplace platform, Vista a Windows version. |
| Purview | Microsoft Purview is a major brand, and there are live class 9/42 PURVIEW marks. |
| Spyglass, Keyhole, Peephole | Spying and surveillance connotations. Keyhole was also Google Earth's original company. Spyglass has a live class 9 mark for a navigation app. |
| Postern, Embrasure | Clean records (0 live marks), but a postern is a **back door**, the wrong message for remote-access software. An embrasure is a gun opening and hard to spell. |
| Deadlight | Live class 9 mark for a video game by Tequila Works ([SN 79103162](https://tsdr.uspto.gov/#caseNumber=79103162&caseType=SERIAL_NO&searchType=statusSearch)). Also grim. |
| Ostium | Live class 9/42 mark for surgical-planning software (Ostium Group). |
| Fanlight | The App Store is full of K-pop "Fanlight" concert-light apps, and FANLIGHT Co. holds marks. |
| Casemate | Case-Mate (phone accessories) holds class 9 marks, and a CaseMate LLC holds class 42. |
| Farlight, Farpoint, Telltale, Otherside, Eyeline, Fieldglass | Owned by big brands: Farlight 84 (Lilith Games), Farpoint (Sony), Telltale Games, Otherside (Yuga Labs), Eyeline (Netflix), SAP Fieldglass. |
| Shoji, Annex, Alcove, Atrium, Lodestar, Sextant, Mooring, Homeport, Slipstream, Clerestory, Porch | Live class 9/42 software marks (for example, Shoji Technologies for cybersecurity software). |
| Davit | Reads as DaVita, the dialysis company. |
| Fenster, Mado, Vitrine, Lintel, Cupola, Thither, Jalousie, Mullion, Homepane | Records mostly clean, but each lost on fit or a small conflict. Fenster: a fasting-timer app. Mado: Turkish ice cream and a digital-detox app. Vitrine: an iOS lists app and a Mac screenshot app. Lintel and Mullion don't suggest a view. Thither: an iOS app of that name. Jalousie: hard to spell, means "jealousy." Homepane: an iOS app "HomePane." |
| Aperture, Oculus, Periscope, Portal, Sidecar, Handoff, Continuity, Duet, Jump, Screens, Parsec, Moonlight, Sunshine, Shadow, Luna | Big brands, Apple feature names, or remote-desktop and streaming competitors (Aperture: Apple; Oculus: Meta; Periscope: Twitter; Portal: Valve and Meta; Duet Display; Jump Desktop; Screens; Parsec; Moonlight and Sunshine game streaming; Shadow PC; Luna Display). |
| Kenning, Haunt, Peer, Kite, Whence | Long shots; the USPTO lookups for Haunt, Peer, Kite and Whence failed on network errors (**not checked**). Cut on fit: Kenning is obscure, Haunt is spooky, Peer and Kite are hopelessly generic, Whence has an iOS app named "Whence?". |
