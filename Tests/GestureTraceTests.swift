import Foundation
import CoreGraphics

// Synthetic events never leave memory and are never posted.
func runGestureTraceTests() -> Int {
  var failures = 0
  func check(_ value: Bool, _ label: String) {
    if !value { failures += 1; print("GestureTrace FAIL: \(label)") }
  }
  let trace = GestureTrace()
  check(trace.enabled, "explicit debug defaults on")
  let keyboard = CGEvent(keyboardEventSource: nil, virtualKey: 12, keyDown: true)!
  keyboard.setIntegerValueField(.eventSourceUserData, value: 987654321)
  trace.recordNative(stage: .txCapture, event: keyboard)
  trace.recordApp(stage: .txCapture, descriptor: NativeGestureDescriptor(kind: .pinch, phase: .began), event: keyboard)
  check(trace.snapshot().contains("lines=0"), "keyboard excluded")
  let native = CGEvent(source: nil)!
  native.type = CGEventType(rawValue: 29)!
  native.setIntegerValueField(CGEventField(rawValue: 110)!, value: 99)
  native.setIntegerValueField(.eventSourceUserData, value: 987654321)
  trace.recordNative(stage: .rxDecoded, event: native, sequence: UInt64.max, stream: "SECRET-hostname-PIN")
  native.setIntegerValueField(CGEventField(rawValue: 110)!, value: 23)
  trace.recordNative(stage: .txCapture, event: native)
  check(trace.snapshot().contains("neutralSkipped=1"), "only exact neutral skipped")
  native.setIntegerValueField(CGEventField(rawValue: 138)!, value: 1)
  trace.recordNative(stage: .txCapture, event: native)
  check(trace.snapshot().contains("f138i=1"), "motion zero flavor retained")
  let zeroTrace=GestureTrace();let zero=CGEvent(source:nil)!;zero.type=CGEventType(rawValue:29)!;zero.setIntegerValueField(CGEventField(rawValue:55)!,value:29);zeroTrace.recordNative(stage:.txCapture,event:zero)
  check(zeroTrace.snapshot().contains("lines=0") && zeroTrace.snapshot().contains("neutralSkipped=1"),"empty type29 contact metadata does not flood ring")
  let first = trace.snapshot()
  check(first.contains("f110=99"), "unknown native subtype fixed metadata")
  check(!first.contains("987654321") && !first.contains("SECRET") && !first.contains("publicKind"), "no secret or inferred public data")
  check(trace.shortTag("secret") == "-", "reject arbitrary tag")
  let uuid = UUID().uuidString
  let tag = trace.shortTag(uuid)
  check(tag.count == 8 && tag.allSatisfy { $0.isHexDigit }, "bounded hex UUID tag")
  check(tag == trace.shortTag(uuid) && tag == GestureTrace().shortTag(uuid) && !first.contains(uuid), "tag stable across endpoints without full UUID")
  trace.setEnabled(false)
  let frozen = trace.snapshot()
  trace.note(.rejected)
  trace.recordNative(stage: .txCapture, event: native)
  check(trace.snapshot() == frozen, "disabled recording frozen")
  trace.setEnabled(true)
  trace.clear()
  for index in 0..<2100 {
    trace.recordDock(stage: .txQueued, descriptor: DockGestureDescriptor(motion: 1, phase: 2, progress: .nan, velocityX: .infinity, velocityY: -.infinity), sequence: UInt64(index))
  }
  let ring = trace.snapshot()
  check(ring.contains("lines=2048 dropped=52"), "ring overwrite accounting")
  check(ring.contains("seq=52 ") && !ring.contains("seq=51 ") && ring.contains("seq=2099 "), "ring order and bounds")
  check(ring.contains("NaN") && ring.contains("+Inf") && ring.contains("-Inf"), "nonfinite labels")
  check(ring.split(separator: "\n").dropFirst().allSatisfy { $0.utf8.count <= 512 }, "line byte bound")
  check(GestureTrace.number(.greatestFiniteMagnitude) == ">1e9" && GestureTrace.number(-.greatestFiniteMagnitude) == "<-1e9", "overflow stable")
  final class Clock {
    let lock = NSLock(); var value = 100.0
    func now() -> Double { lock.lock(); defer { lock.unlock() }; return value }
    func advance() { lock.lock(); value += 600; lock.unlock() }
  }
  let clock = Clock()
  let timed = GestureTrace(testClock: { clock.now() })
  timed.note(.enabled); clock.advance()
  check(!timed.enabled && timed.snapshot().contains("expired=1"), "monotonic expiry")
  let expired = timed.snapshot(); timed.note(.rejected)
  check(timed.snapshot() == expired, "snapshot does not reactivate")
  timed.setEnabled(true); timed.note(.enabled)
  check(timed.enabled && timed.snapshot().contains("lines=2"), "explicit renewal")
  trace.clear()
  DispatchQueue.concurrentPerform(iterations: 8) { _ in
    for index in 0..<100 {
      trace.note(.rejected)
      if index % 10 == 0 { _ = trace.snapshot(); _ = trace.enabled }
    }
  }
  check(trace.snapshot().contains("lines=800 dropped=0"), "parallel bounded append and snapshot")
  trace.clear()
  check(trace.snapshot().contains("lines=0 dropped=0 expired=0"), "clear")
  for continuous in [true, false] {
    let ticketReady = DispatchSemaphore(value: 0), snapshotHeld = DispatchSemaphore(value: 0)
    let releaseSnapshot = DispatchSemaphore(value: 0), producerDone = DispatchSemaphore(value: 0)
    let snapshotDone = DispatchSemaphore(value: 0)
    let stateLock = NSLock(); var holdSnapshot = false
    let contended = GestureTrace(testClock: {
      stateLock.lock(); let hold = holdSnapshot; holdSnapshot = false; stateLock.unlock()
      if hold { snapshotHeld.signal(); releaseSnapshot.wait() }
      return 100
    }, continuous: continuous, beforeNeutralAccounting: {
      ticketReady.signal(); snapshotHeld.wait()
    })
    let event = CGEvent(source: nil)!
    event.type = CGEventType(rawValue: 29)!
    event.setIntegerValueField(CGEventField(rawValue: 55)!, value: 29)
    DispatchQueue.global().async {
      contended.recordNative(stage: .txCapture, event: event); producerDone.signal()
    }
    check(ticketReady.wait(timeout: .now() + 5) == .success, "neutral ticket acquired")
    stateLock.lock(); holdSnapshot = true; stateLock.unlock()
    DispatchQueue.global().async { _ = contended.snapshot(); snapshotDone.signal() }
    let returnedWhileHeld = producerDone.wait(timeout: .now() + 0.25) == .success
    check(returnedWhileHeld == continuous, "neutral recording follows continuous try-lock or explicit blocking policy")
    releaseSnapshot.signal()
    if !returnedWhileHeld { check(producerDone.wait(timeout: .now() + 5) == .success, "producer joins after snapshot release") }
    check(snapshotDone.wait(timeout: .now() + 5) == .success, "snapshot joins")
    check(contended.snapshot().contains("neutralSkipped=\(continuous ? 0 : 1)"), "only counted neutral records increment counter")
  }
  print("GestureTrace tests failures=\(failures)")
  return failures
}
