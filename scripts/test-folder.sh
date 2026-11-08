#!/bin/bash
# Standalone folder module checks (Foundation/CryptoKit/Darwin only, no AppKit).
# Usage: scripts/test-folder.sh [OUTPUT_BINARY]
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-${TMPDIR:-/tmp}/thundercontrol-folder-tests}"
xcrun swiftc -swift-version 5 -parse-as-library -D FOLDER_TRANSFER_SELF_TEST \
  FileTransferStorage.swift FolderManifest.swift FolderReceiverStore.swift FolderTransferEngine.swift \
  Tests/FolderTransferTests.swift -framework CryptoKit -o "$OUT"
# Only the binary this script just built. Never clear other files.
if /usr/bin/xattr "$OUT" | grep -qx com.apple.quarantine; then /usr/bin/xattr -d com.apple.quarantine "$OUT"; fi
if /usr/bin/xattr "$OUT" | grep -qx com.apple.quarantine; then echo 'Quarantine remains on test binary.' >&2; exit 1; fi
if otool -L "$OUT" | grep -q AppKit; then echo 'Folder modules must not link AppKit.' >&2; exit 1; fi
"$OUT"
