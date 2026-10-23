# ThunderControl 0.8.30.7 (build 67)

The registered AppKit display helper now dequeues and dispatches application events in its bounded pump instead of running only NSRunLoop. Guard checks and the existing monotonic deadline/capped wait remain; non-AppKit synthetic paths keep the run-loop fallback. No frame-rate, quality, protocol, pairing, permission, or physical-display policy changes. Stable per-user identity and process-lifetime exclusion remain.

An application-local event regression fails with the old pump and passes with the corrected pump. It creates no window, virtual display, capture stream, network, or posted system input. Existing offline suites and 300 separate-process identity probes also pass.

This corrects a concrete AppKit event-dispatch omission. Whether it also stops the independently observed physical ICC rewrite loop must be verified on the installed build. Do not claim ColorSync or perceived stutter fixed based on the event test alone. A temporary system-sRGB override on the live owned virtual display did NOT stop the loop (24 physical file rewrites in30s) and was restored to its factory assignment.
