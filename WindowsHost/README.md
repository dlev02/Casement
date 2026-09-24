# Vantage Host for Windows

A Windows host for the Vantage iPad/iPhone/Vision Pro client: the same wire protocol as the Mac
host (`VantageHost/`), written in C# on .NET 10 LTS. The byte-level contract is
`docs/research/windows-host-protocol.md`; when it and the Swift code disagree, the Swift code in
`Packages/VantageCore` and `VantageHost` wins.

## Layout

| Path | What | Builds on |
| --- | --- | --- |
| `src/Vantage.Protocol/` | Wire format, messages, auth, transport, file engine, input translation, and the session logic (`Host/`). No Windows APIs. | macOS, Windows |
| `src/Vantage.SyntheticHost/` | Loopback test host: the real session logic with a looping H.264 clip, an input log and an in-memory clipboard. | macOS, Windows |
| `tests/Vantage.Protocol.Tests/` | xUnit v3 tests (Microsoft.Testing.Platform). | macOS, Windows |
| `tests/golden/` | Wire vectors written by both the Swift and the C# side; each decodes the other's. | — |
| `assets/test-clip/` | The pre-encoded clip the synthetic host loops. | — |
| `src/Vantage.Host.Windows.Platform/` | Capture (Windows.Graphics.Capture), encode (Media Foundation), `SendInput`, clipboard, WTS/power, tray. | Windows (compile-only on macOS) |
| `src/Vantage.Host.Windows.Cli/`, `src/Vantage.Host.Windows/` | Console bring-up host and the WinUI 3 app. | Windows |

### Contracts between the protocol library and the platform

`src/Vantage.Protocol/Host/` defines what a platform provides; `HostEnvironment` bundles it and
`HostListener` runs everything else:

- `IScreenSource` (displays, capture start/stop, opaque `ICapturedFrame`s) and
  `IVideoEncoderFactory`/`IVideoEncoder` (frames in, `EncodedFrame` Annex-B or AVCC out through an
  `IEncodedFrameSink`). The core converts to AVCC, builds `videoConfig`, forces IDRs, skips idle
  frames, keeps one frame in flight, and runs the capture watchdog.
- `IInputSink` (wire-level input). On Windows use `Input/WindowsInputTranslator`, which needs only
  an `IInputInjector` (`SendInput`) underneath.
- `IClipboard`, `IHostStatusSource` (`HostConditions`), `IPowerControl`, `IPeerDirectory` (whois),
  `IFileStore` (receive folder, Hidden attribute, Zone.Identifier).
- `IProtectedStorage` (DPAPI on Windows) under the library's `ProtectedIdentityStore` and
  `ProtectedTrustStore`; `IEd25519` (NSec by default).

## On the Mac

The .NET 10 SDK lives in `~/.dotnet` and isn't on `PATH`:

```sh
export DOTNET_ROOT=$HOME/.dotnet PATH=$HOME/.dotnet:$PATH
cd WindowsHost
dotnet build Vantage.Windows.slnx
dotnet test --solution Vantage.Windows.slnx
```

Never run anything on port 47820 on the Mac (the real Mac host); test hosts use 47821 and up.

## On the PC (drew-pc)

One-time setup (Drew, as admin): OpenSSH Server, an SSH key in `administrators_authorized_keys`
or `~\.ssh\authorized_keys`, the .NET 10 SDK (`winget install Microsoft.DotNet.SDK.10`),
`dotnet new install Microsoft.WindowsAppSDK.WinUI.CSharp.Templates`, Developer Mode, and the
firewall rule, created **before** the first launch so Windows never makes a block rule:

```powershell
New-NetFirewallRule -DisplayName "Vantage Host (tailnet)" -Direction Inbound -Action Allow -Protocol TCP `
  -LocalPort 47820-47829 -RemoteAddress 100.64.0.0/10,fd7a:115c:a1e0::/48 -Profile Any
```

The remote loop from the Mac:

```sh
# push
tar -czf - WindowsHost | ssh you@100.64.0.20 "tar -xzf - -C C:/src/vantage"
# build
ssh you@100.64.0.20 "cd C:/src/vantage/WindowsHost; dotnet build -c Debug"
```

Run the host in Drew's **interactive** session, not the SSH one (an SSH process can't see the
console desktop):

```powershell
schtasks /Create /TN VantageDev /TR "<path>\VantageHost.exe --port 47821 --pairing-code 246810 --log-file <path>" /SC ONCE /ST 00:00 /IT /F
schtasks /Run /TN VantageDev
Get-Content $env:LOCALAPPDATA/'Vantage Host'/logs/host.log -Wait -Tail 50
```

Never test while Remote Desktop is connected: it takes the console session (`tscon` gives it back).

From the Mac, `xcrun swift test` reaches `100.64.0.20:47821` directly over Tailscale, so the
interop suite runs against the real Windows host. The simulator may not route to the tailnet; tunnel
so the peer is loopback (a DEBUG host accepts it):
`ssh -N -L 47831:127.0.0.1:47821 you@100.64.0.20`.
