# Security

Casement controls computers, so security reports matter more than most bugs. Thank you for taking the time.

## Reporting a vulnerability

Please **don't open a public issue** for a security problem. Report it privately through [GitHub's private vulnerability reporting](https://github.com/dlev02/Casement/security/advisories/new). Include what you found, how to reproduce it, and which versions and platforms it affects.

You'll get a reply as soon as I can, usually within a week. Once a fix ships, I'm glad to credit you in the release notes unless you'd rather stay anonymous.

## What's in scope

- The Casement apps and Casement Host for Mac and Windows, built from this repository or downloaded from its releases or the App Store.
- The wire protocol, pairing, and device authentication (`Packages/VantageCore`, `WindowsHost/src/Vantage.Protocol`).
- How secrets are stored: device identity keys, Tailscale keys, and saved Mac passwords.

## How Casement is meant to be secure

- **Network boundary.** Casement Host accepts connections only from Tailscale's address ranges (100.64.0.0/10 and fd7a:115c:a1e0::/48). Release builds refuse everything else, including loopback. Transport encryption comes from Tailscale's WireGuard tunnel; the Casement stream itself isn't separately encrypted.
- **Device identity.** Every client has an Ed25519 key kept in the Keychain (DPAPI on Windows). The host challenges each connection with a fresh nonce, and the client signs a domain-separated transcript.
- **Pairing.** A new device needs the six-digit code shown on the host. A code expires after 10 minutes and is destroyed after 5 wrong guesses, and each wrong guess costs the peer a second.
- **Revocation.** Removing a device in Casement Host revokes its key and closes its open connections.
- **Secrets.** Tailscale keys and Mac passwords live in the Keychain, readable only while the device is unlocked, and are never logged.

## Known limits

These are deliberate, documented trade-offs, not vulnerabilities:

- Anyone who can use an already paired, unlocked device can control the computers it's paired with. Turn on the app lock (Face ID or Touch ID) in Settings › Privacy & Security.
- Type Password and Log In with Screen Sharing use the Mac's built-in Screen Sharing (Apple Remote Desktop authentication), which is only as strong as that protocol. It's used only over your tailnet or, at the login window, your home network.
- Casement hasn't had an independent security audit.
