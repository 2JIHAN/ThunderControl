import Foundation
import CoreGraphics

/// No dwell clock. Each side must have its own inward sample before an
/// outward edge event can enter an exact canonical half-open portal.
struct DesktopEntryPolicy {
  private var armed=Set<DesktopSide>()
  private var sourceRect:CGRect?
  private(set) var latchedSide:DesktopSide?

  mutating func reset(returningThrough side:DesktopSide?=nil) {
    armed.removeAll();sourceRect=nil;latchedSide=side
  }
  private func distance(_ p:CGPoint,size:CGSize,side:DesktopSide)->CGFloat {
    switch side {
    case .left:return p.x
    case .right:return size.width-1-p.x
    case .top:return p.y
    case .bottom:return size.height-1-p.y
    }
  }
  mutating func candidate(sourceLocal p:CGPoint,delta:CGVector,sourceRect rect:CGRect,portals:[DesktopPortal],held:Bool)->DesktopPortal? {
    guard ReceiverDesktop.sane(rect),ReceiverDesktop.has(CGRect(origin:.zero,size:rect.size),p),
      delta.dx.isFinite,delta.dy.isFinite else{return nil}
    if sourceRect != rect {armed.removeAll();sourceRect=rect}
    for side in DesktopSide.allCases where distance(p,size:rect.size,side:side)>=2 {
      armed.insert(side)
      if latchedSide==side {latchedSide=nil}
    }
    guard !held else{return nil}
    return portals.first { portal in
      guard portal.sourceRect==rect,armed.contains(portal.sourceSide),distance(p,size:rect.size,side:portal.sourceSide)<=1 else{return false}
      let tangent:CGFloat,outward:Bool
      switch portal.sourceSide {
      case .left:tangent=rect.minY+p.y;outward=delta.dx<0
      case .right:tangent=rect.minY+p.y;outward=delta.dx>0
      case .top:tangent=rect.minX+p.x;outward=delta.dy<0
      case .bottom:tangent=rect.minX+p.x;outward=delta.dy>0
      }
      return outward && tangent>=portal.intervalStart && tangent<portal.intervalEnd
    }
  }
  mutating func latch(_ side:DesktopSide) {armed.removeAll();latchedSide=side}
}
