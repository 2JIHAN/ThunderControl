# ThunderControl 0.8.30 (build 60)

Experimental prerelease for two Apple Silicon Macs using a dedicated Thunderbolt Bridge.

## Viewer and input focus

The MacBook's extended-display viewer and remote-input ownership now share coordinated window ownership rather than competing for keyboard focus. A validated viewer can serve as the input ownership window; the invisible ownership window remains a fallback when no eligible viewer exists. Video stays view-only, with no duplicate keyboard/mouse forwarding path.

Native full-screen entry and video rendering are separate lifecycles. A usable viewer can display received video while the native window transition is pending or has fallen back. Moving to another app returns remote input locally without intentionally disconnecting video. Closing or replacing a viewer cannot leave stale input ownership behind. Existing authentication, session, permission, cleanup and input-release gates remain.

## First-layout default

For a device pair without saved placements, the logical left-to-right order is **Sender screen → Receiver virtual extended screen → Receiver physical monitor**, vertically center-aligned. Only the app-owned virtual display and logical Sender attachment are placed; existing physical monitor configuration is not rearranged. Saved per-pair and supported legacy placements take priority and are not reset, including an existing virtual display on the right. Odd-height integer display origins may differ from an exact center by at most half a logical point.

Update both Macs. Verify ThunderControl-0.8.30-macOS-arm64.zip using SHA256SUMS.txt, quit the old app normally, keep a backup and replace the whole app bundle. Do not reset permissions, pairing or Keychain. Select Use this Mac as a virtual display on the input Sender. Control+Option+Escape remains the remote-input emergency stop. No automatic installer is introduced.

## Verification and limits

The final combined optimized Developer ID build and complete safe regressions passed: geometry 288 assertions, actual Relay map adoption 42, sharing lifecycle 44, localization 772, display preference 48 and updater policy 160, plus helper offline 238 and recovery/ownership/desktop-map/local PIN fixtures. English/Korean offscreen AppKit checks passed. The final binary entered native fullscreen under both regular and production accessory activation policies, recognized the exact viewer as input owner, rejected another key window, rendered a new eighth frame while that other window held focus, and rejected closed-viewer ownership. Screenshots contain generated video only; no user desktop was captured. Physical two-Mac input/video and real display reconfiguration were not exercised by these fixtures.

Apple notarization Accepted on 2026-10-22 (status code 0, Ready for distribution, no listed issues). The ticket is stapled and validated. Strict/deep code signature verification passed and Gatekeeper reports accepted, source=Notarized Developer ID. All signed app files remained unchanged after submission.

MacBook-specific full-screen behavior, actual two-Mac input/video continuity and sustained performance remain subject to field validation. Local AppKit fixtures are not a physical two-Mac test or proof of compatibility across macOS versions. Some display/gesture features use undocumented macOS interfaces. Notarization is not App Store review or an independent security audit.
