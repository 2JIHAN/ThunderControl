import Foundation
import CoreGraphics
import CryptoKit

/// Drives the actual Relay barrier handlers with fake native snapshots/time/TX.
/// Cursor operations are mocked; no event is constructed, posted, or sent.
@discardableResult func runDesktopMapTransitionTests()->Int {
  final class Cursor:CursorRecoveryAPI {
    var points=[CGPoint]()
    func associate(_ a:Bool)->CGError {.success}
    func hide(display:CGDirectDisplayID)->CGError {.success}
    func show(display:CGDirectDisplayID)->CGError {.success}
    func warp(to:CGPoint)->CGError {points.append(to);return .success}
  }
  var failures=0,checks=0
  func check(_ ok:Bool,_ label:String) {checks+=1;if !ok {failures+=1;fputs("DesktopMapTransition failed: \(label)\n",stderr)}}
  let suite="ThunderControl.DesktopMapTransition."+UUID().uuidString
  let defaults=UserDefaults(suiteName:suite)!
  defer{defaults.removePersistentDomain(forName:suite)}
  func relay(_ sender:Bool=false)->Relay {
    let r=Relay(cursorResources:CursorRecoveryController(api:Cursor()),receiverCursor:CursorVisibilityController(api:Cursor()),layoutStore:SavedScreenLayoutStore(defaults:defaults),desktopPlacementStore:SavedDesktopPlacementStore(defaults:defaults))
    r.senderForTests=sender;r.connectionForTests=OwnedSocket(-1);r.contextForTests=SessionContext(OwnedSocket(-1));r.keyForTests=SymmetricKey(size:.bits256)
    r.desktopEpochForTests={0}
    r.multiDisplayDesktopCompatibleForTests=true;r.concurrentDisplayCompatibleForTests=true
    return r
  }
  let one=ReceiverDisplay(id:1,bounds:CGRect(x:0,y:0,width:1200,height:800))
  let two=ReceiverDisplay(id:2,bounds:CGRect(x:-900,y:0,width:900,height:700))
  let maps=[ReceiverDesktop(revision:1,mainID:1,displays:[one]),ReceiverDesktop(revision:1,mainID:1,displays:[one,two]),ReceiverDesktop(revision:1,mainID:2,displays:[one,two]),ReceiverDesktop(revision:1,mainID:2,displays:[two])]
  let r=relay();var actual:ReceiverDesktop?=maps[0],now=100.0,packets=[Wire]()
  r.desktopMapReadForTests={revision,virtualID in actual.map{ReceiverDesktop(revision:revision,mainID:$0.mainID,displays:$0.displays,virtualDisplayID:virtualID)}}
  r.desktopClockForTests={now};r.desktopEnqueueForTests={packets.append($0);return true}
  r.topologyForTests=DisplayTopologySnapshot(mainID:1,activeIDs:[1],bounds:one.bounds)
  let socket=r.connectionForTests,context=r.contextForTests,generation=r.desktopGenerationForTests,key=r.keyForTests!.withUnsafeBytes{Data($0)}
  check(r.control("available",width:0),"initial publication")
  check(r.desktopPublishedRevisionForTests==1,"first revision")
  for (index,map) in maps.dropFirst().enumerated() {
    actual=map;packets.removeAll()
    check(r.detectDesktopMapForTests(),"map change detected")
    guard let barrier=r.desktopBarrierForTests else {check(false,"barrier exists");continue}
    check(barrier.phase == .awaitingAck,"wait for source drain")
    check(!r.desktopRoutingAllowedForTests,"stale geometry blocked before posting")
    _ = r.control("available",width:0)
    check(packets.map{$0.kind}==["displayPause"],"no background map publication before ACK")
    check(r.desktopPublishedRevisionForTests==UInt64(index+1),"no pre-ACK revision bump")
    r.receiveDesktopBarrierForTests(Wire(kind:"displayPaused",session:r.sessionForTests,sequence:1,token:barrier.token))
    check(r.desktopBarrierForTests==nil,"resumed after two stable reads")
    check(Array(packets.prefix(3)).map{$0.kind}==["displayPause","available","displayResume"],"ordered pause map resume")
    check(packets[1].width==0 && packets[1].receiverDesktopMap != nil,"map published while disabled")
    check(r.topologyForTests?.bounds==map.displays.first(where:{$0.id==map.mainID})?.bounds,"local main bounds not hull")
    check(r.desktopPublishedRevisionForTests==UInt64(index+2),"one bump per changed fingerprint")
    check(r.connectionForTests === socket && r.contextForTests === context && r.desktopGenerationForTests==generation && r.keyForTests!.withUnsafeBytes{Data($0)}==key && context?.cancelled==false,"authenticated identity retained")
    let revision=r.desktopPublishedRevisionForTests
    _ = r.control("available",width:0)
    check(r.desktopPublishedRevisionForTests==revision,"unchanged map no bump")
  }
  // Invalid transient is paused, not disconnected; ACK cannot publish it.
  actual=nil;packets.removeAll();_ = r.detectDesktopMapForTests()
  let transient=r.desktopBarrierForTests!
  r.receiveDesktopBarrierForTests(Wire(kind:"displayPaused",session:r.sessionForTests,sequence:1,token:transient.token))
  check(r.authenticated && r.desktopBarrierForTests?.phase == .paused,"invalid transient preserves authentication")
  actual=maps[0];r.tickDesktopMapForTests()
  check(r.desktopBarrierForTests==nil && r.authenticated,"valid retry resumes")
  // Helper takes ownership of pending map barrier and is the only resumer.
  actual=maps[1];_ = r.detectDesktopMapForTests();let helper=r.desktopBarrierForTests!;var helperReady=false
  r.beginDisplayTopologyTransition {if case .success=$0 {helperReady=true}}
  check(r.desktopBarrierForTests?.token==helper.token,"helper shares nonce and deadline")
  r.receiveDesktopBarrierForTests(Wire(kind:"displayPaused",session:r.sessionForTests,sequence:1,token:helper.token))
  r.tickDesktopMapForTests()
  check(helperReady && r.desktopBarrierForTests?.phase == .paused,"helper prevents automatic resume")
  let baseline=DisplayBaseline(ids:[1,2],active:[1,2],main:1,bounds:one.bounds,rectangles:[one.bounds,two.bounds],mirrors:[0,0])
  r.desktopBaselineReadForTests={baseline}
  do {try r.finishDisplayTopologyRemoval(original:baseline);check(r.desktopBarrierForTests==nil,"helper removal resumes current map")} catch {check(false,"helper removal \(error)")}
  // Source ACK waits for the production local-input drain guard.
  let source=relay(true);var sourceTX=[Wire]()
  source.topologyForTests=DisplayTopologySnapshot(mainID:1,activeIDs:[1],bounds:one.bounds)
  source.desktopSourceReadForTests={source.topologyForTests};source.desktopClockForTests={now};source.desktopEnqueueForTests={sourceTX.append($0);return true}
  source.desktopPhysicalInputsForTests={false}
  source.desktopLocalKeysForTests=[12]
  let token=UUID().uuidString
  source.receiveDesktopBarrierForTests(Wire(kind:"displayPause",session:source.sessionForTests,sequence:1,token:token))
  check(source.desktopBarrierForTests?.phase == .draining && sourceTX.isEmpty,"held source key prevents ACK")
  source.desktopLocalKeysForTests=[];source.tickDesktopMapForTests()
  check(source.desktopBarrierForTests?.phase == .paused && sourceTX.last?.kind=="displayPaused","drained source ACK")
  check(!source.forward && !source.auto,"source paused before map adoption")
  let adoptedData=try! JSONEncoder().encode(maps[1])
  source.receiveControlForTests(Wire(kind:"available",session:source.sessionForTests,sequence:2,width:0,receiverDesktopMap:adoptedData))
  check(source.receiverDesktop?.displays.count==2 && source.desktopBarrierForTests?.phase == .paused,"source adopts while paused")
  source.receiveDesktopBarrierForTests(Wire(kind:"displayResume",session:source.sessionForTests,sequence:3,token:token,width:0))
  check(source.desktopBarrierForTests==nil,"source resumes only after map adoption")
  // A second fresh pause while resuming preserves original mode intent.
  source.auto=true
  let a=UUID().uuidString,b=UUID().uuidString
  source.receiveDesktopBarrierForTests(Wire(kind:"displayPause",session:source.sessionForTests,sequence:4,token:a))
  source.receiveControlForTests(Wire(kind:"available",session:source.sessionForTests,sequence:5,width:0,receiverDesktopMap:try! JSONEncoder().encode(ReceiverDesktop(revision:2,mainID:1,displays:[one,two]))))
  source.desktopLocalKeysForTests=[12]
  source.receiveDesktopBarrierForTests(Wire(kind:"displayResume",session:source.sessionForTests,sequence:6,token:a,width:0))
  check(source.desktopBarrierForTests?.phase == .resuming,"A waits for fresh held key")
  source.receiveDesktopBarrierForTests(Wire(kind:"displayPause",session:source.sessionForTests,sequence:7,token:b))
  check(source.authenticated && source.desktopBarrierForTests?.token==b && source.desktopBarrierForTests?.savedAuto==true && !source.auto,"B keeps original intent without auth close")
  source.desktopLocalKeysForTests=[];source.tickDesktopMapForTests()
  check(sourceTX.last?.kind=="displayPaused" && sourceTX.last?.token==b,"release ACKs B")
  // Epoch flip after fresh map validation cancels before any mock side effect.
  let gated=relay();var epoch:UInt64=1,effects=0
  gated.desktopEpochForTests={epoch};gated.desktopMapReadForTests={rev,_ in ReceiverDesktop(revision:rev,mainID:1,displays:[one])};gated.desktopEnqueueForTests={_ in true}
  _ = gated.control("available",width:0)
  gated.desktopBeforeGateForTests={epoch+=1}
  gated.desktopGateEffectsForTests(post:{effects+=1},warp:{effects+=1},bookkeeping:{effects+=1})
  check(effects==0 && gated.authenticated && gated.desktopBarrierForTests?.phase == .awaitingAck,"epoch invalidation drops posts warp bookkeeping into B")
  for side in [DesktopSide.top,.bottom] {
    let cursor=Cursor(),bounds=CGRect(x:20,y:30,width:200,height:200)
    let stopped=Relay(cursorResources:CursorRecoveryController(api:cursor),receiverCursor:CursorVisibilityController(api:Cursor()))
    stopped.topologyForTests=DisplayTopologySnapshot(mainID:1,activeIDs:[1],bounds:bounds)
    let target=CGRect(x:0,y:0,width:200,height:200),source=CGRect(x:0,y:side == .top ? 200:-200,width:200,height:200)
    let map=ReceiverDesktop(revision:1,mainID:1,displays:[ReceiverDisplay(id:1,bounds:target)])
    let portal=map.portals(sourceRect:source)[0],point=portal.targetPoint(fromSourceEdge:CGPoint(x:75,y:0))
    let expected=DesktopHandoffRouting.localReturn(portal:portal,point:point,bounds:bounds)
    stopped.desktopPrepareStopProjectionForTests(portal:portal,point:point);stopped.stop()
    check(cursor.points.last==expected,"stop preserves \(side) projection until mock warp")
  }
  // Actual source Relay handlers: remote intent survives drain/map/consent and
  // must negotiate a fresh normal portal token before becoming remote again.
  let identity=UUID().uuidString
  let old=ReceiverDesktop(revision:10,mainID:1,displays:[ReceiverDisplay(id:1,bounds:one.bounds,stableIdentity:identity)])
  // Non-16:9 resolution change and translation of the same physical screen.
  let next=ReceiverDesktop(revision:11,mainID:7,displays:[ReceiverDisplay(id:7,bounds:CGRect(x:300,y:100,width:1280,height:1024),stableIdentity:identity)])
  func focused(_ remote:Bool=true)->(Relay,()->[Wire]) {
    let r=relay(true);var tx=[Wire]()
    r.topologyForTests=DisplayTopologySnapshot(mainID:1,activeIDs:[1],bounds:one.bounds)
    r.desktopSourceReadForTests={r.topologyForTests};r.desktopClockForTests={now}
    r.desktopPhysicalInputsForTests={false};r.desktopFocusSafetyForTests={true}
    r.desktopEnqueueForTests={tx.append($0);return true}
    r.desktopFocusBeginForTests={_ in};r.desktopFocusFlushForTests={true}
    if remote {r.desktopPrepareFocusForTests(map:old,origin:CGPoint(x:-1200,y:0),point:CGPoint(x:600,y:400))}
    return (r,{tx})
  }
  func pause(_ r:Relay)->String {
    let t=UUID().uuidString
    r.receiveDesktopBarrierForTests(Wire(kind:"displayPause",session:r.sessionForTests,sequence:1,token:t));return t
  }
  func publish(_ r:Relay,_ map:ReceiverDesktop,_ token:String) {
    r.receiveControlForTests(Wire(kind:"available",session:r.sessionForTests,sequence:2,width:0,receiverDesktopMap:try! JSONEncoder().encode(map)))
    r.receiveDesktopBarrierForTests(Wire(kind:"displayResume",session:r.sessionForTests,sequence:3,token:token,width:0))
    r.receiveControlForTests(Wire(kind:"available",session:r.sessionForTests,sequence:4,width:1,receiverDesktopMap:try! JSONEncoder().encode(map)))
    r.tickDesktopMapForTests()
  }
  let (focus,focusTX)=focused();var restored=0;focus.restoreSourceActivation={restored+=1}
  focus.desktopLocalButtonsForTests=[0]
  let focusToken=pause(focus)
  check(restored==0 && focusTX().isEmpty,"pause defers source app activation and held button ACK")
  focus.desktopLocalButtonsForTests=[];focus.tickDesktopMapForTests()
  check(focusTX().last?.kind=="displayPaused","button release permits ACK")
  publish(focus,next,focusToken)
  check(focus.desktopFocusPendingForTests && !focus.desktopFocusRemoteForTests,"remote-before reenters normal pending, not direct active")
  // The test begin hook deliberately skips foreground scheduling. Drive actual
  // strict begin + ready + active handlers with only cursor/permission hooks.
  // Obtain the freshly negotiated token through the hook on a second barrier.
  var freshToken:String?
  let (active,_)=focused();active.desktopFocusBeginForTests={freshToken=$0}
  let activePause=pause(active);publish(active,next,activePause)
  if let t=freshToken {
    let target=next.displays[0].bounds
    active.receiveControlForTests(Wire(kind:"ready",session:active.sessionForTests,sequence:5,token:t,width:target.width,height:target.height))
    active.receiveControlForTests(Wire(kind:"active",session:active.sessionForTests,sequence:6,token:t))
    check(active.desktopFocusRemoteForTests,"remote-before becomes remote-after fresh ready/active")
    check(active.desktopFocusPointForTests==CGPoint(x:940,y:612),"active validated motion restores relative cursor position")
  } else {check(false,"fresh focus token available")}
  let (local,_)=focused(false);let localPause=pause(local);publish(local,next,localPause)
  check(!local.desktopFocusPendingForTests && !local.desktopFocusRemoteForTests,"local-before stays local")
  let (cancel,_)=focused();let cancelPause=pause(cancel);cancel.configureAuto(false,edge:.right);publish(cancel,next,cancelPause)
  check(!cancel.desktopFocusPendingForTests && !cancel.auto,"explicit manual pause cancels restore")
  let (missing,_)=focused();let missingPause=pause(missing)
  publish(missing,ReceiverDesktop(revision:11,mainID:2,displays:[ReceiverDisplay(id:2,bounds:one.bounds,stableIdentity:UUID().uuidString)]),missingPause)
  check(!missing.desktopFocusPendingForTests,"missing physical display cannot redirect intent")
  let (stale,_)=focused();_ = pause(stale)
  stale.receiveControlForTests(Wire(kind:"available",session:stale.sessionForTests,sequence:2,width:0,receiverDesktopMap:try! JSONEncoder().encode(old)))
  check(stale.desktopBarrierForTests?.phase == .paused && !stale.desktopFocusPendingForTests,"same revision cannot authorize resume")
  let (repeatFocus,_)=focused();var repeatedToken:String?
  repeatFocus.desktopFocusBeginForTests={repeatedToken=$0}
  let firstPause=pause(repeatFocus);publish(repeatFocus,next,firstPause)
  let secondPause=pause(repeatFocus)
  let nextAgain=ReceiverDesktop(revision:12,mainID:7,displays:next.displays)
  publish(repeatFocus,nextAgain,secondPause)
  check(repeatFocus.desktopFocusPendingForTests && repeatedToken != nil,"rapid second pause retains original bounded focus intent")
  let (denied,_)=focused();let deniedPause=pause(denied);denied.desktopFocusSafetyForTests={false};publish(denied,next,deniedPause)
  check(!denied.desktopFocusPendingForTests && !denied.auto,"permission/session gate denies focus restore")
  let gap=ReceiverDesktop(revision:12,mainID:7,displays:[ReceiverDisplay(id:7,bounds:CGRect(x:4000,y:4000,width:1280,height:1024),stableIdentity:identity)])
  check(gap.valid && !gap.contains(CGPoint(x:2000,y:2000)),"desktop gap is not a valid cursor point")
  // Ordinary unmarked follow-through remains remote intent, but is never
  // posted on the source or forwarded while geometry is paused.
  let (follow,followTX)=focused();let followPause=pause(follow)
  check(follow.drainDesktopPauseInput(type:.mouseMoved),"pause consumes mouse follow-through")
  check(follow.drainDesktopPauseInput(type:.keyDown,code:12),"pause quarantines a new key down")
  follow.tickDesktopMapForTests()
  check(follow.drainDesktopPauseInput(type:.keyUp,code:12),"pause consumes matching key release")
  check(follow.drainDesktopPauseInput(type:.leftMouseDown,button:0),"pause quarantines new click")
  check(follow.drainDesktopPauseInput(type:.leftMouseUp,button:0),"pause consumes matching button release")
  check(followTX().allSatisfy{$0.kind=="displayPaused"},"no paused input packets forwarded")
  publish(follow,next,followPause)
  check(follow.desktopFocusPendingForTests,"follow-through does not cancel original remote intent")
  let virtual=ReceiverDisplay(id:2,bounds:CGRect(x:0,y:0,width:1200,height:1024),stableIdentity:UUID().uuidString)
  let physical=ReceiverDisplay(id:7,bounds:CGRect(x:1200,y:800,width:1280,height:1024),stableIdentity:identity)
  let elbow=ReceiverDesktop(revision:12,mainID:7,displays:[virtual,physical],virtualDisplayID:2)
  let sourceRect=CGRect(x:-1200,y:0,width:1200,height:800),physicalPoint=CGPoint(x:1840,y:1312)
  if let route=DesktopMapFocusRoute.make(desktop:elbow,source:sourceRect,target:physicalPoint) {
    check(route.portal.displayID==2 && route.preserved,"L-shape uses virtual portal for physical settings target")
    var p=route.entry
    for waypoint in route.waypoints {
      p=elbow.moved(from:p,delta:CGVector(dx:waypoint.x-p.x,dy:waypoint.y-p.y))
      check(elbow.contains(p),"route waypoint stays on a real display")
    }
    check(hypot(p.x-physicalPoint.x,p.y-physicalPoint.y)<0.001,"edge-connected L-shape reaches saved physical point")
  } else {check(false,"L-shape canonical route exists")}
  let disconnected=ReceiverDesktop(revision:12,mainID:7,displays:[virtual,ReceiverDisplay(id:7,bounds:CGRect(x:4000,y:4000,width:1280,height:1024),stableIdentity:identity)],virtualDisplayID:2)
  if let route=DesktopMapFocusRoute.make(desktop:disconnected,source:sourceRect,target:CGPoint(x:4640,y:4512)) {
    check(!route.preserved && route.portal.displayID==2 && route.waypoints.isEmpty && disconnected.contains(route.entry),"disconnected target resumes at canonical remote entry, not a hole")
  } else {check(false,"disconnected physical target retains valid virtual portal")}
  let oldPair=ReceiverDesktop(revision:10,mainID:1,displays:[virtual,ReceiverDisplay(id:1,bounds:CGRect(x:1200,y:0,width:1200,height:800),stableIdentity:identity)],virtualDisplayID:2)
  let (pairFocus,_)=focused();var pairToken:String?
  pairFocus.desktopPrepareFocusForTests(map:oldPair,origin:sourceRect.origin,point:CGPoint(x:1800,y:400))
  pairFocus.desktopFocusBeginForTests={pairToken=$0}
  let pairPause=pause(pairFocus);publish(pairFocus,elbow,pairPause)
  check(pairFocus.desktopFocusPendingForTests && pairToken != nil,"actual Relay resumes when source portal is virtual and cursor target physical")
  if let t=pairToken {
    pairFocus.receiveControlForTests(Wire(kind:"ready",session:pairFocus.sessionForTests,sequence:5,token:t,width:virtual.bounds.width,height:virtual.bounds.height))
    pairFocus.receiveControlForTests(Wire(kind:"active",session:pairFocus.sessionForTests,sequence:6,token:t))
    check(pairFocus.desktopFocusRemoteForTests && pairFocus.desktopFocusPointForTests==physicalPoint,"actual Relay L-route restores physical settings cursor")
  }
  let intent=DesktopMapFocusIntent(desktop:old,point:CGPoint(x:600,y:400),now:now)!
  check(intent.target(in:next)==CGPoint(x:940,y:612),"stable identity relative point follows non-16:9 bounds")
  check(intent.target(in:old)==nil,"intent refuses stale revision")
  // Missing ACK fails closed at the original monotonic 12-second deadline.
  actual=maps[2];_ = r.detectDesktopMapForTests();now += 12.01;r.tickDesktopMapForTests()
  check(!r.authenticated && r.desktopGenerationForTests != generation,"missing ACK timeout fails closed")
  print("DesktopMapTransition: \(checks) checks, \(failures) failures")
  return failures
}
