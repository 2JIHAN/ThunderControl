# ThunderControl 0.8.30.9: Pipeline diagnostics and reconnect intent

Experimental prerelease, build 69. Apple Silicon; display sharing requires macOS 14 or later.

## Changes

- Automatically records numeric capture, encoder, pipe, transport, decoder, pacing and renderer-enqueue stages after the video connection authenticates. Shared stream IDs and frame sequence numbers correlate the two Macs without logging video pixels, typed text, PINs or authentication keys.
- Saves bounded local JSONL chunks and retries copying retained chunks to iCloud Drive/ThunderControl-진단/<random device ID>. Adds folder buttons in the permissions tab. Local copying does not prove upload or arrival on the other Mac.
- Keeps at most 1,024 outstanding events and 64 MiB or 15 minutes per local/cloud device directory. Copying is limited to 4 MiB and 64 files per five seconds. Drops, retention and copy backlog are explicit. Normal exit waits at most two seconds for a final flush.
- Stops treating the exact local authenticated-input queue overload as an authentication failure. A display-transition timeout retires the session and allows retry only after safe cleanup. Existing independent safety holds remain.
- Binds sender discovery reconnects to the remembered authenticated peer, separately from the cached-route time budget. Receiver listening uses the remembered peer from the same app execution when available.
- Manual Stop, emergency stop, permission/session restrictions, authentication and integrity checks remain enforced. This is not a claim that every video failure can recover without disconnecting.

Codec, FPS, encoder slots, wire format and frame-selection policy are unchanged. Instrumentation itself can add overhead.

## Verification and limits

- Full build and existing headless regressions passed. Recorder: 65 checks; receiver frame tracing: 22; diagnostic line parser: 34; helper offline selftest passed.
- 1,050,151 comparisons across 300,000 simulated pacing ticks matched the previous selected frames, queue lengths and counters.
- A 6,000-event test stored/copied 5,935 accepted events and explicitly counted 65 drops. A controlled-clock 60-second workload stored/copied 35,960 events with at most one pending chunk at the five-second checkpoints. These are local test folders, not real iCloud WAN delivery.
- Developer ID signing, Apple notarization, stapling and Gatekeeper assessment passed.

Actual cable unplug/replug recovery, physical-panel continuity, two-Mac 60fps and input-to-display latency remain unverified. Renderer enqueue and display-link callbacks are not panel-presentation proof. Never subtract timestamps from different Macs; helper CLOCK_MONOTONIC and systemUptime fields also have distinct clock domains.

## Install

1. Download the ARM64 ZIP and verify SHA256SUMS.txt.
2. Quit the previous app normally, keep a backup, and replace /Applications/ThunderControl.app.
3. Do not reset pairing, Keychain, permissions or saved layouts.
4. Update both Macs to collect the complete two-sided diagnostic trace. Saved OFF choices and explicit safety stops remain respected.

Older update checks may ignore four-component test tags. Use this prerelease page directly.

## 한국어 안내

프레임 공급이 줄어드는 지점을 찾기 위한 진단 버전입니다. 인증된 화면 연결 후 단계별 숫자 로그를 자동 저장하고, iCloud가 준비되면 보존 중인 로그를 자동 복사합니다. 영상이나 입력한 글자, 인증 비밀은 기록하지 않습니다. 저장 용량과 기간에 한도가 있고 누락을 별도 집계합니다.

일시적인 입력 큐 과부하나 화면 전환 시간 초과가 자동 재연결 의도를 불필요하게 막지 않도록 수정했습니다. 안전 정리가 끝난 뒤 같은 상대를 재인증하며, 직접 중지와 보안 제한은 우회하지 않습니다.

양쪽 맥에 설치해야 전체 진단을 모을 수 있습니다. 기존 페어링과 설정은 초기화하지 마세요. 실제 케이블 재삽입 복구와 끊김 개선은 아직 검증되지 않았습니다.
