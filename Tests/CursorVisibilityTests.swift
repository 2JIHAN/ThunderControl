import CoreGraphics
import Foundation

/// Memory-only mock tests. No system API instances, cursor operations, or logging.
func runCursorVisibilityTests() -> Int {
  final class Mock: CursorRecoveryAPI {
    var hideResults: [CGError] = []
    var showResults: [CGError] = []
    var calls: [String] = []
    func associate(_ associated: Bool) -> CGError {
      calls.append(associated ? "associate" : "detach")
      return .failure
    }
    func warp(to point: CGPoint) -> CGError {
      calls.append("warp")
      return .failure
    }
    func hide(display: CGDirectDisplayID) -> CGError {
      calls.append("hide:\(display)")
      return hideResults.isEmpty ? .success : hideResults.removeFirst()
    }
    func show(display: CGDirectDisplayID) -> CGError {
      calls.append("show:\(display)")
      return showResults.isEmpty ? .success : showResults.removeFirst()
    }
  }
  var failures = 0
  func check(_ condition: Bool) { if !condition { failures += 1 } }
  func idle(_ controller: CursorVisibilityController) -> Bool {
    !controller.isHidden && !controller.needsRecovery && controller.leaseID == nil
  }
  var mocks: [Mock] = []

  do {
    let m = Mock(); mocks.append(m)
    let c = CursorVisibilityController(api: m)
    check(idle(c) && m.calls.isEmpty)
    check(c.restore() && c.restore(expectedLeaseID: UUID()))
    check(idle(c) && m.calls.isEmpty)
    check(c.hide(display: 7))
    let lease = c.leaseID
    check(c.isHidden && c.needsRecovery && lease != nil)
    for _ in 0..<5 { check(c.hide(display: 7)) }
    check(c.leaseID == lease && m.calls == ["hide:7"])
    check(!c.hide(display: 8))
    check(c.leaseID == lease && c.isHidden && m.calls == ["hide:7"])
    check(!c.restore(expectedLeaseID: UUID()))
    check(c.leaseID == lease && c.needsRecovery && m.calls == ["hide:7"])
    check(c.restore(expectedLeaseID: lease))
    check(idle(c) && m.calls == ["hide:7", "show:7"])
    check(c.restore() && c.restore(expectedLeaseID: lease))
    check(m.calls == ["hide:7", "show:7"])
    check(c.hide(display: 8))
    check(c.leaseID != nil && c.leaseID != lease)
    let newLease = c.leaseID
    check(!c.restore(expectedLeaseID: lease))
    check(c.leaseID == newLease && c.isHidden)
    check(m.calls == ["hide:7", "show:7", "hide:8"])
    check(c.restore())
    check(idle(c) && m.calls == ["hide:7", "show:7", "hide:8", "show:8"])
  }
  do {
    let m = Mock(); mocks.append(m)
    m.hideResults = [.failure, .illegalArgument, .success]
    let c = CursorVisibilityController(api: m)
    check(!c.hide(display: 42) && idle(c))
    check(c.restore() && m.calls == ["hide:42"])
    check(!c.hide(display: 43) && idle(c))
    check(c.restore(expectedLeaseID: UUID()))
    check(m.calls == ["hide:42", "hide:43"])
    check(c.hide(display: 44) && c.needsRecovery && c.leaseID != nil)
    check(c.restore())
    check(idle(c) && m.calls == ["hide:42", "hide:43", "hide:44", "show:44"])
  }
  do {
    let m = Mock(); mocks.append(m)
    m.showResults = [.failure, .illegalArgument, .success]
    let c = CursorVisibilityController(api: m)
    check(c.hide(display: 90))
    let lease = c.leaseID
    check(!c.restore(expectedLeaseID: lease))
    check(c.isHidden && c.needsRecovery && c.leaseID == lease)
    check(c.hide(display: 90) && !c.hide(display: 91))
    check(m.calls == ["hide:90", "show:90"])
    check(!c.restore(expectedLeaseID: UUID()))
    check(m.calls == ["hide:90", "show:90"])
    check(!c.restore())
    check(c.isHidden && c.needsRecovery && c.leaseID == lease)
    check(c.restore(expectedLeaseID: lease))
    check(idle(c) && m.calls == ["hide:90", "show:90", "show:90", "show:90"])
    check(c.restore() && m.calls.count == 4)
    check(c.hide(display: 91) && c.leaseID != lease)
    check(!c.restore(expectedLeaseID: lease))
    check(c.restore() && idle(c))
    check(m.calls == ["hide:90", "show:90", "show:90", "show:90", "hide:91", "show:91"])
  }

  // Exhaust every policy input combination, including legacy/disabled senders,
  // unauthenticated peers, remote-active control, and local override recovery.
  for mask in 0..<32 {
    let authenticated = mask & 1 != 0
    let enabled = mask & 2 != 0
    let sourceAuto = mask & 4 != 0
    let localPhase = mask & 8 != 0
    let localOverride = mask & 16 != 0
    check(receiverCursorShouldHide(
      authenticated: authenticated, enabled: enabled, sourceAuto: sourceAuto,
      localPhase: localPhase, localOverride: localOverride
    ) == (mask == 15))
  }
  for m in mocks {
    check(!m.calls.contains("associate"))
    check(!m.calls.contains("detach"))
    check(!m.calls.contains("warp"))
  }
  return failures
}
