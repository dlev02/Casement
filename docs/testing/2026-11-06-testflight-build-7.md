# Casement 1.1 (7) — TestFlight delivery

## Release source

The client and widget use version 1.1, build 7, built from
`cd1ea7eb4e814c94fa498fc7010e46ff7b235d67` on `dlev/lock-delay-and-curtain-mode` (PR #16), not yet
merged. Casement Host isn't rebuilt or published: Curtain and PC scale fitting need Host 1.6, and until
it ships the Curtain toggle is dimmed and says to update.

## Archives and uploads

Release archives with Xcode 27.2, reusing `.deriveddata`, signed through the team release API key with
`asc xcode export --wait`. Each archive's bundle ID, version and build were read back. `asc` stayed at
6.5.0 although Homebrew offers an update, since another product's release was running at the same time.

| Platform | Build ID | State |
| --- | --- | --- |
| iPhone / iPad | `20396683-5e72-4449-a690-bbc6d3c896a9` | VALID |
| macOS | `0186519a-5435-459c-b11c-3867039a1313` | VALID |
| visionOS | `09ae73d8-1068-42ef-a92a-810e0b7f548e` | VALID |

Archives are in `~/Library/Developer/Xcode/Archives/2026-11-06/`, logs and portal evidence in
`~/Developer/Casement-Releases/1.1-7/`.

## Portal

- The Internal group (all builds) gets all three, and all three are in the external Testers group with
  tester notifications on. Beta review: iPhone/iPad approved at once; Mac waiting for review; Vision Pro
  not yet submitted, because Apple allows one build in review per train and Vision Pro build 6 is still
  waiting. Submit it with `asc testflight review submit --build-id <its ID> --confirm` once 6 clears.
- The TestFlight review notes say what build 7 adds and that Curtain needs Host 1.6.
- [What to Test](../app-store/testflight-1.1-build-7.txt) is on every build.
- Build 7 is attached to each 1.1 draft. **Nothing was submitted to App Review.**
- The Mac draft's What's New has the new sections; a dry run after applying reports no changes left. iOS
  and visionOS omit it because this is their first public version.
- App Review notes now say build 7 and Host 1.6 for Curtain, read back on all three.
- `asc validate` for 1.1: 0 errors and 0 blocking on all three. iOS and visionOS each warn that What's
  New is empty, as expected.

## Proof boundaries

The lock screen from inside a session, the delay, and the Curtain toggle were checked in the iPad
simulator; [the update log](../releases/1.1.md) has the story. The Mac and PC curtains ran against
real hosts with throwaway test clients (PR #16 has the numbers). Still unchecked: physical keys and mouse
being dropped, Control-Option-Command-L and Windows-L, the guard's lock path, click-through on Windows,
what the PC's panel shows, and any session from a real device with this build.
