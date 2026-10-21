# Experimental system-gesture codec

The C bridge and Swift codec adapt the bounded ISS payload subset named in `Vendor/LICENSE-ISC` and `../THIRD_PARTY_NOTICES.md`. The pinned upstream ISS revision is `493b008f2ea8e9215877c39700e8ea3add800e97`.

The implementation reconstructs bounded scalar gesture descriptors. It does not claim to preserve an arbitrary original opaque HID event stream. Horizontal Spaces and the separately admitted experimental vertical Mission Control descriptor are distinct paths. Finger count cannot be inferred by this codec.

The parent app additionally requires authenticated input control, feature negotiation, the same exact OS build, a current desktop-map revision and the expected active pointer/display before accepting a system gesture. A map or display change rejects stale work. Supported codec construction is not evidence that the native UI gesture was delivered on a second Mac.

Memory-only codec and integrated receiver tests passed on the locally tested macOS 27.2 build. Actual two-Mac Mission Control behavior, gesture suppression and four-finger mapping remain unverified. Do not disable SIP, invent private API signatures or remove the parent's security gates to make a fixture pass.
