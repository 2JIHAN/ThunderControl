# ThunderControl0.8.29 (build59)

Experimental prerelease fixing a0.8.28 startup regression.

## Connected is not the same as sharing ready

Changing input roles previously called the same path as explicit Stop, saving input/video OFF and keeping a sharing-stop latch. Connecting again could authenticate successfully while automatic input restoration and the display preference never started. This release separates role-change teardown from intentional Stop. Explicit Connect resumes input intent only for the freshly authenticated peer and keeps explicit videoOFF choices and session/permission/recovery guards.

The same-peer connection step no longer discards a pending virtual-display checkbox change. A different peer/role cannot inherit that pending choice. Startup diagnostics now identify blocking gates and input readiness instead of treating connection authentication as proof that sharing is armed.

## Update both Macs

Install ThunderControl-0.8.29-macOS-arm64.zip after checking SHA256SUMS.txt. Quit the old app normally, keep a backup and replace the whole bundle. Do not reset pairing, Keychain or permissions. On the Sender, select the connected Receiver and click Connect once to explicitly resume input after the old stop state. Select Use this Mac as a virtual display when video is wanted; explicit videoOFF is not silently reset. Existing manual/emergency stops are not resumed by role changes or automatic reconnects. Keep Control+Option+Escape available.

The app retains the0.8.28 update-check menu and single-checkbox video interface. No automatic installation is introduced.

## Verification

The final optimized Developer ID build and complete safe regression script passed. App/Relay lifecycle fixtures passed44 checks, localization772, display-preference48 and update-check160. Fixtures exercised actual inert teardown, generation/role/pair-scoped resume, preservation of explicit/global videoOFF and real control-receive callbacks. Main/helper, recovery, ownership, desktop-map and local PIN integration passed; English/Korean offscreen AppKit checks passed. Full native modeChanged/Connect UI and physical two-Mac input/video were not exercised.

Apple notarization Accepted on2026-10-22, status code0, Ready for distribution, no listed issues. The ticket is stapled and validated. Strict/deep signature verification passed and Gatekeeper reports accepted, source=Notarized Developer ID. All signed app files remained unchanged after submission.

Physical two-Mac mouse/keyboard/video behavior must still be confirmed after installation on both Macs. Fixture success, code signing and notarization are not a substitute for that test or an independent security audit. Some display/gesture features use undocumented macOS interfaces. No frame-rate, latency or broad OS compatibility guarantee.
