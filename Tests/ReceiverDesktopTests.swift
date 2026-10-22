import Foundation
import CoreGraphics

// Standalone test harness for ReceiverDesktop.swift. Foundation + CoreGraphics
// only. No AppKit, no network, no real input, no OS configuration writes.
// Reads of native display topology via readReceiverDesktop are read-only.

private var _asserts = 0
private var _fails: [String] = []
private func check(_ cond: @autoclosure () -> Bool, _ name: String) {
    _asserts += 1
    if !cond() { _fails.append(name) }
}
private func rejects(_ name: String, _ block: () throws -> Void) {
    _asserts += 1
    do { try block(); _fails.append(name + " (did not throw)") } catch { /* ok */ }
}
private func close(_ a: CGFloat, _ b: CGFloat, _ eps: CGFloat = 1e-6) -> Bool {
    a.isFinite && b.isFinite && abs(a - b) <= eps
}

private func mk(_ id: UInt32, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                _ uuid: String? = nil) -> ReceiverDisplay {
    ReceiverDisplay(id: id, bounds: CGRect(x: x, y: y, width: w, height: h), stableIdentity: uuid)
}
private func desktop(_ main: UInt32, _ ds: [ReceiverDisplay],
                     _ virt: UInt32? = nil, _ rev: UInt64 = 1) -> ReceiverDesktop {
    ReceiverDesktop(revision: rev, mainID: main, displays: ds, virtualDisplayID: virt)
}

// MARK: - API freeze: stableIdentity defaults to nil and is canonicalized.

private func stableIdentityTests() {
    let d0 = ReceiverDisplay(id: 1, bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
    check(d0.stableIdentity == nil, "stableIdentity defaults to nil")

    let valid = "12345678-1234-1234-1234-1234567890AB"
    let d1 = ReceiverDisplay(id: 1, bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                             stableIdentity: valid.lowercased())
    check(d1.stableIdentity == valid.uppercased(),
          "init canonicalizes stableIdentity to uppercase UUID")

    // Present-but-malformed input is preserved verbatim so `valid` rejects it,
    // rather than being silently canonicalized to nil (absent).
    let d2 = ReceiverDisplay(id: 1, bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                             stableIdentity: "not-a-uuid")
    check(d2.stableIdentity == "not-a-uuid", "init preserves non-nil malformed id")
    check(desktop(1, [d2]).valid == false, "valid rejects malformed stableIdentity")

    check(ReceiverDesktop.canonicalUUID(nil) == nil, "canonicalUUID(nil) == nil")
    check(ReceiverDesktop.canonicalUUID("")  == nil, "canonicalUUID(empty) == nil")
    check(ReceiverDesktop.canonicalUUID("zzz") == nil, "canonicalUUID(garbage) == nil")
    check(ReceiverDesktop.canonicalUUID(valid) == valid.uppercased(), "canonicalUUID round-trip")
}

// MARK: - Validation and read-only receiver OS map.

private func validationTests() {
    check(desktop(0, []).valid == false, "empty displays invalid")
    check(desktop(1, [mk(1, 0, 0, 100, 100)]).valid, "single display valid")
    check(desktop(2, [mk(1, 0, 0, 100, 100)]).valid == false, "mainID must exist")
    check(desktop(1, [mk(0, 0, 0, 100, 100)]).valid == false, "id 0 forbidden")
    check(desktop(1, [mk(1, 0, 0, 100, 100), mk(1, 200, 0, 100, 100)]).valid == false,
          "duplicate ids rejected")

    // overlap rejection (except mirrors which readReceiverDesktop filters out)
    check(desktop(1, [mk(1, 0, 0, 100, 100), mk(2, 50, 0, 100, 100)]).valid == false,
          "overlapping displays rejected")
    // edge touching != overlap
    check(desktop(1, [mk(1, 0, 0, 100, 100), mk(2, 100, 0, 100, 100)]).valid,
          "touching edges not overlap")

    // >8 displays
    var many: [ReceiverDisplay] = []
    for i in 0..<9 { many.append(mk(UInt32(i + 1), CGFloat(i) * 200, 0, 100, 100)) }
    check(desktop(1, many).valid == false, "9 displays rejected")
    // Exactly 8 is allowed.
    many.removeLast()
    check(desktop(1, many).valid, "8 displays accepted")

    // non-finite bounds
    let nan = mk(2, CGFloat.nan, 0, 100, 100)
    check(desktop(1, [mk(1, 0, 0, 100, 100), nan]).valid == false, "NaN bounds rejected")

    // dimension limits
    let huge = mk(3, 0, 0, 1_000_000, 100)
    check(desktop(3, [huge]).valid == false, "dimension over limit rejected")
    let tiny = mk(4, 0, 0, 0.5, 100)
    check(desktop(4, [tiny]).valid == false, "width < 1 rejected")

    // virtualDisplayID must resolve
    let d = desktop(1, [mk(1, 0, 0, 100, 100)], 99)
    check(d.valid == false, "unresolved virtualDisplayID rejected")
    let d2 = desktop(1, [mk(1, 0, 0, 100, 100), mk(2, 100, 0, 100, 100)], 2)
    check(d2.valid, "resolved virtualDisplayID accepted")

    // Negative stored size must be rejected by sane (CGRect.width absolutizes).
    let neg = ReceiverDisplay(id: 7,
        bounds: CGRect(origin: .zero, size: CGSize(width: -100, height: 50)))
    check(desktop(7, [neg]).valid == false, "negative stored size rejected")

    // stableIdentity validity enforced through valid even if assigned post-init.
    var good = mk(1, 0, 0, 100, 100, "12345678-1234-1234-1234-1234567890AB")
    check(desktop(1, [good]).valid, "canonical stableIdentity preserved by valid")
    good.stableIdentity = "not-a-uuid"   // bypasses init
    check(desktop(1, [good]).valid == false, "valid rejects non-canonical stableIdentity")
}

// MARK: - Serialization + revision round-trip.

private func serializationTests() {
    let d = desktop(1,
        [mk(1, -500, -300, 1920, 1200, "12345678-1234-1234-1234-1234567890AB"),
         mk(2, 1420, -300, 1024, 768)],
        2, 42)
    check(d.valid, "serialization fixture valid")
    let enc = JSONEncoder()
    let dec = JSONDecoder()
    let data = try! enc.encode(d)
    let d2 = try! dec.decode(ReceiverDesktop.self, from: data)
    check(d == d2, "round-trip equal")
    check(d2.revision == 42, "revision preserved")
    check(d2.displays[0].stableIdentity == "12345678-1234-1234-1234-1234567890AB",
          "stableIdentity preserved")
    check(d2.displays[1].stableIdentity == nil, "nil stableIdentity preserved")

    // backward-compat: legacy JSON without stableIdentity key decodes.
    let legacy = Data("""
    {"revision":7,"mainID":1,"displays":[{"id":1,"bounds":[[0,0],[100,100]]}]}
    """.utf8)
    let dl = try! dec.decode(ReceiverDesktop.self, from: legacy)
    check(dl.valid && dl.displays[0].stableIdentity == nil, "legacy JSON decodes")

    // Present-but-malformed stableIdentity on the wire must be rejected, not nulled.
    let dirty = Data("""
    {"revision":1,"mainID":1,"displays":[{"id":1,"bounds":[[0,0],[100,100]],"stableIdentity":"garbage"}]}
    """.utf8)
    rejects("malformed wire stableIdentity rejected") {
        _ = try dec.decode(ReceiverDesktop.self, from: dirty)
    }
}

// MARK: - containment and clamped fallback.

private func containmentTests() {
    let d = desktop(1, [mk(1, 0, 0, 100, 100), mk(2, 100, 0, 100, 100)])
    check(d.contains(CGPoint(x: 50, y: 50)), "inside first")
    check(d.contains(CGPoint(x: 150, y: 50)), "inside second")
    check(d.contains(CGPoint(x: 100, y: 50)), "half-open: boundary belongs to right")
    check(d.contains(CGPoint(x: 100, y: 100)) == false, "bottom-right corner excluded")
    check(d.contains(CGPoint(x: 200, y: 50)) == false, "beyond right edge")

    // clamped is nearest-point fallback and never teleports relative motion.
    let outside = CGPoint(x: 1000, y: 50)
    let c = d.clamped(outside)
    check(d.contains(c), "clamped lands inside a display")
    check(c.x > 199.0 && c.x < 200.0 && close(c.y, 50), "clamped to nearest edge of nearest display")

    // non-finite falls back to mainID origin anchor then clamps.
    let f = d.clamped(CGPoint(x: CGFloat.nan, y: CGFloat.infinity))
    check(d.contains(f), "non-finite clamp lands inside")
}

// MARK: - moved: continuous edge-connected, no teleport, no holes.

private func movementTests() {
    // Horizontal pair.
    let d = desktop(1, [mk(1, 0, 0, 100, 100), mk(2, 100, 0, 100, 100)])
    let p = d.moved(from: CGPoint(x: 50, y: 50), delta: CGVector(dx: 120, dy: 0))
    check(d.contains(p) && close(p.x, 170), "crosses shared vertical edge continuously")

    // Vertical pair top/bottom.
    let v = desktop(1, [mk(1, 0, 0, 100, 100), mk(2, 0, 100, 100, 100)])
    let pv = v.moved(from: CGPoint(x: 50, y: 50), delta: CGVector(dx: 0, dy: 120))
    check(v.contains(pv) && close(pv.y, 170), "crosses shared horizontal edge")
    let pv2 = v.moved(from: CGPoint(x: 50, y: 150), delta: CGVector(dx: 0, dy: -120))
    check(v.contains(pv2) && close(pv2.y, 30), "reverse crossing top direction")

    // Disconnected pair: never land in gap, never teleport.
    let gap = desktop(1, [mk(1, 0, 0, 100, 100), mk(2, 300, 0, 100, 100)])
    let pg = gap.moved(from: CGPoint(x: 50, y: 50), delta: CGVector(dx: 500, dy: 0))
    check(gap.display(at: pg)?.id == 1 && close(pg.x, 99.99999, 0.001),
          "disconnected: slides to source edge, no hole, no teleport")

    // Diagonal-only corner neighbor (no edge-bridge): must NOT be entered.
    let corner = desktop(1, [mk(1, 0, 0, 100, 100), mk(2, 100, 100, 100, 100)])
    let pc = corner.moved(from: CGPoint(x: 50, y: 50),
                          delta: CGVector(dx: 200, dy: 200))
    check(corner.display(at: pc)?.id == 1,
          "corner-only neighbor is not crossed diagonally")

    // Exact corner-junction with edge-bridge (A plus right-neighbor only): a
    // 45-degree exit at the bottom-right of A must slide onto the
    // edge-connected right neighbor rather than block both axes.
    let AB = desktop(1, [mk(1, 0, 0, 100, 100), mk(2, 100, 0, 100, 100)])
    let pAB = AB.moved(from: CGPoint(x: 50, y: 50), delta: CGVector(dx: 100, dy: 100))
    check(AB.display(at: pAB)?.id == 2 && close(pAB.x, 150, 0.01),
          "corner-junction with right edge-neighbor slides onto it")

    // 2x2 fully-contiguous grid: 45-degree traversal from A through the
    // central junction must reach the diagonal display D via the edge-bridge.
    let grid = desktop(1, [
        mk(1, 0,   0,   100, 100),
        mk(2, 100, 0,   100, 100),
        mk(3, 0,   100, 100, 100),
        mk(4, 100, 100, 100, 100),
    ])
    let pg2 = grid.moved(from: CGPoint(x: 50, y: 50), delta: CGVector(dx: 100, dy: 100))
    check(grid.display(at: pg2)?.id == 4,
          "2x2 grid: exact-diagonal through central junction reaches D")
    let pg3 = grid.moved(from: CGPoint(x: 150, y: 150), delta: CGVector(dx: -100, dy: -100))
    check(grid.display(at: pg3)?.id == 1,
          "2x2 grid: reverse exact-diagonal through central junction reaches A")

    // A plus down-neighbor only: 45-degree exit must slide onto the
    // edge-connected bottom neighbor via the y-axis.
    let AC = desktop(1, [mk(1, 0, 0, 100, 100), mk(2, 0, 100, 100, 100)])
    let pAC = AC.moved(from: CGPoint(x: 50, y: 50), delta: CGVector(dx: 100, dy: 100))
    check(AC.display(at: pAC)?.id == 2,
          "corner-junction with bottom edge-neighbor slides onto it")

    // Three of four quadrants (A, B, D - no C): the A-D path has only a
    // corner neighbor, but B provides the edge-bridge. Must reach D.
    let ABD = desktop(1, [mk(1, 0, 0, 100, 100),
                           mk(2, 100, 0, 100, 100),
                           mk(3, 100, 100, 100, 100)])
    let pABD = ABD.moved(from: CGPoint(x: 50, y: 50), delta: CGVector(dx: 100, dy: 100))
    check(ABD.display(at: pABD)?.id == 3,
          "corner-junction reaches diagonal via edge-bridge through B")

    // Staggered L-shape: A on left (0..100, 0..100), B shifted (100..200, 50..150).
    // Pointer at (50,80) with v=(100,20) enters B on the right-edge half-interval.
    let stag = desktop(1, [mk(1, 0, 0, 100, 100), mk(2, 100, 50, 100, 100)])
    let ps = stag.moved(from: CGPoint(x: 50, y: 80), delta: CGVector(dx: 100, dy: 20))
    check(stag.display(at: ps)?.id == 2, "staggered: enters neighbor on half-overlap")
    // Below the overlap: should slide, not jump.
    let psOut = stag.moved(from: CGPoint(x: 50, y: 10), delta: CGVector(dx: 200, dy: 0))
    check(stag.display(at: psOut)?.id == 1 && close(psOut.x, 99.99999, 0.001),
          "staggered: exits above neighbor interval, slides on edge")

    // Three-across sliding: travel across two shared edges in one call.
    let row = desktop(1, [mk(1, 0, 0, 100, 100), mk(2, 100, 0, 100, 100), mk(3, 200, 0, 100, 100)])
    let pr = row.moved(from: CGPoint(x: 10, y: 50), delta: CGVector(dx: 260, dy: 0))
    check(row.display(at: pr)?.id == 3 && close(pr.x, 270), "slides across two edges")

    // Non-finite delta: no motion.
    let nmv = row.moved(from: CGPoint(x: 50, y: 50), delta: CGVector(dx: CGFloat.nan, dy: 0))
    check(close(nmv.x, 50) && close(nmv.y, 50), "non-finite delta rejected")
    // Extremely large delta magnitude: rejected safely.
    let huge = row.moved(from: CGPoint(x: 50, y: 50),
                         delta: CGVector(dx: 1e12, dy: 0))
    check(close(huge.x, 50) && close(huge.y, 50), "oversize delta rejected")

    // Starting outside any display uses clamped fallback once, then moves.
    let fr = row.moved(from: CGPoint(x: -1000, y: 50), delta: CGVector(dx: 10, dy: 0))
    check(row.contains(fr), "stale/removed origin recovered via clamped fallback only")

    // Negative-origin topologies behave the same way.
    let neg = desktop(1, [mk(1, -200, -100, 100, 100), mk(2, -100, -100, 100, 100)])
    let pn = neg.moved(from: CGPoint(x: -150, y: -50), delta: CGVector(dx: 80, dy: 0))
    check(neg.display(at: pn)?.id == 2 && close(pn.x, -70),
          "negative origins cross as expected")

    // Property: for random short segments inside a connected pair, result stays in map.
    var rng = SystemRandomNumberGenerator()
    for _ in 0..<200 {
        let x = CGFloat.random(in: 0..<200, using: &rng)
        let y = CGFloat.random(in: 0..<100, using: &rng)
        let dx = CGFloat.random(in: -300...300, using: &rng)
        let dy = CGFloat.random(in: -200...200, using: &rng)
        let r = d.moved(from: CGPoint(x: x, y: y), delta: CGVector(dx: dx, dy: dy))
        check(d.contains(r), "property: moved stays inside connected pair")
    }
}

// MARK: - portals: external shared edges only, actual target, all 4 sides.

private func portalTests() {
    let d = desktop(1, [mk(1, 0, 0, 100, 100), mk(2, 100, 0, 100, 100)])
    // Source rect to the left of display 1, sharing full left edge.
    let sLeft = CGRect(x: -200, y: 0, width: 200, height: 100)
    let pls = d.portals(sourceRect: sLeft)
    check(pls.count == 1 && pls[0].displayID == 1 && pls[0].sourceSide == .right,
          "left-of-receiver: portal targets receiver via source right side")
    check(close(pls[0].intervalStart, 0) && close(pls[0].intervalEnd, 100),
          "actual shared interval returned, not forced virtual")

    // Overlapping source rejected entirely.
    let overlap = CGRect(x: 50, y: 50, width: 20, height: 20)
    check(d.portals(sourceRect: overlap).isEmpty, "overlapping source yields no portals")

    // Four-sided: a source rect bridging two receivers from below shares bottoms.
    let bottomBridge = CGRect(x: 0, y: 100, width: 200, height: 50)
    let pb = d.portals(sourceRect: bottomBridge)
    check(pb.count == 2 && Set(pb.map { $0.sourceSide }) == Set([.top]),
          "bridge below both receivers emits top-side portals for both")

    // All four sides reachable with a square cross arrangement.
    //    [B(100,-100..100,0)]
    // [A(0,0..100,100)] [C(100,0..100,100)]
    //    [D(0..100,100..200)]
    let cross = desktop(1, [mk(1, 0, 0, 100, 100), mk(2, 100, -100, 100, 100),
                            mk(3, 100, 0, 100, 100), mk(4, 0, 100, 100, 100)])
    // Hmm displays 1 and 3 share edge, 3 and 2 share edge, 1 and 4 share edge.
    // Place source at (-100, 0, 100, 100): sits to left of 1 only.
    let srcLeft = CGRect(x: -100, y: 0, width: 100, height: 100)
    let pcross = cross.portals(sourceRect: srcLeft)
    check(pcross.count == 1 && pcross[0].displayID == 1,
          "cross map: source left of A touches only A")

    // targetPoint maps to actual target interior with half-open guarantee.
    let portal = pls[0]
    let tp = portal.targetPoint(fromSourceEdge: CGPoint(x: -0.5, y: 25))
    check(d.contains(tp), "targetPoint maps inside receiver (half-open ok)")
    let tpEdge = portal.targetPoint(fromSourceEdge: CGPoint(x: -0.5, y: 99.9))
    check(d.contains(tpEdge), "targetPoint near top end still inside")

    // sourcePoint inverse is on the source side.
    let sp = portal.sourcePoint(fromTargetEdge: CGPoint(x: 0, y: 25))
    check(close(sp.x, sLeft.maxX.nextDown), "sourcePoint on source right edge")

    // isReverseCrossing: motion crossing target's shared edge back into source.
    check(portal.isReverseCrossing(from: CGPoint(x: 0.5, y: 25),
                                   to: CGPoint(x: -1, y: 25)),
          "reverse-crossing detected for inward->source motion")
    check(portal.isReverseCrossing(from: CGPoint(x: 50, y: 25),
                                   to: CGPoint(x: 60, y: 25)) == false,
          "motion along same display is not reverse-crossing")
    check(portal.isReverseCrossing(from: CGPoint(x: 0.5, y: 25),
                                   to: CGPoint(x: 0.5, y: 50)) == false,
          "motion along edge is not reverse-crossing")
}

// MARK: - snappedSourceOrigin: four-direction snap, no overlap, works concave.

private func snapTests() {
    let d = desktop(1, [mk(1, 0, 0, 100, 100)])
    let size = CGSize(width: 50, height: 50)

    // Proposed to the far left: snap on the left of display 1.
    guard let left = d.snappedSourceOrigin(proposed: CGPoint(x: -1000, y: 25), size: size)
    else { check(false, "snap left should succeed"); return }
    check(close(left.x, -50) && left.y >= -49 && left.y <= 100,
          "snapped to left side of receiver")
    let placedL = CGRect(origin: left, size: size)
    check(ReceiverDesktop.overlaps(placedL, mk(1, 0, 0, 100, 100).bounds) == false,
          "left snap does not overlap receiver")

    // Right.
    guard let right = d.snappedSourceOrigin(proposed: CGPoint(x: 1000, y: 25), size: size)
    else { check(false, "snap right should succeed"); return }
    check(close(right.x, 100), "snapped to right side")

    // Top.
    guard let top = d.snappedSourceOrigin(proposed: CGPoint(x: 50, y: -1000), size: size)
    else { check(false, "snap top should succeed"); return }
    check(close(top.y, -50), "snapped above receiver")

    // Bottom.
    guard let bot = d.snappedSourceOrigin(proposed: CGPoint(x: 50, y: 1000), size: size)
    else { check(false, "snap bottom should succeed"); return }
    check(close(bot.y, 100), "snapped below receiver")

    // Concave/staggered arrangement: L-shape of two displays.
    let L = desktop(1, [mk(1, 0, 0, 200, 100), mk(2, 0, 100, 100, 100)])
    let picked = L.snappedSourceOrigin(proposed: CGPoint(x: 300, y: 150),
                                       size: CGSize(width: 50, height: 50))
    check(picked != nil, "concave arrangement produces a valid snap")
    if let p = picked {
        let rect = CGRect(origin: p, size: CGSize(width: 50, height: 50))
        check(L.displays.allSatisfy { !ReceiverDesktop.overlaps(rect, $0.bounds) },
              "concave snap never overlaps any display")
        check(!L.portals(sourceRect: rect).isEmpty,
              "concave snap shares at least one edge")
    }

    // defaultSourceOrigin returns a valid left/right-of-main placement.
    let def = d.defaultSourceOrigin(size: size, preferRight: false)
    check(def != nil && close(def!.x, -50), "default left-of-main")
    let defR = d.defaultSourceOrigin(size: size, preferRight: true)
    check(defR != nil && close(defR!.x, 100), "default right-of-main")

    // Non-finite proposed rejected cleanly.
    check(d.snappedSourceOrigin(proposed: CGPoint(x: CGFloat.nan, y: 0), size: size) == nil,
          "non-finite proposed rejected")
}

// MARK: - DesktopPortal boundary tests at interval endpoints.

private func portalBoundaryTests() {
    let d = desktop(1, [mk(1, 0, 0, 100, 100)])
    let s = CGRect(x: 100, y: 0, width: 100, height: 100) // to right of 1
    let portals = d.portals(sourceRect: s)
    check(portals.count == 1 && portals[0].sourceSide == .left,
          "right-of-receiver uses source left side")
    let portal = portals[0]
    // Half-open: tangent clamped to intervalEnd.nextDown.
    let t = portal.targetPoint(fromSourceEdge: CGPoint(x: 100, y: 100))
    check(t.y < portal.intervalEnd, "tangent remains half-open")
    check(d.contains(t), "near end still inside target")
    // Non-finite tangent falls back to intervalStart.
    let tnan = portal.targetPoint(fromSourceEdge: CGPoint(x: 100, y: CGFloat.nan))
    check(d.contains(tnan), "non-finite tangent clamps safely")
}

// MARK: - Native read is read-only; harness tolerates missing displays.

private func nativeReadNote() -> String {
    do {
        let d = try readReceiverDesktop(revision: 1)
        _asserts += 1
        if d.valid {
            // Validate no overlaps and ≤8.
            _asserts += 1
            let okCount = d.displays.count <= 8
            if !okCount { _fails.append("native read exceeded 8 displays") }
            // Validate stableIdentity canonical form where present.
            for disp in d.displays {
                _asserts += 1
                if let s = disp.stableIdentity, UUID(uuidString: s) == nil {
                    _fails.append("native read emitted non-canonical UUID \(s)")
                }
            }
            return "native: \(d.displays.count) displays, main=\(d.mainID)"
        } else {
            _fails.append("native read returned invalid topology")
            return "native: invalid"
        }
    } catch {
        // Headless / unstable environments are a known limitation of the harness.
        return "native: unavailable (\(error))"
    }
}


private func firstDefaultLayoutTests() {
    let physical=mk(11,0,0,1920,1080)
    let map=desktop(11,[physical])
    let virtualSize=CGSize(width:1512,height:950),sourceSize=CGSize(width:1280,height:800)
    let owned=map.defaultOwnedVirtualOrigin(size:virtualSize)
    check(owned==CGPoint(x:-1512,y:65),"first virtual left of physical centered")
    let virtual=mk(12,-1512,65,1512,950)
    let extended=desktop(11,[physical,virtual],12,2)
    let source=extended.defaultSourceOrigin(size:sourceSize)
    check(source==CGPoint(x:-2792,y:140),"first sender left of virtual centered")
    check(owned.map{$0.y+virtualSize.height/2}==physical.bounds.midY,"virtual/physical center match")
    check(source.map{$0.y+sourceSize.height/2}==virtual.bounds.midY,"sender/virtual center match")
    check(map.defaultSourceOrigin(size:sourceSize)==CGPoint(x:-1280,y:140),"pre-virtual source centered left of physical")
    let negative=desktop(21,[mk(21,-1000,-501,1200,901)])
    let odd=negative.defaultOwnedVirtualOrigin(size:CGSize(width:800,height:600))
    check(odd==CGPoint(x:-1800,y:-351),"odd center rounded to integer negative origin")
    check(odd.map{abs($0.y+300-negative.displays[0].bounds.midY)<=0.5}==true,"odd center at most half point error")
    let blocked=desktop(1,[mk(1,0,0,640,480),mk(2,-640,2000,640,480)])
    check(blocked.defaultOwnedVirtualOrigin(size:CGSize(width:640,height:480))==nil,"staggered leftmost without portal rejected")
    check(map.defaultOwnedVirtualOrigin(size:CGSize(width:CGFloat.nan,height:600))==nil,"nonfinite owned size rejected")
    check(extended.defaultOwnedVirtualOrigin(size:virtualSize)==nil,"physical-only map required for owned default")
    let rightVirtual=desktop(11,[physical,mk(12,1920,65,1512,950)],12)
    check(rightVirtual.defaultSourceOrigin(size:sourceSize)==CGPoint(x:-1280,y:140),"saved right virtual keeps valid source outside whole map")
    check(map.displays==[physical],"default geometry never mutates physical map")
}

/// Returns the number of failing assertions. 0 means every assertion passed.
/// Total assertions executed is written to stderr alongside each failure.
@discardableResult
public func runReceiverDesktopTests() -> Int {
    _asserts = 0
    _fails.removeAll()
    stableIdentityTests()
    validationTests()
    serializationTests()
    containmentTests()
    movementTests()
    portalTests()
    portalBoundaryTests()
    firstDefaultLayoutTests()
    _ = nativeReadNote()
    FileHandle.standardError.write(Data("ReceiverDesktopTests: \(_asserts) assertions, \(_fails.count) failures\n".utf8))
    for f in _fails { FileHandle.standardError.write(Data("FAIL: \(f)\n".utf8)) }
    return _fails.count
}

#if RECEIVER_DESKTOP_TESTS_MAIN
@main
enum ReceiverDesktopTestsMain {
    static func main() {
        exit(Int32(runReceiverDesktopTests() == 0 ? 0 : 1))
    }
}
#endif
