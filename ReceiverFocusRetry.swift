import Foundation
// One hide episode gets at most two requests. Unsettled OS activation/restoration
// never consumes a request and never permits another activation. No OS effects.
struct ReceiverFocusRetryPolicy {
  private(set) var attempts=0
  private var nextAttempt:TimeInterval=0
  mutating func begin(now:TimeInterval,unsettled:Bool)->Bool {
    guard now.isFinite,!unsettled,attempts<2,now>=nextAttempt else{return false}
    attempts+=1
    return true
  }
  mutating func failed(now:TimeInterval) {nextAttempt=now.isFinite ? now+0.5:.infinity}
  mutating func reset(){attempts=0;nextAttempt=0}
}
func runReceiverFocusRetryTests()->Int {
  var p=ReceiverFocusRetryPolicy(),failures=0
  func check(_ b:Bool){if !b{failures+=1}}
  check(!p.begin(now:1,unsettled:true));check(p.attempts==0)
  check(p.begin(now:1,unsettled:false));p.failed(now:2)
  check(!p.begin(now:2.49,unsettled:false));check(!p.begin(now:3,unsettled:true));check(p.attempts==1)
  check(p.begin(now:3,unsettled:false));p.failed(now:4)
  check(!p.begin(now:100,unsettled:false));p.reset();check(p.begin(now:100,unsettled:false))
  p.reset();check(!p.begin(now:.nan,unsettled:false));check(!p.begin(now:.infinity,unsettled:false))
  print("Receiver focus retry: bounded attempts, cooldown, unsettled debt and episode reset failures=\(failures); memory-only")
  return failures
}
