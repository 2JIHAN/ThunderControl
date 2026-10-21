import Foundation
import CoreGraphics
func check(_ value: @autoclosure () -> Bool, _ name: String) {
    precondition(value(), name); print("PASS \(name)")
}
check(DockGestureCodec.supported, "runtime horizontal memory capability")
for phase in [1, 2, 4, 8] {
    let d = DockGestureDescriptor(motion: 1, phase: phase, progress: 0.25, velocityX: 1, velocityY: 0)
    let e = DockGestureCodec.makeEvent(d)!
    check(DockGestureCodec.inspect(e) == d, "scalar phase \(phase) memory roundtrip")
    check(DockGestureCodec.cancelledCopy(e) == nil, "generic cancellation unavailable")
    check(DockGestureCodec.encode(e) == nil, "opaque attachment preservation fails closed")
    if phase == 4 {
        let n = DockGestureCodec.neutralizedEndedCopy(e)!
        check(DockGestureCodec.inspect(n)!.progress == 0 && DockGestureCodec.inspect(n)!.velocityX == 0,
              "ended cleanup clone zero fields")
        check(DockGestureCodec.inspect(e) == d, "original remains unchanged")
    } else { check(DockGestureCodec.neutralizedEndedCopy(e) == nil, "non-ended cleanup rejected") }
}
check(DockGestureCodec.makeEvent(.init(motion: 2, phase: 1, progress: 0, velocityX: 0, velocityY: 0)) == nil, "vertical rejected")
check(DockGestureCodec.makeEvent(.init(motion: 1, phase: 1, progress: .nan, velocityX: 0, velocityY: 0)) == nil, "NaN rejected")
check(DockGestureCodec.makeEvent(.init(motion: 1, phase: 1, progress: 0, velocityX: .infinity, velocityY: 0)) == nil, "infinity rejected")
check(DockGestureCodec.makeEvent(.init(motion: 1, phase: 16, progress: 0, velocityX: 0, velocityY: 0)) == nil, "unknown phase rejected")
check(DockGestureCodec.decode(Data(repeating: 0, count: 65537)) == nil, "64KB cap")
check(DockGestureCodec.decode(Data()) == nil, "empty rejected")
check(DockGestureCodec.decode(Data([0,0,0,2])) == nil, "truncated rejected before CG parser")
check(DockGestureCodec.inspect(CGEvent(source: nil)!) == nil, "ordinary event rejected")
print("All tests memory-only: no capture, tap, post, permission request, or touch persistence.")

let vertical = DockGestureDescriptor(motion: 2, phase: 2, progress: 0.25, velocityX: 0, velocityY: 1)
let experimental = DockGestureCodec.makeExperimentalVerticalEvent(vertical)!
check(DockGestureCodec.inspectExperimentalVertical(experimental) == vertical, "experimental vertical scalar memory only")
check(DockGestureCodec.inspect(experimental) == nil, "primary inspect still rejects vertical")
check(DockGestureCodec.encode(experimental) == nil, "primary opaque encode rejects vertical")
check(DockGestureCodec.makeExperimentalVerticalEvent(.init(motion: 1, phase: 1, progress: 0, velocityX: 0, velocityY: 0)) == nil, "experimental API rejects horizontal")
