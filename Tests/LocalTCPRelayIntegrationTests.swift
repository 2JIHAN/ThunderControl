import Foundation
import CryptoKit
import Darwin
import AppKit


private enum LocalTCPError: Error, CustomStringConvertible {
    case assertion(String)
    var description: String {
        switch self { case .assertion(let m): return m }
    }
}
private func localTCPRequire(_ ok: Bool, _ message: String) throws {
    if !ok { throw LocalTCPError.assertion(message) }
}

private final class LocalTCPMemoryStore: TrustedPairingStorage, @unchecked Sendable {
    let id: String
    private let lock = NSLock()
    private var keys: [String: Data] = [:]
    init(_ id: String) { self.id = id }
    func identity() throws -> String { id }
    private func index(_ sender: Bool, _ peer: String) -> String {
        (sender ? "sender:" : "receiver:") + peer
    }
    func key(isSender: Bool, peerID: String) throws -> SymmetricKey? {
        lock.lock(); defer { lock.unlock() }
        return keys[index(isSender, peerID)].map { SymmetricKey(data: $0) }
    }
    func save(_ key: SymmetricKey, isSender: Bool, peerID: String) throws {
        lock.lock(); defer { lock.unlock() }
        let k = index(isSender, peerID)
        guard keys[k] == nil else { throw LocalTCPError.assertion("duplicate trust write") }
        keys[k] = key.withUnsafeBytes { Data($0) }
    }
}

private func localTCPLoopbackPair() throws -> (OwnedSocket, OwnedSocket) {
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    guard listener >= 0 else { throw LocalTCPError.assertion("listener socket") }
    let listenOwned = OwnedSocket(listener)
    var yes: Int32 = 1
    guard setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
        throw LocalTCPError.assertion("SO_REUSEADDR")
    }
    var bindAddr = sockaddr_in()
    bindAddr.sin_family = sa_family_t(AF_INET)
    bindAddr.sin_port = 0
    bindAddr.sin_addr.s_addr = UInt32(0x7f000001).bigEndian
    let bindResult = withUnsafePointer(to: &bindAddr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else { throw LocalTCPError.assertion("bind 127.0.0.1:0") }
    guard listen(listener, 1) == 0 else { throw LocalTCPError.assertion("listen") }
    var boundAddr = sockaddr_in()
    var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
    let getnameResult = withUnsafeMutablePointer(to: &boundAddr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(listener, $0, &boundLen)
        }
    }
    guard getnameResult == 0 else { throw LocalTCPError.assertion("getsockname") }
    try localTCPRequire(boundAddr.sin_addr.s_addr == UInt32(0x7f000001).bigEndian,
        "endpoint not bound to loopback 127.0.0.1")
    try localTCPRequire(boundAddr.sin_port != 0, "ephemeral port assignment")

    let client = socket(AF_INET, SOCK_STREAM, 0)
    guard client >= 0 else { throw LocalTCPError.assertion("client socket") }
    let clientOwned = OwnedSocket(client)
    let connectResult = withUnsafePointer(to: &boundAddr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connectResult == 0 else { throw LocalTCPError.assertion("connect loopback") }
    var peerAddr = sockaddr_in()
    var peerLen = socklen_t(MemoryLayout<sockaddr_in>.size)
    let acceptedFD = withUnsafeMutablePointer(to: &peerAddr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            accept(listener, $0, &peerLen)
        }
    }
    guard acceptedFD >= 0 else { throw LocalTCPError.assertion("accept") }
    try localTCPRequire(peerAddr.sin_addr.s_addr == UInt32(0x7f000001).bigEndian,
        "accepted peer not loopback")
    let serverOwned = OwnedSocket(acceptedFD)
    listenOwned.interrupt()
    withExtendedLifetime(listenOwned) {}

    for fd in [clientOwned.fd, serverOwned.fd] {
        var one: Int32 = 1
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw LocalTCPError.assertion("socket options on loopback endpoint")
        }
    }
    return (clientOwned, serverOwned)
}

private func localTCPPair(sender: Bool, socket: OwnedSocket) -> PINPairingTransport {
    PINPairingTransport(
        send: { try sendFrame(socket.fd, $0) },
        receive: { try readFrame(socket.fd, maximum: 4096) },
        cancelled: { false })
}

private struct LocalTCPSides {
    let senderStore: LocalTCPMemoryStore
    let receiverStore: LocalTCPMemoryStore
}

private struct LocalTCPConnection {
    let sender: OwnedSocket
    let receiver: OwnedSocket
    let root: SymmetricKey
    let senderSession: String
    let receiverSession: String
    var outgoing: SymmetricKey { connectionKey(root, sender: senderSession, receiver: receiverSession) }
}

private func localTCPRunPairing(sides: LocalTCPSides, senderSession: String, receiverSession: String, allowNewTrust: Bool,
    pin: String?, expectEnrollment: Bool) throws -> LocalTCPConnection {
    let (a, b) = try localTCPLoopbackPair()
    var established = false
    defer { if !established { a.interrupt(); b.interrupt() } }
    let group = DispatchGroup()
    final class Box<T>: @unchecked Sendable { var value: T?; var error: Error? }
    let senderKey = Box<SymmetricKey>()
    let receiverKey = Box<SymmetricKey>()
    let senderScope = Box<String>()
    let receiverScope = Box<String>()
    let approvals = Box<Int>(); approvals.value = 0
    let approvalLock = NSLock()

    let senderScopeID = senderSession
    let receiverScopeID = receiverSession
    for isSender in [true, false] {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            let socket = isSender ? a : b
            let local = isSender ? senderScopeID : receiverScopeID
            let name = isSender ? "sender-fixture" : "receiver-fixture"
            do {
                let scope = try agreePairingScope(sendMode: isSender,
                    localSession: local,
                    send: { try sendFrame(socket.fd, $0) },
                    receive: { try readFrame(socket.fd) })
                if isSender { senderScope.value = scope } else { receiverScope.value = scope }
                let io = localTCPPair(sender: isSender, socket: socket)
                let store: TrustedPairingStorage = isSender ? sides.senderStore : sides.receiverStore
                let key = try performTrustedPairing(isSender: isSender,
                    senderPIN: isSender ? pin : nil,
                    sessionID: scope, localName: name,
                    transport: io, store: store,
                    nonce: { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } },
                    allowNewTrust: allowNewTrust,
                    authenticatedIdentity: nil,
                    receiverApproval: { _ in
                        approvalLock.lock()
                        approvals.value = (approvals.value ?? 0) + 1
                        approvalLock.unlock()
                        return pin ?? ""
                    })
                if isSender { senderKey.value = key } else { receiverKey.value = key }
            } catch {
                fputs("local-tcp fixture \(isSender ? "sender" : "receiver"): \(error)\n", stderr)
                if isSender { senderKey.error = error } else { receiverKey.error = error }
            }
        }
    }
    guard group.wait(timeout: .now() + 10) == .success else {
        a.interrupt(); b.interrupt()
        _ = group.wait(timeout: .now() + 4)
        throw LocalTCPError.assertion("pairing deadline exceeded")
    }
    if let e = senderKey.error { throw e }
    if let e = receiverKey.error { throw e }
    try localTCPRequire(senderScope.value == receiverScope.value, "scope agreement")
    try localTCPRequire(senderScope.value == senderScopeID, "sender prelude sets scope")
    try localTCPRequire(senderKey.value != nil && receiverKey.value != nil, "keys produced")
    try localTCPRequire(
        senderKey.value!.withUnsafeBytes({ Data($0) }) == receiverKey.value!.withUnsafeBytes({ Data($0) }),
        "both endpoints agreed on identical session root key")
    let approvalCount = approvals.value ?? 0
    if expectEnrollment {
        try localTCPRequire(approvalCount == 1, "exactly one PIN approval on enrollment")
    } else {
        try localTCPRequire(approvalCount == 0, "no PIN approval on reconnect")
    }
    for (socket, session, kind) in [(a, senderSession, "sender-hello-v5"), (b, receiverSession, "receiver-hello-v5")] {
        try sendFrame(socket.fd, seal(Wire(kind: kind, session: session, sequence: 0), senderKey.value!))
    }
    let atSender = try unseal(readFrame(a.fd), senderKey.value!)
    let atReceiver = try unseal(readFrame(b.fd), receiverKey.value!)
    try localTCPRequire(atSender.kind == "receiver-hello-v5" && atSender.session == receiverSession && atReceiver.kind == "sender-hello-v5" && atReceiver.session == senderSession, "sealed role/session confirmation")
    established = true
    return LocalTCPConnection(sender: a, receiver: b, root: senderKey.value!, senderSession: senderSession, receiverSession: receiverSession)
}

private final class LocalTCPResult: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var failure: Error?
    func complete(_ error: Error?) { lock.lock(); failure = error; finished = true; lock.unlock() }
    var done: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    var error: Error? { lock.lock(); defer { lock.unlock() }; return failure }
}

private final class LocalTCPMockCursorRecoveryAPI: CursorRecoveryAPI {
    func associate(_ associated: Bool) -> CGError { .success }
    func hide(display: CGDirectDisplayID) -> CGError { .success }
    func show(display: CGDirectDisplayID) -> CGError { .success }
    func warp(to point: CGPoint) -> CGError { .success }
}

private final class LocalTCPInputRecorder {
    struct CGRecord { let type: UInt32; let key: Int64; let button: Int64 }
    var plans: [MotionPlan] = []
    var cg: [CGRecord] = []
    var opens = 0
    var closes = 0
    var epoch: UInt64 = 0
    var permission = true
    var afterOpen: () -> Void = {}
    var api: RelayInputAPI {
        RelayInputAPI(motion: HIDMotionAPI(permissionCheck: { self.permission }, open: {
            self.opens += 1; self.afterOpen(); return (0, 42)
        }, post: { port, plan in
            precondition(Thread.isMainThread && port == 42)
            self.plans.append(plan); return 0
        }, close: { port in precondition(port == 42); self.closes += 1 }), postCG: { event, _ in
            precondition(Thread.isMainThread)
            self.cg.append(CGRecord(type: event.type.rawValue,
                key: event.getIntegerValueField(.keyboardEventKeycode),
                button: event.getIntegerValueField(.mouseEventButtonNumber)))
        })
    }
}

private func localTCPPump(until predicate: () -> Bool, _ note: String) throws {
    precondition(Thread.isMainThread)
    let deadline = Date().addingTimeInterval(5)
    while !predicate() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.002))
    }
    try localTCPRequire(predicate(), "bounded main pump: " + note)
}

private final class LocalTCPFixture {
    let sender: Relay
    let receiver: Relay
    let input: LocalTCPInputRecorder
    let connection: LocalTCPConnection
    let context: SessionContext
    let senderContext: SessionContext
    let result = LocalTCPResult()
    let suite: String
    let defaults: UserDefaults
    let token = UUID().uuidString
    let queued = DispatchSemaphore(value: 0)
    let map = ReceiverDesktop(revision: 7, mainID: 11, displays: [ReceiverDisplay(id: 11, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))])
    var finished = false
    var processed = 0
    var point = CGPoint(x: 800, y: 400)

    init(sides: LocalTCPSides, enrollment: Bool) throws {
        precondition(Thread.isMainThread)
        suite = "ThunderControl.tests.local-tcp." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        let recorder = LocalTCPInputRecorder()
        input = recorder
        let cursor = LocalTCPMockCursorRecoveryAPI()
        sender = Relay(cursorResources: CursorRecoveryController(api: cursor), receiverCursor: CursorVisibilityController(api: cursor), layoutStore: SavedScreenLayoutStore(defaults: defaults), desktopPlacementStore: SavedDesktopPlacementStore(defaults: defaults), inputAPI: recorder.api)
        receiver = Relay(cursorResources: CursorRecoveryController(api: cursor), receiverCursor: CursorVisibilityController(api: cursor), layoutStore: SavedScreenLayoutStore(defaults: defaults), desktopPlacementStore: SavedDesktopPlacementStore(defaults: defaults), inputAPI: recorder.api)
        sender.prepareLocalTCPSafetyForTests(); receiver.prepareLocalTCPSafetyForTests()
        connection = try localTCPRunPairing(sides: sides, senderSession: sender.sessionForTests, receiverSession: receiver.sessionForTests, allowNewTrust: enrollment, pin: enrollment ? "4837" : nil, expectEnrollment: enrollment)
        context = SessionContext(connection.receiver)
        senderContext = SessionContext(connection.sender)
        sender.prepareLocalTCPSafetyForTests(); receiver.prepareLocalTCPSafetyForTests()
        sender.senderForTests = true
        sender.connectionForTests = connection.sender; sender.contextForTests = senderContext; sender.keyForTests = connection.outgoing
        receiver.connectionForTests = connection.receiver; receiver.contextForTests = context
        receiver.keyForTests = connectionKey(connection.root, sender: connection.senderSession, receiver: connection.receiverSession, reverse: true)
        receiver.desktopEpochForTests = { [input] in input.epoch }
        receiver.desktopMapReadForTests = { [map] _, _ in map }
        receiver.desktopInputPermissionForTests = { [input] in input.permission }
        receiver.prepareDesktopSystemGestureForTests(map: map, point: point, token: token)
        precondition(receiver.desktopInputPostForTests == nil)
        receiver.authenticatedFrameQueuedForTests = { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async { self.processed += 1 }
            self.queued.signal()
        }
        let relay = receiver, conn = connection, ctx = context, output = result, generation = receiver.generation
        DispatchQueue.global(qos: .userInitiated).async {
            var validator = PeerValidator(senderPeer: true, session: conn.senderSession, concurrentDisplaySupported: true, multiDisplayDesktopSupported: true)
            do {
                try relay.runAuthenticatedStream(fd: conn.receiver.fd, incomingKey: conn.outgoing, validator: &validator, context: ctx, generation: generation)
                output.complete(nil)
            } catch { output.complete(error) }
        }
    }

    func packet(type: UInt32 = 5, dx: Double = 9, dy: Double = -3, token override: String? = nil, revision: UInt64 = 7) throws -> Wire {
        let moving = [UInt32(5), 6, 7, 27].contains(type)
        let destination = moving ? CGPoint(x: point.x + dx, y: point.y + dy) : point
        let event: CGEvent?
        if [UInt32(10), 11, 12].contains(type) {
            event = CGEvent(keyboardEventSource: nil, virtualKey: type == 12 ? 56 : 0, keyDown: type != 11)
            event?.type = CGEventType(rawValue: type)!
        } else {
            event = CGEvent(mouseEventSource: nil, mouseType: CGEventType(rawValue: type)!, mouseCursorPosition: destination, mouseButton: [UInt32(3), 4, 7].contains(type) ? .right : .left)
        }
        guard let event else { throw LocalTCPError.assertion("CGEvent construction") }
        event.flags = []
        if moving {
            event.setDoubleValueField(.mouseEventDeltaX, value: dx)
            event.setDoubleValueField(.mouseEventDeltaY, value: dy)
        }
        guard let data = event.data else { throw LocalTCPError.assertion("CGEvent serialization") }
        return Wire(kind: "event", session: connection.senderSession, sequence: 0, raw: type, data: data as Data, token: override ?? token, desktopMapRevision: revision, desktopGlobalX: destination.x, desktopGlobalY: destination.y)
    }

    func send(_ wire: Wire, acceptedMotion: Bool = false) throws {
        let count = processed + 1
        sender.prepareLocalTCPSafetyForTests(); receiver.prepareLocalTCPSafetyForTests()
        try localTCPRequire(sender.enqueue(wire), "actual Relay.enqueue accepted")
        sender.flushLocalTCPWritesForTests()
        try localTCPPump(until: { self.processed >= count || self.result.done }, "authenticated receive marker")
        try localTCPRequire(processed >= count, "frame reached actual receive before assertion; error=\(String(describing: result.error))")
        if acceptedMotion { point = CGPoint(x: wire.desktopGlobalX!, y: wire.desktopGlobalY!) }
    }

    func finish() throws {
        if finished { return }
        context.cancel(reason: "local TCP fixture teardown")
        senderContext.cancel(reason: "local TCP fixture teardown")
        connection.sender.interrupt(); connection.receiver.interrupt()
        try localTCPPump(until: { self.result.done }, "stream worker teardown")
        var drained = false
        DispatchQueue.main.async { drained = true }
        try localTCPPump(until: { drained }, "queued receive drain")
        receiver.stop(); sender.stop()
        receiver.authenticatedFrameQueuedForTests = nil
        input.afterOpen = {}
        defaults.removePersistentDomain(forName: suite)
        finished = true
    }
}

private enum LocalTCPNegative: String, CaseIterable {
    case wrongToken, staleRevision, permissionDenied, epochAfterOpen
}

func runLocalTCPRelayIntegrationTests() throws {
    precondition(Thread.isMainThread)
    let sides = LocalTCPSides(senderStore: LocalTCPMemoryStore(UUID().uuidString), receiverStore: LocalTCPMemoryStore(UUID().uuidString))
    let core = try LocalTCPFixture(sides: sides, enrollment: true)
    var stale: Data
    do {
        defer { try? core.finish() }
        var wire = try core.packet()
        wire.sequence = 1
        stale = try seal(wire, core.connection.outgoing)
        for type: UInt32 in [5, 6, 7] {
            let w = try core.packet(type: type, dx: 9, dy: -3)
            try core.send(w, acceptedMotion: true)
            guard let p = core.input.plans.last else { throw LocalTCPError.assertion("actual HID plan missing") }
            let payload = p.payload
            try localTCPRequire(p.type == type && p.location == core.point && p.dx == 9 && p.dy == -3 && p.point.x == Int16(core.point.x) && p.point.y == Int16(core.point.y) && p.subx == 0 && p.suby == 0 && payload.mouseMove.dx == 9 && payload.mouseMove.dy == -3 && payload.mouseMove.subx == 0 && payload.mouseMove.suby == 0 && p.flags == 0x100, "exact HID motion/drag plan and payload")
        }
        try localTCPRequire(core.input.plans.count == 3 && core.input.cg.isEmpty && core.input.opens == 1, "three motions only HID, one port")
        for type: UInt32 in [10, 11, 1, 2, 3, 4] { try core.send(core.packet(type: type)) }
        try localTCPRequire(core.input.cg.map(\.type) == [10, 11, 1, 2, 3, 4], "keyboard and button CG fallback only")
        try localTCPRequire(core.input.cg[0].key == 0 && core.input.cg[4].button == 1, "keyboard/button payload")
        try core.send(core.packet(type: 10)); try core.send(core.packet(type: 1))
        core.context.cancel(reason: "test stop cleanup"); core.senderContext.cancel()
        try localTCPPump(until: { core.result.done }, "stop worker")
        core.receiver.stop()
        let count = core.input.cg.count
        try localTCPRequire(core.input.cg.suffix(2).map(\.type).sorted() == [2, 11], "stop releases held key and button")
        core.receiver.stop()
        try localTCPRequire(core.input.cg.count == count && core.input.closes == 1, "repeated stop releases once and closes HID once")
        try core.finish()
    }
    print("PASS local TCP actual Relay.enqueue -> authenticated stream -> Relay.receive -> HID poster 5/6/7 exact payload; CG keyboard/buttons; idempotent stop cleanup")

    for scenario in LocalTCPNegative.allCases {
        let f = try LocalTCPFixture(sides: sides, enrollment: false)
        defer { try? f.finish() }
        var w = try f.packet()
        switch scenario {
        case .wrongToken: w.token = UUID().uuidString
        case .staleRevision: w.desktopMapRevision = 6
        case .permissionDenied: f.input.permission = false
        case .epochAfterOpen: f.input.afterOpen = { f.input.epoch += 1 }
        }
        try f.send(w)
        try localTCPRequire(f.input.plans.isEmpty && f.input.cg.isEmpty, "\(scenario.rawValue) rejected after actual main receive marker")
        if scenario == .epochAfterOpen { try localTCPRequire(f.input.opens == 1, "late epoch actually changed inside fake open") }
        try f.finish()
        print("PASS local TCP receive negative \(scenario.rawValue)")
    }

    enum Corruption: String, CaseIterable { case tamper, replay, wrongKey, oldCiphertext, partialHeader, partialPayload }
    for scenario in Corruption.allCases {
        let f = try LocalTCPFixture(sides: sides, enrollment: false)
        defer { try? f.finish() }
        try f.send(f.packet(), acceptedMotion: true)
        let before = f.input.plans.count
        var w = try f.packet(); w.sequence = scenario == .replay ? 1 : 2
        var bytes = try seal(w, scenario == .wrongKey ? SymmetricKey(size: .bits256) : f.connection.outgoing)
        switch scenario {
        case .tamper: bytes[bytes.startIndex] ^= 1
        case .oldCiphertext: bytes = stale
        default: break
        }
        if scenario == .partialHeader || scenario == .partialPayload {
            var raw = scenario == .partialHeader ? Data([0, 0]) : Data([0, 0, 0, 10, 1, 2])
            let sent = raw.withUnsafeMutableBytes { Darwin.send(f.connection.sender.fd, $0.baseAddress, $0.count, 0) }
            try localTCPRequire(sent == raw.count, "partial frame sent")
            f.connection.sender.interrupt()
        } else { try sendFrame(f.connection.sender.fd, bytes) }
        try localTCPPump(until: { f.result.done }, "\(scenario.rawValue) bounded rejection")
        try localTCPRequire(f.result.error != nil && f.input.plans.count == before && f.input.cg.isEmpty, "\(scenario.rawValue) fails before extra input")
        try f.finish()
        print("PASS local TCP shared pump rejection \(scenario.rawValue); fresh trusted reconnect motion accepted")
    }

    for cancel in [true, false] {
        let f = try LocalTCPFixture(sides: sides, enrollment: false)
        defer { try? f.finish() }
        let w = try f.packet()
        try localTCPRequire(f.sender.enqueue(w), "queue cancellation frame enqueued")
        f.sender.flushLocalTCPWritesForTests()
        try localTCPRequire(f.queued.wait(timeout: .now() + 3) == .success, "frame queued while main deliberately held")
        if cancel { f.context.cancel(reason: "cancel before main receive") }
        else { f.receiver.invalidateLocalTCPGenerationForTests() }
        try localTCPPump(until: { f.processed == 1 }, "queued stale/cancelled receive marker")
        try localTCPRequire(f.input.plans.isEmpty && f.input.cg.isEmpty && f.input.opens == 0, "queued receive rejected before any effect")
        try f.finish()
        print("PASS local TCP queued inbound \(cancel ? "context cancellation" : "stale generation")")
    }
    print("PASS local TCP Relay integration. Core handoff is explicitly primed active; begin/commit, discovery, bridge lease and delayed outgoing writes are not covered. All input and cursor effects are injected record-only APIs.")
}
