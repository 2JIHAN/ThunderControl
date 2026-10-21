import CoreGraphics

struct ModifierDescriptor {
  let aggregate: CGEventFlags
  let sideBit: UInt64
  let pairBits: UInt64
}
// Published device-specific masks from IOKit/hidsystem/IOLLEvent.h.
let modifierDescriptors: [CGKeyCode: ModifierDescriptor] = [
  56: .init(aggregate: .maskShift, sideBit: 0x2, pairBits: 0x6),
  60: .init(aggregate: .maskShift, sideBit: 0x4, pairBits: 0x6),
  59: .init(aggregate: .maskControl, sideBit: 0x1, pairBits: 0x2001),
  62: .init(aggregate: .maskControl, sideBit: 0x2000, pairBits: 0x2001),
  58: .init(aggregate: .maskAlternate, sideBit: 0x20, pairBits: 0x60),
  61: .init(aggregate: .maskAlternate, sideBit: 0x40, pairBits: 0x60),
  55: .init(aggregate: .maskCommand, sideBit: 0x8, pairBits: 0x18),
  54: .init(aggregate: .maskCommand, sideBit: 0x10, pairBits: 0x18),
  63: .init(aggregate: .maskSecondaryFn, sideBit: 0, pairBits: 0),
]

// nil means side information is absent or contradictory. Never infer a fresh
// per-key down from an aggregate flag shared by left and right keys.
func modifierDown(_ code: CGKeyCode, flags: CGEventFlags) -> Bool? {
  guard let d = modifierDescriptors[code] else { return nil }
  if d.pairBits == 0 { return flags.contains(d.aggregate) }
  let anySide = flags.rawValue & d.pairBits != 0
  guard flags.contains(d.aggregate) == anySide else { return nil }
  return flags.rawValue & d.sideBit != 0
}
func modifierGroupIsUp(_ group: UInt64, flags: CGEventFlags) -> Bool {
  guard let d = modifierDescriptors.values.first(where: { $0.aggregate.rawValue == group }) else {
    return false
  }
  return !flags.contains(d.aggregate) && flags.rawValue & d.pairBits == 0
}
func filteredModifierFlags(
  _ flags: CGEventFlags, orphanCodes: Set<CGKeyCode>, ambiguous: Set<UInt64>
) -> CGEventFlags {
  var raw = flags.rawValue
  var touched = Set<UInt64>()
  for code in orphanCodes {
    guard let d = modifierDescriptors[code] else { continue }
    touched.insert(d.aggregate.rawValue)
    raw &= ~d.sideBit
  }
  for group in touched.union(ambiguous) {
    guard let d = modifierDescriptors.values.first(where: { $0.aggregate.rawValue == group }) else {
      continue
    }
    if ambiguous.contains(group) {
      raw &= ~(group | d.pairBits)
    } else if d.pairBits == 0 || raw & d.pairBits == 0 {
      raw &= ~group
    }
  }
  return CGEventFlags(rawValue: raw)
}
func runModifierStateTests() -> Int {
  var failures = 0
  func check(_ condition: Bool) { if !condition { failures += 1 } }
  for pair: [CGKeyCode] in [[56, 60], [59, 62], [58, 61], [55, 54]] {
    let left = modifierDescriptors[pair[0]]!
    let right = modifierDescriptors[pair[1]]!
    let both = CGEventFlags(rawValue: left.aggregate.rawValue | left.pairBits)
    for first in [0, 1] {
      let second = 1 - first
      let remaining = modifierDescriptors[pair[second]]!
      let one = CGEventFlags(rawValue: remaining.aggregate.rawValue | remaining.sideBit)
      check(modifierDown(pair[0], flags: both) == true)
      check(modifierDown(pair[1], flags: both) == true)
      check(modifierDown(pair[first], flags: one) == false)
      check(modifierDown(pair[second], flags: one) == true)
      check(modifierDown(pair[second], flags: []) == false)
      let filtered = filteredModifierFlags(both, orphanCodes: [pair[first]], ambiguous: [])
      check(filtered.contains(left.aggregate))
      check(filtered.rawValue & remaining.sideBit != 0)
      check(filtered.rawValue & modifierDescriptors[pair[first]]!.sideBit == 0)
    }
    check(modifierDown(pair[0], flags: left.aggregate) == nil)
    check(modifierDown(pair[1], flags: left.aggregate) == nil)
    check(
      filteredModifierFlags(both, orphanCodes: [], ambiguous: [left.aggregate.rawValue])
        .intersection(left.aggregate).isEmpty)
    check(modifierGroupIsUp(left.aggregate.rawValue, flags: []))
    check(!modifierGroupIsUp(left.aggregate.rawValue, flags: CGEventFlags(rawValue: right.sideBit)))
  }
  check(modifierDown(63, flags: .maskSecondaryFn) == true)
  check(modifierDown(63, flags: []) == false)
  return failures
}
