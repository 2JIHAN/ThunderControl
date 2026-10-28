import AppKit
import CoreGraphics

/// A bounded description, not a serialized event to replay. Only the five
/// display/audio controls below may cross this boundary; power and playback do not.
struct SystemControlKey: Equatable {
  let code: UInt16
  let down: Bool
  let isRepeat: Bool
  let flags: UInt64

  static let safeFlags = CGEventFlags.maskShift.rawValue | CGEventFlags.maskAlternate.rawValue

  init(code: UInt16, down: Bool, isRepeat: Bool = false, flags: UInt64 = 0) {
    self.code = code
    self.down = down
    self.isRepeat = isRepeat
    // Keep fine-step controls, never Command/Control, device-specific flags,
    // or any unknown bits from a remote event.
    self.flags = flags & Self.safeFlags
  }

  private static func permits(_ code: UInt16) -> Bool {
    switch code {
    case 0, 1, 2, 3, 7: return true
    default: return false
    }
  }

  var valid: Bool { Self.permits(code) && (down || !isRepeat) }

  static func decode(_ event: CGEvent) -> Self? {
    guard event.type.rawValue == 14,
          let native = NSEvent(cgEvent: event),
          native.type == .systemDefined, native.subtype.rawValue == 8,
          native.data1 >= 0, UInt64(native.data1) <= UInt64(UInt32.max) else { return nil }
    let packed = UInt32(native.data1)
    let code = UInt16(packed >> 16)
    // Low-byte bit 0 is repeat, and bits 8...15 must be exactly NX_KEYDOWN
    // or NX_KEYUP. Reject unknown low bits and a repeat-marked release.
    let down: Bool, isRepeat: Bool
    switch packed & 0xffff {
    case 0x0a00: down = true; isRepeat = false
    case 0x0a01: down = true; isRepeat = true
    case 0x0b00: down = false; isRepeat = false
    default: return nil
    }
    let key = Self(code: code, down: down, isRepeat: isRepeat, flags: event.flags.rawValue)
    // data2 and all event metadata are deliberately not transported.
    return key.valid ? key : nil
  }

  /// Creates a new in-memory event. The caller owns any subsequent posting and
  /// must apply its own loop-prevention marker rather than inherit peer metadata.
  func makeEvent() -> CGEvent? {
    guard valid else { return nil }
    let packed = (Int(code) << 16) | (down ? 0x0a00 : 0x0b00) | (isRepeat ? 1 : 0)
    guard let native = NSEvent.otherEvent(with: .systemDefined, location: .zero,
      modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags & Self.safeFlags)),
      timestamp: 0, windowNumber: 0, context: nil,
      subtype: 8, data1: packed, data2: -1), let event = native.cgEvent else { return nil }
    event.flags = CGEventFlags(rawValue: flags & Self.safeFlags)
    event.setIntegerValueField(.eventSourceUserData, value: 0)
    return event
  }
}

/// Pure per-connection ownership. At most five keys can be held. Rejected input
/// cannot acquire ownership, and disconnect releases only this connection's keys.
struct SystemControlKeyState {
  private(set) var pressed = Set<UInt16>()

  mutating func accept(_ key: SystemControlKey) -> Bool {
    guard key.valid else { return false }
    if key.down {
      if key.isRepeat { return pressed.contains(key.code) }
      return pressed.insert(key.code).inserted
    }
    return pressed.remove(key.code) != nil
  }

  mutating func releaseAll() -> [SystemControlKey] {
    let releases = pressed.sorted().map { SystemControlKey(code: $0, down: false) }
    pressed.removeAll()
    return releases
  }
}
