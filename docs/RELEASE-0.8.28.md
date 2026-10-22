# ThunderControl 0.8.28 (build 58)

Experimental prerelease for two Apple Silicon Macs on a dedicated direct Thunderbolt Bridge. Display sharing requires macOS 14 or later.

## One checkbox for extended display

On the input **Sender** (MacBook), select **Use this Mac as a virtual display** (한국어: **현 기기를 가상 디스플레이로 사용**). The authenticated input Receiver (Mac mini) automatically creates and sends its extended display to that MacBook. The separate Extended Display tab, display IP field and manual Send/Receive Screen buttons are removed. Clear the checkbox to stop video while keeping input connected.

Both Macs need **0.8.28 or later** for this negotiated preference. Older peers retain input compatibility but do not support this automatic video request. Only the authenticated live peer route is used. Saved OFF choices, safety stops, permission/session checks and topology cleanup remain enforced. The Receiver only offers the Screen Recording permission action when it is needed.

## Check for updates

Use **Check for Updates…** in the app menu. Background checks can indicate a newer public release without interrupting work; opening the notice goes to this repository’s GitHub release page. Published prereleases are included. This is not automatic installation: no app download, bundle replacement or restart occurs.

## Install and keep control

Download **ThunderControl-0.8.28-macOS-arm64.zip** and compare it with **SHA256SUMS.txt** before expanding. Quit the previous app normally, keep a backup, and replace the entire bundle in /Applications on both Macs. Do not reset pairing, Keychain or permissions. Screen Recording is required on the Mac mini. **Control+Option+Escape** remains the emergency remote-input stop. Keep Gatekeeper, SIP and Secure Input enabled.

## Verification and limits

The optimized build, complete main memory-only regressions, helper state-machine, recovery, ownership, desktop-map and local-socket PIN fixtures passed. New preference protocol/policy tests cover 48 checks; localization covers 754 checks. Update-check policy fixtures cover160 checks, and a live anonymous GitHub metadata request passed. English and Korean AppKit offscreen hierarchy checks verified the Sender checkbox and removal of the old tab/IP controls. English/Korean update-menu hierarchy checks also passed. These are not real-device connection tests. Physical two-Mac behavior and native Receiver UI remain unverified. Frame rate, end-to-end latency and broad macOS compatibility are not guaranteed. Some display/gesture features use undocumented macOS interfaces.

Apple notarization Accepted on 2026-10-22 (status code0, Ready for distribution, no listed issues). The ticket is stapled and validated; strict/deep signature verification passed and Gatekeeper reports accepted, source=Notarized Developer ID. Main/helper and all originally signed app files remained unchanged after submission.

Notarization is not App Store review or an independent security audit. No license has been selected for original code/artwork. Third-party notices are preserved.
