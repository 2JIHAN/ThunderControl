#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
APP="${1:-${APP:-$ROOT/local-loopback-validation/ThunderControl-local-tcp-tests.app}}"
[[ "$APP" = /* ]] || { echo 'APP must be an absolute workspace path.' >&2; exit 1; }
[[ "$APP" == "$ROOT/local-loopback-validation/"*.app ]] || { echo 'Refusing an app outside this workspace validation directory.' >&2; exit 1; }
part="$APP"
while [[ "$part" != / ]]; do
  [[ ! -L "$part" ]] || { echo "Refusing symlink path: $part" >&2; exit 1; }
  part="$(dirname "$part")"
done
[[ -d "$APP" ]] || { echo "Build the local test app first: $APP" >&2; exit 1; }
APP="$(cd "$APP" && pwd -P)"
[[ "$APP" == "$ROOT/local-loopback-validation/"*.app ]] || { echo "Refusing a canonical app path outside workspace validation." >&2; exit 1; }
MAIN="$APP/Contents/MacOS/ThunderControl"
[[ -x "$MAIN" && ! -L "$MAIN" && ! -L "$APP/Contents" && ! -L "$APP/Contents/MacOS" ]] || { echo 'Missing or symlink test executable.' >&2; exit 1; }
while IFS= read -r -d '' item; do
  opts=(); [[ ! -L "$item" ]] || opts=(-s)
  attrs=$(/usr/bin/xattr ${opts[@]+"${opts[@]}"} "$item")
  if printf '%s\n' "$attrs" | grep -qx com.apple.quarantine; then
    echo "Refusing quarantined test app: $item" >&2; exit 1
  fi
done < <(find "$APP" \( -type f -o -type d -o -type l \) -print0)
status=0
output=$("$MAIN" --self-test --local-tcp-relay-integration-test) || status=$?
printf '%s\n' "$output"
[[ "$status" -eq 0 ]] || exit "$status"
printf '%s\n' "$output" | grep -Fq 'PASS local TCP actual Relay.enqueue -> authenticated stream -> Relay.receive -> HID poster 5/6/7 exact payload' || { echo 'Missing actual Relay/HID integration proof; refusing an old or incompatible binary.' >&2; exit 1; }
printf '%s\n' "$output" | grep -Fq 'PASS local TCP Relay integration. Core handoff is explicitly primed active;' || { echo 'Local TCP integration did not finish.' >&2; exit 1; }
