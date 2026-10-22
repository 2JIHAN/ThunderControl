# Verification scope for v0.8.30.1 (build61)

This is a test revision of0.8.30, not a physical two-Mac latency claim. Installed0.8.30 is left unchanged by this release task.

## New display path

TDSP6 and a separately authenticated exact capability echo isolate stamped-frame and cursor metadata. Cursor capture is disabled only in the owned virtual-display SCStream; a separate bounded enum/normalized-coordinate packet drives a viewer overlay. Invalid topology is checked again after the output mutex is acquired. Unknown custom shapes fall back to arrow. The source reports authoritative cursor state, not local prediction.

Stage diagnostics never subtract different hosts' monotonic timestamps. Encoder callbacks, decoder cookies, and the latest presentation buffer are bounded. Socket-write duration is not delivery, renderer enqueue is not panel scanout. The viewer replaces readiness polling with an epoch-guarded callback that stops registration before drain.

## Verification record

Final Developer ID optimized build and full safe regression script passed. Updated version comparison passed299 fixtures. Actual hardware H.264 stamped-envelope/AEAD/production decode passed8/8 at1920x1080 and3024x1900 physical. Native accessory and regular fullscreen fixtures each decoded/submitted8 frames and checked separate cursor image/layer, coordinate movement, duplicate rejection, explicit hide,500ms expiry and close cleanup;703 colorful generated samples per screenshot. A new video frame while another key window held focus also passed. Source stage timestamps in these fixtures are synthetic, not performance measurements. Forced sustained renderer backpressure was not separately tested. One incorrect native CLI flag ordering was rejected before fixture startup; corrected calls passed. A read-only independent source review found and resolved cursor post-mutex topology staleness and protocol compatibility gaps, then found no further production blockers; this is not a security certification. Evidence is recorded in checks-0.8.30.1. No actual two-Mac trial, physical panel latency measurement, or real input posting is performed in these local fixtures. This release does not change the capture backend, H.264 quality policy or network transport family.

Apple notarization for0.8.30.1 Accepted on2026-10-22. Stapled ticket, strict/deep signature and Gatekeeper Notarized Developer ID passed; original signed app-file hashes unchanged.

## Historical 0.8.30 verification

# Verification scope for v0.8.30 (build60)

## Viewer ownership and presentation

The authenticated view-only display viewer may serve as source input ownership via a coordinator shared by production request/restore callbacks. The invisible HUD is used only when there is no eligible viewer. Arbitrary key windows are not accepted. Viewer closure/focus loss uses the existing local-return/input-drain path; no second viewer input-forwarding path is added.

Video rendering is no longer gated on native full-screen completion or active keyboard ownership. The viewer stays usable while native readiness/entry are pending or fall back. Native readiness and entry have separate bounded deadlines, one request per viewer lifetime, and distinct diagnostic reasons. Focus lifecycle observation is independent of optional viewer-local input monitors.

## First default layout

Unsaved pairs default to Sender screen, Receiver owned virtual display and Receiver physical monitor from left to right with vertical centers aligned. Only owned virtual origins and the logical Sender map attachment change; physical monitor positions are not rearranged. A default Sender attachment moves from the physical-only map to the virtual-left edge when the virtual arrives. Saved per-pair and legacy source/virtual placements win; a saved right-side virtual retains a valid collision-free source fallback. Geometry fixtures passed288 assertions and the helper offline suite238 checks before the final combined build. No physical display configuration was changed by these fixtures.

The final combined optimized Developer ID build and complete safe regressions passed: geometry 288 assertions, actual Relay map adoption 42, sharing lifecycle 44, localization 772, display preference 48 and updater policy 160, plus helper offline 238 and recovery/ownership/desktop-map/local PIN fixtures. English/Korean offscreen AppKit checks passed. The final binary entered native fullscreen under both regular and production accessory activation policies, recognized the exact viewer as input owner, rejected another key window, rendered a new eighth frame while that other window held focus, and rejected closed-viewer ownership. Screenshots contain generated video only; no user desktop was captured. Physical two-Mac input/video and real display reconfiguration were not exercised by these fixtures.

Apple notarization Accepted on 2026-10-22 (status code 0, Ready for distribution, no listed issues). The ticket is stapled and validated. Strict/deep code signature verification passed and Gatekeeper reports accepted, source=Notarized Developer ID. All signed app files remained unchanged after submission.

One earlier immediate windowed fixture after a full-screen test missed its3s activation bound; an isolated retry passed. Final combined regular/accessory full-screen tests both passed. Physical MacBook/two-Mac input/video behavior remains unverified by local fixtures. Do not treat the prior report's suspected focus conflict as a fully instrumented field root-cause determination.

## Historical0.8.29 evidence

## Sharing startup regression

A user field report and sender/receiver logs showed authenticated input connections and geometry exchange without Auto arming or display startup after repeated role changes. Source inspection found modeChanged calling the explicit Stop-all path, leaving shared input/video intent OFF and an input-restoration block. Authentication status was not evidence of completed sharing startup.

The fix separates role teardown from explicit Stop, applies explicit Connect input-resume only after a matching authenticated generation/role/pair, preserves videoOFF and safety/session/permission/recovery gates, and preserves checkbox intent during same-peer address synchronization. Startup diagnostics record blocking gates/readiness without credentials. No blanket preference migration or reset is performed.

The final Developer ID build and full safe release script passed. App/Relay lifecycle44, localization772, display48 and update160 checks passed, along with main/helper, recovery, ownership, desktop-map and local PIN fixtures and English/Korean offscreen AppKit checks. Apple notarization Accepted on2026-10-22, status code0, Ready for distribution, no listed issues. The ticket is stapled and validated. Strict/deep signature verification passed and Gatekeeper reports accepted, source=Notarized Developer ID. All signed app files remained unchanged after submission. App/Relay fixture coverage exercises actual teardown with inert sockets, explicit-resume and actual control dispatch, not the complete native modeChanged/Connect UI with physical peers. Physical two-Mac input/video recovery remains unverified until both devices update and reconnect.

## Historical0.8.28 evidence

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
