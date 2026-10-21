import Foundation
import CryptoKit
import Darwin

// Headless integration only: no Relay, AppKit initialization, network discovery,
// capture, HID queries or event posting. All bytes travel over AF_UNIX sockets.
private enum PINRelayTestError: Error { case assertion(String), declined, timeout }
private func pinRelayRequire(_ ok: Bool, _ message: String) throws {
    if !ok { throw PINRelayTestError.assertion(message) }
}
private final class PINRelayResults: @unchecked Sendable {
    struct Endpoint {
        var completed = false
        var rootReturned = false
        var authenticated = false
        var active = false
        var tag: Data?
        var failed = false
    }
    private let lock = NSLock()
    private var endpoints = [Endpoint(), Endpoint()]
    private var approvals = 0
    func approval() { lock.lock(); approvals += 1; lock.unlock() }
    func update(_ side: Int, _ body: (inout Endpoint) -> Void) {
        lock.lock(); defer { lock.unlock() }; body(&endpoints[side])
    }
    func read() -> ([Endpoint], Int) {
        lock.lock(); defer { lock.unlock() }; return (endpoints, approvals)
    }
}
private func pinRelaySockets() throws -> (OwnedSocket, OwnedSocket) {
    var fds: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
        throw PINRelayTestError.assertion("UNIX socketpair creation")
    }
    let a = OwnedSocket(fds[0]), b = OwnedSocket(fds[1])
    for fd in fds {
        var yes: Int32 = 1
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw PINRelayTestError.assertion("UNIX socket deadline configuration")
        }
    }
    return (a, b)
}
private func pinRelayPrelude(_ scope: String) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(["v":"4", "kind":"pin-intro", "role":"sender", "pairingSession":scope])
}

@discardableResult
private func pinRelayRun(receiverPIN: String = "1234", decline: Bool = false,
                         injectedPrelude: Data? = nil, expectSuccess: Bool,
                         expectedApprovals: Int) throws -> String {
    let (a, b) = try pinRelaySockets()
    defer { a.interrupt(); b.interrupt() }
    let senderID = UUID().uuidString, receiverID = UUID().uuidString
    try pinRelayRequire(senderID != receiverID, "independent endpoint identities")
    let results = PINRelayResults(), group = DispatchGroup()
    for sender in [true, false] {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let socket = sender ? a : b, side = sender ? 0 : 1
            defer { socket.interrupt(); group.leave() }
            do {
                let local = sender ? senderID : receiverID
                let scope: String
                if sender, let prelude = injectedPrelude {
                    try sendFrame(socket.fd, prelude)
                    scope = senderID
                } else {
                    scope = try agreePairingScope(sendMode: sender, localSession: local,
                        send: { try sendFrame(socket.fd, $0) }, receive: { try readFrame(socket.fd) })
                }
                if injectedPrelude == nil {
                    try pinRelayRequire(scope == senderID, "sender prelude establishes common scope")
                }
                let io = PINPairingTransport(send: { try sendFrame(socket.fd, $0) },
                    receive: { try readFrame(socket.fd) }, cancelled: { false })
                let root = try performPINPairing(isSender: sender, senderPIN: sender ? "1234" : nil,
                    sessionID: scope, localName: sender ? "Fixture sender" : "Fixture receiver",
                    transport: io, receiverApproval: { request in
                        results.approval()
                        try pinRelayRequire(!sender && request.sessionID == senderID,
                                            "approval bound to agreed sender scope")
                        if decline { throw PINRelayTestError.declined }
                        return receiverPIN
                    })
                results.update(side) {
                    $0.rootReturned = true
                    $0.tag = Data(HMAC<SHA256>.authenticationCode(
                        for: Data("headless integration root agreement".utf8), using: root))
                }
                try sendFrame(socket.fd, seal(Wire(kind: sender ? "sender-hello-v5" : "receiver-hello-v5",
                    session: local, sequence: 0, os: 15), root))
                var hello = try unseal(readFrame(socket.fd), root)
                try pinRelayRequire(hello.kind == (sender ? "receiver-hello-v5" : "sender-hello-v5") &&
                    hello.session == (sender ? receiverID : senderID), "encrypted hello role and independent identity")
                if !sender { try pinRelayRequire(hello.session == scope, "sender hello scope binding") }
                hello.kind = "hello"
                var helloValidator = Validator(); try helloValidator.accept(hello)
                let forward = connectionKey(root, sender: senderID, receiver: receiverID)
                let reverse = connectionKey(root, sender: senderID, receiver: receiverID, reverse: true)
                let probe = Wire(kind: "ping", session: senderID, sequence: 1)
                let sealed = try seal(probe, forward)
                var wrongDirectionRejected = false
                do { _ = try unseal(sealed, reverse) } catch { wrongDirectionRejected = true }
                try pinRelayRequire(wrongDirectionRejected, "directional AEAD key separation")
                let outgoing = sender ? forward : reverse, incoming = sender ? reverse : forward
                var validator = PeerValidator(senderPeer: !sender, session: hello.session)
                func send(_ w: Wire) throws { try sendFrame(socket.fd, seal(w, outgoing)) }
                func receive(_ kind: String) throws -> Wire {
                    let w = try unseal(readFrame(socket.fd), incoming)
                    try validator.accept(w)
                    try pinRelayRequire(w.kind == kind, "ordered control transaction")
                    return w
                }
                results.update(side) { $0.authenticated = true }
                if sender {
                    let available = try receive("available")
                    try pinRelayRequire(available.width == 1, "explicit receiver consent advertised")
                    let token = UUID().uuidString
                    try send(Wire(kind: "begin", session: local, sequence: 1, y: 0.5,
                        token: token, edge: .right, screenWidth: 1920, screenHeight: 1080, layoutY: 0))
                    let ready = try receive("ready")
                    try pinRelayRequire(ready.token == token, "ready transfer binding")
                    try send(Wire(kind: "commit", session: local, sequence: 2, token: token))
                    let active = try receive("active")
                    try pinRelayRequire(active.token == token, "active transfer binding")
                    // A final authenticated acknowledgement keeps both endpoints alive
                    // until active was decrypted and validated, without emitting input.
                    try send(Wire(kind: "ping", session: local, sequence: 3))
                } else {
                    try send(Wire(kind: "available", session: local, sequence: 1,
                        width: 1, screenWidth: 2560, screenHeight: 1440))
                    let begin = try receive("begin")
                    try send(Wire(kind: "ready", session: local, sequence: 2,
                        token: begin.token, width: 2560, height: 1440))
                    let commit = try receive("commit")
                    try pinRelayRequire(commit.token == begin.token, "commit transfer binding")
                    try send(Wire(kind: "active", session: local, sequence: 3, token: begin.token))
                    _ = try receive("ping")
                }
                results.update(side) { $0.active = true; $0.completed = true }
            } catch {
                // Intentionally do not report error payloads, PINs, keys or frames.
                results.update(side) { $0.failed = true; $0.completed = true }
            }
        }
    }
    guard group.wait(timeout: .now() + 5) == .success else {
        a.interrupt(); b.interrupt()
        _ = group.wait(timeout: .now() + 0.5)
        throw PINRelayTestError.timeout
    }
    let (states, approvals) = results.read()
    try pinRelayRequire(approvals == expectedApprovals, "expected explicit approval count")
    try pinRelayRequire(states.allSatisfy { $0.completed }, "both bounded workers completed")
    if expectSuccess {
        try pinRelayRequire(states.allSatisfy { !$0.failed && $0.rootReturned && $0.authenticated && $0.active },
                            "paired duplex encrypted control transaction")
        try pinRelayRequire(states[0].tag != nil && states[0].tag == states[1].tag, "root HMAC agreement")
    } else {
        try pinRelayRequire(states.allSatisfy { $0.failed && !$0.rootReturned && !$0.authenticated && !$0.active },
                            "failure closed before handshake key or control authorization")
    }
    return senderID
}

/// Called by the parent's CLI self-test branch before any application initialization.
func runPINRelayIntegrationTests() throws {
    let consumedScope = try pinRelayRun(expectSuccess: true, expectedApprovals: 1)
    try pinRelayRun(receiverPIN: "9876", expectSuccess: false, expectedApprovals: 1)
    try pinRelayRun(decline: true, expectSuccess: false, expectedApprovals: 1)
    try pinRelayRun(injectedPrelude: pinRelayPrelude(consumedScope), expectSuccess: false, expectedApprovals: 0)
    let malformed: [Data] = [
        Data("{}".utf8), Data(repeating: 65, count: 257),
        try pinRelayPrelude("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"),
        Data("{\"v\":4,\"kind\":\"pin-intro\"}".utf8),
        Data(" ".utf8) + (try pinRelayPrelude(UUID().uuidString))
    ]
    for bytes in malformed {
        try pinRelayRun(injectedPrelude: bytes, expectSuccess: false, expectedApprovals: 0)
    }
    // Validator rejection must not consume a sequence number.
    let session = UUID().uuidString, token = UUID().uuidString
    var validator = PeerValidator(senderPeer: true, session: session)
    var rejected = false
    do { try validator.accept(Wire(kind: "active", session: session, sequence: 1, token: token)) }
    catch { rejected = true }
    try pinRelayRequire(rejected && validator.next == 1, "reject opposite role without advancing")
    try validator.accept(Wire(kind: "ping", session: session, sequence: 1))
    rejected = false
    do { try validator.accept(Wire(kind: "ping", session: session, sequence: 1)) }
    catch { rejected = true }
    try pinRelayRequire(rejected && validator.next == 2, "reject replay without advancing")
    let (a, b) = try pinRelaySockets()
    let context = SessionContext(a)
    try pinRelayRequire(context.add(b), "track both local sockets")
    context.cancel(reason: "first fixture terminal")
    context.cancel(reason: "secondary fixture terminal")
    context.cancel()
    try pinRelayRequire(context.cancelled && context.terminalReason == "first fixture terminal",
                        "first terminal reason retained across repeated cancellation")
    print("PASS headless PIN relay integration: duplex control, fail-closed pairing, prelude replay, cancellation")
}
