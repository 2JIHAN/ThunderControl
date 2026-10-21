import CoreGraphics

// Capture runs at cgSessionEventTap. Scroll data may already reflect source-side
// modifier-dependent axis processing. Replaying it upstream
// at HID risks processing it a second time. Keep axes, precision, flags, scroll
// phases and momentum untouched. Keyboard/button/motion and cleanup stay at HID.
func replayTapLocation(for rawType: UInt32) -> CGEventTapLocation {
  switch rawType {
  case CGEventType.scrollWheel.rawValue, 29, 30: return .cgSessionEventTap
  default: return .cghidEventTap
  }
}
