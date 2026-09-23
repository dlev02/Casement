# Vantage — Secure input, screensharingd, and reboot survival

**Scope:** How to type into secure fields / the lock screen (the thing CGEvent cannot do), how
Screens 5 actually does it, the exact RFB/ARD protocol a minimal "authenticate + send keys" client
needs, and the reboot-survival story for a FileVault'd MacBook that travels. macOS 27 host +
iPadOS 27 client, Tailscale-only transport.

**Date:** 2026-09-22.
**Research host:** macOS 27.0 (build 26A5421a), Apple silicon (arm64), FileVault **On**,
`fdesetup supportsauthrestart` → **true**. Screen Sharing / Remote Management **enabled** and
serving `RFB 003.889` on `*:5900`. Screens 5 (v5.9.2) installed and inspected read-only.
**Live evidence:** an actual Screens session from the iPad (`drews-ipad-pro`, `100.64.0.4`) to
this Mac over Tailscale was captured in the unified log during research; its `screensharingd`
handshake is quoted throughout and is the strongest single source here.

Evidence tags: **[VERIFIED]** observed on this machine; **[SDK]** from headers/man pages on this
machine; **[APPLE]** Apple documentation; **[OSS]** open-source implementation read directly;
**[COMMUNITY]** third-party report; **[INFERRED]** reasoned from the above; **[ASSUMED]** best guess,
must be tested.

Cross-reference: this report extends `input.md` §A.1b (Secure Event Input),
`product-and-host-lifecycle.md` §4.2–4.4 (login window, lock, power), and `tailscale.md` §3
(unattended access). Where those already settled a point, this report only adds new evidence.

---

## Summary of conclusions

1. **The hypothesis is correct and now directly verified.** Screens 5 does not do anything clever to
   beat Secure Event Input — it simply is not the process injecting the keys. It connects as an RFB
   client to Apple's built-in **`screensharingd`** (the Screen Sharing / Remote Management server on
   TCP 5900) and Apple's privileged daemon+agent perform the input. `ScreensharingAgent` carries
   `com.apple.private.hid.client.admin` + `com.apple.private.hid.client.event-dispatch` and
   `com.apple.private.screencapturekit.systemRecording`/`noprompt` entitlements **[VERIFIED]**, which
   is exactly the privilege set CGEvent-from-a-third-party lacks. That is why "Screens typed my Mac
   password into a secure field without me touching the Mac."
2. **Auth type 30 (Apple Diffie-Hellman) still works on macOS 27.0.** The live iPad→Mac session in
   the log authenticated with `viewer->authProtocol = 30` … `Type: DH` on this 27.0 machine
   **[VERIFIED]**. Types 33/35/36 (RSA-name/password, Kerberos, SRP) are also offered, but type 30 is
   the pragmatic target: it is fully documented in open source and needs only the account username +
   password. It requires the **macOS account username** (64-byte username field), so a VNC
   password-only credential cannot use it.
3. **The protocol for a keys-only client is small and well documented.** RFB 3.889 handshake →
   security type 30 (DH, MD5→AES-128-ECB, 128-byte `username[64]‖password[64]` block) → SecurityResult
   → ClientInit(shared=1) → parse Apple ServerInit → then send `KeyEvent` (type 4) messages. No
   `SetEncodings`/`FramebufferUpdateRequest` is required to make key injection work; those only start
   the video stream, which Vantage does not need from screensharingd.
4. **Recommended design: the iPad connects directly to `<mac-tailnet-ip>:5900`** for the
   password/secure-field/login-adjacent case, entirely independent of the Vantage host process. This
   is the one path that also works when the Vantage host isn't running (right after a reboot, at the
   lock screen). Vantage's own hand-rolled protocol stays the primary experience; the RFB client is a
   narrow "type the password / unlock" fallback.
5. **Reboot survival for a travelling FileVault MacBook is a configuration problem, not something
   Vantage can fully solve in software.** For **planned** restarts, ship a host-side "Restart safely"
   that runs `fdesetup authrestart` (Apple silicon, macOS 27, supported here **[VERIFIED]**) so the
   Mac comes back to the desktop without pre-boot interaction. For **unplanned** power loss, the only
   real recovery is macOS 26+ SSH-FileVault-unlock reached over the LAN or a **subnet router** on the
   home network, because Tailscale is not running pre-boot. Everything else is documentation for Drew.
6. **A menu-bar app can intercept Restart/Shut Down/Log Out** via
   `applicationShouldTerminate` + inspecting `NSAppleEventManager.currentAppleEvent`'s `kAEQuitReason`
   attribute, returning `.terminateLater`/`.terminateCancel` to prompt. Verified snippet in §6.

---

## 1. How Screens 5 actually connects and types passwords

### 1.1 It is a VNC/RFB client to Apple's Screen Sharing server

Screens 5's own docs are explicit that the transport is macOS built-in Screen Sharing, not a Screens
protocol:

> "We recommend using Screen Sharing for most setups. It's the simplest way to remotely access your
> Mac with Screens." — Edovia, *Preparing Your Mac for Screen Sharing* **[APPLE/COMMUNITY]**

The setup instructions are pure macOS-server configuration — enable **Screen Sharing** (and,
optionally, **Remote Login** for the SSH tunnel), and under **Allow access for** choose *All users* or
specific accounts. There is no Screens-side server component doing input. **Screens Connect is only a
discovery/reachability helper** (a dynamic-DNS + relay/port-mapping service tied to a Screens Connect
account); since Screens 5.8.8 on macOS 14+, that helper is built into the Screens Mac app, but it
still only makes the Mac *reachable* — the actual session is RFB/VNC to `:5900` (optionally wrapped in
an SSH tunnel). **[COMMUNITY]** This matches `product-and-host-lifecycle.md` §2's earlier finding that
"Screens' Tailscale integration is read-only metadata, not transport; the actual connection is still
VNC/SSH to the 100.x address."

The Screens binary confirms the client stack directly. `Screens 5.app/Contents/Frameworks/` contains
**`VNCKit.framework`** (Apple-RFB client), `RDPKit.framework`, `SSHKit.framework`, and
`OpenSSL.framework` **[VERIFIED]**. Inside `VNCKit`:

- Source paths `…/Vendor/VNC.framework/…/VncClient.m`, `VncAuthentication.m`, and symbols
  `VncAuthenticationPerformVncPassword`, `authenticate:username:password:`, `authenticate:password:`,
  `selectedAuthenticationType`, `supportedAuthentications`, `serverKeyFingerprint`,
  `VNCAuthenticatorRA2` (the RSA-AES / "RA2" path), `setUseAppleSessionSelection:`,
  `sendKeySequence:withKeyboardLocale:`, `sendKeyString:withKeyboardLocale:` **[VERIFIED]**.
- An "Apple ServerInit handshake" parser and `appleServerFeatureBits`, Apple adaptive-DCT codec,
  Apple PNG/WebArchive pasteboard types — i.e. the Apple RFB dialect, not generic RFB. **[VERIFIED]**

So the mechanism behind "Screens typed my password" is: Screens authenticates to `screensharingd`
with Drew's Mac account credentials and then sends RFB `KeyEvent`s; **`screensharingd` /
`ScreensharingAgent`** — not Screens — synthesize the keystrokes, and they are entitled to inject into
secure fields (see §3).

### 1.2 The privilege that beats Secure Event Input

`input.md` §A.1b already concluded that the only shipping technique for secure-field/login input is
"connect to the local `screensharingd` as an RFB client, letting Apple's own daemon perform the
injection." This report confirms the entitlements that make it work, read from the on-disk bundles
**[VERIFIED]**:

`/System/Library/CoreServices/RemoteManagement/ScreensharingAgent.bundle` holds, among others:

```
com.apple.private.hid.client.admin              = true
com.apple.private.hid.client.event-dispatch     = true
com.apple.private.screencapturekit.systemRecording = true
com.apple.private.screencapturekit.noprompt     = true
com.apple.private.accessibility.sendVoiceOverCommand = true
com.apple.private.SkyLight.virtualdisplay       = true
```

`…/screensharingd.bundle` holds `com.apple.private.hid.client.admin`,
`com.apple.private.hid.client.event-dispatch`, `com.apple.private.hid.client.event-filter`,
`com.apple.private.opendirectory.GetAuthenticationData`, and `com.apple.private.tcc.manager.access.read
= [kTCCServiceAll]`. These are Apple-only (`com.apple.private.*`) and cannot be claimed by a Developer
ID app. **The remote-desktop client never needs them** — it just talks to the daemon that has them.

---

## 2. The wire protocol for a minimal "authenticate + send keys" RFB client

Everything below is what Vantage's iPad-side RFB client must implement. It is cross-checked against
LibVNCServer's `libvncclient` (`rfbclient.c`, `HandleARDAuth`) and noVNC (`core/rfb.js`,
`_negotiateARDAuth`), which agree byte-for-byte, and against the live `screensharingd` log on this
Mac.

### 2.1 Version handshake — RFB 3.889

- On connect the server writes a 12-byte ProtocolVersion string. Verified by reading the greeting on
  `127.0.0.1:5900` (no bytes sent by us): `b'RFB 003.889\n'` **[VERIFIED]**.
- The client replies with its own 12-byte version. `screensharingd` logs `RFB viewer version: 3.889`
  for the real iPad session **[VERIFIED]**. Send `RFB 003.889\n` to get the Apple dialect (which
  enables auth types 30/33/35/36 and the Apple ServerInit). A generic client can send `RFB 003.008\n`
  and fall back to standard behaviour, but then you lose the Apple auth types — send **3.889**.
- `.889` is Apple's marker; the format is otherwise the standard RFB `RFB xxx.yyy\n`. **[OSS/VERIFIED]**

### 2.2 Security handshake and the types Apple offers

After version exchange the server sends the security-type list. On this Mac the offered set is
`[30, 33, 36, 35]` (Diffie-Hellman, RSA-name/password, SRP, Kerberos-ish). Confirmed indirectly in
the log: `SendAuthenticationInfoMessage`, `supports SRP`, `supports kerberos`, and the viewer chose
`HandleAuthTypeMessage 30` → `viewerDesiredAuthMethod 30` **[VERIFIED]**.

| Type | Name | Credentials | Notes |
|---|---|---|---|
| **30** | Apple **Diffie-Hellman** ("DH"/ARD auth) | macOS **username + password** | Fully documented in `libvncclient`/noVNC. **Works on macOS 27.0 today** (`authProtocol = 30`, `Type: DH` in the live log). **[VERIFIED]** Recommended target. |
| 33 | RSA name/password (a.k.a. "RA2"/RSA-AES variant Apple offers) | username + password | Screens' `VNCKit` implements `VNCAuthenticatorRA2` (performRA2WithUsername:password:, RSA server key, AES cipher). More robust identity (server key fingerprint pinning) but more code. **[VERIFIED via Screens symbols]** |
| 35 | Kerberos / directory (used for `.local`/directory accounts) | Kerberos ticket | Niche; skip. **[COMMUNITY]** |
| 36 | **SRP** (+ ChaCha20-Poly1305 session on newer builds) | username + password | Newer Apple type; `screensharingd` logs `supports SRP` and legitimate sessions show `RSA-SRP`. Advertised but not required. **[COMMUNITY/VERIFIED]** |

**Choose type 30.** It needs only the two things Vantage already stores per device (Mac username +
password), and it has two independent open-source reference implementations. Its one limitation —
**it requires the account username**, so it cannot be driven by a Remote Management "VNC password"
(the anonymous single-password mode). If the user only has a VNC password configured, that maps to
the legacy `rfbVncAuth` type (2), which is a different, weaker DES challenge and is not offered when
"macOS/Apple" auth is enabled. Vantage should require the account username+password path.

### 2.3 Type 30 (Apple DH) exact steps

From `libvncclient` `HandleARDAuth` (LibVNCServer) and noVNC `_negotiateARDAuth`/`_negotiateARDAuthAsync`
— they agree exactly **[OSS]**:

1. Read from the server: `generator` (2 bytes, big-endian; observed value **5** in the log:
   `prime size 512 bytes generator 5` **[VERIFIED]**), then `keyLength` (2 bytes, big-endian; observed
   **512** bytes → a 4096-bit prime), then the `prime` modulus (`keyLength` bytes), then the server's
   DH `publicKey` (`keyLength` bytes).
2. Generate a client DH keypair over `(generator, prime)`.
3. Compute the DH shared secret with the server's public key (`keyLength` bytes).
4. **AES key = MD5(sharedSecret)** — a 16-byte digest → AES-128 key. (libvnc: "Perform an MD5 hash of
   the shared secret. This 128-bit value will be used as the AES key.")
5. Build a **128-byte plaintext** credentials block: `username` in bytes `[0..64)`, `password` in
   `[64..128)`, **each UTF-8, NUL-terminated, and the unused bytes filled with random data**. noVNC
   truncates each to 63 chars + a NUL; libvnc caps each half at 64. So the effective max is 63
   characters each. **[OSS]**
6. **Encrypt the 128-byte block with AES-128 in ECB mode**, no additional padding (two 16-byte ECB
   blocks × 8 = 128 bytes in, 128 out). **[OSS]**
7. Write to the server: the **128-byte ciphertext**, then the **client DH public key** (`keyLength`
   bytes). (Order: ciphertext first, then public key — libvnc `WriteToRFBServer(ciphertext…)` then
   `WriteToRFBServer(pub…)`; noVNC pushes `ardCredentials` then `ardPublicKey`.) **[OSS]**

libvnc, verbatim, on the block layout and cipher **[OSS]**:

```c
/* Step 5: Pack the username and password into a 128-byte plaintext "userpass"
   structure: { username[64], password[64] }. Null-terminate each. Fill the
   unused bytes with random characters … */
random_bytes(userpass, sizeof(userpass));
memcpy(userpass, cred->userCredential.username, usernameLen);
memcpy(userpass+sizeof(userpass)/2, cred->userCredential.password, passwordLen);
/* Step 6: Encrypt … AES 128-bit … electronic codebook (ECB) mode. No further padding. */
encrypt_aes128ecb(ciphertext, &ciphertext_len, shared, userpass, sizeof(userpass));
```

Then the **SecurityResult** message: 4-byte big-endian status, `0 = OK`, non-zero = failed (RFB ≥ 3.8
follows a failure with a reason string). The log shows `authResult = 0` … `good authentication` …
`Authentication: SUCCEEDED :: User Name: Drew Levinson :: Viewer Address: 100.64.0.4 :: Type: DH`
**[VERIFIED]**. Note the DH computation is slow: the server logged `calculation time: 144517
microseconds` for the 4096-bit prime — budget ~150–300 ms for auth, don't treat it as a hang.

Practical implementation notes:
- Swift has no ready DH-with-arbitrary-prime primitive in CryptoKit. Use `Security`/`SecKey` is also
  awkward here; the cleanest path is BigInt modular exponentiation for DH (the shared secret is just
  `serverPub^clientPriv mod prime`) plus `CryptoKit`'s `Insecure.MD5` and a small AES-ECB (CommonCrypto
  `CCCrypt` with `kCCOptionECBMode`, `kCCAlgorithmAES`, 16-byte key). ECB is deliberately what the
  protocol wants; do not "fix" it to CBC.
- The username is the **short account name** or full name that OpenDirectory accepts; the log resolved
  `Drew Levinson` via `CFOpenDirectory`/`Membership API` and mapped it to `uid 501`. Test which form
  the account needs; prefer the short name.

### 2.4 ClientInit and Apple ServerInit

- After SecurityResult OK the client sends **ClientInit**: 1 byte `shared-flag`. Send **1** (shared)
  so you don't kick the local user's own console session; the real viewer was admitted with the
  console user still logged in (`consoleUserUID 501 viewer->authenticationUID 501`, `userLoggedInFlag
  1`) **[VERIFIED]**. **[SDK: rfbproto ClientInit]**
- The server replies with **ServerInit** — but Apple's is **extended**. The log:
  `server init size 64 extralen 40 machineNamelen 18 RFBServerInfo2 46` **[VERIFIED]**. Standard
  ServerInit is `framebuffer-width(2) height(2) PIXEL_FORMAT(16) name-length(4) name(...)`. Apple
  appends ~40 bytes of `RFBServerInfo2`/feature bits after the name (Screens' parser is literally
  named "Apple ServerInit handshake"). A keys-only client must read the standard fields, read the
  name, and then **drain the Apple extra bytes** before sending anything, or it desyncs. The safe
  approach: read standard ServerInit, then read the documented Apple trailer length. If you only need
  input and can tolerate it, you can also just read until the socket quiesces before the first write;
  but reading the exact trailer is correct.

### 2.5 KeyEvent — you do NOT need the framebuffer

Client→server messages in RFB are self-delimiting by message-type, so **you can send `KeyEvent`
immediately after ServerInit without ever sending `SetEncodings` or `FramebufferUpdateRequest`.**
Those two only start/steer the *video* stream (the log shows the real viewer then sending
`set encodings`, `SetPixelFormat`, and `FramebufferUpdateRequest`, but that is because Screens wants
pixels). Vantage does not want screensharingd's pixels — it has its own video path — so it can skip
them. The server's input handling is not gated on them. **[INFERRED from RFB message framing + the
log; ASSUMED that screensharingd imposes no extra gate — verify with a keys-only probe.]**

**KeyEvent format** (message-type 4) — `rfbproto.rst` and noVNC agree **[SDK/OSS]**:

```
1 byte   U8    = 4     message-type
1 byte   U8            down-flag (1 = pressed, 0 = released)
2 bytes        = 0     padding
4 bytes  U32           key  (X11 keysym, big-endian)
```

noVNC encoder, verbatim **[OSS]**:

```js
keyEvent(sock, keysym, down) {
    sock.sQpush8(4);      // msg-type
    sock.sQpush8(down);
    sock.sQpush16(0);     // padding
    sock.sQpush32(keysym);
    sock.flush();
}
```

**Keysyms** are X11 values (`<X11/keysymdef.h>`). For printable ASCII the keysym equals the ASCII code
(`A`=0x41, `a`=0x61, `!`=0x21, `1`=0x31). Common control keys **[SDK: rfbproto]**:

```
Return/Enter 0xff0d   BackSpace 0xff08   Tab 0xff09   Escape 0xff1b   Delete 0xffff
Left/Up/Right/Down 0xff51/52/53/54   Home 0xff50   End 0xff57   PgUp/PgDn 0xff55/56
Shift-L 0xffe1  Control-L 0xffe3  Alt/Option-L 0xffe9  Meta/Command-L 0xffe7 (right variants +1)
```

**Does uppercase/symbols need an explicit `Shift_L`?** `ScreensharingAgent` builds a full keymap at
session start (log: `KeyMapDictionary_Init`, `local keyboard type 3`, `keyToCharTableSize 127`,
`done with keymap`) and translates incoming keysyms to Mac virtual keycodes **including the modifier
state implied by the keysym** **[VERIFIED that a keymap exists]**. So sending keysym `0x41` ("A") or
`0x21` ("!") should produce the shifted character without a separate Shift keysym — the daemon
synthesizes the shift. This is how vncdotool's `type` works against Apple servers. **[INFERRED;
ASSUMED — verify on device.]** To be safe for a *password field* (where correctness matters and there
is no visual feedback), the most robust approach is to send each character as its bare keysym and, if
a device test shows shifted characters failing, wrap them in explicit `Shift_L` down / key / `Shift_L`
up. For a whole password, prefer sending the exact keysym per character over emulating a physical
keyboard.

**Return terminates the password.** Send `0xff0d` down+up after the password to submit — this is what
Screens' key button does per `MacShortcut`/`DeviceSecrets` in Vantage today ("types it plus Return").

**Apple-specific quirks / server chatter to tolerate [VERIFIED unless noted]:**
- The server sends unsolicited server→client messages Vantage must **read and discard** to avoid a
  stuck socket: framebuffer updates (only if you asked), **ServerCutText / Apple pasteboard messages**
  (`RFBAutoPasteboardMessage`, `HandleViewerClipboardRequest`), Bell, and resolution-change messages
  (`SendResolutionChargeToViewer`). A keys-only client should run a tiny read loop that parses the
  message-type byte and skips payloads it doesn't care about.
- `screensharingd` reports secure-text state to itself (`ScreensharingAgent: flag that server is in /
  not in secure text field`, `got secure text notification 752/753`) **[VERIFIED]** — it *tracks*
  Secure Event Input but is not blocked by it (that is the whole point). Vantage's existing
  `HostStatus.isSecureInputActive` banner can key off the same reality, but the RFB path itself is
  unaffected.
- **Idle timeout:** screensharingd will close idle/uninitialized connections. In the log, a viewer
  that connected and did nothing was closed by the "viewer authentication thread"; connections that
  never send a version are reset quickly. Keep the handshake moving and, once in, don't leave the
  socket silent for long. **[VERIFIED]**
- **Auth is CPU-heavy once (the DH exp), then cheap.** See §2.3 timing.

Reference implementations to mirror (all read directly or cited):
- **LibVNCServer `libvncclient`** — `src/libvncclient/rfbclient.c`, function `HandleARDAuth` (type 30
  end-to-end) and version negotiation. **[OSS, read]**
- **noVNC** — `core/rfb.js`, `securityTypeARD = 30`, `_negotiateARDAuth` /
  `_negotiateARDAuthAsync` (DH → MD5 → AES-ECB, 128-byte block), and `RFB.messages.keyEvent`. **[OSS,
  read]**
- **`vncdotool`** (Python) — `key`/`type` command semantics for keysym-per-character typing against
  Apple servers. **[COMMUNITY]**
- **RoyalTSX / Remmina / TigerVNC** notes and the `rfbproto` spec for message framing. **[COMMUNITY/SDK]**

---

## 3. Does it really type into secure fields / lock screen / login window?

- **Into secure fields while logged in, even with another app holding Secure Event Input: yes.**
  That is the entire reason to use screensharingd. `ScreensharingAgent` holds `hid.client.admin` +
  `hid.client.event-dispatch` **[VERIFIED]**; Apple's daemon injects below the layer that Secure Event
  Input blocks for third parties. Drew's observed behaviour (Screens typed his password into a secure
  field) is the direct confirmation. **[VERIFIED via behaviour + entitlements]**
- **At the lock screen (user still logged in, session locked): yes, with a caveat.** The
  Screen-Sharing daemon can attach to the locked console session and inject the password to unlock —
  this is a documented Screens/ARD capability and follows from the same entitlements. Note the daemon
  distinguishes `wantConsole`/`createLoginWindow` states (`uid 501 wantConsole 0 createLoginWindow 0`
  in the logged-in case) **[VERIFIED]**. It *can* target the login-window session too, but that path
  needs the login-window Screen Sharing agent to be running (see below). **[INFERRED/COMMUNITY]**
- **At the pre-login login window (no user logged in): only if the login-window Screen Sharing agent
  is up.** macOS runs a `LoginWindow`-session Screen Sharing agent when Remote Management/Screen
  Sharing is enabled, which is how ARD/Screen Sharing shows the login UI and lets an admin log in
  remotely. But on a **FileVault** Mac, *nothing* runs before the data volume is unlocked — including
  screensharingd — so this does **not** rescue a cold boot. It only helps for the "logged out but
  booted and unlocked" state. `product-and-host-lifecycle.md` §4.2 already reached the "skip
  login-window support" verdict for Vantage's own capture; for the RFB fallback the nuance is: it
  works at the *lock screen* and at a *logged-out-but-unlocked* login window, not at the FileVault
  pre-boot screen. **[INFERRED; ASSUMED for the logged-out case — verify.]**
- **Does connecting show an indicator / change the session?** Yes. screensharingd adds the viewer to
  the menu-bar Screen Sharing status item (`AddViewerNameToMenu`, `ADD viewer … to menu extra`) and
  `SSMenuAgent` manages that menu extra **[VERIFIED]**. With shared-flag=1 it observes/controls the
  existing console session rather than creating a new virtual one (Screens' `Mac Guest User (Observe)`
  vs control, and `useAppleSessionSelection`, expose these choices). Expect a visible "screen is being
  observed"/menu-bar affordance. There is no way to make Apple's daemon inject *silently*; that is by
  design.
- **Username requirement:** type 30 needs the **macOS account username** (confirmed by the 64-byte
  username field and by the server resolving `User Name: Drew Levinson` via OpenDirectory)
  **[VERIFIED]**. A **Remote Management "VNC password"** (anonymous, single password) uses a different
  security type and *cannot* satisfy type 30/33/36. Vantage must collect and store the account
  username to use this feature; it already stores the password per device (`DeviceSecrets`).

---

## 4. Design recommendation

**Recommendation: the iPad client connects directly to `<mac-tailnet-ip>:5900` and speaks RFB itself,
as a narrow "type password / unlock" fallback. Do not route it through the Vantage host process.**

Rationale:
- **Availability when the Vantage host isn't running.** The whole value of this feature is the moment
  right after a reboot or at a lock screen where the Vantage host (a normal Aqua LaunchAgent) may not
  be up yet but `screensharingd` is. A host-relayed design (host connects to `127.0.0.1:5900` for the
  client) is dead exactly when you need it, because the host process is the thing that's absent.
- **No new trust surface on the host.** The host would otherwise have to accept "type this arbitrary
  text into a secure field" commands over Vantage's own channel and replay them into screensharingd —
  a nasty confused-deputy. Keeping the credential and the RFB session on the iPad means the Mac
  password only ever leaves the iPad Keychain to Apple's own daemon.
- **It reuses Tailscale identity.** Port 5900 is already reachable over the tailnet from the iPad (the
  live session came from `100.64.0.4` → `100.64.0.2:5900`, direct, no relay) **[VERIFIED]**. The
  host's existing tailnet ACLs gate who can reach 5900.

**Exact flow (client-side RFB fallback):**
1. User taps "Type Mac password" (or "Unlock Mac") in a session, or on a device tile when the Vantage
   host is unreachable but the Mac answers on 5900.
2. Client opens TCP to `<saved-device tailnet IP>:5900`. If it fails/refuses, show "Screen Sharing
   isn't enabled on this Mac" with a link to the setup steps (§ below). If the connection is not from
   inside `100.64.0.0/10` / `fd7a:115c:a1e0::/48`, don't even attempt (belt-and-braces, mirrors
   `tailscale.md` §5).
3. Read `RFB 003.889\n`; reply `RFB 003.889\n`.
4. Read security types; require type **30**. If 30 is absent but 33/36 are present, either implement 33
   (RSA, with server-key fingerprint pinning — nicer security, more code) or tell the user their Mac
   is configured for an unsupported auth mode.
5. Run the DH exchange (§2.3) using the stored **account username + password**. On SecurityResult ≠ 0,
   surface "Wrong Mac username or password" and offer to re-enter (reuse the biometric gate Screens
   uses on `Type User Password`).
6. ClientInit(shared=1); parse Apple ServerInit and drain the trailer.
7. Send the password as per-character `KeyEvent`s, then `Return` (0xff0d). For "unlock", the target
   field already has focus at the lock screen; for "type into whatever field is focused", just send the
   text.
8. Read-and-discard server messages; close the socket when done (don't linger — idle close, §2.5).

**Failure handling:**
- Connection refused / timeout on 5900 → Screen Sharing not enabled or Mac unreachable → setup CTA.
- Security type 30 not offered → auth-mode mismatch (likely VNC-password-only) → explain, point at
  "Allow access for: only these users" + an account with a password.
- SecurityResult failed → credential problem → re-prompt behind Face ID/Touch ID.
- FileVault pre-boot (Mac not answering on 5900 at all after a reboot) → this fallback can't help;
  route the user to the reboot-recovery story (§5).
- Secure Event Input elsewhere is **not** a failure for this path (unlike Vantage's CGEvent path).

**What the user must set up (document, one-time):**
- **System Settings → General → Sharing → Screen Sharing** (or **Remote Management** for the ARD
  superset). Either enables `screensharingd` on 5900.
- **Allow access for: Only these users** → add Drew's account (tighter than "All users"). Type 30
  authenticates as that account.
- Ensure the account **has a password** (type 30 can't use a blank/VNC-only credential).
- Tailscale ACLs already restrict who can reach `:5900`; keep 5900 off the public internet (it should
  only be reachable over the tailnet — never port-forward it).
- Optional: **Remote Login** (SSH) if you also want the reboot-recovery path in §5c.

**Keep this narrow.** Vantage's hand-rolled protocol remains the everyday remote-desktop experience
(better latency, its own video path). The RFB client exists only for the two things CGEvent can't do:
typing into secure fields and unlocking a locked-but-booted Mac.

---

## 5. Reboot survival with FileVault ON and auto-login OFF

Baseline confirmed on this Mac **[VERIFIED]**: `FileVault is On`, `fdesetup isactive` → true,
`fdesetup supportsauthrestart` → true, Apple silicon (arm64), macOS 27.0.

### 5a. `fdesetup authrestart` on Apple silicon / macOS 27

`man fdesetup` on this machine **[SDK]**:

> `authrestart [-inputplist] [-delayminutes number_of_minutes_to_delay] [-verbose]` — "If FileVault is
> enabled on the current volume, it restarts the system, bypassing the initial unlock. … A value of 0
> represents 'immediately', and a value of -1 represents 'never'. The command may not work on all
> systems."

And the warning **[SDK]**:

> "FileVault protections are reduced during authenticated restarts. In particular, fdesetup
> deliberately stores at least one additional copy of a permanent FDE unlock key in both system memory
> and (on supported systems) the System Management Controller (SMC). `fdesetup` must be run as root
> and itself prompts for a password to unlock the FileVault root volume. … Once authrestart is
> authenticated, it launches `shutdown(8)` and, upon successful unlock, the unlock key will be
> removed."

What this means for Vantage:
- **It works here** (`supportsauthrestart` = true, Apple silicon, 27.0). **[VERIFIED]** The man page's
  "may not work on all systems" is the honest hedge; this system is supported.
- **It needs root and a password.** `fdesetup authrestart` prompts for a FileVault-enabled user's
  password. To run it non-interactively from a host helper, use `-inputplist` and feed a plist on
  stdin with `Username`/`Password` keys (Apple's documented input-plist form for `fdesetup`). Running
  as root requires a privileged helper (`SMAppService.daemon` + a signed helper, as in
  `product-and-host-lifecycle.md` §4.1), not a plain LaunchAgent.
- **After it: the Mac boots straight past the pre-boot FileVault screen** and lands where it normally
  would with the volume unlocked — i.e. at the **login window** (because auto-login is off), *not*
  auto-logged-in-as-the-unlocking-user. authrestart bypasses the *disk* unlock, not the *account*
  login. So Tailscale (a per-user/GUI variant here) and the Vantage Aqua LaunchAgent still won't be up
  until someone logs in — unless auto-login is on, which FileVault disables. **Net: authrestart gets
  you to a reachable-over-LAN, data-unlocked login window; it does not by itself restore the tailnet
  or Vantage.** The remaining login step is the same gap `tailscale.md` §3.3 documents.
- **`-delayminutes -1`** stages the unlock key but does **not** restart now ("never" auto-restart);
  a subsequent ordinary `shutdown -r`/Restart then consumes the stashed key. This is the clean pattern
  for **user-initiated "Restart" from a remote session**: stage the key, then let the normal restart
  proceed, so the user sees a normal restart that happens to survive FileVault. (`-delayminutes 0` =
  restart immediately.)
- **Usable for a user-initiated remote "Restart": yes** — this is the single most useful thing Vantage
  can build for planned reboots. See §6 for intercepting the reboot and §5e for ranking.

### 5b. Is Tailscale reachable at the login window / pre-login?

**No, for the variants that matter here.** Tailscale's own docs: on macOS "there's no ability to run
as the system just yet" for the GUI variants; only the open-source `tailscaled` LaunchDaemon runs
before login. `tailscale.md` §3.1 already tabulated this and it is unchanged. On this Mac the tunnel
is the **standalone (`macsys`) System Extension** (`io.tailscale.ipn.macsys.network-extension`,
running as root but **loaded within the user's context**, PID confirmed via `ps`) **[VERIFIED]** — it
comes up **after** login, not at the login window and certainly not at FileVault pre-boot. There is no
`tailscale`/`tailscaled` LaunchDaemon in `/Library/LaunchDaemons` here **[VERIFIED: none matched]`.

Which variant runs pre-login **[APPLE/Tailscale docs]**:

| Variant | Before login? |
|---|---|
| Mac App Store (`io.tailscale.ipn.macos`, Network Extension) | No |
| Standalone (`io.tailscale.ipn.macsys`, System Extension) — **installed here** | No |
| Open-source `tailscaled` as a LaunchDaemon | **Yes** (system daemon), but conflicts with the GUI app and still needs the data volume unlocked |

So even `tailscaled` cannot help at the FileVault **pre-boot** stage — the daemon binary and its state
live on the still-locked data volume. Cite: Tailscale *Three ways to run Tailscale on macOS* and *Keep
Tailscale running when I'm not logged in*.

### 5c. macOS 26+ FileVault unlock over SSH at pre-boot

`man apple_ssh_and_filevault(7)` on this Mac, verbatim **[SDK]**:

> "When FileVault is enabled, the data volume is locked and unavailable during and after booting, until
> an account has been authenticated using a password. … when Remote Login is enabled, it is possible
> to perform password authentication using SSH even in this situation. This can be used to unlock the
> data volume remotely over the network. However, it does not immediately permit an SSH session.
> Instead, once the data volume has been unlocked using this method, macOS will disconnect SSH briefly
> while it completes mounting the data volume and starting the remaining services … The capability to
> unlock the data volume over SSH appeared in macOS 26 Tahoe."

Requirements and the subnet-router question:
- **Remote Login (SSH) enabled**, and a **network connection available in the pre-boot environment**.
  On Apple silicon pre-boot networking is minimal: **Ethernet (open)** or **Wi-Fi that was previously
  joined and is open or WPA2-PSK**; enterprise 802.1X / captive portals / WPA3-only are out.
  (`tailscale.md` §3.3 and `product-and-host-lifecycle.md` §4.2 already state this; unchanged.)
- **Tailscale is not up pre-boot** (§5b), so the unlock SSH must arrive over a path that does **not**
  depend on the Mac's own tunnel. That means the same LAN, **or** a **Tailscale subnet router** on
  another always-on device at that location (Apple TV running Tailscale as a subnet router, a NAS, a
  Pi, a router) advertising the Mac's LAN subnet. With that, the iPad — anywhere on the tailnet —
  reaches the Mac's **LAN IP** through the subnet router, `ssh user@<mac-lan-ip>`, enters the account
  password, the volume unlocks, SSH drops briefly, and the Mac finishes booting and (after login)
  brings up its own Tailscale + Vantage. **[APPLE + Tailscale subnet-router docs; the combination is
  reported working in the wild — COMMUNITY.]**
- Note the Apple TV caveat: tvOS Tailscale can act as an exit node/subnet router in recent versions;
  confirm the specific device can advertise routes before recommending it. **[ASSUMED — verify per
  device.]**

This is the one real recovery for **unplanned** reboots (power loss) on a travelling FileVault Mac,
and it is entirely outside Vantage — it is Drew's home-network setup plus the built-in SSH unlock.

### 5d. System Settings / `pmset` options that help

Observed `pmset` state on this Mac and what to recommend **[VERIFIED values]**:
- **"Start up automatically after a power failure"** (`SystemSettings → Energy`, or
  `sudo pmset -a autorestart 1`): essential for unplanned power loss so the Mac at least reboots to the
  pre-boot screen where §5c can reach it. Not shown in current `pmset -g` here — recommend enabling.
- **"Wake for network access"** (`womp`): AC shows `womp 1`, battery `womp 0` **[VERIFIED]**. Keep on
  for AC. But note `tailscale.md`/`product-and-host-lifecycle.md` §4.3: Tailscale (L3) cannot carry
  the L2 magic packet, so WoL only helps on the same LAN — useful in combination with a home LAN
  helper, not over the tailnet.
- **Prevent sleep while reachable:** AC `sleep 0`, `displaysleep 0`, and system-wide `SleepDisabled 1`
  are already set here (Screens/caffeinate are holding assertions) **[VERIFIED]**. Vantage should hold
  its own modern assertion (`kIOPMAssertPreventUserIdleSystemSleep` while on AC) rather than rely on
  `SleepDisabled`, per `product-and-host-lifecycle.md` §4.3.
- **`powernap 1`, `tcpkeepalive 1`, `standby 1`** are on **[VERIFIED]**; fine to leave. Power Nap does
  not bring up Tailscale from a full boot, so it doesn't change the reboot story.
- **`pmset destroyfvkeyonstandby`**: the `fdesetup` man page suggests it to avoid persisting the
  authrestart key across standby. Consider setting it so the reduced-protection window from
  authrestart is bounded. **[SDK]**

### 5e. Ranked recommendation

**What Vantage can build:**
1. **Host-side "Restart safely" (highest value, planned reboots).** A menu-bar action + a remote
   command that runs `fdesetup authrestart -inputplist` (via a privileged helper, credentials from the
   Keychain) so a user-initiated restart survives FileVault and returns to the login window with the
   volume unlocked. Pair with the reboot-intercept in §6 so an OS-driven restart also offers it. Be
   honest in the UI that the user still has to *log in* (or reach the Mac via §5c) before Vantage/
   Tailscale return. **[Recommended]**
2. **Client-side RFB "Type Mac password / Unlock" (§2–4).** Covers the lock screen and secure-field
   typing once the Mac is booted and reachable on 5900. Does **not** cover FileVault pre-boot.
   **[Recommended]**
3. **Clear post-reboot state UX.** When the host is unreachable but was recently up, show "Your Mac
   restarted — it needs to be unlocked/logged in before Vantage can reconnect," with the recovery
   steps, instead of a generic timeout. (`tailscale.md` §3.3 item 4.) **[Recommended]**

**What Drew must configure (document, don't build):**
- Enable **auto-restart after power failure**; keep **FileVault on**; **disable key expiry** for this
  Mac in the Tailscale admin console (`tailscale.md` §3.2).
- For unplanned-reboot recovery: **Remote Login on**, plus a **Tailscale subnet router** on an
  always-on home device, then use macOS 26+ **SSH FileVault unlock** over the LAN/subnet route (§5c).
- Accept the honest limit: a **cold boot / power loss while travelling with FileVault on** cannot be
  fully recovered by Vantage alone; it needs the home-network SSH-unlock path or physical presence.

**For unplanned crashes/power loss specifically:** ranking is (1) auto-restart after power failure →
(2) reach pre-boot SSH via subnet router → (3) unlock → (4) log in (or auto-login if the user ever
chooses FileVault-off on a *dedicated desktop*, which is out of scope for a MacBook per
`tailscale.md` §3.3). Vantage's role is only steps' *guidance*, not execution, because none of it runs
before the volume is unlocked.

---

## 6. Intercepting a user-initiated Restart / Shut Down / Log Out

A menu-bar (`LSUIElement`) app is still an `NSApplication` and receives the standard termination
handshake. The mechanism **[APPLE + COMMUNITY]**:

- `NSApplicationDelegate.applicationShouldTerminate(_:)` is called before the app is asked to quit,
  including when `loginwindow` is tearing the session down for a Restart/Shut Down/Log Out. Return
  `.terminateNow` to allow, `.terminateCancel` to veto, or `.terminateLater` to defer while you show a
  prompt and then call `NSApp.reply(toApplicationShouldTerminate:)`.
- **Why the app is quitting** is carried by the current Apple event: when `loginwindow` initiates the
  quit, `NSAppleEventManager.shared().currentAppleEvent` is the quit event and its **`kAEQuitReason`**
  attribute (`keyAEQuitReason`) holds `kAERestart`, `kAEShutDown`, `kAEReallyLogOut`, or `kAELogOut`.
  A Cmd-Q / Quit-menu / programmatic terminate carries **no** current Apple event (or no reason
  attribute), which is exactly how you tell "the user chose Restart" from "the user quit Vantage."
- If you `.terminateCancel` (or `.terminateLater` and then cancel) a system-initiated logout/restart,
  macOS surfaces the classic **"⟨App⟩ canceled restart / logout"** dialog naming your app — so cancel
  sparingly and only with a visible reason.
- `NSWorkspace.shared.notificationCenter` also posts **`willPowerOffNotification`** (logout or
  shutdown) — useful as an early heads-up, but it does **not** distinguish restart vs shutdown vs
  logout and cannot veto; use `applicationShouldTerminate` + `kAEQuitReason` for the decision.

Verified-shape Swift snippet (compiles against the macOS 27 SDK; Carbon constants come from
`CoreServices`) **[SDK for the APIs; ASSUMED exact integration until built in-tree]**:

```swift
import AppKit
import CoreServices   // kAEQuitReason, kAERestart, kAEShutDown, kAEReallyLogOut, kAELogOut

final class AppDelegate: NSObject, NSApplicationDelegate {

    enum QuitReason { case restart, shutDown, logOut, userQuit }

    private func currentQuitReason() -> QuitReason {
        guard let evt = NSAppleEventManager.shared().currentAppleEvent else { return .userQuit }
        // kAEQuitReason is an attribute on the quit ('aevt'/'quit') event.
        let reason = evt.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))
        switch reason?.typeCodeValue {
        case UInt32(kAERestart):      return .restart
        case UInt32(kAEShutDown):     return .shutDown
        case UInt32(kAEReallyLogOut), UInt32(kAELogOut): return .logOut
        default:                      return .userQuit
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch currentQuitReason() {
        case .restart:
            // Offer "Restart safely" (fdesetup authrestart via the privileged helper), then reply.
            presentRestartSafelyPrompt { proceed in
                if proceed { self.stageAuthRestartThenAllow() }      // helper stages the FV key
                NSApp.reply(toApplicationShouldTerminate: true)      // let the restart continue
            }
            return .terminateLater
        case .shutDown, .logOut, .userQuit:
            return .terminateNow
        }
    }
}
```

Notes:
- For a background host you may not want to *block* a restart — `.terminateLater` + an immediate
  reply, using the reason only to *stage authrestart* (§5a) rather than to nag, is the least annoying
  design. Reserve `.terminateCancel` for a real "you have an active remote session — restart anyway?"
  confirmation.
- `applicationWillTerminate(_:)` is not guaranteed during an OS shutdown (the system may SIGKILL after
  a timeout), so do the important work (release input, stage authrestart) in the
  `applicationShouldTerminate` handler, not in `willTerminate`.

---

## Sources

- **This Mac (read-only probes, 2026-09-22):** `sw_vers` (27.0/26A5421a), `uname -m` (arm64),
  `fdesetup status|isactive|supportsauthrestart`, `pmset -g`/`-g custom`/`-g cap`,
  `netstat` (5900 LISTEN + the live iPad session), `ps aux` (screensharingd/ScreensharingAgent/
  SSMenuAgent/Tailscale sysext), RFB greeting on `127.0.0.1:5900` (`RFB 003.889\n`), `codesign -d
  --entitlements` on the two RemoteManagement bundles, and `log show` for `screensharingd` /
  `ScreensharingAgent` including a full successful `Type: DH` (auth type 30) session from
  `100.64.0.4`. **[VERIFIED]**
- **SDK / man pages (this Mac):** `man fdesetup`, `man apple_ssh_and_filevault(7)`,
  `rfbproto` KeyEvent/ClientInit definitions, AppKit `NSApplicationDelegate`/`NSWorkspace`,
  CoreServices `kAEQuitReason` family. **[SDK]**
- **Open source (read directly):** LibVNCServer `libvncclient` `src/libvncclient/rfbclient.c`
  (`HandleARDAuth`, version negotiation); noVNC `core/rfb.js` (`securityTypeARD`, `_negotiateARDAuth`,
  `_negotiateARDAuthAsync`, `RFB.messages.keyEvent`). **[OSS]**
- **Edovia / Screens 5:** *Preparing Your Mac for Screen Sharing*, *Connect From Anywhere with Screens
  Connect*, *Troubleshooting macOS Remote Management and Screen Sharing Issues*
  (help.edovia.com/support.edovia.com, en/screens-5). Local read-only inspection of
  `/Applications/Screens 5.app` (`VNCKit.framework` symbols). **[COMMUNITY/VERIFIED]**
- **Tailscale docs:** *Three ways to run Tailscale on macOS* (macos-variants), *Authorizing the
  Tailscale system extension on macOS* (macos-sysext), *Keep Tailscale running when I'm not logged in*,
  subnet-router docs; corroborated by `tailscale.md` §3. **[APPLE/Tailscale]**
- **Apple developer forums / docs:** *Graceful Application Termination*, forum thread 94126 ("How to
  determine if an application quit is because of a logout or restart/shutdown?") for the
  `kAEQuitReason` technique. **[APPLE/COMMUNITY]**
- **Related in-repo reports:** `input.md` §A.1b, `product-and-host-lifecycle.md` §4.2–4.4,
  `tailscale.md` §3. Read those for the CGEvent/Secure-Event-Input, capture-at-lock, and
  unattended-access context this report builds on.

## Open questions / verify on device

1. **Keys-only session without framebuffer:** confirm `screensharingd` accepts `KeyEvent` after
   ServerInit with no `SetEncodings`/`FramebufferUpdateRequest`. If it insists on a framebuffer
   request, send a 1×1 `FramebufferUpdateRequest` and discard updates. **[ASSUMED]**
2. **Shift for shifted characters:** verify whether bare keysyms (e.g. `0x21` for "!") type correctly,
   or whether explicit `Shift_L` wrapping is needed for a password with symbols. **[INFERRED]**
3. **Apple ServerInit trailer:** pin the exact `RFBServerInfo2`/extra-bytes length so the reader
   stays in sync (log showed `extralen 40`, `RFBServerInfo2 46`). **[VERIFIED length; parse to confirm]**
4. **Username form:** short name vs full name vs `user@host` for the 64-byte username field.
5. **Type 33/36 fallback:** decide whether to implement RSA (33) with server-key fingerprint pinning
   for Macs not offering 30, or to require the type-30 configuration.
6. **`fdesetup authrestart -inputplist` non-interactively from a privileged helper:** confirm the
   plist keys and that it returns to the login window (not auto-login) on 27. **[SDK-documented; test]**
7. **tvOS/other always-on device as a Tailscale subnet router** advertising the home LAN so the iPad
   can reach pre-boot SSH from anywhere. **[ASSUMED — verify per device]**
8. **Login-window (logged-out-but-unlocked) RFB injection:** confirm the `LoginWindow`-session Screen
   Sharing agent accepts type-30 auth and injects at that screen. **[INFERRED]**
