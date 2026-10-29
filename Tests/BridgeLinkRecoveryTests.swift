import Foundation
import CryptoKit

@MainActor func runBridgeLinkRecoveryTests()->Int {
  var failures=0,checks=0
  func check(_ ok:Bool,_ note:String) {checks+=1;if !ok{failures+=1;print("FAIL bridge recovery: \(note)")}}
  let token=UUID().uuidString,session=UUID().uuidString
  for sender in [false,true] {
    for kind in ["linkReset","linkReady"] {
      let frame=Wire(kind:kind,session:session,sequence:1,token:token)
      var validator=PeerValidator(senderPeer:sender,session:session,bridgeRecoverySupported:true)
      do {try validator.accept(frame);check(validator.next==2,"both directions accept negotiated boundary")}
      catch {check(false,"valid boundary \(error)")}
      var legacy=PeerValidator(senderPeer:sender,session:session)
      do {try legacy.accept(frame);check(false,"legacy must reject extension")} catch {check(legacy.next==1,"legacy sequence unchanged")}
      let mutations:[(inout Wire)->Void] = [{$0.token=nil},{$0.token="bad"},{$0.raw=10},{$0.data=Data([1])},{$0.width=0},{$0.cursorMode=false},{$0.bridgeRecoveryCodec=1},{$0.displayPreference=true},{$0.receiverDesktopMap=Data()},{$0.gestureCodec=0},{$0.desktopGestureTargetID=1}]
      for mutate in mutations {
        var bad=frame;mutate(&bad)
        var v=PeerValidator(senderPeer:sender,session:session,bridgeRecoverySupported:true)
        do {try v.accept(bad);check(false,"invalid field rejected")} catch {check(v.next==1,"rejection does not advance")}
      }
      do {
        let key=SymmetricKey(size:.bits256)
        var v=PeerValidator(senderPeer:sender,session:session,bridgeRecoverySupported:true)
        let restored=try unseal(seal(frame,key),key);try v.accept(restored)
        do {try v.accept(restored);check(false,"replay rejected")} catch {check(v.next==2,"replay preserves next")}
      } catch {check(false,"authenticated round trip")}
    }
  }
  var state=BridgeInputRecovery()
  state.begin(local:true,now:10)
  check(state.suspended && state.makeRequest()==nil,"no reset before fresh active proof")
  state.proveActive();let request=state.makeRequest()!
  check(state.makeRequest()==nil,"only one ordered request")
  check(!state.acceptReply(token,now:11) && state.suspended,"unrelated acknowledgement ignored")
  check(!state.finishIfReady(),"cannot resume before own acknowledgement")
  check(state.acceptReply(request,now:11) && state.finishIfReady() && !state.suspended,"matching boundary resumes")
  check(!state.acceptReply(request,now:11),"late duplicate ignored")
  state.begin(local:true,now:20);state.proveActive();let expired=state.makeRequest()!
  check(!state.acceptReply(expired,now:24) && !state.valid(now:24),"four second cleanup deadline is strict")
  state.begin(local:true,now:23)
  check(state.deadline==24,"repeated flap cannot extend cleanup deadline")
  for invalid in [Double.nan,Double.infinity,-Double.infinity,-1] {check(!state.valid(now:invalid),"invalid clock rejected")}
  var peer=BridgeInputRecovery();peer.receiveRequest(token,now:30)
  check(peer.takeReply()==nil && !peer.finishIfReady(),"peer request needs independent local bridge proof")
  peer.proveActive();check(peer.takeReply()==token && peer.finishIfReady(),"reply precedes resumed input")
  // Both ends can discover the same interruption independently. Neither side
  // waits for the other acknowledgement before sending its own ready boundary.
  var a=BridgeInputRecovery(),b=BridgeInputRecovery()
  a.begin(local:true,now:40);b.begin(local:true,now:40)
  a.proveActive();b.proveActive();let ar=a.makeRequest()!,br=b.makeRequest()!
  a.receiveRequest(br,now:40.1);b.receiveRequest(ar,now:40.1)
  a.proveActive();b.proveActive()
  let aReply=a.takeReply()!,bReply=b.takeReply()!
  check(!a.finishIfReady() && !b.finishIfReady(),"simultaneous recovery remains gated")
  check(a.acceptReply(bReply,now:40.2) && b.acceptReply(aReply,now:40.2),"crossed acknowledgements match")
  check(a.finishIfReady() && b.finishIfReady(),"simultaneous recovery cannot deadlock")
  var slow=BridgeInputRecovery(),fast=BridgeInputRecovery()
  slow.begin(local:true,now:50);fast.begin(local:true,now:50)
  slow.proveActive();fast.proveActive();let slowRequest=slow.makeRequest()!,fastRequest=fast.makeRequest()!
  slow.receiveRequest(fastRequest,now:50.1);fast.receiveRequest(slowRequest,now:50.1)
  fast.proveActive();let earlyReply=fast.takeReply()!
  check(slow.acceptReply(earlyReply,now:50.2) && !slow.finishIfReady(),"early matching reply retained but cannot bypass own proof")
  slow.proveActive();let lateReply=slow.takeReply()!
  check(slow.finishIfReady() && fast.acceptReply(lateReply,now:50.3) && fast.finishIfReady(),"staggered proofs do not lose only acknowledgement")
  var lease=BridgeInputLease();let issued=lease.issue(now:100)
  check(lease.accepts(issued,now:100.349) && !lease.accepts(issued,now:100.351),"receiver local clock bounds delayed input")
  check(!lease.accepts(UUID().uuidString,now:100.1) && !lease.accepts(issued,now:99),"unknown or backward lease rejected")
  lease.receive(issued,now:101)
  check(lease.sourceFresh(now:101.1) && !lease.accepts(issued,now:101.1),"source receipt cannot refresh receiver issued age")
  for i in 0..<1000 {_ = lease.issue(now:Double(i)+200)}
  check(!lease.accepts(issued,now:1200),"bounded challenge history cannot revive old token")
  for kind in BridgeInputLease.inputKinds {
    let packet=Wire(kind:kind,session:session,sequence:1,inputLease:issued)
    check(!BridgeInputRecovery.validEnvelope(packet),"lease does not authorize reset envelope")
  }
  check(Relay.verifyBridgeInputRecoveryForTests(),"production quarantine, held-key release, stale packet discard, exact identity and timeouts")
  print("Bridge link recovery: \(checks) checks, failures=\(failures); no physical cable manipulation or OS input posting")
  return failures
}
