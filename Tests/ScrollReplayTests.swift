import CoreGraphics

// Memory-only regression tests. No event tap, input capture or event posting.
func runScrollReplayTests() -> Int {
  var failures = 0
  var assertions = 0
  func check(_ condition: Bool) { assertions += 1; if !condition { failures += 1 } }
  for type in UInt32(0)...UInt32(40) {
    check(replayTapLocation(for: type) == ([22, 29, 30].contains(type) ? .cgSessionEventTap : .cghidEventTap))
  }
  let fields: [CGEventField] = [
    .scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2,
    .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2,
    .scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2,
    .scrollWheelEventIsContinuous, .scrollWheelEventScrollPhase,
    .scrollWheelEventMomentumPhase,
  ]
  let flags: [CGEventFlags] = [[], .init(rawValue: CGEventFlags.maskShift.rawValue | 0x2),
    .init(rawValue: CGEventFlags.maskShift.rawValue | 0x4),
    .init(rawValue: CGEventFlags.maskShift.rawValue | 0x6), [.maskControl, .maskAlternate, .maskCommand]]
  // Vertical, horizontal and diagonal fields, discrete and smooth devices,
  // normal/changed/end/cancel phases and momentum. Axis values are fixtures,
  // not an assertion about what a real mouse driver produces with Shift held.
  for flag in flags {
    for continuous in [Int64(0), 1] {
      for axes: [Int64] in [[3, 0], [0, -3], [2, -3], [0, 0]] {
        for phase in [Int64(0), 1, 2, 4, 8] {
          for momentum in [Int64(0), 1, 2, 3] {
            guard let event = CGEvent(scrollWheelEvent2Source: nil,
              units: continuous == 1 ? .pixel : .line, wheelCount: 2,
              wheel1: Int32(axes[0]), wheel2: Int32(axes[1]), wheel3: 0) else {
              check(false); continue
            }
            event.flags = flag
            let values: [Int64] = [axes[0], axes[1], axes[0] * 65536 + (axes[0] == 0 ? 0 : 16384),
              axes[1] * 65536, axes[0] * 12, axes[1] * 12, continuous, phase, momentum]
            for (field, value) in zip(fields, values) { event.setIntegerValueField(field, value: value) }
            guard let data = event.data,
              let decoded = CGEvent(withDataAllocator: nil, data: data) else { check(false); continue }
            check(decoded.type == .scrollWheel)
            check(decoded.flags == flag)
            check(replayTapLocation(for: decoded.type.rawValue) == .cgSessionEventTap)
            for (field, value) in zip(fields, values) { check(decoded.getIntegerValueField(field) == value) }
          }
        }
      }
    }
  }
  print("Scroll replay: \(assertions) memory assertions, \(failures) failures; no capture/posting, real Shift+wheel still requires two-Mac validation")
  return failures
}
