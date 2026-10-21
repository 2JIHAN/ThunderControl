import Foundation
/// Observations must come from full bridge("bridge0") validation, never from an OS hint alone.
struct VerifiedBridgeRecoveryState {
  private var lastVerified:String?
  private(set) var revision:UInt64=0
  mutating func observe(_ signature:String?)->Bool {
    revision &+= 1
    let recovered=signature != nil && signature != lastVerified
    lastVerified=signature
    return recovered
  }
  mutating func observe(_ signature:String?,after expectedRevision:UInt64)->Bool {
    guard revision==expectedRevision else{return false}
    return observe(signature)
  }
}
func automaticRetryDeadline(sending:Bool,attempt:Double,discovery:Double,now:Double)->Double? {
  let candidates=sending ? [attempt,discovery]:[attempt]
  return candidates.filter{$0.isFinite && $0>now}.min()
}
func runBridgeRecoverySchedulingTests()->Int {
  var checks=0,failures=0
  func check(_ ok:Bool){checks+=1;if !ok{failures+=1}}
  var state=VerifiedBridgeRecoveryState()
  check(!state.observe(nil));check(!state.observe(nil));check(state.observe("verified-A"))
  for _ in 0..<20 {check(!state.observe("verified-A"))}
  check(!state.observe(nil));check(state.observe("verified-A"))
  check(state.observe("verified-B"));check(!state.observe("verified-B"))
  let older=state.revision
  check(!state.observe("verified-B"))
  let newer=state.revision
  check(!state.observe(nil,after:older));check(state.revision==newer)
  check(!state.observe("verified-B"))
  let live=state.revision
  check(!state.observe(nil,after:live))
  check(!state.observe("verified-B",after:live))
  check(state.observe("verified-B",after:state.revision))
  check(!state.observe("verified-B"))
  check(automaticRetryDeadline(sending:true,attempt:5,discovery:0,now:2)==5)
  check(automaticRetryDeadline(sending:true,attempt:5,discovery:8,now:4)==5)
  check(automaticRetryDeadline(sending:false,attempt:8,discovery:5,now:4)==8)
  check(automaticRetryDeadline(sending:true,attempt:0,discovery:0,now:4)==nil)
  check(automaticRetryDeadline(sending:true,attempt:3,discovery:9,now:4)==9)
  check(automaticRetryDeadline(sending:true,attempt:Double.nan,discovery:Double.infinity,now:4)==nil)
  for mask in 0..<128 {
    let safe=automaticConnectionMayStart(configured:mask&1 != 0,paused:mask&2 != 0,suspended:mask&4 != 0,permissions:mask&8 != 0,sessionSafe:mask&16 != 0,recovery:mask&32 != 0,hasSession:mask&64 != 0)
    check(safe == (mask==25))
  }
  print("Bridge recovery/exact retry: \(checks) checks, \(failures) failures; repeated hints do not reset cooldown; all safety gates retained")
  return failures
}
