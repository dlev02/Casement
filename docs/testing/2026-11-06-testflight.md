# Casement 1.1 (6) — TestFlight delivery

## Release source

The client and widget use version 1.1, build 6. The release source is current main through
`e229be79f37a1bbca5ec31420243123140b0708d`, plus the version-only change recorded in
`524496c`. The Mac Host stays at 1.4 (3); this release does not rebuild or publish Host installers.
The original checkout and its unrelated concept work were preserved.

## Archives and uploads

All three Release archives succeeded with Xcode 27.2 (27B52), deployment target 26.0.
`asc` was upgraded through Homebrew from 6.3.0 to 6.5.0. Archives reused the existing
`.deriveddata` cache. Cloud signing and uploads used `asc xcode export --wait` with the existing
team release API credential, passed to Xcode through its authentication flags.

| Platform | Build ID | Result |
| --- | --- | --- |
| iPhone / iPad | `98980e0a-a70b-4384-9eeb-7216fb81787b` | VALID; IN_BETA_TESTING internally; external beta review submitted |
| macOS | `c639cdd6-68eb-442f-8b7a-796ce70420ec` | VALID; IN_BETA_TESTING internally; external beta review submitted |
| visionOS | `b234dad8-b12e-4e9a-bf08-0f62c7498d25` | VALID; IN_BETA_TESTING internally; external beta review submitted |

Archives are retained in Xcode Organizer under `~/Library/Developer/Xcode/Archives/2026-11-06/`,
named `Casement-1.1-6-iOS.xcarchive`, `Casement-1.1-6-macOS.xcarchive`, and
`Casement-1.1-6-visionOS.xcarchive`. Each archive’s bundle ID and version/build were read back.

## Portal metadata and distribution

The existing iOS and visionOS draft records were moved to 1.1; a Mac 1.1 draft was created
beside the live Mac 1.0 release. Public release is manual, and no public App Review submission
was made. The version descriptions and URLs match the canonical metadata. The editable shared
subtitle is now “Control Mac & PC, privately”; the Mac update also has What’s New. iOS and
visionOS omit that store-only field because they have not had a public release.

Existing screenshot sets were retained and checked: iPhone (5), iPad (6), iPhone Duo (5), Mac (5),
and Apple Vision Pro (5). Existing App Review notes and contact details were retained, with the
1.1 build and Host 1.4 requirement appended. TestFlight review instructions were refreshed.
A metadata dry run after applying the changes reported zero remaining changes on each platform.

TestFlight targets the existing Internal group (all builds) and external Testers group.
External builds have automatic tester notifications enabled and require Apple beta review.
Group membership was verified through the build-specific group lookup. The same What to Test
notes are attached to every build. The [release story](../releases/1.1.md) includes visual examples;
the [beta notes](../app-store/testflight-1.1-build-6.txt) distinguish newer changes and regression checks.

Apple’s processed icon renditions were downloaded and visually checked on all three platforms:
each contains the new C-shaped casement artwork.

The iOS upload succeeded, but the export helper’s build-discovery wait timed out. A separate
`asc builds wait --app 6821765234 --build-number 6 --version 1.1 --platform IOS` verified VALID;
no duplicate upload was made. A helper timeout must not be treated as proof that an accepted
upload failed. Durable logs and portal evidence are in `~/Developer/Casement-Releases/1.1-6/`.

## Signing recipe

The default local ASC profile can read app state but cannot create App Store signing profiles.
A protected team release credential already exists for cloud signing. Use its environment
(`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY_PATH`) and pass the same authentication flags to
Xcode. Do not rotate or revoke certificates to address this role mismatch. No new certificate
was created; a profile-creation attempt under the limited credential was denied without mutation.

`asc signing run` is restricted to registered-device release testing in 6.5.0 and cannot wrap
App Store profiles. Cloud signing avoids changing keychain search lists or importing distribution
keys, which also avoids interfering with another product’s concurrent release.

## Proof boundaries

The prior icon integration’s simulator and visual evidence is in
[the icon verification record](2026-11-06-icons.md). This run proved Release archives, Apple upload
processing, portal state, and group assignment; it did not repeat a full device/host runtime audit.
External availability remains subject to Apple beta review. Existing public-review issues are
separate and were not marked resolved or resubmitted here.
