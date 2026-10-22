# Vantage wire protocol: what a host must do (Windows host edition)

Taken from the Swift code at `Packages/VantageCore/Sources/VantageCore/**`, `VantageHost/**` and
`Vantage/Net/ClientSession.swift`. Protocol version **2**. Default port **47820/TCP**. There is no
TLS: authentication is Ed25519 at the application layer, and privacy comes from Tailscale's
WireGuard tunnel.

**Rule:** every Apple client in the field closes the connection on (a) an unknown kind byte, (b) a
JSON payload it can't decode into the Swift type (a missing required key, the wrong JSON type,
`null` in a required field), or (c) a truncated binary payload or an unknown enum byte inside one.
So everything the host sends must match this document exactly.

Things that differ from what one might assume:

1. **`keyEvent` carries macOS virtual key codes (kVK), not HID usages.** The client converts HID to
   kVK before sending (`HIDKeyMap`, called from `Vantage/Input/InputController.swift`). A Windows
   host needs a kVK → Windows scan code table (§7.5).
2. **The Mac host never sends `cursorPosition` or `cursorShape`.** The cursor is drawn into the
   video (`ScreenCapture.swift`: `showsCursor = true`). A Windows host may: with
   `HostCapabilities.cursorShapes` and a client's `features.localCursor`, it leaves the pointer out
   of the video and sends both, and the client draws the pointer itself.
3. **Video is AVCC, not Annex-B.** Each NAL unit gets a 4-byte big-endian length prefix, and
   SPS/PPS travel separately in `videoConfig`. The client builds its format description only from
   `videoConfig`; frames that arrive before it are dropped with a keyframe request.
4. **An unknown message kind closes the connection on both Swift sides.** A Windows host may
   tolerate unknown kinds, but it must never send a kind the client didn't ask for.
5. **The client can't know the host platform before pairing.** `HostCapabilities` only arrives with
   a successful `authResult`, and the pairing prompt appears before that; hence the optional
   `Challenge.hostPlatform` as well as `HostCapabilities.platform`.
6. **Nothing pings the file channel, and files-only primary connections never ping.** The file
   engine closes the channel on any non-file kind. No host-side idle timeouts should be added.
7. **`FileOffer.modified` uses Swift's default date format**: seconds since 2001-01-01 UTC.
   `FileChunk` IDs are the 16 bytes in RFC order. In .NET, write them with
   `TryWriteBytes(span, bigEndian: true, out _)`.

## 1. Transport

- One TCP connection per session (the **primary** connection). A second, optional TCP connection is
  the **file channel** (§10). Every connection starts with the client sending one message: `hello`
  (kind 1) opens a session; `attachMedia` (kind 60) turns the connection into a file channel.
  Anything else, or nothing within **15 s**, and the host closes it (`HostController.accept`).
- The listener binds all interfaces. In .NET use a dual-mode IPv6 socket on `[::]:47820`, and call
  `IPAddress.MapToIPv4()` on IPv4-mapped peers before any check.
- Socket options, matching `VantageNetwork.tcpParameters()`: `NoDelay=true`, keepalive on, idle 5 s,
  interval 2 s, 3 probes (about 11 s to detect a dead peer), connect timeout 8 s (client side). The
  file channel uses the same TCP tuning but a background service class. On Windows, set
  `ExclusiveAddressUse=true` instead of address reuse.
- **Accepted peer addresses** (`TailscaleListener.isTailnetPeer`, `VantageNetwork`):
  - IPv4 `100.64.0.0/10`: `b[0]==100 && (b[1] & 0xC0)==0x40`.
  - IPv6 `fd7a:115c:a1e0::/48`: first six bytes `FD 7A 11 5C A1 E0`.
  - Loopback `127.0.0.1` / `::1` in **DEBUG builds only**. Release builds reject loopback so no local
    process can reach pairing.
  - Everything else: close without reading.
- There is no application-level idle timeout on either side. Liveness comes from TCP keepalive.
- Writes must be whole frames, in order, and never interleaved: use one writer per connection. The
  Mac host sends video and replies fire-and-forget; answers from the receive loop never wait on the
  network (§10.6).

## 2. Framing (`Wire/Frame.swift`)

Every message is an 8-byte header followed by `length` payload bytes. All header integers are
little-endian.

| Offset | Size | Field | Value |
|---|---|---|---|
| 0 | 1 | magic | `0x56` ('V'). Anything else is `badMagic`: close. |
| 1 | 1 | kind | `MessageKind` raw value (§3). Unknown: Swift throws `unknownKind` and closes. |
| 2 | 2 | flags | u16 LE, always `0`. Never interpreted; send 0, ignore on receipt. |
| 4 | 4 | length | u32 LE payload length. Must be ≤ **33 554 432** (32 MiB) or `payloadTooLarge`: close. |
| 8 | length | payload | JSON (kinds < 100) or packed binary (kinds ≥ 100). May be empty. |

The reader reads exactly 8 bytes, then exactly `length` bytes. A zero length is allowed and is used
by `requestKeyframe`.

## 3. Message kinds (`Messages/MessageKind.swift`)

C→H means client to host; H→C means host to client. "Windows v1" is what the Windows host does.

| Kind | Name | Enc | Dir | Windows v1 |
|---|---|---|---|---|
| 1 | hello | JSON | C→H | handle |
| 2 | challenge | JSON | H→C | send |
| 3 | authenticate | JSON | C→H | handle |
| 4 | authResult | JSON | H→C | send |
| 10 | displayList | JSON | H→C | send only in reply to `refreshDisplays` |
| 11 | selectDisplay | JSON | C→H | handle |
| 12 | streamConfig | JSON | H→C | send |
| 13 | viewportChanged | JSON | C→H | force a keyframe; current clients never send it |
| 20 | qualityFeedback | JSON | C→H | handle (4 Hz) |
| 21 | requestKeyframe | **empty payload** | C→H | handle; don't JSON-parse it |
| 22 | streamStats | JSON | H→C | don't send (the Mac never does; the client ignores it) |
| 30 | clipboard | JSON | both | handle and send |
| 40 | hostCommand | JSON | C→H | handle |
| 50 | ping | JSON | C→H | answer with pong |
| 51 | pong | JSON | H→C | send |
| 52 | disconnect | JSON | both | handle; send only for a deliberate kick (§9.6) |
| 53 | protocolError | JSON | — | never sent by the Mac host; don't send |
| 60 | attachMedia | JSON | C→H | first message on a file channel |
| 61 | textInput | JSON | C→H | handle |
| 62 | modifierState | JSON | C→H | never sent by current clients; ignore |
| 63 | audioRequest | JSON | C→H | never arrives unless `audio` is advertised; don't advertise |
| 64 | dictationControl | JSON | C→H | gated by `dictationEngines`; don't advertise |
| 70 | cursorShape | JSON | H→C | only to a client with `features.localCursor`, when the host advertises `cursorShapes` |
| 71 | videoConfig | JSON | H→C | send |
| 72 | hostStatus | JSON | H→C | send |
| 73 | audioConfig | JSON | H→C | never send |
| 74 | dictationResult | JSON | H→C | never send |
| 80–84 | fileOffer/Accept/Complete/Result/Cancel | JSON | both, file channel only | handle and send |
| 100 | videoFrame | bin | H→C | send |
| 101 | cursorPosition | bin | H→C | same rule; the client uses `isVisible` |
| 102 | audioPacket | bin | H→C | never send |
| 103 | fileChunkToClient | bin | H→C, file channel | send |
| 120 | pointerEvent | bin | C→H | handle |
| 121 | scrollEvent | bin | C→H | handle |
| 122 | keyEvent | bin | C→H | handle |
| 123 | micAudio | bin | C→H | gated; ignore |
| 124 | fileChunkToHost | bin | C→H, file channel | handle |

**Unknown kinds.** Swift hosts and clients drop the connection. That is why every new kind is gated
on a capability in `Hello.features` or `HostCapabilities`. The Windows host is more tolerant: if the
kind is unknown but the length is ≤ 32 MiB, read and discard the payload, log it, and carry on. A
known kind whose payload fails to decode: during the handshake, close; afterwards, log and drop that
message. The host must **never send** a kind the client didn't opt into.

## 4. Binary encoding (`Wire/BinaryCoding.swift`)

- Every integer is **little-endian**. `Bool` is one byte: write 0 or 1; read non-zero as true.
- `Float` is IEEE-754 binary32 LE; `Double` is binary64 LE.
- Swift decoders **ignore trailing bytes** after a fixed-layout message and **throw on truncation**.
  Unknown enum bytes throw.
- UUIDs inside binary payloads are the 16 bytes in RFC-4122 order, the same order as the printed
  string. In .NET that is `new Guid(span, bigEndian: true)` and
  `guid.TryWriteBytes(span, bigEndian: true, out _)`. **`Guid.ToByteArray()` is wrong** (mixed-endian).

## 5. JSON encoding rules (Swift `JSONEncoder`/`JSONDecoder` as configured in `Message.swift`)

- Keys are the Swift property names exactly, in camelCase. Key order doesn't matter. Unknown keys
  are **ignored** by Swift decoders, which makes adding optional fields safe.
- Optional fields: Swift omits a nil optional from its output, and a missing key or `null` decodes to
  nil. Non-optional fields must be present and non-null, **even if the Swift `init` gives them a
  default** (for example `VideoConfig.nalLengthSize` and `FileAccept.resumeOffset`). In C#, use
  `DefaultIgnoreCondition = WhenWritingNull`.
- `Data` fields are standard base64 **with padding**, no line breaks.
- `Date` uses Swift's default `deferredToDate` strategy: a **JSON number of seconds since
  2001-01-01T00:00:00Z**, which may be fractional. That's Unix seconds − 978 307 200. The only `Date`
  field is `FileOffer.modified`.
- `UUID` is a string, e.g. `"E621E1F8-C36C-495A-93FC-0C247A3E6E5F"`. Swift emits uppercase and accepts
  either case. Emit uppercase.
- Integers: Swift `Int`/`UInt*` fields must be JSON integers with no `.0`. Parse `UInt64` fields such
  as `sentAtNanos` as `ulong`, **never through `double`**: client uptime in nanoseconds exceeds 2^53.
- `Double` fields accept integer or fractional JSON numbers. Never emit NaN or Infinity.
- String enums use the raw value (lists below).
- `KeyModifiers` (an OptionSet) is a **plain JSON number**, its `rawValue`.
- `DisplaySelection` (an enum with associated values, synthesized Codable) is a single-key object
  whose payload is keyed `_0`:
  - `{"display":{"_0":3}}`
  - `{"fitViewport":{"_0":{"widthPoints":1210,"heightPoints":834,"scale":2}}}`
- `DictationEngineID` is a plain string. `MicAudioFormat` is a number, `0`.

### 5.1 Enums

- `VideoCodec`: `"h264"`, `"hevc"`
- `QualityPreset`: `"auto"`, `"text"`, `"motion"`, `"maximum"`
- `AuthStatus`: `"ok"`, `"pairingRequired"`, `"badPairingCode"`, `"badSignature"`, `"denied"`,
  `"versionMismatch"`
- `HostInputPath`: `"native"`, `"screenSharingBridge"` (Windows always sends `"native"`)
- `HostCommand`: `"lockScreen"`, `"sleepDisplay"`, `"wakeDisplay"`, `"releaseAllInput"`,
  `"refreshDisplays"`, `"restoreDisplays"`
- `KeyModifiers` bits: capsLock `1<<0`, shift `1<<1`, control `1<<2`, option `1<<3` (Alt), command
  `1<<4` (Win), function `1<<5` (Fn; no Windows equivalent)

### 5.2 JSON messages. `?` means optional (omit when nil).

**Hello (1, C→H)**
- `protocolVersion` UInt16 (2)
- `clientName` String (iOS reports just "iPad"/"iPhone")
- `deviceModel` String
- `appVersion` String
- `clientPublicKey` base64 of the 32-byte raw Ed25519 public key
- `supportedCodecs` [VideoCodec] (currently `["hevc","h264"]`; `[]` for probes and files-only)
- `maxDecodeWidth` Int (4096), `maxDecodeHeight` Int (2304); 0 for probes and files-only
- `viewport?` {`widthPoints` Double, `heightPoints` Double, `scale` Double}
- `isReadinessProbe?` Bool
- `features?` {`dictation?` Bool, `macAudio?` Bool, `fileTransfer?` Bool, `filesOnly?` Bool}

**Challenge (2, H→C)**
- `hostName` String; the Mac uses its computer name. On Windows use the DNS hostname, case preserved.
- `hostVersion` String ("1.0")
- `hostPublicKey` base64, 32 bytes
- `nonce` base64, 32 random bytes from a CSPRNG
- `isPaired` Bool
- `peerTailnetName?` String: the whois `UserProfile.LoginName`; omitted for probes and files-only
- `hostPlatform?` String `"macos"|"windows"` (added for Windows hosts; old clients ignore it)

**Authenticate (3, C→H)**
- `signature` base64, 64 bytes
- `pairingCode?` String: six digits, sent only when `isPaired == false`

**AuthResult (4, H→C)**
- `status` AuthStatus
- `message?` String: user-visible (the client shows it for denied, badSignature, versionMismatch)
- `sessionToken?` base64, 32 bytes
- `displays?` [DisplayInfo]
- `capabilities?` HostCapabilities
- `readiness?` {`screenRecordingGranted` Bool, `accessibilityGranted` Bool}

**HostCapabilities**
- `codecs` [VideoCodec], `canManageVirtualDisplay` Bool, `clipboard` Bool, `maxFPS` Int (all required)
- `dictationEngines?` [String], `audio?` Bool, `fileTransfer?` Bool, `filesOnlySessions?` Bool
- `platform?` String `"macos"|"windows"`

**DisplayInfo** (all required)
- `id` UInt32
- `name` String
- `pixelWidth`, `pixelHeight`, `pointWidth`, `pointHeight` Int
- `scale` Double
- `originX`, `originY` Double
- `isMain`, `isBuiltIn`, `isVirtual` Bool
- `refreshRate` Double

**AttachMedia (60)**: `sessionToken` base64

**SelectDisplay (11, C→H)**
- `selection` DisplaySelection
- `targetFPS` Int
- `quality` QualityPreset
- `preferredCodec?` VideoCodec
- `useVirtualDisplay?` Bool

**DisplayList (10)**: `displays` [DisplayInfo]

**StreamConfig (12, H→C)**: `display` DisplayInfo, `codec` VideoCodec, `fps` Int, `bitrateKbps` Int

**ViewportChanged (13)**: `viewport` Viewport

**QualityFeedback (20, C→H)**
- `rttMillis` Double, `decodeMillis` Double
- `framesReceived` UInt64, `framesDropped` UInt64
- `queueDepth` Int (the client always sends 0)
- `bytesReceived` UInt64
- `windowSeconds` Double (0.25)

**StreamStats (22)**: `captureFPS` Double, `encodeMillis` Double, `bitrateKbps` Int,
`targetBitrateKbps` Int, `framesSent` UInt64, `framesSkipped` UInt64

**Clipboard (30)**
- `text?` String
- `imagePNG?` base64
- `rtf?` base64 of the RTF bytes
- Never send an empty payload (all three nil).

**HostStatus (72, H→C)**
- `isScreenLocked` Bool, `isSecureInputActive` Bool, `inputPath` HostInputPath (required)
- `message?` String
- `isDisplayAsleep?` Bool
- `isScreenUnavailable?` Bool

**HostCommandMessage (40)**: `command` HostCommand

**Ping (50)**: `sentAtNanos` UInt64. **Pong (51)**: `echoNanos` UInt64; echo the ping's value exactly.

**DisconnectMessage (52)**: `reason` String. **ProtocolErrorMessage (53)**: `code` String, `message` String.

**TextInput (61)**: `text` String. **ModifierState (62)**: `modifiers` Number.

**VideoConfig (71, H→C)** (all required)
- `codec`
- `width` Int, `height` Int
- `parameterSets` [base64]: raw NAL units including the 1-byte NAL header, **no start codes, no
  length prefix**. H.264: `[SPS, PPS]`. HEVC: `[VPS, SPS, PPS]`.
- `nalLengthSize` Int = **4**
- `fps` Int

**CursorShape (70)**: `pngData`, `widthPoints`, `heightPoints`, `hotspotX`, `hotspotY`, `scale`.
JSON; not used in v1.

**File messages (80–84)**: see §10.

**Not used by a Windows v1 host:** AudioRequest (63), AudioConfig (73), DictationControl (64),
DictationResult (74). Their schemas are in `AudioMessages.swift` and `DictationMessages.swift`.

## 6. Binary layouts (byte offsets inside the payload)

**videoFrame (100, H→C)**: 25-byte header, then data.

| Off | Type | Field |
|---|---|---|
| 0 | u64 | sequence: per encoder, starts at 0, +1 per frame |
| 8 | u64 | captureNanos: host monotonic ns (the client ignores it today) |
| 16 | u8 | isKeyframe: 1 if the AU contains an IDR (H.264 NAL type 5) |
| 17 | u32 | width: encoded width |
| 21 | u32 | height |
| 25 | … | data: one access unit in **AVCC** form (see below) |

The data is a sequence of `[u32 **big-endian** NAL length][NAL bytes]` with no start codes. Remove
SPS (7), PPS (8) and AUD (9) from the AU; they travel in `videoConfig`. Keep slices (1, 5). SEI (6)
is tolerated by VideoToolbox; drop it if decoding misbehaves. The client feeds `data` as one sample
to `AVSampleBufferDisplayLayer` under the format description built from the last `videoConfig`,
marked display-immediately.

**cursorPosition (101)**: `x f32 | y f32 | isVisible u8` = 9 bytes, in display points. Sent with `cursorShape` (see CLAUDE.md, Local pointer).

**pointerEvent (120, C→H)**: 15 bytes.

| Off | Type | Field |
|---|---|---|
| 0 | u8 | action: 0 move, 1 down, 2 up |
| 1 | u8 | button: 0 left, 1 right, 2 middle, 3 back, 4 forward |
| 2 | f32 | x: display points, origin top-left of the streamed display |
| 6 | f32 | y |
| 10 | u8 | clickCount (≥1) |
| 11 | u32 | modifiers (KeyModifiers bits) |

A `move` carries no meaningful button. If a button is held, the host treats the move as a drag of
the held button.

**scrollEvent (121, C→H)**: 31 bytes.

| Off | Type | Field |
|---|---|---|
| 0 | u8 | phase: 0 none, 1 began, 2 changed, 3 ended, 4 cancelled |
| 1 | u8 | momentum: 0 none, 1 began, 2 changed, 3 ended |
| 2 | u8 | isContinuous: 1 = trackpad, deltas in points; 0 = wheel, deltas in lines |
| 3 | f32 | deltaX |
| 7 | f32 | deltaY |
| 11 | f32 | x |
| 15 | f32 | y |
| 19 | f32 | velocityX: points/s, only on `ended` |
| 23 | f32 | velocityY |
| 27 | u32 | modifiers |

The client has already applied Natural Scrolling to the deltas (`RemoteInteractionView`). A discrete
delta is the translation divided by 10 points per line. See §7.4 for the Windows sign rule.

**keyEvent (122, C→H)**: 8 bytes.

| Off | Type | Field |
|---|---|---|
| 0 | u16 | keyCode: **macOS virtual key code (kVK)**, table in §7.5 |
| 2 | u8 | isDown |
| 3 | u32 | modifiers |
| 7 | u8 | isRepeat |

**audioPacket (102)**: `seq u64 | captureNanos u64 | frameCount u16 | opus…` (18-byte header). Not used.

**micAudio (123)**: `dictationID 16B | seq u32 | format u8 | pcm…` (21-byte header). Not used.

**fileChunkToClient (103) / fileChunkToHost (124)**: `id 16B (RFC order) | offset u64 LE | bytes…`.
24-byte header; 256 KiB of data (262 144 bytes) except the last chunk.

## 7. Session behaviour

### 7.1 Handshake (`HostSession.handshake`, `ClientSession.handshake`)

1. The host accepts the TCP connection, checks the peer range (§1), and reads the first message
   (15 s limit). For `hello`:
2. If `protocolVersion != 2`: send `authResult{status:"versionMismatch", message:"Protocol 2 required"}`
   **instead of** a challenge, then close.
3. Otherwise send `challenge`:
   - `isPaired` = the client key's fingerprint is in the trust list.
   - `peerTailnetName` = whois result, only for ordinary sessions (not probes or files-only). The Mac
     runs `tailscale whois --json <peerIP>` with a 2 s timeout, caches per IP, and uses
     `UserProfile.LoginName`, else `DisplayName`. This is optional.
4. Read `authenticate`. Anything else: close. (The Mac has no timeout at this step; Windows keeps
   one 15 s limit for the whole handshake.)
5. **Verify the signature** before anything else. The signed transcript is:
   `transcript = UTF8("vantage-auth-v1") ‖ nonce(32) ‖ hostPublicKey(32) ‖ clientPublicKey(32)`
   That's 15 + 96 = **111 bytes**, a plain concatenation with no lengths. The signature is Ed25519
   (RFC 8032, pure) by the client key. CryptoKit signatures are randomized but standard; any RFC 8032
   verifier accepts them. If invalid: `authResult{status:"badSignature"}` and close.
6. If the client isn't paired:
   - No `pairingCode`: `authResult{status:"pairingRequired", message:"Enter the pairing code shown on the PC"}`
     and close. The client shows its code prompt and reconnects with a new connection carrying the code.
   - Code given, run `consumePairingCode`:
     - `accepted`: add the key to the trust list with name = `hello.clientName`, and continue.
     - `incorrect`: **wait 1 s**, then `authResult{status:"badPairingCode", message:"Incorrect pairing code. Try the code shown on the PC."}`
       and close.
     - `unavailable` (no code active, or expired): wait 1 s, then `badPairingCode` with an "expired,
       show a new code" message, and close.
   - Pairing code rules (`TrustStore`):
     - Six digits, `%06d` from a uniform 0…999 999.
     - Created only when the user asks ("Show Pairing Code").
     - One active code at a time; a new code replaces the old one and resets the miss counter.
     - Expires **10 min** after it was issued. Expiry is checked when a code is consumed.
     - Compared in constant time.
     - Each wrong guess increments a counter; at **5** the code is burned. Success, expiry or burning
       clears the code and hides it in the UI.
     - The counter is per code, not per peer.
     - DEBUG `--pairing-code N` fixes the code and it never expires.
7. **Readiness probe** (`isReadinessProbe == true`; the device list sends one every 15 s per saved
   host, 5 s timeout): after steps 5–6, send
   `authResult{status:"ok", readiness:{screenRecordingGranted:true, accessibilityGranted:true}}` and
   close. Never enumerate displays, start capture, or touch the clipboard for a probe. An unpaired
   probe sends no code, so it receives `pairingRequired`.
8. **Files-only** (`features.filesOnly == true`):
   - Requires `features.fileTransfer == true`, otherwise
     `authResult{status:"denied", message:"Nothing to do on this connection."}` and close.
   - Otherwise issue a token (§10.1) and send `authResult{status:"ok", sessionToken, capabilities:{codecs:[], canManageVirtualDisplay:false, clipboard:false, maxFPS:0, fileTransfer:true, filesOnlySessions:true}}`.
     No `displays`, no whois.
   - Then run the **files-only loop**: answer `ping` with `pong`, return on `disconnect`, ignore
     everything else (log the first). Never start capture, input, clipboard, status or power handling.
   - The client never sends a pairing code on this path. An unpaired files-only client gets
     `pairingRequired` and tells the user to open the screen once.
9. **Screen session**:
   - If capture is impossible (Mac: no Screen Recording; Windows: `GraphicsCaptureSession.IsSupported()`
     false) send `authResult{status:"denied", message:…}` and close.
   - Enumerate displays.
   - If `features.fileTransfer`, issue a 32-byte token.
   - Send `authResult{status:"ok", sessionToken?, displays:[…], capabilities}`.
   - **Windows v1 capabilities:** `{codecs:["h264"], canManageVirtualDisplay:false, clipboard:true, maxFPS:60, fileTransfer:true, filesOnlySessions:true, platform:"windows"}`,
     `fileTransfer`/`filesOnlySessions` only when the client said `fileTransfer`. Omit
     `dictationEngines` and `audio` (nil means the client never sends those kinds).
10. The client then immediately sends
    `selectDisplay{selection:{"fitViewport":{"_0":viewport}}, targetFPS:60, quality:"auto", preferredCodec: <saved preference, may be "hevc">, useVirtualDisplay:false}`.
    From here the receive loop (§7.2) runs.

**Client reaction to results:**
- `ok`: connected.
- `pairingRequired` / `badPairingCode`: shows the prompt; it doesn't reconnect by itself.
- `denied`, `badSignature`, `versionMismatch`: failed with `message`, no automatic retry.
- On any drop after `ok`, it reconnects with backoff `min(1.6^n, 15)` s, up to 40 attempts. The
  attempt counter resets once the host answers the stream request (`hostStatus`, `streamConfig`,
  `videoConfig` or `videoFrame`) or the connection lasted 10 s.

**Keys and trust:**
- The host identity is an Ed25519 private key stored as the 32-byte seed. CryptoKit's
  `rawRepresentation` is the seed; in NSec use `KeyBlobFormat.RawPrivateKey` for the seed and
  `RawPublicKey` for the 32-byte public key.
- **Fingerprint** = lowercase hex of the first **8** bytes of SHA-256(raw 32-byte public key): 16 hex
  characters. The trust list is `[{fingerprint, name, addedAt}]`, keyed by fingerprint; revoking
  removes the entry.

### 7.2 Streaming (`HostSession.receiveLoop`, `selectDisplay`, `startStreaming`, `emit`)

On the first `selectDisplay`:
1. Start the session-long monitors (power assertion, lock/secure/sleep monitoring) and **send
   `hostStatus` right away** (§8).
2. Wake the display if it's asleep.
3. Choose the display. `display(id)`: that display. `fitViewport`: the main display. (There is no
   virtual display on Windows, so ignore `useVirtualDisplay` and the viewport size.)
4. Start the encoder and capture. The Mac starts at `min(targetFPS, 60)` fps with a starting bitrate
   of `clamp(pixels × fps × 0.08 / 1000, 4 000, 60 000)` kbps.
5. Send the current clipboard if it isn't empty (the Mac does this before `streamConfig`).
6. `send streamConfig{display, codec, fps, bitrateKbps}`. Use the codec actually chosen: **always
   `h264` on Windows v1**, whatever `preferredCodec` says. The client decodes by `videoConfig.codec`.
7. Set `needsKeyframe = true`.

**Every encoded frame:** if it's an IDR and its SPS/PPS differ from the last ones sent (or it's the
first frame), send `videoConfig` **before** the `videoFrame`. Sending `videoConfig` before every IDR
is also safe.

**Keyframes:** forced IDR on stream start, `requestKeyframe`, `viewportChanged`, capture restart, and
after the host drops frames (§7.3). The client asks for a keyframe when it has no format
description, when the renderer fails, or when it needs a flush. The Mac uses **no periodic IDRs**.
If the screen is static when an IDR is needed, re-encode the last captured texture rather than
waiting for the next change.

**Idle:** skip encoding when nothing changed, unless a keyframe is pending. The client treats a quiet
stream as normal and never reconnects because of missing video.

**Receive loop dispatch:**
- `selectDisplay`: (re)start as above.
- `pointerEvent`, `scrollEvent`, `keyEvent`, `textInput`: go to input injection. While the display is
  asleep, only releases are delivered; any other input wakes the display (at most once per second)
  and is dropped, except during the 2 s after a `sleepDisplay` command.
- `clipboard`: apply to the local clipboard (§9.3).
- `qualityFeedback`: feed the adaptive controller (§9.1).
- `requestKeyframe`, `viewportChanged`: set `needsKeyframe`.
- `hostCommand`: §9.4.
- `ping`: send `pong{echoNanos: ping.sentAtNanos}` at once. The client sends a ping and a
  `qualityFeedback` **every 250 ms** while connected; the host never pings.
- `disconnect`: end the session.
- `audioRequest`: ignore unless audio was advertised.
- Anything else: ignore.

**Teardown:** revoke the session's attach token; release every held key and button; stop capture,
clipboard monitoring, status monitoring and the power assertion; close the socket. If a file channel
is attached it **keeps running** (§10).

### 7.3 Video format expected by the client (`VideoStreamView.swift`, Mac `VideoEncoder.swift`)

- H.264, progressive 4:2:0 8-bit (the Mac captures `'420v'`, i.e. NV12 video range). High profile
  (Main also works), CABAC, **no B-frames or reordering**, low-latency rate control.
- Colour: the Mac tags BT.709 primaries, sRGB transfer and BT.709 matrix, video range. The client
  doesn't override colour, so what's in the SPS VUI is used. Aim for `colour_primaries=1`,
  `transfer_characteristics=13` (sRGB), or 1 if the encoder can't, `matrix_coefficients=1`,
  `video_full_range_flag=0`.
- `maxDecodeWidth` × `maxDecodeHeight` from `hello` (4096 × 2304 today) must bound the encoded size.
  Downscale larger desktops.
- Dimensions must be even; SPS cropping handles padding.
- **Backpressure** (a Windows improvement; the Mac leans on unbounded `NWConnection` buffering): if
  more than about 2 video frames (or 1–2 MB) are waiting in the socket write queue, drop new
  **P-frames**, never half a frame, then force an IDR and resume. The client doesn't detect gaps, so
  a dropped P-frame without a following IDR smears the picture.

### 7.4 Coordinates and input semantics (`InputInjector.swift`, `KeyboardSequencer.swift`, `InputController.swift`)

**Pointer coordinates:**
- x and y are floats in the streamed display's **point** space: 0…pointWidth, 0…pointHeight, origin
  top-left. The client clamps to `[0, size−1]` and puts edge positions on the last row or column.
- The host converts: `px = x / pointWidth × pixelWidth + monitorLeft` (and the same for y), clamped
  inside the monitor. For Windows, report `scale = dpi/96` (GetDpiForMonitor, MDT_EFFECTIVE_DPI) and
  `pointWidth = round(pixelWidth/scale)`. That keeps the trackpad feeling like the Mac, since client
  sensitivity is in points.

**Buttons:** down/up by button; a move while a button is held is a drag of that button. Windows:
`MOUSEEVENTF_{LEFT,RIGHT,MIDDLE}{DOWN,UP}`; back/forward are `XDOWN/XUP` with `XBUTTON1/XBUTTON2`.
`clickCount` is informational: Windows derives double-clicks from timing, and the client sends
double-clicks back to back.

**Modifiers on pointer and scroll events:** the host adds the event's modifier bits to whatever
modifier keys are held. On Windows, press the missing modifier keys around the click, then release them.

**Scroll, Windows v1 rule (verify the sign on hardware; keep it in one constant):**
- A **positive deltaY means content should move down**, i.e. reveal what's above, i.e. a positive
  `WHEEL_DELTA`.
- Discrete (wheel): `wheel = round(deltaY × 120)` via `MOUSEEVENTF_WHEEL`.
- Continuous (trackpad): accumulate `deltaY × 120 / 48` per point and carry the fractional remainder.
- Horizontal: `MOUSEEVENTF_HWHEEL` with `−deltaX` using the same scale (positive HWHEEL scrolls right).
- The Mac forwards scroll phases unchanged. Momentum synthesis from velocity on `ended` is optional
  (decaying wheel events for about 600 ms, cancelled by the next `began`).
- Mac reference, for context: continuous `wheel1 = −deltaY` pixels; discrete `wheel1 = deltaY` lines.

**Keys** (behaviour, not wire format; the client relies on it):
- A key event for a **modifier key** (§7.5 marks them) changes that modifier's held state.
- **Chords:** a `keyDown` for a non-modifier key whose `modifiers` bits name modifiers that aren't
  held (on either side) first presses those modifiers as their own left-hand keys, in the order
  Ctrl, Alt, Shift, Win. The matching `keyUp` releases them afterwards, in reverse. This is how
  control-strip buttons and sticky modifiers send `⌘Space`, `Win+D` and so on.
- Repeats (`isRepeat=1`) are another keydown.
- Caps Lock and Fn are never pressed implicitly. Fn has no Windows key: drop it.

**`textInput`:**
- Type Unicode text. The Mac chunks 16 UTF-16 units per event.
- Windows: `KEYEVENTF_UNICODE` down and up per UTF-16 unit (surrogates in order).
- Map `\n` (and `\r\n`) to a VK_RETURN press and `\t` to VK_TAB. Unicode 0x0A isn't Enter in most
  Windows apps.

**`releaseAllInput`, disconnect, and session end:** release every held button, every held key, then
every held modifier.

### 7.5 macOS virtual key code → Windows scan code (set 1)

Built by reversing the client's `HIDKeyMap` (HID usage → kVK) and applying the standard USB HID →
PS/2 set-1 table. Send with `KEYEVENTF_SCANCODE`; `E0`-prefixed codes also need
`KEYEVENTF_EXTENDEDKEY` (and `KEYUP` on release). Unlisted codes: drop and log.

| kVK | Key | Scan | | kVK | Key | Scan |
|---|---|---|---|---|---|---|
| 00 | A | 1E | | 0B | B | 30 |
| 08 | C | 2E | | 02 | D | 20 |
| 0E | E | 12 | | 03 | F | 21 |
| 05 | G | 22 | | 04 | H | 23 |
| 22 | I | 17 | | 26 | J | 24 |
| 28 | K | 25 | | 25 | L | 26 |
| 2E | M | 32 | | 2D | N | 31 |
| 1F | O | 18 | | 23 | P | 19 |
| 0C | Q | 10 | | 0F | R | 13 |
| 01 | S | 1F | | 11 | T | 14 |
| 20 | U | 16 | | 09 | V | 2F |
| 0D | W | 11 | | 07 | X | 2D |
| 10 | Y | 15 | | 06 | Z | 2C |
| 12 | 1 | 02 | | 13 | 2 | 03 |
| 14 | 3 | 04 | | 15 | 4 | 05 |
| 17 | 5 | 06 | | 16 | 6 | 07 |
| 1A | 7 | 08 | | 1C | 8 | 09 |
| 19 | 9 | 0A | | 1D | 0 | 0B |
| 24 | Return | 1C | | 35 | Esc | 01 |
| 33 | Delete (Backspace) | 0E | | 30 | Tab | 0F |
| 31 | Space | 39 | | 1B | − | 0C |
| 18 | = | 0D | | 21 | [ | 1A |
| 1E | ] | 1B | | 2A | \ | 2B |
| 29 | ; | 27 | | 27 | ' | 28 |
| 32 | ` | 29 | | 2B | , | 33 |
| 2F | . | 34 | | 2C | / | 35 |
| 0A | ISO § (non-US \) | 56 | | 39 | Caps Lock | 3A |
| 7A | F1 | 3B | | 78 | F2 | 3C |
| 63 | F3 | 3D | | 76 | F4 | 3E |
| 60 | F5 | 3F | | 61 | F6 | 40 |
| 62 | F7 | 41 | | 64 | F8 | 42 |
| 65 | F9 | 43 | | 6D | F10 | 44 |
| 67 | F11 | 57 | | 6F | F12 | 58 |
| 69 | F13 | 64 | | 6B | F14 | 65 |
| 71 | F15 | 66 | | 6A | F16 | 67 |
| 40 | F17 | 68 | | 4F | F18 | 69 |
| 50 | F19 | 6A | | 5A | F20 | 6B |
| 72 | Help/Insert | E0 52 | | 73 | Home | E0 47 |
| 74 | Page Up | E0 49 | | 75 | Fwd Delete | E0 53 |
| 77 | End | E0 4F | | 79 | Page Down | E0 51 |
| 7B | ← | E0 4B | | 7C | → | E0 4D |
| 7D | ↓ | E0 50 | | 7E | ↑ | E0 48 |
| 47 | Keypad Clear (Num Lock) | 45 + EXTENDED* | | 4B | KP / | E0 35 |
| 43 | KP * | 37 | | 4E | KP − | 4A |
| 45 | KP + | 4E | | 4C | KP Enter | E0 1C |
| 51 | KP = | 59 | | 41 | KP . | 53 |
| 52 | KP 0 | 52 | | 53 | KP 1 | 4F |
| 54 | KP 2 | 50 | | 55 | KP 3 | 51 |
| 56 | KP 4 | 4B | | 57 | KP 5 | 4C |
| 58 | KP 6 | 4D | | 59 | KP 7 | 47 |
| 5B | KP 8 | 48 | | 5C | KP 9 | 49 |
| 5F | KP , (JIS) | 7E | | 5E | JIS _ (Ro) | 73 |
| 5D | JIS ¥ | 7D | | 68 | Kana (LANG1) | 72 |
| 66 | Eisu (LANG2) | 71 | | 6E | Menu/Application | E0 5D |
| 4A | Mute | E0 20 | | 48 | Vol Up | E0 30 |
| 49 | Vol Down | E0 2E | | 3F | Fn | *(drop)* |

Modifier keys (these change held state; flag as modifiers):

| kVK | Key | Windows | Scan |
|---|---|---|---|
| 3B | ⌃ left | LCtrl | 1D |
| 3E | ⌃ right | RCtrl | E0 1D |
| 38 | ⇧ left | LShift | 2A |
| 3C | ⇧ right | RShift | 36 |
| 3A | ⌥ left | LAlt | 38 |
| 3D | ⌥ right | RAlt / AltGr | E0 38 |
| 37 | ⌘ left | **LWin** | E0 5B |
| 36 | ⌘ right | **RWin** | E0 5C |

\*For Num Lock, SendInput needs the EXTENDED flag with scan code `45`; verify on hardware.

Implied chord modifier keys: control → kVK 3B, option → 3A, shift → 38, command → 37. **The host maps
kVK literally.** Swapping ⌘ and Ctrl is the client's job.

## 8. HostStatus (`LockMonitor`, `HostSession.currentStatus`)

- Sent when the first `selectDisplay` arrives, whenever any field changes, and when capture is lost
  or recovered.
- `isScreenUnavailable = (no frames for ≥ 3 s while the display is awake)`. It's cleared on the first
  frame back, and it's never true while `isDisplayAsleep` is true.
- The Mac retries capture with backoff 0.5 s doubling to 5 s for the whole session, and treats
  "started but no frame within 5 s" as failed.
- Never end a session because capture can't start.

Windows mapping:
- `isScreenLocked`: `WTSRegisterSessionNotification` → `WM_WTSSESSION_CHANGE`
  `WTS_SESSION_LOCK`/`UNLOCK`. Initial state from
  `WTSQuerySessionInformation(WTSSessionInfoEx).SessionFlags == WTS_SESSIONSTATE_LOCK`. Message:
  "The PC is locked".
- `isSecureInputActive`: the secure desktop is up while the session isn't locked (a UAC prompt, the
  Ctrl+Alt+Del screen). Detect by polling `OpenInputDesktop` once a second: if it fails, or
  `GetUserObjectInformation(UOI_NAME) != "Default"`, the secure desktop is showing. Message: "A
  Windows security prompt is open on the PC". Windows has no secure-input equivalent for password fields.
- `inputPath`: `"native"`.
- `isDisplayAsleep`: `RegisterPowerSettingNotification(GUID_CONSOLE_DISPLAY_STATE)`; 0 = off.
- `isScreenUnavailable`: as above. This also covers an RDP login taking the console away.

## 9. Other features

### 9.1 Adaptive bitrate (`AdaptiveController.swift`, pure logic)

- `loss = framesDropped > 0 || queueDepth > 1`.
- On loss: `bitrate = max(2000, bitrate × 0.7)` and hold probing for 2 s.
- Otherwise, if the hold is over and 2 s have passed since the last change:
  `bitrate = min(60000, bitrate × 1.1)`.
- A changed bitrate is applied to the encoder.
- Mode: `smoothed = 0.9·smoothed + 0.1·dirtyRatio`. Text mode below 0.02 runs at 30 fps with maxQP
  32; motion mode runs at 60 fps with maxQP 44.
- A minimal host may ignore `qualityFeedback` and use a fixed bitrate. Today's client always sends
  `queueDepth = 0`, so the Mac effectively ramps to 60 Mbps. The Windows host should also treat its
  own send backlog (§7.3) as loss.

### 9.2 Displays

- `displays` in `authResult`, and `displayList` in reply to the `refreshDisplays` command.
- Current clients have **no display picker**: they always send `fitViewport`, so the host streams the
  **primary** display.
- Windows `DisplayInfo`:
  - `id`: the number in `\\.\DISPLAYn`
  - `name`: DisplayConfig monitor friendly name
  - `pixel*`: physical size; `scale`/`point*`: as in §7.4
  - `originX/Y`: the monitor rect's top-left in virtual-desktop pixels
  - `isMain`: `MONITORINFOF_PRIMARY`
  - `isBuiltIn`: output technology is internal
  - `isVirtual`: false
  - `refreshRate`: `dmDisplayFrequency`

### 9.3 Clipboard (`ClipboardBridge.swift`)

- Host → client: watch for changes (the Mac polls every 0.5 s) and send the whole payload whenever
  the clipboard changes. The payload carries text, RTF (if present), and PNG (if an image, ≤ 24 MiB).
- Client → host: sent only when the user taps "Send Clipboard"; apply it with **echo suppression**.
- The payload also goes out once when a stream starts, if not empty.
- Disabled in synthetic mode.
- Windows specifics:
  - Use `AddClipboardFormatListener` and track `GetClipboardSequenceNumber` to suppress echoes.
  - Text is `CF_UNICODETEXT`: convert LF→CRLF when applying and CRLF→LF when sending.
  - RTF is `RegisterClipboardFormat("Rich Text Format")`.
  - Images: write `"PNG"` plus `CF_DIBV5`; read `"PNG"` if present, else convert `CF_DIBV5` to PNG.

### 9.4 Host commands (`HostSession.handle`)

| Command | Mac | Windows |
|---|---|---|
| lockScreen | SACLockScreenImmediate | `LockWorkStation()` |
| sleepDisplay | `pmset displaysleepnow`; then ignore non-release input for 2 s | `SendMessage(ownHwnd, WM_SYSCOMMAND, SC_MONITORPOWER, 2)`; same 2 s rule |
| wakeDisplay | declare user activity; **also "retry capture now"** | 1 px `SendInput` move and back, plus `SetThreadExecutionState(ES_DISPLAY_REQUIRED)`; retry capture |
| releaseAllInput | release all | release all |
| refreshDisplays | send `displayList` | same |
| restoreDisplays | disconnect the virtual display | no-op |

Synthetic mode on the Mac ignores commands except sleep/wake with the pretend display. While any
session is active the Mac prevents idle display sleep. On Windows, hold
`ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED` on a dedicated thread; an explicit
sleepDisplay still turns the monitor off.

### 9.5 Audio and dictation

Not in Windows v1. Don't advertise `audio` or `dictationEngines`. The client then hides or disables
those features and never sends kinds 63, 64 or 123.

### 9.6 disconnect

- Client → host: end the session.
- Host → client: the client stops and shows "The Mac ended the session." with **no automatic
  reconnect**.
- Send it only when the user deliberately disconnects or revokes a device. On app quit or restart,
  just close the socket so clients reconnect.

## 10. File channel (`AttachTokenRegistry`, `FileTransferEngine`, `HostController`, `HostSession.attachFileChannel`)

### 10.1 Tokens

- `issue(owner, peer)`: 32 random bytes. It removes the owner's older tokens and any expired ones.
  Lifetime **60 s**. `peer` is the **address only** (no port) of the connection the token was issued on.
- `claim(token, peer)`:
  - Constant-time compare against **every** entry (no early exit).
  - A matching entry is **removed whether or not the rest passes**: single use.
  - Succeeds only if `entry.peer == peer` and it hasn't expired. Compare `IPAddress` values after
    `MapToIPv4()`.
- `revoke(owner)` runs when the session ends.
- On a failed claim the host closes the connection silently.

### 10.2 Attach

- A new connection's first message is `attachMedia{sessionToken}`.
- After a successful claim, the session accepts it only if the session is streaming or files-only,
  **the client said `fileTransfer`**, and **no file channel is attached yet**. Otherwise close.
- Both roles start a file engine on it.
- The client opens the channel right after `authResult ok`; it's 1:1 with the session.

### 10.3 Lifetime (`filesOnlySessions`)

The channel **outlives its session**. It closes when:
- the client closes it,
- the client's key is revoked, or
- **120 s** pass with nothing moving after the session ended (the host checks every 15 s; "busy"
  means any transfer queued, active or rehashing).

The client normally closes an idle channel after 30 s.

### 10.4 Kinds allowed on a file channel

Only 80–84 and chunks in the correct direction: the host sends 103 and accepts 124. **Any other
kind, including ping, closes the channel.** Nothing pings a file channel.

### 10.5 JSON

- **FileOffer (80)**
  - `id` UUID
  - `name` String: untrusted; the receiver sanitises it
  - `byteCount` UInt64
  - `modified?` Double: seconds since 2001-01-01
  - `uti?` String, e.g. "com.adobe.pdf"; may be omitted when sending
- **FileAccept (81)**
  - `id`
  - `resumeOffset` UInt64 (**required**; 0 for a fresh file, or when rejecting)
  - `rejected?` String: user-facing reason; present means refused
- **FileComplete (82)**: `id`, `sha256` base64 of the 32-byte SHA-256 of the **whole** file (resumed
  prefix included)
- **FileResult (83)**: `id`, `ok` Bool, `savedName?` String (final name after sanitising and
  de-duplicating), `error?` String (user-facing)
- **FileCancel (84)**: `id`

### 10.6 Engine rules, both roles

- **Sending:**
  - One file at a time per direction, FIFO.
  - Send `fileOffer`, then wait for the reply:
    - `fileAccept.rejected` → failed with that reason.
    - `resumeOffset > byteCount` → failed.
    - `fileResult` before accept → failed. `fileCancel` → cancelled.
  - If `resumeOffset > 0`, hash the first `resumeOffset` bytes from disk off the hot path, then
    stream from there.
  - Chunks are **256 KiB** at explicit offsets, in order, with **≤ 4 chunks handed to the socket but
    not yet written**.
  - After the last chunk has been flushed, send `fileComplete{sha256}` and wait for `fileResult`.
  - If the file changes size or can't be read mid-send: send `fileCancel`, fail with "The file
    changed while it was being sent."
- **Receiving an offer:**
  - Reject "That file is already being transferred." if the id is already incoming, or equals the id
    being sent.
  - Sanitise the name (§10.7). The partial file is `<folder>/.vantage-<ID uppercase>.partial`.
  - If a partial exists with size `0 < s ≤ byteCount`, re-hash it. If that works, `resumeOffset = s`
    and the file is opened for writing, truncated to `s`. Otherwise start fresh.
  - Rejections:
    - `byteCount > 64 GiB` → "The file is too large (…)."
    - Free space < `(byteCount − alreadyHave) + 256 MiB` → "There isn't enough free space for it."
    - Can't create the file → "The file couldn't be saved on this device."
  - Rejecting deletes the partial.
  - **Replies from the receive loop are enqueued without waiting for the socket.** If two big files
    cross and both loops wait on full pipes, they deadlock.
- **Chunks:**
  - A chunk for an unknown id is ignored (late chunks after a cancel).
  - `offset != received`, or overflowing `byteCount` → fail:
    `fileResult{ok:false, error:"The file arrived damaged."}` and delete the partial.
  - A write error → "The file couldn't be saved. The disk may be full."
- **fileComplete:**
  - Require `received == byteCount` and a constant-time digest match. Otherwise delete, send
    `fileResult{ok:false, error:"The file arrived damaged. Try sending it again."}`.
  - Then set the mtime from `modified`, and rename to the first free name (`"Name.ext"`,
    `"Name 2.ext"`, … `"Name 9999.ext"`, then a random 10 000–999 999), retrying up to 8 times on a race.
  - Send `fileResult{ok:true, savedName}`.
  - Windows: **clear the Hidden attribute before renaming** (set it on the partial when creating it),
    and add `Zone.Identifier` (`[ZoneTransfer]\r\nZoneId=3`) to the saved file. That's the Windows
    equivalent of the Mac's quarantine flag.
- **fileCancel:**
  - For the current outgoing file → cancelled.
  - For an incoming file → delete its partial and stop.
  - For an unknown id → delete its partial if no other channel holds it.
  - No result follows a cancel.
- **Channel lost:** outgoing fails ("The connection was lost."); incoming partials are **kept** for
  resume. At engine start, delete partials untouched for more than 24 h.
- **Partial ownership:** if a new channel from the same sender offers an id whose partial another
  live channel is still writing, the new channel takes it over, and the old engine lets go without
  deleting.
- Old peers answer `resumeOffset = 0`, which is always valid. A minimal v1 may always answer 0.
- The client re-offers a cut-off send up to 10 times with the same id.
- The Mac host re-sends its own interrupted sends when the same client fingerprint attaches again
  within 1 h. That's optional for Windows v1.

### 10.7 Name sanitising (`FileNames.sanitize`)

1. NFC-normalise.
2. Split on `/` and `\`; take the last component that isn't blank.
3. Drop Unicode scalars in categories Cc, Cf, Zl, Zp, Cs and Cn.
4. Replace `:` with `-`.
5. Trim whitespace. Repeatedly strip leading `.`/whitespace and trailing `.`/whitespace.
6. If empty, use `"Untitled"`.
7. If longer than **200 UTF-8 bytes**: keep the extension (last `.`, not first or last character)
   when `".ext"` is ≤ 16 bytes, and cut the base name on whole grapheme clusters (`StringInfo` text
   elements). Otherwise cut the whole name.

**Windows additions:** replace `< > " | ? *` with `-`, and prefix `_` to reserved device names (CON,
PRN, AUX, NUL, COM0–9, LPT0–9 and the superscript ¹²³ variants; case-insensitive, with or without an
extension). Uniqueness checks are case-insensitive, as NTFS is.

### 10.8 Folders

- Mac: `~/Downloads` or the folder set in Settings.
- Windows: `FOLDERID_Downloads`, or the folder set in Settings.
- Synthetic hosts: `$TMPDIR/VantageSynthetic/Received`, or `--receive-folder`.

## 11. DEBUG-only and synthetic behaviour of the Mac host (mirrored by the C# SyntheticHost)

DEBUG-only flags:
- `--synthetic-capture`: rendered test pattern; no real input, clipboard or commands; a **separate
  trust store**; readiness is always true; the synthetic display is id 1, "Vantage Synthetic
  Display", scale 2, points = `max(640, viewport.w)` × `max(480, viewport.h)`.
- `--port N`
- `--pairing-code N`: fixed, never expires
- `--exit-after S`
- `--display-asleep`: pretend display that starts asleep; sleep/wake commands work
- `--capture-fails-for S`
- `--send-file-on-connect PATH`
- `--receive-folder PATH`
- `--log-input-events`

Loopback peers are also accepted only in DEBUG. UI tests use ports 47821/47822,
`TEST_RUNNER_VANTAGE_TEST_HOST`, `TEST_RUNNER_VANTAGE_SYNTHETIC_HOST` and
`TEST_RUNNER_VANTAGE_UNAVAILABLE_HOST`. The Swift live tests use `VANTAGE_TEST_HOST` and
`VANTAGE_TEST_PAIRING_CODE` (default 246810).

## 12. Sequence summary

```
C: hello ─────────────────────▶ H  (peer checked; 15 s for the first message)
C ◀──────────────────── challenge   (or authResult versionMismatch, then close)
C: authenticate ──────────────▶ H  (verify sig → pairing → probe/filesOnly/screen)
C ◀──────────────────── authResult (ok + token + displays + caps)  [non-ok → close]
C: selectDisplay ─────────────▶ H
C ◀──── hostStatus, [clipboard], streamConfig, videoConfig, videoFrame(IDR), videoFrame…
C: ping+qualityFeedback every 250 ms ▶ H ; H: pong
(file channel) C: attachMedia{token} ▶ H ; then fileOffer/Accept/chunks/Complete/Result both ways
```
