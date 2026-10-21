[English](README.md) | [한국어](README.ko.md)

# <img src="docs/assets/app-icon.png" width="32" height="32" alt=""> ThunderControl

Control your Mac mini with your MacBook's keyboard and trackpad, while viewing the Mac mini's HiDPI extended display on your MacBook. Uses a dedicated, direct Thunderbolt Bridge, not Wi-Fi remote desktop.

**[Download v0.8.26 for Apple Silicon](https://github.com/2JIHAN/ThunderControl/releases/download/v0.8.26/ThunderControl-0.8.26-macOS-arm64.zip)** | [Release notes and checksums](https://github.com/2JIHAN/ThunderControl/releases/tag/v0.8.26)

> **Experimental preview:** Apple Silicon only. Video targets macOS 14+, but local testing used macOS 27.2, not a broad compatibility matrix. Developer ID signed, **not notarized or stapled**; Gatekeeper may block it. Do not disable Gatekeeper or SIP.

![Conceptual connection diagram: MacBook input travels to Mac mini; Mac mini's virtual display video travels back over Thunderbolt Bridge.](docs/assets/overview-en.svg)

*Conceptual connection diagram, not an app screenshot. Input and view-only video use separate connections.*

## What it does

- Share keyboard, pointer and scrolling across two Macs.
- Create an app-owned virtual display on Mac mini and receive its 2x HiDPI video on MacBook.
- Remember screen placement for each device pair and use native macOS full screen.
- Keep input and video separate, with pairing approval and safety stops.

## Install and connect

1. Download the ZIP, compare its SHA-256 with the release's `SHA256SUMS.txt`, and expand it. Quit older instances on both Macs before replacing `/Applications/ThunderControl.app`. Do not reset Keychain or permissions to update.
2. Connect a Thunderbolt cable, not a charging-only USB-C cable. Enable Thunderbolt Bridge on both Macs for a dedicated direct connection.
3. Open both apps. Select **Sender** on MacBook and **Receiver** on Mac mini. Allow the required role-specific permissions: Accessibility, Input Monitoring, Local Network, and Screen Recording where requested.
4. Choose the intended peer, click **Request Connection**, and follow the PIN confirmation prompts. Approve only your own request after checking the code on the Sender Mac.
5. After input connects, click **Receive Screen** on MacBook and **Send Extended Display** on Mac mini. Use **Stop Screen Sharing** to end video. **Control+Option+Escape** stops remote input; safety stops require an explicit resume. Keep a local keyboard available.

## Language

v0.8.26 (build 56) bundles native English and Korean UI. It follows the macOS app language, with English fallback. Change ThunderControl's app-specific language in macOS settings, then restart. There is no in-app language picker. See [localization](docs/LOCALIZATION.md).

## More details

[Build from source](docs/BUILDING.md) | [Verification scope](docs/VERIFICATION.md) | [Security and reporting](SECURITY.md)

No guaranteed frame rate, end-to-end latency, universal compatibility, independent audit, or verified two-Mac system gestures. Do not share PINs, pairing material or private diagnostics publicly.

## License status

No license is selected for original code or artwork; public access does not grant free redistribution. Third-party licenses remain intact: [notices](THIRD_PARTY_NOTICES.md).
