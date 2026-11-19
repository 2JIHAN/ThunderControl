#!/bin/bash
# Builds ThunderControlAudio.driver next to this script. SIGNING_IDENTITY defaults to ad hoc.
set -euo pipefail
cd "$(dirname "$0")"
B=ThunderControlAudio.driver
rm -rf "$B"; mkdir -p "$B/Contents/MacOS"
cat > "$B/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ThunderControlAudio</string>
<key>CFBundleIdentifier</key><string>local.experimental.ThunderControl.AudioDriver</string>
<key>CFBundleName</key><string>ThunderControlAudio</string>
<key>CFBundlePackageType</key><string>BNDL</string>
<key>CFBundleShortVersionString</key><string>1.0</string><key>CFBundleVersion</key><string>1</string>
<key>CFPlugInFactories</key><dict><key>5B3F2C1E-7A64-4D8B-9E21-C0A47F6D3B58</key><string>ThunderControlAudioFactory</string></dict>
<key>CFPlugInTypes</key><dict><key>443ABAB8-E7B3-491A-B985-BEB9187030DB</key><array><string>5B3F2C1E-7A64-4D8B-9E21-C0A47F6D3B58</string></array></dict>
</dict></plist>
PLIST
xcrun clang -Wall -Wextra -Werror -Wno-unused-parameter -O2 -target arm64-apple-macos13.0 -bundle ThunderControlAudio.c \
  -o "$B/Contents/MacOS/ThunderControlAudio" -framework CoreFoundation -framework CoreAudio
ARGS=(--force --options runtime --sign "${SIGNING_IDENTITY:--}")
[[ "${SIGNING_IDENTITY:--}" != "-" ]] && ARGS+=(--timestamp)
codesign "${ARGS[@]}" "$B"
codesign --verify --strict "$B"
