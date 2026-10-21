import Foundation
import CoreGraphics

/// Samples only valid current maps. Never applies configuration or replays a
/// physical layout. A stale saved anchor must not be overwritten by a fallback
/// startup position unless the user subsequently changes the current layout.
struct VirtualDisplayPlacementSample: Equatable {
    let ownedBounds: CGRect
    let physicalDesktop: ReceiverDesktop
    init?(desktop: ReceiverDesktop, ownedID: UInt32, format: DisplayVideoFormat) {
        guard desktop.valid, desktop.virtualDisplayID == ownedID,
              let owned = desktop.displays.first(where: { $0.id == ownedID }), owned.bounds.size == format.size else { return nil }
        let physical = desktop.displays.filter { $0.id != ownedID }
        guard !physical.isEmpty else { return nil }
        let map = ReceiverDesktop(revision: 1,
            mainID: physical.contains(where: { $0.id == desktop.mainID }) ? desktop.mainID : physical[0].id,
            displays: physical)
        guard map.valid else { return nil }
        ownedBounds = owned.bounds; physicalDesktop = map
    }
}

struct VirtualDisplayPlacementSession {
    private let pair: LayoutDevicePair
    private let requestedOrigin: CGPoint?
    private let hadSaved: Bool
    private var initial: VirtualDisplayPlacementSample?
    private var pending: VirtualDisplayPlacementSample?
    private var pendingSince: Double = 0
    private var lastSaved: VirtualDisplayPlacementSample?
    init(pair: LayoutDevicePair, requestedOrigin: CGPoint?, hadSaved: Bool) {
        self.pair = pair; self.requestedOrigin = requestedOrigin; self.hadSaved = hadSaved
    }
    @discardableResult mutating func observe(_ sample: VirtualDisplayPlacementSample, now: Double,
        store: SavedVirtualDisplayPlacementStore, force: Bool = false) -> Bool {
        guard now.isFinite else { return false }
        if initial == nil { initial = sample }
        // Don't replace a usable old record merely because its monitor was
        // absent or the startup race made its geometry unsafe this time.
        if hadSaved, initial == sample,
           requestedOrigin == nil || sample.ownedBounds.origin != requestedOrigin { return false }
        if pending != sample { pending = sample; pendingSince = now; if !force { return false } }
        guard force || now - pendingSince >= 0.75, sample != lastSaved else { return false }
        guard store.save(ownedBounds: sample.ownedBounds, physicalDesktop: sample.physicalDesktop, for: pair) else { return false }
        lastSaved = sample; return true
    }
}
