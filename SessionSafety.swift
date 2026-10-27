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
  #if TC_FRESH_RECEIVER_SAFETY
  failures += runDisplaySampleSafetyTests()
  #endif
  return failures
}

#if TC_FRESH_RECEIVER_SAFETY
/// Fixed at DisplayMode.start. UUID revision never reuses a prior latch state (ABA).
struct DisplaySafetyTicket: Equatable {
  let relayGeneration: UUID
  let safetyRevision: UUID
  let displayEpoch: UUID
}

/// Metadata plus notification fencing, NOT an atomic OS authorization primitive.
/// No TTL or precomputed allowed bit. Each payload owns exactly one fresh sample.
struct FreshSessionSafetySample {
  let snapshot: SessionSafetySnapshot
  let secureInput: Bool
  let startedAt: Double
  let snapshotFinishedAt: Double
  let finishedAt: Double
  var snapshotMs: Double {(snapshotFinishedAt-startedAt)*1000}
  var secureMs: Double {(finishedAt-snapshotFinishedAt)*1000}
  var sampleWorkerMs: Double {(finishedAt-startedAt)*1000}
  func valid(at now:Double)->Bool {
    startedAt.isFinite && snapshotFinishedAt.isFinite && finishedAt.isFinite && now.isFinite &&
      startedAt >= 0 && snapshotFinishedAt >= startedAt && finishedAt >= snapshotFinishedAt && now >= finishedAt
  }
}

/// Injectable reads/clock are worker-only hooks, including deterministic barriers.
/// Sampling holds no Relay state or lock and cannot delay stop/cancellation.
struct FreshSessionSafetySampler {
  var clock:()->Double = {ProcessInfo.processInfo.systemUptime}
  var snapshot:()->SessionSafetySnapshot = readSystemSessionSnapshot
  var secure:()->Bool = isSystemSecureInputEnabled
  func sample()->FreshSessionSafetySample {
    let start=clock(),state=snapshot(),middle=clock(),input=secure(),end=clock()
    return FreshSessionSafetySample(snapshot:state,secureInput:input,startedAt:start,snapshotFinishedAt:middle,finishedAt:end)
  }
}

/// Process-lifetime payload admission, shared by ALL replacement transports.
/// Zero-time semaphore acquisition never queues a native query or waits for one.
/// Retirement cannot release this permit: only return from the native reads can.
final class DisplayPayloadSafetyAdmission: @unchecked Sendable {
  static let shared=DisplayPayloadSafetyAdmission()
  private let permit=DispatchSemaphore(value:1)
  private init() {}
  enum Busy:Error {case nativeQueryInProgress}
  func sample(_ sampler:FreshSessionSafetySampler)throws->FreshSessionSafetySample {
    guard permit.wait(timeout:.now()) == .success else{throw Busy.nativeQueryInProgress}
    defer{permit.signal()}
    return sampler.sample()
  }
}

/// Main-owned one-outstanding permit. Retirement does not clear an in-flight
/// permit: a replacement cannot accumulate work behind a blocked native query.
struct DisplaySafetyPending {
  private(set) var token:UUID?
  mutating func begin()->UUID? {guard token == nil else{return nil};let id=UUID();token=id;return id}
  mutating func finish(_ id:UUID)->Bool {guard token==id else{return false};token=nil;return true}
}

func verifyDisplayPayloadAdmissionForTests()->Bool {
  guard Thread.isMainThread else{return false}
  let entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0),done=DispatchSemaphore(value:0)
  let countLock=NSLock();var snapshots=0,secureQueries=0
  let sampler=FreshSessionSafetySampler(snapshot:{
    countLock.lock();snapshots+=1;countLock.unlock()
    entered.signal();_ = release.wait(timeout:.now()+10)
    return .init(onConsole:true,loginDone:true,screenLocked:false)
  },secure:{countLock.lock();secureQueries+=1;countLock.unlock();return false})
  let admission=DisplayPayloadSafetyAdmission.shared
  DispatchQueue(label:"ThunderControl.admission.test").async {
    _ = try? admission.sample(sampler);done.signal()
  }
  guard entered.wait(timeout:.now()+2) == .success else{release.signal();return false}
  defer{release.signal()}
  for _ in 0..<6 {do{_ = try admission.sample(sampler);return false}catch{}}
  countLock.lock();let bounded=snapshots==1 && secureQueries==0;countLock.unlock()
  var pumped=false;DispatchQueue.main.async{pumped=true}
  let deadline=Date(timeIntervalSinceNow:1)
  while !pumped && Date()<deadline {_ = RunLoop.current.run(mode:.default,before:Date(timeIntervalSinceNow:0.005))}
  release.signal()
  guard done.wait(timeout:.now()+2) == .success else{return false}
  let healthy=FreshSessionSafetySampler(snapshot:{.init(onConsole:true,loginDone:true,screenLocked:false)},secure:{false})
  guard (try? admission.sample(healthy)) != nil else{return false}
  countLock.lock();let exact=snapshots==1 && secureQueries==1;countLock.unlock()
  return bounded && pumped && exact
}

func runDisplaySampleSafetyTests()->Int {
  var failures=0
  func check(_ value:Bool){if !value{failures+=1}}
  check(verifyDisplayPayloadAdmissionForTests())
  var snapshotCount=0,secureCount=0,time=1.0
  let sampler=FreshSessionSafetySampler(clock:{time+=1;return time},snapshot:{snapshotCount+=1;return .init(onConsole:true,loginDone:true,screenLocked:false)},secure:{secureCount+=1;return false})
  let sample=sampler.sample()
  check(snapshotCount==1 && secureCount==1 && sample.valid(at:5))
  check(sample.snapshotMs==1000 && sample.secureMs==1000 && sample.sampleWorkerMs==2000)
  check(!sample.valid(at:3) && !sample.valid(at:.nan))
  let unknown=FreshSessionSafetySampler(snapshot:{.init(onConsole:nil,loginDone:nil,screenLocked:nil)},secure:{false}).sample()
  check(sessionBlockReason(snapshot:unknown.snapshot,lockedSignal:false,sleeping:false,secureInput:unknown.secureInput) != nil)
  // No arbitrary slow-query threshold: a long but ordered timeline is valid.
  check(sample.valid(at:1_000_000))
  let reversed=FreshSessionSafetySample(snapshot:sample.snapshot,secureInput:false,startedAt:3,snapshotFinishedAt:2,finishedAt:4)
  check(!reversed.valid(at:5))
  let infinite=FreshSessionSafetySample(snapshot:sample.snapshot,secureInput:false,startedAt:1,snapshotFinishedAt:.infinity,finishedAt:.infinity)
  check(!infinite.valid(at:.infinity))
  var pending=DisplaySafetyPending();let first=pending.begin()!
  check(pending.begin()==nil);check(!pending.finish(UUID()));check(pending.begin()==nil)
  check(pending.finish(first));check(pending.begin() != nil)
  let generation=UUID(),epoch=UUID(),revision=UUID()
  let ticket=DisplaySafetyTicket(relayGeneration:generation,safetyRevision:revision,displayEpoch:epoch)
  check(ticket != DisplaySafetyTicket(relayGeneration:generation,safetyRevision:UUID(),displayEpoch:epoch))
  check(ticket != DisplaySafetyTicket(relayGeneration:UUID(),safetyRevision:revision,displayEpoch:epoch))
  check(ticket != DisplaySafetyTicket(relayGeneration:generation,safetyRevision:revision,displayEpoch:UUID()))
  return failures
}
#endif
