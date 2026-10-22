import Foundation
import AppKit
import CoreGraphics

/// Pure retry reducer. No route, trust, permissions or input APIs live here.
struct AutomaticSharingResume {
  struct Binding:Equatable {let pair:LayoutDevicePair;let inputIsSender:Bool;let host:String}
  private(set) var binding:Binding?
  private(set) var lastBinding:Binding?
  private(set) var blocked=false
  private(set) var attempts=0
  private(set) var nextAttempt=0.0
  mutating func bind(_ value:Binding?) {
    guard value != binding else{return}
    binding=value;if let value {lastBinding=value};attempts=0;nextAttempt=0
  }
  mutating func manualResume(){blocked=false;attempts=0;nextAttempt=0}
  mutating func manualStop(){blocked=true;attempts=0;nextAttempt=0}
  mutating func shouldStart(now:Double,intent:SavedSharingState?,safe:Bool,active:Bool,cleaning:Bool)->Bool {
    guard now.isFinite,let binding,let intent,intent.pair==binding.pair,intent.inputIsSender==binding.inputIsSender,
      intent.valid,intent.videoEnabled,safe,!blocked,!active,!cleaning,now>=nextAttempt else{return false}
    let delays:[Double]=[1,2,4,8,15,15]
    nextAttempt=now+delays[min(attempts,delays.count-1)];attempts=min(attempts+1,delays.count);return true
  }
}

@MainActor extension App {
  func sharingObserveAuthenticatedBinding() {
    // Metadata only: capture the proven pair before a queued disconnect can
    // erase it. Activation remains deferred until input setup has completed.
    guard !isAutomationTest else{return}
    if relay.authenticated,let pair=relay.authenticatedDevicePair,
      let host=relay.authenticatedSharingPeerHost,DisplayPeerRoute.valid(host) {
      sharingResume.bind(.init(pair:pair,inputIsSender:relay.inputIsSender,host:host))
    } else {sharingResume.bind(nil);displayPreferenceLastSent=nil;if displayMode.active {displayMode.stop()}}
  }
  func sharingInputPermitted(pair:LayoutDevicePair,sender:Bool)->Bool {
    if !applicationIsQuitting,!automaticConnectionPaused,!relay.automaticReconnectSuspended,!displayMode.cleaning,!relay.displayTopologyTransitionActive,!relay.hasUnresolvedLocalRecovery,relay.authenticated,relay.authenticatedDevicePair==pair,relay.inputIsSender==sender,relay.sessionAllowed,inputPermissionsReady() {_ = sharingApplyExplicitConnectIntent(pair:pair,sender:sender)}
    guard !applicationIsQuitting,!sharingInputRestoreBlocked,sharingStore.isReadable else{return false}
    guard let saved=sharingStore.load(pair:pair,inputIsSender:sender) else{return true}
    return sender ? saved.inputAuto:saved.receiverConsent
  }
  func sharingCurrentIntent()->SavedSharingState? {
    guard relay.authenticated,let pair=relay.authenticatedDevicePair else{return nil}
    return sharingStore.load(pair:pair,inputIsSender:relay.inputIsSender)
  }
  func sharingSeedCurrentIntent() {
    guard !isAutomationTest,!applicationIsQuitting,!automaticConnectionPaused,
      !sharingInputRestoreBlocked,!sharingResume.blocked,!relay.automaticReconnectSuspended,
      sharingStore.isReadable,relay.authenticated,let pair=relay.authenticatedDevicePair,
      let host=relay.authenticatedSharingPeerHost,DisplayPeerRoute.valid(host),
      relay.sessionAllowed,!relay.sessionLockedSignal,!relay.screenSleeping,!relay.systemSleeping,
      !relay.hasUnresolvedLocalRecovery,inputPermissionsReady(),
      !relay.displayTopologyTransitionActive,!displayMode.cleaning else{return}
    // A proven live peer, not a discovered/stored address, adopts always-on
    // input and video intent once. Actual capture still requires the existing
    // screen-recording permission and topology/session guards in restoreTick.
    // Saved OFF records and manual/emergency stop latches always win.
    let existing=sharingStore.load(pair:pair,inputIsSender:relay.inputIsSender)
    if var initial=sharingStore.seedAuthenticatedDefaults(pair:pair,inputIsSender:relay.inputIsSender),
      existing==nil,relay.inputIsSender,
      let preferred=UserDefaults.standard.object(forKey:"ThunderControl.virtualDisplayPreferred") as? Bool {
      initial.videoEnabled=preferred;sharingStore.save(initial)
    }
  }
  func sharingUserChangedInput() {
    guard !isAutomationTest,!applicationIsQuitting else{return}
    let binding=sharingResume.lastBinding
    guard let pair=relay.authenticatedDevicePair ?? binding?.pair else{return}
    let sender=relay.authenticated ? relay.inputIsSender:(binding?.inputIsSender ?? false)
    guard (mode.selectedSegment==0)==sender else{return}
    var state=sharingStore.load(pair:pair,inputIsSender:sender) ?? .authenticatedDefault(pair:pair,inputIsSender:sender)
    state.inputAuto=sender && automatic.state == .on
    state.inputForward=sender && !state.inputAuto && forward.state == .on
    state.receiverConsent = !sender && enable.state == .on
    sharingStore.save(state);sharingResume.manualResume();sharingInputRestoreBlocked=false
  }
  func sharingUserRequestedVideo(sending:Bool) {
    guard !sharingAutomaticVideoStart,!isAutomationTest,!applicationIsQuitting,relay.authenticated,
      let pair=relay.authenticatedDevicePair,relay.inputIsSender == !sending else{return}
    sharingSeedCurrentIntent()
    var state=sharingCurrentIntent() ?? .firstVideo(pair:pair,inputIsSender:relay.inputIsSender,auto:relay.auto,forward:relay.forward,consent:relay.inject)
    state.videoEnabled=true;state.videoSending=sending;sharingStore.save(state);sharingResume.manualResume()
  }
  func sharingUserStoppedVideo() {
    guard !applicationIsQuitting,!isAutomationTest else{return}
    if var state=sharingCurrentIntent() {state.videoEnabled=false;sharingStore.save(state)}
    // Also handles stop during disconnected cleanup, without guessing a new pair.
    else if let binding=sharingResume.lastBinding,var state=sharingStore.load(pair:binding.pair,inputIsSender:binding.inputIsSender) {state.videoEnabled=false;sharingStore.save(state)}
    sharingResume.manualStop()
  }
  func sharingUserStoppedAll() {
    guard !applicationIsQuitting,!isAutomationTest else{return}
    sharingExplicitResumePending=nil
    sharingInputRestoreBlocked=true
    if let pair=relay.authenticatedDevicePair {sharingStore.save(.off(pair:pair,inputIsSender:relay.inputIsSender))}
    else if let binding=sharingResume.lastBinding {sharingStore.save(.off(pair:binding.pair,inputIsSender:binding.inputIsSender))}
    sharingResume.manualStop()
  }
  func sharingDisplayStatusDidChange() {
    if applicationIsQuitting {
      if !displayMode.active && !displayMode.cleaning {DispatchQueue.main.async {NSApp.terminate(nil)}}
      return
    }
    // Status strings are not evidence of user off. Cleanup and failures preserve intent.
    sharingSeedCurrentIntent()
  }
  func sharingRestoreTick() {
    guard !isAutomationTest,!applicationIsQuitting,!sharingRestoreInProgress else{return}
    sharingRestoreInProgress=true;defer{sharingRestoreInProgress=false}
    guard relay.authenticated,let pair=relay.authenticatedDevicePair,
      let host=relay.authenticatedSharingPeerHost,DisplayPeerRoute.valid(host) else{sharingResume.bind(nil);displayPreferenceLastSent=nil;refreshDisplayPreferenceUI();return}
    sharingResume.bind(.init(pair:pair,inputIsSender:relay.inputIsSender,host:host))
    let safe = !automaticConnectionPaused && !relay.automaticReconnectSuspended && relay.sessionAllowed && !relay.sessionLockedSignal && !relay.screenSleeping && !relay.systemSleeping && !relay.hasUnresolvedLocalRecovery && inputPermissionsReady()
    guard safe else{sharingReportGate(TCText("Sharing paused: check session, permissions or safety stop."));return}
    _ = sharingApplyExplicitConnectIntent(pair:pair,sender:relay.inputIsSender)
    guard !sharingInputRestoreBlocked else{sharingReportGate(TCText("Sharing paused. Stop and reconnect to resume."));return}
    sharingSeedCurrentIntent()
    guard var state=sharingCurrentIntent() else{sharingReportGate(TCText("Sharing preferences unavailable."));return}
    if relay.inputIsSender {
      if let pending=displayPreferencePending {
        if DisplayPreferencePolicy.pendingApplies(expected:displayPreferencePendingPair,current:pair) {
          state.videoEnabled=pending
          if sharingStore.save(state){displayPreferencePending=nil;displayPreferencePendingPair=nil}
        } else {displayPreferencePending=nil;displayPreferencePendingPair=nil}
      }
      if relay.displayPreferenceCompatible {
        if displayPreferenceLastSent?.0 != relay.generation || displayPreferenceLastSent?.1 != state.videoEnabled {
          if relay.sendDisplayPreference(state.videoEnabled) {displayPreferenceLastSent=(relay.generation,state.videoEnabled)}
        }
      }
    }
    refreshDisplayPreferenceUI()
    if !relay.displayTopologyTransitionActive && !displayMode.cleaning {
      if relay.inputIsSender {
        if !state.inputAuto && relay.auto {relay.configureAuto(false,edge:relay.selectedEdge)}
        if !state.inputForward && relay.forward {relay.forward=false;relay.releaseInputs()}
        if state.inputAuto && !relay.auto {relay.restoreSavedSharingAutoIfReady()}
        // Forward's own receiver-ready check remains the Relay's responsibility.
        if state.inputForward && !relay.forward {relay.restoreSavedSharingForwardIfReady()}
      } else if relay.inject != state.receiverConsent {relay.consent(state.receiverConsent)}
    }
    guard DisplayPreferencePolicy.canStart(inputIsSender:relay.inputIsSender,compatible:relay.displayPreferenceCompatible,localIntent:state.videoEnabled,remoteIntent:relay.peerDisplayPreference) else{
      if state.videoEnabled {sharingReportGate(relay.displayPreferenceCompatible ? TCText("Waiting for the Sender display request."):TCText("Automatic virtual display requires 0.8.28 or later on both Macs."))}else{sharingReportGate(nil)};return}
    state.videoEnabled=true // authenticated sender owns video; ignore stale receiver OFF
    let videoSafe=safe && relay.multiDisplayDesktopReady && (!state.videoSending || CGPreflightScreenCaptureAccess())
    sharingReportGate(videoSafe ? nil:TCText("Screen sharing waits for capture permission and desktop readiness."))
    if sharingResume.shouldStart(now:ProcessInfo.processInfo.systemUptime,intent:state,safe:videoSafe,active:displayMode.active,cleaning:displayMode.cleaning) {
      // Current authenticated socket route only, never a stored unrelated host.
      displayPeer.stringValue=host;sharingAutomaticVideoStart=true
      beginDisplay(sending:state.videoSending)
      sharingAutomaticVideoStart=false
    }
  }
}
