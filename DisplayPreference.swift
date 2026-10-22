import Foundation
import AppKit
import CoreGraphics

/// Negotiated intent has no host or identity; routing uses the live authenticated socket.
enum DisplayPreferencePolicy {
  static func validEnvelope(_ w:Wire)->Bool {
    guard w.kind=="displayPreference",w.displayPreference != nil,
      let data=try? JSONEncoder().encode(w),data.count<=256,
      let json=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else{return false}
    return Set(json.keys)==Set(["kind","session","sequence","displayPreference"])
  }
  static func pendingApplies(expected:LayoutDevicePair?,current:LayoutDevicePair)->Bool {expected==nil || expected==current}
  static func senderControlVisible(selectedRole:Int)->Bool {selectedRole==0}
  static func canStart(inputIsSender:Bool,compatible:Bool,localIntent:Bool,remoteIntent:Bool?)->Bool {
    compatible && (inputIsSender ? localIntent:remoteIntent==true)
  }
}
@MainActor extension App {
  func refreshDisplayPreferenceUI() {
    let sender=mode.selectedSegment==0
    displayPreferenceToggle.isHidden = !DisplayPreferencePolicy.senderControlVisible(selectedRole:mode.selectedSegment)
    let saved=sharingCurrentIntent()?.videoEnabled
    let preferred=UserDefaults.standard.object(forKey:"ThunderControl.virtualDisplayPreferred") as? Bool ?? true
    displayPreferenceToggle.state=(displayPreferencePending ?? saved ?? preferred) ? .on:.off
    displayPreferenceToggle.isEnabled = !applicationIsQuitting && (!relay.authenticated || relay.inputIsSender)
    displayPreferenceToggle.toolTip=TCText("Uses the connected Mac automatically. Both Macs require 0.8.28 or later.")
    let requested=relay.inputIsSender ? displayPreferenceToggle.state == .on:relay.peerDisplayPreference==true
    displayStatus.isHidden = !displayMode.active && !displayMode.cleaning && (!relay.authenticated || !requested)
    screenPermissionButton.isHidden=sender || relay.peerDisplayPreference != true || CGPreflightScreenCaptureAccess()
    if relay.authenticated && !relay.displayPreferenceCompatible {displayStatus.stringValue=TCText("Automatic virtual display requires 0.8.28 or later on both Macs.")}
  }
  @objc func toggleVirtualDisplay() {
    guard mode.selectedSegment==0,!applicationIsQuitting else{return}
    let enabled=displayPreferenceToggle.state == .on
    UserDefaults.standard.set(enabled,forKey:"ThunderControl.virtualDisplayPreferred")
    displayPreferencePending=enabled;displayPreferencePendingPair=relay.authenticatedDevicePair
    if enabled {if !sharingInputRestoreBlocked {sharingResume.manualResume()}} else {sharingUserStoppedVideo();displayMode.stop()}
    sharingRestoreTick()
  }
  func sharingReceivedDisplayPreference(_ enabled:Bool) {
    guard relay.authenticated,!relay.inputIsSender,relay.displayPreferenceCompatible else{return}
    // Remote intent never clears emergency/manual-stop safety latches.
    if !enabled {displayMode.stop()}
    sharingRestoreTick()
  }
}
