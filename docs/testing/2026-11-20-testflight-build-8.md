# Casement 1.2 (8) — internal TestFlight

## Release source

The client and widget use version 1.2, build 8, built from `94d60fb` on `main`. It is 1.2 because
the macOS and visionOS 1.1 versions are already Ready for Distribution, which closes their 1.1 trains
(iOS 1.1 is still waiting for review). Casement Host isn't rebuilt or published: the virtual display
size fix for Macs that aren't 2× (`MacHostEnvironment`) reaches people with the next Host release.

## Archives and uploads

Release archives with Xcode 27.2, reusing `.deriveddata`, signed with the 326HWBKSV6 API key and
uploaded with `asc xcode export --wait`. Each archive's bundle ID, version and build were read back.

| Platform | Build ID | State |
| --- | --- | --- |
| iPhone / iPad | `d666a0f2-613e-4d3f-bb6b-156c7e5a655a` | VALID |
| macOS | `49395bd7-08ff-415f-a8f0-ed233597b959` | VALID |
| visionOS | `97d6a14e-0adf-4672-8ee1-87c816ce2585` | VALID |

Archives are in `~/Library/Developer/Xcode/Archives/2026-11-20/`, the script and logs in
`~/Developer/Casement-Releases/1.2-8/`.

## Portal

- Internal group only (it takes every build). Not added to the external Testers group, and nothing
  was submitted to beta review or App Review.
- [What to Test](../app-store/testflight-1.2-build-8.txt) is on every build.

## Proof boundaries

`CI=1 scripts/check.sh` passed and the visionOS build compiled. Full Screen, freeform resizing and the
live Fit Display switch have not been run against a real PC from a Mac yet.
