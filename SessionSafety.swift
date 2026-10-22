import AppKit
import CoreGraphics
import Carbon

/// Only session metadata booleans. nil means unavailable, not false.
struct SessionSafetySnapshot: Equatable {
  let onConsole: Bool?
  let loginDone: Bool?
  let screenLocked: Bool?

  init(onConsole: Bool?, loginDone: Bool?, screenLocked: Bool?) {
    self.onConsole = onConsole
    self.loginDone = loginDone
    self.screenLocked = screenLocked
  }
}

/// Secure Input is an OS event-delivery restriction, not evidence of a locked
/// session. Keep authenticated connections by default; never disable or bypass
/// macOS Secure Input. Strict callers may explicitly retain the old stop policy.
enum SecureInputSessionPolicy { case keepConnection, stopSession }

/// Pure, stateless policy. A non-nil result must stop ALL relay traffic,
/// including mouse movement, clicks, scrolling, keys and modifiers.
/// The caller owns notification latches, cancellation and re-arming. In
/// particular, an absent/false supplemental lock key must not clear a latch.
/// nil only permits the session gate; it does not authorize automatic resume.
func sessionBlockReason(
  snapshot: SessionSafetySnapshot,
  lockedSignal: Bool,
  sleeping: Bool,
  secureInput: Bool,
  secureInputPolicy: SecureInputSessionPolicy = .keepConnection
) -> String? {
  if sleeping { return "System is sleeping" }
  if lockedSignal { return "Session lock signal is active" }
  if secureInput && secureInputPolicy == .stopSession { return "Secure input is enabled" }
  if snapshot.screenLocked == true { return "Session reports screen locked" }
  guard let onConsole = snapshot.onConsole else { return "Console session state is unavailable" }
  guard let loginDone = snapshot.loginDone else { return "Session login state is unavailable" }
  if !onConsole { return "Session is not on console" }
  if !loginDone { return "Session login is incomplete" }
  return nil
}

/// Read-only metadata sampling. No observers, event capture, injection, settings
/// changes, identity extraction or raw dictionary logging.
///
/// kCGSessionOnConsoleKey and kCGSessionLoginDoneKey are public required fields.
/// CGSSessionScreenIsLocked is an UNDOCUMENTED optional dictionary key, not a
/// published lock-state API. Only an explicit CFBoolean true supplements the
/// caller's lock signal. Absence/false is NOT proof that the screen is unlocked.
/// A snapshot is not atomic with subsequent events; callers must also gate every
/// relay path and cancel active forwarding on lock/sleep/resign notifications.
func readSystemSessionSnapshot() -> SessionSafetySnapshot {
  guard let session = CGSessionCopyCurrentDictionary() else {
    return SessionSafetySnapshot(onConsole: nil, loginDone: nil, screenLocked: nil)
  }
  let dictionary = session as NSDictionary
  func boolean(_ key: String) -> Bool? {
    guard let value = dictionary.object(forKey: key),
          CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() else { return nil }
    return (value as? NSNumber)?.boolValue
  }
  return SessionSafetySnapshot(
    onConsole: boolean(kCGSessionOnConsoleKey as String),
    loginDone: boolean(kCGSessionLoginDoneKey as String),
    screenLocked: boolean("CGSSessionScreenIsLocked")
  )
}

/// Public HIToolbox read-only query. Does not enable or disable secure input.
func isSystemSecureInputEnabled() -> Bool {
  return IsSecureEventInputEnabled()
}

/// Returns the failure count, zero on success. No live OS state is required.
/// Exhausts 27 optional-field combinations x 8 signal combinations x 2 policies,
/// then checks explicit state transitions and reason selection.
func runSessionSafetyTests() -> Int {
  var failures = 0
  func check(_ condition: Bool) { if !condition { failures += 1 } }
  let values: [Bool?] = [nil, false, true]
  for onConsole in values {
    for loginDone in values {
      for screenLocked in values {
        for lockedSignal in [false, true] {
          for sleeping in [false, true] {
            for secureInput in [false, true] {
              let state = SessionSafetySnapshot(
                onConsole: onConsole, loginDone: loginDone, screenLocked: screenLocked)
              for policy: SecureInputSessionPolicy in [.keepConnection, .stopSession] {
                let reason = sessionBlockReason(
                  snapshot: state, lockedSignal: lockedSignal,
                  sleeping: sleeping, secureInput: secureInput, secureInputPolicy: policy)
                let allowed = onConsole == true && loginDone == true && screenLocked != true
                  && !lockedSignal && !sleeping && !(secureInput && policy == .stopSession)
                check((reason == nil) == allowed)
                if let reason = reason { check(!reason.isEmpty) }
              }
            }
          }
        }
      }
    }
  }
  let ready = SessionSafetySnapshot(onConsole: true, loginDone: true, screenLocked: nil)
  let unlocked = SessionSafetySnapshot(onConsole: true, loginDone: true, screenLocked: false)
  let locked = SessionSafetySnapshot(onConsole: true, loginDone: true, screenLocked: true)
  let unknown = SessionSafetySnapshot(onConsole: nil, loginDone: nil, screenLocked: nil)
  func reason(_ state: SessionSafetySnapshot, _ lock: Bool = false,
              _ sleep: Bool = false, _ secure: Bool = false) -> String? {
    return sessionBlockReason(snapshot: state, lockedSignal: lock,
                              sleeping: sleep, secureInput: secure)
  }
  check(reason(ready) == nil)
  check(reason(ready, true) == "Session lock signal is active")
  check(reason(unlocked, true) != nil) // Supplemental false cannot override latch.
  check(reason(locked) == "Session reports screen locked")
  check(reason(locked, false) != nil) // An unlock signal cannot override true metadata.
  check(reason(unlocked) == nil)
  check(reason(ready) == nil) // Missing optional key alone never claims locked.
  check(reason(ready, false, true) == "System is sleeping")
  check(reason(ready, false, false, true) == nil)
  check(sessionBlockReason(snapshot: ready, lockedSignal: false, sleeping: false,
    secureInput: true, secureInputPolicy: .stopSession) == "Secure input is enabled")
  check(reason(ready) == nil) // Wake/secure-input end: policy is stateless.
  check(reason(unknown) == "Console session state is unavailable")
  check(reason(.init(onConsole: true, loginDone: nil, screenLocked: false))
        == "Session login state is unavailable")
  check(reason(.init(onConsole: false, loginDone: true, screenLocked: nil))
        == "Session is not on console")
  check(reason(.init(onConsole: true, loginDone: false, screenLocked: nil))
        == "Session login is incomplete")
  check(reason(unknown, true, true, true) == "System is sleeping")
  check(reason(unknown, true, false, true) == "Session lock signal is active")
  check(reason(unknown, false, false, true) == "Console session state is unavailable")
  check(reason(locked, false, false, true) == "Session reports screen locked")
  check(reason(.init(onConsole: nil, loginDone: nil, screenLocked: true))
        == "Session reports screen locked")
  return failures
}
