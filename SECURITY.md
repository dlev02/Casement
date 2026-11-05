# Security

Casement controls computers, so security reports matter more than most bugs. Thank you for taking the time.

## Reporting a vulnerability

Please **don't open a public issue** for a security problem. Report it privately through [GitHub's private vulnerability reporting](https://github.com/dlev02/Casement/security/advisories/new). Include what you found, how to reproduce it, and which versions and platforms it affects.

You'll get a reply as soon as I can, usually within a week. Once a fix ships, I'm glad to credit you in the release notes unless you'd rather stay anonymous.

## What's in scope

- The Casement apps and Casement Host for Mac and Windows, built from this repository or downloaded from its releases or the App Store.
- The wire protocol, pairing, and device authentication (`Packages/VantageCore`, `WindowsHost/src/Vantage.Protocol`).
- How secrets are stored: device identity keys, Tailscale keys, and saved Mac passwords.
- Casement Host's self-updater (`WindowsHost/src/Vantage.Host.Windows.Platform/Updates`).

## How Casement is meant to be secure

- **Network boundary.** Casement Host accepts connections only from Tailscale's address ranges (100.64.0.0/10 and fd7a:115c:a1e0::/48). Release builds refuse everything else, including loopback. Transport encryption comes from Tailscale's WireGuard tunnel; the Casement stream itself isn't separately encrypted.
- **Device identity.** Every client and every host has an Ed25519 key kept in the Keychain (DPAPI on Windows). The client opens each connection with a fresh nonce, the host signs it back to prove it holds the key it names, and the client refuses a host whose key isn't the one it saw on the device's first connection (Edit Device shows the fingerprint). Only then does the client sign the host's challenge, in a transcript tied to that host and to what the connection is for, so a signature can't be carried to another host or reused to open a screen session.
- **Paired devices.** A Mac keeps its list of paired devices in the Keychain, where other programs can't read it, rather than in preferences, which any program you run can rewrite.
- **Pairing.** A new device needs the six-digit code shown on the host. A code expires after 10 minutes and is destroyed after 5 wrong guesses, and each wrong guess costs the peer a second.
- **Revocation.** Removing a device in Casement Host revokes its key and closes its open connections.
- **Secrets.** Tailscale keys and Mac passwords live in the Keychain, readable only while the device is unlocked, and are never logged.
- **Updates.** Casement Host installs an update only if it's signed with the release key, whose public half is built into the app. The signature covers the version and the download's SHA-256, and only a newer version is accepted, so whoever controls the download can't substitute a file or roll a copy back to an older version. The private key isn't in this repository.

## Known limits

These are deliberate, documented trade-offs, not vulnerabilities:

- Anyone who can use an already paired, unlocked device can control the computers it's paired with. Turn on the app lock (Face ID, Touch ID, or Optic ID) in Settings › Privacy & Security.
- Type Password and Log In with Screen Sharing use the Mac's built-in Screen Sharing (Apple Remote Desktop authentication), which is only as strong as that protocol. It's used only over your tailnet or, at the login window, your home network.
- Every device on your tailnet can reach Casement Host's port unless your access rules say otherwise. Without a pairing code it can't get in, but it can use up a code that's showing with 5 wrong guesses; choose New Code on the host if one disappears. [Limit who can reach it](#limit-who-can-reach-casement-host) to stop this.
- The update signature protects the download, not a computer that's already compromised: Casement Host for Windows lives in a folder your user account can write to, so a program already running as you could change it, with or without updates.
- **Control apps running as administrator** (Windows, off by default) starts Casement Host as administrator without asking. Any program running as you could use that to get administrator rights without a prompt, so turn it on only if you need to control such apps, and turn it off when you don't.
- Casement hasn't had an independent security audit.

## Limit who can reach Casement Host

If other people have devices on your tailnet, a new tailnet's default rule lets them reach every port on your computers, including Casement Host's (TCP 47820). In the [Tailscale access controls](https://login.tailscale.com/admin/acls/file), replace the rule that allows everything with these, using your own login name, and leave the rest of the file as it is:

```jsonc
"grants": [
  // My devices reach everything.
  { "src": ["you@example.com"], "dst": ["*"], "ip": ["*"] },
  // Everyone else reaches their own devices.
  { "src": ["autogroup:member"], "dst": ["autogroup:self"], "ip": ["*"] },
  // Everyone can still use exit nodes.
  { "src": ["autogroup:member"], "dst": ["autogroup:internet"], "ip": ["*"] },
],
```
