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
    let back=DesktopHandoffRouting.reversePoint(portal:portal,previous:entry,delta:delta,held:false)
    check(back != nil,"reverse crossing \(side)")
    check(DesktopHandoffRouting.reversePoint(portal:portal,previous:entry,delta:delta,held:true)==nil,"held input return blocked")
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
  print("DesktopHandoffRouting: \(checks) checks, \(failures) failures")
  return failures
}
