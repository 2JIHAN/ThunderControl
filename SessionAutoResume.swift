import AppKit
// A verified session-unlock notification is necessary but insufficient. An
// intervening explicit stop/safety/auth failure changes the epoch and revokes it.
struct SessionAutoResumePermit {
  private(set) var epoch:UInt64?
  private(set) var unlockObserved=false
  mutating func suspend(paused:Bool,suspended:Bool,before:UInt64,after:UInt64) {
    let eligible = !paused && (!suspended || epoch==before)
    epoch=eligible ? after:nil;unlockObserved=false
  }
  mutating func adoptTransition(epoch current:UInt64) {if epoch != current {unlockObserved=false};epoch=current}
  mutating func clearUnlockProof(){unlockObserved=false}
  mutating func armLockedStandby(epoch current:UInt64){adoptTransition(epoch:current)}
  func permitsLockedStandby(paused:Bool,epoch current:UInt64)->Bool {!paused && epoch==current}
  mutating func observedUnlock(){if epoch != nil {unlockObserved=true}}
  mutating func revoke(){epoch=nil;unlockObserved=false}
  func permits(paused:Bool,epoch current:UInt64)->Bool { !paused && unlockObserved && epoch==current }
}
@MainActor extension App {
  var lockedStandbyAutomaticEligible:Bool {
    !automaticConnectionPaused && relay.lockedTransportEligible && (!relay.automaticReconnectSuspended || sessionAutoResume.permitsLockedStandby(paused:automaticConnectionPaused,epoch:relay.automaticSuspensionEpoch))
  }
  func invalidateUnlockEvidenceForNewTransition() {
    lockedTransportUnlockObserved=false;sessionAutoResume.clearUnlockProof()
  }
  func suspendForSessionTransition(_ reason:String,actualScreenLock:Bool=false) {
    // New notification evidence always needs its own unlock proof. Repeated
    // polling within one transition remains idempotent in Relay.
    invalidateUnlockEvidenceForNewTransition()
    if actualScreenLock {relay.transportScreenLockObserved=true}
    automaticSessionVerified=false;relay.sessionLockedSignal=true
    if relay.lockedTransportOnly,relay.lockedTransportEligible {
      relay.suspendAutomaticForSession(.transition)
    } else {relay.sessionBecameUnsafe(reason,origin:.transition)}
    requestAutomaticConnectionTick()
  }
  func observedSessionUnlock(){lockedTransportUnlockObserved=true;sessionAutoResume.observedUnlock();tryResumeAfterVerifiedUnlock()}
  func tryResumeAfterVerifiedUnlock() {
    // Cleanup is not permission to restart: Stop/missing input permission must not leave a stale lock latch.
    if lockedTransportUnlockObserved {
      let fresh=readSystemSessionSnapshot()
      if mayClearSessionLockAfterUnlock(snapshot:fresh,unlockObserved:true,screenSleeping:relay.screenSleeping,systemSleeping:relay.systemSleeping,observersInstalled:relay.safetyObserversInstalled) {
        // Clearing a stale lock display is separate from authorization to
        // restart. Independent Stop/auth failures remain suspended below.
        relay.transportScreenLockObserved=false;relay.sessionLockedSignal=false;lockedTransportUnlockObserved=false
        refreshModeUI()
        if relay.lockedTransportOnly {relay.stop(reason:"Verified unlock: standby keys discarded")}
      }
    }
    guard sessionAutoResume.permits(paused:automaticConnectionPaused,epoch:relay.automaticSuspensionEpoch),
      (!relay.hasSession || relay.lockedTransportOnly),!relay.screenSleeping,!relay.systemSleeping,!relay.hasUnresolvedLocalRecovery,
      inputPermissionsReady(),relay.safetyObserversInstalled else{return}
    let fresh=readSystemSessionSnapshot()
    guard sessionBlockReason(snapshot:fresh,lockedSignal:false,sleeping:false,secureInput:isSystemSecureInputEnabled())==nil else{return}
    if relay.lockedTransportOnly {relay.stop(reason:"Verified unlock: discard standby keys for fresh input authentication")}
    relay.transportScreenLockObserved=false
    relay.sessionLockedSignal=false
    guard relay.currentSessionBlockReason(forceRefresh:true)==nil else{return}
    relay.automaticReconnectSuspended=false
    automaticSessionVerified=true
    reconnectBackoff.reset()
    sessionAutoResume.revoke();nextAutomaticAttempt=0
    connectionLog("Verified session unlock: fresh automatic authentication permitted; old session discarded")
    refreshModeUI();requestAutomaticConnectionTick()
  }
}
func runSessionAutoResumeTests()->Int {
  var p=SessionAutoResumePermit(),f=0
  func check(_ b:Bool){if !b{f+=1}}
  p.suspend(paused:false,suspended:false,before:0,after:1)
  check(!p.permits(paused:false,epoch:1));p.observedUnlock();check(p.permits(paused:false,epoch:1))
  check(!p.permits(paused:true,epoch:1));check(!p.permits(paused:false,epoch:2))
  p.suspend(paused:false,suspended:true,before:1,after:2);p.observedUnlock();check(p.permits(paused:false,epoch:2))
  p.suspend(paused:false,suspended:true,before:3,after:4);p.observedUnlock();check(!p.permits(paused:false,epoch:4))
  p.suspend(paused:true,suspended:false,before:4,after:5);p.observedUnlock();check(!p.permits(paused:false,epoch:5))
  p.revoke();check(!p.permits(paused:false,epoch:5))
  p.adoptTransition(epoch:10);p.observedUnlock()
  p.adoptTransition(epoch:10);check(p.permits(paused:false,epoch:10))
  p.armLockedStandby(epoch:10);check(p.permits(paused:false,epoch:10))
  p.clearUnlockProof();check(!p.permits(paused:false,epoch:10))
  p.observedUnlock();p.adoptTransition(epoch:11);check(!p.permits(paused:false,epoch:11))
  print("Session automatic resume: unlock proof, independent stop epochs, duplicates and pause failures=\(f)")
  return f
}
