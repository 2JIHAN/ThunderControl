# Security

ThunderControl is experimental. Its encryption, pairing, route checks and fail-closed policies are not a substitute for an independent security review. Use it only between Macs you control over a dedicated, direct Thunderbolt Bridge.

If you find a security issue, use GitHub's private vulnerability reporting for this repository if available. If private reporting is unavailable, open an issue asking for a private contact without including exploit details, secrets or private captures.

Never publish PINs, tokens, pairing material, Keychain exports or unreviewed diagnostic archives. A PIN confirms a pairing exchange, not a person's identity or cable proximity. Keep the local keyboard available and use Control + Option + Escape to stop input.

Do not disable SIP or Gatekeeper to test the app. Do not reset macOS permissions or delete Keychain items as a generic upgrade step. A change in bundle ID or signing identity can affect existing permission grants.

## v0.8.27 policy changes

v0.8.27 (build 57) is an experimental prerelease target. Its release asset availability, signing and Apple notarization remain pending verification. v0.8.26 was Developer ID-signed and Apple-notarized; that historical approval does not cover v0.8.27.

- **Secure Input is not a session-disconnect trigger by itself.** The default session policy retains authenticated connections without disabling or bypassing macOS Secure Input. macOS may restrict protected event delivery; connection continuity does not promise delivery of protected keystrokes. An explicit strict stop policy remains available in the policy implementation.
- **Ordinary source foreground loss pauses remote input, not the authenticated session.** Active remote ownership is cancelled and input returns locally; authenticated transport, video and saved sharing intent are retained. This is not authorization to continue background input forwarding.
- **First authenticated pair defaults are automatic, not unconditional.** A valid live authenticated pair with no saved record can seed automatic input and video intent. Existing records, including OFF, take priority. Unreadable sharing storage is not treated as an absent record. Discovered or stored addresses alone do not authorize sharing.
- **Stop and safety gates still take precedence.** Saved OFF, manual/emergency-stop latches, lock/sleep/session checks, permissions, authenticated route validation and capture/topology checks remain applicable. Automatic restore is not permission to bypass these checks. Lock/unlock recovery requires its existing verified-unlock and fresh-authentication conditions; ordinary focus changes do not weaken them.

Claims that Secure Input always disconnects, that every source focus loss tears down transport/video, or that every first video start requires a button click no longer describe the default v0.8.27 behavior. Conversely, retaining transport does not mean remote input is allowed in an unsafe session. See [verification scope](docs/VERIFICATION.md) for the distinction between source inspection, reported standalone policy tests and still-pending integrated/live results. There is no promised support lifecycle for older prereleases.
