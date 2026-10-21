import Foundation
import CoreGraphics

@discardableResult func runDesktopEntryPolicyTests()->Int {
  var failures=0,checks=0
  func check(_ ok:Bool,_ label:String){checks+=1;if !ok{failures+=1;fputs("DesktopEntry: \(label)\n",stderr)}}
  let target=CGRect(x:0,y:0,width:200,height:200),size=CGSize(width:200,height:200)
  let map=ReceiverDesktop(revision:1,mainID:1,displays:[ReceiverDisplay(id:1,bounds:target)])
  for side in DesktopSide.allCases {
    let origin:CGPoint,out:CGVector
    switch side {
    case .left:origin=CGPoint(x:200,y:0);out=CGVector(dx:-1,dy:0)
    case .right:origin=CGPoint(x:-200,y:0);out=CGVector(dx:1,dy:0)
    case .top:origin=CGPoint(x:0,y:200);out=CGVector(dx:0,dy:-1)
    case .bottom:origin=CGPoint(x:0,y:-200);out=CGVector(dx:0,dy:1)
    }
    let rect=CGRect(origin:origin,size:size),portals=map.portals(sourceRect:CGRect(origin:origin,size:size))
    func point(_ distance:CGFloat,_ tangent:CGFloat)->CGPoint {
      switch side {
      case .left:return CGPoint(x:distance,y:tangent)
      case .right:return CGPoint(x:199-distance,y:tangent)
      case .top:return CGPoint(x:tangent,y:distance)
      case .bottom:return CGPoint(x:tangent,y:199-distance)
      }
    }
    for tangent:CGFloat in [0,1,100,198,199] {
      var policy=DesktopEntryPolicy()
      check(policy.candidate(sourceLocal:point(0,tangent),delta:out,sourceRect:rect,portals:portals,held:false)==nil,"initial boundary \(side)")
      _=policy.candidate(sourceLocal:point(2,tangent),delta:.zero,sourceRect:rect,portals:portals,held:false)
      check(policy.candidate(sourceLocal:point(1,tangent),delta:out,sourceRect:rect,portals:portals,held:false)==portals.first,"single outward sample \(side) t=\(tangent)")
      policy.latch(side)
      check(policy.candidate(sourceLocal:point(1,tangent),delta:out,sourceRect:rect,portals:portals,held:false)==nil,"1pt not rearmed")
      _=policy.candidate(sourceLocal:point(2,tangent),delta:.zero,sourceRect:rect,portals:portals,held:false)
      check(policy.candidate(sourceLocal:point(0,tangent),delta:out,sourceRect:rect,portals:portals,held:true)==nil,"held input")
      check(policy.candidate(sourceLocal:point(0,tangent),delta:out,sourceRect:rect,portals:portals,held:false) != nil,"2pt side-only rearm")
    }
    var strict=DesktopEntryPolicy()
    _=strict.candidate(sourceLocal:point(2,100),delta:.zero,sourceRect:rect,portals:portals,held:false)
    check(strict.candidate(sourceLocal:point(2,100),delta:out,sourceRect:rect,portals:portals,held:false)==nil,"outside 1pt strip")
    check(strict.candidate(sourceLocal:point(0,100),delta:.zero,sourceRect:rect,portals:portals,held:false)==nil,"no outward motion")
    check(strict.candidate(sourceLocal:point(0,100),delta:out,sourceRect:rect,portals:[],held:false)==nil,"no portal")
    let split=ReceiverDesktop(revision:2,mainID:1,displays:[ReceiverDisplay(id:1,bounds:(side == .left || side == .right) ? CGRect(x:0,y:50,width:200,height:100):CGRect(x:50,y:0,width:100,height:200))])
    let partial=split.portals(sourceRect:rect)
    check(strict.candidate(sourceLocal:point(0,49),delta:out,sourceRect:rect,portals:partial,held:false)==nil,"strict interval below start")
    check(strict.candidate(sourceLocal:point(0,50),delta:out,sourceRect:rect,portals:partial,held:false) != nil,"inclusive interval start")
    check(strict.candidate(sourceLocal:point(0,150),delta:out,sourceRect:rect,portals:partial,held:false)==nil,"exclusive interval end")
    let gap=map.portals(sourceRect:rect.offsetBy(dx:side == .left ? 1:side == .right ? -1:0,dy:side == .top ? 1:side == .bottom ? -1:0))
    check(gap.isEmpty,"nonadjacent gap has no portal")
    strict.reset(returningThrough:side)
    check(strict.candidate(sourceLocal:point(0,0),delta:CGVector(dx:-1,dy:-1),sourceRect:rect,portals:portals,held:false)==nil,"return corner cannot jump")
#if !DESKTOP_ENTRY_PURE_ONLY
    final class Cursor:CursorRecoveryAPI {
      func associate(_ a:Bool)->CGError {.success}
      func hide(display:CGDirectDisplayID)->CGError {.success}
      func show(display:CGDirectDisplayID)->CGError {.success}
      func warp(to:CGPoint)->CGError {.success}
    }
    let absent=Relay(cursorResources:CursorRecoveryController(api:Cursor()),receiverCursor:CursorVisibilityController(api:Cursor()))
    absent.senderForTests=true;absent.multiDisplayDesktopCompatibleForTests=true
    absent.topologyForTests=DisplayTopologySnapshot(mainID:1,activeIDs:[1],bounds:rect)
    absent.desktopPhysicalInputsForTests={false}
    var absentBegins=0;absent.desktopFocusBeginForTests={_ in absentBegins+=1}
    absent.desktopPrepareEntryForTests(map:map,origin:CGPoint(x:1000,y:1000))
    absent.desktopEntryForTests(point(2,100),delta:.zero,now:1)
    absent.desktopEntryForTests(point(0,100),delta:out,now:2)
    check(absentBegins==0 && !absent.desktopFocusPendingForTests,"Relay no portal cannot begin")
    let partialRelay=Relay(cursorResources:CursorRecoveryController(api:Cursor()),receiverCursor:CursorVisibilityController(api:Cursor()))
    partialRelay.senderForTests=true;partialRelay.multiDisplayDesktopCompatibleForTests=true
    partialRelay.topologyForTests=DisplayTopologySnapshot(mainID:1,activeIDs:[1],bounds:rect)
    partialRelay.desktopPrepareEntryForTests(map:split,origin:origin)
    partialRelay.desktopPhysicalInputsForTests={false}
    var partialBegins=0;partialRelay.desktopFocusBeginForTests={_ in partialBegins+=1}
    partialRelay.desktopEntryForTests(point(2,100),delta:.zero,now:1)
    partialRelay.desktopEntryForTests(point(0,49),delta:out,now:2)
    partialRelay.desktopEntryForTests(point(0,150),delta:out,now:3)
    check(partialBegins==0,"Relay strict half-open interval")
    partialRelay.desktopEntryForTests(point(0,50),delta:out,now:4)
    check(partialBegins==1,"Relay inclusive interval start")
    // Real Relay detector. The hooks replace ONLY physical read/foreground
    // activation; pending and entry buffering are the production path.
    for tangent:CGFloat in [0,1,100,198,199] {
      let r=Relay(cursorResources:CursorRecoveryController(api:Cursor()),receiverCursor:CursorVisibilityController(api:Cursor()))
      r.senderForTests=true;r.multiDisplayDesktopCompatibleForTests=true
      r.topologyForTests=DisplayTopologySnapshot(mainID:1,activeIDs:[1],bounds:rect)
      r.desktopPrepareEntryForTests(map:map,origin:origin)
      var begins=0,physical=false
      r.desktopPhysicalInputsForTests={physical};r.desktopFocusBeginForTests={_ in begins+=1}
      r.desktopEntryForTests(point(0,tangent),delta:out,now:100)
      check(begins==0,"Relay initial boundary blocked \(side)")
      r.desktopEntryForTests(point(2,tangent),delta:.zero,now:100.001)
      r.desktopEntryForTests(point(0,tangent),delta:out,held:true,now:100.002)
      check(begins==0,"Relay held logical input")
      physical=true;r.desktopEntryForTests(point(0,tangent),delta:out,now:100.003)
      check(begins==0,"Relay held physical input")
      physical=false;r.desktopEntryForTests(point(0,tangent),delta:out,now:100.004)
      check(begins==1 && r.desktopFocusPendingForTests && r.desktopEntryStartedForTests==100.004,"Relay begins NOW \(side)")
      check(!r.forward && !r.desktopFocusRemoteForTests,"no input before active")
      _=r.restoreLocal()
      check(r.desktopEntryLatchedSideForTests==side,"return latch binds actual portal side")
      r.desktopEntryForTests(point(0,tangent),delta:out,now:101)
      check(begins==1,"Relay return boundary blocked")
      r.desktopEntryForTests(point(2,tangent),delta:.zero,now:101.001)
      r.desktopEntryForTests(point(0,tangent),delta:out,now:101.002)
      check(begins==2,"Relay near-corner 2pt rearm \(side)")
    }
#endif
  }
  print("DesktopEntryPolicy: \(checks) checks, \(failures) failures")
  return failures
}
