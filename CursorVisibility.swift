import CoreGraphics
import Foundation

/// Visibility-only ownership. Callers serialize on the main thread and schedule retries.
/// Construction has no OS effects; this controller never associates or warps the cursor.
final class CursorVisibilityController {
  private let api: CursorRecoveryAPI
  private var ownedDisplay: CGDirectDisplayID?
  private(set) var isHidden = false
  private(set) var leaseID: UUID?
  var needsRecovery: Bool { isHidden }

  init(api: CursorRecoveryAPI = SystemCursorRecoveryAPI()) {
    self.api = api
  }

  /// A successful hide owns exactly one matching show. Repeated hides are idempotent.
  @discardableResult
  func hide(display: CGDirectDisplayID) -> Bool {
    if isHidden { return ownedDisplay == display }
    guard api.hide(display: display) == .success else { return false }
    ownedDisplay = display
    leaseID = UUID()
    isHidden = true
    return true
  }

  /// A failed show retains ownership for a later retry. A stale retry cannot release
  /// a newer lease. An already restored controller requires no further work.
  @discardableResult
  func restore(expectedLeaseID: UUID? = nil) -> Bool {
    guard isHidden else { return true }
    if let expected = expectedLeaseID, expected != leaseID { return false }
    guard let display = ownedDisplay, api.show(display: display) == .success else {
      return false
    }
    isHidden = false
    ownedDisplay = nil
    leaseID = nil
    return true
  }
}

/// `sourceAuto` must be true only for a negotiated-capable sender that explicitly
/// advertises automatic mode. `localPhase` means the source owns local control.
func receiverCursorShouldHide(
  authenticated: Bool, enabled: Bool, sourceAuto: Bool,
  localPhase: Bool, localOverride: Bool
) -> Bool {
  authenticated && enabled && sourceAuto && localPhase && !localOverride
}
