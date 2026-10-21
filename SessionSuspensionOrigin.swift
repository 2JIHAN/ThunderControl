import Foundation

// Only confirmed lock/sleep/login-session transitions are automatically
// recoverable. Ordinary foreground loss, Secure Input and all explicit safety
// failures stay independent, even if a lock happens shortly afterwards.
enum SessionSuspensionOrigin: Equatable {case independent,transition}
func mayAdoptSessionTransition(suspended:Bool,origin:SessionSuspensionOrigin)->Bool {
  !suspended || origin == .transition
}
// Cleanup never enables input. Secure Input remains a separate resume gate.
func mayClearSessionLockAfterUnlock(snapshot:SessionSafetySnapshot,unlockObserved:Bool,screenSleeping:Bool,systemSleeping:Bool,observersInstalled:Bool)->Bool {
  !screenSleeping && verifiedStandbyUnlock(snapshot:snapshot,unlockObserved:unlockObserved,systemSleeping:systemSleeping,secureInput:false,observersInstalled:observersInstalled)
}
func runSessionSuspensionOriginTests()->Int {
  var n=0,f=0;func check(_ b:Bool){n+=1;if !b{f+=1}}
  for suspended in [false,true] {for origin:SessionSuspensionOrigin in [.independent,.transition] {
    check(mayAdoptSessionTransition(suspended:suspended,origin:origin) == (!suspended || origin == .transition))
  }}
  let values:[Bool?]=[nil,false,true]
  for console in values {for login in values {for locked in values {
    for unlocked in [false,true] {for screenSleep in [false,true] {for systemSleep in [false,true] {for installed in [false,true] {
      let snapshot=SessionSafetySnapshot(onConsole:console,loginDone:login,screenLocked:locked)
      check(mayClearSessionLockAfterUnlock(snapshot:snapshot,unlockObserved:unlocked,screenSleeping:screenSleep,systemSleeping:systemSleep,observersInstalled:installed) == (unlocked && installed && !screenSleep && !systemSleep && console==true && login==true && locked != true))
    }}}}
  }}}
  print("Session suspension/unlock cleanup: \(n) memory assertions, \(f) failures; independent stops never adopted")
  return f
}
