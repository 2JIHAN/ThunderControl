import CoreGraphics

/// Includes identity and origin, not just display dimensions.
struct DisplayTopologySnapshot: Equatable {
  let mainID: CGDirectDisplayID
  let activeIDs: [CGDirectDisplayID]
  let bounds: CGRect
}

enum DisplayTopologyError: Error {
  case enumerationFailed(CGError)
  case unstableEnumeration
  case activeDisplayCount(Int)
  case mainDisplayMismatch
  case invalidBounds
  case topologyChanged
}

/// Pure validation shared by capture and mock-based tests. No operating-system calls.
func validateSingleDisplayTopology(
  mainID: CGDirectDisplayID,
  activeIDs: [CGDirectDisplayID],
  bounds: CGRect
) throws -> DisplayTopologySnapshot {
  guard activeIDs.count == 1 else {
    throw DisplayTopologyError.activeDisplayCount(activeIDs.count)
  }
  guard mainID != kCGNullDirectDisplay, activeIDs[0] == mainID else {
    throw DisplayTopologyError.mainDisplayMismatch
  }
  // Inspect stored components: CGRect's standardized accessors can hide negative sizes.
  guard bounds.origin.x.isFinite, bounds.origin.y.isFinite,
    bounds.size.width.isFinite, bounds.size.height.isFinite,
    bounds.size.width > 0, bounds.size.height > 0,
    (bounds.origin.x + bounds.size.width).isFinite,
    (bounds.origin.y + bounds.size.height).isFinite
  else {
    throw DisplayTopologyError.invalidBounds
  }
  return DisplayTopologySnapshot(
    mainID: mainID, activeIDs: activeIDs.sorted(), bounds: bounds
  )
}

private func readActiveDisplayIDs() throws -> [CGDirectDisplayID] {
  var required: UInt32 = 0
  let countResult = CGGetActiveDisplayList(0, nil, &required)
  guard countResult == .success else {
    throw DisplayTopologyError.enumerationFailed(countResult)
  }
  guard required == 1 else {
    throw DisplayTopologyError.activeDisplayCount(Int(required))
  }
  // Reserve an extra slot so a second display arriving between calls is observed.
  var ids = [CGDirectDisplayID](repeating: kCGNullDirectDisplay, count: 2)
  var actual: UInt32 = 0
  let listResult = ids.withUnsafeMutableBufferPointer {
    CGGetActiveDisplayList(UInt32($0.count), $0.baseAddress, &actual)
  }
  guard listResult == .success else {
    throw DisplayTopologyError.enumerationFailed(listResult)
  }
  guard actual == required else { throw DisplayTopologyError.unstableEnumeration }
  return Array(ids.prefix(Int(actual)))
}

/// Fail closed if enumeration or either independently validated endpoint changes.
/// Call fresh at begin, commit, while active, and on each monitoring timer tick.
func captureSingleDisplayTopology() throws -> DisplayTopologySnapshot {
  func endpoint() throws -> DisplayTopologySnapshot {
    let ids = try readActiveDisplayIDs()
    let main = CGMainDisplayID()
    return try validateSingleDisplayTopology(
      mainID: main, activeIDs: ids, bounds: CGDisplayBounds(main)
    )
  }
  let first = try endpoint()
  let second = try endpoint()
  guard first == second else { throw DisplayTopologyError.topologyChanged }
  return second
}

/// Pure endpoint comparison; BOTH endpoints must independently pass validation.
func validateDisplayTopologyEndpoints(
  initialMainID: CGDirectDisplayID,
  initialActiveIDs: [CGDirectDisplayID],
  initialBounds: CGRect,
  currentMainID: CGDirectDisplayID,
  currentActiveIDs: [CGDirectDisplayID],
  currentBounds: CGRect
) throws -> DisplayTopologySnapshot {
  let initial = try validateSingleDisplayTopology(
    mainID: initialMainID, activeIDs: initialActiveIDs, bounds: initialBounds
  )
  let current = try validateSingleDisplayTopology(
    mainID: currentMainID, activeIDs: currentActiveIDs, bounds: currentBounds
  )
  guard initial == current else { throw DisplayTopologyError.topologyChanged }
  return current
}

/// Returns the number of failed assertions. Uses mock data only, never OS calls.
@discardableResult
func runDisplayTopologyTests() -> Int {
  var failures = 0
  let normal = CGRect(x: 0, y: 0, width: 1920, height: 1080)
  func accepts(_ main: CGDirectDisplayID, _ ids: [CGDirectDisplayID], _ rect: CGRect) -> Bool {
    (try? validateSingleDisplayTopology(mainID: main, activeIDs: ids, bounds: rect)) != nil
  }
  func check(_ condition: Bool) { if !condition { failures += 1 } }
  check(accepts(1, [1], normal))
  let invalid: [(CGDirectDisplayID, [CGDirectDisplayID], CGRect)] = [
    (1, [1, 2], normal), (1, [], normal), (1, [2], normal), (0, [0], normal),
    (1, [1], CGRect(x: 0, y: 0, width: 0, height: 10)),
    (1, [1], CGRect(x: 0, y: 0, width: 10, height: -1)),
    (1, [1], CGRect(x: CGFloat.infinity, y: 0, width: 10, height: 10)),
    (1, [1], CGRect(x: 0, y: CGFloat.nan, width: 10, height: 10)),
    (1, [1], CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 10)),
    (1, [1], CGRect(x: 0, y: 0, width: 10, height: CGFloat.nan)),
  ]
  for (main, ids, rect) in invalid {
    check(!accepts(main, ids, rect))
    // Invalid initial and invalid current endpoints must each be rejected.
    check(
      (try? validateDisplayTopologyEndpoints(
        initialMainID: main, initialActiveIDs: ids, initialBounds: rect,
        currentMainID: 1, currentActiveIDs: [1], currentBounds: normal
      )) == nil)
    check(
      (try? validateDisplayTopologyEndpoints(
        initialMainID: 1, initialActiveIDs: [1], initialBounds: normal,
        currentMainID: main, currentActiveIDs: ids, currentBounds: rect
      )) == nil)
  }
  let changes: [(CGDirectDisplayID, [CGDirectDisplayID], CGRect)] = [
    (2, [2], normal),  // Same bounds, substituted display identity.
    (1, [1], CGRect(x: 1, y: 0, width: 1920, height: 1080)),
    (1, [1], CGRect(x: 0, y: 1, width: 1920, height: 1080)),
    (1, [1], CGRect(x: 0, y: 0, width: 1919, height: 1080)),
    (1, [1], CGRect(x: 0, y: 0, width: 1920, height: 1079)),
  ]
  for (main, ids, rect) in changes {
    check(
      (try? validateDisplayTopologyEndpoints(
        initialMainID: 1, initialActiveIDs: [1], initialBounds: normal,
        currentMainID: main, currentActiveIDs: ids, currentBounds: rect
      )) == nil)
  }
  check(
    (try? validateDisplayTopologyEndpoints(
      initialMainID: 1, initialActiveIDs: [1], initialBounds: normal,
      currentMainID: 1, currentActiveIDs: [1], currentBounds: normal
    )) != nil)
  return failures
}
