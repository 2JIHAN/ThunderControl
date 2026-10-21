import Foundation
import CoreGraphics
import CryptoKit

// Shared production routing and authenticated schema only. No input is posted.
func runDesktopSystemGestureTests()->Int {
  var failures=0,checks=0
  func check(_ value:Bool,_ note:String){checks+=1;if !value{failures+=1;fputs("DesktopSystemGesture: "+note+"\n",stderr)}}
  let session=UUID().uuidString,token=UUID().uuidString,stream=UUID().uuidString
  let map=ReceiverDesktop(revision:7,mainID:11,displays:[
    ReceiverDisplay(id:11,bounds:CGRect(x:0,y:0,width:1920,height:1080)),
    ReceiverDisplay(id:99,bounds:CGRect(x:-1512,y:-945,width:1512,height:945))],virtualDisplayID:99)
  let p=CGPoint(x:-400,y:-300)
  let d=DockGestureDescriptor(motion:2,phase:1,progress:0,velocityX:0,velocityY:0)
  let base=Wire(kind:"dock",session:session,sequence:1,token:token,dock:d,dockID:stream)
  guard let bound=DesktopSystemGestureTarget.attach(base,desktop:map,revision:7,point:p) else{return 1}
  check(bound.desktopGestureTargetID==99,"virtual rather than physical target")
  let target=DesktopSystemGestureTarget.resolve(bound,desktop:map,revision:7,previous:p)
  check(target==DesktopSystemGestureTarget(revision:7,displayID:99),"exact revision and target")
  check(DesktopSystemGestureTarget.resolve(bound,desktop:map,revision:8,previous:p)==nil,"stale revision")
  check(DesktopSystemGestureTarget.resolve(bound,desktop:map,revision:7,previous:CGPoint(x:-401,y:-300))==nil,"cannot relocate pointer by gesture")
  var altered=bound;altered.desktopGestureTargetID=11
  check(DesktopSystemGestureTarget.resolve(altered,desktop:map,revision:7,previous:p)==nil,"wrong display")
  altered=bound;altered.desktopGlobalX = .nan
  check(DesktopSystemGestureTarget.resolve(altered,desktop:map,revision:7,previous:p)==nil,"nonfinite point")
  check(DesktopSystemGestureTarget.attach(base,desktop:map,revision:7,point:CGPoint(x:2200,y:1500))==nil,"gap/outside rejected")
  check(DesktopSystemGestureTarget.attach(base,desktop:map,revision:7,point:CGPoint(x:-1,y:0))==nil,"half-open edge outside")
  if let target {
    check(DesktopSystemGestureTarget.continues(phase:1,requested:target,current:nil),"first begin")
    check(!DesktopSystemGestureTarget.continues(phase:1,requested:target,current:target),"duplicate begin")
    for phase in [2,4,8] {
      check(DesktopSystemGestureTarget.continues(phase:phase,requested:target,current:target),"bound continuation")
      check(!DesktopSystemGestureTarget.continues(phase:phase,requested:target,current:nil),"no begin")
      check(!DesktopSystemGestureTarget.continues(phase:phase,requested:target,current:.init(revision:7,displayID:11)),"no cross-display continuation")
      check(!DesktopSystemGestureTarget.continues(phase:phase,requested:target,current:.init(revision:8,displayID:99)),"no cross-map continuation")
    }
    check(!DesktopSystemGestureTarget.continues(phase:9,requested:target,current:target),"unknown phase")
  }
  func accepts(_ w:Wire,mapMode:Bool=true,newCodec:Bool=true,sender:Bool=true)->Bool {
    var validator=PeerValidator(senderPeer:sender,session:session,multiDisplayDesktopSupported:mapMode,desktopGesturesSupported:newCodec)
    do {try validator.accept(w);return validator.next==2}catch{return false}
  }
  check(accepts(bound),"new negotiated gesture envelope")
  check(!accepts(bound,newCodec:false),"old peer cannot receive new coordinates")
  check(!accepts(bound,mapMode:false),"map capability required")
  check(!accepts(bound,sender:false),"wrong role")
  check(!accepts(base),"new map mode never falls back to untargeted gestures")
  check(accepts(base,mapMode:false,newCodec:false),"legacy one-screen behavior preserved")
  for field in 0..<5 {
    var malformed=bound
    switch field {case 0:malformed.desktopGestureTargetID=nil;case 1:malformed.desktopMapRevision=nil;case 2:malformed.desktopGlobalX=nil;case 3:malformed.desktopGlobalY=nil;default:malformed.desktopGestureTargetID=0}
    check(!accepts(malformed),"incomplete targeted envelope")
  }
  altered=bound;altered.desktopGestureCodec=1
  check(!accepts(altered),"no renegotiation during stream")
  altered=bound;altered.kind="ping"
  check(!accepts(altered),"target only on system gesture")
  for motion in [1,2] {for phase in [1,2,4,8] {
    var w=bound;w.dock=DockGestureDescriptor(motion:motion,phase:phase,progress:0.25,velocityX:0.5,velocityY:0.5)
    check(accepts(w),"horizontal/vertical lifecycle")
  }}
  do {
    let key=SymmetricKey(size:.bits256),cipher=try seal(bound,key),received=try unseal(cipher,key)
    check(received.desktopGestureTargetID==99 && received.desktopMapRevision==7 && received.desktopGlobalX == -400,"AEAD preserves target binding")
    check(accepts(received),"authenticated schema")
  }catch{check(false,"AEAD round trip")}

  // Actual receive(...) -> receiveDockGesture(...) path, not only pure helpers.
  // Native permission/build/post effects are replaced; map and epoch checks run.
  let receiver=Relay()
  receiver.connectionForTests=OwnedSocket(-1);receiver.contextForTests=SessionContext(OwnedSocket(-1));receiver.keyForTests=SymmetricKey(size:.bits256)
  receiver.safetyObserversInstalled=true
  receiver.desktopEnqueueForTests={_ in true}
  receiver.gestureTrace.setEnabled(false)
  var epoch:UInt64=0,posted=[CGPoint](),built=[DockGestureDescriptor]()
  receiver.desktopEpochForTests={epoch};receiver.desktopMapReadForTests={_,_ in map}
  receiver.desktopSystemGesturePermissionForTests={true}
  receiver.desktopSystemGestureBuildForTests={built.append($0);return CGEvent(source:nil)}
  receiver.desktopSystemGesturePostForTests={event in posted.append(event.location)}
  receiver.prepareDesktopSystemGestureForTests(map:map,point:p,token:token,negotiated:false)
  receiver.receive(bound);check(posted.isEmpty,"actual receiver rejects absent capability")
  receiver.prepareDesktopSystemGestureForTests(map:map,point:p,token:token)
  receiver.receive(bound);check(posted==[p],"actual receiver reaches bound output instead of blanket return")
  for phase in [2,4] {var w=bound;w.dock=DockGestureDescriptor(motion:2,phase:phase,progress:-0.25,velocityX:0,velocityY:-1);receiver.receive(w)}
  check(posted.count==3 && posted.allSatisfy{$0==p},"actual full stream stays on virtual target")
  check(built.count==3 && built.last?.progress==0.25 && built.last?.velocityY==1,"existing vertical projection preserved")
  receiver.prepareDesktopSystemGestureForTests(map:map,point:p,token:token)
  var wrong=bound;wrong.desktopGestureTargetID=11
  receiver.receive(wrong);check(posted.count==3,"actual wrong target rejected")
  receiver.desktopBeforeGateForTests={epoch+=1}
  receiver.receive(bound);check(posted.count==3,"actual epoch change blocks output at final gate")
  receiver.desktopBeforeGateForTests=nil
  receiver.contextForTests?.cancel(reason:"DesktopSystemGesture memory fixture end")
  print("Desktop system gesture routing: \(checks) checks, \(failures) failures; no input/window/network/keychain")
  return failures
}
