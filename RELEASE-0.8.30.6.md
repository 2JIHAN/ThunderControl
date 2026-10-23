# ThunderControl 0.8.30.6 (build 66)

## Stable virtual-display identity

The display sender previously chose a fresh random serial on every helper launch. macOS could therefore register each reconnect as a new monitor and retain another generated ICC profile. The sender now requests a stable vendor/product/serial tuple for the same local macOS user, independent of video format, process, peer and reconnect. Keep this v1 mapping stable in future releases. Different valid UIDs map to different nonzero serials; the invalid UID sentinel fails closed.

A process-lifetime nonblocking file lock permits only one new helper to use the per-user identity. The private lock directory/file must be owned by that user and not writable by other users; symlink/hardlink lock files fail closed. A process exit releases the lock; the lock file is intentionally not unlinked. Startup also rejects an already-online matching identity (or an unreadable serial in the same vendor/product namespace), rather than adopting an unknown display or choosing a new random identity.

No video protocol, bitrate, frame scheduling, display permissions, pairing, Keychain, or saved-placement changes. No automatic ICC deletion or ColorSync service modification. A newly fixed identity may produce one new ICC profile on first live use; the intention is to reuse that identity on subsequent connections, not to prevent macOS maintaining a profile.

## Verification

- Strict helper compilation and offline self-tests cover deterministic/nonzero/user-separated serials, exact collision matching, cross-process lock exclusion, release/reacquisition, owner and directory-mode checks, and symlink/hardlink rejection.
- `node scripts/test-display-identity.mjs` launches 300 separate read-only probe processes with default, 1080p and HiDPI formats, checks identical identity output, malformed arguments, the production descriptor assignment, and no installed-profile mutations. Node is only required for this optional developer test, not the app.
- Full app build and existing offline test suites must pass before installation.

These are offline checks, not a claim of verified live CoreGraphics UUID/ICC reuse or physical two-Mac stutter improvement. Live reconnect tests and installation are recorded separately in the workspace checks folder and HANDOFF.md. The existing installed app is not changed by building this candidate.
