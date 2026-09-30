# Porthole Host for Windows

A Windows host for the Porthole iPad/iPhone/Vision Pro client: the same wire protocol as the Mac
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

The .NET 10 SDK lives in `~/.dotnet` and isn't on `PATH`. Always opt out of the SDK's telemetry
(`DOTNET_CLI_TELEMETRY_OPTOUT=1`; the test runner honours it too), on the PC as well:

```sh
export DOTNET_ROOT=$HOME/.dotnet PATH=$HOME/.dotnet:$PATH DOTNET_CLI_TELEMETRY_OPTOUT=1
cd WindowsHost
dotnet build Vantage.Windows.slnx
dotnet test --solution Vantage.Windows.slnx
```

Never run anything on port 47820 on the Mac (the real Mac host); test hosts use 47821 and up.

The synthetic host runs the real session logic with a looping clip, so the iPad app, the Swift
tests and the simulator can talk to it:

```sh
dotnet src/Vantage.SyntheticHost/bin/Debug/net10.0/Vantage.SyntheticHost.dll --port 47862 --pairing-code 246810 \
  [--pairing-code-rearm 3] [--display-asleep] [--capture-fails-for 6] [--send-file-on-connect PATH] \
  [--receive-folder PATH] [--input-log PATH.jsonl] [--clipboard-text TEXT] [--platform windows|macos] \
  [--state-dir PATH] [--exit-after S] [--log-input-events]
xcrun simctl launch <sim> com.benjaminlevinson.vantage -VantageAutoConnect 127.0.0.1:47862 -VantagePairingCode 246810
```

A fixed `--pairing-code` is used up by one pairing (as on the Mac); `--pairing-code-rearm S` shows
it again S seconds later. The Swift side of the proof (golden vectors, `WindowsHostInteropTests`,
`LiveHostFilesTests`, `SessionUITests`) is described in the repo's `CLAUDE.md`, "Windows host".

## On the PC (drew-pc)

One-time setup (Drew, as admin): OpenSSH Server, an SSH key in `administrators_authorized_keys`
or `~\.ssh\authorized_keys`, the .NET 10 SDK (`winget install Microsoft.DotNet.SDK.10`),
`dotnet new install Microsoft.WindowsAppSDK.WinUI.CSharp.Templates`, Developer Mode, and the
firewall rule, created **before** the first launch so Windows never makes a block rule:

```powershell
New-NetFirewallRule -DisplayName "Vantage Host (tailnet)" -Direction Inbound -Action Allow -Protocol TCP `
  -LocalPort 47820-47829 -RemoteAddress 100.64.0.0/10,fd7a:115c:a1e0::/48 -Profile Any
```

The remote loop from the Mac, with `PC` set to your SSH target (for example `export PC=you@your-pc`, the
PC's Tailscale name) and `<pc-address>` its Tailscale address:

```sh
# push
tar -czf - WindowsHost | ssh $PC "tar -xzf - -C C:/src/vantage"
# build
ssh $PC "$env:DOTNET_CLI_TELEMETRY_OPTOUT=1; cd C:/src/vantage/WindowsHost; dotnet build -c Debug"
```

Run the host in Drew's **interactive** session, not the SSH one (an SSH process can't see the
console desktop):

```powershell
schtasks /Create /TN VantageDev /TR "<path>\VantageHost.exe --port 47821 --pairing-code 246810 --log-file <path>" /SC ONCE /ST 00:00 /IT /F
schtasks /Run /TN VantageDev
Get-Content $env:LOCALAPPDATA/'Vantage Host'/logs/host.log -Wait -Tail 50
```

Never test while Remote Desktop is connected: it takes the console session (`tscon` gives it back).

From the Mac, `xcrun swift test` reaches `<pc-address>:47821` directly over Tailscale, so the
interop suite runs against the real Windows host. The simulator may not route to the tailnet; tunnel
so the peer is loopback (a DEBUG host accepts it):
`ssh -N -L 47831:127.0.0.1:47821 $PC`.

## Windows host: projects and the PC-side workflow

| Project | Output | What |
| --- | --- | --- |
| `src/Vantage.Host.Windows.Platform/` | library | WGC capture on the monitor's GPU, D3D11 BGRA→NV12, Media Foundation H.264 (hardware MFT by adapter LUID, software fallback), `SendInput`, Win32 clipboard, WTS/secure-desktop/display-power status, keep-awake, DPAPI storage, receive folder + Mark of the Web, Tailscale CLI, tray icon, start at login, and `WindowsHostRuntime` (the composition root). |
| `src/Vantage.Host.Windows.Cli/` | `VantageHostCli.exe` | The real pipeline with console logging and no UI (bring-up, SSH). Keys: P new pairing code, Q quit. |
| `src/Vantage.Host.Windows/` | `VantageHost.exe` | The WinUI 3 tray app (Windows App SDK 2.5, unpackaged, self-contained). Same flags as the CLI. |
| `tools/InputProbe/` | `InputProbe.exe` | Logs mouse/keyboard events with `injected` and `vantage` marks (the Windows `click-target.swift`). |
| `tests/Vantage.Host.Windows.Tests/` | xUnit | The pure parts (coordinates, dirty regions, DPI maths, clipboard text/DIB/PNG, tray menu, Tailscale JSON, NAL units, flags, receive folder, start at login). |

On the Mac, `dotnet build Vantage.Windows.slnx` compiles everything but the WinUI app (the
Windows projects set `EnableWindowsTargeting`), and `dotnet test --solution Vantage.Windows.slnx`
runs the Windows tests too. Export `DOTNET_CLI_TELEMETRY_OPTOUT=1 TESTINGPLATFORM_TELEMETRY_OPTOUT=1`
first; the scripts do. XAML compiles only on Windows: build the app from `Vantage.Windows.PC.slnx`.

Flags (both executables): `--port N`, `--pairing-code NNNNNN` (Debug), `--exit-after S`,
`--receive-folder PATH`, `--log-file PATH`, `--dump-h264 PATH` (append the encoded Annex-B stream),
`--platform windows|macos`, `--synthetic` (separate `Vantage Host (Synthetic)` data folder, input
logged instead of injected, in-memory clipboard, no power/lock actions), `--encoder
auto|hardware|software`, `--rate-control cbr|lowdelayvbr`, `--send-file-on-connect PATH` and
`--capture-fails-for S` (Debug), `--background`, `--verbose`. Logs default to
`%LOCALAPPDATA%\Vantage Host\logs\host.log`; `run-dev.ps1` uses `dev.log`.

### First bring-up on drew-pc

```powershell
# 0. Once, elevated, before anything listens (also removes block rules Windows may have made):
powershell -ExecutionPolicy Bypass -File C:\src\vantage\WindowsHost\scripts\firewall.ps1
```

```sh
# 1. From the Mac: copy the tree over (once first: ssh $PC "mkdir C:\src\vantage")
sh WindowsHost/scripts/push.sh
# 2. Build everything and run the Windows tests on the PC
ssh $PC "cd C:\src\vantage\WindowsHost & set DOTNET_CLI_TELEMETRY_OPTOUT=1& set TESTINGPLATFORM_TELEMETRY_OPTOUT=1& dotnet build Vantage.Windows.PC.slnx -c Debug & dotnet test --project tests\Vantage.Host.Windows.Tests"
# 3. Run the console host in Drew's interactive session for a minute, saving the encoded stream
ssh $PC "powershell -ExecutionPolicy Bypass -File C:\src\vantage\WindowsHost\scripts\run-dev.ps1 -DumpH264 C:\temp\vantage.h264 -ExitAfter 60"
# 4. Connect something so it streams: the interop suite, or the simulator through the tunnel above
VANTAGE_INTEROP_HOST=<pc-address>:47821 xcrun swift test --filter WindowsHostInteropTests
# 5. Read the log, then check the stream on the Mac
ssh $PC "powershell -Command Get-Content (Join-Path $env:LOCALAPPDATA 'Vantage Host\logs\dev.log') -Tail 80"
scp $PC:C:/temp/vantage.h264 /tmp/ && ffprobe -v error -show_streams /tmp/vantage.h264 | grep -E "profile|has_b_frames|color_|width|height"
ffprobe -v error -show_frames -select_streams v /tmp/vantage.h264 | grep -c pict_type=I   # IDRs only when asked for
ffplay /tmp/vantage.h264
```

What the log should show: `GPU: NVIDIA GeForce RTX 5070 Ti …` (the monitor's adapter, not the
AMD iGPU), `capturing … on NVIDIA …; dirty regions True, min interval True` (24H2+),
`encoder: NVIDIA H.264 Encoder MFT (hardware, async) …`, then `…: first frame N bytes, NAL types
[7,8,5]` (SPS, PPS, IDR; a 9 or 6 in front is an AUD/SEI the core drops). If the NVIDIA MFT
misbehaves, rerun with `-Encoder software` to separate encoder problems from pipeline ones.
`ffprobe` should report High profile, `has_b_frames=0`, `color_primaries=bt709`,
`color_transfer=iec61966-2-1` (or `bt709`) and `color_range=tv`.

Input: start `InputProbe.exe` (`tools\InputProbe\bin\Debug\net10.0-windows\`) at the PC (or
through a scheduled task with its output redirected to a file), then move, click, scroll, type and
send chords from the client; every event the host sends is marked `injected vantage`. Stop the
console host with `run-dev.ps1 -Stop`.

### The app

```powershell
powershell -ExecutionPolicy Bypass -File C:\src\vantage\WindowsHost\scripts\publish.ps1 -Launch
```

publishes `VantageHost.exe` self-contained into `%LOCALAPPDATA%\Programs\Vantage Host\` with a
Start menu shortcut. It listens on 47820 (Release: tailnet peers only, no fixed code). Left-click
the tray icon for the window (General shows the tailnet address and Show Pairing Code), right-click
for the menu; turn on "Start Porthole Host when I sign in" there. Closing the window keeps it in the
tray; Quit is in the tray menu and on the About page. Drew's iPad then pairs with
`<pc-address>:47820`.
