# Tailscale engineering research for Vantage

Research date: 2026-09-21. Verified locally against **Tailscale 1.102.4** (standalone / `macsys` variant, `io.tailscale.ipn.macsys`, Developer ID team `W5364U7YZB`) on Drew's MacBook Pro, tailnet `tail1234.ts.net`.

Scope: iPadOS 27 client discovers and connects to a macOS 27 host over Tailscale only. No app code is written here.

---

## Summary of recommendations

1. **Discovery on the iPad needs the Tailscale HTTP API (OAuth), or manual entry. There is no credential-free way for a third-party iPadOS app to enumerate tailnet peers.** The `http://100.100.100.100/api/data` endpoint is real, unauthenticated, and works today — but it returns **only the local device's own identity**, never a peer list. See §1.5. Plan for the Screens 5 model: user pastes a **Tailnet ID** + **OAuth client secret** (`tskey-client-…`) with scope `devices:core:read`.
2. **Offer a "no credentials" path as the default and OAuth as an upgrade.** Most users have exactly one Mac. Let them type/paste the MagicDNS name (`drews-macbook-pro-1.tail1234.ts.net`) or the 100.x IP once. Use `/api/data` on the iPad purely to confirm Tailscale is up and to learn the tailnet's MagicDNS suffix so you can autocomplete `<hostname>.<suffix>`. Reserve the OAuth flow for the "show me a picker of all my devices" feature.
3. **On the host, shell out to `/usr/local/bin/tailscale` — do not reimplement the LocalAPI handshake.** `/usr/local/bin/tailscale` is a 2-line `/bin/sh` shim that execs `/Applications/Tailscale.app/Contents/MacOS/Tailscale`. It resolves the LocalAPI port + token itself and survives Tailscale upgrades that rotate the port. Direct LocalAPI is viable (verified working) but requires reading a root-owned, `admin`-group-only file and re-reading it after every Tailscale restart. See §1.4.
4. **Authenticate iPad clients by tailnet identity using `tailscale whois <peer-ip>` on the host.** Verified working: it returns the peer's stable node ID, MagicDNS name, user ID, login name, tags, and CapMap. This is a genuinely strong authentication primitive — the source IP of a Tailscale connection cannot be spoofed by a non-tailnet party, and DERP/peer-relay do **not** change the observed source IP. Caveats in §1.6.
5. **Bind the host listener to the Tailscale IP, and re-validate at accept time.** Use `NWParameters.requiredLocalEndpoint` on the current 100.x address (the utun interface index changes on every reconnect — locally it is `utun16` today), re-bind on `NWPathMonitor` changes, and independently check that the accepted peer address is inside `100.64.0.0/10` or `fd7a:115c:a1e0::/48` before doing anything. Belt and braces: the bind can silently become wrong, the CGNAT check cannot.
6. **Design the video path for a 1280-byte MTU.** Verified: `utun16 … mtu 1280`. For QUIC/UDP datagrams target ~1200 bytes of payload; for TCP expect an MSS of 1240 (v4) / 1220 (v6). Do not assume 1500.
7. **Expect the iPad, not the Mac, to be the throughput bottleneck.** The iOS Tailscale Network Extension historically ran in a ~15 MB memory jail and is a documented source of tunnel teardowns under sustained large transfers. Budget bitrate conservatively, implement graceful degradation, and detect/report DERP-relayed paths as a "reduced quality" state.
8. **Unattended access on a personal MacBook is the weak link and cannot be fully solved with the GUI app.** The standalone/App Store GUI variants cannot run before user login — this is documented by Tailscale, not a bug. Only the open-source `tailscaled` variant can. See §3 for the practical trade-off.

---

## 1. Discovery and identity

### 1.1 OAuth client credentials flow

**Token endpoint** (verified from Tailscale docs):

```
POST https://api.tailscale.com/api/v2/oauth/token
Content-Type: application/x-www-form-urlencoded

client_id=<id>&client_secret=<secret>
```

Documented curl form:

```shell
curl -d "client_id=${OAUTH_CLIENT_ID}" -d "client_secret=${OAUTH_CLIENT_SECRET}" \
    "https://api.tailscale.com/api/v2/oauth/token"
```

**Response:**

```json
{
  "access_token": "tskey-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ",
  "token_type": "Bearer",
  "expires_in": 3600,
  "scope": "devices"
}
```

- **Lifetime: 3600 s (1 hour), not configurable.** "An API access token expires after one hour. This time cannot be modified."
- The token is a bearer credential. Refresh by re-running the client-credentials request; there is no refresh token.
- Usage: `Authorization: Bearer $ACCESS_TOKEN`.

**Notable shortcut used by Screens 5:** the client *secret alone* is sufficient. Tailscale accepts the OAuth client secret (`tskey-client-…`) directly as an API access token in the `Authorization: Bearer` header for many endpoints — which is why the Screens setup flow says "You will not need the Client ID." Treat this as convenient but undocumented-ish; the safest implementation does the proper token exchange and caches the 1-hour token.

**Scopes** (from the Trust credentials reference — Tailscale renamed "OAuth clients" to "trust credentials" and made scopes granular; the old flat `devices` scope is legacy):

| Scope | Grants |
| --- | --- |
| `devices:core:read` | **What Vantage needs.** Read the device inventory. |
| `devices:core` | Read + write devices: authorize, delete, retag. |
| `devices:routes:read` / `devices:routes` | Subnet router / exit node settings. |
| `devices:posture_attributes:read` / `…` | Posture attributes. |
| `all:read` | Read-only across the whole tailnet (over-broad for us). |
| `all` | Everything (never ask for this). |
| `dns:read`, `policy_file:read`, `users:read`, `auth_keys`, `oauth_keys`, `webhooks`, `logs:network:read`, … | Not needed. |

Legacy mapping: old `devices` → `devices:core`; old `routes` → `devices:routes`; old `acl` → `policy_file`.

In the admin console UI the scope appears as **Devices → Core → Read**, which is exactly what the Screens instructions tell users to check.

**Tailnet identifier.** Three accepted forms:
- `-` — "the default tailnet of the token owner". Documented: "You can optionally use the value `-` as the tailnet ID" when using an access token owned by that tailnet. **Use `-` unless you have a reason not to.**
- The tailnet *name*, e.g. `tail1234.ts.net` or an org domain like `example.com`.
- The opaque **Tailnet ID** from *Settings → General*, e.g. `TcfXSop1q66VBYTZ`. This is the value Screens asks for.

For our tailnet, `tailscale status --json` reports:

```json
"MagicDNSSuffix": "tail1234.ts.net",
"CurrentTailnet": {
  "Name": "someone@privaterelay.appleid.com",
  "MagicDNSSuffix": "tail1234.ts.net",
  "MagicDNSEnabled": true
}
```

Note that `CurrentTailnet.Name` here is the **login identity**, not the Tailnet ID. If you need the Tailnet ID programmatically, prefer `-`.

### 1.2 Listing devices

```
GET https://api.tailscale.com/api/v2/tailnet/-/devices?fields=all
Authorization: Bearer tskey-…
```

Query parameter `fields`: `default` (the default) or `all`. Only these two values are supported. `fields=all` adds `enabledRoutes`, `advertisedRoutes`, and `clientConnectivity` — everything else is present either way.

Response envelope: `{"devices": [ … ]}`.

**Device object** — exact JSON keys, from the Tailscale Go client (`tailscale.com/client/tailscale`, `devices.go`) plus the v2 client (`tailscale.com/client/tailscale/v2`):

```go
type Device struct {
    Addresses         []string `json:"addresses"`      // ["100.x.y.z", "fd7a:…"]
    DeviceID          string   `json:"id"`             // numeric-ish string, legacy ID
    NodeID            string   `json:"nodeId"`         // stable node ID, e.g. "nABC123CNTRL"
    User              string   `json:"user"`           // login name of owner
    Name              string   `json:"name"`           // FQDN: "host.tail1234.ts.net"
    Hostname          string   `json:"hostname"`       // OS hostname, e.g. "Drew's MacBook Pro"
    ClientVersion     string   `json:"clientVersion"`  // "" for external devices
    UpdateAvailable   bool     `json:"updateAvailable"`
    OS                string   `json:"os"`             // "macOS", "iOS", "linux", …
    Tags              []string `json:"tags"`
    Created           string   `json:"created"`        // RFC3339; "" for external
    LastSeen          string   `json:"lastSeen"`       // RFC3339
    KeyExpiryDisabled bool     `json:"keyExpiryDisabled"`
    Expires           string   `json:"expires"`
    Authorized        bool     `json:"authorized"`
    IsExternal        bool     `json:"isExternal"`     // shared in from another tailnet
    MachineKey        string   `json:"machineKey"`     // "" for external
    NodeKey           string   `json:"nodeKey"`
    BlocksIncomingConnections bool `json:"blocksIncomingConnections"`

    // Only with ?fields=all:
    EnabledRoutes      []string            `json:"enabledRoutes"`
    AdvertisedRoutes   []string            `json:"advertisedRoutes"`
    ClientConnectivity *ClientConnectivity `json:"clientConnectivity"`

    PostureIdentity *DevicePostureIdentity `json:"postureIdentity"`
    TailnetLockKey  string                 `json:"tailnetLockKey,omitempty"`
    TailnetLockErr  string                 `json:"tailnetLockError,omitempty"`
}

type ClientConnectivity struct {
    Endpoints             []string              `json:"endpoints"`   // ip:port candidates
    DERP                  string                `json:"derp"`        // e.g. "127.3.3.40:2"
    MappingVariesByDestIP bool                  `json:"mappingVariesByDestIP"` // hard NAT
    DERPLatency           map[string]DerpRegion `json:"latency"`     // keyed "New York City", "Seattle", …
    ClientSupports        map[string]bool       `json:"clientSupports"` // hairPinning, ipv6, pcp, pmp, udp, upnp
}

type DerpRegion struct {
    Preferred           bool    `json:"preferred,omitempty"`
    LatencyMilliseconds float64 `json:"latencyMs"`
}

type DevicePostureIdentity struct {
    Disabled      bool     `json:"disabled,omitempty"`
    SerialNumbers []string `json:"serialNumbers,omitempty"`
}
```

The newer v2 client additionally exposes `isEphemeral` (`json:"isEphemeral"`), `sshEnabled` (`json:"sshEnabled"`), `distro`, and — critically — **`connectedToControl` (`json:"connectedToControl"`)**.

### 1.3 Does the API report online/offline? Yes, since 2025-10-08

This changed recently and the old "lastSeen only" answer is out of date.

> **2025-10-08 changelog:** "The Read and List endpoint responses in the Devices API include a `connectedToControl` flag, which indicates whether the device has recently connected to the Tailscale control server. The `lastSeen` field is included only when `connectedToControl` is false."

That initial rollout broke consumers and was partially reverted three days later:

> **status.tailscale.com incident 01K76ZVEFT538NWXK0XJFKT2HD (Oct 10, 2025):** a change to `lastSeen` "caused unexpected negative impact to some workloads"; Tailscale rolled out a change to "restore the `lastSeen` field on devices which are connected to Tailscale's control server." Investigating 11:59 AM → resolved 2:44 PM.

**Practical guidance for Vantage:** read `connectedToControl` as the online signal; fall back to `lastSeen` age (treat > ~5 min as offline) if the field is absent. Do not build UI that depends on sub-minute `lastSeen` granularity — it reflects control-plane heartbeats, not data-plane liveness, and a device can be `connectedToControl: true` while being unreachable on the data plane (e.g. asleep behind a firewall that still holds the control connection, or reachable only via DERP).

`connectedToControl` also cannot tell you whether *your* host app is running and listening. The only reliable liveness check is attempting your own connection.

### 1.4 The credential-free host-side alternative: CLI and LocalAPI

This is the right answer for the **Mac host**, which has no credential problem at all.

#### `tailscale status --json`

Verified locally. Top-level keys:

```
Version, TUN, BackendState, HaveNodeKey, AuthURL, TailscaleIPs, Self,
Health, MagicDNSSuffix, CurrentTailnet, CertDomains, ExtraRecords,
Peer, User, ClientVersion
```

`Peer` is a map keyed by `nodekey:<hex>`. Verified per-peer keys on 1.102.4:

```
ID, NodeID, PublicKey, HostName, DNSName, OS, UserID, TailscaleIPs,
AllowedIPs, Tags, Addrs, CurAddr, Relay, PeerRelay, RxBytes, TxBytes,
Created, LastWrite, LastSeen, LastHandshake, Online, ExitNode,
ExitNodeOption, Active, PeerAPIURL, TaildropTarget, NoFileSharingReason,
CapMap, InNetworkMap, InMagicSock, InEngine, Location
```

Authoritative semantics from `tailscale.com/ipn/ipnstate` `PeerStatus`:

| Field | Meaning |
| --- | --- |
| `DNSName` | Peer FQDN **with a trailing dot**: `"host.<MagicDNSSuffix>."` — strip it before use. |
| `HostName` | `HostInfo.Hostname`; "not a DNS name or necessarily unique" (ours is literally `Drew's MacBook Pro`). |
| `CurAddr` | "one of Addrs, or unique if roaming". **Non-empty ⟹ direct connection.** |
| `Relay` | DERP region code, e.g. `"dfw"`. |
| `PeerRelay` | "peer relay address (`ip:port:vni`)". Empty when not using a peer relay. |
| `Online` | "whether node is connected to the control plane" — same caveat as `connectedToControl`. |
| `LastSeen` | "last seen to tailcontrol; **only present if offline**". Zero value is `0001-01-01T00:00:00Z`. |
| `LastHandshake` | "with local wireguard" — the real data-plane liveness signal. |
| `Active` | "some packet sent to this peer in the past two minutes … definition is subject to change". |
| `RxBytes` / `TxBytes` | Per-peer counters. Useful for a live throughput readout. |
| `Expired` / `KeyExpiry` | Node key expiry. |

Observed sample (offline iOS peer, no contact since August):

```
localhost | family-iphone.tail1234.ts.net. | iOS | online=False | cur= | relay= | peerrelay='' | active=False | lastseen=2026-08-04T03:06:05.1Z
```

#### LocalAPI directly

The macOS GUI variants do **not** expose a unix socket. They listen on a **random loopback TCP port** with a bearer token. From `safesocket/safesocket_darwin.go`:

```go
ln, err := net.Listen("tcp4", "127.0.0.1:0")   // localhostListener()
buf := make([]byte, 10); crand.Read(buf)       // 10 random bytes
token := fmt.Sprintf("%x", buf)                // 20 hex chars
```

Discovery differs by variant:

**Standalone / `macsys`** (what is installed here) — `isMacSysExt()` branch:

```
/Library/Tailscale/ipnport                 → dangling symlink whose TARGET IS THE PORT NUMBER
/Library/Tailscale/sameuserproof-<port>    → file containing only the token, hex, + "\n"
```

File mode `0640`, chowned `root:admin` (uid 0, gid 80) so "all members of the admin group" can read it. Verified locally:

```
lrwxr-xr-x  ipnport -> 60091
-rw-r-----  1 root  admin  21  sameuserproof-60091
$ readlink /Library/Tailscale/ipnport
60091
$ id -Gn | grep admin        # staff admin _lpadmin
```

Note `cat /Library/Tailscale/ipnport` **fails** (`No such file or directory`) because the symlink target is a port number, not a path. You must `readlink`.

**Mac App Store variant** — the token file lives in the app group container and is *discovered via `lsof`*, not a fixed path. From `readMacosSameUserProof()`:

```go
exec.Command("lsof", "-n", "-a", fmt.Sprintf("-u%d", os.Getuid()), "-c", "IPNExtension", "-F")
// scans output for the substring ".tailscale.ipn.macos/sameuserproof-"
// filename form: sameuserproof-<port>-<token>   (perm 0666)
```

The group container is `W5364U7YZB.io.tailscale.ipn.macos` (team ID `W5364U7YZB`, confirmed by `codesign` on the installed app). **On this machine there is no Tailscale group container** — `ls ~/Library/Group Containers/ | grep -i tailscale` returned nothing, consistent with the standalone variant.

Fallback order in `portAndTokenFromSameUserProof()`: App Store (lsof) → macsys (`/Library/Tailscale`) → plain unix socket for open-source `tailscaled`. Also: the CLI validates the port with a 1-second `net.DialTimeout` before trusting it, "files may be stale."

**Verified LocalAPI call** (HTTP Basic, empty username, token as password):

```bash
TOK=$(cat /Library/Tailscale/sameuserproof-60091)
curl -s -u ":$TOK" "http://127.0.0.1:60091/localapi/v0/status"
```

Returned the full status JSON. Endpoint probe results on 1.102.4:

| Path | Status |
| --- | --- |
| `/localapi/v0/status` | 200 |
| `/localapi/v0/whois?addr=IP[:PORT]` | 200 (400 without `addr`) |
| `/localapi/v0/prefs` | 200 |
| `/localapi/v0/dns-osconfig` | 200 |
| `/localapi/v0/metrics` | 200 |
| `/localapi/v0/derpmap` | 200 |
| `/localapi/v0/tka/status` | 200 |
| `/localapi/v0/profiles/current` | 200 |
| `/localapi/v0/files/` | 200 |
| `/localapi/v0/ping` | 400 (needs params) |
| `/localapi/v0/bugreport`, `/upload-client-metrics` | 405 (POST-only) |
| `/localapi/v0/netmap`, `/pprof`, `/debug/peer-endpoint-changes` | 404 |

`prefs` keys observed: `ControlURL, RouteAll, ExitNodeID, ExitNodeIP, InternalExitNodePrior, ExitNodeAllowLANAccess, CorpDNS, RunSSH, RunWebClient, WantRunning, LoggedOut, ShieldsUp, AdvertiseTags, Hostname, NotepadURLs, AdvertiseRoutes, AdvertiseServices, Sync, NoSNAT, NoStatefulFiltering, NetfilterMode, AutoUpdate, AppConnector, PostureChecking, NetfilterKind, RemoteConfig, DriveShares, Config`.

#### Verdict: CLI vs LocalAPI for a Developer-ID (non-sandboxed) host app

**Shell out to `/usr/local/bin/tailscale`.** Reasons:

- It is a trivial shim, not a symlink: `#!/bin/sh` + `exec` of `/Applications/Tailscale.app/Contents/MacOS/Tailscale "$@"`. Both paths reach the same universal binary; either works. `/usr/local/bin/tailscale` is friendlier because it survives a user moving the app, but it is only present if the user ran "Install CLI" — so **probe both**, with `/Applications/Tailscale.app/Contents/MacOS/Tailscale` as the reliable fallback.
- Tailscale rotates the LocalAPI port on every daemon restart. The CLI re-resolves it every invocation, validates it with a dial, and handles all three variants. You would be reimplementing `lsof`-scraping for App Store users.
- The `sameuserproof` file is `root:admin 0640`. A Mac whose user is a **standard (non-admin) account cannot read it** — direct LocalAPI would fail for that user while the CLI still works (the App Store path uses `0666` in the user's own container). This alone argues against hardcoding the direct path.
- Cost: ~30–60 ms per `tailscale status --json` invocation. For a status poll every few seconds that is irrelevant. If you need high-frequency peer stats (live Rx/Tx for a bitrate HUD), cache the port+token that the CLI would find and hit `/localapi/v0/status` directly, refreshing on dial failure.

Do **not** ship a non-sandboxed app that assumes port 60091 or the current `utun16` — both are per-boot values.

### 1.5 The quad100 endpoint — real, unauthenticated, and insufficient

**Verified from the Mac, no credentials:**

```bash
$ curl -s http://100.100.100.100/api/data
{"ID":"nABC123CNTRL","Status":"Running","DeviceName":"drews-macbook-pro-1",
 "TailnetName":"tail1234.ts.net","DomainName":"Drew's Network",
 "IPv4":"100.64.0.2","IPv6":"fd7a:115c:a1e0::2","OS":"macOS",
 "IPNVersion":"1.102.4",
 "Profile":{"ID":1234567890123456,"LoginName":"someone@privaterelay.appleid.com","DisplayName":"someone"},
 "IsTagged":false,"Tags":null,"KeyExpiry":"2027-02-16T16:22:49Z","KeyExpired":false,
 "TUNMode":true,"IsSynology":false,"DSMVersion":0,"IsUnraid":false,"UnraidToken":"",
 "URLPrefix":"","UsingExitNode":null,"AdvertisingExitNode":false,
 "AdvertisingExitNodeApproved":false,"AdvertisedRoutes":null,
 "RunningSSHServer":false,"ClientVersion":{"RunningLatest":true},
 "ACLAllowsAnyIncomingTraffic":true,
 "ControlAdminURL":"https://login.tailscale.com/admin",
 "LicensesURL":"https://tailscale.com/licenses/apple",
 "Features":{"advertise-exit-node":true,"advertise-routes":true,"auto-update":false,
             "ssh":false,"use-exit-node":true}}
```

HTTP 200, `Content-Type: application/json`, headers `X-Frame-Options: DENY`, `Cross-Origin-Resource-Policy: same-origin`, and a CSP with a script hash. `GET http://100.100.100.100/` also returns 200 (the HTML web UI).

**What this is.** It is Tailscale's built-in device web interface (`client/web` package), served on quad100 port 80. Per Tailscale docs: minimum client v1.56.0 to have the web interface at all; **as of v1.64.0 it runs on `100.100.100.100` by default** (before that it needed `tailscale set --webclient`). The unauthenticated `/api/data` GET is explicitly whitelisted in `Server.authorizeRequest`:

```go
case r.URL.Path == "/api/data" && r.Method == httpm.GET:
    // Readonly endpoint allowed without valid browser session.
    return true
```

Route installation is unconditional — in `ipnlocal/local.go`, whenever the node has any IPv4 address:

```go
rs.Routes = append(rs.Routes, netip.PrefixFrom(tsaddr.TailscaleServiceIP(), 32))
```

and `tsaddr.TailscaleServiceIP()` is `100.100.100.100` (`TailscaleServiceIPv6String = "fd7a:115c:a1e0::53"`). So the address is reachable from **any** process on the device, including a third-party sandboxed app, with no entitlement and no Tailscale cooperation.

**Why it does not solve discovery.** Look at `serveGetNodeData` — every field is populated from `st.Self`, `prefs`, and `distro`. There is **no peer enumeration anywhere in the response**. `100.100.100.100` is a link-local service address served by your own device's Tailscale instance; you cannot query another node's quad100.

**So the honest answer to "does this remove the credential setup?" is no** — but it is still worth using on the iPad for three things:

1. **Zero-cost "is Tailscale on?" check.** A 200 from `/api/data` with `"Status":"Running"` is a stronger signal than interface sniffing.
2. **Learn the tailnet suffix** (`TailnetName`) so you can turn a short hostname the user types into a full MagicDNS FQDN.
3. **Learn the user's own identity** (`Profile.LoginName`) to pre-scope the device list and to show "connecting as …".

Two caveats to verify on hardware:

- The upstream open-source `handleQuad100Port80Conn` in `ipn/ipnlocal/local.go` serves only a stub (`<h1>Tailscale</h1>` plus a list of local addresses) with CSP `default-src 'self';`. The rich JSON we observed has a *different* CSP (`img-src * data:` plus a script hash), so the Apple client is wiring `client/web` into quad100 itself. That is closed-source Apple-client behaviour and could differ between the macOS and iOS apps.
- Tailscale's own doc for the web interface says it runs on "all machines running the **desktop** platform (Linux, macOS, Windows)", while other doc text says a device needs v1.56.0+ "including iOS". **Treat iOS quad100 availability as unverified** and make the iPad code path tolerate a connection refusal.

There is no other credential-free peer-listing surface. PeerAPI (`http://100.64.0.2:34330`, advertised as `PeerAPIURL` / `Hostinfo.Services` `peerapi4`/`peerapi6`) is a node-to-node RPC for Taildrop and DNS proxying, is authenticated by whois on the caller, and does not expose a netmap.

### 1.6 `tailscale whois` — authenticating clients by tailnet identity

**Verified working** for both self and an arbitrary peer, with or without a port:

```bash
$ /usr/local/bin/tailscale whois 100.64.0.2
Machine:
  Name:          drews-macbook-pro-1.tail1234.ts.net
  ID:            nABC123CNTRL
  Addresses:     [100.64.0.2/32 fd7a:115c:a1e0::2/128]
User:
  Name:     someone@privaterelay.appleid.com
  ID:       1234567890123456

$ /usr/local/bin/tailscale whois 100.64.0.3
Machine:
  Name:           us-lax-wg-402.mullvad.ts.net
  ID:             nXYZ789CNTRL
  Addresses:      [100.64.0.3/32 fd7a:115c:a1e0::3/128]
  AllowedIPs:     [0.0.0.0/0 ::/0]
  Tags:           tag:mullvad-exit-node
```

LocalAPI equivalent, verified:

```
GET /localapi/v0/whois?addr=100.64.0.2:1234
```

(the `:PORT` is optional in practice; omitting `addr` entirely gives 400).

`WhoIsResponse` (`tailscale.com/client/local`) contains:

- **`Node`** — a `tailcfg.Node`: `ID` (numeric), `StableID` (`"nABC123CNTRL"`), `Name` (FQDN with trailing dot), `User` (user ID), `Key` (`nodekey:…`), `KeyExpiry`, `DiscoKey`, `Addresses`, `AllowedIPs`, `Endpoints`, `Hostinfo` (incl. `Hostname` and `Services`), `Created`, `MachineAuthorized`, `Capabilities`, `CapMap`, `Tags`.
- **`UserProfile`** — display name, login name, profile picture URL.
- **`CapMap`** — `tailcfg.PeerCapMap`, the grants the *peer* has toward this node. This is the hook for app-level authorization (see §2.4).

**Why this is a good auth primitive.** The 100.x source address of an inbound Tailscale connection is written by the local WireGuard engine after cryptographic authentication of the peer's node key. Nothing off-tailnet can present a `100.64.0.0/10` source to your listener bound on the Tailscale interface. So `whois(peerAddr)` yields a claim you can trust as strongly as you trust Tailscale itself.

**Caveats that matter for Vantage:**

- **Relaying does not affect the source IP.** DERP and peer relays operate below the tailnet IP layer; `whois` sees the same 100.x either way. (`CurAddr`/`Relay`/`PeerRelay` in `status --json` are where you learn the path, not `whois`.)
- **Subnet-routed clients appear as the router.** If someone reaches your Mac through a subnet router / exit node, the source address you see is the *router's* tailnet IP, and `whois` will identify the router node and its owner — not the real originator. For a remote-desktop host this is a genuine authorization hole; pin the allowed `Node.StableID` set explicitly rather than trusting "any tailnet member."
- **Tagged nodes have no human user.** `whois` on a tagged device gives `Tags: [tag:…]` and a synthetic user. Decide whether tagged devices are ever allowed.
- **Shared-in devices** (`IsExternal` / `AltSharerUserID`) belong to a different tailnet's user. Screens explicitly notes "Tailscale's system does not support showing shared devices"; you should likewise decide whether to allow them.
- **`whois` fails for a non-peer address.** Handle the error as "deny", not "unknown".
- Never accept an identity asserted *in your own protocol*. Derive it only from the kernel-reported peer address + `whois`.

### 1.7 Detecting Tailscale on the iPad, and deep links

**VPN detection.** Three independent signals, in increasing order of reliability:

1. `getifaddrs()` — enumerate interfaces, look for a `utun*` whose IPv4 is inside `100.64.0.0/10` (excluding ChromeOS's `100.115.92.0/23`, per `tsaddr.IsTailscaleIPv4`) or whose IPv6 is inside `fd7a:115c:a1e0::/48`. On the Mac this is verified: `utun16 … inet 100.64.0.2 … inet6 fd7a:115c:a1e0::2`. Note there were **18 utun interfaces** present; you must filter by address, never by name or index.
2. `NWPathMonitor` — observe `path.status == .satisfied` and `path.availableInterfaces`. Use this to trigger re-evaluation; `NWInterface` has no public initializer, so you obtain instances from the path, not by name.
3. `GET http://100.100.100.100/api/data` with a 1–2 s timeout — the strongest signal, and it tells you `Status`, `TailnetName`, and identity in one shot (subject to the iOS caveat in §1.5).

**Deep link.** The scheme is real. Verified from the installed macOS bundle:

```
$ /usr/libexec/PlistBuddy -c "Print :CFBundleURLTypes" /Applications/Tailscale.app/Contents/Info.plist
Array {
    Dict { CFBundleURLName = io.tailscale.ipn.macsys
           CFBundleURLSchemes = Array { io.tailscale.ipn.macsys } }
    Dict { CFBundleURLName = io.tailscale.ipn.macos.urlscheme
           CFBundleURLSchemes = Array { tailscale } }
}
```

So `tailscale://` is registered on macOS 1.102.4. Corroborating changelog entry (1.102.1, Aug 3 2026): *"The Tailscale protocol handler supports deep-linking to devices, exit nodes, and settings panels in the application window."*

Important: the long-standing feature request **tailscale/tailscale#14679, "FR: Add custom URL scheme or deep linking to iOS app"** (opened Jan 2025) is about iOS. The 1.102 changelog entry is filed under macOS. **Whether `tailscale://` is claimed by the iOS app is unverified.** Implement `UIApplication.canOpenURL(URL(string: "tailscale://")!)` and fall back to the App Store link (`https://apps.apple.com/us/app/tailscale/id1470499037`) or plain instructions. The specific deep-link paths ("devices, exit nodes, settings panels") are undocumented — do not guess them.

**Admin console URLs** (useful for a "manage devices" escape hatch):

- `https://login.tailscale.com/admin` — root
- `https://login.tailscale.com/admin/machines` — device list
- `https://login.tailscale.com/admin/machines/<tailscale-ip>` — a specific device, e.g. `.../machines/100.64.0.2`
- `https://login.tailscale.com/admin/settings/general` — where the **Tailnet ID** lives
- `https://login.tailscale.com/admin/settings/keys` — API access tokens / trust credentials
- `https://console.tailscale.com/admin/machines` also resolves

### 1.8 Rate limits and caching

Tailscale **does not publish numeric rate limits** for `api.tailscale.com`. Searches of the docs, changelog, and status site turned up no documented requests-per-minute figure. Assume limits exist and that a 429 is possible.

Caching guidance for Vantage:

- Cache the OAuth access token for its full `expires_in` minus a 5-minute safety margin; store it in memory only, never on disk.
- Store the client secret in the **Keychain** with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and *no* iCloud sync. It is a long-lived tailnet-wide read credential. Screens requires re-linking on every device precisely because it does not sync the secret; match that behaviour.
- Cache the device list for **30–60 s** minimum. Refresh on explicit pull-to-refresh, on app foreground, and after a failed connection. Never poll the API to drive a live status indicator — use your own connection state for that.
- Implement exponential backoff with jitter on 429/5xx and surface a clear "Tailscale API unavailable" state that still lets the user connect to a remembered host by IP/FQDN.

### 1.9 Addressing: MagicDNS name vs IPv4 vs IPv6

- **`device.name` from the API is already a fully-qualified MagicDNS name** — `drews-macbook-pro-1.tail1234.ts.net`. No suffix concatenation needed. Use it directly.
- **`DNSName` from `tailscale status --json` has a trailing dot** — `"drews-macbook-pro-1.tail1234.ts.net."`. Strip it. `MagicDNSSuffix` is the bare `tail1234.ts.net`.
- **IPv4** comes from `100.64.0.0/10` (`tsaddr.CGNATRange()`), minus the ChromeOS carve-out `100.115.92.0/23`. Ours: `100.64.0.2`.
- **IPv6** comes from `fd7a:115c:a1e0::/48` (`tsaddr.TailscaleULARange()`). Ours: `fd7a:115c:a1e0::2`. Note the interface reports `prefixlen 48`, so do not infer a /128 host route from the interface config.
- **Prefer the FQDN for user-visible identity and for connecting**, because the 100.x address can change (it is stable in practice but not contractually). Keep the IP as a cached fallback for when DNS misbehaves — which on iOS it sometimes does (§2.3).

---

## 2. Host-side networking on the tailnet

### 2.1 Binding a listener to the Tailscale interface

Tailscale addresses are ordinary addresses on an ordinary `utun` device, so `NWListener` works normally. The practical approach:

- Build `NWParameters` (TCP or QUIC), then set **`parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: <100.x or fd7a:…>, port: <your port>)`**. Binding to the *address* is more robust than binding to the interface, because you can obtain the address from `tailscale status --json` (`TailscaleIPs`) without needing an `NWInterface` instance (which has no public initializer).
- If you do want interface-level restriction, get the `NWInterface` from an `NWPathMonitor` update and set `parameters.requiredInterface`. Do **not** try to match on the name `utun16` — that index is assigned at connect time and changed on this machine across Tailscale restarts; there were 18 utun devices present, only one of which was Tailscale's.
- `prohibitedInterfaceTypes` is not useful here: Tailscale's utun reports as `.other`, as do other VPNs.

**Re-binding.** The listener must be torn down and re-created when the Tailscale address changes. Trigger on:
- `NWPathMonitor` path updates,
- `NWListener.stateUpdateHandler` entering `.failed`,
- a periodic (~10 s) comparison of the bound address against `tailscale status --json → TailscaleIPs`.

Use a small debounce (~500 ms) — Tailscale reconnects produce a burst of path changes, and the tunnel address may briefly disappear before reappearing.

**Accept-time validation (non-negotiable).** Regardless of how the bind is configured, on every accepted connection:

1. Extract the remote address from `NWConnection.currentPath?.remoteEndpoint` (or `endpoint`).
2. Reject unless it is in `100.64.0.0/10` (and not in `100.115.92.0/23`) or `fd7a:115c:a1e0::/48`.
3. Run `tailscale whois` / LocalAPI whois on it and check the resulting `Node.StableID` against your allowlist (§1.6).
4. Only then start your protocol handshake.

Also set the Tailscale client preference **"Allow incoming connections"** expectations correctly: if the user has `ShieldsUp` enabled (visible in `/localapi/v0/prefs` as `ShieldsUp`, and reflected in `blocksIncomingConnections` in the API), *all* inbound tailnet connections to that host are dropped. Detect this and tell the user, because it produces a silent connection timeout that looks like a Vantage bug.

### 2.2 Direct vs DERP vs peer relay

**Reading the current path for a peer** from `tailscale status --json`:

| Condition | Path |
| --- | --- |
| `CurAddr != ""` | **Direct** UDP to that `ip:port`. |
| `CurAddr == ""` and `PeerRelay != ""` | **Peer relay**, value is `ip:port:vni`. |
| `CurAddr == ""` and `Relay != ""` | **DERP**, value is a region code (`"dfw"` here). |
| all empty | No active path yet (nothing sent). Our `Self.Relay` is `"dfw"` even with `CurAddr` empty, because that's the *home* DERP, not an active relay — only interpret `Relay` for **peers**, and only when `CurAddr` is empty. |

CLI text form (`tailscale status` without `--json`) prints `direct 140.82.13.138:41641`, `relay "tor"`, or `peer-relay`, plus `active`/`idle`/`-` and tx/rx byte counts.

**`tailscale ping`** — verified behaviour on this machine:

```
$ tailscale ping -c 2 --timeout 3s 100.64.0.3
ping "100.64.0.3" timed out
ping "100.64.0.3" timed out
2026/09/21 20:24:27 no reply

$ tailscale ping -c 1 --timeout 3s family-iphone
2026/09/21 20:24:29 peer's node key has expired
```

Per Tailscale docs, a successful ping reports `via DERP(<region>)` for the first packets and then the direct UDP endpoint once hole-punching completes; a peer-relay path reports `via peer-relay` with `ip:port:vni` and concludes "direct connection not established". **`tailscale ping` is the correct way to force path establishment before measuring** — a cold peer will show no `CurAddr` simply because no packets have flowed.

**Peer relays.** Introduced in client **1.86**, GA **2026-02-18**. Enabled per-device with `tailscale set --relay-server-port=40000` (any UDP port, must be reachable from other tailnet devices); disable with `--relay-server-port=""`. **Any OS except iOS, Apple TV, and Android can act as a relay**; all platforms including iOS can *use* one. Tailscale tries peer relays before falling back to DERP. Relevant to Vantage only as a user-side remedy: if the iPad and Mac cannot go direct, suggesting the user turn a always-on home device into a peer relay is a real fix that beats DERP.

**MTU.** Verified on the host:

```
utun16: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280
	inet 100.64.0.2 --> 100.64.0.2 netmask 0xffffffff
	inet6 fd7a:115c:a1e0::2 prefixlen 48
```

Tailscale standardises on **MTU 1280** (the IPv6 minimum) so that the encapsulated packet fits through essentially any path. Consequences:

- **TCP:** MSS = 1280 − 40 = **1240** over IPv4, 1280 − 60 = **1220** over IPv6. The stack derives this automatically from the interface MTU on the same host, so a listener bound to the Tailscale address gets the right MSS without clamping. You only need explicit MSS clamping when routing *through* a subnet router.
- **UDP / QUIC:** size datagrams so that the IP packet stays ≤ 1280. That means a QUIC max_datagram_frame payload of roughly **1200 bytes** (1280 − 40 IPv6 header − 8 UDP − ~20–30 QUIC/DATAGRAM overhead), which is conveniently also QUIC's own conservative default. Do **not** enable any path-MTU-discovery probing above 1280; it will just cost you RTTs. Tell your video encoder/packetiser the MTU explicitly rather than letting it assume 1500 — an assumed 1500 produces IP fragmentation or silent drops.
- If you ever tunnel over an exit node or subnet router, the effective MTU can be lower still. Treat 1280 as a ceiling, not a guarantee.

### 2.3 Performance realities

**macOS host (userspace WireGuard on utun).** The GUI variants run WireGuard in userspace inside a Network/System Extension and push packets through a `utun` device, so every packet crosses the kernel boundary twice. Tailscale's own performance guidance states they target "10Gb/s and beyond" via transport-layer offload work in `wireguard-go`, and the interface here does advertise `TSO4,TSO6,CHANNEL_IO,PARTIAL_CSUM` offloads. In practice a modern Apple-silicon Mac will not be the bottleneck for a screen-share stream; expect hundreds of Mbit/s to low Gbit/s on a direct path, with a CPU cost. The documented Linux-only `ethtool rx-udp-gro-forwarding` tuning does not apply to macOS.

**iPad client (Network Extension) — this is the real constraint.** iOS runs VPNs as a Network Extension with a hard memory cap; Tailscale engineers have described it as roughly **15 MB** (vs ~5 GB for a normal app), and the cap has driven features like HTTP/2 and UPnP support to be left out of the iOS client entirely. Known consequences, from Tailscale's own issue tracker:

- **tailscale/tailscale#21355** — "iOS client tears down the tunnel during large uploads; macOS client on the same network and same upload does not." Reports show the extension at **32.0–32.5 MB** during large transfers, well past the limit, at which point iOS kills it and the VPN drops.
- **tailscale/tailscale#2566** — historical NE crashes.
- Recent releases have reduced memory on large tailnets and fixed an OOM triggered by high netmap-response rates, so the situation is better than it was — but the architectural ceiling is unchanged.

**Design implications for Vantage:**

- Treat a mid-stream tunnel drop as an expected event, not an exception. Implement fast reconnect with session resumption; do not make the user re-authenticate.
- Prefer a **steady, moderate bitrate over bursty high-bitrate**. Large bursts are what drive NE buffer growth. Cap at something like 8–15 Mbit/s for 1080p-class screen content and use an adaptive controller rather than a fixed high ceiling.
- Avoid large in-flight windows. A deep TCP send buffer full of video is memory pressure on the NE.
- Report the path type in the UI. A DERP-relayed session should visibly degrade quality targets — DERP has, in Tailscale's words, "limited quality of service characteristics."
- Test specifically for the failure mode "tunnel drops after N minutes of sustained streaming." It will not show up in short tests.

**MagicDNS from a third-party iOS app.** The mechanism is sound: when "Use Tailscale DNS settings" is enabled, the Tailscale NE installs a DNS configuration pointing at `100.100.100.100` / `fd7a:115c:a1e0::53` with the tailnet as a search domain, which is system-wide and applies to `getaddrinfo` in any app. On macOS this is verifiable — `scutil --dns` shows:

```
resolver #1
  search domain[0] : tail1234.ts.net
  nameserver[0] : 100.100.100.100
  nameserver[1] : fd7a:115c:a1e0::53
  if_index : 46 (utun16)
  flags : Supplemental, Request A records, Request AAAA records
```

**But do not rely on it on iOS.** There is a documented pattern of third-party iOS apps failing to resolve `host.tailnet.ts.net` — the query goes to the OS resolver, misses Tailscale's, and returns NXDOMAIN or a stale LAN address (tailscale/tailscale#13799 and related). The community workaround is exactly what Vantage should do automatically:

> **Resolve the FQDN, but always keep the 100.x address as a fallback, and connect by IP if resolution fails or returns a non-Tailscale address.**

Concretely: if `getaddrinfo("host.tail1234.ts.net")` returns anything outside `100.64.0.0/10` / `fd7a:115c:a1e0::/48`, discard it and use the cached tailnet IP. This single check eliminates the entire class of "connects to the wrong machine on a hotel LAN" bugs.

### 2.4 ACLs / grants to restrict the host port

Tailscale is deny-by-default at the tailnet level, so you should tell users to narrow access rather than rely on app-level auth alone. Grants (the modern syntax; ACLs are the legacy equivalent) live in the tailnet policy file as HuJSON.

General shape:

```jsonc
{
  "grants": [
    {
      "src":        ["<sources>"],
      "dst":        ["<destinations>"],
      "ip":         ["tcp:PORT", "udp:PORT"],   // network-layer permissions
      "app":        { "<cap-uri>": [ { /* params */ } ] },  // app-layer permissions
      "srcPosture": ["<posture conditions>"],
      "via":        ["<routing devices>"]
    }
  ]
}
```

Only `src` and `dst` are required, plus at least one of `ip` or `app`. All values are arrays except `app`, which is a map.

A minimal policy for a personal Vantage setup — only this user's own devices may reach the Vantage port on their own Mac, and nothing else is opened:

```jsonc
{
  "hosts": {
    "vantage-host": "100.64.0.2"
  },
  "grants": [
    {
      // Everything else stays deny-by-default.
      "src": ["autogroup:self"],
      "dst": ["autogroup:self"],
      "ip":  ["tcp:7443"]
    }
  ]
}
```

`autogroup:self` means "a user's own devices from their own devices" — the right primitive for a single-user remote-desktop app. For a named-user variant:

```jsonc
{
  "grants": [
    {
      "src": ["you@example.com"],
      "dst": ["vantage-host"],
      "ip":  ["tcp:7443"]
    }
  ]
}
```

Destinations can be a host alias from the `hosts` block, a bare IP or CIDR, a `tag:` selector, a user, or an autogroup. Sources may additionally be filtered with `srcPosture`.

**Application-layer grants are the elegant option worth considering.** Because `whois` returns the peer's `CapMap`, you can define a Vantage-specific capability URI and have Tailscale's policy file carry per-peer authorization that your host app simply reads:

```jsonc
{
  "grants": [
    {
      "src": ["autogroup:self"],
      "dst": ["vantage-host"],
      "ip":  ["tcp:7443"],
      "app": {
        "vantage.app/cap/remote-desktop": [
          { "displays": ["*"], "input": true, "clipboard": true }
        ]
      }
    },
    {
      "src": ["viewer@example.com"],
      "dst": ["vantage-host"],
      "ip":  ["tcp:7443"],
      "app": {
        "vantage.app/cap/remote-desktop": [
          { "displays": ["*"], "input": false, "clipboard": false }
        ]
      }
    }
  ]
}
```

The host then does `whois(peerAddr)` → read `CapMap["vantage.app/cap/remote-desktop"]` → decode the JSON payload → apply view-only vs full-control. This gives users a real, centrally-managed permission model for free, with no Vantage account system. Verified that `CapMap` is populated in both `status --json` and `whois --json` output on 1.102.4.

**`tailscale serve` is not applicable.** `serve` proxies HTTP(S)/TCP through the Tailscale daemon's own listener with TLS termination using tailnet certs. It adds a hop, is oriented at web services, and would force your stream through the daemon. Vantage should own its own socket on the tailnet address. (Likewise `funnel`, which exposes to the public internet — explicitly the opposite of this app's threat model.)

---

## 3. Unattended access

### 3.1 The three macOS variants

| | **Standalone** (`macsys`) | **Mac App Store** (`macos`) | **Open-source `tailscaled`** |
| --- | --- | --- | --- |
| Bundle ID | `io.tailscale.ipn.macsys` | `io.tailscale.ipn.macos` | n/a (CLI + daemon) |
| Installed here | **yes**, `/Applications/Tailscale.app`, v1.102.4, Developer ID `W5364U7YZB` | no | no |
| Tunnel mechanism | System Extension | Network Extension | kernel `utun` directly |
| GUI | yes | yes | **no** |
| LocalAPI discovery | `/Library/Tailscale/ipnport` + `sameuserproof-<port>` (`root:admin 0640`) | `lsof` on `IPNExtension` → `~/Library/Group Containers/W5364U7YZB.io.tailscale.ipn.macos/sameuserproof-<port>-<token>` (`0666`) | unix socket |
| **Runs before user login** | **no** | **no** | **yes** |
| `tailscale ssh` (as SSH *server*) | **no** | **no** | **yes** |
| `tailscale ssh` (as CLI *client*) | yes | no (use plain `ssh`) | yes |
| Screen Time web filter conflict | no | **yes** | no |

Tailscale's own comparison table answers "before login" as **no / no / yes**. The open-source variant is "only recommended for unattended installs managed by experienced macOS system administrators," and is useful precisely because "it allows Tailscale to run without requiring a specific user to log in — thanks to the unique way macOS services are tied to user accounts."

The GUI variants bundle GUI, daemon, and CLI into a single binary that macOS loads in three contexts; only the open-source variant has the classic `tailscale` / `tailscaled` split.

### 3.2 Can the standalone GUI reconnect automatically after reboot?

**Partially, and only after a user logs in.** The Tailscale docs page "Keep Tailscale running when I'm not logged in to my computer" is blunt about macOS: *"On macOS, there's no ability to run as the system just yet"*, with a pointer to tailscale/tailscale#987. No workaround is offered.

What the standalone GUI *does* do reliably:

- It installs a login item and starts at login (controlled from the app's settings).
- State is persisted in `/Library/Tailscale/profile-data`, so it reconnects without re-authentication.
- Key expiry is the other failure mode. Ours: `KeyExpiry: 2027-02-16`, `tailnet.maxKeyDuration: 15552000` (180 days). A Mac that is offline past key expiry needs interactive re-auth. **Recommend the user enable "Disable key expiry" on the host device** in the admin console — this is the single highest-value unattended-access setting and it costs nothing.

So the reboot story is: power returns → macOS boots → **a user must log in** → Tailscale GUI launches → tunnel comes up. With auto-login enabled, that middle step disappears.

### 3.3 The FileVault trade-off

The honest framing for a personal MacBook:

- **FileVault on + no auto-login** (Apple's default and the secure posture): after any reboot, the Mac sits at the pre-boot FileVault screen. Tailscale is not running. Vantage is unreachable until someone is physically present. Screens' own Tailscale documentation states the same limitation: "Tailscale must run on the target computer; it launches only after login by default. Remote restarts temporarily disconnect access until someone logs in locally."
- **FileVault on + auto-login**: not possible in the normal sense. FileVault's pre-boot authentication *is* the login; enabling FileVault disables automatic login. You can get one automatic login after the FileVault unlock (macOS carries the credential through), but the unlock itself still requires a human at the keyboard.
- **FileVault off + auto-login**: the Mac boots straight to the desktop, Tailscale starts, Vantage is reachable. The disk is unencrypted at rest. For a **MacBook** — a device that gets carried around and stolen — this is a materially bad trade.
- **Open-source `tailscaled` as a system daemon**: this genuinely runs before login, but it conflicts with the GUI app (you cannot run `macos` and `macsys` simultaneously, and running `tailscaled` alongside a GUI variant means the CLI has to pick one — it prefers the GUI clients). It also loses the GUI, MagicDNS integration niceties, and the macOS VPN settings integration. Even then, on a FileVault'd Mac it cannot start before the data volume is unlocked.

**macOS 26 SSH-over-FileVault does not rescue this, for the reason you suspected.** macOS 26 "Tahoe" added the ability to authenticate over SSH at the pre-boot stage and unlock the data volume remotely (`apple_ssh_and_filevault(7)`; requires Remote Login enabled). But at that stage only the base networking stack is up — **the Tailscale VPN cannot be running, because it lives in a System/Network Extension on the encrypted data volume.** So you need reachability to the Mac *without* Tailscale to use it: same LAN, or a Tailscale **subnet router** on another always-on device at that location advertising the Mac's LAN subnet. (That combination is exactly what people are demonstrating in the wild.) Reports also note Ethernet worked reliably while Wi-Fi initially did not, though Wi-Fi reportedly improved around 26.5.

**Practical recommendation for a personal MacBook:**

1. Keep **FileVault on**. Do not trade disk encryption on a portable machine for remote-access convenience.
2. In the Tailscale admin console, **disable key expiry** for the host Mac.
3. Enable **"Start on login"** in the Tailscale app and **"Prevent sleeping"** / configure `pmset` so the Mac stays reachable while logged in.
4. Have Vantage **detect and clearly explain** the post-reboot state rather than showing a generic timeout: "Your Mac restarted. Tailscale starts after someone logs in — log in on the Mac to restore access."
5. Document the two escape hatches for users who need true unattended access: (a) a cheap always-on device at home running Tailscale as a subnet router, plus macOS 26 SSH FileVault unlock; or (b) the open-source `tailscaled` system daemon with FileVault disabled, on a *desktop* Mac only.
6. Do not build any of this into Vantage. It is documentation, not product.

### 3.4 Tailscale SSH on macOS GUI variants — confirmed not supported

> "This functionality is only available on Linux devices and macOS devices running our open source Tailscale + tailscaled CLI. This means that some features … won't work for Windows devices, iOS/Android devices, or macOS devices running the App Store or Standalone variant of the macOS app."

Consistent with the local machine: `/localapi/v0/prefs` shows `RunSSH` present but the quad100 payload reports `"RunningSSHServer": false` and `"Features": {… "ssh": false …}`, and `Self.Capabilities` includes `https://tailscale.com/cap/ssh` (the tailnet *permits* it) while the client cannot serve it. Vantage must not depend on Tailscale SSH for anything on the host.

---

## Open questions / verify locally

1. **Does `http://100.100.100.100/api/data` respond on iPadOS 27 from a third-party app?** Highest-value unknown. Tailscale's web-interface doc scopes the feature to "desktop platforms" while other text implies iOS inclusion, and the rich JSON we saw is served by the closed-source Apple client, not the OSS stub handler. Test on a real iPad with a trivial `URLSession` GET and a 2 s timeout. If it works, it is a free Tailscale-liveness + tailnet-suffix probe; if not, fall back to `getifaddrs`.
2. **Is `tailscale://` registered by the iOS app?** Confirmed registered on macOS 1.102.4 via `CFBundleURLTypes`. The 1.102.1 changelog entry is macOS-scoped, and FR #14679 (iOS deep linking) is still open. Check `canOpenURL` on device; also check whether `io.tailscale.ipn.macos` works as a scheme on iOS.
3. **Undocumented `tailscale://` paths.** "Devices, exit nodes, and settings panels" is all the changelog says. Sniff the macOS app's URL handling (`strings` on the binary, or `open "tailscale://..."` experiments) if a specific deep link would meaningfully improve onboarding. Do not ship a guessed path.
4. **Does the OAuth *client secret* work directly as a bearer token for `GET /api/v2/tailnet/-/devices`?** Screens' instructions imply yes ("You will not need the Client ID"). Verify with a scratch `devices:core:read` credential before relying on it; implement the proper token exchange regardless.
5. **Does `?fields=all` still gate the same three fields?** The Go client says `enabledRoutes`, `advertisedRoutes`, `clientConnectivity`. Confirm `connectedToControl` is present in the *default* field set, since it is the online indicator. The interactive API reference at `https://tailscale.com/api` is a client-rendered Next.js app and could not be scraped; check it in a browser, or just diff a live `fields=default` vs `fields=all` response.
6. **Actual `api.tailscale.com` rate limits.** Undocumented. Empirically probe, or simply never exceed ~1 request/30 s in steady state.
7. **iPad sustained-throughput ceiling.** Run a 30-minute sustained transfer at your target bitrate over both a direct path and a forced-DERP path, watching for NE teardown. This is the single most likely source of "it works in testing, fails in real use."
8. **Does MagicDNS resolve from inside a third-party iPadOS app on 27?** Test `getaddrinfo` / `NWEndpoint.hostPort(host: "drews-macbook-pro-1.tail1234.ts.net", …)` directly. Implement the IP-fallback path regardless of the result.
9. **`whois` behaviour for a connection arriving via a subnet router.** Confirm it reports the router node, and decide policy. Hard to test without a second site; reason about it and pin `StableID`s defensively.
10. **App Store variant LocalAPI on a machine that has it installed.** All App Store paths in §1.4 come from `safesocket_darwin.go`, not from observation — this Mac runs the standalone variant and has no Tailscale group container. If Vantage ever talks to LocalAPI directly, test against both variants.
11. **Does `Self.Relay` ever mislead?** Ours is `"dfw"` with `CurAddr: ""` and `RxBytes: 0` — that is the home DERP region, not an active relay. Make sure the path-type classifier only runs against `Peer[]` entries with nonzero traffic.

---

## Sources

**Tailscale docs**
- API overview / auth — https://tailscale.com/docs/reference/tailscale-api
- Interactive API reference — https://tailscale.com/api (client-rendered; not scrapable)
- OAuth clients — https://tailscale.com/docs/features/oauth-clients
- OAuth on Tailscale — https://tailscale.com/docs/oauth
- Trust credentials (scope list, legacy mapping) — https://tailscale.com/docs/reference/trust-credentials
- Tailnets API — https://tailscale.com/docs/features/tailnets-api
- Exporting a list of tailnet devices — https://tailscale.com/docs/features/access-control/device-management/how-to/export-list
- Connection types (direct / DERP / peer-relay) — https://tailscale.com/docs/reference/connection-types
- Tailscale Peer Relays — https://tailscale.com/docs/features/peer-relay
- Device connectivity — https://tailscale.com/docs/reference/device-connectivity
- Performance best practices — https://tailscale.com/docs/reference/best-practices/performance
- Poor performance between tailnet devices — https://tailscale.com/docs/reference/troubleshooting/poor-performance-tailnet
- Troubleshoot TCP connection issues (MTU 1280) — https://tailscale.com/docs/reference/troubleshooting/network-configuration/tcp-connection-two-devices
- Site-to-site networking (MSS clamping) — https://tailscale.com/docs/features/site-to-site
- Manage devices using the web interface (quad100) — https://tailscale.com/docs/features/client/device-web-interface
- Grants syntax — https://tailscale.com/docs/reference/syntax/grants
- Grant examples — https://tailscale.com/docs/reference/examples/grants
- Manage permissions using ACLs — https://tailscale.com/docs/features/access-control/acls
- Tailnet policy file syntax — https://tailscale.com/docs/reference/syntax/policy-file
- Three ways to run Tailscale on macOS — https://tailscale.com/docs/concepts/macos-variants
- Install Tailscale on macOS — https://tailscale.com/docs/install/mac
- Authorizing the Tailscale system extension on macOS — https://tailscale.com/docs/concepts/macos-sysext
- Keep Tailscale running when I'm not logged in — https://tailscale.com/docs/how-to/run-unattended
- tailscaled daemon — https://tailscale.com/docs/reference/tailscaled
- Tailscale SSH — https://tailscale.com/docs/features/tailscale-ssh
- Tailscale CLI — https://tailscale.com/docs/reference/tailscale-cli
- DNS in Tailscale — https://tailscale.com/docs/reference/dns-in-tailscale
- MagicDNS — https://tailscale.com/docs/features/magicdns
- Machine names — https://tailscale.com/docs/concepts/machine-names
- Manage client preferences — https://tailscale.com/docs/features/client/manage-preferences
- Install Tailscale on iOS — https://tailscale.com/docs/install/ios
- Changelog — https://tailscale.com/changelog
- Status incident: Devices API change impact — https://status.tailscale.com/incidents/01K76ZVEFT538NWXK0XJFKT2HD

**Tailscale source (github.com/tailscale/tailscale, main)**
- `safesocket/safesocket_darwin.go` — https://raw.githubusercontent.com/tailscale/tailscale/main/safesocket/safesocket_darwin.go
- `net/tsaddr/tsaddr.go` — https://raw.githubusercontent.com/tailscale/tailscale/main/net/tsaddr/tsaddr.go
- `ipn/ipnstate/ipnstate.go` (`PeerStatus`) — https://raw.githubusercontent.com/tailscale/tailscale/main/ipn/ipnstate/ipnstate.go
- `ipn/ipnlocal/local.go` (quad100 handler, route install, port intercept) — https://raw.githubusercontent.com/tailscale/tailscale/main/ipn/ipnlocal/local.go
- `client/web/web.go` (`/api/data`, `authorizeRequest`, `serveGetNodeData`) — https://raw.githubusercontent.com/tailscale/tailscale/main/client/web/web.go
- `client/tailscale/devices.go` (Device JSON tags, `DeviceFieldsOpts`) — https://raw.githubusercontent.com/tailscale/tailscale/main/client/tailscale/devices.go
- `tailscale.com/client/tailscale/v2` (v2 Device incl. `connectedToControl`) — https://pkg.go.dev/tailscale.com/client/tailscale/v2
- `tailscale.com/client/local` (LocalClient, WhoIsResponse) — https://pkg.go.dev/tailscale.com/client/local
- `tailscale.com/ipn/localapi` — https://pkg.go.dev/tailscale.com/ipn/localapi
- `tailscale.com/net/tsaddr` — https://pkg.go.dev/tailscale.com/net/tsaddr

**Tailscale issues / PRs**
- #21355 iOS client tears down tunnel during large uploads — https://github.com/tailscale/tailscale/issues/21355
- #2566 iOS Network Extension crashes — https://github.com/tailscale/tailscale/issues/2566
- #13799 iOS MagicDNS hostname detection not working — https://github.com/tailscale/tailscale/issues/13799
- #14679 FR: custom URL scheme / deep linking for iOS — https://github.com/tailscale/tailscale/issues/14679
- #987 macOS: run before login — referenced from the run-unattended doc
- #7209 FR: API device connection status — https://github.com/tailscale/tailscale/issues/7209
- #4526 safesocket: fix CLI on standalone mac GUI build — https://github.com/tailscale/tailscale/pull/4526
- #3063 safesocket: warn against sudo on macOS — https://github.com/tailscale/tailscale/issues/3063
- #1066 support specifying which local interfaces to bind to — https://github.com/tailscale/tailscale/issues/1066
- #10680 net/interfaces: handle iOS network transitions (NWPathMonitor / utun) — https://github.com/tailscale/tailscale/pull/10680

**Tailscale blog**
- Peer Relays GA — https://tailscale.com/blog/peer-relays-ga
- Peer Relays beta — https://tailscale.com/blog/peer-relays-beta
- Manage network and application access with Grants — https://tailscale.com/blog/acl-grants
- Grants generally available — https://tailscale.com/blog/grants-ga
- OAuth support for the Tailscale API — https://tailscale.com/blog/oauth
- Roll out Tailscale as a standalone macOS app — https://tailscale.com/blog/standalone-macos
- Hey linker, can you spare a meg? (NE memory) — https://tailscale.com/blog/go-linker
- Improving Tailscale performance — https://tailscale.com/blog/throughput-improvements
- Reimagining Tailscale for iOS — https://tailscale.com/blog/reimagining-tailscale-for-ios

**Screens 5 (Edovia)**
- Connect from anywhere with Screens 5 and Tailscale — https://support.edovia.com/en/screens-5/connecting-anywhere/tailscale

**macOS 26 FileVault over SSH**
- `apple_ssh_and_filevault(7)` — https://keith.github.io/xcode-man-pages/apple_ssh_and_filevault.7.html
- Unlocking FileVault via SSH on macOS Tahoe (Der Flounder) — https://derflounder.wordpress.com/2025/10/11/unlocking-filevault-via-ssh-on-macos-tahoe/
- You can finally manage Macs with FileVault remotely in Tahoe (Jeff Geerling) — https://www.jeffgeerling.com/blog/2025/you-can-finally-manage-macs-filevault-remotely-tahoe/

**Apple**
- Binding a connection to a specific interface/utun (Developer Forums) — https://developer.apple.com/forums/thread/729316
- Restricting NWListener service advertisement — https://developer.apple.com/forums/thread/123175

---

## Appendix: verbatim output of local verification commands

All commands were read-only. No Tailscale settings were changed; `tailscale up`/`down`/`set` were never invoked.

```
$ /usr/local/bin/tailscale version
1.102.4
  tailscale commit: 3caf7d9e7dcaba589cfc58beda596929733e4fea
  long version: 1.102.4-t3caf7d9e7-g084ee3b64
  other commit: 084ee3b64537a1276e56fc38cdf0a711da9f4936
  go version: go1.26.6 (tailscale/go 7275f792d4)

$ /usr/local/bin/tailscale status --json | head
{
  "Version": "1.102.4-t3caf7d9e7-g084ee3b64",
  "TUN": true,
  "BackendState": "Running",
  "HaveNodeKey": true,
  "AuthURL": "",
  "TailscaleIPs": ["100.64.0.2", "fd7a:115c:a1e0::2"],
  "Self": { "ID": "nABC123CNTRL", "NodeID": 6543210987654321, ...

  Self.HostName      = "Drew's MacBook Pro"
  Self.DNSName       = "drews-macbook-pro-1.tail1234.ts.net."
  Self.OS            = "macOS"
  Self.Relay         = "dfw"          (home DERP; CurAddr is "")
  Self.Online        = true
  Self.PeerAPIURL    = ["http://100.64.0.2:34330",
                        "http://[fd7a:115c:a1e0::2]:36138"]
  Self.KeyExpiry     = "2027-02-16T16:22:49Z"
  MagicDNSSuffix     = "tail1234.ts.net"
  CertDomains        = ["drews-macbook-pro-1.tail1234.ts.net"]
  CurrentTailnet     = {Name: "someone@privaterelay.appleid.com",
                        MagicDNSSuffix: "tail1234.ts.net",
                        MagicDNSEnabled: true}
  Health             = []

top-level keys: ['Version','TUN','BackendState','HaveNodeKey','AuthURL',
 'TailscaleIPs','Self','Health','MagicDNSSuffix','CurrentTailnet',
 'CertDomains','ExtraRecords','Peer','User','ClientVersion']

peer keys: ['ID','NodeID','PublicKey','HostName','DNSName','OS','UserID',
 'TailscaleIPs','AllowedIPs','Tags','Addrs','CurAddr','Relay','PeerRelay',
 'RxBytes','TxBytes','Created','LastWrite','LastSeen','LastHandshake',
 'Online','ExitNode','ExitNodeOption','Active','PeerAPIURL','TaildropTarget',
 'NoFileSharingReason','CapMap','InNetworkMap','InMagicSock','InEngine','Location']

Real (non-Mullvad) peer:
  localhost | family-iphone.tail1234.ts.net. | iOS
    online=False cur='' relay='' peerrelay='' active=False
    lastseen=2026-08-04T03:06:05.1Z
(The remaining ~60 peers are tag:mullvad-exit-node nodes in mullvad.ts.net.)
```

```
$ /usr/local/bin/tailscale whois 100.64.0.2
Machine:
  Name:          drews-macbook-pro-1.tail1234.ts.net
  ID:            nABC123CNTRL
  Addresses:     [100.64.0.2/32 fd7a:115c:a1e0::2/128]
User:
  Name:     someone@privaterelay.appleid.com
  ID:       1234567890123456

$ /usr/local/bin/tailscale whois 100.64.0.3
Machine:
  Name:           us-lax-wg-402.mullvad.ts.net
  ID:             nXYZ789CNTRL
  Addresses:      [100.64.0.3/32 fd7a:115c:a1e0::3/128]
  AllowedIPs:     [0.0.0.0/0 ::/0]
  Tags:           tag:mullvad-exit-node

$ /usr/local/bin/tailscale whois --json 100.64.0.2   (abridged)
{ "Node": { "ID": 6543210987654321, "StableID": "nABC123CNTRL",
    "Name": "drews-macbook-pro-1.tail1234.ts.net.", "User": 1234567890123456,
    "Key": "nodekey:0123abcd…", "KeyExpiry": "2027-02-16T16:22:49Z",
    "DiscoKey": "discokey:4567cdef…",
    "Addresses": ["100.64.0.2/32","fd7a:115c:a1e0::2/128"],
    "Endpoints": ["203.0.113.10:41641","192.168.1.20:41641", …],
    "Hostinfo": { "Hostname": "Drew's MacBook Pro",
      "Services": [{"Proto":"peerapi4","Port":34330},
                   {"Proto":"peerapi6","Port":36138},
                   {"Proto":"peerapi-dns-proxy","Port":1}] },
    "Created": "2026-08-20T16:22:49.344223178Z", "MachineAuthorized": true,
    "Capabilities": ["https://tailscale.com/cap/is-admin",
                     "https://tailscale.com/cap/tailnet-lock"],
    "CapMap": { … } } }
```

```
$ ls "$HOME/Library/Group Containers/" | grep -i tailscale
(no output — this Mac runs the standalone/macsys variant, which uses
 /Library/Tailscale instead of a group container.
 Unrelated but noted: group.com.edovia.screens.5 is present, i.e. Screens 5
 is installed on this machine.)

$ ls -la /Library/Tailscale/
drwxr-xr-x@ 13 root  wheel   416 Sep 16 14:02 .
-rw-------   1 root  wheel     2 Aug 20 11:21 audit-log
drwx------   5 root  wheel   160 Aug 21 04:31 certs
drwx------   3 root  wheel    96 Aug 20 11:22 files
drwxr-xr-x@  2 root  wheel    64 Aug 20 11:21 incoming-files
-rw-------   1 root  wheel     0 Sep 21 20:09 ipn.log..log1.txt
-rw-------   1 root  wheel     0 Sep 21 20:00 ipn.log..log2.txt
lrwxr-xr-x@  1 root  wheel     5 Sep 16 14:02 ipnport -> 60091
drwx------   3 root  wheel    96 Aug 20 11:22 profile-data
-rw-r-----@  1 root  admin    21 Sep 16 14:02 sameuserproof-60091
-rw-------   1 root  wheel     0 Aug 20 11:21 sockstats.log1.txt
-rw-------   1 root  wheel     0 Aug 20 11:21 sockstats.log2.txt

$ cat /Library/Tailscale/ipnport
cat: /Library/Tailscale/ipnport: No such file or directory   # dangling symlink
$ readlink /Library/Tailscale/ipnport
60091
$ head -c 8 /Library/Tailscale/sameuserproof-60091
23f818e7          # 20 hex chars + newline = 21 bytes; readable because I'm in group "admin"
$ id -Gn | grep -o admin
admin
$ netstat -an -p tcp | grep 60091
tcp4  127.0.0.1.60091  127.0.0.1.59242  ESTABLISHED   # loopback only, IPv4 only
```

```
$ TOK=$(cat /Library/Tailscale/sameuserproof-60091)
$ curl -s -u ":$TOK" http://127.0.0.1:60091/localapi/v0/status | head
{
	"Version": "1.102.4-t3caf7d9e7-g084ee3b64",
	"TUN": true,
	"BackendState": "Running",
	...

LocalAPI endpoint probe (GET, with auth):
200  /localapi/v0/status        200  /localapi/v0/prefs
200  /localapi/v0/dns-osconfig  200  /localapi/v0/metrics
200  /localapi/v0/derpmap       200  /localapi/v0/tka/status
200  /localapi/v0/profiles/current   200  /localapi/v0/files/
400  /localapi/v0/whois  (400 = missing ?addr; 200 with it)
400  /localapi/v0/ping   400  /localapi/v0/debug-portmap
405  /localapi/v0/bugreport     405  /localapi/v0/upload-client-metrics
404  /localapi/v0/netmap  404  /localapi/v0/pprof
404  /localapi/v0/debug/peer-endpoint-changes

$ curl -s -u ":$TOK" "http://127.0.0.1:60091/localapi/v0/whois?addr=100.64.0.2:1234"
{ "Node": { "ID": 6543210987654321, "StableID": "nABC123CNTRL", … } }   # 200 OK
```

```
$ curl -s --max-time 3 http://100.100.100.100/api/data
{"ID":"nABC123CNTRL","Status":"Running","DeviceName":"drews-macbook-pro-1",
"TailnetName":"tail1234.ts.net","DomainName":"Drew's Network",
"IPv4":"100.64.0.2","IPv6":"fd7a:115c:a1e0::2","OS":"macOS",
"IPNVersion":"1.102.4","Profile":{"ID":1234567890123456,
"LoginName":"someone@privaterelay.appleid.com","DisplayName":"someone"},
"IsTagged":false,"Tags":null,"KeyExpiry":"2027-02-16T16:22:49Z","KeyExpired":false,
"TUNMode":true,"IsSynology":false,"DSMVersion":0,"IsUnraid":false,"UnraidToken":"",
"URLPrefix":"","UsingExitNode":null,"AdvertisingExitNode":false,
"AdvertisingExitNodeApproved":false,"AdvertisedRoutes":null,
"RunningSSHServer":false,"ClientVersion":{"RunningLatest":true},
"ACLAllowsAnyIncomingTraffic":true,
"ControlAdminURL":"https://login.tailscale.com/admin",
"LicensesURL":"https://tailscale.com/licenses/apple",
"Features":{"advertise-exit-node":true,"advertise-routes":true,
"auto-update":false,"ssh":false,"use-exit-node":true}}

Response headers:
  HTTP/1.1 200 OK
  Content-Type: application/json
  Content-Security-Policy: default-src 'self'; img-src * data:;
                           script-src 'self' 'sha384-CW2AYVfS14P7QHZN27thEkMLKiCj3YNURPoLc1elwiEkMVHeuYTWkJOEki1F3nZc'
  Cross-Origin-Resource-Policy: same-origin
  X-Frame-Options: DENY
  Content-Length: 962

$ curl -s -o /dev/null -w "%{http_code}" http://100.100.100.100/
200
```

```
$ ifconfig | grep -E "^utun|inet 100\.|inet6 fd7a"
utun0  … mtu 1380      utun1  … mtu 2000     utun2  … mtu 1000
utun3  … mtu 1500      utun4  … mtu 1500     utun5–utun8 … mtu 1380
utun9–utun15 … mtu 1500
utun16: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280
	inet 100.64.0.2 --> 100.64.0.2 netmask 0xffffffff
	inet6 fd7a:115c:a1e0::2 prefixlen 48
	options=6460<TSO4,TSO6,CHANNEL_IO,PARTIAL_CSUM,ZEROINVERT_CSUM>
utun17 … mtu 1380
(18 utun interfaces present; only utun16 is Tailscale. Filter by address, not name.)

$ scutil --dns | grep -B2 -A4 "ts.net"
resolver #1
  search domain[0] : tail1234.ts.net
  search domain[1] : attlocal.net
  nameserver[0] : 100.100.100.100
  nameserver[1] : fd7a:115c:a1e0::53
  if_index : 46 (utun16)
  flags    : Supplemental, Request A records, Request AAAA records
resolver #3
  domain   : tail1234.ts.net.
  nameserver[0] : 100.100.100.100
  nameserver[1] : fd7a:115c:a1e0::53
  if_index : 46 (utun16)
```

```
$ /usr/local/bin/tailscale ping -c 2 --timeout 3s 100.64.0.3
ping "100.64.0.3" timed out
ping "100.64.0.3" timed out
2026/09/21 20:24:27 no reply

$ /usr/local/bin/tailscale ping -c 1 --timeout 3s family-iphone
2026/09/21 20:24:29 peer's node key has expired
```

```
$ cat /usr/local/bin/tailscale
#!/bin/sh
/Applications/Tailscale.app/Contents/MacOS/Tailscale "$@"

$ /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" /Applications/Tailscale.app/Contents/Info.plist
io.tailscale.ipn.macsys
$ /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" /Applications/Tailscale.app/Contents/Info.plist
1.102.4
$ /usr/libexec/PlistBuddy -c "Print :CFBundleURLTypes" /Applications/Tailscale.app/Contents/Info.plist
Array {
    Dict { CFBundleTypeRole = Editor
           CFBundleURLName = io.tailscale.ipn.macsys
           CFBundleURLSchemes = Array { io.tailscale.ipn.macsys } }
    Dict { CFBundleTypeRole = Editor
           CFBundleURLName = io.tailscale.ipn.macos.urlscheme
           CFBundleURLSchemes = Array { tailscale } }
}
$ ls /Applications/Tailscale.app/Contents/MacOS/
Tailscale                      # single universal binary: GUI + daemon + CLI
$ codesign -dv --verbose=2 /Applications/Tailscale.app
Identifier=io.tailscale.ipn.macsys
Authority=Developer ID Application: Tailscale Inc. (W5364U7YZB)
TeamIdentifier=W5364U7YZB
```
