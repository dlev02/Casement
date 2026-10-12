# Age rating questionnaire

**Result: 4+** in every region (Apple's calculated rating; no override). Apple's own reference
page says a 4+ app may still include parental controls, age assurance, user-generated content,
messaging, advertising, and infrequent contests. Casement has none of those anyway.

The questionnaire is the 2025 version (five tiers: 4+, 9+, 13+, 16+, 18+), required for
submissions since January 31, 2026. It's in App Store Connect › App Information › Age Ratings ›
Set Up Age Ratings. The answers are the same for iOS, macOS, and visionOS. Field names in
parentheses are the App Store Connect API's `ageRatingDeclarations` attributes.

With `asc` (5.14.1), the whole declaration is one command. It writes to App Store Connect, so
run it only when you mean to:

```sh
asc age-rating edit --app "$APP_ID" --all-none --age-rating-override-v2 NONE
```

`--all-none` sets every frequency to NONE and every Yes/No to false, which matches every answer
below. Verify with `asc age-rating view --app "$APP_ID" --output table`.

## Step 1: In-app controls and capabilities

| Question | Answer | Reasoning |
| --- | --- | --- |
| Parental Controls (`parentalControls`) | **No** | The Face ID / Touch ID / Optic ID app lock protects the owner's own sessions. It doesn't let a parent monitor or restrict a child, so it isn't a parental control as Apple defines it. |
| Age Assurance (`ageAssurance`) | **No** | No Declared Age Range API, age estimation, or ID check. |
| Unrestricted Web Access (`unrestrictedWebAccess`) | **No** | See the discussion below. |
| User-Generated Content (`userGeneratedContent`) | **No** | Apple means "broad distribution of content created by users". Casement moves a user's files and screen only between that user's own devices. Nothing is published or shown to other people. |
| Social Media (`socialMedia`) | **No** | No feed or discovery surface. |
| Messaging and Chat (`messagingAndChat`) | **No** | Users can't talk to each other. Clipboard and file transfer go between one person's own devices. |
| Advertising (`advertising`) | **No** | No ads. |

### Is a remote-desktop client "Unrestricted Web Access"?

Apple's definition: *"Users can navigate to any webpage within the app or freely browse the web.
May include: embedded browser functionality or browser app."* Answering Yes makes the app 16+.

**Answer No**, because:

1. **There's no browser in Casement.** It has no WebKit, `WKWebView`, `SFSafariViewController`,
   or JavaScriptCore (grep: zero hits), and no URL field. Its few links (About, Tailscale's admin
   console) open in Safari, outside the app.
2. **The pixels come from the user's own computer.** Casement shows a desktop that the same person
   owns, has set up, signed in to, and paired with a code shown on that computer. Whatever that
   computer can browse is governed by that computer and its own parental controls (Screen Time
   on a Mac, Microsoft Family Safety on Windows), not by Casement. Rating by "what the remote
   machine could display" would also make every SSH client, VNC viewer, and video-call app 16+,
   which isn't how Apple applies it.
3. **Every comparable app is rated 4+** (US App Store, iTunes Search API, 2026-10-11): Screens 5
   (Edovia, Utilities), Jump Desktop (Business), Windows App and Windows App Mobile (Microsoft,
   Business), AnyDesk, TeamViewer Remote Control, RealVNC Viewer, Splashtop, and Tailscale itself.
   Chrome Remote Desktop has no separate iOS app in the US store to compare. The one outlier is
   an unrelated app, "Porthole: Remote Desktop" (TRD Ventures), shown as 12+ by the legacy API field. That
   value doesn't match any answer that applies to a remote-desktop client, and the API still
   reports legacy tiers, so it's no precedent for Yes.

If App Review ever disagrees, the fix is a metadata-only change: answer Yes and accept 16+, which
needs no new build. Don't pre-emptively choose 16+: an over-rating costs downloads and is also
inaccurate under Guideline 2.3.6.

## Steps 2 to 6: Content

Every content item is **None** (or **No** for Yes/No items). Casement has no content of its own:
it shows the user's own computer and its own settings screens.

| Section | Item (API field) | Answer |
| --- | --- | --- |
| Mature themes | Profanity or Crude Humor (`profanityOrCrudeHumor`) | None |
| | Horror/Fear Themes (`horrorOrFearThemes`) | None |
| | Alcohol, Tobacco, or Drug Use or References (`alcoholTobaccoOrDrugUseOrReferences`) | None |
| Medical or wellness | Medical or Treatment Information (`medicalOrTreatmentInformation`) | None |
| | Health or Wellness Topics (`healthOrWellnessTopics`) | No |
| Sexuality or nudity | Mature or Suggestive Themes (`matureOrSuggestiveThemes`) | None |
| | Sexual Content or Nudity (`sexualContentOrNudity`) | None |
| | Graphic Sexual Content and Nudity (`sexualContentGraphicAndNudity`) | None |
| Violence | Cartoon or Fantasy Violence (`violenceCartoonOrFantasy`) | None |
| | Realistic Violence (`violenceRealistic`) | None |
| | Prolonged Graphic or Sadistic Realistic Violence (`violenceRealisticProlongedGraphicOrSadistic`) | None |
| | Guns or Other Weapons (`gunsOrOtherWeapons`) | None |
| Chance-based activities | Gambling (`gambling`) | No |
| | Simulated Gambling (`gamblingSimulated`) | None |
| | Contests (`contests`) | None |
| | Loot Boxes (`lootBox`) | No |

## Step 7: Additional information

- **Calculated rating**: 4+.
- **Age category and override**: **Not Applicable**. Not Made for Kids: Casement isn't for
  children, and the Kids category isn't available on visionOS in any case. No override: the GPL
  and TERMS.md set no minimum age.
- **Age suitability URL**: leave blank.
- **Korea (GRAC) RCN**: none needed.

Sources: Apple, "Age ratings values and definitions" and "Set an app age rating" (App Store
Connect Help, read 2026-10-11); App Store listings through the iTunes Search API.
