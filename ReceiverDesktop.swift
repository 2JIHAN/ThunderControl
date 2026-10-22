import Foundation
import CoreGraphics
#if canImport(ApplicationServices)
import ApplicationServices
#endif

/// CG global logical points: +x right, +y down. Independent of legacy Edge.
enum DesktopSide: String, Codable, Equatable, CaseIterable { case left, right, top, bottom }

struct ReceiverDisplay: Codable, Equatable {
    var id: UInt32
    var bounds: CGRect
    var stableIdentity: String? = nil

    init(id: UInt32, bounds: CGRect, stableIdentity: String? = nil) {
        self.id = id
        self.bounds = bounds
        // Normalize valid UUIDs; preserve non-nil malformed input verbatim so
        // `valid` can reject it rather than silently dropping to nil.
        if let s = stableIdentity {
            self.stableIdentity = UUID(uuidString: s)?.uuidString ?? s
        } else {
            self.stableIdentity = nil
        }
    }
    enum CodingKeys: String, CodingKey { case id, bounds, stableIdentity }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UInt32.self, forKey: .id)
        bounds = try c.decode(CGRect.self, forKey: .bounds)
        if let raw = try c.decodeIfPresent(String.self, forKey: .stableIdentity) {
            guard let u = UUID(uuidString: raw) else {
                throw DecodingError.dataCorruptedError(forKey: .stableIdentity, in: c,
                    debugDescription: "stableIdentity is not a canonical UUID")
            }
            stableIdentity = u.uuidString
        } else {
            stableIdentity = nil
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(bounds, forKey: .bounds)
        try c.encodeIfPresent(stableIdentity, forKey: .stableIdentity)
    }
}

/// Shared *absolute* tangent interval [intervalStart, intervalEnd).
/// sourceSide is the edge of sourceRect, not the target edge. No scaling or
/// normalization: tangent coordinates are preserved. The target is on the
/// other side of that edge; max edges use nextDown to remain half-open valid.
struct DesktopPortal: Codable, Equatable {
    let sourceSide: DesktopSide
    let displayID: UInt32
    let intervalStart: CGFloat
    let intervalEnd: CGFloat
    let sourceRect: CGRect
    let targetRect: CGRect

    func targetPoint(fromSourceEdge point: CGPoint) -> CGPoint {
        let t = tangent(point)
        switch sourceSide {
        case .left: return CGPoint(x: targetRect.maxX.nextDown, y: t)
        case .right: return CGPoint(x: targetRect.minX, y: t)
        case .top: return CGPoint(x: t, y: targetRect.maxY.nextDown)
        case .bottom: return CGPoint(x: t, y: targetRect.minY)
        }
    }
    func sourcePoint(fromTargetEdge point: CGPoint) -> CGPoint {
        let t = tangent(point)
        switch sourceSide {
        case .left: return CGPoint(x: sourceRect.minX, y: t)
        case .right: return CGPoint(x: sourceRect.maxX.nextDown, y: t)
        case .top: return CGPoint(x: t, y: sourceRect.minY)
        case .bottom: return CGPoint(x: t, y: sourceRect.maxY.nextDown)
        }
    }
    /// Tests the un-clamped intended segment BEFORE ReceiverDesktop.moved.
    /// True only crossing target's shared edge toward source, with intersection
    /// tangent in the half-open interval; motion along the edge is not crossing.
    func isReverseCrossing(from: CGPoint, to: CGPoint) -> Bool {
        guard ReceiverDesktop.finite(from), ReceiverDesktop.finite(to),
              ReceiverDesktop.has(targetRect, from) else { return false }
        let a: CGFloat, b: CGFloat, edge: CGFloat
        switch sourceSide {
        case .left: a=from.x; b=to.x; edge=sourceRect.minX; guard b >= edge, b > a else{return false}
        case .right: a=from.x; b=to.x; edge=sourceRect.maxX; guard b < edge, b < a else{return false}
        case .top: a=from.y; b=to.y; edge=sourceRect.minY; guard b >= edge, b > a else{return false}
        case .bottom: a=from.y; b=to.y; edge=sourceRect.maxY; guard b < edge, b < a else{return false}
        }
        let u=(edge-a)/(b-a)
        guard u >= 0, u <= 1 else{return false}
        let t = (sourceSide == .left || sourceSide == .right) ? from.y+(to.y-from.y)*u : from.x+(to.x-from.x)*u
        return t >= intervalStart && t < intervalEnd
    }
    private func tangent(_ p: CGPoint) -> CGFloat {
        let t = (sourceSide == .left || sourceSide == .right) ? p.y : p.x
        return min(max(t.isFinite ? t : intervalStart, intervalStart), intervalEnd.nextDown)
    }
}

struct ReceiverDesktop: Codable, Equatable {
    var revision: UInt64
    var mainID: UInt32
    var displays: [ReceiverDisplay]
    var virtualDisplayID: UInt32? = nil

    // Generous wire/geometry limits, not the enclosing rectangle as hit region.
    static let coordinateLimit: CGFloat = 1_000_000
    static let dimensionLimit: CGFloat = 65_536
    static func finite(_ p: CGPoint) -> Bool { p.x.isFinite && p.y.isFinite }
    static func sane(_ r: CGRect) -> Bool {
        // Guard the stored size, not CGRect.width/height (which absolutize).
        finite(r.origin) && r.size.width.isFinite && r.size.height.isFinite &&
        r.size.width >= 1 && r.size.height >= 1 &&
        r.size.width <= dimensionLimit && r.size.height <= dimensionLimit &&
        abs(r.minX) <= coordinateLimit && abs(r.minY) <= coordinateLimit &&
        abs(r.maxX) <= coordinateLimit && abs(r.maxY) <= coordinateLimit
    }
    static func has(_ r: CGRect, _ p: CGPoint) -> Bool {
        finite(p) && p.x >= r.minX && p.x < r.maxX && p.y >= r.minY && p.y < r.maxY
    }
    static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        min(a.maxX,b.maxX) > max(a.minX,b.minX) && min(a.maxY,b.maxY) > max(a.minY,b.minY)
    }
    /// Returns Foundation's canonical uppercase hyphenated UUID string if `s`
    /// parses as a UUID; nil otherwise or when `s` itself is nil.
    static func canonicalUUID(_ s: String?) -> String? {
        guard let s = s, let u = UUID(uuidString: s) else { return nil }
        return u.uuidString
    }
    var valid: Bool {
        guard (1...8).contains(displays.count), mainID != 0,
              Set(displays.map(\.id)).count == displays.count,
              displays.contains(where: {$0.id == mainID}),
              displays.allSatisfy({$0.id != 0 && Self.sane($0.bounds) && ($0.stableIdentity == nil || UUID(uuidString: $0.stableIdentity!) != nil)}),
              virtualDisplayID == nil || displays.contains(where: {$0.id == virtualDisplayID}) else { return false }
        for i in displays.indices { for j in displays.indices where j > i {
            if Self.overlaps(displays[i].bounds,displays[j].bounds) {return false}
        }}
        return true
    }
    var bounds: CGRect { guard valid else{return .null}; return displays.dropFirst().reduce(displays[0].bounds){$0.union($1.bounds)} }
    func display(at point: CGPoint) -> ReceiverDisplay? {
        guard valid else{return nil}; return displays.first{Self.has($0.bounds,point)}
    }
    func contains(_ point: CGPoint) -> Bool {display(at:point) != nil}
    /// Closest-point fallback for stale/removed display coordinates ONLY. Do not
    /// use this for ordinary relative motion, which would teleport across gaps.
    func clamped(_ point: CGPoint) -> CGPoint {
        guard valid else{return .zero}
        let p = Self.finite(point) ? point : displays.first{$0.id == mainID}!.bounds.origin
        return displays.map { d -> CGPoint in
            CGPoint(x:min(max(p.x,d.bounds.minX),d.bounds.maxX.nextDown), y:min(max(p.y,d.bounds.minY),d.bounds.maxY.nextDown))
        }.min { hypot($0.x-p.x,$0.y-p.y) < hypot($1.x-p.x,$1.y-p.y) }!
    }
    /// Segment traversal through edge-connected rectangles, sliding on exposed
    /// edges. Corner-only neighbors and disconnected monitors are never entered.
    func moved(from start: CGPoint, delta: CGVector) -> CGPoint {
        guard valid else{return .zero}
        var p = contains(start) ? start : clamped(start)
        guard delta.dx.isFinite, delta.dy.isFinite, abs(delta.dx) <= Self.coordinateLimit*4, abs(delta.dy) <= Self.coordinateLimit*4 else{return p}
        var v=delta
        for _ in 0..<64 {
            guard let d=display(at:p), v.dx != 0 || v.dy != 0 else{return p}
            let r=d.bounds
            let tx = v.dx > 0 ? (r.maxX-p.x)/v.dx : (v.dx < 0 ? (r.minX-p.x)/v.dx : .infinity)
            let ty = v.dy > 0 ? (r.maxY-p.y)/v.dy : (v.dy < 0 ? (r.minY-p.y)/v.dy : .infinity)
            let t=max(0,min(1,min(tx,ty)))
            if t == 1 { return CGPoint(x:min(max(p.x+v.dx,r.minX),r.maxX.nextDown),y:min(max(p.y+v.dy,r.minY),r.maxY.nextDown)) }
            let hit=CGPoint(x:p.x+v.dx*t,y:p.y+v.dy*t)
            let xExit = tx <= ty, yExit = ty <= tx
            let corner = xExit && yExit
            var next: ReceiverDisplay? = nil
            // Pure-diagonal (corner-only, no edge overlap) connectivity is
            // never accepted: the strict `min(_,_) > max(_,_)` orthogonal
            // overlap requirement filters it out on both axes. At an exact
            // corner where a real edge-neighbor exists on one axis, we take
            // it (relaxing hit containment to the closed interval; the
            // post-step inward clamp lands the pointer inside the half-open
            // interior).
            if xExit && v.dx != 0 {
                next = displays.first { n in
                    guard n.id != d.id else { return false }
                    let b = n.bounds
                    let edgeTouch = v.dx > 0 ? b.minX == r.maxX : b.maxX == r.minX
                    guard edgeTouch, min(b.maxY, r.maxY) > max(b.minY, r.minY) else { return false }
                    return corner ? (hit.y >= b.minY && hit.y <= b.maxY)
                                  : (hit.y >= b.minY && hit.y <  b.maxY)
                }
            }
            if next == nil, yExit, v.dy != 0 {
                next = displays.first { n in
                    guard n.id != d.id else { return false }
                    let b = n.bounds
                    let edgeTouch = v.dy > 0 ? b.minY == r.maxY : b.maxY == r.minY
                    guard edgeTouch, min(b.maxX, r.maxX) > max(b.minX, r.minX) else { return false }
                    return corner ? (hit.x >= b.minX && hit.x <= b.maxX)
                                  : (hit.x >= b.minX && hit.x <  b.maxX)
                }
            }
            v=CGVector(dx:v.dx*(1-t),dy:v.dy*(1-t))
            if let n=next {
                p=CGPoint(x:min(max(hit.x,n.bounds.minX),n.bounds.maxX.nextDown),y:min(max(hit.y,n.bounds.minY),n.bounds.maxY.nextDown))
            } else {
                p=CGPoint(x:min(max(hit.x,r.minX),r.maxX.nextDown),y:min(max(hit.y,r.minY),r.maxY.nextDown))
                if xExit {v.dx=0}; if yExit {v.dy=0}
            }
        }
        return p
    }
    func portals(sourceRect s: CGRect) -> [DesktopPortal] {
        guard valid, Self.sane(s), !displays.contains(where:{Self.overlaps(s,$0.bounds)}) else{return []}
        var result:[DesktopPortal]=[]
        for d in displays {
            let r=d.bounds
            for side in DesktopSide.allCases {
                let vertical=side == .left || side == .right
                let lo=vertical ? max(s.minY,r.minY) : max(s.minX,r.minX)
                let hi=vertical ? min(s.maxY,r.maxY) : min(s.maxX,r.maxX)
                let contact:Bool
                switch side {case .left:contact=s.minX == r.maxX; case .right:contact=s.maxX == r.minX; case .top:contact=s.minY == r.maxY; case .bottom:contact=s.maxY == r.minY}
                if contact && hi > lo {result.append(DesktopPortal(sourceSide:side,displayID:d.id,intervalStart:lo,intervalEnd:hi,sourceRect:s,targetRect:r))}
            }
        }
        return result
    }
    /// Nearest collision-free edge attachment. Source is never placed over any
    /// receiver display. Nil means the bounded geometry has no candidate.
    func snappedSourceOrigin(proposed p: CGPoint, size: CGSize) -> CGPoint? {
        guard valid, Self.finite(p), Self.sane(CGRect(origin:.zero,size:size)) else{return nil}
        var candidates:[CGPoint]=[]
        for d in displays {
            let r=d.bounds
            // Preserve proposed tangent whenever it provides >=1 point contact.
            let y=min(max(p.y,r.minY-size.height+1),r.maxY-1)
            let x=min(max(p.x,r.minX-size.width+1),r.maxX-1)
            candidates += [CGPoint(x:r.minX-size.width,y:y),CGPoint(x:r.maxX,y:y),CGPoint(x:x,y:r.minY-size.height),CGPoint(x:x,y:r.maxY)]
            // Ends handle obstructions from staggered neighboring displays.
            for yy in [r.minY,r.maxY-size.height] { candidates += [CGPoint(x:r.minX-size.width,y:yy),CGPoint(x:r.maxX,y:yy)] }
            for xx in [r.minX,r.maxX-size.width] { candidates += [CGPoint(x:xx,y:r.minY-size.height),CGPoint(x:xx,y:r.maxY)] }
        }
        return candidates.filter { !portals(sourceRect:CGRect(origin:$0,size:size)).isEmpty }.min {hypot($0.x-p.x,$0.y-p.y) < hypot($1.x-p.x,$1.y-p.y)}
    }
    func defaultSourceOrigin(size: CGSize, preferRight: Bool = false) -> CGPoint? {
        guard valid,Self.sane(CGRect(origin:.zero,size:size)),let anchor=displays.first(where:{$0.id == virtualDisplayID}) ?? displays.first(where:{$0.id == mainID}) else{return nil}
        let point=CGPoint(x:preferRight ? anchor.bounds.maxX : anchor.bounds.minX-size.width,y:anchor.bounds.midY-size.height/2)
        if !portals(sourceRect:CGRect(origin:point,size:size)).isEmpty{return point}
        // Saved virtual placement may occupy the right side. Preserve it and
        // place source outside the whole map rather than leaving Auto unarmed.
        if let left=displays.map({$0.bounds.minX}).min() {
            let outside=CGPoint(x:left-size.width,y:point.y)
            if !portals(sourceRect:CGRect(origin:outside,size:size)).isEmpty{return outside}
        }
        return snappedSourceOrigin(proposed:point,size:size)
    }
    /// Owned virtual screen only. Physical monitor coordinates remain untouched.
    /// Integer OS origins round an odd-height center by at most half a point.
    func defaultOwnedVirtualOrigin(size:CGSize)->CGPoint? {
        guard valid,virtualDisplayID==nil,Self.sane(CGRect(origin:.zero,size:size)),
          let main=displays.first(where:{$0.id==mainID}),let left=displays.map({$0.bounds.minX}).min() else{return nil}
        let point=CGPoint(x:left-size.width,y:(main.bounds.midY-size.height/2).rounded(.toNearestOrAwayFromZero))
        guard point.x.rounded()==point.x,point.y.rounded()==point.y else{return nil}
        return portals(sourceRect:CGRect(origin:point,size:size)).isEmpty ? nil:point
    }
}

enum ReceiverDesktopReadError: Error { case displayQuery(CGError), unstableOrInvalid }

/// Read-only CG capture. Two identical full endpoints (IDs/main/bounds) per
/// attempt, up to three attempts. No display settings, input or auth mutations.
func readReceiverDesktop(revision: UInt64, virtualDisplayID: UInt32? = nil) throws -> ReceiverDesktop {
    func endpoint() throws -> ReceiverDesktop {
        var count:UInt32=0
        var err=CGGetActiveDisplayList(0,nil,&count)
        guard err == .success else{throw ReceiverDesktopReadError.displayQuery(err)}
        guard count > 0, count <= 64 else{throw ReceiverDesktopReadError.unstableOrInvalid}
        var ids=[CGDirectDisplayID](repeating:0,count:Int(count))
        let capacity=count
        err=CGGetActiveDisplayList(capacity,&ids,&count)
        guard err == .success, count <= capacity else{throw ReceiverDesktopReadError.unstableOrInvalid}
        let ds=ids.prefix(Int(count)).filter{CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay}.sorted().map{ did -> ReceiverDisplay in
            var uuid: String? = nil
            if let unmanaged = CGDisplayCreateUUIDFromDisplayID(did) {
                let cf = unmanaged.takeRetainedValue()
                if let s = CFUUIDCreateString(nil, cf) as String? {
                    uuid = ReceiverDesktop.canonicalUUID(s)
                }
            }
            return ReceiverDisplay(id: did, bounds: CGDisplayBounds(did), stableIdentity: uuid)
        }
        return ReceiverDesktop(revision:revision,mainID:CGMainDisplayID(),displays:ds,virtualDisplayID:virtualDisplayID)
    }
    for _ in 0..<3 {let a=try endpoint(),b=try endpoint();if a == b && b.valid{return b}}
    throw ReceiverDesktopReadError.unstableOrInvalid
}
