import Foundation
import CoreGraphics

/// System gesture parameters only, never touch contacts or finger count.
public struct DockGestureDescriptor: Codable, Equatable {
    public let motion: Int
    public let phase: Int
    public let progress: Double
    public let velocityX: Double
    public let velocityY: Double
    public enum Flavor: String { case spaces, missionControl }
    public enum Phase: Int { case began = 1, changed = 2, ended = 4, cancelled = 8 }
    public var flavor: Flavor { motion == 2 ? .missionControl : .spaces } // Vertical is experimental vocabulary only.
    public var gesturePhase: Phase? { Phase(rawValue: phase) }
    public init(motion: Int, phase: Int, progress: Double, velocityX: Double, velocityY: Double) {
        self.motion = motion; self.phase = phase; self.progress = progress
        self.velocityX = velocityX; self.velocityY = velocityY
    }
}

public enum DockGestureCodec {
    public static let maximumDataSize = 65_536
    private static func field(_ n: UInt32) -> CGEventField { CGEventField(rawValue: n)! }
    // No undocumented symbol or guessed ABI. Linking public CG APIs establishes
    // symbol availability. Exact build + user opt-in gates are the caller's duty.
    public static let supported: Bool = {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27,
              let e = DGCreateMemoryFixture() else { return false }
        return inspect(e) != nil
    }()
    private static func valid(_ d: DockGestureDescriptor) -> Bool {
        // Intentionally tighter than fixed16.16 representable range; bound all
        // floating inputs before the ISC C conversion (including NaN/infinity).
        d.motion == 1 && DockGestureDescriptor.Phase(rawValue: d.phase) != nil &&
        d.progress.isFinite && abs(d.progress) <= 1 &&
        d.velocityX.isFinite && abs(d.velocityX) <= 10_000 &&
        d.velocityY.isFinite && abs(d.velocityY) <= 10_000
    }
    public static func inspect(_ event: CGEvent) -> DockGestureDescriptor? {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27,
              event.getIntegerValueField(field(55)) == 30,
              event.getIntegerValueField(field(110)) == 23 else { return nil }
        let d = DockGestureDescriptor(motion: Int(event.getIntegerValueField(field(123))),
            phase: Int(event.getIntegerValueField(field(132))),
            progress: event.getDoubleValueField(field(124)),
            velocityX: event.getDoubleValueField(field(129)),
            velocityY: event.getDoubleValueField(field(130)))
        return valid(d) ? d : nil
    }
    /// Reconstructs scalar horizontal parameters, NOT an opaque original clone.
    /// Does not post. Native behavior and four-finger mapping remain untested.
    public static func makeEvent(_ descriptor: DockGestureDescriptor) -> CGEvent? {
        guard supported, valid(descriptor) else { return nil }
        return DGMakeEvent(Int32(descriptor.phase), descriptor.progress,
                           descriptor.velocityX, descriptor.velocityY)
    }
    /// EXPERIMENTAL numeric motion2 corroboration only, not native behavior.
    /// Same licensed ISC layout; user-authorized hardware validation outstanding.
    public static func inspectExperimentalVertical(_ event: CGEvent) -> DockGestureDescriptor? {
        guard supported,
              event.getIntegerValueField(field(55)) == 30,
              event.getIntegerValueField(field(110)) == 23,
              event.getIntegerValueField(field(123)) == 2 else { return nil }
        let d = DockGestureDescriptor(motion: 2, phase: Int(event.getIntegerValueField(field(132))),
            progress: event.getDoubleValueField(field(124)),
            velocityX: event.getDoubleValueField(field(129)),
            velocityY: event.getDoubleValueField(field(130)))
        let horizontal = DockGestureDescriptor(motion: 1, phase: d.phase, progress: d.progress,
                                              velocityX: d.velocityX, velocityY: d.velocityY)
        return valid(horizontal) ? d : nil
    }
    public static func makeExperimentalVerticalEvent(_ d: DockGestureDescriptor) -> CGEvent? {
        guard supported, d.motion == 2 else { return nil }
        let horizontal = DockGestureDescriptor(motion: 1, phase: d.phase, progress: d.progress,
                                              velocityX: d.velocityX, velocityY: d.velocityY)
        guard valid(horizontal) else { return nil }
        return DGMakeExperimentalVerticalEvent(Int32(d.phase), d.progress, d.velocityX, d.velocityY)
    }
    /// Fail closed: on this native build CGEvent.data drops attached raw HID.
    /// No inspected ISC accessor can retrieve the original opaque attachment.
    public static func encode(_ event: CGEvent) -> Data? {
        guard supported, inspect(event) != nil, let raw = event.data,
              CFDataGetLength(raw) <= maximumDataSize, DGHasISCRawSuffix(raw),
              let copy = DGEventFromData(raw), let again = copy.data,
              DGHasISCRawSuffix(again), CFEqual(raw, again) else { return nil }
        return raw as Data
    }
    /// Bounded, suffix-whitelisted CG decoder, not an untrusted-network sandbox.
    /// Caller must authenticate data. Unknown formats/attachments fail closed.
    public static func decode(_ data: Data) -> CGEvent? {
        guard supported, data.count >= 4, data.count <= maximumDataSize else { return nil }
        let raw = data as CFData
        guard DGHasISCRawSuffix(raw), let event = DGEventFromData(raw),
              inspect(event) != nil, let again = event.data,
              DGHasISCRawSuffix(again), CFEqual(raw, again) else { return nil }
        return event
    }
    /// No generic native cancellation was proven by the licensed source.
    public static func cancelledCopy(_ event: CGEvent) -> CGEvent? { nil }
    /// ISS cleanup ONLY after replacement switching. Not generic suppression.
    /// Uses CGEvent copy rather than serialization; ISS.s original
    /// terminal mutation does. Attachment/CG scalar consistency is unverified.
    public static func neutralizedEndedCopy(_ event: CGEvent) -> CGEvent? {
        guard supported, let d = inspect(event), d.phase == 4,
              let clone = event.copy() else { return nil }
        clone.setDoubleValueField(field(124), value: 0)
        clone.setDoubleValueField(field(129), value: 0)
        clone.setDoubleValueField(field(130), value: 0)
        return clone
    }
}
