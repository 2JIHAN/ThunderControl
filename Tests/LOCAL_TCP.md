# Run the .32 local TCP input tests

This fixture tests the 0.8.30.33 unified-HID test source with test instrumentation. It uses real localhost TCP, memory-backed trusted pairing, the application's outgoing queue, the shared authenticated receive loop, Relay input validation and the unified HID input poster. It records native input and cursor operations instead of sending them to macOS.

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

The build uses the .33 quality-tier configuration, build 71.38. It does not replace `/Applications/ThunderControl.app` or the published release ZIP.

## Read the result correctly

The legacy negative suite explicitly primes an active handoff. A separate negotiated suite starts both endpoints local, exchanges capability-bearing authenticated hello packets and pumps both authenticated streams. It publishes the map and lease, exercises the actual edge detector and begin/ready/commit/active handshake, records the activation warp, delivers HID motion, then returns through return/returnAck with fresh tokens on repeated cycles. Additional cases cover held-source-key return ACK deferral, stale handoff tokens, expired genuine leases delayed behind a bounded writer latch, source-only/receiver-only/simultaneous/staggered same-connection reset/ready recovery, wrong ready tokens, old pre-reset leases at the exact next sequence and new handoff token before age expiry, begin/commit permission or routing denial, native focus denial, bridge name/index/address mismatch, exact two-second grace expiry, and queued outbound cancellation with a 128-frame budget and peer EOF. A replacement-transport case keeps the same sender writer, cancels its old context, drains old queued jobs and accepts the fresh connection's first sequence under its new key. All native input APIs and cursor operations are record-only dependencies.

Discovery, physical interface binding, real foreground confirmation, WindowServer acceptance and physical Thunderbolt recovery are not proven. The source constructs serialized events instead of capturing a physical mouse.

A passing result proves delivery to the recording native boundary. It does not prove that WindowServer or a game accepts the input, that a physical Thunderbolt cable recovers, or that two independent full application processes work together. The production address validation continues to reject localhost; only this explicitly gated test creates loopback sockets.

The earlier `transport-only-initial` build is archived for provenance. It does not include the Relay/HID path and must not be used as the final integration result.


## Separate native owned-window mode

`--local-native-input-test` is an additional explicit opt-in and still requires both base test flags. It runs only the small negotiated native case, not the headless matrix. The default runner never creates the owned window or calls its real input APIs. Native execution needs a separate announced run and preflight; compiling the mode is not native acceptance evidence. The source cursor controllers remain fake. Receiver motion, keyboard, buttons and Shift are limited to the manager-owned window.

## Unified HID boundary coverage

The recording suite asserts A down/up, left/right/other button transitions, motion and drags 5/6/7/27 use the same HID port. Keyboard and modifier posts use global-flags option 1. Mouse posts use cursor option 2. The fake kernel flags verify Shift remains visible to a subsequent drag, dual Shift retains its aggregate until the last side releases, and the final up clears Shift. Payload checks inspect the public NXEventData mouse union, not an assumed raw-delta union. Scroll stays on CG. Stop after authentication expiry releases owned keys/buttons through HID, restores the initial Caps state with flagsChanged 57, and closes only afterward. Failed cleanup must retain its port and ledger for an idempotent retry.

These are assertions awaiting rebuild and execution, not a claim of a new passing run. System-defined type 14 and whole-desktop unsupported-coordinate CG backend selection are not added to this integration matrix.

The owned-window mode additionally requires keyboard, Shift, left/right/other button state and drag NSEvents, including type 27. Every matching ordinary event must report this process as its source PID. Unknown source identity fails. Emergency cleanup is limited to its own tracked HID inputs, owned focus and existing port, and marks the run failed. It does not issue unconditional CG key/button releases. The diagnostic cursor-anchor synchronization bypass has been removed. Exact relative delta comparisons remain independent checks without relaxed tolerance. Native relative delta delivery, especially the first movement after warp, remains unverified by this change.

Native execution requires fresh user consent after the parent rebuild. No game, physical capture, virtual driver or new production setting is introduced. The original foreground app, cursor recovery and 20-second watchdog remain in the fixture.
