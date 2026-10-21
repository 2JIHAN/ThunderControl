import Foundation
import CoreGraphics

/// Pure geometry and isolated preferences only. No display or input APIs called.
@discardableResult func runSavedVirtualDisplayPlacementTests() -> Int {
    var failures = 0, checks = 0
    func check(_ ok: Bool, _ name: String) {
        checks += 1
        if !ok { failures += 1; print("FAIL virtual placement: \(name)") }
    }
    let suite = "ThunderControl.tests.virtual-placement." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = SavedVirtualDisplayPlacementStore(defaults: defaults)
    let key = SavedVirtualDisplayPlacementStore.key
    let pair = LayoutDevicePair(localID: UUID().uuidString, peerID: UUID().uuidString)!
    let peer = LayoutDevicePair(localID: pair.localID.uuidString, peerID: UUID().uuidString)!
    let reverse = LayoutDevicePair(localID: pair.peerID.uuidString, peerID: pair.localID.uuidString)!
    let identity = "AABBCCDD-0000-4000-8000-000000000001"
    let size = CGSize(width: 800, height: 600)
    let anchor = ReceiverDisplay(id: 11, bounds: CGRect(x: -1200, y: -300, width: 1200, height: 900), stableIdentity: identity)
    let map = ReceiverDesktop(revision: 1, mainID: 11, displays: [anchor])
    let untouched: [String: Any] = [SavedDesktopPlacementStore.key: Data("source-sentinel".utf8),
                                  SavedScreenLayoutStore.key: Data("legacy-sentinel".utf8), "unrelated": "leave alone"]
    for (k, v) in untouched { defaults.set(v, forKey: k) }
    let baseline = defaults.persistentDomain(forName: suite)! as NSDictionary
    check(key != SavedDesktopPlacementStore.key && key != SavedScreenLayoutStore.key, "separate preference key")
    check(!store.hasSaved(for: pair), "empty store")
    check(store.restored(for: pair, size: size, physicalDesktop: map) == nil, "no source preference migration")
    check(defaults.object(forKey: key) == nil, "read does not initialize preference")

    let origins = [CGPoint(x: 0, y: -250), CGPoint(x: -2000, y: -250),
                   CGPoint(x: -1100, y: 600), CGPoint(x: -1100, y: -900)]
    let changedSize = CGSize(width: 1280, height: 720)
    let resized = [CGPoint(x: 0, y: -250), CGPoint(x: -2480, y: -250),
                   CGPoint(x: -1100, y: 600), CGPoint(x: -1100, y: -1020)]
    for (i, origin) in origins.enumerated() {
        check(store.save(ownedBounds: CGRect(origin: origin, size: size), physicalDesktop: map, for: pair), "save direction \(i)")
        check(store.hasSaved(for: pair), "saved direction \(i)")
        check(store.restored(for: pair, size: size, physicalDesktop: map) == origin, "restore direction \(i)")
        check(store.restored(for: pair, size: changedSize, physicalDesktop: map) == resized[i], "resize direction \(i)")
        let moved = ReceiverDesktop(revision: 2, mainID: 99, displays: [ReceiverDisplay(id: 99,
            bounds: CGRect(x: 500, y: -1000, width: 1400, height: 1000), stableIdentity: identity.lowercased())])
        let expected = [CGPoint(x: 1900, y: -950), CGPoint(x: -300, y: -950),
                        CGPoint(x: 600, y: 0), CGPoint(x: 600, y: -1600)][i]
        check(store.restored(for: pair, size: size, physicalDesktop: moved) == expected, "moved resized anchor with changed ephemeral ID \(i)")
        check(store.restored(for: peer, size: size, physicalDesktop: map) == nil && !store.hasSaved(for: peer), "peer isolation \(i)")
        check(store.restored(for: reverse, size: size, physicalDesktop: map) == nil, "directional pair isolation \(i)")
    }
    check(store.save(ownedBounds: CGRect(origin: origins[0], size: size), physicalDesktop: map, for: pair), "seed right placement")
    let saved = defaults.data(forKey: key)!
    let replacement = ReceiverDesktop(revision: 3, mainID: 11, displays: [ReceiverDisplay(id: 11, bounds: anchor.bounds, stableIdentity: UUID().uuidString)])
    check(store.restored(for: pair, size: size, physicalDesktop: replacement) == nil, "same numeric ID is not stable identity")
    check(store.hasSaved(for: pair) && defaults.data(forKey: key) == saved, "missing anchor retains intent")
    let unrelatedMain = ReceiverDisplay(id: 12, bounds: CGRect(x: 2000, y: 0, width: 1200, height: 900), stableIdentity: UUID().uuidString)
    let nonMain = ReceiverDesktop(revision: 4, mainID: 12, displays: [unrelatedMain, anchor])
    check(store.restored(for: pair, size: size, physicalDesktop: nonMain) == origins[0], "exact non-main anchor only")
    let obstructed = ReceiverDesktop(revision: 5, mainID: 11, displays: [anchor,
        ReceiverDisplay(id: 13, bounds: CGRect(x: 0, y: -300, width: 1200, height: 900), stableIdentity: UUID().uuidString)])
    let originalMap = obstructed
    check(store.restored(for: pair, size: size, physicalDesktop: obstructed) == nil, "obstruction conservatively rejected")
    check(obstructed == originalMap && defaults.data(forKey: key) == saved, "no physical or saved geometry mutation")
    check(store.restored(for: pair, size: size, physicalDesktop: map) == origins[0], "original placement survives obstruction")
    let noUUID = ReceiverDesktop(revision: 1, mainID: 11, displays: [ReceiverDisplay(id: 11, bounds: anchor.bounds)])
    check(!store.save(ownedBounds: CGRect(origin: origins[0], size: size), physicalDesktop: noUUID, for: pair), "no ephemeral anchor fallback")
    check(store.restored(for: pair, size: size, physicalDesktop: noUUID) == nil, "missing UUID cannot restore")
    var includesOwned = map; includesOwned.virtualDisplayID = 11
    check(!store.save(ownedBounds: CGRect(origin: origins[0], size: size), physicalDesktop: includesOwned, for: pair), "physical-only contract save")
    check(store.restored(for: pair, size: size, physicalDesktop: includesOwned) == nil, "physical-only contract restore")
    let duplicateUUID = ReceiverDesktop(revision: 1, mainID: 11, displays: [anchor,
        ReceiverDisplay(id: 14, bounds: unrelatedMain.bounds, stableIdentity: identity)])
    check(store.restored(for: pair, size: size, physicalDesktop: duplicateUUID) == nil, "ambiguous UUID rejected")
    check(!store.save(ownedBounds: CGRect(origin: origins[0], size: size), physicalDesktop: duplicateUUID, for: pair), "ambiguous UUID save rejected")

    for rect in [CGRect(x: 0.5, y: -250, width: 800, height: 600),
                 CGRect(x: 0, y: -250.5, width: 800, height: 600),
                 CGRect(x: -100, y: -250, width: 800, height: 600),
                 CGRect(x: 0, y: 600, width: 800, height: 600), // corner only
                 CGRect(x: 100, y: -250, width: 800, height: 600), // gap
                 CGRect(x: 0, y: -250, width: -800, height: 600),
                 CGRect(x: 0, y: -250, width: 0, height: 600),
                 CGRect(x: CGFloat.nan, y: 0, width: 800, height: 600),
                 CGRect(x: CGFloat.infinity, y: 0, width: 800, height: 600),
                 CGRect(x: 0, y: -250, width: CGFloat.infinity, height: 600)] {
        check(!store.save(ownedBounds: rect, physicalDesktop: map, for: pair), "invalid save geometry")
        check(defaults.data(forKey: key) == saved, "invalid save preserves record")
    }
    for invalidSize in [CGSize.zero, CGSize(width: -800, height: 600), CGSize(width: CGFloat.nan, height: 600),
                        CGSize(width: 800, height: CGFloat.infinity), CGSize(width: 65537, height: 600)] {
        check(store.restored(for: pair, size: invalidSize, physicalDesktop: map) == nil, "invalid restore size")
    }
    let boundary = ReceiverDesktop(revision: 1, mainID: 11, displays: [ReceiverDisplay(id: 11,
        bounds: CGRect(x: 999000, y: 0, width: 1000, height: 900), stableIdentity: identity)])
    check(store.restored(for: pair, size: size, physicalDesktop: boundary) == nil, "bounded final rectangle")
    let fraction = ReceiverDesktop(revision: 1, mainID: 11, displays: [ReceiverDisplay(id: 11,
        bounds: CGRect(x: -1200.5, y: -300, width: 1200, height: 900), stableIdentity: identity)])
    check(store.restored(for: pair, size: size, physicalDesktop: fraction) == nil, "integer restored origin")

    // Corruption is atomic: one invalid sibling invalidates every record. A
    // failed save must not silently discard corrupt or future-version metadata.
    let root = try! JSONSerialization.jsonObject(with: saved) as! [String: Any]
    let goodRecord = (root["records"] as! [[String: Any]])[0]
    func encoded(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    func reject(_ data: Data, _ name: String) {
        defaults.set(data, forKey: key)
        check(!store.hasSaved(for: pair), "corrupt hasSaved \(name)")
        check(store.restored(for: pair, size: size, physicalDesktop: map) == nil, "corrupt restore \(name)")
        check(!store.save(ownedBounds: CGRect(origin: origins[0], size: size), physicalDesktop: map, for: pair), "corrupt save \(name)")
        check(defaults.data(forKey: key) == data, "corrupt data preserved \(name)")
    }
    reject(Data("not-json".utf8), "syntax")
    reject(Data(saved.dropLast()), "truncation")
    reject(Data(repeating: 32, count: SavedVirtualDisplayPlacementStore.maxBytes + 1), "byte limit")
    reject(encoded(["version": 2, "records": [goodRecord]]), "future version")
    reject(encoded(["version": 1, "records": [goodRecord, goodRecord]]), "duplicate pair")
    reject(encoded(["version": 1, "records": Array(repeating: goodRecord, count: 129)]), "record limit")
    reject(encoded(["version": 1, "records": [goodRecord], "extra": true]), "unknown envelope field")
    for (field, bad): (String, Any) in [("anchorIdentity", "not-a-uuid"), ("anchorIdentity", identity.lowercased()),
                                      ("side", "diagonal"), ("tangentOffset", 2_000_001),
                                      ("tangentOffset", "NaN"), ("extra", true), ("anchorIdentity", NSNull())] {
        var record = goodRecord; record[field] = bad
        var sibling = goodRecord
        sibling["pair"] = ["localID": peer.localID.uuidString, "peerID": peer.peerID.uuidString]
        reject(encoded(["version": 1, "records": [sibling, record]]), field)
    }
    var badPair = goodRecord
    badPair["pair"] = ["localID": pair.localID.uuidString, "peerID": pair.localID.uuidString]
    reject(encoded(["version": 1, "records": [badPair]]), "self pair")
    var missing = goodRecord; missing.removeValue(forKey: "side")
    reject(encoded(["version": 1, "records": [missing]]), "missing field")
    defaults.set("wrong type", forKey: key)
    check(!store.hasSaved(for: pair), "wrong preference type")
    check(!store.save(ownedBounds: CGRect(origin: origins[0], size: size), physicalDesktop: map, for: pair), "wrong type not overwritten")
    check(defaults.string(forKey: key) == "wrong type", "wrong type preserved")

    defaults.removeObject(forKey: key)
    var pairs = [LayoutDevicePair]()
    for _ in 0..<129 {
        let p = LayoutDevicePair(localID: pair.localID.uuidString, peerID: UUID().uuidString)!
        pairs.append(p)
        check(store.save(ownedBounds: CGRect(origin: origins[0], size: size), physicalDesktop: map, for: p), "bounded append")
    }
    check(SavedVirtualDisplayPlacementStore.maxRecords == 128 && SavedVirtualDisplayPlacementStore.maxBytes == 262144, "documented limits")
    check(!store.hasSaved(for: pairs[0]) && store.hasSaved(for: pairs[128]), "oldest eviction")
    check(store.save(ownedBounds: CGRect(origin: origins[1], size: size), physicalDesktop: map, for: pairs[1]), "replace existing pair")
    let boundedData = defaults.data(forKey: key)!
    let boundedRoot = try! JSONSerialization.jsonObject(with: boundedData) as! [String: Any]
    check((boundedRoot["records"] as! [Any]).count == 128 && boundedData.count <= SavedVirtualDisplayPlacementStore.maxBytes, "bounded collection")
    check(store.restored(for: pairs[1], size: size, physicalDesktop: map) == origins[1], "replacement restored")
    check(SavedVirtualDisplayPlacementStore(defaults: defaults).restored(for: pairs[128], size: size, physicalDesktop: map) == origins[0], "new instance reconnect")
    let recordKeys = Set(((boundedRoot["records"] as! [[String: Any]])[0]).keys)
    check(recordKeys == ["pair", "anchorIdentity", "side", "tangentOffset"], "metadata only, no ephemeral IDs or input")
    var finalDomain = defaults.persistentDomain(forName: suite)!
    finalDomain.removeValue(forKey: key)
    check((finalDomain as NSDictionary).isEqual(baseline), "no other preferences changed")
    print("Saved virtual placement: \(checks) checks failures=\(failures); isolated preferences and pure geometry only")
    return failures
}
