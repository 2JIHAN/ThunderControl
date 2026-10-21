# Apple notarization

## Published v0.8.26 download

On 2026-10-21, Apple's notary service accepted ThunderControl 0.8.26 / build 56 with status code 0, `Ready for distribution`, and no listed issues. The approval ticket was stapled to the app and validated. Gatekeeper assessed it as `accepted`, `source=Notarized Developer ID`.

The main executable and video helper are byte-identical to the original v0.8.26 build. Only the distribution ticket and packaging notes changed. The ZIP and `SHA256SUMS.txt` on the release were replaced; use the current checksum beside the download. The Git tag preserves the original source commit, including its initial publication documentation. The current README and this page record the subsequent notarization update.

Notarization is Apple's automated distribution check, not App Store review, independent security auditing, proof of private-API stability or validation of every feature. The app remains an experimental prerelease. Accessibility, Input Monitoring, Screen Recording and Local Network permissions still depend on the intended role and macOS.

## Verify the downloaded app

After verifying the ZIP against `SHA256SUMS.txt` and expanding it:

```sh
codesign --verify --deep --strict ThunderControl.app
xcrun stapler validate ThunderControl.app
spctl --assess --type execute --verbose=4 ThunderControl.app
```

The ticket should validate, and Gatekeeper should report `Notarized Developer ID`. Do not disable Gatekeeper or SIP to work around an unexpected failure. Do not reset pairing data, Keychain items or macOS permissions merely to update.

## Notarize your own build

Start with your own Developer ID-signed, hardened-runtime build. The default ad-hoc local build is not a distribution signature. Store your own Apple notarization credentials privately in Keychain; do not put a password, API private key or other secret in source or build logs.

```sh
# Run in an interactive terminal; the password is requested securely.
xcrun notarytool store-credentials YOUR_PROFILE \
  --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID

# Create a submission ZIP from the signed app.
ditto -c -k --sequesterRsrc --keepParent ThunderControl.app submission.zip
xcrun notarytool submit submission.zip --keychain-profile YOUR_PROFILE --wait

# Only after Apple returns Accepted:
xcrun stapler staple ThunderControl.app
xcrun stapler validate ThunderControl.app
codesign --verify --deep --strict ThunderControl.app
spctl --assess --type execute --verbose=4 ThunderControl.app
```

Recreate the final download ZIP after stapling, then regenerate its SHA-256 checksum. Do not rebuild or re-sign after stapling; that may invalidate the approved distribution. Keep the initial artifact and the Apple log privately for diagnosis.

See Apple's [notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).
