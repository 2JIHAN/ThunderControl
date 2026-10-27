#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export TMPDIR="$PWD/own_tmp/compiler"
mkdir -p "$TMPDIR"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
[[ "$(shasum -a 256 Pairing/lib/libcrypto.a | awk '{print $1}')" == "acb1bd219ae99204bc6c972bd1a2a515aa417a61fb991bc5a95342ecc55faf62" ]] || { echo "Pinned crypto dependency mismatch" >&2; exit 1; }
APP="${APP:-ThunderControl.app}"
EXPERIMENT_FLAGS=()
case "${TC_RECEIVER_VARIANT:-baseline}" in
 immediate-fix) EXPERIMENT_FLAGS=(-D TC_FRESH_RECEIVER_SAFETY -D TC_RENDERER_HEALTH -D TC_IMMEDIATE_PRESENTATION); EXPERIMENT_BUILD="71.15";;
 immediate) EXPERIMENT_FLAGS=(-D TC_FRESH_RECEIVER_SAFETY -D TC_RENDERER_HEALTH -D TC_IMMEDIATE_PRESENTATION); EXPERIMENT_BUILD="71.11";;
 deadline) EXPERIMENT_FLAGS=(-D TC_NATIVE_VSYNC -D TC_FRESH_RECEIVER_SAFETY -D TC_RENDERER_HEALTH -D TC_DEADLINE_PRESENTATION); EXPERIMENT_BUILD="71.10";;
 final) EXPERIMENT_FLAGS=(-D TC_NATIVE_VSYNC -D TC_FRESH_RECEIVER_SAFETY -D TC_RENDERER_HEALTH); EXPERIMENT_BUILD="71.9";;
 baseline) EXPERIMENT_BUILD="71.2";;
 latest) EXPERIMENT_FLAGS=(-D TC_LATEST_DECODED); EXPERIMENT_BUILD="71.3";;
 timed) EXPERIMENT_FLAGS=(-D TC_LATEST_DECODED -D TC_TIMED_PRESENTATION); EXPERIMENT_BUILD="71.4";;
 safe-fifo) EXPERIMENT_FLAGS=(-D TC_FRESH_RECEIVER_SAFETY); EXPERIMENT_BUILD="71.7";;
 safe-only) EXPERIMENT_FLAGS=(-D TC_LATEST_DECODED -D TC_FRESH_RECEIVER_SAFETY); EXPERIMENT_BUILD="71.5";;
 safe) EXPERIMENT_FLAGS=(-D TC_LATEST_DECODED -D TC_TIMED_PRESENTATION -D TC_FRESH_RECEIVER_SAFETY); EXPERIMENT_BUILD="71.6";;
 *) echo "Unknown receiver variant" >&2; exit 2;;
esac
mkdir -p "$APP/Contents/MacOS"
# Discard an obsolete notarization ticket from a prior local build.
# This is the stapler metadata, NOT Contents/_CodeSignature/CodeResources.
rm -f -- "$APP/Contents/CodeResources"
bash DisplaySenderHelper/build-helper.sh
cp DisplaySenderHelper/DisplaySenderHelper "$APP/Contents/MacOS/ThunderDisplaySender"
xcrun clang -ffile-prefix-map="$PWD"=. -fdebug-prefix-map="$PWD"=. -target arm64-apple-macos13.0 -Wall -Wextra -c DockGesture/DockGestureBridge.c -o DockGesture/bridge.o
xcrun swiftc "${EXPERIMENT_FLAGS[@]}" -file-prefix-map "$PWD"=. -debug-prefix-map "$PWD"=. -swift-version 5 -parse-as-library -target arm64-apple-macos13.0 -O Localization.swift UpdateReleasePolicy.swift AppUpdateCheck.swift Tests/UpdateReleaseTests.swift LocalizationUIPreview.swift Tests/LocalizationTests.swift SavedSharingState.swift SharingLifecycle.swift Tests/SharingLifecycleIntegrationTests.swift DisplayPreference.swift Tests/DisplayPreferenceTests.swift AutomaticSharingResume.swift Tests/SavedSharingStateTests.swift Tests/AutomaticSharingResumeTests.swift DesktopEntryPolicy.swift Tests/DesktopEntryPolicyTests.swift DisplayVideoFormat.swift DisplayViewerTarget.swift Tests/DisplayVideoFormatTests.swift SavedVirtualDisplayPlacement.swift VirtualDisplayPlacementSession.swift Tests/SavedVirtualDisplayPlacementTests.swift Tests/VirtualDisplayPlacementSessionTests.swift ReceiverDesktop.swift SavedDesktopPlacement.swift Tests/ReceiverDesktopTests.swift Tests/ReceiverDesktopUITests.swift Tests/SavedDesktopPlacementTests.swift Tests/ReceiverDesktopRelayTests.swift Tests/DesktopHandoffRoutingTests.swift Tests/DesktopMapTransitionTests.swift ConcurrentDisplayTopology.swift Tests/ConcurrentDisplayTopologyTests.swift DevelopmentDiagnostics.swift Tests/DevelopmentDiagnosticsTests.swift Tests/DevelopmentFrameTraceTests.swift DisplayDiagnosticLines.swift Tests/DisplayDiagnosticLinesTests.swift DisplayCadence.swift Tests/DisplayCadenceTests.swift DisplayFramePacing.swift Tests/DisplayFramePacingTests.swift DisplayDeadlinePlan.swift Tests/DisplayDeadlinePlanTests.swift DisplayStreamMetadata.swift DisplayHeartbeat.swift Tests/DisplayHeartbeatTests.swift DisplayPeerRoute.swift DisplayTrust.swift Tests/DisplayTrustTests.swift Tests/DisplayLiveUITests.swift Tests/DisplayPipelineTests.swift DisplayRemoteInput.swift Tests/DisplayRemoteInputTests.swift DisplayMode.swift DisplayTransport.swift DisplayDecodeWorker.swift DisplayVideoDecoder.swift Tests/DisplayDecodeWorkerTests.swift Tests/DisplayTransportTests.swift Tests/DisplayVideoDecoderTests.swift ThunderControl.swift ScrollReplay.swift Tests/ScrollReplayTests.swift DiscoveryRecovery.swift AppAppearancePreferences.swift AppAppearanceIntegration.swift AppWindowPresentationPolicy.swift ConnectedWindowVisibility.swift SavedScreenLayout.swift Tests/SavedScreenLayoutTests.swift Tests/AppAppearancePreferencesTests.swift ConnectionNotifications.swift ConnectionNotificationPermission.swift Tests/ConnectionNotificationTests.swift AutomaticConnectionPolicy.swift Tests/CableReconnectPolicyTests.swift Tests/ScreenArrangementDragTests.swift AutomaticConnectionUI.swift BridgeRecoveryObserver.swift BridgeRecoveryScheduling.swift BridgeRecoveryIntegration.swift AutomaticReconnectBackoff.swift Tests/AutomaticReconnectBackoffTests.swift SessionAutoResume.swift SessionSuspensionOrigin.swift LockedTransportPolicy.swift AuthenticatedRouteHint.swift Tests/AuthenticatedRouteHintTests.swift FastReconnectIntegration.swift LoginLaunch.swift TrustedPairing.swift Tests/TrustedPairingTests.swift ReceiverCursorFocus.swift ReceiverFocusRetry.swift Tests/ReceiverCursorFocusTests.swift CursorVisibility.swift Tests/CursorVisibilityTests.swift ConnectedLayout.swift Tests/CursorModeProtocolTests.swift GestureTrace.swift DiagnosticStore.swift DiagnosticUI.swift Tests/DiagnosticStoreTests.swift Tests/GestureTraceTests.swift TransitionMotion.swift Tests/TransitionMotionTests.swift DockOutputExperiment.swift NativeGesture.swift DockTransferState.swift DockGesture/DockGestureCodec.swift Tests/NativeGestureTests.swift Tests/DesktopSystemGestureTests.swift DockGesture/bridge.o -import-objc-header DockGesture/DockGestureBridge.h CursorRecovery.swift Tests/ReturnWarpResumeTests.swift DisplayTopology.swift ModifierState.swift ScreenLayout.swift SessionSafety.swift SourceOwnershipHUD.swift SafePairing.swift PairingConsent.swift Tests/PINRelayIntegration.swift Discovery/BridgePeer.swift Discovery/BridgeDNSTransport.swift Discovery/BridgeDiscovery.swift -I Discovery/DNSShim -I Pairing/CSPAKE2 -Xcc -I"$PWD/Pairing/BoringSSL/include" Pairing/lib/libcrypto.a -lc++ -o "$APP/Contents/MacOS/ThunderControl" -framework ApplicationServices -framework AppKit -framework CryptoKit -framework IOKit -framework Security -framework LocalAuthentication -framework ServiceManagement -framework UserNotifications -framework SystemConfiguration -framework ScreenCaptureKit -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework AVFoundation -framework CoreImage
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>ThunderControl</string><key>CFBundleIdentifier</key><string>local.experimental.ThunderControl</string><key>CFBundleName</key><string>ThunderControl</string><key>CFBundleIconFile</key><string>ThunderControl.icns</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>0.8.30.13</string><key>CFBundleVersion</key><string>71</string><key>LSMinimumSystemVersion</key><string>13.0</string><key>NSBonjourServices</key><array><string>_thunderctrl._tcp</string></array><key>NSLocalNetworkUsageDescription</key><string>Connect only to a paired Mac over the verified Thunderbolt bridge to share keyboard, pointer input and an automatically resumed extended display with an authenticated peer.</string><key>CFBundleDevelopmentRegion</key><string>en</string><key>CFBundleLocalizations</key><array><string>en</string><string>ko</string></array><key>NSHighResolutionCapable</key><true/></dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $EXPERIMENT_BUILD" "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp DisplaySenderHelper/THIRD_PARTY_NOTICES.txt "$APP/Contents/Resources/DisplaySender-THIRD-PARTY-NOTICES.txt"
cp Assets/ThunderControl.icns "$APP/Contents/Resources/ThunderControl.icns"
cp DevelopmentFailureReasons.json "$APP/Contents/Resources/DevelopmentFailureReasons.json"
cp Assets/ThunderControlMenuBarTemplate.png "$APP/Contents/Resources/ThunderControlMenuBarTemplate.png"
mkdir -p "$APP/Contents/Resources/Licenses"
cp Licenses/* "$APP/Contents/Resources/Licenses/"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp -R Resources/en.lproj Resources/ko.lproj "$APP/Contents/Resources/"
# Remove linker debug/OSO records, which can retain absolute archive paths
# despite source prefix maps. Do this before signing/notarization.
strip -S "$APP/Contents/MacOS/ThunderControl" "$APP/Contents/MacOS/ThunderDisplaySender"
SIGN_ARGS=(--force --options runtime --sign "$SIGNING_IDENTITY")
if [[ "$SIGNING_IDENTITY" != "-" ]]; then SIGN_ARGS+=(--timestamp); fi
codesign "${SIGN_ARGS[@]}" "$APP/Contents/MacOS/ThunderDisplaySender"
codesign "${SIGN_ARGS[@]}" "$APP"
find "$APP" \( -type f -o -type d -o -type l \) -print0 | while IFS= read -r -d '' f; do
  opts=(); if [[ -L "$f" ]];then opts=(-s);fi
  attrs=$(/usr/bin/xattr ${opts[@]+"${opts[@]}"} "$f") || { echo "Attribute verification failed: $f" >&2; exit 1; }
  if printf '%s\n' "$attrs" | grep -qx com.apple.quarantine; then
    /usr/bin/xattr ${opts[@]+"${opts[@]}"} -d com.apple.quarantine "$f" || exit 1
  fi
  attrs=$(/usr/bin/xattr ${opts[@]+"${opts[@]}"} "$f") || { echo "Attribute verification failed: $f" >&2; exit 1; }
  if printf '%s\n' "$attrs" | grep -qx com.apple.quarantine; then echo "Quarantine remains: $f" >&2; exit 1; fi
done
codesign --verify --deep --strict "$APP"
touch "$APP"
"$APP/Contents/MacOS/ThunderControl" --self-test
