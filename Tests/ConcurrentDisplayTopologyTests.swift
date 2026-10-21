import Foundation
import CoreGraphics
func runConcurrentDisplayTests()->Int {
  var failures=0
  func check(_ value:Bool,_ note:String="unlabeled"){if !value {failures+=1;fputs("ConcurrentDisplay check failed: \(note)\n",stderr)}}
  check(Relay.verifyConcurrentTemporaryLayoutForTests(),"temporary layout")
  let physical=CGRect(x:0,y:0,width:1440,height:900),extensionRect=CGRect(x:1440,y:0,width:1920,height:1080)
  let original=DisplayBaseline(ids:[1,3],active:[1],main:1,bounds:physical,rectangles:[physical,physical],mirrors:[0,1])
  let current=DisplayBaseline(ids:[1,2,3],active:[1,2],main:1,bounds:physical,rectangles:[physical,extensionRect,physical],mirrors:[0,0,1])
  do {
    let lease=try ConcurrentDisplayLease(original:original,current:current,ownedID:2)
    // Topology bounds union the whole desktop including mirrors mapped to main.
    // The old build pinned bounds to the extension rectangle alone, which
    // misrepresented the authenticated input coordinate space.
    let expectedUnion=physical.union(extensionRect)
    check(lease.topology.bounds==expectedUnion,"topology union covers desktop")
    check(lease.topology.mainID==original.main,"topology main stays original")
    check(lease.matches(current),"lease matches accepted baseline")
    check(!lease.matches(original),"lease does not match pre-extension baseline")
    check(Relay.verifyConcurrentDisplayIdentityForTests(lease),"identity adoption preserves transport")
    // Peripheral display rearrangement must not break the authenticated link.
    let rearranged=DisplayBaseline(ids:[1,2,3],active:[1,2],main:1,bounds:physical,rectangles:[physical,extensionRect,CGRect(x:1,y:0,width:1440,height:900)],mirrors:[0,0,1])
    check(lease.matches(rearranged),"peripheral rearrangement tolerated")
    check(lease.rearranged(from:rearranged),"rearrangement signalled for revision bump")
    check(!lease.rearranged(from:current),"identical baseline not reported as rearranged")
    // Lease creation still succeeds with rearranged peripheral display; only
    // mirror pattern + owned ID presence are protocol invariants.
    do {_ = try ConcurrentDisplayLease(original:original,current:rearranged,ownedID:2)}catch{check(false,"lease create tolerates peripheral rearrangement")}
    // Removing the owned ID (helper vanished) must fail match.
    let withoutOwned=DisplayBaseline(ids:[1,3],active:[1],main:1,bounds:physical,rectangles:[physical,physical],mirrors:[0,1])
    check(!lease.matches(withoutOwned),"owned ID removal breaks match")
    // Physical mirror changes are native layout changes, not peer changes.
    let mirrorChanged=DisplayBaseline(ids:[1,2,3],active:[1,2],main:1,bounds:physical,rectangles:[physical,extensionRect,physical],mirrors:[0,0,0])
    check(lease.matches(mirrorChanged),"physical mirror change permitted")
    let third=CGRect(x:3360,y:0,width:1000,height:900)
    let added=DisplayBaseline(ids:[1,2,3,4],active:[1,2,4],main:1,bounds:physical,rectangles:[physical,extensionRect,physical,third],mirrors:[0,0,1,0])
    check(lease.matches(added),"physical display addition accepted")
    let newMain=CGRect(x:0,y:0,width:1000,height:900),ownedLeft=CGRect(x:-1920,y:0,width:1920,height:1080)
    let removed=DisplayBaseline(ids:[2,4],active:[2,4],main:4,bounds:newMain,rectangles:[ownedLeft,newMain],mirrors:[0,0])
    check(lease.matches(removed),"physical removal and changed main accepted")
    var monitor=OwnedDisplayMonitor()
    check(monitor.observe(current,ownedID:2,now:0) == .ready,"video monitor starts ready")
    check(monitor.observe(removed,ownedID:2,now:1) == .ready,"video monitor keeps stream after original display removal")
    check(monitor.observe(nil,ownedID:2,now:2) == .waiting,"video enumeration transient waits")
    check(monitor.observe(nil,ownedID:2,now:6.9) == .waiting,"bounded invalid does not stop early")
    check(monitor.observe(added,ownedID:2,now:7) == .ready,"native recovery resets invalid timer")
    check(monitor.observe(nil,ownedID:2,now:8) == .waiting,"new invalid interval starts fresh")
    check(monitor.observe(nil,ownedID:2,now:13) == .expired,"persistent invalid owned screen stops video")
    let ownedMirrorRoot=DisplayBaseline(ids:[1,2,3],active:[2],main:2,bounds:extensionRect,rectangles:[extensionRect,extensionRect,extensionRect],mirrors:[2,0,2])
    check(ownedMirrorRoot.supported && !lease.matches(ownedMirrorRoot),"owned mirror root is not a valid capture lease")
    let secondaryMirrorGroup=DisplayBaseline(ids:[1,2,3,4],active:[1,2,3],main:1,bounds:physical,rectangles:[physical,extensionRect,third,third],mirrors:[0,0,0,3])
    check(secondaryMirrorGroup.supported,"secondary physical mirror group supported")
    check(lease.matches(secondaryMirrorGroup),"secondary mirror group does not revoke lease")
    let mirrorCycle=DisplayBaseline(ids:[1,2,3,4],active:[1,2],main:1,bounds:physical,rectangles:[physical,extensionRect,third,third],mirrors:[0,0,4,3])
    check(!mirrorCycle.supported,"mirror cycle rejected")
    let duplicate=DisplayBaseline(ids:[1,1],active:[1],main:1,bounds:physical,rectangles:[physical,physical],mirrors:[0,0])
    check(!duplicate.supported,"duplicate identities rejected")
    // Owned ID mirroring something is rejected at construction.
    let ownedMirrors=DisplayBaseline(ids:[1,2,3],active:[1,2],main:1,bounds:physical,rectangles:[physical,extensionRect,physical],mirrors:[0,1,1])
    do {_ = try ConcurrentDisplayLease(original:original,current:ownedMirrors,ownedID:2);check(false,"owned ID mirror rejected")}catch{}
    // Owned ID overlapping original main bounds remains rejected.
    let overlapping=DisplayBaseline(ids:[1,2,3],active:[1,2],main:1,bounds:physical,rectangles:[physical,CGRect(x:100,y:100,width:1920,height:1080),physical],mirrors:[0,0,1])
    do {_ = try ConcurrentDisplayLease(original:original,current:overlapping,ownedID:2);check(false,"owned overlap rejected")}catch{}
  }catch{failures+=1;fputs("lease create unexpectedly threw: \(error)\n",stderr)}
  let session=UUID().uuidString,token=UUID().uuidString
  func rejects(_ w:Wire,sender:Bool,supported:Bool=true)->Bool {
    var p=PeerValidator(senderPeer:sender,session:session,concurrentDisplaySupported:supported)
    do {try p.accept(w);return false}catch{return p.next==1}
  }
  for kind in ["displayPause","displayPaused","displayResume"] {
    let sender=kind=="displayPaused",packet=Wire(kind:kind,session:session,sequence:1,token:token,width:kind=="displayResume" ? 1:nil)
    var validator=PeerValidator(senderPeer:sender,session:session,concurrentDisplaySupported:true)
    do {try validator.accept(packet);check(validator.next==2,"\(kind) accepted");do{try validator.accept(packet);check(false,"\(kind) replay rejected")}catch{}}catch{failures+=1}
    check(rejects(packet,sender:!sender),"\(kind) wrong role rejected")
    check(rejects(packet,sender:sender,supported:false),"\(kind) unsupported rejected")
    var bad=packet;bad.session=UUID().uuidString;check(rejects(bad,sender:sender),"\(kind) wrong session")
    bad=packet;bad.token="invalid";check(rejects(bad,sender:sender),"\(kind) bad token")
    bad=packet;bad.raw=10;check(rejects(bad,sender:sender),"\(kind) non-nil raw")
    bad=packet;bad.width=kind=="displayResume" ? 2:1;check(rejects(bad,sender:sender),"\(kind) bad width")
    if kind=="displayResume" {
      bad=packet;bad.width=nil;check(rejects(bad,sender:sender),"displayResume width required")
      bad=packet;bad.width=0;check(!rejects(bad,sender:sender),"displayResume width=0 accepted")
      bad=packet;bad.width = .nan;check(rejects(bad,sender:sender),"displayResume NaN width")
    }
    bad=packet;bad.concurrentDisplayCodec=1;check(rejects(bad,sender:sender),"\(kind) codec rejected on bar")
    // Receiver desktop map must never piggyback on a barrier packet.
    bad=packet;bad.receiverDesktopMap=Data("x".utf8);check(rejects(bad,sender:sender),"\(kind) desktop map rejected")
  }
  var cache=ConcurrentDisplayNonceCache()
  for _ in 0..<300 {let nonce=UUID().uuidString;check(!cache.contains(nonce));cache.insert(nonce);check(cache.contains(nonce));check(cache.recent.count<=128)}
  cache.removeAll();check(cache.recent.isEmpty,"nonce cache cleared")
  print("Concurrent display ownership lease, physical add/remove/main/mirror change, strict owned identity and barrier tests failures=\(failures); no input/network/capture/keychain effects")
  return failures
}
