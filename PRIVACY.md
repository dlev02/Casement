# Privacy Policy

**Effective September 30, 2026**

This policy covers the Casement apps for iPhone, iPad, Apple Vision Pro, and Mac, and Casement Host for Mac and Windows (together, "Casement"). Casement is made by Drew Levinson.

## The short version

Casement doesn't collect any information about you. There is no Casement account, no Casement server, and no advertising, analytics, tracking, or third-party crash reporting. Your screen, keystrokes, clipboard, sound, and files travel directly between your own devices over your own [Tailscale](https://tailscale.com) network. Nothing is sent to the developer.

## What stays on your devices

Casement stores the following on your devices to work. None of it is sent to the developer.

**In the Casement app:**

- The computers you've added: their names, addresses, and your settings for each.
- Your preferences, such as appearance, controls, and keyboard options.
- In the Keychain: this device's identity key, used to prove to your computers that it's really this device. If you choose to add them, it also holds your Tailscale API token or OAuth client, and the account name and password for each Mac you saved one for.
- Files you receive, in the app's own folder (on iPhone and iPad, Files › On My iPhone/iPad › Casement › Received; on a Mac, your Downloads folder).

**In Casement Host:**

- The identity keys of devices you've paired, so they can reconnect without a new code.
- Your host settings.
- Files you send to the computer, saved to Downloads or the folder you choose.

Removing a device in Casement deletes the secrets saved for it. Deleting the app deletes its data, though Apple's Keychain items can outlive the app on some devices.

## What goes over the network

Casement connects only to the places below, and only when you use the matching feature.

| Where | When | What is sent |
| --- | --- | --- |
| Your own computers, over Tailscale | When you connect, check availability, transfer files, or dictate | The session itself: screen video, sound, input, clipboard content, files, and dictation audio |
| Your Mac's built-in Screen Sharing (port 5900) | Only when you use Type Password or Log In with Screen Sharing | Your saved Mac account name and password, to type them at the Mac |
| `api.tailscale.com` | Only if you add a Tailscale key, to list your tailnet's devices | Your Tailscale key. Tailscale returns your device list, which stays on your device |
| Hugging Face | Only if you turn on the built-in Parakeet dictation model in Casement Host | A download request for the model files (about 490 MB) |

Casement doesn't add its own encryption layer. It relies on Tailscale's encrypted WireGuard tunnel between your devices, and on the pairing step, where each device proves its identity with a signing key. Casement Host refuses connections from outside Tailscale's address ranges. Tailscale's handling of your data is covered by [Tailscale's privacy policy](https://tailscale.com/privacy-policy).

## Permissions

Casement asks for a permission only for the feature that needs it:

- **Microphone and Speech Recognition**, for dictation. Audio is transcribed on your device, or sent to your own computer if you choose to dictate there. It's used for that one transcript and not kept.
- **Local Network**, to reach your computers, including a Mac's home-network address if you save one.
- **Face ID or Touch ID**, if you turn on the app lock. Apple handles the check; Casement never sees your biometric data.
- **Screen Recording and Accessibility** (Casement Host on a Mac), to show your screen and move the pointer and type for you.
- **Downloads folder and Notifications** (Casement Host on a Mac), to save files you send and tell you when they arrive.
- **Automation** (Casement Host on a Mac), only for Restart Safely, which asks macOS to restart.

## iCloud

If you turn on iCloud sync in Casement's settings, your saved passwords and Tailscale key sync between your devices through iCloud Keychain, which is end-to-end encrypted by Apple. When available, your list of computers syncs through your private iCloud storage. The developer can't see any of it.

## Crash reports

Casement has no crash reporter of its own. If you've chosen to share analytics with app developers in your device's settings, Apple may pass along anonymous crash reports and usage statistics under [Apple's privacy policy](https://www.apple.com/legal/privacy/). You can turn that off in Settings › Privacy & Security › Analytics & Improvements.

## Donations

Casement is free. If you choose to support it on [Ko-fi](https://ko-fi.com/dlev384895), that happens on Ko-fi's website, under Ko-fi's privacy policy, and isn't connected to the apps in any way.

## Children

Casement isn't directed at children and collects no information from anyone, including children under 13.

## Changes

If this policy changes, the new version will be posted here with a new effective date. The full history is in this repository's commit log.

## Contact

Questions about privacy? [Open an issue on GitHub](https://github.com/dlev02/Casement/issues). For anything sensitive, such as a security problem, use [private vulnerability reporting](https://github.com/dlev02/Casement/security/advisories/new) instead.
