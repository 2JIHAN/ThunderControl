import Foundation
import CoreGraphics

// Calls the exact pure adapters used by Relay. No sockets, OS input posting,
// cursor warps, keychain, or permission changes.
@discardableResult func runDesktopHandoffRoutingTests()->Int {
  var failures=0,checks=0
  func check(_ value:Bool,_ label:String){checks+=1;if !value{failures+=1;fputs("Desktop routing: \(label)\n",stderr)}}
  let target=CGRect(x:-600,y:-400,width:400,height:300)
  let desktop=ReceiverDesktop(revision:7,mainID:1,displays:[ReceiverDisplay(id:1,bounds:target)])
  let session=UUID().uuidString,token=UUID().uuidString
  for side in DesktopSide.allCases {
    let origin:CGPoint,delta:CGVector
    switch side {
    case .left:origin=CGPoint(x:target.maxX,y:target.minY);delta=CGVector(dx:12,dy:0)
    case .right:origin=CGPoint(x:target.minX-200,y:target.minY);delta=CGVector(dx:-12,dy:0)
    case .top:origin=CGPoint(x:target.minX,y:target.maxY);delta=CGVector(dx:0,dy:12)
    case .bottom:origin=CGPoint(x:target.minX,y:target.minY-200);delta=CGVector(dx:0,dy:-12)
    }
    let source=CGRect(origin:origin,size:CGSize(width:200,height:200))
    guard let portal=desktop.portals(sourceRect:source).first(where:{$0.sourceSide==side}) else{check(false,"portal \(side)");continue}
    let previewScreen=CGRect(x:-1100,y:700,width:target.width,height:target.height)
    let geometry=ReturnBoundaryGeometry(portal:portal,point:CGPoint(x:target.midX,y:target.midY),screenFrame:previewScreen)
    let opposite:DesktopSide
    switch side {case .left:opposite = .right;case .right:opposite = .left;case .top:opposite = .bottom;case .bottom:opposite = .top}
    check(geometry.targetEdge==opposite,"overlay target opposite source \(side)")
    check(previewScreen.contains(geometry.frame),"overlay negative global coordinates contained \(side)")
    check(min(geometry.frame.width,geometry.frame.height)<=26 && max(geometry.frame.width,geometry.frame.height)<=140,"overlay bounded \(side)")
    switch side {
    case .left:check(geometry.frame.maxX==previewScreen.maxX,"right target edge")
    case .right:check(geometry.frame.minX==previewScreen.minX,"left target edge")
    case .top:check(geometry.frame.minY==previewScreen.minY,"CG bottom becomes AppKit bottom")
    case .bottom:check(geometry.frame.maxY==previewScreen.maxY,"CG top becomes AppKit top")
    }
    check(ReturnBoundaryGeometry.stretch(-1)==0 && ReturnBoundaryGeometry.stretch(10_000)*25<26,"bounded distance rubberband")
    check(ReturnBoundaryGeometry.stretch(10)<ReturnBoundaryGeometry.stretch(100),"distance changes visual depth")
    let tangent=(portal.intervalStart+portal.intervalEnd)/2
    let edgePoint=(side == .left || side == .right) ? CGPoint(x:origin.x,y:tangent):CGPoint(x:tangent,y:origin.y)
    let entry=portal.targetPoint(fromSourceEdge:edgePoint)
    var begin=DesktopHandoffRouting.beginFrame(session:session,token:token,portal:portal,entry:entry,revision:7)
    check(DesktopHandoffRouting.portal(begin,desktop:desktop,publishedRevision:7)==portal,"canonical \(side)")
    var validator=PeerValidator(senderPeer:true,session:session,multiDisplayDesktopSupported:true)
    begin.sequence=1
    do{try validator.accept(begin);check(true,"begin envelope")}catch{check(false,"begin envelope \(error)")}
    var bad=begin;bad.desktopPortalIntervalEnd=portal.intervalEnd+1
    check(DesktopHandoffRouting.portal(bad,desktop:desktop,publishedRevision:7)==nil,"interval alteration")
    bad=begin;bad.desktopPortalTargetOriginX=target.minX+1
    check(DesktopHandoffRouting.portal(bad,desktop:desktop,publishedRevision:7)==nil,"target alteration")
    bad=begin;bad.desktopMapRevision=nil
    check(DesktopHandoffRouting.portal(bad,desktop:desktop,publishedRevision:7)==nil,"missing begin revision")
    bad=begin;bad.desktopGlobalX=target.midX;bad.desktopGlobalY=target.midY
    check(DesktopHandoffRouting.portal(bad,desktop:desktop,publishedRevision:7)==nil,"non-edge entry")
    let inward=CGVector(dx:-delta.dx,dy:-delta.dy)
    let moved=DesktopHandoffRouting.moved(entry,delta:inward,desktop:desktop)
    check(desktop.contains(moved),"move containment")
    var event=Wire(kind:"event",session:session,sequence:2,raw:5,data:Data([1]),token:token,desktopMapRevision:7,desktopGlobalX:moved.x,desktopGlobalY:moved.y)
    check(DesktopHandoffRouting.eventPoint(event,desktop:desktop,revision:7,previous:entry,delta:inward,moving:true)==moved,"movement map \(side)")
    event.desktopMapRevision=6
    check(DesktopHandoffRouting.eventPoint(event,desktop:desktop,revision:7,previous:entry,delta:inward,moving:true)==nil,"stale revision")
    event.desktopMapRevision=nil
    check(DesktopHandoffRouting.point(event,desktop:desktop,revision:7)==nil,"missing event revision")
    event.desktopMapRevision=7;event.desktopGlobalX=entry.x;event.desktopGlobalY=entry.y
    check(DesktopHandoffRouting.eventPoint(event,desktop:desktop,revision:7,previous:entry,delta:inward,moving:true)==nil,"stale point")
    event.raw=22
    check(DesktopHandoffRouting.eventPoint(event,desktop:desktop,revision:7,previous:entry,delta:.zero,moving:false)==entry,"scroll location")
    event.raw=10
    check(DesktopHandoffRouting.eventPoint(event,desktop:desktop,revision:7,previous:entry,delta:.zero,moving:false)==entry,"key location")
    let approach=CGPoint(x:entry.x-delta.dx/2,y:entry.y-delta.dy/2)
    check(abs(DesktopHandoffRouting.outwardDistance(portal:portal,previous:approach,delta:delta)-6)<1e-8,"only true boundary overshoot counted \(side)")
    check(DesktopHandoffRouting.outwardDistance(portal:portal,previous:approach,delta:.zero)==0,"inbound travel not visual distance \(side)")
    let back=DesktopHandoffRouting.reversePoint(portal:portal,previous:entry,delta:delta,held:false)
    check(back != nil,"reverse crossing \(side)")
    check(DesktopHandoffRouting.reversePoint(portal:portal,previous:entry,delta:delta,held:true)==nil,"held input return blocked")
    let key=DesktopReturnPressure.Key(boundary:.desktop(portal),token:token,session:session,revision:7,epoch:1)
    var pressure:DesktopReturnPressure?
    func push(_ time:Double,_ candidate:DesktopReturnPressure.Key? = key)->Bool {
      DesktopReturnPressure.advance(&pressure,key:candidate,now:time)
    }
    check(!push(0),"first hit never returns \(side)")
    check(!push(0.01),"fast swipe never returns \(side)")
    check(!push(0.10) && !push(0.20) && !push(0.249),"sustained pressure below threshold \(side)")
    check(push(0.250),"continuous outward pressure returns \(side)")
    pressure=nil
    check(!push(1) && !push(1.151),"gap restarts episode \(side)")
    check(!push(1.25) && !push(1.35),"gap cannot count old pressure \(side)")
    check(push(1.41),"fresh episode after gap \(side)")
    for label in ["inward", "tangent", "no reverse", "non-move", "held input"] {
      pressure=nil
      check(!push(2) && !push(2.1) && !push(2.2),"prepare reset \(label)")
      check(!push(2.25,nil) && pressure==nil,"reset \(label)")
      check(!push(2.3) && !push(2.4) && !push(2.5),"no inherited dwell \(label)")
    }
    for changed in [
      DesktopReturnPressure.Key(boundary:.desktop(portal),token:UUID().uuidString,session:session,revision:7,epoch:1),
      DesktopReturnPressure.Key(boundary:.desktop(portal),token:token,session:session,revision:8,epoch:1),
      DesktopReturnPressure.Key(boundary:.desktop(portal),token:token,session:session,revision:7,epoch:2),
      DesktopReturnPressure.Key(boundary:.desktop(portal),token:token,session:UUID().uuidString,revision:7,epoch:1),
      DesktopReturnPressure.Key(boundary:.desktop(DesktopPortal(sourceSide:portal.sourceSide,displayID:portal.displayID+1,intervalStart:portal.intervalStart,intervalEnd:portal.intervalEnd,sourceRect:portal.sourceRect,targetRect:portal.targetRect)),token:token,session:session,revision:7,epoch:1)
    ] {
      pressure=nil;_ = push(3);_ = push(3.1);_ = push(3.2)
      check(!push(3.3,changed) && pressure?.startedAt==3.3,"identity change restarts episode \(side)")
    }
    var small:DesktopReturnPressure?,large:DesktopReturnPressure?
    for time in [0.0,0.05,0.1,0.2,0.249] {
      let smallReturn=DesktopReturnPressure.advance(&small,key:key,now:time,distance:1)
      let largeReturn=DesktopReturnPressure.advance(&large,key:key,now:time,distance:1e100)
      check(!smallReturn && !largeReturn,"distance cannot accelerate return \(side)")
    }
    check(small?.outwardDistance==5 && large?.outwardDistance==10_000,"bounded cumulative episode distance")
    check(ReturnBoundaryGeometry.stretch(small!.outwardDistance)<ReturnBoundaryGeometry.stretch(large!.outwardDistance),"same time different distance different visual")
    check(DesktopReturnPressure.advance(&small,key:key,now:0.250,distance:1) && DesktopReturnPressure.advance(&large,key:key,now:0.250,distance:1e100),"identical exact 250ms return regardless of distance")
    _ = DesktopReturnPressure.advance(&large,key:key,now:1,distance:900)
    _ = DesktopReturnPressure.advance(&large,key:key,now:1.151,distance:2)
    check(large?.outwardDistance==2,"gap resets visual distance")
    _ = DesktopReturnPressure.advance(&large,key:nil,now:1.2,distance:900)
    check(large==nil,"reset clears visual distance")
    pressure=nil;_ = push(4)
    check(!push(40),"stationary elapsed time does not return \(side)")
    let localBounds=CGRect(x:100,y:200,width:200,height:200)
    let local=DesktopHandoffRouting.localReturn(portal:portal,point:back ?? entry,bounds:localBounds)
    check(ReceiverDesktop.has(localBounds,local),"return within source CG bounds")
    switch side {
    case .left:check(local.x==localBounds.minX,"left return")
    case .right:check(abs(local.x-localBounds.maxX)<0.001,"right return")
    case .top:check(local.y==localBounds.minY,"top return")
    case .bottom:check(abs(local.y-localBounds.maxY)<0.001,"bottom return")
    }
    let outside=(side == .left || side == .right) ? CGPoint(x:entry.x,y:portal.intervalEnd):CGPoint(x:portal.intervalEnd,y:entry.y)
    check(DesktopHandoffRouting.reversePoint(portal:portal,previous:outside,delta:delta,held:false)==nil,"half-open return interval")
  }
  var spring=ReturnBoundarySpring(position:0.2,velocity:1.3,target:0.8,startedAt:10)
  for (time,target) in [(10.07,0.95),(10.12,0.0),(10.16,0.6),(10.21,0.0)] {
    let old=spring.sample(at:time)
    let next=spring.retarget(target,at:time)
    let sampled=next.sample(at:time)
    check(abs(old.position-sampled.position)<1e-12 && abs(old.velocity-sampled.velocity)<1e-12,"exact retarget/reversal/release x-v continuity")
    spring=next
  }
  let normalReturn=ReturnBoundarySpring(position:0.8,velocity:0,target:0,startedAt:0)
  let slowReturn=ReturnBoundarySpring(position:0.8,velocity:0,target:0,startedAt:0,responseScale:1.2)
  check(abs(normalReturn.sample(at:0.2).position-slowReturn.sample(at:0.24).position)<1e-12,"return curve takes 20 percent longer")
  let slowed=spring.retarget(0,at:10.25,responseScale:1.2)
  let oldMotion=spring.sample(at:10.25),slowMotion=slowed.sample(at:10.25)
  check(abs(oldMotion.position-slowMotion.position)<1e-12 && abs(oldMotion.velocity-slowMotion.velocity)<1e-12,"slower return preserves position and velocity")
  check(abs(slowed.animation(key:"transform.scale.x").duration-0.78)<1e-12,"return keyframes use slower duration")
  let resumed=slowed.retarget(0.8,at:10.3,responseScale:1)
  check(resumed.responseScale==1 && abs(resumed.sample(at:10.3).velocity-slowed.sample(at:10.3).velocity)<1e-12,"pushing resumes original speed without velocity reset")
  let map=ReceiverDesktop(revision:7,mainID:1,displays:[ReceiverDisplay(id:1,bounds:CGRect(x:0,y:0,width:200,height:200)),ReceiverDisplay(id:2,bounds:CGRect(x:200,y:0,width:200,height:200)),ReceiverDisplay(id:3,bounds:CGRect(x:600,y:0,width:200,height:200))])
  let portal=map.portals(sourceRect:CGRect(x:-200,y:0,width:200,height:200))[0]
  let p=CGPoint(x:199,y:100),d=CGVector(dx:10,dy:0)
  check(DesktopHandoffRouting.moved(p,delta:d,desktop:map)==CGPoint(x:209,y:100),"internal edge traversed")
  check(DesktopHandoffRouting.reversePoint(portal:portal,previous:p,delta:d,held:false)==nil,"internal edge never return")
  let gap=Wire(kind:"event",session:session,sequence:1,desktopMapRevision:7,desktopGlobalX:500,desktopGlobalY:100)
  check(DesktopHandoffRouting.point(gap,desktop:map,revision:7)==nil,"union gap rejected")
  let joined=ReceiverDesktop(revision:9,mainID:1,displays:[ReceiverDisplay(id:1,bounds:CGRect(x:0,y:0,width:200,height:200)),ReceiverDisplay(id:2,bounds:CGRect(x:0,y:200,width:200,height:200))])
  let original=CGRect(x:-200,y:0,width:200,height:400)
  let p1=CGPoint(x:0,y:100),p2=CGPoint(x:0,y:300),out=CGVector(dx:-10,dy:0)
  check(DesktopHandoffRouting.reverse(desktop:joined,sourceRect:original,previous:p1,delta:out,held:true)==nil,"receiver local held key blocks first predicted crossing")
  if let actual=DesktopHandoffRouting.reverse(desktop:joined,sourceRect:original,previous:p2,delta:out,held:false) {
    check(actual.0.displayID==2,"entry D1 exits D2 canonical portal")
    var w=DesktopHandoffRouting.returnFrame(session:session,token:token,portal:actual.0,point:actual.1,revision:9)
    check(DesktopHandoffRouting.returnPortal(w,desktop:joined,revision:9,sourceRect:original)==actual.0,"authoritative later P2")
    var receiverValidator=PeerValidator(senderPeer:false,session:session,multiDisplayDesktopSupported:true);w.sequence=1
    do{try receiverValidator.accept(w);check(true,"receiver authoritative envelope")}catch{check(false,"return envelope \(error)")}
    var senderValidator=PeerValidator(senderPeer:true,session:session,multiDisplayDesktopSupported:true)
    do{try senderValidator.accept(w);check(false,"sender must not claim return")}catch{check(true,"receiver only return")}
    check(DesktopHandoffRouting.returnPortal(w,desktop:joined,revision:8,sourceRect:original)==nil,"stale return revision")
    check(DesktopHandoffRouting.returnPortal(w,desktop:joined,revision:9,sourceRect:original.offsetBy(dx:1,dy:0))==nil,"exact original source rect")
    w.desktopPortalIntervalEnd=399
    check(DesktopHandoffRouting.returnPortal(w,desktop:joined,revision:9,sourceRect:original)==nil,"malformed return interval")
  } else{check(false,"D2 return exists")}
  check(Relay.verifyDesktopReturnPressureForTests(),"actual Relay posted-event return policy")
  print("DesktopHandoffRouting: \(checks) checks, \(failures) failures")
  return failures
}
