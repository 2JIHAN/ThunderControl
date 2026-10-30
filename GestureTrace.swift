import Foundation
import CoreGraphics
import OSLog

// No event serialization, coordinates or identity. Optional user-requested debug system log contains only this fixed numeric allowlist.
enum GestureTraceStage: String, CaseIterable {
  case txCapture, txQueued, txWritten, rxDecoded, rxProjected, rxBuilt, rxPosted
  case txRejected, rxRejected
}
enum GestureTraceNote: String {
  case enabled, disabled, rejected, unsupported, invalidDescriptor, missingStream
}

final class GestureTrace {
  private let lock = NSLock()
  private let clock: () -> Double
  private let beforeNeutralAccounting: (() -> Void)?
  private let origin: Double
  private let lifetime: Double
  private let continuous: Bool
  private let sink: ((String) -> Void)?
  private let persistSystemLog:Bool
  private let systemLog=Logger(subsystem:"local.experimental.ThunderControl",category:"gesture")
  private var active = true
  private var deadline: Double
  private var generation: UInt64 = 0
  private var ring = [String?](repeating: nil, count: 2048)
  private var head = 0
  private var count = 0
  private var dropped: UInt64 = 0
  private var expired: UInt64 = 0
  private var neutralSkipped: UInt64 = 0

  init(persistSystemLog:Bool=false,recordingInitially:Bool=true,continuous:Bool=false,sink:((String)->Void)?=nil) {
    self.continuous = continuous; self.sink = sink
    beforeNeutralAccounting = nil
    active=recordingInitially
    self.persistSystemLog=persistSystemLog
    let now = ProcessInfo.processInfo.systemUptime
    clock = { ProcessInfo.processInfo.systemUptime }
    origin = now; deadline = now + 600; lifetime = 600
  }
  // Deterministic clock seam. Legacy default expiry remains ten minutes.
  init(testClock: @escaping () -> Double, continuous: Bool = false, sink: ((String) -> Void)? = nil, beforeNeutralAccounting: (() -> Void)? = nil) {
    self.continuous = continuous; self.sink = sink
    self.beforeNeutralAccounting = beforeNeutralAccounting
    persistSystemLog=false
    let now = testClock()
    clock = testClock; origin = now; deadline = now + 600; lifetime = 600
  }
  private func expireLocked(_ now: Double) {
    if active && (!now.isFinite || now < origin || (!continuous && now >= deadline)) {
      active = false; expired &+= 1; generation &+= 1
    }
  }
  private func acquireRecordingLock()->Bool {
    if continuous {return lock.try()}
    lock.lock();return true
  }
  var enabled: Bool {
    guard acquireRecordingLock() else{return false}
    defer { lock.unlock() }
    expireLocked(clock()); return active
  }
  func setEnabled(_ value: Bool) {
    lock.lock(); defer { lock.unlock() }
    let now = clock()
    active = value && now.isFinite
    deadline = now + lifetime
    generation &+= 1
  }
  func clear() {
    lock.lock(); defer { lock.unlock() }
    ring = [String?](repeating: nil, count: 2048)
    head = 0; count = 0; dropped = 0; expired = 0; neutralSkipped = 0; generation &+= 1
  }
  private func ticket() -> UInt64? {
    guard acquireRecordingLock() else{return nil}
    defer { lock.unlock() }
    expireLocked(clock())
    return active ? generation : nil
  }
  // Only UUIDs are admitted. Deterministic fixed-width hash tags correlate endpoints without echoing caller text.
  func shortTag(_ stream: String?) -> String {
    guard let stream = stream, stream.utf8.prefix(37).count == 36,
      let uuid = UUID(uuidString: stream) else { return "-" }
    var hash:UInt64 = 14695981039346656037
    for byte in uuid.uuidString.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
    return String(format: "%08x", UInt32(truncatingIfNeeded: hash))
  }
  static func number(_ value: Double) -> String {
    if value.isNaN { return "NaN" }
    if value == .infinity { return "+Inf" }
    if value == -.infinity { return "-Inf" }
    if abs(value) > 1_000_000_000 { return value < 0 ? "<-1e9" : ">1e9" }
    return String(format: "%.6g", locale: Locale(identifier: "en_US_POSIX"), value == 0 ? 0 : value)
  }
  private func append(_ text: String, ticket: UInt64) {
    guard acquireRecordingLock() else{return}
    let now = clock(); expireLocked(now)
    guard active, ticket == generation else { lock.unlock(); return }
    let line = "t=\(Self.number(max(0, now - origin))) " + text
    // All producers use fixed ASCII vocabulary, scalars, and bounded hex tags.
    let bounded = String(decoding: line.utf8.prefix(512), as: UTF8.self)
    if persistSystemLog {systemLog.notice("\(bounded,privacy:.public)")}
    if count == ring.count { ring[head] = bounded; head = (head + 1) % ring.count; dropped &+= 1 }
    else { ring[(head + count) % ring.count] = bounded; count += 1 }
    lock.unlock()
    // The production sink only enqueues. Never perform disk work under the trace lock.
    sink?(bounded)
  }
  private func context(_ stage: GestureTraceStage, _ sequence: UInt64?, _ stream: String?) -> String {
    "stage=\(stage.rawValue) seq=\(sequence.map(String.init) ?? "-") stream=\(shortTag(stream))"
  }
  private static func field(_ value: UInt32) -> CGEventField { CGEventField(rawValue: value)! }
  private static func isNative(_ event: CGEvent) -> Bool {
    // Check BOTH public type and private type so keyboard fixtures fail closed.
    let type = event.type.rawValue
    guard type == 29 || type == 30 else { return false }
    let nativeType = event.getIntegerValueField(field(55))
    return nativeType == 29 || nativeType == 30
  }
  private static func nativeFields(_ event: CGEvent) -> String {
    var result = "type55=\(event.getIntegerValueField(field(55)))"
    for id: UInt32 in [110, 123, 132] {
      result += " f\(id)=\(event.getIntegerValueField(field(id)))"
    }
    for id: UInt32 in [124, 129, 130] {
      result += " f\(id)=\(number(event.getDoubleValueField(field(id))))"
    }
    result += " f138i=\(event.getIntegerValueField(field(138))) f138d=\(number(event.getDoubleValueField(field(138))))"
    return result
  }
  private static func publicFields(_ descriptor: NativeGestureDescriptor, _ event: CGEvent?) -> String {
    var result = " publicKind=\(descriptor.kind.rawValue) publicPhase=\(descriptor.phase.rawValue)"
    guard let event = event, isNative(event), NativeGestureDescriptor.decode(event) == descriptor else { return result }
    // Only read these public scalars after the actual classifier accepted it.
    for id: UInt32 in [113, 114] {
      result += " f\(id)=\(number(event.getDoubleValueField(field(id))))"
    }
    result += " f115=\(event.getIntegerValueField(field(115)))"
    return result
  }
  func recordNative(stage: GestureTraceStage, event: CGEvent, sequence: UInt64? = nil, stream: String? = nil) {
    guard let token = ticket(), Self.isNative(event) else { return }
    let subtype=event.getIntegerValueField(Self.field(110))
    if (subtype == 23 || (event.type.rawValue == 29 && subtype == 0 && event.getIntegerValueField(Self.field(132)) == 0)),
       event.getIntegerValueField(Self.field(123)) == 0,
       event.getIntegerValueField(Self.field(138)) == 0,event.getDoubleValueField(Self.field(138)) == 0,
       [UInt32(124), 129, 130].allSatisfy({ event.getDoubleValueField(Self.field($0)) == 0 }) {
      beforeNeutralAccounting?()
      lock.lock()
      expireLocked(clock())
      if active && generation == token { neutralSkipped &+= 1 }
      lock.unlock()
      return
    }
    var text = context(stage, sequence, stream) + " native " + Self.nativeFields(event)
    if let descriptor = NativeGestureDescriptor.decode(event) {
      text += Self.publicFields(descriptor, event)
    }
    append(text, ticket: token)
  }
  func recordDock(stage: GestureTraceStage, descriptor: DockGestureDescriptor, sequence: UInt64? = nil,
                  stream: String? = nil, inverted: Bool? = nil) {
    guard let token = ticket() else { return }
    let text = context(stage, sequence, stream) + " dock flavor=NOT_CARRIED motion=\(descriptor.motion) phase=\(descriptor.phase) progress=\(Self.number(descriptor.progress)) vx=\(Self.number(descriptor.velocityX)) vy=\(Self.number(descriptor.velocityY)) inverted=\(inverted.map { $0 ? "true" : "false" } ?? "-")"
    append(text, ticket: token)
  }
  func recordApp(stage: GestureTraceStage, descriptor: NativeGestureDescriptor, event: CGEvent? = nil,
                 sequence: UInt64? = nil, stream: String? = nil) {
    guard let token = ticket(), descriptor.valid else { return }
    if let event = event, !Self.isNative(event) { return }
    append(context(stage, sequence, stream) + " app" + (event.map { " native " + Self.nativeFields($0) } ?? "") + Self.publicFields(descriptor, event), ticket: token)
  }
  func note(_ fixed: GestureTraceNote) {
    guard let token = ticket() else { return }
    append("note=\(fixed.rawValue)", ticket: token)
  }
  func snapshot() -> String {
    lock.lock()
    expireLocked(clock())
    let header = "GestureTrace memory-ring systemLog=\(persistSystemLog) enabled=\(active) lines=\(count) dropped=\(dropped) expired=\(expired) neutralSkipped=\(neutralSkipped) capacity=2048 maxLineBytes=512 ttlSeconds=\(continuous ? "continuous" : "600") time=process-relative"
    let lines = (0..<count).compactMap { ring[(head + $0) % ring.count] }
    lock.unlock()
    return ([header] + lines).joined(separator: "\n")
  }
}
