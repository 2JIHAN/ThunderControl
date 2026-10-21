import Foundation

// Standalone executable test runner. Native transport is linked, NEVER instantiated.
private final class MockDNS: BridgeDNSTransport {
    struct Call {
        let id: UUID
        let request: BridgeDNSRequest
        let index: UInt32
        let receive: (BridgeDNSEvent) -> Void
    }
    var calls: [Call] = []
    var live: Set<UUID> = []
    var failOpen = false
    func open(_ request: BridgeDNSRequest, index: UInt32, receive: @escaping (BridgeDNSEvent) -> Void) -> UUID? {
        guard !failOpen else { return nil }
        let id = UUID(); calls.append(Call(id: id, request: request, index: index, receive: receive)); live.insert(id)
        return id
    }
    func close(_ id: UUID) { live.remove(id) }
    func stop() { live.removeAll() }
}
@main struct BridgeDiscoveryTests {
    @MainActor static func flush() async { for _ in 0..<30 { await Task.yield() } }
    @MainActor static func main() async {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            precondition(condition(), "FAILED: \(name)"); checks += 1
        }
        for value in ["", "0.1.2.3", "127.0.0.1", "224.0.0.1", "239.1.1.1", "255.255.255.255", "256.1.1.1", "1.2.3", "01.2.3.4", "1.2.3.4:80", "::1", "1.2.3.4\n"] {
            check(BridgeDiscoveryValidation.ipv4(value) == nil, "reject \(value)")
        }
        for value in ["10.0.0.1", "169.254.23.2", "192.168.1.3", "172.16.0.1"] {
            check(BridgeDiscoveryValidation.ipv4(value) == value, "accept \(value)")
        }
        check(!BridgeDiscoveryValidation.validInterface(0), "no default index")
        check(!BridgeDiscoveryValidation.validInterface(UInt32.max), "no pseudo index")
        check(BridgeDiscoveryValidation.displayName(" \nhello\u{0000}\u{202E}\t ") == "hello", "name sanitation")
        check(BridgeDiscoveryValidation.displayName(String(repeating: "a", count: 200)).count == 60, "name bound")
        check(BridgeDiscoveryValidation.displayName("\u{0000}") == "Bridge peer", "empty name fallback")
        for raw in [String(repeating: "한글", count: 40), String(repeating: "😀", count: 40), String(repeating: "e\u{0301}", count: 80)] {
            let name = BridgeDiscoveryValidation.displayName(raw)
            check(!name.isEmpty && name.utf8.count <= 60 && !name.contains("\u{FFFD}"), "multibyte scalar-safe name bound")
        }
        let mock = MockDNS();
 let discovery = BridgeDiscovery(transport: mock, useTimer: false)
        var deliveries = 0; var peers: [BridgePeer] = []
        discovery.startBrowsing(interfaceIndex: 0, localIPv4: "10.0.0.1") { _ in deliveries += 1 }
        check(mock.calls.isEmpty, "invalid index fails closed")
        discovery.startBrowsing(interfaceIndex: 9, localIPv4: "127.0.0.1") { _ in deliveries += 1 }
        check(mock.calls.isEmpty, "invalid local fails closed")
        discovery.startBrowsing(interfaceIndex: 9, localIPv4: "10.0.0.1") { peers = $0; deliveries += 1 }
        let browse = mock.calls.last!
        browse.receive(.service(add: true, index: 2, name: "Wrong interface", type: "_thunderctrl._tcp.", domain: "local."))
        await flush(); check(mock.calls.count == 1, "callback index enforced")
        browse.receive(.service(add: true, index: 9, name: " Receiver\u{0001} ", type: "_thunderctrl._tcp.", domain: "local."))
        await flush(); let resolve = mock.calls.last!
        check(mock.calls.count == 2 && resolve.index == 9, "resolve explicitly scoped")
        resolve.receive(.resolved(index: 9, host: "receiver.local.", port: 4242))
        await flush(); let address = mock.calls.last!
        check(address.index == 9 && !mock.live.contains(resolve.id), "address scoped, resolve retired")
        address.receive(.address(add: true, index: 9, ipv4: "10.0.0.1", ttl: 120))
        address.receive(.address(add: true, index: 9, ipv4: "224.0.0.2", ttl: 120))
        address.receive(.address(add: true, index: 3, ipv4: "10.0.0.2", ttl: 120))
        await flush(); check(peers.isEmpty, "self/non-unicast/wrong-index filtered")
        address.receive(.address(add: true, index: 9, ipv4: "10.0.0.2", ttl: 120))
        await flush(); check(peers.count == 1 && peers[0].port == 4242 && peers[0].name == "Receiver", "publish valid endpoint")
        address.receive(.address(add: false, index: 9, ipv4: "10.0.0.2", ttl: 0))
        await flush(); check(peers.isEmpty, "address withdrawal")
        address.receive(.address(add: true, index: 9, ipv4: "10.0.0.2", ttl: 1))
        await flush(); discovery.expire(now: Date().addingTimeInterval(5))
        check(peers.isEmpty, "TTL expiration")
        discovery.advertise(interfaceIndex: 9, name: "Receiver", port: 4242)
        check(mock.calls.last!.index == 9, "advertisement scoped")
        let beforeStop = deliveries
        discovery.stop(); check(mock.live.isEmpty, "stop releases sources")
        address.receive(.address(add: true, index: 9, ipv4: "10.0.0.2", ttl: 120))
        browse.receive(.failed(-1)); await flush()
        check(deliveries == beforeStop, "no callbacks after stop")
        discovery.startBrowsing(interfaceIndex: 11, localIPv4: "10.0.0.1") { peers = $0; deliveries += 1 }
        let newBrowse = mock.calls.last!; let oldCount = mock.calls.count
        browse.receive(.service(add: true, index: 9, name: "Stale", type: "_thunderctrl._tcp.", domain: "local."))
        await flush(); check(mock.calls.count == oldCount, "restart rejects old generation")
        for n in 0..<100 { newBrowse.receive(.service(add: true, index: 11, name: "Peer\(n)", type: "_thunderctrl._tcp.", domain: "local.")) }
        await flush(); check(mock.live.count == 32, "31 peer sources plus browse maximum")
        discovery.expire(now: Date().addingTimeInterval(11))
        check(mock.live.count == 1, "unresolved peers expire")
        discovery.advertise(interfaceIndex: 0, name: "bad", port: 1)
        check(mock.live.isEmpty, "invalid advertisement stops all fail closed")
        check(mock.calls.allSatisfy { $0.index == 9 || $0.index == 11 }, "never any/default interface")
        var errors: [String] = []
        discovery.onError = { errors.append($0) }
        mock.failOpen = true
        discovery.startBrowsing(interfaceIndex: 9, localIPv4: "10.0.0.1") { _ in deliveries += 1 }
        check(mock.live.isEmpty, "creation failure safe")
        discovery.stop()
        check(errors.count == 1 && errors[0].contains("-65537"), "browse creation error reported")
        discovery.advertise(interfaceIndex: 9, name: "Receiver", port: 42)
        check(errors.count == 2, "register creation error reported")
        mock.failOpen = false
        discovery.startBrowsing(interfaceIndex: 9, localIPv4: "10.0.0.1") { _ in }
        let errorBrowse = mock.calls.last!
        errorBrowse.receive(.failed(-65570)); await flush()
        check(errors.count == 3 && errors.last!.contains("-65570"), "async browse error code reported")
        discovery.advertise(interfaceIndex: 9, name: "Receiver", port: 42)
        let errorRegister = mock.calls.last!
        errorRegister.receive(.failed(-65548)); await flush()
        check(errors.count == 4 && errors.last!.contains("-65548"), "async register error code reported")
        discovery.stop()
        errorRegister.receive(.failed(-65555)); errorBrowse.receive(.failed(-65555)); await flush()
        check(errors.count == 4, "no error callbacks after stop")
        // Reproduce failed registration while the TCP listener belongs to App.
        discovery.advertise(interfaceIndex: 9, name: "Receiver", port: 49177)
        let failedAdvertisement = mock.calls.last!
        check(discovery.isAdvertising, "registration operation initially present")
        failedAdvertisement.receive(.failed(-65563)); await flush()
        check(!discovery.isAdvertising, "failed advertisement remains observable for App repair")
        discovery.advertise(interfaceIndex: 9, name: "Receiver", port: 49177)
        check(discovery.isAdvertising, "same verified listener can be advertised again")
        failedAdvertisement.receive(.failed(-65563)); await flush()
        check(discovery.isAdvertising, "old registration failure cannot remove repaired advertisement")
        discovery.stop()
        check(!discovery.isAdvertising && !discovery.isBrowsing, "stop cancels repaired registration")

        // One service Add + failed resolve leaves a live empty browser. A new
        // round must resolve the unchanged service, rejecting old callbacks.
        discovery.startBrowsing(interfaceIndex: 9, localIPv4: "10.0.0.1") { peers = $0 }
        let staleBrowse = mock.calls.last!
        staleBrowse.receive(.service(add: true, index: 9, name: "Receiver", type: "_thunderctrl._tcp.", domain: "local."))
        await flush(); let failedResolve = mock.calls.last!
        failedResolve.receive(.failed(-65563)); await flush()
        check(discovery.isBrowsing && peers.isEmpty, "resolve failure alone leaves live empty browse")
        discovery.startBrowsing(interfaceIndex: 9, localIPv4: "10.0.0.1") { peers = $0 }
        let repairedBrowse = mock.calls.last!
        repairedBrowse.receive(.service(add: true, index: 9, name: "Receiver", type: "_thunderctrl._tcp.", domain: "local."))
        await flush(); let repairedResolve = mock.calls.last!
        repairedResolve.receive(.resolved(index: 9, host: "receiver.local.", port: 49177))
        await flush(); let repairedAddress = mock.calls.last!
        repairedAddress.receive(.address(add: true, index: 9, ipv4: "10.0.0.2", ttl: 120))
        await flush(); check(peers.count == 1 && peers[0].port == 49177, "fresh same-interface search rediscovers same peer")
        staleBrowse.receive(.failed(-65563)); failedResolve.receive(.failed(-65563)); await flush()
        check(discovery.isBrowsing && peers.count == 1, "stale failure cannot erase renewed search")
        discovery.stop()
        print("PASS: \(checks) pure validation and mock lifecycle checks; no native DNS/network/HID executed")
    }
}
