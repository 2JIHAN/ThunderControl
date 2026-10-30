import Foundation

// These stand-ins record production flush/enqueue calls without querying or posting OS input.
enum Edge { case left, right
  func outward(_ dx: Double) -> Bool { self == .right ? dx > 0 : dx < 0 }
}
struct CGVector { var dx: Double; var dy: Double }
struct Point { var x: Double = 0; var y: Double = 0; static let zero = Point() }
struct Flags { func subtracting(_ other: Flags) -> Flags { self } }
enum EventType { case mouseMoved }
enum Button { case left }
enum EventField { case mouseEventDeltaX, mouseEventDeltaY }
enum StateID { case hidSystemState }
enum CGEventSource { static func flagsState(_ state: StateID) -> Flags { Flags() } }
final class CGEvent {
  var flags = Flags()
  var data: Data? { Data([1]) }
  init?(mouseEventSource: Any?, mouseType: EventType, mouseCursorPosition: Point, mouseButton: Button) {}
  func setDoubleValueField(_ field: EventField, value: Double) {}
}
struct Desktop { var revision: UInt64 = 1 }
enum DesktopHandoffRouting {
  static func moved(_ p: Point, delta: CGVector, desktop: Desktop) -> Point {
    Point(x: min(99, max(0, p.x + delta.dx)), y: min(99, max(0, p.y + delta.dy)))
  }
}
struct Handoff {
  enum Phase { case remote, local }
  var phase = Phase.remote
  var token: String? = "replay"
  var x = 1.0; var y = 1.0; var width = 100.0; var height = 100.0
  mutating func relative(_ dx: Double, _ dy: Double) {
    x = min(99, max(0, x + dx)); y = min(99, max(0, y + dy))
  }
}
struct Wire {
  var kind: String; var session: String; var sequence: UInt64
  var raw: Int? = nil; var data: Data? = nil; var x: Double? = nil; var y: Double? = nil
  var token: String? = nil; var desktopMapRevision: UInt64? = nil
  var desktopGlobalX: Double? = nil; var desktopGlobalY: Double? = nil
  var inputLease: String? = nil
}
final class Context {
  var cancelled = false
  var terminalReason: String?
  func cancel(reason: String) { cancelled = true; terminalReason = reason }
}
struct Socket { var fd: Int32 = -1 }
struct BridgeInputLease { static let inputKinds: Set<String> = ["event"] }
struct Lease { var latest: String? = "lease"; func sourceFresh(now: Double) -> Bool { true } }
enum Stage { case txQueued, txWritten }
func connectionLog(_ s: String) {}
func seal(_ w: Wire, _ k: Int) throws -> Data { Data() }
func sendFrame(_ fd: Int32, _ data: Data) throws { fatalError("Cancelled replay must never reach transport") }
func safeConnectionError(_ error: Error) -> String { String(describing: error) }

final class TransitionReplayFixture {
  var entryMotion = EntryMotionBuffer()
  var handoff = Handoff()
  var desktopFocusSafety = true
  var multiDisplayDesktopCompatible = true
  var receiverDesktop: Desktop? = Desktop()
  var desktopHandoffRevision: UInt64? = 1
  var desktopGlobalPointer: Point? = Point()
  var desktopFocusFlushForTests: (() -> Bool)?
  var heldModifierMask = Flags()
  var session = "session"
  var bridgeInputSuspended = false
  var displayBarrier: Int?
  var lockedTransportOnly = false
  var lockedTransportEligible = true
  var key: Int? = 1
  var connection: Socket? = Socket()
  var context: Context? = Context()
  var pending = DispatchSemaphore(value: 128)
  var bridgeRecoveryCompatible = false
  var sender = true
  var bridgeLease = Lease()
  var seq: UInt64 = 0
  var generation = UUID()
  var localTCPOutgoingFrameForTests: ((Wire) -> Wire)?
  var out = DispatchQueue(label: "TransitionReplayFixture.writer")
  var lastEnqueueFailure = ""
  var polledSessionSuspensionOrigin = 0
  var queued: [Wire] = []
  var stopReasons: [String] = []
  func lockedTransportOutgoingAllowed(_ input: Wire) -> Bool { true }
  func currentSessionBlockReason() -> String? { nil }
  func sessionBecameUnsafe(_ reason: String, origin: Int) { stop(reason: reason) }
  func traceGesture(stage: Stage, packet: Wire) { if stage == .txQueued { queued.append(packet) } }
  func status(_ message: String) {}
  func stop(reason: String = "Local Stop") {
    stopReasons.append(reason)
    context?.cancel(reason: reason)
    handoff.phase = .local
  }
  func runReplay(count: Int, availableSlots: Int = 128) {
    precondition((0...128).contains(availableSlots))
    for _ in availableSlots..<128 { precondition(pending.wait(timeout: .now()) == .success) }
    entryMotion.begin(token: "replay")
    for i in 0..<count {
      precondition(entryMotion.append(token: "replay", dx: 1, dy: i.isMultiple(of: 2) ? -30 : 30))
    }
    let entered = DispatchSemaphore(value: 0)
    let released = DispatchSemaphore(value: 0)
    out.async { entered.signal(); released.wait() }
    precondition(entered.wait(timeout: .now() + 5) == .success)
    let ctx = context!
    let result = flushEntryMotion(token: "replay")
    let overloaded = count > availableSlots
    precondition(result == !overloaded)
    let accepted = min(count, availableSlots)
    precondition(queued.count == accepted && seq == UInt64(accepted))
    precondition(queued.enumerated().allSatisfy { $0.element.sequence == UInt64($0.offset) && $0.element.token == "replay" })
    if overloaded {
      precondition(lastEnqueueFailure == "Output queue full")
      precondition(stopReasons == ["Desktop transition flush failed"])
      precondition(ctx.cancelled && handoff.phase == .local)
    } else {
      precondition(lastEnqueueFailure.isEmpty && stopReasons.isEmpty)
      precondition(!ctx.cancelled && handoff.phase == .remote)
      ctx.cancel(reason: "Record-only writer drain")
    }
    precondition(entryMotion.count == 0)
    released.signal()
    out.sync {}
    for _ in 0..<availableSlots { precondition(pending.wait(timeout: .now()) == .success) }
    precondition(pending.wait(timeout: .now()) == .timedOut)
    for _ in 0..<128 { pending.signal() }
    print("PASS record-only existing replay: samples=\(count) availableTX=\(availableSlots) queued=\(queued.count) overload=\(overloaded) stop=\(stopReasons.first ?? "none"); no transport or OS input")
  }
