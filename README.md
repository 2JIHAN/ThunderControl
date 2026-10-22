[English](README.md) | [한국어](README.ko.md)

# <img src="docs/assets/app-icon.png" width="32" height="32" alt=""> ThunderControl

Use your MacBook's keyboard, trackpad and screen to work on your Mac mini over a direct Thunderbolt connection.

**[Download for Apple Silicon](https://github.com/2JIHAN/ThunderControl/releases/download/v0.8.27/ThunderControl-0.8.27-macOS-arm64.zip)** | [Release notes and checksums](https://github.com/2JIHAN/ThunderControl/releases/tag/v0.8.27)

v0.8.27 (build 57) is an experimental prerelease for two Apple Silicon Macs. Display sharing requires macOS 14 or later. The full build, memory-only regression suites and strict/deep Developer ID signature validation passed. Apple notarization is blocked on credentials, so the binary release remains a draft; the links above are intended download locations, not a published download. The previous v0.8.26 release was Developer ID-signed and Apple-notarized.

![MacBook sends keyboard and pointer input to Mac mini; Mac mini sends its extended display back over Thunderbolt Bridge.](docs/assets/overview-en.svg)

*Connection diagram, not an app screenshot.*

## What you can do

- **Work on the Mac mini from your MacBook.** Share keyboard, pointer and scrolling while your apps keep running on the mini.
- **Add a HiDPI workspace.** View a virtual extended display, rather than a mirror of an existing monitor, with 2x HiDPI support and native macOS full screen.
- **Keep your screen arrangement.** The extended display's position is saved for each pair of Macs and reused on the next connection.

ThunderControl is designed for a dedicated, direct Thunderbolt Bridge between two Macs, not Wi-Fi or Internet remote access.

## Connect your Macs

1. **Install on both Macs.** Download the ZIP, verify it against `SHA256SUMS.txt` on the release page, and expand it. Quit older instances before copying the app to `/Applications`. Keep your previous app as a fallback; updating does not require resetting pairing, Keychain or permissions.
2. **Connect a Thunderbolt cable.** A USB-C connector alone is not enough. Check that Thunderbolt Bridge is configured and active in macOS Network settings on both Macs.
3. **Set the input roles.** Choose **Sender** on the MacBook and **Receiver** on the Mac mini. Allow Accessibility and Input Monitoring on both, plus Local Network access when requested. The mini listens for the connection; if listening was paused, use **Resume Listening**.
4. **Pair with your Mac mini.** On the MacBook, select the mini and click **Connect**. Follow the PIN prompt on the mini, checking the code shown on the MacBook. Approve only a connection you requested.
5. **Allow sharing to start.** For a first valid authenticated pair with no saved OFF preference, automatic input and video intent is enabled by default. Screen Recording permission on the mini and the existing safety checks are still required. If sharing needs a manual start, use **Receive Screen** on the MacBook and **Send Extended Display** on the mini. Saved OFF preferences and explicit stops are not overridden.

On the MacBook, use **Screen Layout** to align the screen positions. Move the pointer across the configured screen edge to switch between Macs.

**Sender and Receiver refer to input.** The screen travels in the opposite direction. The video window is view-only; the separate input connection controls the mini.

## Stop or recover control

- **Control+Option+Escape** stops remote input and returns control locally.
- **Stop Screen Sharing** ends video separately; it does not normally end the input connection.
- After a manual or emergency stop, check the app's status and resume explicitly. Automatic restore does not override those stops or saved OFF preferences. Keep a local keyboard available on the mini.
- Ordinary source foreground loss returns input locally while retaining authenticated transport and video. Secure Input alone no longer disconnects the session; macOS still controls protected event delivery. Lock, sleep, session, route, permission and capture checks remain in force.
- The viewer waits for confirmed native full screen before presenting video. If entry fails or times out, it presents a usable window instead.

If the mini is missing from the device list, check the cable, Thunderbolt Bridge, Local Network permission and Receiver listening state. If input connects but video does not, check Screen Recording on the mini and the screen controls on both Macs. Do not reset pairing as a first troubleshooting step.

## Before relying on it

Earlier v0.8.25/v0.8.26 local validation used macOS 27.2. For v0.8.27, standalone policy tests were reported passed; the main memory-only suite is planned, not yet successfully completed. A v0.8.27 build and physical two-Mac validation are not established. Actual two-Mac input-to-screen latency, native Mission Control gestures and broader macOS compatibility remain unverified. Frame rate and image quality are not guaranteed. See [what has and has not been tested](docs/VERIFICATION.md).

Some display and system-gesture features use undocumented macOS interfaces and may break after OS updates. Keep Gatekeeper and SIP enabled. Apple notarization is not an independent security audit.

## Guides and development

English and Korean follow the app's macOS language setting. [Change the app language](docs/LOCALIZATION.md#change-the-app-language).

[Build from source](docs/BUILDING.md) | [Verification](docs/VERIFICATION.md) | [Signing and notarization](docs/NOTARIZATION.md) | [Security and reporting](SECURITY.md)

## License

No license has been selected for original code or artwork; public access does not grant free redistribution. Third-party licenses are preserved in the [notices](THIRD_PARTY_NOTICES.md).
