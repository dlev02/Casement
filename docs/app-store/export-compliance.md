# Export compliance (encryption)

**Answer: `ITSAppUsesNonExemptEncryption = NO` is correct for iOS, macOS, and visionOS.** No
documents, no CCATS, and no French declaration are needed. With the key in the build, App Store
Connect doesn't ask the encryption questions for each build.

## Why NO is right

Casement doesn't encrypt user data in transit or at rest itself. The session runs over the
user's Tailscale WireGuard tunnel, which is Tailscale's software, not part of Casement
(SECURITY.md: "the Casement stream itself isn't separately encrypted"). The crypto in the client
is limited to the uses US export rules exclude (EAR Category 5 Part 2, Note to 5A002.a:
authentication, digital signatures, and integrity):

| Use | API | Where | Purpose |
| --- | --- | --- | --- |
| Device identity: Ed25519 sign and verify | CryptoKit `Curve25519.Signing` | `Packages/VantageCore/Sources/VantageCore/Identity/DeviceIdentity.swift` | Authentication: the client signs the host's challenge |
| SHA-256 | CryptoKit `SHA256` | `FileTransferEngine` (file integrity), key fingerprints | Integrity and identification |
| macOS Screen Sharing (ARD) login: Diffie-Hellman over the server's prime, MD5, AES-128-ECB | `ModularExponent.swift` (DH math), CommonCrypto `CCCrypt` / MD5 | `Packages/VantageCore/Sources/VantageCore/ScreenSharing/ScreenSharingTyper.swift:106-140` | Authentication only: it protects the password block of Apple's own RFB authentication handshake. After login, only key events go unencrypted to the user's own Mac. |
| Keychain storage | Security framework | `Packages/VantageCore/Sources/VantageCore/Identity/KeychainStore.swift` | Apple's OS-provided encryption |
| HTTPS to `api.tailscale.com` | `URLSession` | `Vantage/Net/TailscaleAPI.swift` | OS-provided TLS |

None of this is a proprietary algorithm or a use that needs classification (no VPN, no
end-to-end messaging, no encrypted file storage). The DH step is standard Diffie-Hellman used
only for authentication, so it's covered by the same exclusion. That matches Apple's "only
exempt encryption" answer, which is exactly what `ITSAppUsesNonExemptEncryption = NO` declares.
(This is a technical reading, not legal advice. Casement Host isn't on the App Store, so it isn't
part of this declaration.)

Note: Casement relies on Tailscale for transport security but doesn't contain or ship it. The
Tailscale app is Tailscale's own App Store product with its own declaration.

## Where it's set

`INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO;` is set without an SDK qualifier, so it
applies to every platform the target builds:

| Target | Debug | Release |
| --- | --- | --- |
| `Vantage` (iOS, macOS, visionOS) | `project.pbxproj:455` | `project.pbxproj:507` |
| `VantageWidgets` (iOS appex) | not set | not set |
| `VantageHost` | not set (not on the App Store) | not set |

The extension doesn't need it: App Store Connect reads the key from the main app's Info.plist
for the whole upload. Adding it to the widget is harmless but redundant.

## Verified in built Info.plists (`.deriveddata`, 2026-10-11)

| Product | `ITSAppUsesNonExemptEncryption` |
| --- | --- |
| `Debug/Vantage.app/Contents/Info.plist` (macOS) | false |
| `Debug-iphonesimulator/Vantage.app/Info.plist` (iOS) | false |
| `Debug-xros/Vantage.app/Info.plist` (visionOS) | false |
| `Debug-xrsimulator/Vantage.app/Info.plist` (visionOS sim) | false |
| `Release-xros/Vantage.app/Info.plist` (visionOS) | false |
| `Debug-iphonesimulator/VantageWidgets.appex/Info.plist` | absent (expected) |

There is no local Release build for iOS or macOS yet, but the Release configuration carries the
same setting (`:507`). Check the archived app once before uploading:

```sh
/usr/libexec/PlistBuddy -c "Print :ITSAppUsesNonExemptEncryption" \
  <Archive>.xcarchive/Products/Applications/Vantage.app/Info.plist          # iOS / visionOS
/usr/libexec/PlistBuddy -c "Print :ITSAppUsesNonExemptEncryption" \
  <Archive>.xcarchive/Products/Applications/Vantage.app/Contents/Info.plist # macOS
```

## Other notes

- **France**: no ANSSI declaration (exempt use only).
- **Annual self-classification report to BIS**: not required for exempt-only apps.
- **If this ever changes**: an app-level encrypted transport (for example, encrypting the stream
  so LAN connections don't depend on Tailscale), end-to-end encrypted file storage, or a built-in
  VPN would be standard non-exempt encryption: set `YES` and answer the questionnaire (`asc
  encryption` manages the declaration and documents).
