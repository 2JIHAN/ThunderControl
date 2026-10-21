# Third-party notices

These notices apply to their named components, not as a license grant for ThunderControl's original code.

## BoringSSL

- Source: https://boringssl.googlesource.com/boringssl
- Pinned commit: `487f196f7f561d5ee08cee968d1d4b4dd24d365f`
- Purpose: SPAKE2 pairing through `libcrypto`.
- License: Apache-2.0; the complete upstream LICENSE, including its support-code notice, is preserved in `Licenses/BoringSSL-LICENSE` and the submodule.
- Upstream source is not modified. Local build flags remap build paths and target arm64/macOS 13 with FIPS disabled. Build products are not tracked.

## ISS adapted gesture payload subset

- Source: https://github.com/joshuarli/iss
- Pinned revision: `493b008f2ea8e9215877c39700e8ea3add800e97`
- License and copyright: `Licenses/ISS-LICENSE-ISC` and `DockGesture/Vendor/LICENSE-ISC`.
- `DockGesture/Vendor/iss_payload.inc` contains the required packed IOHID layouts, fixed-point conversion, payload generation and augmentation subset. `DockGestureBridge.c` adapts the builder with bounded scalar validation. Upstream tap, posting, main and Space APIs were not copied.
- The numeric vertical-motion value was cross-checked against a public report in Mac Mouse Fix; no Mac Mouse Fix implementation or GPL code was copied. Native gesture behavior is not established by a memory fixture.

## Chromium-derived virtual-display declarations

- Source: https://chromium.googlesource.com/chromium/src/+/HEAD/ui/display/mac/test/virtual_display_util_mac.mm
- Scope: adapted/cross-checked private `CGVirtualDisplay` interface declarations in the display helper.
- Full attribution and BSD-style license: `Licenses/Chromium-NOTICE.txt` and `DisplaySenderHelper/THIRD_PARTY_NOTICES.txt`.
- These declarations describe undocumented Apple runtime interfaces, not a supported public SDK contract.

All three complete notice files and this summary are packaged under `ThunderControl.app/Contents/Resources/`.
