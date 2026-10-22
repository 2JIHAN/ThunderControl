# ThunderControl 0.8.27 (build 57)

Experimental prerelease for two Apple Silicon Macs over a dedicated, direct Thunderbolt Bridge. Display sharing requires macOS 14 or later.

**Release status:** draft, blocked on Apple notarization credentials. The optimized arm64 build and full memory-only regression suites passed. Both executables are hardened-runtime Developer ID signed with the existing app identity; strict/deep verification passed. Gatekeeper currently reports `Unnotarized Developer ID`, not acceptance. Do not infer v0.8.27 approval from the notarized v0.8.26 release.

## Download and connect

Intended release locations: [ThunderControl-0.8.27-macOS-arm64.zip](https://github.com/2JIHAN/ThunderControl/releases/download/v0.8.27/ThunderControl-0.8.27-macOS-arm64.zip) and [release assets/checksums](https://github.com/2JIHAN/ThunderControl/releases/tag/v0.8.27). Availability is not yet verified. Once published, compare the ZIP with `SHA256SUMS.txt` before expanding it.

1. Quit older instances, then install on both Macs at the existing location, normally `/Applications`. Keep the previous app as a fallback. Do not reset pairing, Keychain or macOS permissions as a generic upgrade step.
2. Connect a Thunderbolt cable with an active Thunderbolt Bridge. Set the MacBook to **Sender** and the mini to **Receiver**. Select the mini, click **Connect**, and complete the PIN confirmation for the connection you requested.
3. Grant the requested Accessibility, Input Monitoring and Local Network permissions. A first valid authenticated pair without saved OFF intent defaults to automatic input and video. Sending the extended display still needs Screen Recording permission on the mini and all existing safety checks. If a manual start is needed, use **Receive Screen** on the MacBook and **Send Extended Display** on the mini.

See the [setup guide](../README.md#connect-your-macs) or [한국어 안내](../README.ko.md#두-mac-연결하기).

## Changes

- **Full-screen viewer startup:** the startup window stays hidden and video presentation waits for AppKit's native full-screen confirmation. A failed entry or five-second timeout exposes a usable window, without repeated automatic full-screen toggles. This is source-level behavior, not a claim of successful two-Mac testing.
- **Secure Input continuity:** Secure Input alone does not disconnect the authenticated session by default. macOS protections remain enabled and may restrict protected event delivery; ThunderControl does not bypass them.
- **Local input on source focus loss:** ordinary foreground loss cancels active remote ownership and returns input locally while retaining authenticated transport, video and saved intent. Lock, sleep and unsafe-session handling remain separate.
- **Automatic first-pair defaults and restore:** a valid live authenticated pair with no saved sharing record seeds automatic input/video intent. Existing records, including explicit OFF, are preserved. Saved intent can restore only when current authentication, route, session, input-permission and capture/topology checks allow it. Manual and emergency stops are not overridden; unreadable storage does not create permissive defaults.

## Keep control

**Control+Option+Escape** stops remote input. **Stop Screen Sharing** ends video separately and saves video OFF. Resume explicitly after a manual or emergency stop. Keep a local keyboard available on the mini. Do not disable SIP, Gatekeeper or Secure Input.

## Verification and known limits

Standalone policy tests, the complete main memory-only suite in English and Korean, helper state-machine tests, recovery mocks, ownership, desktop-map and local-socket PIN pairing integration all passed. The stripped final signed binaries passed the main/helper suites again. The helper password-field continuity, lock and unknown/malformed session-state checks passed. Native visible full-screen startup and physical two-Mac results remain unverified. Earlier v0.8.25/v0.8.26 live results are historical, not new v0.8.27 evidence.

Actual two-Mac latency, native Mission Control gestures and broad macOS compatibility remain unverified. Frame rate and image quality are not guaranteed. Some display and gesture features use undocumented macOS interfaces. Notarization, if subsequently accepted, is not an independent security audit.

[Verification scope](VERIFICATION.md) | [Signing and notarization](NOTARIZATION.md) | [Security](../SECURITY.md)

No license has been selected for original code or artwork. Third-party licenses and notices are preserved.
