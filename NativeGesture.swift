import AppKit
import CoreGraphics

// Classification only: parent preserves original event data. No HID synthesis.
struct NativeGestureDescriptor: Codable, Equatable {
  enum Kind: String, Codable, CaseIterable { case pinch, rotate, swipe, smartMagnify }
  enum Phase: String, Codable { case none, mayBegin, began, changed, ended, cancelled }
  let kind: Kind
  let phase: Phase
  var atomic: Bool { phase == .none && (kind == .swipe || kind == .smartMagnify) }
  var terminal: Bool { phase == .ended || phase == .cancelled }
  var valid: Bool { kind == .smartMagnify ? phase == .none : (phase != .none || kind == .swipe) }

  static func decode(_ event: CGEvent) -> NativeGestureDescriptor? {
    guard event.type.rawValue == 29 || event.type.rawValue == 30,
      let native = NSEvent(cgEvent: event) else { return nil }
    let kind: Kind
    switch event.getIntegerValueField(CGEventField(rawValue: 110)!) {
    case 8:
      guard native.type == .magnify, native.magnification.isFinite,
        abs(native.magnification) <= 4 else { return nil }
      kind = .pinch
    case 5:
      guard native.type == .rotate, native.rotation.isFinite,
        abs(native.rotation) <= 360 else { return nil }
      kind = .rotate
    case 16:
      let direction = event.getIntegerValueField(CGEventField(rawValue: 115)!)
      guard native.type == .swipe, [Int64(1), 2, 4, 8].contains(direction),
        native.deltaX.isFinite, native.deltaY.isFinite,
        abs(native.deltaX) <= 1, abs(native.deltaY) <= 1,
        native.deltaX != 0 || native.deltaY != 0 else { return nil }
      kind = .swipe
    case 22:
      guard native.type == .smartMagnify else { return nil }
      kind = .smartMagnify
    default: return nil // Includes raw contact subtype 23.
    }
    // Public NSEvent phase semantics, NOT IOHID numeric phase semantics.
    let phase: Phase
    switch native.phase {
    case []: phase = .none
    case .mayBegin: phase = .mayBegin
    case .began: phase = .began
    case .changed: phase = .changed
    case .ended: phase = .ended
    case .cancelled: phase = .cancelled
    default: return nil
    }
    let result = Self(kind: kind, phase: phase)
    return result.valid ? result : nil
  }
}

struct GestureRoute: Equatable {
  let forward: Bool
  let suppress: Bool
  let id: String?
}

struct SourceGestureState {
  private struct Stream {
    let id: String?
    var phase: NativeGestureDescriptor.Phase
    let started: Double
  }
  private var local: [NativeGestureDescriptor.Kind: Stream] = [:]
  private var remote: [NativeGestureDescriptor.Kind: Stream] = [:]
  private var orphans = Set<NativeGestureDescriptor.Kind>()
  var hasOrphans: Bool { !orphans.isEmpty }
  var localActive: Bool { !local.isEmpty }
  var remoteActive: Bool { !remote.isEmpty }
  var blockAuto: Bool { localActive || remoteActive || hasOrphans }

  mutating func route(_ descriptor: NativeGestureDescriptor, remote wantsRemote: Bool,
                      now: Double) -> GestureRoute {
    let drop = GestureRoute(forward: false, suppress: true, id: nil)
    let pass = GestureRoute(forward: false, suppress: false, id: nil)
    guard descriptor.valid else { return wantsRemote ? drop : pass }
    let kind = descriptor.kind
    if orphans.contains(kind) {
      if descriptor.terminal { orphans.remove(kind) }
      return drop
    }
    guard now.isFinite else { return wantsRemote ? drop : pass }
    if descriptor.atomic {
      guard local[kind] == nil, remote[kind] == nil else { return wantsRemote ? drop : pass }
      return wantsRemote ? GestureRoute(forward: true, suppress: true, id: UUID().uuidString) : pass
    }
    if var stream = local[kind] {
      if descriptor.terminal { local.removeValue(forKey: kind) }
      else if stream.phase == .mayBegin && descriptor.phase == .began {
        stream.phase = .began; local[kind] = stream
      } else if descriptor.phase == .changed { stream.phase = .changed; local[kind] = stream }
      return pass // Never transfer a preexisting local stream midgesture.
    }
    if var stream = remote[kind] {
      guard wantsRemote else {
        remote.removeValue(forKey: kind)
        if !descriptor.terminal { orphans.insert(kind) }
        return drop
      }
      if descriptor.terminal {
        remote.removeValue(forKey: kind)
      } else if descriptor.phase == .began && stream.phase == .mayBegin {
        stream.phase = .began; remote[kind] = stream
      } else if descriptor.phase == .changed && stream.phase != .mayBegin {
        stream.phase = .changed; remote[kind] = stream
      } else { return drop }
      return GestureRoute(forward: true, suppress: true, id: stream.id)
    }
    if descriptor.terminal { return wantsRemote ? drop : pass }
    if wantsRemote {
      guard descriptor.phase == .began || descriptor.phase == .mayBegin else {
        orphans.insert(kind); return drop
      }
      let id = UUID().uuidString
      remote[kind] = Stream(id: id, phase: descriptor.phase, started: now)
      return GestureRoute(forward: true, suppress: true, id: id)
    }
    local[kind] = Stream(id: nil, phase: descriptor.phase, started: now)
    return pass
  }
  mutating func forceLocal() {
    orphans.formUnion(remote.keys)
    remote.removeAll()
  }
  // Reset live state but never silently release a held remote gesture.
  mutating func reset() { forceLocal(); local.removeAll() }
  // Explicit physical-release/administrative recovery only, never timeout.
  mutating func clearOrphans() { orphans.removeAll() }
  func expired(now: Double) -> Bool {
    guard now.isFinite else { return localActive || remoteActive || hasOrphans }
    return local.values.contains { now < $0.started || now - $0.started >= 30 }
      || remote.values.contains { now < $0.started || now - $0.started >= 30 }
  }
}

struct ReceiverGestureState {
  private struct Stream {
    let id: String
    var phase: NativeGestureDescriptor.Phase
    let started: Double
  }
  private var streams: [NativeGestureDescriptor.Kind: Stream] = [:]
  var active: Bool { !streams.isEmpty }
  mutating func accept(_ descriptor: NativeGestureDescriptor, id: String,
                       now: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
    guard descriptor.valid, now.isFinite, let uuid = UUID(uuidString: id),
      uuid.uuidString == id else { return false }
    let kind = descriptor.kind
    if descriptor.atomic {
      return streams[kind] == nil && !streams.values.contains { $0.id == id }
    }
    if var stream = streams[kind] {
      guard stream.id == id else { return false }
      if descriptor.terminal { streams.removeValue(forKey: kind); return true }
      if descriptor.phase == .began && stream.phase == .mayBegin {
        stream.phase = .began
      } else if descriptor.phase == .changed && stream.phase != .mayBegin {
        stream.phase = .changed
      } else { return false }
      streams[kind] = stream
      return true
    }
    guard descriptor.phase == .began || descriptor.phase == .mayBegin,
      !streams.values.contains(where: { $0.id == id }) else { return false }
    streams[kind] = Stream(id: id, phase: descriptor.phase, started: now)
    return true
  }
  func expired(now: Double) -> Bool {
    guard now.isFinite else { return active }
    return streams.values.contains { now < $0.started || now - $0.started >= 30 }
  }
  mutating func reset() { streams.removeAll() }
}
