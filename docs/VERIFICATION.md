# Verification scope for v0.8.26

## Inherited v0.8.25 implementation evidence

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

The full main regression suite and helper state-machine tests passed. The main suite includes 52 memory-only cases on the integrated system-gesture receiver path. Native full-screen presentation was checked on the Mac mini.

## Not established

- Actual two-Mac keyboard or pointer input to panel latency.
- MacBook-side decoder/display latency or visual quality across arbitrary real workloads.
- A guaranteed 60 fps output rate.
- Real two-Mac Mission Control gestures, four-finger mapping or MacBook notch placement after updating both devices.
- Independent cryptographic/security auditing, broad macOS compatibility, or a production support guarantee.

## v0.8.26 localization and public packaging

This release adds presentation-only localization and an offscreen native-control preview. The v0.8.25 encoder source is unchanged except its version banner. Wire keys, authentication, pairing storage, route policy, capture/decoder safety bounds and input gates are not intentionally changed.

The clean signed build passed the full memory-only regression suite in both English and Korean. Localization checks passed 703 assertions, including parity of 228 keys in each bundled language, indexed parameters, printf types/order, regional Korean, English fallback and literal handling of peer-supplied values. The helper state-machine, recovery mocks, ownership, desktop-map and local-socket pairing integration tests also passed.

All five native settings tabs were constructed in both languages with the app inactive, the window hidden, no relay session, discovery not browsing and input disabled. Fifteen visible buttons per language passed frame and intrinsic-width checks. Tab labels, text and guarded state were recorded without a PIN or peer address. AppKit print previews show labels and paragraph layout, but may omit modern layer-backed button/tab artwork; they are not full visible-window appearance proof.

The final implementation retained the four-size generated H.264/AEAD/decoder pipeline checks listed above. Strict/deep code-signature validation, bundled-license matching and executable private-path scans are separate release checks. Release assets include SHA-256 checksums, and the published download is compared with the local ZIP.

Offscreen rendering and guarded-state observations do not establish visible-window focus behavior, packet instrumentation, live sharing or physical two-Mac results.
