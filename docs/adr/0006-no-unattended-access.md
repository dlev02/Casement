# No unattended access; a PC's secure desktop only through an opt-in service

Casement Host runs as an ordinary app in the signed-in user's session on both Mac and Windows, so it can't sign in to a computer nobody is signed in to: the Mac's login window after a restart, FileVault's pre-boot screen, or Windows' sign-in screen. That stays out of scope on purpose. The gaps are covered where possible instead: Restart Safely, start at login, Log In with Screen Sharing through Apple's `screensharingd`, and a lock-screen banner.

**Changed 2026-11-22 (Drew's decision):** on Windows, an opt-in SYSTEM service, Casement Host Service, shows and controls the *secure desktop of a signed-in session*: administrator (UAC) prompts, the Ctrl+Alt+Del screen, the lock screen (so a device can type the PC's PIN or password), and apps that run as administrator such as Task Manager. Windows lets only a process running as SYSTEM on that desktop see or touch it, which is why AnyDesk, TeamViewer, RustDesk and Sunshine all use a service.

The shape, chosen to keep the network-facing part unprivileged:

- **Off by default.** General › Control administrator prompts and apps installs it after one UAC prompt, which only someone at the PC can answer; turning it off, or uninstalling Casement Host, removes it (service, files, key).
- **Casement Host stays the only network endpoint.** The service starts a helper as SYSTEM in the console session only while someone is signed in to it, and the helper talks only to Casement Host over a local pipe that only that session's user (and SYSTEM) can open, from the same session, from `VantageHost.exe`/`VantageHostCli.exe`. Devices still pair and authenticate with the host exactly as before.
- **The helper proves itself.** It signs the host's nonce with a key made at install (private half readable by SYSTEM and administrators only, public half in Program Files), so a program that takes the pipe's name first gets nothing, not even keys typed at the lock screen.
- **It lives in Program Files,** which only administrators can change, so a program running as the user can't swap the file a SYSTEM service runs. It replaces the old elevated launch task, which ran an exe from a user-writable folder and let any program running as the user gain administrator rights silently.

Accepted cost: a program already running as the user could pose as Casement Host to the helper and answer an administrator prompt. Microsoft doesn't treat UAC as a security boundary, but this is weaker than without the service, which is why it's opt-in and says so where it's turned on. The Mac keeps its own route (Screen Sharing); a Mac privileged helper still needs a decision of its own. See `docs/guide/windows-host.md` (Casement Host Service) and `SECURITY.md`.
