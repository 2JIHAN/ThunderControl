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
  func sharingPrepareRoleChange() {sharingExplicitResumePending=nil}
  func sharingDidStartExplicitConnection(sending:Bool) {sharingExplicitResumePending=(relay.generation,sending)}
  @discardableResult func sharingApplyExplicitConnectIntent(pair:LayoutDevicePair,sender:Bool)->Bool {
    guard relay.authenticated,relay.authenticatedDevicePair==pair,relay.inputIsSender==sender,
      let request=sharingExplicitResumePending,request.generation==relay.generation,
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
  func sharingReportGate(_ reason:String?) {
    sharingBlockedReason=reason
    let text="gate=\(reason ?? "ready") inputBlocked=\(sharingInputRestoreBlocked) videoBlocked=\(sharingResume.blocked) paused=\(automaticConnectionPaused) suspended=\(relay.automaticReconnectSuspended) "+relay.sharingReadinessSummary
    if text != sharingLastGateDiagnostic {sharingLastGateDiagnostic=text;connectionLog("Sharing startup "+text)}
    updateConnectionState()
  }
}
