#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
BUILD_ROOT="$(cd .. && pwd)"
xcrun clang -ffile-prefix-map="$BUILD_ROOT"=. -fdebug-prefix-map="$BUILD_ROOT"=. -fobjc-arc -Wall -Wextra -Werror -O2 ${TC_HELPER_CFLAGS:-} -target arm64-apple-macos14.0 DisplaySenderHelper.m -framework AppKit -framework CoreGraphics -framework ScreenCaptureKit -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework Carbon -framework CoreText -o DisplaySenderHelper
for f in . DisplaySenderHelper.m build-helper.sh THIRD_PARTY_NOTICES.txt DisplaySenderHelper; do
 if [[ -L "$f" ]];then attrs=$(/usr/bin/xattr -s "$f");else attrs=$(/usr/bin/xattr "$f");fi
 if printf '%s\n' "$attrs" | grep -qx com.apple.quarantine; then if [[ -L "$f" ]];then /usr/bin/xattr -s -d com.apple.quarantine "$f";else /usr/bin/xattr -d com.apple.quarantine "$f";fi; fi
 if [[ -L "$f" ]];then attrs=$(/usr/bin/xattr -s "$f");else attrs=$(/usr/bin/xattr "$f");fi
 if printf '%s\n' "$attrs" | grep -qx com.apple.quarantine; then echo 'Quarantine verification failed' >&2; exit 1; fi
done
