import Foundation

func runAuthenticatedRouteHintTests() -> Int {
    var checks = 0, failures = 0
    func check(_ condition: Bool) {
        checks += 1
        if !condition { failures += 1; print("FAIL authenticated route hint check \(checks)") }
    }
    let suite = "ThunderControl.AuthenticatedRouteHintTests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let local = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
    let peer = UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!
    let other = UUID(uuidString: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC")!
    let pair = LayoutDevicePair(localID: local.uuidString, peerID: peer.uuidString)!
    let nextPair = LayoutDevicePair(localID: local.uuidString, peerID: other.uuidString)!
    let store = AuthenticatedRouteHintStore(defaults: defaults)
    let hint = AuthenticatedRouteHint(pair: pair, ipv4: "169.254.10.20", port: 49177)!
    defaults.set("preserve", forKey: "unrelated")
    check(store.load(localID: local) == nil)
    check(store.save(hint))
    check(AuthenticatedRouteHintStore(defaults: defaults).load(localID: local) == hint)
    check(store.load(localID: peer) == nil)
    check(store.load(localID: UUID()) == nil)
    check((defaults.data(forKey: AuthenticatedRouteHintStore.key)?.count ?? Int.max) <= 4096)
    check((try? JSONDecoder().decode(AuthenticatedRouteHint.self,
        from: JSONEncoder().encode(hint))) == hint)
    let next = AuthenticatedRouteHint(pair: nextPair, ipv4: "192.168.1.10", port: 49177)!
    check(store.save(next))
    check(store.load(localID: local) == next)
    for ip in ["10.0.0.1", "172.16.0.1", "192.168.0.1", "169.254.1.2", "1.2.3.4"] {
        check(AuthenticatedRouteHint(pair: pair, ipv4: ip, port: 49177) != nil)
    }
    let invalidIPs = ["localhost", "host.example", "::1", "0.0.0.0", "0.1.2.3", "127.0.0.1",
        "127.1.2.3", "224.0.0.1", "239.255.255.250", "240.0.0.1", "255.255.255.255",
        "256.1.1.1", "192.168.001.1", "1.2.3", "1.2.3.4.5", " 1.2.3.4", "1.2.3.4\n",
        "1..2.3", "1.2.3.-1", "１.2.3.4"]
    func object(ip: String = "169.254.10.20", port: Int = 49177,
                localID: String = local.uuidString, peerID: String = peer.uuidString) -> [String: Any] {
        ["version": 1, "hint": ["pair": ["localID": localID, "peerID": peerID], "ipv4": ip, "port": port]]
    }
    func install(_ object: [String: Any]) {
        defaults.set(try! JSONSerialization.data(withJSONObject: object), forKey: AuthenticatedRouteHintStore.key)
    }
    for ip in invalidIPs {
        check(AuthenticatedRouteHint(pair: pair, ipv4: ip, port: 49177) == nil)
        install(object(ip: ip)); check(store.load(localID: local) == nil)
    }
    for port in [0, 80, 49176, 49178, 65535] {
        check(AuthenticatedRouteHint(pair: pair, ipv4: hint.ipv4, port: UInt16(port)) == nil)
        install(object(port: port)); check(store.load(localID: local) == nil)
    }
    for port in [-1, 65536] { install(object(port: port)); check(store.load(localID: local) == nil) }
    for ids in [(local.uuidString.lowercased(), peer.uuidString),
                (local.uuidString, peer.uuidString.lowercased()),
                ("not-a-uuid", peer.uuidString), (local.uuidString, local.uuidString)] {
        install(object(localID: ids.0, peerID: ids.1)); check(store.load(localID: local) == nil)
    }
    let forged = object(ip: "224.0.0.1")["hint"]!
    check((try? JSONDecoder().decode(AuthenticatedRouteHint.self,
        from: JSONSerialization.data(withJSONObject: forged))) == nil)
    var wrongVersion = object(); wrongVersion["version"] = 2
    install(wrongVersion); check(store.load(localID: local) == nil)
    for field in ["version", "hint"] {
        var missing = object(); missing.removeValue(forKey: field)
        install(missing); check(store.load(localID: local) == nil)
    }
    for field in ["pair", "ipv4", "port"] {
        var missing = object(); var inner = missing["hint"] as! [String: Any]
        inner.removeValue(forKey: field); missing["hint"] = inner
        install(missing); check(store.load(localID: local) == nil)
    }
    for field in ["localID", "peerID"] {
        var missing = object(); var inner = missing["hint"] as! [String: Any]
        var ids = inner["pair"] as! [String: Any]; ids.removeValue(forKey: field)
        inner["pair"] = ids; missing["hint"] = inner
        install(missing); check(store.load(localID: local) == nil)
    }
    for level in [0, 1, 2] {
        var unknown = object(); var inner = unknown["hint"] as! [String: Any]
        if level == 0 { unknown["unknown"] = true }
        if level == 1 { inner["unknown"] = true; unknown["hint"] = inner }
        if level == 2 {
            var ids = inner["pair"] as! [String: Any]; ids["unknown"] = true
            inner["pair"] = ids; unknown["hint"] = inner
        }
        install(unknown); check(store.load(localID: local) == nil)
    }
    for data in [Data(), Data("not json".utf8), Data("[]".utf8),
                 Data(repeating: 32, count: 4097)] {
        defaults.set(data, forKey: AuthenticatedRouteHintStore.key)
        check(store.load(localID: local) == nil)
    }
    // A valid JSON document is also rejected when oversized, not just malformed bytes.
    let validData = try! JSONSerialization.data(withJSONObject: object())
    var oversized = validData; oversized.append(Data(repeating: 32, count: 4097 - validData.count))
    defaults.set(oversized, forKey: AuthenticatedRouteHintStore.key)
    check(store.load(localID: local) == nil)
    var boundary = validData; boundary.append(Data(repeating: 32, count: 4096 - validData.count))
    defaults.set(boundary, forKey: AuthenticatedRouteHintStore.key)
    check(store.load(localID: local) == hint)
    let beforeRead = defaults.data(forKey: AuthenticatedRouteHintStore.key)
    check(store.load(localID: other) == nil)
    check(defaults.data(forKey: AuthenticatedRouteHintStore.key) == beforeRead)
    defaults.set("wrong preference type", forKey: AuthenticatedRouteHintStore.key)
    check(store.load(localID: local) == nil)
    check(store.save(hint))
    store.clear()
    check(store.load(localID: local) == nil)
    check(defaults.object(forKey: AuthenticatedRouteHintStore.key) == nil)
    check(defaults.string(forKey: "unrelated") == "preserve")
    print("Authenticated route hints: \(checks) checks, \(failures) failures; routing only, no authentication or input")
    return failures
}
