#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
MAIN='ThunderControl.app/Contents/MacOS/ThunderControl'
HELPER='ThunderControl.app/Contents/MacOS/ThunderDisplaySender'
[[ -x "$MAIN" && -x "$HELPER" ]] || { echo 'Run bash build.sh first.' >&2; exit 1; }
# Only locally built executables, never an arbitrary downloaded app or system path.
for f in "$MAIN" "$HELPER"; do
  [[ ! -L "$f" ]] || { echo 'Refusing a symlink executable.' >&2; exit 1; }
  attrs=$(/usr/bin/xattr "$f")
  if printf '%s\n' "$attrs" | grep -qx com.apple.quarantine; then /usr/bin/xattr -d com.apple.quarantine "$f"; fi
  attrs=$(/usr/bin/xattr "$f")
  if printf '%s\n' "$attrs" | grep -qx com.apple.quarantine; then echo 'Quarantine remains.' >&2; exit 1; fi
done
"$MAIN" --self-test
"$HELPER" --selftest
"$MAIN" --recovery-self-test
"$MAIN" --ownership-self-test
"$MAIN" --desktop-map-self-test
"$MAIN" --pairing-integration-test
