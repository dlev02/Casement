# Casement 1.2 (10) — TestFlight

## Release source

The client and widget use version 1.2, build 10, built from `58da295` on `main` (the merge of PR #24
plus the build number). No Casement Host release went with it: Host 1.8 is still the latest.

## Archives and uploads

Release archives with Xcode 27.2, signed with the 326HWBKSV6 API key and uploaded with
`asc xcode export --wait`. Each archive's bundle ID, version and build were read back.

| Platform | Build ID | State |
| --- | --- | --- |
| iPhone / iPad | `54beb751-58ee-429a-9a36-6e30d725aef3` | VALID |
| macOS | `3dfc2693-a5da-417b-8795-514903eb9f4c` | VALID |
| visionOS | `f7e9c43c-20b7-4f3f-ae35-c262ab803de8` | VALID |

Archives are in `~/Library/Developer/Xcode/Archives/2026-11-23/`, the script and logs in
`~/Developer/Casement-Releases/1.2-10/`.

## Portal

- [What to Test](../app-store/testflight-1.2-build-10.txt) is on every build.
- Internal group only (it takes every build). The builds weren't added to the external Testers group
  or submitted to beta app review, and nothing was submitted to App Review.
- Encryption: the builds read as exempt, as build 9 did.

## Proof boundaries

Before the merge, both test suites, lint and the iOS, visionOS, Mac client and Mac host builds passed
on the branch, and CI passed on the pull request. The uploaded Release builds weren't installed. Not
yet tried on a device: the bar at the top of Full Screen on the Mac, a real mouse's middle and side
buttons (Back and Forward may be swapped on an iPad), a PC opening fitted, and the Connection card on
an upright iPhone.

Two things in `main` wait for the next Casement Host: 120 frames a second, and a locked Mac saying
it's locked when a session starts at its lock screen.
