# Pairing dependency

BoringSSL is pinned as a Git submodule at the revision recorded in `VENDOR-REVISION.txt`. The upstream source is unmodified; `scripts/build-dependencies.sh` builds arm64 `libcrypto.a` with macOS 13 deployment target, FIPS disabled and build-path remapping. The full upstream license is preserved under `Licenses/` and in the app bundle.

`SafePairing.swift` uses the pinned `include/openssl/curve25519.h` SPAKE2 API through `CSPAKE2`. The protocol binds session, request, role, device display names and fresh nonces, then verifies role-separated key confirmations before returning a session key. Traffic framing, deadlines, attempt budgets, approval and authenticated session-ready activation are caller responsibilities implemented in the parent app.

A four-digit PIN has only 10,000 possibilities and is not a permanent device identity. SPAKE2 does not prove physical proximity or eliminate active guessing, relay attacks or approval mistakes. The implementation is not claimed independently audited. Do not log or persist PINs or session secrets.

See `Tests/PairingTests.swift`, the integrated pairing fixtures, and the main source for concrete validation and fail-closed policies. Do not treat a successful memory-only test as a real two-Mac security assessment.
