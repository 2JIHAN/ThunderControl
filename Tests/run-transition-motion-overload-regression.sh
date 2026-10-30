#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
RESULTS=${1:?Pass the shared compiler-slot results directory}
SCRATCH=${2:?Pass a task-owned scratch directory}
SLOT=''
for N in 1 2; do
  if mkdir "$RESULTS/compiler-slot-$N" 2>/dev/null; then SLOT="$RESULTS/compiler-slot-$N"; break; fi
done
if [ -z "$SLOT" ]; then echo 'Both compiler slots occupied; retry after another lane finishes.' >&2; exit 75; fi
trap 'rmdir "$SLOT"' EXIT
mkdir -p "$SCRATCH"
GENERATED="$SCRATCH/TransitionMotionOverloadMain.swift"
BINARY="$SCRATCH/transition-motion-overload"
grep -Fq 'private let pending = DispatchSemaphore(value: 128)' "$ROOT/ThunderControl.swift"
cat "$ROOT/Tests/TransitionMotionOverloadRegression.swift.inc" > "$GENERATED"
sed -n '/^  func enqueue(_ input: Wire) -> Bool {$/,/^  @discardableResult$/p' "$ROOT/ThunderControl.swift" | sed '$d' >> "$GENERATED"
sed -n '/^  private func flushEntryMotion(token:String)->Bool {$/,/^  private func handleSourceGesture(/p' "$ROOT/ThunderControl.swift" | sed '$d' >> "$GENERATED"
cat >> "$GENERATED" <<'SWIFT'
}
@main struct Run {
  static func main() {
    precondition(runTransitionMotionTests() == 0)
    TransitionReplayFixture().runReplay(count: 128)
    TransitionReplayFixture().runReplay(count: 129)
    TransitionReplayFixture().runReplay(count: 2_048)
    TransitionReplayFixture().runReplay(count: 129, availableSlots: 127)
  }
}
SWIFT
CLEAR=/Users/seesoong/.aside/u/0/skills/user/quarantine-free-files/scripts/clear-quarantine.sh
"$CLEAR" "$GENERATED" "$SCRATCH"
xcrun swiftc -swift-version 5 -parse-as-library "$ROOT/TransitionMotion.swift" "$ROOT/Tests/TransitionMotionTests.swift" "$GENERATED" -o "$BINARY"
"$CLEAR" "$GENERATED" "$BINARY" "$SCRATCH"
"$BINARY"
