# ThunderControl 0.8.26 / build 56

## First public preview

English-first native macOS UI with bundled Korean support, plus a shorter bilingual README and a reproducible source build.

**Download:** `ThunderControl-0.8.26-macOS-arm64.zip` for Apple Silicon. Compare it with `SHA256SUMS.txt` before expanding it. The video helper targets macOS 14 or later; local validation used macOS 27.2, not a broad OS compatibility matrix.

**Signing update, 2026-10-21:** Apple notarization was accepted, the approval ticket was stapled to the app and validated, and Gatekeeper assessed it as **Notarized Developer ID**. The two executable files are byte-identical to the initial v0.8.26 build. The ZIP and checksum were updated to carry the ticket and current installation notes. This is still an experimental prerelease, not App Store review or a guarantee of safe/correct behavior. macOS role-specific permissions remain required. Do not disable Gatekeeper or SIP.

## What's new

- English is the development language; Korean is selected through the normal macOS app-language setting, with English fallback elsewhere.
- Buttons, tabs, status messages, alerts, notifications and the Local Network permission explanation use bundled translation resources.
- English and Korean README entry points have the same structure and clear language links. Detailed build, localization and verification notes are separate.
- The public build uses a pinned BoringSSL source dependency, configurable signing, complete third-party notices and build-path prefix maps rather than shipping personal checkout paths.

## What stays the same

The 0.8.25 response-first encoder profile, 2x HiDPI negotiation, authenticated input/video separation, native macOS full screen and existing input safety gates are retained. Only the helper's version banner changes in its source. No Keychain, pairing settings or macOS permissions need to be reset to update. The previous app can be kept as a fallback.

Use **Control+Option+Escape** to stop input. Video has a separate **Stop Screen Sharing** control. A safety stop is not an ordinary cable disconnect and requires an explicit resume.

The inherited generated-pattern encoder measurements are not a new two-Mac latency benchmark. No guaranteed 60fps, arbitrary-workload visual quality, end-to-end input-to-panel latency, broad macOS compatibility, real two-Mac Mission Control gesture support or independent security audit is claimed.

No license has yet been selected for the original code or artwork. Third-party components retain their own licenses and notices.

See [README](../README.md), [한국어](../README.ko.md), [localization](LOCALIZATION.md) and [verification scope](VERIFICATION.md).
