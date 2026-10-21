# ThunderControl 0.8.26

Control your Mac mini from your MacBook's keyboard and trackpad, and view its HiDPI extended display on the MacBook over a direct Thunderbolt connection.

## Download and connect

Download **ThunderControl-0.8.26-macOS-arm64.zip** and verify it against **SHA256SUMS.txt** before expanding it. Use two Apple Silicon Macs with a dedicated Thunderbolt Bridge; display sharing requires macOS 14 or later. This is an experimental prerelease, with local validation on macOS 27.2 rather than a broad compatibility matrix.

1. Install on both Macs and connect a Thunderbolt cable.
2. Set the MacBook to **Sender** and the mini to **Receiver**. On the MacBook, choose the mini, click **Connect** and complete PIN confirmation on the mini.
3. Once input connects, click **Receive Screen** on the MacBook and **Send Extended Display** on the mini. Allow the requested macOS permissions.

See the [setup guide](../README.md#connect-your-macs) or [한국어 안내](../README.ko.md#두-mac-연결하기) for permissions and troubleshooting.

## In this release

- Developer ID-signed and Apple-notarized download, with the approval ticket attached.
- English and Korean UI, selected through macOS app-language settings.
- The same input and display behavior as v0.8.25, including 2x HiDPI support, saved display placement and native full screen. This release does not introduce new encoder tuning.

When upgrading, quit the old app before replacing it and keep it as a fallback. Do not reset pairing, Keychain or permissions. The installed app is not replaced automatically.

## Keep control

**Control+Option+Escape** stops remote input. **Stop Screen Sharing** ends video separately. Check the app's status and resume explicitly after a safety stop; keep a local keyboard available.

## Known limits

Actual two-Mac latency, native Mission Control gestures and broad macOS compatibility remain unverified. Frame rate and image quality are not guaranteed. Some display and system-gesture features use undocumented macOS interfaces and may break after OS updates. Notarization is not App Store review or an independent security audit. Keep Gatekeeper and SIP enabled.

[Verification scope](VERIFICATION.md) | [Signing and notarization](NOTARIZATION.md) | [Security](../SECURITY.md)

No license has been selected for original code or artwork. Third-party licenses and notices are preserved.
