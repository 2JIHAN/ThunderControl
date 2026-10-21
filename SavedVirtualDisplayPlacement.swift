import Foundation
import CoreGraphics

/// Local metadata for the receiver-owned extension, independent of source layout.
/// The caller supplies a physical-only desktop and an authenticated device pair.
/// No display enumeration, display writes, input state, or migration from source
/// placement preferences occurs here. Geometry, not video negotiation, is checked.
final class SavedVirtualDisplayPlacementStore {
    static let key = "ThunderControl.virtualDisplayPlacements.v1"
    static let maxRecords = 128
    static let maxBytes = 256 * 1024

    private struct Key: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    private static func requireKeys(_ decoder: Decoder, _ expected: Set<String>) throws {
        let c = try decoder.container(keyedBy: Key.self)
        guard Set(c.allKeys.map(\.stringValue)) == expected else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Invalid placement schema"))
        }
    }
    private struct Record: Codable {
        let pair: LayoutDevicePair
        let anchorIdentity: String
        // Side of the owned rectangle, matching DesktopPortal.sourceSide.
        let side: DesktopSide
        let tangentOffset: Double
        enum CodingKeys: String, CodingKey { case pair, anchorIdentity, side, tangentOffset }
        enum PairKeys: String, CodingKey { case localID, peerID }
        init(pair: LayoutDevicePair, anchorIdentity: String, side: DesktopSide, tangentOffset: Double) {
            self.pair = pair; self.anchorIdentity = anchorIdentity
            self.side = side; self.tangentOffset = tangentOffset
        }
        init(from decoder: Decoder) throws {
            try SavedVirtualDisplayPlacementStore.requireKeys(decoder, ["pair", "anchorIdentity", "side", "tangentOffset"])
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let pd = try c.superDecoder(forKey: .pair)
            try SavedVirtualDisplayPlacementStore.requireKeys(pd, ["localID", "peerID"])
            let pc = try pd.container(keyedBy: PairKeys.self)
            guard let pair = LayoutDevicePair(localID: try pc.decode(String.self, forKey: .localID),
                                              peerID: try pc.decode(String.self, forKey: .peerID)) else {
                throw DecodingError.dataCorrupted(.init(codingPath: pd.codingPath, debugDescription: "Invalid pair"))
            }
            self.pair = pair
            anchorIdentity = try c.decode(String.self, forKey: .anchorIdentity)
            side = try c.decode(DesktopSide.self, forKey: .side)
            tangentOffset = try c.decode(Double.self, forKey: .tangentOffset)
        }
        var valid: Bool {
            pair.localID != pair.peerID && UUID(uuidString: anchorIdentity)?.uuidString == anchorIdentity &&
            tangentOffset.isFinite && abs(tangentOffset) <= 2_000_000
        }
    }
    private struct Envelope: Codable {
        let version: Int
        let records: [Record]
        enum CodingKeys: String, CodingKey { case version, records }
        init(records: [Record]) { version = 1; self.records = records }
        init(from decoder: Decoder) throws {
            try SavedVirtualDisplayPlacementStore.requireKeys(decoder, ["version", "records"])
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decode(Int.self, forKey: .version)
            records = try c.decode([Record].self, forKey: .records)
        }
    }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Reject the entire envelope, including on save, instead of salvaging or
    /// overwriting a partially corrupt collection. Reads never mutate preferences.
    private func records() -> [Record]? {
        guard let value = defaults.object(forKey: Self.key) else { return [] }
        guard let data = value as? Data, data.count <= Self.maxBytes,
              let e = try? JSONDecoder().decode(Envelope.self, from: data),
              e.version == 1, e.records.count <= Self.maxRecords else { return nil }
        var seen = Set<LayoutDevicePair>()
        guard e.records.allSatisfy({ $0.valid && seen.insert($0.pair).inserted }) else { return nil }
        return e.records
    }
    private func validDesktop(_ desktop: ReceiverDesktop) -> Bool {
        // Reject an accidentally unfiltered owned display, and ambiguous UUIDs.
        guard desktop.valid, desktop.virtualDisplayID == nil else { return false }
        let identities = desktop.displays.compactMap { ReceiverDesktop.canonicalUUID($0.stableIdentity) }
        return Set(identities).count == identities.count
    }
    private func validRect(_ rect: CGRect, in desktop: ReceiverDesktop, anchorID: UInt32? = nil) -> Bool {
        guard ReceiverDesktop.sane(rect), rect.origin.x.rounded() == rect.origin.x,
              rect.origin.y.rounded() == rect.origin.y,
              !desktop.displays.contains(where: { ReceiverDesktop.overlaps(rect, $0.bounds) }) else { return false }
        return desktop.portals(sourceRect: rect).contains { anchorID == nil || $0.displayID == anchorID }
    }
    func hasSaved(for pair: LayoutDevicePair) -> Bool {
        records()?.contains(where: { $0.pair == pair }) == true
    }
    @discardableResult
    func save(ownedBounds: CGRect, physicalDesktop: ReceiverDesktop, for pair: LayoutDevicePair) -> Bool {
        guard pair.localID != pair.peerID, validDesktop(physicalDesktop),
              validRect(ownedBounds, in: physicalDesktop), var list = records() else { return false }
        let candidates = physicalDesktop.portals(sourceRect: ownedBounds).filter { portal in
            physicalDesktop.displays.contains { $0.id == portal.displayID && ReceiverDesktop.canonicalUUID($0.stableIdentity) != nil }
        }
        guard let portal = candidates.first(where: { $0.displayID == physicalDesktop.mainID }) ?? candidates.first,
              let anchor = physicalDesktop.displays.first(where: { $0.id == portal.displayID }),
              let identity = ReceiverDesktop.canonicalUUID(anchor.stableIdentity) else { return false }
        let vertical = portal.sourceSide == .left || portal.sourceSide == .right
        let offset = vertical ? ownedBounds.minY - anchor.bounds.minY : ownedBounds.minX - anchor.bounds.minX
        let record = Record(pair: pair, anchorIdentity: identity, side: portal.sourceSide, tangentOffset: Double(offset))
        guard record.valid else { return false }
        list.removeAll { $0.pair == pair }; list.append(record)
        if list.count > Self.maxRecords { list.removeFirst(list.count - Self.maxRecords) }
        guard let data = try? JSONEncoder().encode(Envelope(records: list)), data.count <= Self.maxBytes else { return false }
        defaults.set(data, forKey: Self.key)
        return true
    }
    func restored(for pair: LayoutDevicePair, size: CGSize, physicalDesktop: ReceiverDesktop) -> CGPoint? {
        guard validDesktop(physicalDesktop), ReceiverDesktop.sane(CGRect(origin: .zero, size: size)),
              let saved = records()?.first(where: { $0.pair == pair }),
              let anchor = physicalDesktop.displays.first(where: {
                  ReceiverDesktop.canonicalUUID($0.stableIdentity) == saved.anchorIdentity
              }) else { return nil }
        let r = anchor.bounds, offset = CGFloat(saved.tangentOffset)
        let origin: CGPoint
        switch saved.side {
        case .left: origin = CGPoint(x: r.maxX, y: r.minY + offset)
        case .right: origin = CGPoint(x: r.minX - size.width, y: r.minY + offset)
        case .top: origin = CGPoint(x: r.minX + offset, y: r.maxY)
        case .bottom: origin = CGPoint(x: r.minX + offset, y: r.minY - size.height)
        }
        // Conservative policy: obstruction, lost seam, fractional origin, or
        // out-of-bounds geometry yields nil. Never re-anchor to another monitor,
        // and preserve saved intent for when the original layout returns.
        return validRect(CGRect(origin: origin, size: size), in: physicalDesktop, anchorID: anchor.id) ? origin : nil
    }
}
