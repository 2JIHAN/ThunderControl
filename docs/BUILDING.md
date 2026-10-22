# Building ThunderControl

## Requirements

Use an Apple Silicon Mac with Xcode command-line tools, a macOS SDK containing the required frameworks, CMake and Git. Compilation targets arm64. The main app targets macOS 13; its video helper targets macOS 14. A deployment target is not proof of testing every supported OS release. Local validation used macOS 27.2.

## Fetch and build

```sh
git clone --recurse-submodules https://github.com/2JIHAN/ThunderControl.git
cd ThunderControl
bash build.sh
```

If using a GitHub-generated source ZIP rather than Git, the BoringSSL submodule's source is not included. Use a recursive Git clone, or fetch the exact revision in `Pairing/VENDOR-REVISION.txt` into `Pairing/BoringSSL`. `build-dependencies.sh` checks the Git commit and refuses an unversioned dependency tree.

`build.sh` builds the pinned BoringSSL `crypto` target with CMake, compiles the helper and main app, packages third-party notices, signs the app and runs the main memory-only regression suite. It does not install the app, capture a desktop, start input control, reset permissions or modify existing pairing state.

The output is `ThunderControl.app`. Intermediate compiler and CMake files stay in ignored `own_tmp/`; the static library stays in ignored `Pairing/lib/`. Build-path prefix maps keep the checkout path out of release executables.

## Signing

The default is **ad-hoc signing**, intended for local development. To sign with your own available Developer ID identity:

```sh
SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' bash build.sh
```

A certificate fingerprint is also accepted by `codesign`. No personal certificate name, team ID, key or signing credential is committed in the build script. The helper and app are both signed with hardened runtime. Real Developer ID signing requests an Apple timestamp; ad-hoc signing does not.

Developer ID signing alone is not Apple notarization. The published v0.8.28 download is notarized and stapled, without changing its executable bytes after submission. Your own rebuild is not automatically notarized. See [the notarization workflow and verified release status](NOTARIZATION.md) and Apple's [documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution). Notarization credentials must be managed privately and must never be committed.

Changing the signing identity of an already paired app can change how macOS recognizes its permission identity. Keep an older app available and do not replace a working installation merely to run tests.

## Safe local tests

```sh
bash scripts/test.sh
```

This runs the main memory-only regressions, memory-only helper state-machine tests, recovery mocks, ownership checks, desktop-map checks and an in-process/local-socket pairing integration fixture. It does not exercise a real two-Mac session or produce actual input events.

Optional generated-pattern H.264 tests require hardware encoding and decoding. They are distinct from a real remote display or input-to-panel latency measurement. See `docs/VERIFICATION.md` for the scope of the existing evidence.

## Packaging

The public ZIP contains the app, its bundled licenses, a short installation note and the notice summary. Do not package the checkout, logs, private diagnostics, pairing preferences or Keychain data. Publish SHA-256 checksums beside the ZIP and verify the downloaded asset, not only the local file.
