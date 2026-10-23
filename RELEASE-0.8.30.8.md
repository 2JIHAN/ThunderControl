# ThunderControl 0.8.30.8: Frame pacing test

Experimental prerelease, build 68. Apple Silicon; display sharing requires macOS 14 or later.

## Changes

- The MacBook video viewer now submits decoded frames from a real, view-associated display link instead of immediately on decode or renderer-readiness callbacks. The requested cadence is 60 Hz; the OS and display determine actual callbacks.
- Keeps at most two decoded frames with a nominal one-frame cushion. Selects eligible recent frames and avoids catch-up bursts. A bounded fallback prevents starvation with faster incoming frames.
- Compressed H.264 reference frames are not discarded by this policy. Encoder settings, transport, pairing, permissions and saved layout formats are unchanged.
- Invalidates display-link callbacks and clears pending images on clear/close. Adds pacing counters and display-link cadence diagnostics.

## What was verified

- 41 deterministic pacing-policy checks and the full existing headless regression suite passed.
- Actual VideoToolbox decoder integration passed with generated 1080p and HiDPI fixtures.
- A local native HiDPI viewer test decoded and submitted all eight fixture frames using the actual display link. Focus changes, one-shot readiness callbacks and close cleanup passed.
- Developer ID signing, Apple notarization, stapled ticket and Gatekeeper assessment passed.

These are policy, codec and local native-window checks. This release has **not yet been verified to eliminate stutter over two Macs**, guarantee stable physical-panel 60 fps, or improve input-to-display latency. The nominal cushion can add latency. The prior serial H.264/raw measurements predate this pacing change and are not results for this release.

## Installation

This change is in the receiving viewer, normally the MacBook. Updating the MacBook is required to use it; an existing 0.8.30.7 Mac mini can continue sending because the wire protocol is unchanged. Both Macs may use this version.

1. Download the ARM64 ZIP and verify it against `SHA256SUMS.txt`.
2. Quit the previous ThunderControl normally and keep a backup before replacing `/Applications/ThunderControl.app`.
3. Launch the updated app. Do not reset pairing, Keychain or permissions.
4. If the virtual-display checkbox was turned off for experiments, enable **Use this Mac as a virtual display** on the MacBook to resume video.

Four-component test tags may not appear in older automatic update checks. Use this release page directly. This is a prerelease, not the latest stable release.

## 한국어 안내

맥북 수신 화면에 프레임 페이싱을 추가한 테스트 버전입니다. 화면 갱신 주기에 맞춰 디코딩된 프레임을 제출하며, 대기 화면은 최대 두 장으로 제한합니다. 기존 페어링, 권한, 저장된 배치는 초기화하지 않습니다.

로컬 검사와 공증은 완료했지만, 실제 두 맥에서 끊김이 줄었는지와 안정적인 패널 60fps는 아직 확인 전입니다. 버퍼로 인해 지연이 늘 수 있으므로 매끄러움과 입력 반응을 함께 확인해야 합니다. 실험 중 가상 화면 체크를 껐다면 업데이트 후 다시 켜주세요.
