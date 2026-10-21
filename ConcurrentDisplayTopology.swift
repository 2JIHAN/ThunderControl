import Foundation
import CoreGraphics

/// Owns one helper display identity, not the user's complete desktop layout.
/// Actual input coordinates are validated using the revisioned ReceiverDesktop.
struct ConcurrentDisplayLease {
  let original:DisplayBaseline
  let accepted:DisplayBaseline
  let ownedID:CGDirectDisplayID
  let topology:DisplayTopologySnapshot
  init(original:DisplayBaseline,current:DisplayBaseline,ownedID:CGDirectDisplayID)throws {
    guard current.preserves(original,adding:ownedID),
      let map=current.desktop(revision:1,virtualID:ownedID),map.valid else{throw Failure("Unrecognized owned display")}
    self.original=original;accepted=current;self.ownedID=ownedID
    // Compatibility metadata only; new-mode injection never treats the hull
    // (which can contain holes) as an input rectangle.
    topology=DisplayTopologySnapshot(mainID:current.main,activeIDs:current.active,bounds:map.bounds)
  }
  func matches(_ actual:DisplayBaseline)->Bool {
    // Another physical display, main selection, mirror group or origin can
    // change. Only this owned non-mirrored display's continued identity matters.
    actual.desktop(revision:1,virtualID:ownedID) != nil
  }
  func rearranged(from actual:DisplayBaseline)->Bool {matches(actual) && actual != accepted}
}

/// Separate protocol transaction state, never a topology validation bypass.
struct ConcurrentDisplayBarrier {
  enum Phase {case awaitingAck,draining,paused,resuming}
  let token:String
  var phase:Phase
  let deadline:Double
  var savedConsent:Bool
  var savedAuto:Bool
  var savedForward:Bool
  init(token:String=UUID().uuidString,phase:Phase,now:Double,consent:Bool=false,auto:Bool=false,forward:Bool=false) {
    self.token=token;self.phase=phase;deadline=now+12;savedConsent=consent;savedAuto=auto;savedForward=forward
  }
}

/// Bounded recent-nonce cache. Wire sequence checks already reject replayed frames.
/// Normal long-lived sessions must not exhaust a lifetime transaction budget.
struct ConcurrentDisplayNonceCache {
  private(set) var recent:[String]=[]
  func contains(_ token:String)->Bool {recent.contains(token)}
  mutating func insert(_ token:String){if recent.count==128{recent.removeFirst()};recent.append(token)}
  mutating func removeAll(){recent.removeAll()}
}

/// A pause is not a new user request. Keep only the already-active physical
/// target and normalized position; never reinterpret a missing screen as hull space.
struct DesktopMapFocusIntent {
  let identity:String
  let relative:CGPoint
  let revision:UInt64
  let deadline:Double
  init?(desktop:ReceiverDesktop,point:CGPoint,now:Double) {
    guard let display=desktop.displays.first(where:{ReceiverDesktop.has($0.bounds,point)}),
      let identity=display.stableIdentity else{return nil}
    self.identity=identity;revision=desktop.revision;deadline=now+12
    relative=CGPoint(x:(point.x-display.bounds.minX)/display.bounds.width,y:(point.y-display.bounds.minY)/display.bounds.height)
  }
  func target(in desktop:ReceiverDesktop)->CGPoint? {
    let matches=desktop.displays.filter{$0.stableIdentity==identity}
    guard desktop.valid,desktop.revision>revision,matches.count==1,let display=matches.first else{return nil}
    let b=display.bounds
    let p=CGPoint(x:min(b.maxX.nextDown,b.minX+relative.x*b.width),y:min(b.maxY.nextDown,b.minY+relative.y*b.height))
    return ReceiverDesktop.has(b,p) ? p:nil
  }
}

/// At most eight real screens. Every crossing uses an overlapping edge,
/// never a union rectangle or a diagonal jump across an unowned hole.
struct DesktopMapFocusRoute {
  let portal:DesktopPortal
  let entry:CGPoint
  let waypoints:[CGPoint]
  let preserved:Bool
  static func make(desktop:ReceiverDesktop,source:CGRect,target:CGPoint)->DesktopMapFocusRoute? {
    guard desktop.valid,let goal=desktop.display(at:target) else{return nil}
    let portals=desktop.portals(sourceRect:source)
    func seam(_ a:CGRect,_ b:CGRect)->(CGPoint,CGPoint)? {
      let y0=max(a.minY,b.minY),y1=min(a.maxY,b.maxY),x0=max(a.minX,b.minX),x1=min(a.maxX,b.maxX)
      if y1>y0 {
        let y=(y0+y1)/2
        if a.maxX==b.minX {return (CGPoint(x:a.maxX-0.5,y:y),CGPoint(x:b.minX+0.5,y:y))}
        if a.minX==b.maxX {return (CGPoint(x:a.minX+0.5,y:y),CGPoint(x:b.maxX-0.5,y:y))}
      }
      if x1>x0 {
        let x=(x0+x1)/2
        if a.maxY==b.minY {return (CGPoint(x:x,y:a.maxY-0.5),CGPoint(x:x,y:b.minY+0.5))}
        if a.minY==b.maxY {return (CGPoint(x:x,y:a.minY+0.5),CGPoint(x:x,y:b.maxY-0.5))}
      }
      return nil
    }
    for portal in portals {
      var queue=[portal.displayID],paths:[UInt32:[CGPoint]]=[portal.displayID:[]],index=0
      while index<queue.count,index<8 {
        let id=queue[index];index+=1
        guard let a=desktop.displays.first(where:{$0.id==id}),let path=paths[id] else{continue}
        if id==goal.id {
          let tangent=CGPoint(x:min(portal.intervalEnd.nextDown,max(portal.intervalStart,target.x)),y:min(portal.intervalEnd.nextDown,max(portal.intervalStart,target.y)))
          let entry=portal.targetPoint(fromSourceEdge:tangent),points=path+[target]
          var previous=entry,valid=true
          for p in points {
            let actual=desktop.moved(from:previous,delta:CGVector(dx:p.x-previous.x,dy:p.y-previous.y))
            guard desktop.contains(actual),hypot(actual.x-p.x,actual.y-p.y)<0.001 else{valid=false;break}
            previous=actual
          }
          if valid {return DesktopMapFocusRoute(portal:portal,entry:entry,waypoints:points,preserved:true)}
        }
        for b in desktop.displays where paths[b.id]==nil {
          if let (before,after)=seam(a.bounds,b.bounds) {paths[b.id]=path+[before,after];queue.append(b.id)}
        }
      }
    }
    // Existing remote intent may resume at a real canonical entry if the saved
    // physical target is disconnected. Never invent a portal to that target.
    guard let portal=portals.min(by:{hypot($0.targetRect.midX-target.x,$0.targetRect.midY-target.y)<hypot($1.targetRect.midX-target.x,$1.targetRect.midY-target.y)}) else{return nil}
    let tangent=CGPoint(x:min(portal.intervalEnd.nextDown,max(portal.intervalStart,target.x)),y:min(portal.intervalEnd.nextDown,max(portal.intervalStart,target.y)))
    return DesktopMapFocusRoute(portal:portal,entry:portal.targetPoint(fromSourceEdge:tangent),waypoints:[],preserved:false)
  }
}
