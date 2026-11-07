import Foundation
import CoreGraphics
import ApplicationServices

struct PhysicalDisplayMirroring: Equatable {
    struct Mode: Equatable {
        var width: Int
        var height: Int
        var pixelWidth: Int
        var pixelHeight: Int
        var hz: Double
        var flags: UInt32

        init(width: Int, height: Int, pixelWidth: Int, pixelHeight: Int, hz: Double, flags: UInt32) {
            self.width = width; self.height = height
            self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
            self.hz = hz; self.flags = flags
        }

        init(_ mode: CGDisplayMode) {
            self.init(width: mode.width, height: mode.height, pixelWidth: mode.pixelWidth,
                      pixelHeight: mode.pixelHeight, hz: mode.refreshRate, flags: mode.ioFlags)
        }
    }
    struct Display: Equatable {
        var id: UInt32
        var uuid: String
        var vendor: UInt32
        var model: UInt32
        var serial: UInt32
        var active: Bool
        var bounds: CGRect
        var mirror: UInt32
        var mode: Mode
    }
    struct Repair: Equatable {
        var aliasID: UInt32
        var rootID: UInt32
    }
    var displays: [Display]
    var mainID: UInt32
    var ownedPresent: Bool

    private var validGraph: Bool {
        let ids = Set(displays.map(\.id))
        guard !displays.isEmpty, displays.count <= 7, ids.count == displays.count,
              displays.contains(where: { $0.id == mainID && $0.active && $0.mirror == 0 }),
              Set(displays.map(\.uuid)).count == displays.count else { return false }
        return displays.allSatisfy { display in
            guard display.id != 0, !display.uuid.isEmpty else { return false }
            if display.mirror == 0 { return display.active }
            return display.mirror != display.id && displays.contains {
                $0.id == display.mirror && $0.mirror == 0 && $0.active
            }
        }
    }

    // The only tolerated change is an existing alias becoming independent.
    // Root modes stay authoritative, so a user's concurrent arrangement wins.
    func repairPlan(current: Self) -> [Repair]? {
        guard ownedPresent, !current.ownedPresent, validGraph, current.validGraph,
              mainID == current.mainID, displays.count == current.displays.count else { return nil }
        var repairs: [Repair] = []
        for saved in displays {
            guard let now = current.displays.first(where: { $0.id == saved.id }),
                  saved.uuid == now.uuid, saved.vendor == now.vendor,
                  saved.model == now.model, saved.serial == now.serial else { return nil }
            if saved == now { continue }
            guard saved.mirror != 0, now.mirror == 0, now.active else { return nil }
            repairs.append(Repair(aliasID: saved.id, rootID: saved.mirror))
        }
        return repairs.sorted { $0.aliasID < $1.aliasID }
    }

    static func read(excluding ownedID: UInt32, requireOwned: Bool) -> Self? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return nil }
        ids = Array(ids.prefix(Int(count)))
        let ownedPresent = ids.contains(ownedID)
        guard ownedPresent == requireOwned else { return nil }
        var displays: [Display] = []
        for id in ids where id != ownedID {
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
                  let mode = CGDisplayCopyDisplayMode(id) else { return nil }
            displays.append(Display(id: id, uuid: CFUUIDCreateString(nil, uuid) as String,
                                    vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id),
                                    serial: CGDisplaySerialNumber(id), active: CGDisplayIsActive(id) != 0,
                                    bounds: CGDisplayBounds(id), mirror: CGDisplayMirrorsDisplay(id), mode: Mode(mode)))
        }
        let result = Self(displays: displays.sorted { $0.id < $1.id },
                          mainID: CGMainDisplayID(), ownedPresent: ownedPresent)
        return result.validGraph ? result : nil
    }

    func repairAfterRemoval(ownedID: UInt32) -> Bool {
        guard let current = Self.read(excluding: ownedID, requireOwned: false),
              let repairs = repairPlan(current: current) else { return false }
        if repairs.isEmpty { return true }
        var modes: [UInt32: CGDisplayMode] = [:]
        // Pre-removal mode objects can be stale after the virtual display vanishes.
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        for rootID in Set(repairs.map(\.rootID)) {
            guard let root = current.displays.first(where: { $0.id == rootID }),
                  let available = CGDisplayCopyAllDisplayModes(rootID, options) as? [CGDisplayMode],
                  let fresh = available.first(where: { Mode($0) == root.mode }) else { return false }
            modes[rootID] = fresh
        }
        guard Self.read(excluding: ownedID, requireOwned: false) == current else { return false }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        for rootID in modes.keys.sorted() {
            guard CGConfigureDisplayWithDisplayMode(config, rootID, modes[rootID]!, nil) == .success else {
                CGCancelDisplayConfiguration(config); return false
            }
        }
        for repair in repairs {
            guard CGConfigureDisplayMirrorOfDisplay(config, repair.aliasID, repair.rootID) == .success else {
                CGCancelDisplayConfiguration(config); return false
            }
        }
        guard Self.read(excluding: ownedID, requireOwned: false) == current else {
            CGCancelDisplayConfiguration(config); return false
        }
        guard CGCompleteDisplayConfiguration(config, .forSession) == .success else { return false }
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        var matches = 0
        repeat {
            let actual = Self.read(excluding: ownedID, requireOwned: false)
            if actual?.mainID == mainID && actual?.displays == displays { matches += 1 }
            else { matches = 0 }
            if matches == 2 { return true }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { break }
            Thread.sleep(forTimeInterval: min(0.05, remaining))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }
}
