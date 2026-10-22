# Verification scope for v0.8.28 (build 58)

## Current local checks

The optimized local build and full memory-only main regression suite passed. New authenticated display-preference protocol/policy tests passed 48 checks, including capability/role/session/sequence/envelope restrictions, pending pair policy, stale Receiver OFF, cleanup and manual-stop constraints. Localization passed 754 checks. Helper offline state-machine tests passed 233 assertions.

English and Korean AppKit offscreen hierarchy tests verified that the checkbox belongs to the Sender section, status shares its connection parent, there is no Extended Display tab and the old display IP field has no parent. These are not physical two-Mac tests. The attempted Receiver-role offscreen invocation was another Sender preview due an existing automation guard; Receiver native UI is not independently verified. Layer-backed buttons were absent in offscreen PNG rendering, so those PNGs are not complete UI visual proof.

The input Sender owns negotiated video preference. Routing uses only the currently authenticated socket peer. Old peers retain input but no automatic video. Remote ON does not clear manual/emergency safety latches or bypass permissions, session checks or topology cleanup. Saved pair OFF is preserved; device defaults seed only an absent record. These claims are supported by source and memory-only tests, not a new physical connection trial.

## Update check policy

Update metadata is fetched from the fixed public GitHub releases endpoint, including prereleases, without cookies or credentials. Responses are limited to1MiB and requests have bounded timeouts; redirects are rejected. Version comparisons are semantic and only newer valid tags are offered. Release links are constructed for this repository, not taken from remote URL fields. Automatic checks are throttled to24h; a passive menu item indicates an update. Manual checks can show a result dialog. There is no automatic download, installation or app restart. Automation/test invocations do not make update requests. The final signed app passed160 updater fixture checks. English/Korean AppKit offscreen checks verified both update menu entries without network requests. A standalone anonymous live transport fixture fetched GitHub release metadata and selected public prerelease0.8.27 over0.8.26. A real future-version update on two installed Macs has not been demonstrated.

## Distribution status

Developer ID build and the complete safe release fixtures passed: main/helper, recovery, ownership, desktop-map and local-socket PIN integration. The designated signing requirement matches installed0.8.27. Apple notarization Accepted on 2026-10-22 (status code0, Ready for distribution, no listed issues). The ticket is stapled and validated; strict/deep signature verification passed and Gatekeeper reports accepted, source=Notarized Developer ID. Main/helper and all originally signed app files remained unchanged after submission. Final status is recorded in the release's NOTARIZATION.txt and download checksums.

## Unverified behavior

Physical two-Mac checkbox-to-display startup/stop/reconnect and native Receiver UI remain unverified. Actual latency, frame rate, broad macOS compatibility, real Mission Control gestures and protected input delivery are not guaranteed. Previous live results below are historical evidence, not new0.8.28 measurements.

## Historical v0.8.25 implementation evidence

These measurements and live-helper checks were performed locally for the v0.8.25 implementation before public packaging. They are not repeated measurements of two physically connected Macs.

Three runs per configuration, 10 seconds per run, at the same generated-pattern size produced these median values:

- Capture-arrival to encoded output, mean: 25.141 ms before, 14.664 ms selected.
- Capture-arrival to encoded output, p95: 49.121 ms before, 15.475 ms selected.
- Encoded age of information: 34.852 ms before, 22.640 ms selected.
- Encoded frame rate: 58.729 fps before, 59.678 fps selected.
- Generated-source RGB PSNR: 43.593 dB before, 44.726 dB selected.
- Mean absolute RGB error: 0.888224/255 before, 0.758269/255 selected.

The selected HiDPI profile uses verified low-latency rate control, one reference buffer, two encoding slots and a bitrate factor of 9 rather than 6, capped at 64 Mbps. An unverifiable reference-buffer requirement falls back to the prior path. Receiver bounds were not relaxed.

H.264 to authenticated encryption to the production decoder passed eight-frame generated-pattern tests at 1920x1080 1x and 1512x950, 1512x945 and 1808x1130 2x.

Local real-virtual-display testing received 333, 364, 354 and 322 frames across creation, left placement, upper placement and a larger saved-placement restore. Low-latency mode and a one-reference-buffer readback were observed. Physical-monitor fields stayed unchanged during the armed stable phase, and EOF cleanup restored the owned configuration. Temporary OS transitions before that stable phase were separately observed and are not claimed invariant.

For v0.8.25, the full main regression suite and helper state-machine tests passed. That main suite includes 52 memory-only cases on the integrated system-gesture receiver path. Native full-screen presentation was checked on the Mac mini for that earlier implementation, not the v0.8.27 startup change.

## Not established

- Actual two-Mac keyboard or pointer input to panel latency.
- MacBook-side decoder/display latency or visual quality across arbitrary real workloads.
- A guaranteed 60 fps output rate.
- Real two-Mac Mission Control gestures, four-finger mapping or MacBook notch placement after updating both devices.
- Independent cryptographic/security auditing, broad macOS compatibility, or a production support guarantee.

## Historical v0.8.26 localization and public packaging

v0.8.26 added presentation-only localization and an offscreen native-control preview. The v0.8.25 encoder source is unchanged except its version banner. Wire keys, authentication, pairing storage, route policy, capture/decoder safety bounds and input gates are not intentionally changed.

The clean signed build passed the full memory-only regression suite in both English and Korean. Localization checks passed 703 assertions, including parity of 228 keys in each bundled language, indexed parameters, printf types/order, regional Korean, English fallback and literal handling of peer-supplied values. The helper state-machine, recovery mocks, ownership, desktop-map and local-socket pairing integration tests also passed.

All five native settings tabs were constructed in both languages with the app inactive, the window hidden, no relay session, discovery not browsing and input disabled. Fifteen visible buttons per language passed frame and intrinsic-width checks. Tab labels, text and guarded state were recorded without a PIN or peer address. AppKit print previews show labels and paragraph layout, but may omit modern layer-backed button/tab artwork; they are not full visible-window appearance proof.

The final implementation retained the four-size generated H.264/AEAD/decoder pipeline checks listed above. Strict/deep code-signature validation, bundled-license matching and executable private-path scans are separate release checks. Release assets include SHA-256 checksums, and the published download is compared with the local ZIP.

Offscreen rendering and guarded-state observations do not establish visible-window focus behavior, packet instrumentation, live sharing or physical two-Mac results.

## Historical v0.8.26 Apple notarization update, 2026-10-21

Apple returned `Accepted`, status code 0, with the summary `Ready for distribution` and no listed issues. The approval ticket was stapled to the app and `stapler validate` passed. Strict/deep code-signature validation passed, and Gatekeeper returned `accepted` with `source=Notarized Developer ID`. Both executables remained byte-identical to the initial v0.8.26 package; there was no rebuild or re-sign after approval.

The rebuilt distribution ZIP includes the stapled app and updated notes/checksum. The initial unnotarized ZIP is retained locally as a backup. The published replacement is separately downloaded and checked for checksum, signature, ticket and Gatekeeper assessment. None of the live-session or physical-device limitations above are removed by notarization.
