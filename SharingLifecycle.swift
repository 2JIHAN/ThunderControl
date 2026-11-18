import Foundation
import AppKit

@MainActor extension App {
  @objc func resumeInputSharing() {
    guard relay.authenticated,let pair=relay.authenticatedDevicePair,
      !applicationIsQuitting,!automaticConnectionPaused,!relay.automaticReconnectSuspended,
      !displayMode.cleaning,!relay.displayTopologyTransitionActive,!relay.hasUnresolvedLocalRecovery,
      !relay.bridgeInputSuspended,relay.sessionAllowed,!relay.sessionLockedSignal,
      !relay.screenSleeping,!relay.systemSleeping,inputPermissionsReady() else{return}
    sharingDidStartExplicitConnection(sending:relay.inputIsSender)
    guard sharingApplyExplicitConnectIntent(pair:pair,sender:relay.inputIsSender) else{return}
    sharingRestoreTick();refreshModeUI()
  }
  func sharingAuthenticatedInputIntent(pair:LayoutDevicePair,sender:Bool)->SavedSharingState? {
    guard relay.authenticated,relay.authenticatedDevicePair==pair,relay.inputIsSender==sender,
      !applicationIsQuitting,!automaticConnectionPaused,!sharingInputRestoreBlocked,
      !relay.automaticReconnectSuspended,!displayMode.cleaning,!relay.displayTopologyTransitionActive,
      !relay.hasUnresolvedLocalRecovery,!relay.bridgeInputSuspended,relay.sessionAllowed,
      !relay.sessionLockedSignal,!relay.screenSleeping,!relay.systemSleeping,
      (!displayMode.active || displayMode.inputReadyAfterRecovery),
      (relay.desktopInputPermissionForTests?() ?? inputPermissionsReady()),sharingStore.isReadable else{return nil}
    let existing=sharingStore.load(pair:pair,inputIsSender:sender)
    var state=existing ?? .authenticatedDefault(pair:pair,inputIsSender:sender)
    if existing==nil,sender,let preferred=sharingNewPairVideoPreference() {state.videoEnabled=preferred}
    state=state.enablingInputForAuthenticatedRole()
    guard existing==state || sharingStore.save(state) else{return nil}
    return state
  }
  func sharingPrepareRoleChange() {sharingExplicitResumePending=nil;sharingDeferredExplicitResume=nil}
  func sharingDidStartExplicitConnection(sending:Bool) {
    sharingDeferredExplicitResume=nil;sharingExplicitResumePending=(relay.generation,sending)
  }
  func sharingDeferExplicitConnection(pair:LayoutDevicePair,sender:Bool) {
    sharingExplicitResumePending=nil;sharingDeferredExplicitResume=(pair,sender)
  }
  @discardableResult func sharingApplyExplicitConnectIntent(pair:LayoutDevicePair,sender:Bool)->Bool {
    guard relay.authenticated,relay.authenticatedDevicePair==pair,relay.inputIsSender==sender else{return false}
    if let deferred=sharingDeferredExplicitResume {
      guard deferred.pair==pair,deferred.sender==sender,
        !applicationIsQuitting,!automaticConnectionPaused,!relay.automaticReconnectSuspended,
        !displayMode.cleaning,!relay.displayTopologyTransitionActive,!relay.hasUnresolvedLocalRecovery,
        !relay.bridgeInputSuspended,relay.sessionAllowed,!relay.sessionLockedSignal,
        !relay.screenSleeping,!relay.systemSleeping,
        (relay.desktopInputPermissionForTests?() ?? inputPermissionsReady()) else{return false}
      sharingDidStartExplicitConnection(sending:sender)
    }
    guard let request=sharingExplicitResumePending,request.generation==relay.generation,
      request.sender==sender,sharingStore.isReadable else{return false}
    let existing=sharingStore.load(pair:pair,inputIsSender:sender)
    var state=existing ?? .authenticatedDefault(pair:pair,inputIsSender:sender)
    if existing==nil,sender,let preferred=sharingNewPairVideoPreference() {state.videoEnabled=preferred}
    // Explicit Connect resumes input, never silently overrides a saved video OFF.
    state.inputAuto=sender;state.inputForward=false;state.receiverConsent = !sender
    guard sharingStore.save(state) else{return false}
    sharingExplicitResumePending=nil;sharingInputRestoreBlocked=false;sharingResume.manualResume()
    return true
  }
  func sharingReportGate(_ reason:String?,details:String?=nil) {
    sharingBlockedReason=reason
    let text="gate=\(reason ?? "ready") inputBlocked=\(sharingInputRestoreBlocked) videoBlocked=\(sharingResume.blocked) paused=\(automaticConnectionPaused) suspended=\(relay.automaticReconnectSuspended) "+relay.sharingReadinessSummary+(details.map{" "+$0} ?? "")
    if text != sharingLastGateDiagnostic {sharingLastGateDiagnostic=text;connectionLog("Sharing startup "+text)}
    updateConnectionState()
  }
}
