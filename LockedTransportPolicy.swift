import Foundation
func lockedTransportSessionAllowed(snapshot:SessionSafetySnapshot,lockedSignal:Bool,systemSleeping:Bool,observersInstalled:Bool)->Bool {
  observersInstalled && !systemSleeping && snapshot.onConsole==true && snapshot.loginDone==true && (lockedSignal || snapshot.screenLocked==true)
}
func lockedTransportOutgoingAllowed(_ w:Wire)->Bool {
  guard w.raw==nil,w.data==nil,w.token==nil,w.edge==nil,w.y==nil,w.layoutY==nil else{return false}
  return w.kind=="ping" || (w.kind=="available" && w.width==0)
}
func verifiedStandbyUnlock(snapshot:SessionSafetySnapshot,unlockObserved:Bool,systemSleeping:Bool,secureInput:Bool,observersInstalled:Bool)->Bool {
  unlockObserved && observersInstalled && sessionBlockReason(snapshot:snapshot,lockedSignal:false,sleeping:systemSleeping,secureInput:secureInput)==nil
}
func runLockedTransportPolicyTests()->Int {
  var n=0,f=0;func check(_ ok:Bool){n+=1;if !ok{f+=1}}
  let values:[Bool?]=[nil,false,true]
  for console in values {for login in values {for locked in values {for latch in [false,true] {for sleep in [false,true] {for observed in [false,true] {
    let s=SessionSafetySnapshot(onConsole:console,loginDone:login,screenLocked:locked)
    check(lockedTransportSessionAllowed(snapshot:s,lockedSignal:latch,systemSleeping:sleep,observersInstalled:observed)==(observed && !sleep && console==true && login==true && (latch || locked==true)))
  }}}}}}
  for console in values {for login in values {for locked in values {for unlocked in [false,true] {for sleep in [false,true] {for secure in [false,true] {for observed in [false,true] {
    let s=SessionSafetySnapshot(onConsole:console,loginDone:login,screenLocked:locked)
    check(verifiedStandbyUnlock(snapshot:s,unlockObserved:unlocked,systemSleeping:sleep,secureInput:secure,observersInstalled:observed)==(unlocked && observed && !sleep && console==true && login==true && locked != true))
  }}}}}}}
  for kind in ["event","begin","commit","active","return","returnAck","dock","appGesture","cursorMode","cancel"] {check(!lockedTransportOutgoingAllowed(Wire(kind:kind,session:"test",sequence:1)))}
  check(lockedTransportOutgoingAllowed(Wire(kind:"ping",session:"test",sequence:1)))
  check(lockedTransportOutgoingAllowed(Wire(kind:"available",session:"test",sequence:1,width:0)))
  check(!lockedTransportOutgoingAllowed(Wire(kind:"available",session:"test",sequence:1,width:1)))
  var permit=SessionAutoResumePermit()
  permit.armLockedStandby(epoch:4)
  check(permit.permitsLockedStandby(paused:false,epoch:4))
  check(!permit.permitsLockedStandby(paused:true,epoch:4))
  check(!permit.permitsLockedStandby(paused:false,epoch:5))
  check(!permit.permits(paused:false,epoch:4))
  permit.observedUnlock();check(permit.permits(paused:false,epoch:4))
  permit.revoke();check(!permit.permitsLockedStandby(paused:false,epoch:4))
  check(!shouldSuspendAutomaticReconnect(stage:"Trusted pairing",error:TrustedPairingError.keychainUnavailable,terminalReason:nil))
  check(shouldSuspendAutomaticReconnect(stage:"Trusted pairing",error:TrustedPairingError.failed,terminalReason:nil))
  print("Locked transport policy: \(n) checks, \(f) failures; no event capture/injection")
  return f
}
