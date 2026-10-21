# Security

ThunderControl is experimental. Its encryption, pairing, route checks and fail-closed policies are not a substitute for an independent security review. Use it only between Macs you control over a dedicated, direct Thunderbolt Bridge.

If you find a security issue, use GitHub's private vulnerability reporting for this repository if available. If private reporting is unavailable, open an issue asking for a private contact without including exploit details, secrets or private captures.

Never publish PINs, tokens, pairing material, Keychain exports or unreviewed diagnostic archives. A PIN confirms a pairing exchange, not a person's identity or cable proximity. Keep the local keyboard available and use Control + Option + Escape to stop input.

Do not disable SIP or Gatekeeper to test the app. Do not reset macOS permissions or delete Keychain items as a generic upgrade step. A change in bundle ID or signing identity can affect existing permission grants.

The current public release is v0.8.26. Its input and display implementation evidence is inherited from v0.8.25; see [verification scope](docs/VERIFICATION.md) for the additional release checks and remaining gaps. There is no promised support lifecycle for older prereleases.
