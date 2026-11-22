# Casement 1.2 (9) — TestFlight

## Release source

The client and widget use version 1.2, build 9, built from `cdb0159` on `main` (the merge of PR #22),
the same commit as Casement Host 1.8. Most of the build's new features need that host.

## Archives and uploads

Release archives with Xcode 27.2, signed with the 326HWBKSV6 API key and uploaded with
`asc xcode export --wait`. Each archive's bundle ID, version and build were read back.

| Platform | Build ID | State |
| --- | --- | --- |
| iPhone / iPad | `ce4cbdcd-90bf-435f-bec5-b5e3fd0b2fd3` | VALID |
| macOS | `4be2f1e5-1706-4494-9788-0866b40a0b9c` | VALID |
| visionOS | `ae96ef7f-c0b1-4207-82e9-2e1c8e2c66ab` | VALID |

Archives are in `~/Library/Developer/Xcode/Archives/2026-11-22/`, the script and logs in
`~/Developer/Casement-Releases/1.2-9/`.

## Portal

- [What to Test](../app-store/testflight-1.2-build-9.txt) is on every build.
- Internal group (it takes every build), and each build was added to the external Testers group and
  submitted to beta app review. Testers on the public link get it once Apple approves. Nothing was
  submitted to App Review.
- Encryption: the builds read as exempt. Local network connections are encrypted by Casement with
  CryptoKit only; [export-compliance.md](../app-store/export-compliance.md) has the reasoning.

## Proof boundaries

See [the Host 1.8 log](2026-11-22-host-1.8.md) for what was run before the merge. The uploaded Release
builds weren't installed. Not yet tried on a device: three-finger swipes (the simulator has no
three-finger input), pause and resume with a live microphone, the on-device Parakeet download, the Mac
client's Settings sheet and new buttons, visionOS, and iPhone layouts in this merged build.
