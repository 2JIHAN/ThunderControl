import AppKit
import CoreGraphics

/// In-memory NSEvent/CGEvent fixtures only. No event taps, HID access, or posting.
func runSystemControlKeyTests() -> Int {
  var failures = 0, checks = 0
  func check(_ value: Bool, _ label: String) {
    checks += 1
    if !value { failures += 1; print("SystemControlKey FAIL: \(label)") }
  }
  func fixture(_ data1: Int, subtype: Int16 = 8, flags: UInt64 = 0,
               type: NSEvent.EventType = .systemDefined, data2: Int = -1) -> CGEvent? {
    NSEvent.otherEvent(with: type, location: .zero,
      modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)), timestamp: 0,
      windowNumber: 0, context: nil, subtype: subtype, data1: data1, data2: data2)?.cgEvent
  }
  func serialized(_ event: CGEvent) -> CGEvent? {
    guard let bytes = event.data else { return nil }
    return CGEvent(withDataAllocator: nil, data: bytes)
  }
  func decodeFixture(_ data1: Int, subtype: Int16 = 8,
                     flags: UInt64 = 0) -> SystemControlKey? {
    guard let event = fixture(data1, subtype: subtype, flags: flags),
          let copy = serialized(event) else { check(false, "fixture serialization"); return nil }
    return SystemControlKey.decode(copy)
  }

  let codes: [UInt16] = [0, 1, 2, 3, 7]
  let safe = CGEventFlags.maskShift.rawValue | CGEventFlags.maskAlternate.rawValue
  for code in codes {
    for (low, down, repeatKey) in [(0x0a00, true, false), (0x0a01, true, true), (0x0b00, false, false)] {
      let expected = SystemControlKey(code: code, down: down, isRepeat: repeatKey, flags: safe)
      check(decodeFixture((Int(code) << 16) | low, flags: safe) == expected,
            "actual decoder serialized code=\(code) state=\(low)")
      guard let fresh = expected.makeEvent(), let copy = serialized(fresh),
            let native = NSEvent(cgEvent: copy) else {
        check(false, "fresh event round trip"); continue
      }
      check(SystemControlKey.decode(copy) == expected, "fresh round trip")
      check(native.type == .systemDefined && native.subtype.rawValue == 8 && native.data2 == -1,
            "fresh envelope")
      check(native.data1 == (Int(code) << 16) | low, "fresh packed state")
    }
  }
  // Playback, eject, power, keyboard illumination, and unknown NX key codes.
  for code in [4, 5, 6, 8, 10, 14, 16, 17, 18, 19, 20, 21, 22, 255, 65535] {
    check(decodeFixture((code << 16) | 0x0a00) == nil, "excluded code \(code)")
    check(SystemControlKey(code: UInt16(code), down: true).makeEvent() == nil, "synthesis excluded code")
  }
  for subtype: Int16 in [-1, 0, 7, 9, Int16.max] {
    check(decodeFixture(0x0a00, subtype: subtype) == nil, "wrong subtype")
  }
  for state in [0, 1, 0x0900, 0x0c00, 0x0a02, 0x0a80, 0x0aff, 0x0b01, 0x0b02, 0xffff] {
    check(decodeFixture(state) == nil, "malformed state/flags \(state)")
  }
  for raw in [-1, Int(Int32.min), Int(UInt32.max)] {
    check(decodeFixture(raw) == nil, "negative/invalid packed width or code")
  }
  // AppKit may narrow data1 to its on-wire 32-bit representation. If a wider
  // value survives that bridge it must be rejected, never silently bit-masked.
  for raw in [Int(UInt32.max) + 1 + 0x0a00, Int.max] {
    if let event = fixture(raw), let copy = serialized(event), let native = NSEvent(cgEvent: copy) {
      if native.data1 == raw {
        check(SystemControlKey.decode(copy) == nil, "wide data1 rejected")
      } else {
        check(native.data1 == Int(UInt32(truncatingIfNeeded: raw)) ||
              native.data1 == Int(Int32(truncatingIfNeeded: raw)), "explicit platform data1 narrowing")
      }
    } else { check(false, "wide fixture construction") }
  }
  if let wrongType = fixture(0x0a00, type: .applicationDefined) {
    check(SystemControlKey.decode(wrongType) == nil, "wrong outer event type")
  } else { check(false, "wrong type fixture") }
  if let ordinary = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) {
    check(SystemControlKey.decode(ordinary) == nil, "ordinary keyboard not media control")
  } else { check(false, "ordinary fixture") }

  for flags in [UInt64(0), CGEventFlags.maskShift.rawValue, CGEventFlags.maskAlternate.rawValue,
                safe, UInt64.max, CGEventFlags.maskCommand.rawValue | CGEventFlags.maskControl.rawValue] {
    let expected = SystemControlKey(code: 0, down: true, flags: flags)
    check(expected.flags == flags & safe, "initializer sanitizes modifiers")
    check(decodeFixture(0x0a00, flags: flags)?.flags == flags & safe, "decoder sanitizes modifiers")
    check(expected.makeEvent()?.flags.rawValue == flags & safe, "fresh event sanitizes modifiers")
  }
  if let marked = fixture(0x0a00, flags: safe, data2: 1234) {
    marked.setIntegerValueField(.eventSourceUserData, value: 0x54434d41524b)
    let before = marked.data
    if let key = SystemControlKey.decode(marked), let fresh = key.makeEvent() {
      check(fresh.getIntegerValueField(.eventSourceUserData) == 0, "peer marker stripped")
      check(NSEvent(cgEvent: fresh)?.data2 == -1, "peer auxiliary payload discarded")
    } else { check(false, "marked decode/synthesis") }
    check(marked.getIntegerValueField(.eventSourceUserData) == 0x54434d41524b, "input marker unchanged")
    check(before.map { $0 as Data } == marked.data.map { $0 as Data }, "decoder does not mutate original")
  } else { check(false, "marker fixture") }

  var held = SystemControlKeyState()
  for code in codes {
    // Drive ownership from the actual serialized-event decoder, not mock keys.
    guard let down = decodeFixture((Int(code) << 16) | 0x0a00),
          let repeatKey = decodeFixture((Int(code) << 16) | 0x0a01),
          let up = decodeFixture((Int(code) << 16) | 0x0b00) else {
      check(false, "ownership fixtures"); continue
    }
    check(!held.accept(up) && !held.accept(repeatKey), "unowned release/repeat rejected")
    check(held.pressed.isEmpty, "rejection preserves empty state")
    check(held.accept(down), "fresh down accepted")
    check(!held.accept(down) && held.pressed == [code], "duplicate fresh down rejected")
    check(held.accept(repeatKey) && held.accept(repeatKey) && held.pressed == [code], "owned repeats accepted")
    check(!held.accept(.init(code: code, down: false, isRepeat: true)), "repeat release rejected")
    check(held.pressed == [code], "malformed release preserves ownership")
    check(held.accept(up) && held.pressed.isEmpty && !held.accept(up), "one matching release")
  }
  check(!held.accept(.init(code: 6, down: true)) && held.pressed.isEmpty, "invalid descriptor cannot acquire")
  check(SystemControlKey(code: 0, down: false, isRepeat: true).makeEvent() == nil, "invalid release synthesis")
  for code in codes.reversed() { check(held.accept(.init(code: code, down: true, flags: safe)), "overlapping down") }
  check(held.pressed == Set(codes), "bounded overlapping ownership")
  let releases = held.releaseAll()
  check(releases == codes.map { SystemControlKey(code: $0, down: false) }, "deterministic held-only releases")
  check(held.pressed.isEmpty && held.releaseAll().isEmpty, "releaseAll clears and is idempotent")
  for release in releases {
    check(release.makeEvent().flatMap(serialized).flatMap(SystemControlKey.decode) == release,
          "cleanup release round trip")
  }
  check(!held.accept(.init(code: 0, down: true, isRepeat: true)), "post-cleanup repeat rejected")
  check(held.accept(.init(code: 0, down: true)), "fresh down after cleanup")
  print("SystemControlKey checks=\(checks) failures=\(failures); synthetic memory only, no capture/posting")
  return failures
}
