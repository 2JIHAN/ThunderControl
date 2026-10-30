import Foundation
import CryptoKit
import Darwin
import AppKit
import IOKit


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
    let senderHello: Wire
    let receiverHello: Wire
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
        try sendFrame(socket.fd, seal(Wire(concurrentDisplayCodec: 1, kind: kind, session: session, sequence: 0, multiDisplayDesktopCodec: 1, desktopGestureCodec: 1, bridgeRecoveryCodec: 1), senderKey.value!))
    }
    let atSender = try unseal(readFrame(a.fd), senderKey.value!)
    let atReceiver = try unseal(readFrame(b.fd), receiverKey.value!)
    try localTCPRequire(atSender.kind == "receiver-hello-v5" && atSender.session == receiverSession && atReceiver.kind == "sender-hello-v5" && atReceiver.session == senderSession, "sealed role/session confirmation")
    try localTCPRequire(atSender.multiDisplayDesktopCodec == 1 && atReceiver.multiDisplayDesktopCodec == 1 && atSender.bridgeRecoveryCodec == 1 && atReceiver.bridgeRecoveryCodec == 1, "wire hello codecs negotiated")
    established = true
    return LocalTCPConnection(sender: a, receiver: b, senderHello: atReceiver, receiverHello: atSender, root: senderKey.value!, senderSession: senderSession, receiverSession: receiverSession)
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
    struct CGRecord { let type: UInt32; let key: Int64; let button: Int64; let flags: CGEventFlags }
    var plans: [HIDInputPlan] = []
    var simulatedKernelFlags: CGEventFlags = []
    var flagsAtPost: [CGEventFlags] = []
    var nativePostResult: Int32 = 0
    var afterPost: () -> Void = {}
    var effects: [String] = []
    var totalPosts: Int { plans.count + cg.count }
    var cg: [CGRecord] = []
    var warps: [CGPoint] = []
    var focusPreparations = 0
    var opens = 0
    var closes = 0
    var epoch: UInt64 = 0
    var permission = true
    var afterOpen: () -> Void = {}
    var api: RelayInputAPI {
        RelayInputAPI(native: HIDInputAPI(permissionCheck: { self.permission }, open: {
            self.opens += 1; self.afterOpen(); return (0, 42)
        }, post: { port, plan in
            precondition(Thread.isMainThread && port == 42)
            self.plans.append(plan); self.effects.append("post")
            if self.nativePostResult == 0 && plan.options == 1 { self.simulatedKernelFlags = CGEventFlags(rawValue: UInt64(plan.flags)) }
            self.flagsAtPost.append(self.simulatedKernelFlags)
            self.afterPost(); return self.nativePostResult
        }, close: { port in precondition(port == 42); self.closes += 1; self.effects.append("close") },
            readFlags: { self.simulatedKernelFlags }), postCG: { event, _ in
            precondition(Thread.isMainThread)
            self.cg.append(CGRecord(type: event.type.rawValue,
                key: event.getIntegerValueField(.keyboardEventKeycode),
                button: event.getIntegerValueField(.mouseEventButtonNumber), flags: event.flags))
        }, warp: { point in self.warps.append(point); return .success })
    }
}

private func localTCPPump(until predicate: () -> Bool, _ note: String, tick: () -> Void = {}) throws {
    precondition(Thread.isMainThread)
    let deadline = Date().addingTimeInterval(5)
    while !predicate() && Date() < deadline {
        tick()
        RunLoop.main.run(until: Date().addingTimeInterval(0.002))
    }
    try localTCPRequire(predicate(), "bounded main pump: " + note)
}

private enum LocalTCPFixtureMode { case primed, negotiated }

private final class LocalTCPFixture {
    let sender: Relay
    let receiver: Relay
    let input: LocalTCPInputRecorder
    let connection: LocalTCPConnection
    let context: SessionContext
    let senderContext: SessionContext
    let result = LocalTCPResult()
    let reverseResult = LocalTCPResult()
    let mode: LocalTCPFixtureMode
    var reverseProcessed = 0
    var forwardKinds: [String: Int] = [:]
    var reverseKinds: [String: Int] = [:]
    let suite: String
    let defaults: UserDefaults
    private let primedToken = UUID().uuidString
    var token: String { mode == .primed ? primedToken : sender.localTCPTokenForTests ?? "missing-token" }
    let queued = DispatchSemaphore(value: 0)
    let map = ReceiverDesktop(revision: 7, mainID: 11, displays: [ReceiverDisplay(id: 11, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))])
    var writerReleases: [DispatchSemaphore] = []
    var finished = false
    var processed = 0
    var point = CGPoint(x: 800, y: 400)

    init(sides: LocalTCPSides, enrollment: Bool, mode: LocalTCPFixtureMode = .primed, inputAPIOverride: RelayInputAPI? = nil) throws {
        self.mode = mode
        precondition(Thread.isMainThread)
        suite = "ThunderControl.tests.local-tcp." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        let recorder = LocalTCPInputRecorder()
        input = recorder
        let cursor = LocalTCPMockCursorRecoveryAPI()
        sender = Relay(cursorResources: CursorRecoveryController(api: cursor), receiverCursor: CursorVisibilityController(api: cursor), layoutStore: SavedScreenLayoutStore(defaults: defaults), desktopPlacementStore: SavedDesktopPlacementStore(defaults: defaults), inputAPI: recorder.api)
        receiver = Relay(cursorResources: CursorRecoveryController(api: cursor), receiverCursor: CursorVisibilityController(api: cursor), layoutStore: SavedScreenLayoutStore(defaults: defaults), desktopPlacementStore: SavedDesktopPlacementStore(defaults: defaults), inputAPI: inputAPIOverride ?? recorder.api)
        if inputAPIOverride == nil { receiver.desktopPhysicalInputsForTests = { false } }
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
        if mode == .primed {
            receiver.prepareDesktopSystemGestureForTests(map: map, point: point, token: token)
        } else {
            let source = DisplayTopologySnapshot(mainID: 22, activeIDs: [22], bounds: CGRect(x: 0, y: 0, width: 1200, height: 800))
            let target = DisplayTopologySnapshot(mainID: 11, activeIDs: [11], bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))
            sender.prepareLocalTCPNegotiationForTests(hello: connection.receiverHello, topology: source)
            receiver.prepareLocalTCPNegotiationForTests(hello: connection.senderHello, topology: target)
            sender.desktopSourceReadForTests = { source }
            sender.desktopFocusSafetyForTests = { true }
            sender.desktopPhysicalInputsForTests = { false }
            sender.desktopFocusBeginForTests = { [weak sender] token in
                _ = sender?.sendLocalTCPDesktopBeginForTests(token: token)
            }
            sender.restoreSourceActivation = {}
            receiver.prepareReceiverInputTarget = { [input] needed, completion in
                input.focusPreparations += 1; completion(needed())
            }
            receiver.desktopMapReadForTests = { revision, _ in
                ReceiverDesktop(revision: max(1, revision), mainID: 11, displays: [ReceiverDisplay(id: 11, bounds: target.bounds)])
            }
            sender.authenticatedFrameQueuedForTests = { [weak self] wire in
                DispatchQueue.main.async { self?.reverseProcessed += 1; self?.reverseKinds[wire.kind, default: 0] += 1 }
            }
            let relay = sender, conn = connection, ctx = senderContext, output = reverseResult, generation = sender.generation
            DispatchQueue.global(qos: .userInitiated).async {
                var validator = PeerValidator(senderPeer: false, session: conn.receiverSession, concurrentDisplaySupported: true, multiDisplayDesktopSupported: true, bridgeRecoverySupported: true)
                do {
                    try relay.runAuthenticatedStream(fd: conn.sender.fd, incomingKey: connectionKey(conn.root, sender: conn.senderSession, receiver: conn.receiverSession, reverse: true), validator: &validator, context: ctx, generation: generation)
                    output.complete(nil)
                } catch {
                    output.complete(error)
                    DispatchQueue.main.async {
                        guard relay.generation == generation else { return }
                        relay.stop(reason: "local TCP reverse stream ended")
                    }
                }
            }
        }
        precondition(receiver.desktopInputPostForTests == nil)
        receiver.authenticatedFrameQueuedForTests = { [weak self] wire in
            guard let self else { return }
            DispatchQueue.main.async { self.processed += 1; self.forwardKinds[wire.kind, default: 0] += 1 }
            self.queued.signal()
        }
        let relay = receiver, conn = connection, ctx = context, output = result, generation = receiver.generation
        DispatchQueue.global(qos: .userInitiated).async {
            var validator = PeerValidator(senderPeer: true, session: conn.senderSession, concurrentDisplaySupported: true, multiDisplayDesktopSupported: true, desktopGesturesSupported: mode == .negotiated, bridgeRecoverySupported: mode == .negotiated)
            do {
                try relay.runAuthenticatedStream(fd: conn.receiver.fd, incomingKey: conn.outgoing, validator: &validator, context: ctx, generation: generation)
                output.complete(nil)
            } catch { output.complete(error) }
        }
    }

    func packet(type: UInt32 = 5, dx: Double = 9, dy: Double = -3, token override: String? = nil, revision: UInt64 = 7, flags: CGEventFlags = [], key: CGKeyCode? = nil) throws -> Wire {
        let revision = mode == .negotiated ? receiver.desktopPublishedRevisionForTests : revision
        let moving = [UInt32(5), 6, 7, 27].contains(type)
        let destination = moving ? (mode == .negotiated ? map.moved(from: point, delta: CGVector(dx: dx, dy: dy)) : CGPoint(x: point.x + dx, y: point.y + dy)) : point
        let event: CGEvent?
        if [UInt32(10), 11, 12].contains(type) {
            event = CGEvent(keyboardEventSource: nil, virtualKey: key ?? (type == 12 ? 56 : 0), keyDown: type != 11)
            event?.type = CGEventType(rawValue: type)!
        } else if type == 22 {
            event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0)
            event?.location = destination
        } else {
            event = CGEvent(mouseEventSource: nil, mouseType: CGEventType(rawValue: type)!, mouseCursorPosition: destination, mouseButton: [UInt32(3), 4, 7].contains(type) ? .right : [UInt32(25), 26, 27].contains(type) ? .center : .left)
        }
        guard let event else { throw LocalTCPError.assertion("CGEvent construction") }
        event.flags = flags
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
        for release in writerReleases { release.signal() }
        context.cancel(reason: "local TCP fixture teardown")
        senderContext.cancel(reason: "local TCP fixture teardown")
        connection.sender.interrupt(); connection.receiver.interrupt()
        try localTCPPump(until: { self.result.done && (self.mode == .primed || self.reverseResult.done) }, "both stream workers teardown")
        var drained = false
        DispatchQueue.main.async { drained = true }
        try localTCPPump(until: { drained }, "queued receive drain")
        var senderDrained = false, receiverDrained = false
        sender.drainLocalTCPWriterForTests { senderDrained = true }
        receiver.drainLocalTCPWriterForTests { receiverDrained = true }
        try localTCPPump(until: { senderDrained && receiverDrained }, "both outbound queues bounded teardown")
        receiver.stop(); sender.stop()
        receiver.authenticatedFrameQueuedForTests = nil
        sender.authenticatedFrameQueuedForTests = nil
        sender.desktopFocusBeginForTests = nil
        receiver.prepareReceiverInputTarget = nil
        sender.restoreSourceActivation = nil
        sender.localTCPOutgoingFrameForTests = nil
        receiver.localTCPOutgoingFrameForTests = nil
        input.afterOpen = {}
        defaults.removePersistentDomain(forName: suite)
        finished = true
    }
}

private enum LocalTCPNegative: String, CaseIterable {
    case wrongToken, staleRevision, permissionDenied, epochAfterOpen
}

func runLocalTCPRelayIntegrationTests() throws {
    precondition(Thread.isMainThread && CommandLine.arguments.contains("--self-test") && CommandLine.arguments.contains("--local-tcp-relay-integration-test"))
    if CommandLine.arguments.contains("--local-native-input-test") { try runLocalTCPNativeInput(); return }
    let sides = LocalTCPSides(senderStore: LocalTCPMemoryStore(UUID().uuidString), receiverStore: LocalTCPMemoryStore(UUID().uuidString))
    let core = try LocalTCPFixture(sides: sides, enrollment: true)
    do {
        defer { try? core.finish() }
        core.input.simulatedKernelFlags = .maskAlphaShift
        for type: UInt32 in [5, 6, 7] {
            let w = try core.packet(type: type, dx: 9, dy: -3)
            try core.send(w, acceptedMotion: true)
            guard let p = core.input.plans.last else { throw LocalTCPError.assertion("actual HID plan missing") }
            let payload = p.payload
            try localTCPRequire(p.type == type && p.location == core.point && p.dx == 9 && p.dy == -3 && p.point.x == Int16(core.point.x) && p.point.y == Int16(core.point.y) && p.subx == 0 && p.suby == 0 && payload.mouse.subx == 0 && payload.mouse.suby == 0 && payload.mouse.eventNum == 0 && payload.mouse.click == 0 && p.flags == 0x100, "exact HID motion/drag plan and payload")
        }
        try localTCPRequire(core.input.plans.count == 3 && core.input.cg.isEmpty && core.input.opens == 1, "three motions only HID, one port")
        for type: UInt32 in [10, 11, 1, 2, 3, 4, 25, 27, 26] {
            try core.send(core.packet(type: type), acceptedMotion: type == 27)
            guard let plan = core.input.plans.last else { throw LocalTCPError.assertion("ordinary HID plan missing") }
            try localTCPRequire(plan.type == type && plan.options == ([10, 11].contains(type) ? 1 : 2), "ordinary keyboard/button/other drag uses HID")
            if [10, 11].contains(type) { try localTCPRequire(plan.keyCode == 0 && plan.payload.key.keyCode == 0, "HID A payload") }
            if [25, 26, 27].contains(type) { try localTCPRequire(plan.button == 2 && plan.payload.mouse.buttonNumber == 2, "HID other button payload") }
        }
        guard let left = modifierDescriptors[56], let right = modifierDescriptors[60] else { throw LocalTCPError.assertion("Shift descriptors") }
        let leftShift = CGEventFlags(rawValue: left.aggregate.rawValue | left.sideBit)
        let bothShift = CGEventFlags(rawValue: leftShift.rawValue | right.sideBit)
        let rightShift = CGEventFlags(rawValue: right.aggregate.rawValue | right.sideBit)
        for (key, flags): (CGKeyCode, CGEventFlags) in [(56, leftShift), (60, bothShift), (56, rightShift)] {
            try core.send(core.packet(type: 12, flags: flags, key: key))
            try localTCPRequire(core.input.plans.last?.type == 12 && core.input.plans.last?.options == 1 && (core.input.plans.last!.flags & UInt32(CGEventFlags.maskShift.rawValue)) != 0 && core.input.simulatedKernelFlags.contains(.maskShift), "remaining Shift side keeps global Shift")
        }
        try core.send(core.packet(type: 6, flags: rightShift), acceptedMotion: true)
        try localTCPRequire(core.input.plans.last?.options == 2 && core.input.flagsAtPost.last?.contains(.maskShift) == true, "HID drag observes globally posted Shift")
        try core.send(core.packet(type: 12, flags: [], key: 60))
        try localTCPRequire(core.input.plans.last?.flags == 0 && core.input.simulatedKernelFlags.isEmpty, "last Shift up clears global flags")
        try localTCPRequire(core.input.cg.isEmpty, "no ordinary input uses CG")
        try core.send(core.packet(type: 22))
        try localTCPRequire(core.input.cg.map(\.type) == [22] && core.input.cg.last?.flags == [], "scroll remains CG without changing ordinary HID backend")
        try core.send(core.packet(type: 10)); try core.send(core.packet(type: 1))
        let beforeCleanup = core.input.plans.count
        core.context.cancel(reason: "test stop cleanup"); core.senderContext.cancel()
        try localTCPPump(until: { core.result.done }, "stop worker")
        core.receiver.stop()
        let cleanup = Array(core.input.plans.dropFirst(beforeCleanup))
        try localTCPRequire(cleanup.contains { $0.type == 11 && $0.keyCode == 0 } && cleanup.contains { $0.type == 2 && $0.button == 0 }, "stop releases held key and button through HID after auth expiry")
        try localTCPRequire(cleanup.last?.type == 12 && cleanup.last?.keyCode == 57 && core.input.simulatedKernelFlags == .maskAlphaShift, "stop restores baseline Caps after keyboard writes")
        let count = core.input.totalPosts
        core.receiver.stop()
        try localTCPRequire(core.input.totalPosts == count && core.input.closes == 1 && core.input.effects.last == "close" && core.input.cg.map(\.type) == [22], "repeated stop releases once and closes HID after cleanup")
        try core.finish()
    }
    print("PASS local TCP actual Relay.enqueue -> authenticated stream -> Relay.receive -> HID poster 5/6/7 exact payload; unified HID keyboard/buttons/27 Shift groups; idempotent HID stop cleanup")

    do {
        let failed = try LocalTCPFixture(sides: sides, enrollment: false)
        defer { try? failed.finish() }
        try failed.send(failed.packet(type: 10)); try failed.send(failed.packet(type: 1))
        failed.input.nativePostResult = Int32(kIOReturnError)
        failed.receiver.stop()
        try localTCPRequire(failed.receiver.hasUnresolvedLocalRecovery && failed.input.closes == 0 && failed.input.cg.isEmpty, "failed HID cleanup retains port without CG fallback")
        let attempted = failed.input.plans.count
        failed.input.nativePostResult = 0
        failed.receiver.stop()
        let retried = Array(failed.input.plans.dropFirst(attempted))
        try localTCPRequire(retried.contains { $0.type == 11 && $0.keyCode == 0 } && retried.contains { $0.type == 2 && $0.button == 0 } && failed.input.closes == 1, "failed HID cleanup retains owned inputs for retry")
        let completed = failed.input.totalPosts
        failed.receiver.stop()
        try localTCPRequire(!failed.receiver.hasUnresolvedLocalRecovery && failed.input.totalPosts == completed && failed.input.closes == 1, "successful cleanup retry is idempotent")
        try failed.finish()
    }
    print("PASS local TCP HID cleanup failure retained and retried without CG fallback")

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
        let before = f.input.totalPosts
        var w = try f.packet(); w.sequence = scenario == .replay ? 1 : 2
        var bytes = try seal(w, scenario == .wrongKey ? SymmetricKey(size: .bits256) : f.connection.outgoing)
        switch scenario {
        case .tamper: bytes[bytes.startIndex] ^= 1
        case .oldCiphertext: bytes = try seal(w, core.connection.outgoing)
        default: break
        }
        if scenario == .partialHeader || scenario == .partialPayload {
            var raw = scenario == .partialHeader ? Data([0, 0]) : Data([0, 0, 0, 10, 1, 2])
            let sent = raw.withUnsafeMutableBytes { Darwin.send(f.connection.sender.fd, $0.baseAddress, $0.count, 0) }
            try localTCPRequire(sent == raw.count, "partial frame sent")
            f.connection.sender.interrupt()
        } else { try sendFrame(f.connection.sender.fd, bytes) }
        try localTCPPump(until: { f.result.done }, "\(scenario.rawValue) bounded rejection")
        try localTCPRequire(f.result.error != nil && f.input.totalPosts == before && f.input.cg.isEmpty, "\(scenario.rawValue) fails before extra input")
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
    try runLocalTCPNegotiatedLifecycle(sides: sides)
    try runLocalTCPNegotiatedDenial(sides: sides)
    try runLocalTCPRemainingRecovery(sides: sides)
    try runLocalTCPLeaseKinds(sides: sides)
    try runLocalTCPOutboundCancellation(sides: sides)
    try runLocalTCPReplayReleaseEOF(sides: sides)
    try runLocalTCPOutboundReconnect(sides: sides)
    print("PASS local TCP Relay integration. Primed legacy and negotiated lifecycle suites completed; discovery and physical Thunderbolt remain outside this fixture. All input and cursor effects are injected record-only APIs.")
}

private func runLocalTCPNegotiatedLifecycle(sides: LocalTCPSides) throws {
    let f = try LocalTCPFixture(sides: sides, enrollment: false, mode: .negotiated)
    defer { try? f.finish() }
    f.receiver.consent(true)
    try localTCPPump(until: { f.sender.localTCPMapForTests != nil && f.reverseProcessed >= 2 }, "published map and input lease")
    guard let map = f.sender.localTCPMapForTests else { throw LocalTCPError.assertion("map adoption") }
    try localTCPRequire(map.revision == 1 && f.sender.localTCPPhaseForTests == "local" && f.receiver.localTCPPhaseForTests == "local", "negotiated endpoints start local")
    var previous: String?
    for cycle in 0..<2 {
        f.sender.desktopPrepareEntryForTests(map: map, origin: CGPoint(x: -1200, y: 0))
        let now = ProcessInfo.processInfo.systemUptime
        _ = f.sender.desktopEntryForTests(CGPoint(x: 600, y: 400), delta: CGVector(dx: 1, dy: 0), now: now)
        _ = f.sender.desktopEntryForTests(CGPoint(x: 1199, y: 400), delta: CGVector(dx: 1, dy: 0), now: now + 0.001)
        try localTCPPump(until: { f.sender.desktopFocusRemoteForTests || f.result.done || f.reverseResult.done }, "begin ready commit active")
        try localTCPRequire(f.sender.desktopFocusRemoteForTests && f.receiver.localTCPPhaseForTests == "targetActive", "actual negotiated remote ownership")
        let token = f.token
        try localTCPRequire(token != previous && UUID(uuidString: token) != nil, "fresh detector token")
        f.point = f.receiver.desktopFocusPointForTests!
        if let previous {
            let posts = f.input.totalPosts
            try f.send(f.packet(dx: 1, dy: 0, token: previous))
            try localTCPRequire(f.input.totalPosts == posts, "old handoff token rejected during fresh active handoff")
        }
        try f.send(f.packet(dx: 20, dy: 0), acceptedMotion: true)
        try localTCPRequire(!f.input.plans.isEmpty, "negotiated input reaches HID recorder")
        if cycle == 0 { f.sender.desktopLocalKeysForTests = [0] }
        try f.send(f.packet(dx: -40, dy: 0))
        if cycle == 0 {
            try localTCPPump(until: { f.receiver.localTCPPhaseForTests == "returning" && f.reverseKinds["return", default: 0] > 0 }, "held source key defers return ACK")
            try localTCPRequire(f.sender.desktopFocusRemoteForTests && f.forwardKinds["returnAck", default: 0] == 0, "no premature ACK while held")
            f.sender.desktopLocalKeysForTests = []
            f.sender.finishReturnIfDrained()
        }
        try localTCPPump(until: { f.sender.localTCPPhaseForTests == "local" && f.receiver.localTCPPhaseForTests == "local" }, "return and returnAck")
        previous = token
        let before = f.reverseProcessed
        f.receiver.refreshLocalTCPLeaseForTests()
        try localTCPPump(until: { f.reverseProcessed > before }, "fresh lease before next handoff")
    }
    try localTCPRequire(f.input.warps.count == 2 && f.input.focusPreparations == 2 && f.processed >= 8 && f.reverseProcessed >= 8, "recorded native boundary and both stream traces")
    let generationA = f.sender.generation, generationB = f.receiver.generation
    let bridge = Bridge(name: "bridge0", index: 7, ip: "169.254.1.1")
    let now = ProcessInfo.processInfo.systemUptime
    f.sender.observeLocalTCPBridgeForTests(.inactive(bridge), expected: bridge, now: now)
    f.sender.observeLocalTCPBridgeForTests(.active(bridge), expected: bridge, now: now + 0.01)
    try localTCPPump(until: { f.receiver.localTCPBridgeSuspendedForTests }, "real linkReset crossed TCP")
    f.receiver.observeLocalTCPBridgeForTests(.active(bridge), expected: bridge, now: now + 0.02)
    try localTCPPump(until: { !f.sender.localTCPBridgeSuspendedForTests && !f.receiver.localTCPBridgeSuspendedForTests }, "real linkReady crossed TCP")
    try localTCPRequire(f.sender.generation == generationA && f.receiver.generation == generationB && f.sender.contextForTests === f.senderContext && f.receiver.contextForTests === f.context && !f.context.cancelled && !f.senderContext.cancelled && f.sender.localTCPPhaseForTests == "local" && f.receiver.localTCPPhaseForTests == "local", "same authenticated contexts and local ownership after recovery")
    print("PASS local TCP negotiated same-connection linkReset linkReady recovery preserves contexts and generations")
    for subject in 0..<3 {
        let before = f.reverseProcessed
        f.receiver.refreshLocalTCPLeaseForTests()
        try localTCPPump(until: { f.reverseProcessed > before }, "fresh lease before active bridge reset")
        f.sender.desktopPrepareEntryForTests(map: map, origin: CGPoint(x: -1200, y: 0))
        let t = ProcessInfo.processInfo.systemUptime
        _ = f.sender.desktopEntryForTests(CGPoint(x: 600, y: 400), delta: CGVector(dx: 1, dy: 0), now: t)
        _ = f.sender.desktopEntryForTests(CGPoint(x: 1199, y: 400), delta: CGVector(dx: 1, dy: 0), now: t + 0.001)
        try localTCPPump(until: { f.sender.desktopFocusRemoteForTests }, "active handoff before bridge reset")
        let retired = f.token
        if subject != 1 { f.sender.observeLocalTCPBridgeForTests(.inactive(bridge), expected: bridge, now: ProcessInfo.processInfo.systemUptime) }
        if subject != 0 { f.receiver.observeLocalTCPBridgeForTests(.inactive(bridge), expected: bridge, now: ProcessInfo.processInfo.systemUptime) }
        try localTCPPump(until: { !f.sender.localTCPBridgeSuspendedForTests && !f.receiver.localTCPBridgeSuspendedForTests && f.sender.localTCPPhaseForTests == "local" && f.receiver.localTCPPhaseForTests == "local" }, "active reset handshake settles", tick: {
            f.sender.observeLocalTCPBridgeForTests(.active(bridge), expected: bridge, now: ProcessInfo.processInfo.systemUptime)
            f.receiver.observeLocalTCPBridgeForTests(.active(bridge), expected: bridge, now: ProcessInfo.processInfo.systemUptime)
        })
        try localTCPRequire(!f.sender.localTCPBridgeSuspendedForTests && !f.receiver.localTCPBridgeSuspendedForTests && f.sender.localTCPPhaseForTests == "local" && f.receiver.localTCPPhaseForTests == "local" && f.sender.localTCPTokenForTests == nil && f.receiver.localTCPTokenForTests == nil && f.sender.generation == generationA && f.receiver.generation == generationB, "active reset retires ownership on same session")
        let leaseCount = f.reverseProcessed
        f.receiver.refreshLocalTCPLeaseForTests()
        try localTCPPump(until: { f.reverseProcessed > leaseCount }, "fresh lease after active reset")
        f.point = CGPoint(x: 0, y: 400)
        let posts = f.input.totalPosts
        try f.send(f.packet(dx: 1, dy: 0, token: retired))
        try localTCPRequire(f.input.totalPosts == posts, "old active handoff never resumes after reset")
        print("PASS local TCP negotiated active bridge reset source receiver simultaneous subject=\(subject)")
    }
    let received = f.reverseProcessed
    f.receiver.refreshLocalTCPLeaseForTests()
    try localTCPPump(until: { f.reverseProcessed > received }, "lease before delayed input")
    f.sender.desktopPrepareEntryForTests(map: map, origin: CGPoint(x: -1200, y: 0))
    _ = f.sender.desktopEntryForTests(CGPoint(x: 600, y: 400), delta: CGVector(dx: 1, dy: 0), now: now + 0.03)
    _ = f.sender.desktopEntryForTests(CGPoint(x: 1199, y: 400), delta: CGVector(dx: 1, dy: 0), now: now + 0.04)
    try localTCPPump(until: { f.sender.desktopFocusRemoteForTests }, "fresh handoff after reset")
    f.point = f.receiver.desktopFocusPointForTests!
    let entered = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0)
    f.writerReleases.append(released)
    f.sender.holdLocalTCPWriterForTests(entered: entered, released: released)
    try localTCPRequire(entered.wait(timeout: .now() + 1) == .success, "writer latch entered")
    let posts = f.input.totalPosts, count = f.processed
    try localTCPRequire(f.sender.enqueue(try f.packet(dx: 10, dy: 0)), "genuine lease attached before delay")
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    released.signal()
    try localTCPPump(until: { f.processed > count }, "delayed valid-sequence frame actually received")
    try localTCPRequire(f.receiver.localTCPBridgeSuspendedForTests && f.input.totalPosts == posts && f.receiver.localTCPPhaseForTests == "local", "expired genuine lease quarantines without input")
    print("PASS local TCP negotiated delayed genuine input lease expires before HID posting")
    try f.finish()
    print("PASS local TCP negotiated lifecycle wire codecs map lease begin ready commit active HID return returnAck repeated fresh tokens")
}

private func runLocalTCPOutboundCancellation(sides: LocalTCPSides) throws {
    for stop in [false, true] {
        let f = try LocalTCPFixture(sides: sides, enrollment: false)
        defer { try? f.finish() }
        let entered = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0)
        f.writerReleases.append(released)
        f.sender.holdLocalTCPWriterForTests(entered: entered, released: released)
        try localTCPRequire(entered.wait(timeout: .now() + 1) == .success, "bounded writer latch entered")
        for _ in 0..<128 {
            try localTCPRequire(f.sender.enqueue(Wire(kind: "ping", session: f.connection.senderSession, sequence: 0)), "128 pending writes accepted")
        }
        try localTCPRequire(!f.sender.enqueue(Wire(kind: "ping", session: f.connection.senderSession, sequence: 0)), "129th pending write rejected")
        if stop { f.sender.stop() } else { f.senderContext.cancel(reason: "cancel held outbound jobs") }
        released.signal()
        var drained = false
        f.sender.drainLocalTCPWriterForTests { drained = true }
        try localTCPPump(until: { drained && f.result.done }, "writer drained and peer observed EOF")
        try localTCPRequire(f.processed == 0 && String(describing: f.result.error).contains("EOF") && f.input.plans.isEmpty && f.input.cg.isEmpty, "cancelled jobs emitted no authenticated frames")
        try f.finish()
        print("PASS local TCP bounded outbound 128 budget 129 rejected cancellation no frames peer EOF stop=\(stop)")
    }
}

private func runLocalTCPNegotiatedDenial(sides: LocalTCPSides) throws {
    enum Denial: String, CaseIterable { case permissionAtBegin, permissionAtCommit, focus, beginRevision, commitToken }
    for scenario in Denial.allCases {
        let f = try LocalTCPFixture(sides: sides, enrollment: false, mode: .negotiated)
        defer { try? f.finish() }
        let map = try f.negotiate()
        switch scenario {
        case .permissionAtBegin: f.input.permission = false
        case .permissionAtCommit:
            f.sender.localTCPOutgoingFrameForTests = { wire in if wire.kind == "commit" { f.input.permission = false }; return wire }
        case .focus: f.receiver.prepareReceiverInputTarget = { needed, completion in completion(needed() && false) }
        case .beginRevision:
            f.sender.localTCPOutgoingFrameForTests = { wire in var w=wire; if w.kind == "begin" { w.desktopMapRevision = map.revision + 1 }; return w }
        case .commitToken:
            f.sender.localTCPOutgoingFrameForTests = { wire in var w=wire; if w.kind == "commit" { w.token = UUID().uuidString }; return w }
        }
        f.propose(map: map)
        if scenario == .commitToken {
            try localTCPPump(until: { f.forwardKinds["commit", default: 0] == 1 }, "mismatched commit actually received")
            try localTCPRequire(f.receiver.localTCPPhaseForTests == "targetReady", "wrong commit cannot activate receiver")
        } else {
            try localTCPPump(until: { f.processed > 0 && f.sender.localTCPPhaseForTests == "local" }, "negotiated denial returns local")
            try localTCPRequire(f.receiver.localTCPPhaseForTests == "local", "receiver ownership local after denial")
        }
        try localTCPRequire(!f.sender.desktopFocusRemoteForTests && f.input.warps.isEmpty && f.input.plans.isEmpty && f.input.cg.isEmpty, "failed negotiation never posts or warps")
        try f.finish()
        print("PASS local TCP negotiated fail closed \(scenario.rawValue)")
    }
}

private extension LocalTCPFixture {
    func negotiate() throws -> ReceiverDesktop {
        receiver.consent(true)
        try localTCPPump(until: { self.sender.localTCPMapForTests != nil && self.reverseKinds["available", default: 0] > 0 && self.reverseKinds["inputLease", default: 0] > 0 }, "actual available map and lease received")
        return sender.localTCPMapForTests!
    }
    func propose(map: ReceiverDesktop) {
        sender.desktopPrepareEntryForTests(map: map, origin: CGPoint(x: -1200, y: 0))
        let now = ProcessInfo.processInfo.systemUptime
        _ = sender.desktopEntryForTests(CGPoint(x: 600, y: 400), delta: CGVector(dx: 1, dy: 0), now: now)
        _ = sender.desktopEntryForTests(CGPoint(x: 1199, y: 400), delta: CGVector(dx: 1, dy: 0), now: now + 0.001)
    }
    func enter(map: ReceiverDesktop) throws {
        let before = reverseProcessed
        receiver.refreshLocalTCPLeaseForTests()
        try localTCPPump(until: { self.reverseProcessed > before }, "fresh lease before handoff")
        propose(map: map)
        try localTCPPump(until: { self.sender.desktopFocusRemoteForTests }, "real handoff active")
        point = receiver.desktopFocusPointForTests!
    }
}

private func runLocalTCPRemainingRecovery(sides: LocalTCPSides) throws {
    let bridge = Bridge(name: "bridge0", index: 7, ip: "169.254.1.1")
    do {
        let f = try LocalTCPFixture(sides: sides, enrollment: false, mode: .negotiated)
        defer { try? f.finish() }
        let map = try f.negotiate()
        try f.enter(map: map)
        let oldLease = f.sender.localTCPLeaseForTests!
        let oldLeaseObserved = ProcessInfo.processInfo.systemUptime
        let oldToken = f.token, generationA = f.sender.generation, generationB = f.receiver.generation
        f.sender.observeLocalTCPBridgeForTests(.inactive(bridge), expected: bridge, now: ProcessInfo.processInfo.systemUptime)
        f.sender.observeLocalTCPBridgeForTests(.active(bridge), expected: bridge, now: ProcessInfo.processInfo.systemUptime)
        try localTCPPump(until: { f.forwardKinds["linkReset", default: 0] == 1 }, "staggered peer received linkReset")
        f.receiver.observeLocalTCPBridgeForTests(.inactive(bridge), expected: bridge, now: ProcessInfo.processInfo.systemUptime)
        let wrongReady = f.reverseKinds["linkReady", default: 0] + 1
        try localTCPRequire(f.receiver.control("linkReady", token: UUID().uuidString), "wrong ready sent on real stream")
        try localTCPPump(until: { f.reverseKinds["linkReady", default: 0] >= wrongReady }, "wrong ready processed")
        try localTCPRequire(f.sender.localTCPBridgeSuspendedForTests && f.receiver.localTCPBridgeSuspendedForTests, "wrong ready cannot resume either endpoint")
        try localTCPPump(until: { !f.sender.localTCPBridgeSuspendedForTests && !f.receiver.localTCPBridgeSuspendedForTests }, "staggered fresh proof handshake", tick: {
            f.sender.observeLocalTCPBridgeForTests(.active(bridge), expected: bridge, now: ProcessInfo.processInfo.systemUptime)
            f.receiver.observeLocalTCPBridgeForTests(.active(bridge), expected: bridge, now: ProcessInfo.processInfo.systemUptime)
        })
        try localTCPRequire(f.sender.generation == generationA && f.receiver.generation == generationB && f.sender.contextForTests === f.senderContext && f.receiver.contextForTests === f.context && f.sender.localTCPPhaseForTests == "local" && f.receiver.localTCPPhaseForTests == "local", "staggered reset keeps sockets and local ownership")
        try f.enter(map: map)
        try localTCPRequire(f.token != oldToken && f.sender.localTCPLeaseForTests != oldLease, "reset requires new token and lease")
        try f.send(f.packet(dx: 2, dy: 0), acceptedMotion: true)
        let posts = f.input.totalPosts
        try localTCPRequire(ProcessInfo.processInfo.systemUptime - oldLeaseObserved < 0.35, "old lease still within age window")
        f.sender.localTCPOutgoingFrameForTests = { wire in var w=wire; if w.kind == "event" { w.inputLease = oldLease }; return w }
        try f.send(f.packet(dx: 1, dy: 0))
        try localTCPRequire(f.result.error == nil && f.receiver.localTCPBridgeSuspendedForTests && f.input.totalPosts == posts, "old reset lease rejected at exact next sequence and current token before expiry")
        try f.finish()
        print("PASS local TCP staggered reset wrong ready blocked fresh handoff accepted old lease current sequence rejected before expiry")
    }
    for scenario in 0..<4 {
        let f = try LocalTCPFixture(sides: sides, enrollment: false, mode: .negotiated)
        defer { try? f.finish() }
        _ = try f.negotiate()
        let generation = f.sender.generation
        let now = ProcessInfo.processInfo.systemUptime
        if scenario == 3 {
            f.sender.observeLocalTCPBridgeForTests(.inactive(bridge), expected: bridge, now: now)
            f.sender.observeLocalTCPBridgeForTests(.active(bridge), expected: bridge, now: now + 2)
        } else {
            let mismatch = Bridge(name: scenario == 0 ? "bridge1" : "bridge0", index: scenario == 1 ? 8 : 7, ip: scenario == 2 ? "169.254.1.2" : "169.254.1.1")
            f.sender.observeLocalTCPBridgeForTests(.active(mismatch), expected: bridge, now: now)
        }
        try localTCPPump(until: { f.result.done && f.reverseResult.done }, "hard stop terminates both actual TCP workers")
        try localTCPRequire(f.senderContext.cancelled && f.sender.contextForTests == nil && f.sender.generation != generation && f.sender.localTCPPhaseForTests == "local" && f.input.plans.isEmpty && f.input.cg.isEmpty, "bridge identity/address/grace hard stop has no fallback")
        try f.finish()
        print("PASS local TCP bridge identity address or exact two-second grace hard stop scenario=\(scenario)")
    }
}

private func runLocalTCPOutboundReconnect(sides: LocalTCPSides) throws {
    let old = try LocalTCPFixture(sides: sides, enrollment: false)
    defer { try? old.finish() }
    let entered = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0)
    old.writerReleases.append(released)
    old.sender.holdLocalTCPWriterForTests(entered: entered, released: released)
    try localTCPRequire(entered.wait(timeout: .now() + 1) == .success, "old-session writer held")
    for _ in 0..<128 { try localTCPRequire(old.sender.enqueue(try old.packet()), "old context job accepted") }
    old.senderContext.cancel(reason: "replace cancelled outgoing context")
    let fresh = try LocalTCPFixture(sides: sides, enrollment: false)
    defer { try? fresh.finish() }
    old.sender.connectionForTests = fresh.connection.sender
    old.sender.contextForTests = fresh.senderContext
    old.sender.keyForTests = fresh.connection.outgoing
    old.sender.localTCPNextSequenceForTests = 1
    released.signal()
    var drained = false
    old.sender.drainLocalTCPWriterForTests { drained = true }
    try localTCPPump(until: { drained && old.result.done }, "old jobs drained and old peer EOF")
    try localTCPRequire(fresh.processed == 0 && fresh.input.plans.isEmpty && !fresh.senderContext.cancelled && String(describing: old.result.error).contains("EOF"), "old jobs cannot emit frames into replacement transport")
    try localTCPRequire(old.sender.enqueue(try fresh.packet()), "fresh session frame accepted by same Relay writer")
    try localTCPPump(until: { fresh.processed == 1 }, "replacement session exact first sequence received")
    try localTCPRequire(fresh.input.plans.count == 1 && fresh.result.error == nil, "fresh key and current session accepted after old jobs cancelled")
    try old.finish(); try fresh.finish()
    print("PASS local TCP previous-session queued jobs cannot leak replacement transport fresh key exact first sequence accepted")
}

private func runLocalTCPNativeInput() throws {
    guard let shiftDescriptor = modifierDescriptors[56] else { throw LocalTCPError.assertion("left Shift descriptor unavailable") }
    let leftShift = CGEventFlags(rawValue: shiftDescriptor.aggregate.rawValue | shiftDescriptor.sideBit)
    try localTCPRequire(modifierDown(56, flags: leftShift) == true && modifierDown(56, flags: .maskShift) == nil, "native fixture uses unambiguous left Shift flags")
    let native = try LocalTCPNativeWindow()
    var fixture: LocalTCPFixture?
    defer { try? fixture?.finish(); native.close() }
    guard native.inputAPI.native.permissionCheck() else { throw LocalTCPError.assertion("native HID permission unavailable before keyboard input") }
    let sides = LocalTCPSides(senderStore: LocalTCPMemoryStore(UUID().uuidString), receiverStore: LocalTCPMemoryStore(UUID().uuidString))
    let f = try LocalTCPFixture(sides: sides, enrollment: true, mode: .negotiated, inputAPIOverride: native.inputAPI)
    fixture = f
    let map = try f.negotiate()
    try f.enter(map: map)
    native.pumpEvents()
    func refreshNativeLease() throws {
        let before=f.reverseProcessed
        f.receiver.refreshLocalTCPLeaseForTests()
        try localTCPPump(until:{f.reverseProcessed>before},"native test fresh lease crossed real TCP")
    }
    try refreshNativeLease()
    let initialMotionCount = native.count(type: 5)
    try f.send(f.packet(type: 5, dx: 20, dy: 0), acceptedMotion: true)
    try native.waitFor(type: 5, count: initialMotionCount + 1)
    try localTCPRequire(f.receiver.authenticated && f.sender.desktopFocusRemoteForTests, "native HID motion succeeded before keyboard input")
    for (type, dx, flags): (UInt32, Double, CGEventFlags) in [
        (10, 0, []), (11, 0, []), (1, 0, []), (6, 10, []), (12, 0, leftShift),
        (6, 10, leftShift), (12, 0, []), (2, 0, []), (3, 0, []), (7, 10, []), (4, 0, []), (25, 0, []), (27, 10, []), (26, 0, [])] {
        native.pumpEvents()
        let eventCount = native.count(type: type)
        try refreshNativeLease()
        try f.send(f.packet(type: type, dx: dx, dy: 0, flags: flags), acceptedMotion: [5, 6, 7, 27].contains(type))
        do {try native.waitFor(type:type,count:eventCount+1)} catch {print("Native delivery timeout type=\(type) auth=\(f.receiver.authenticated) suspended=\(f.receiver.localTCPBridgeSuspendedForTests) phase=\(f.receiver.localTCPPhaseForTests)");try? native.verify();throw error}
    }
    try f.finish()
    let deadline = Date().addingTimeInterval(2)
    var verified = false
    while !verified && Date() < deadline {
        native.pumpEvents()
        do { try native.verify(); verified = true } catch { RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }
    }
    try native.verify()
    if let index = CommandLine.arguments.firstIndex(of: "--native-proof") {
        guard index + 1 < CommandLine.arguments.count, CommandLine.arguments[index + 1].hasPrefix("/") else { throw LocalTCPError.assertion("native proof requires absolute output path") }
        try native.saveProof(to: CommandLine.arguments[index + 1])
    }
    native.close()
    try native.verify()
    print("PASS local TCP owned native window actual negotiated unified HID keyboard buttons Shift 5/6/7/27 and restoration")
}

private func runLocalTCPLeaseKinds(sides: LocalTCPSides) throws {
    for kind in ["event", "dock", "appGesture", "begin", "commit"] {
        let f = try LocalTCPFixture(sides: sides, enrollment: false, mode: .negotiated)
        defer { try? f.finish() }
        let map = try f.negotiate()
        let invalidLease = UUID().uuidString
        f.sender.localTCPOutgoingFrameForTests = { wire in var w=wire; if w.kind == kind { w.inputLease = invalidLease }; return w }
        if kind == "begin" || kind == "commit" {
            f.propose(map: map)
        } else {
            try f.enter(map: map)
            var wire: Wire
            if kind == "event" { wire = try f.packet(dx: 1, dy: 0) }
            else if kind == "dock" {
                wire = Wire(kind: kind, session: f.connection.senderSession, sequence: 0, token: f.token, dock: DockGestureDescriptor(motion: 2, phase: 1, progress: 0, velocityX: 0, velocityY: 0), dockID: UUID().uuidString, desktopMapRevision: map.revision, desktopGlobalX: f.point.x, desktopGlobalY: f.point.y, desktopGestureTargetID: 11)
            } else {
                let event = CGEvent(source: nil)!
                event.type = CGEventType(rawValue: 29)!
                event.setIntegerValueField(CGEventField(rawValue: 110)!, value: 8)
                event.setIntegerValueField(CGEventField(rawValue: 132)!, value: 1)
                event.setDoubleValueField(CGEventField(rawValue: 113)!, value: 0)
                wire = Wire(kind: kind, session: f.connection.senderSession, sequence: 0, raw: 29, data: event.data! as Data, x: 0.1, y: 0.4, token: f.token, appGesture: NativeGestureDescriptor(kind: .pinch, phase: .began), appGestureID: UUID().uuidString, appGestureCodec: 1)
                try localTCPRequire(AppGestureCodec.decode(wire) != nil, "valid synthetic app gesture before lease mutation")
            }
            try localTCPRequire(f.sender.enqueue(wire), "lease-kind frame enqueued")
        }
        try localTCPPump(until: { f.forwardKinds[kind, default: 0] > 0 || f.result.done }, "lease-kind actual receive marker")
        try localTCPRequire(f.result.error == nil && f.forwardKinds[kind, default: 0] > 0 && f.receiver.localTCPBridgeSuspendedForTests && f.receiver.localTCPPhaseForTests == "local" && f.input.plans.isEmpty && f.input.cg.isEmpty, "valid current-sequence lease-kind envelope quarantined before native input")
        try f.finish()
        print("PASS local TCP freshness lease rejects current-sequence \(kind) before native input")
    }
}

private func runLocalTCPReplayReleaseEOF(sides:LocalTCPSides) throws {
    let f=try LocalTCPFixture(sides:sides,enrollment:false)
    defer {try? f.finish()}
    try f.send(f.packet(type:10))
    let before=f.input.plans.count
    try localTCPRequire(f.input.plans.last?.type==10,"admitted keydown reached actual record-only HID receiver")
    let release=try f.packet(type:11)
    try localTCPRequire(f.sender.stageReplayReleaseForLocalTCPTests(map:f.map,point:f.point,token:f.token,release:release),"matching keyup source-owned in bounded replay capture stage")
    f.sender.forceLocal()
    try localTCPRequire(f.senderContext.cancelled,"forceLocal cancels replay context before discarding staged up")
    try localTCPPump(until:{f.result.done},"receiver observed replay cancellation EOF")
    f.receiver.stop(reason:"local TCP EOF cleanup")
    let cleanup=Array(f.input.plans.dropFirst(before))
    try localTCPRequire(cleanup.filter{$0.type==11 && $0.keyCode==0}.count==1,"actual EOF stop cleanup releases admitted key exactly once after staged up discard")
    let posts=f.input.totalPosts
    f.receiver.stop()
    try localTCPRequire(f.input.totalPosts==posts,"repeated receiver EOF cleanup is idempotent")
    print("PASS local TCP actual receiver EOF cleanup admitted-down/staged-up; captured up discarded only after context cancellation")
}
