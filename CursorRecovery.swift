import CoreGraphics
import Foundation

/// Implementations and callers must be serialized on the main thread. No private APIs.
public protocol CursorRecoveryAPI {
  func associate(_ associated: Bool) -> CGError
  func hide(display: CGDirectDisplayID) -> CGError
  func show(display: CGDirectDisplayID) -> CGError
  func warp(to point: CGPoint) -> CGError
}

// Only for a restored LOCAL cursor. Never use while a remote detach lease exists.
// Public API workaround for post-warp hardware-motion suppression; no global policy change.
func warpRestoredLocalCursor(to point:CGPoint,warp:(CGPoint)->CGError,resume:()->CGError)->CGError {
  let result=warp(point)
  guard result == .success else{return result}
  return resume()
}

public struct SystemCursorRecoveryAPI: CursorRecoveryAPI {
  public init() {}
  public func associate(_ associated: Bool) -> CGError {
    CGAssociateMouseAndMouseCursorPosition(associated ? 1 : 0)
  }
  public func hide(display: CGDirectDisplayID) -> CGError { CGDisplayHideCursor(display) }
  public func show(display: CGDirectDisplayID) -> CGError { CGDisplayShowCursor(display) }
  public func warp(to point: CGPoint) -> CGError {
    warpRestoredLocalCursor(to:point,warp:{CGWarpMouseCursorPosition($0)},resume:{CGAssociateMouseAndMouseCursorPosition(1)})
  }
}

public enum CursorRecoveryError: Error, Equatable, CustomStringConvertible {
  case outstandingResources
  case staleLease
  case operation(String, Int32)

  public var description: String {
    switch self {
    case .outstandingResources: return "Cursor resources still belong to an outstanding lease."
    case .staleLease: return "Ignored recovery for a stale cursor lease."
    case .operation(let name, let code): return "\(name) failed (CGError \(code))."
    }
  }
}

public struct RecoveryOutcome {
  /// True only when no detach or hide ownership remains.
  public let recovered: Bool
  public let errors: [CursorRecoveryError]
  public let warnings: [CursorRecoveryError]
  public let restoreAttempt: Int
  public let automaticRetriesRemaining: Int
  public var shouldRetry: Bool { !recovered && automaticRetriesRemaining > 0 }
}

/// A single outstanding cursor lease. Constructing this object has no OS effects.
/// Inject a mock API for tests. The parent owns serialization and timer scheduling.
/// Capture leaseID in retry closures, independently of application session tokens.
public final class CursorRecoveryController {
  public private(set) var isDetached = false
  public private(set) var isHidden = false
  public private(set) var ownedDisplayID: CGDirectDisplayID?
  public private(set) var leaseID: UUID?
  public private(set) var restoreAttempts = 0
  public let maximumAutomaticRetries: Int
  public var needsRecovery: Bool { isDetached || isHidden }
  public var canAcquire: Bool { !needsRecovery }

  private let apiFactory: () -> CursorRecoveryAPI
  private lazy var api: CursorRecoveryAPI = apiFactory()
  private var restoreStarted = false
  private var pendingWarp: CGPoint?

  public init(
    maximumAutomaticRetries: Int = 3,
    apiFactory: @escaping () -> CursorRecoveryAPI = { SystemCursorRecoveryAPI() }
  ) {
    self.maximumAutomaticRetries = max(0, maximumAutomaticRetries)
    self.apiFactory = apiFactory
  }

  public convenience init(api: CursorRecoveryAPI, maximumAutomaticRetries: Int = 3) {
    self.init(maximumAutomaticRetries: maximumAutomaticRetries, apiFactory: { api })
  }

  /// Failure includes rollback errors, if any. Inspect needsRecovery even on failure.
  public func acquire(display: CGDirectDisplayID) -> Result<Void, AcquisitionFailure> {
    guard canAcquire else {
      return .failure(AcquisitionFailure(errors: [.outstandingResources]))
    }
    restoreAttempts = 0
    restoreStarted = false
    pendingWarp = nil
    let detach = api.associate(false)
    guard detach == .success else {
      return .failure(AcquisitionFailure(errors: [.operation("detach", detach.rawValue)]))
    }
    isDetached = true
    leaseID = UUID()
    let hide = api.hide(display: display)
    guard hide == .success else {
      // Hide was not acquired, so never issue a compensating show.
      let rollback = restore(point: nil)
      return .failure(
        AcquisitionFailure(errors: [.operation("hide", hide.rawValue)] + rollback.errors))
    }
    isHidden = true
    ownedDisplayID = display
    return .success(())
  }

  public struct AcquisitionFailure: Error, CustomStringConvertible {
    public let errors: [CursorRecoveryError]
    public var description: String { errors.map { $0.description }.joined(separator: "; ") }
  }

  /// The first restore call fixes the optional warp target. Later calls cannot introduce
  /// a delayed target. Warp runs at most once, only after all resources are restored.
  /// Failed warp is a warning and is NEVER retried. Failed resource operations retain
  /// ownership. Automatic callers must honor shouldRetry (initial attempt + N retries).
  /// Explicit/manual recovery remains possible after that automatic budget is exhausted.
  @discardableResult
  public func restore(point: CGPoint?, expectedLeaseID: UUID? = nil) -> RecoveryOutcome {
    if let expected = expectedLeaseID, expected != leaseID {
      return outcome(errors: [.staleLease], warnings: [], allowRetry: false)
    }
    guard needsRecovery else { return outcome(errors: [], warnings: []) }
    if !restoreStarted {
      restoreStarted = true
      pendingWarp = point
    }
    restoreAttempts += 1
    var errors: [CursorRecoveryError] = []
    var warnings: [CursorRecoveryError] = []
    if isDetached {
      let result = api.associate(true)
      if result == .success {
        isDetached = false
      } else {
        errors.append(.operation("reassociate", result.rawValue))
      }
    }
    if isHidden, let display = ownedDisplayID {
      let result = api.show(display: display)
      if result == .success {
        isHidden = false
        ownedDisplayID = nil
      } else {
        errors.append(.operation("show", result.rawValue))
      }
    }
    if !needsRecovery {
      if let target = pendingWarp {
        pendingWarp = nil  // Consume before attempting; a failure never causes a late jump.
        let result = api.warp(to: target)
        if result != .success { warnings.append(.operation("warp", result.rawValue)) }
      }
      leaseID = nil
    }
    return outcome(errors: errors, warnings: warnings)
  }

  private func outcome(
    errors: [CursorRecoveryError], warnings: [CursorRecoveryError],
    allowRetry: Bool = true
  ) -> RecoveryOutcome {
    let remaining =
      needsRecovery && allowRetry
      ? max(0, maximumAutomaticRetries - max(0, restoreAttempts - 1)) : 0
    return RecoveryOutcome(
      recovered: !needsRecovery, errors: errors, warnings: warnings,
      restoreAttempt: restoreAttempts, automaticRetriesRemaining: remaining)
  }
}

/// Pure mock tests: returns failed assertion count. Never constructs the real API.
public func runCursorRecoveryTests() -> Int {
  final class Mock: CursorRecoveryAPI {
    var detach: [CGError] = []
    var attach: [CGError] = []
    var hides: [CGError] = []
    var shows: [CGError] = []
    var warps: [CGError] = []
    var calls: [String] = []
    func next(_ values: inout [CGError]) -> CGError {
      values.isEmpty ? .success : values.removeFirst()
    }
    func associate(_ associated: Bool) -> CGError {
      calls.append(associated ? "attach" : "detach")
      return associated ? next(&attach) : next(&detach)
    }
    func hide(display: CGDirectDisplayID) -> CGError {
      calls.append("hide:\(display)")
      return next(&hides)
    }
    func show(display: CGDirectDisplayID) -> CGError {
      calls.append("show:\(display)")
      return next(&shows)
    }
    func warp(to point: CGPoint) -> CGError {
      calls.append("warp")
      return next(&warps)
    }
  }
  var failures = 0
  func check(_ condition: Bool) { if !condition { failures += 1 } }
  func succeeded(_ result: Result<Void, CursorRecoveryController.AcquisitionFailure>) -> Bool {
    if case .success = result { return true }
    return false
  }
  do {
    let m = Mock()
    m.detach = [.failure]
    let c = CursorRecoveryController(api: m)
    check(!succeeded(c.acquire(display: 7)))
    check(c.canAcquire && !c.needsRecovery && m.calls == ["detach"])
  }
  do {
    let m = Mock()
    m.hides = [.failure]
    m.attach = [.failure, .success]
    let c = CursorRecoveryController(api: m)
    let result = c.acquire(display: 7)
    check(!succeeded(result))
    if case .failure(let error) = result { check(error.errors.count == 2) }
    check(c.isDetached && !c.isHidden && !c.canAcquire)
    let count = m.calls.count
    check(!succeeded(c.acquire(display: 8)) && m.calls.count == count)
    check(c.restore(point: CGPoint(x: 1, y: 2)).recovered)
    check(!m.calls.contains("warp") && !m.calls.contains("show:7"))
  }
  do {
    let m = Mock()
    m.attach = [.failure, .success]
    m.shows = [.failure, .success]
    let c = CursorRecoveryController(api: m)
    check(succeeded(c.acquire(display: 42)))
    let id = c.leaseID!
    let a = c.restore(point: CGPoint(x: 2, y: 3), expectedLeaseID: id)
    check(!a.recovered && a.errors.count == 2 && a.shouldRetry)
    check(c.isDetached && c.isHidden && c.ownedDisplayID == 42)
    check(c.restore(point: nil, expectedLeaseID: id).recovered)
    let count = m.calls.count
    check(c.restore(point: nil).recovered && m.calls.count == count)
    check(m.calls.filter { $0 == "warp" }.count == 1)
    check(m.calls.filter { $0 == "show:42" }.count == 2)
    check(succeeded(c.acquire(display: 43)))
    let before = m.calls.count
    check(c.restore(point: nil, expectedLeaseID: id).errors == [.staleLease])
    check(m.calls.count == before && c.needsRecovery)
    _ = c.restore(point: nil)
  }
  do {
    let m = Mock()
    m.warps = [.failure]
    let c = CursorRecoveryController(api: m)
    check(succeeded(c.acquire(display: 9)))
    let a = c.restore(point: .zero)
    check(a.recovered && a.errors.isEmpty && a.warnings.count == 1)
    _ = c.restore(point: CGPoint(x: 100, y: 100))
    check(m.calls == ["detach", "hide:9", "attach", "show:9", "warp"])
  }
  do {
    let m = Mock()
    m.attach = Array(repeating: .failure, count: 4)
    let c = CursorRecoveryController(api: m)
    check(succeeded(c.acquire(display: 1)))
    for attempt in 1...4 {
      let a = c.restore(point: nil)
      check(!a.recovered && a.restoreAttempt == attempt)
      check(a.automaticRetriesRemaining == 4 - attempt)
      check(a.shouldRetry == (attempt < 4))
    }
    check(c.isDetached && !c.isHidden && !c.canAcquire)
    check(m.calls.filter { $0 == "show:1" }.count == 1)
    check(c.restore(point: nil).recovered)  // Explicit recovery after automatic budget.
  }
  return failures
}
