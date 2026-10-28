import AppKit
import CryptoKit

@MainActor func runSystemControlRelayTests()->Int {
  var failures=0
  func check(_ ok:Bool,_ label:String){if !ok{failures+=1};print("\(ok ? "PASS":"FAIL") system-key-relay \(label)")}
  do {
    let session=UUID().uuidString,token=UUID().uuidString,key=SymmetricKey(size:.bits256)
    var validator=PeerValidator(senderPeer:true,session:session,systemControlKeysSupported:true)
    for (i,event) in [SystemControlKey(code:0,down:true),SystemControlKey(code:0,down:true,isRepeat:true),SystemControlKey(code:0,down:false)].enumerated() {
      guard let native=event.makeEvent(),let data=native.data else{throw Failure("fixture creation")}
      let wire=Wire(kind:"event",session:session,sequence:UInt64(i+1),raw:14,data:data as Data,token:token)
      let restored=try unseal(seal(wire,key),key)
      try validator.accept(restored)
      check(!allowed(14,true) && validFields(native,14),"raw system events remain globally blocked; typed media accepted")
      do {var old=PeerValidator(senderPeer:true,session:session,next:UInt64(i+1));try old.accept(restored);check(false,"old peer rejects system key")}
      catch{check(true,"old peer rejects system key")}
      do {var reverse=PeerValidator(senderPeer:false,session:session,next:UInt64(i+1),systemControlKeysSupported:true);try reverse.accept(restored);check(false,"wrong direction rejected")}
      catch{check(true,"wrong direction rejected")}
    }
    let unsupported=NSEvent.otherEvent(with:.systemDefined,location:.zero,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,subtype:8,data1:(6<<16)|0xA00,data2:-1)!.cgEvent!
    let bad=Wire(kind:"event",session:session,sequence:1,raw:14,data:unsupported.data! as Data,token:token)
    do {var v=PeerValidator(senderPeer:true,session:session,systemControlKeysSupported:true);try v.accept(bad);check(false,"power key denied")}
    catch {check(true,"power key denied")}
    var ownership=RemoteInputOwnership()
    ownership.accepted(.systemKey(0),down:true,suppressed:true)
    check(!ownership.owned.isEmpty,"suppressed down belongs to source")
    ownership.force()
    check(ownership.blocked && ownership.owned.isEmpty,"disconnect quarantines physical release")
    check(ownership.filter(.systemKey(0),down:true,repeatKey:true),"orphan repeat swallowed locally")
    check(ownership.filter(.systemKey(0),down:false,repeatKey:false) && !ownership.blocked,"matching release drains orphan")
    check(!ownership.filter(.systemKey(0),down:true,repeatKey:false),"new local press unaffected")
    check(Relay.verifySystemControlKeyReceiveForTests(),"actual receiver route rebuilds typed keys; stale token and legacy peer rejected; modifiers preserved; no OS posting")
    check(Relay.verifySystemControlKeyCleanupForTests(),"real cleanup path releases only injected function keys once without OS posting")
  }catch{check(false,"unexpected error")}
  return failures
}
