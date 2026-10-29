# Run the .32 local TCP input tests

This fixture tests the latest published 0.8.30.32 source with test instrumentation. It uses real localhost TCP, memory-backed trusted pairing, the application's outgoing queue, the shared authenticated receive loop, Relay input validation and the HID motion poster. It records native input and cursor operations instead of sending them to macOS.

## Run the built test application

From `checks-final-vsync-20261027/source`, run:

```sh
bash scripts/test-local-tcp.sh
```

The script uses `../local-loopback-validation/ThunderControl-local-tcp-tests.app`. It refuses paths outside the validation folder, symlinks and quarantined bundles. It requires specific Relay/HID completion messages, so an old application that ignores the new flag cannot silently pass.

## Rebuild after changing source

```sh
TC_RECEIVER_VARIANT=quality-tiers \
  APP="$HOME/workspace/ThunderControl-builds/checks-final-vsync-20261027/local-loopback-validation/ThunderControl-local-tcp-tests.app" \
  SIGNING_IDENTITY=- nice -n 10 bash build.sh
bash scripts/test-local-tcp.sh
```

The build uses the .32 quality-tier configuration, build 71.37. It does not replace `/Applications/ThunderControl.app` or the published release ZIP.

## Read the result correctly

The core fixture begins with an authenticated handoff already active. It does not test automatic screen-edge entry, begin/ready/commit/active negotiation, discovery, bridge interface binding, the bridge input lease or delayed outgoing-write cancellation. The local source constructs serialized events instead of capturing a physical mouse.

A passing result proves delivery to the recording native boundary. It does not prove that WindowServer or a game accepts the input, that a physical Thunderbolt cable recovers, or that two independent full application processes work together. The production address validation continues to reject localhost; only this explicitly gated test creates loopback sockets.

The earlier `transport-only-initial` build is archived for provenance. It does not include the Relay/HID path and must not be used as the final integration result.
