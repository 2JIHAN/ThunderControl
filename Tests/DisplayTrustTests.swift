import Foundation
import CryptoKit

/// Real TrustedHandshake over bounded memory channels. Never uses Keychain,
/// UserDefaults, sockets, PIN approval, display capture, or input injection.
func runDisplayTrustTests() -> Int {
    enum TestError: Error { case denied, timeout }
    final class MemoryStore: TrustedPairingStorage, @unchecked Sendable {
        let id: String, lock = NSLock()
        private var keys: [String: Data] = [:]
        private var readHistory: [Bool] = []
        private var writes = 0
        var failingRole: Bool?
        var failIdentity = false
        init(_ id: String) { self.id = id }
        private func index(_ role: Bool, _ peer: String) -> String { (role ? "s:" : "r:") + peer }
        func identity() throws -> String { if failIdentity { throw TestError.denied }; return id }
        func key(isSender: Bool, peerID: String) throws -> SymmetricKey? {
            lock.lock(); defer { lock.unlock() }
            readHistory.append(isSender)
            if failingRole == isSender { throw TestError.denied }
            return keys[index(isSender, peerID)].map { SymmetricKey(data: $0) }
        }
        func save(_ key: SymmetricKey, isSender: Bool, peerID: String) throws {
            lock.lock(); defer { lock.unlock() }; writes += 1
            keys[index(isSender, peerID)] = key.withUnsafeBytes { Data($0) }
        }
        func seed(_ value: UInt8, role: Bool, peer: String) {
            lock.lock(); defer { lock.unlock() }; keys[index(role, peer)] = Data(repeating: value, count: 32)
        }
        var reads: [Bool] { lock.lock(); defer { lock.unlock() }; return readHistory }
        var writeCount: Int { lock.lock(); defer { lock.unlock() }; return writes }
    }
    final class Channel: @unchecked Sendable {
        let condition = NSCondition()
        var messages: [Data] = []
        func send(_ data: Data) throws {
            condition.lock(); defer { condition.unlock() }
            guard data.count <= 4096, messages.count < 8 else { throw TestError.denied }
            messages.append(data); condition.signal()
        }
        func receive() throws -> Data {
            condition.lock(); defer { condition.unlock() }
            let limit = Date().addingTimeInterval(0.4)
            while messages.isEmpty { guard condition.wait(until: limit) else { throw TestError.timeout } }
            return messages.removeFirst()
        }
    }
    final class Results: @unchecked Sendable {
        let lock = NSLock()
        var results: [Bool: Result<Data, Error>] = [:]
        var approved = 0
        var proven: [Bool: (String, String)] = [:]
        var enrolledPrelude = false
        func finish(_ result: Result<Data, Error>, side: Bool) { lock.lock(); defer { lock.unlock() }; results[side] = result }
        func approval() { lock.lock(); defer { lock.unlock() }; approved += 1 }
        func identity(_ local: String, _ peer: String, side: Bool) { lock.lock(); defer { lock.unlock() }; proven[side] = (local, peer) }
        func capture(_ data: Data) {
            guard let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let kind = fields["kind"] as? String else { return }
            if !["autoHello", "autoOffer", "autoAuthenticate"].contains(kind) {
                lock.lock(); enrolledPrelude = true; lock.unlock()
            }
        }
        var succeeded: Bool {
            lock.lock(); defer { lock.unlock() }
            guard case .success(let a)? = results[true], case .success(let b)? = results[false] else { return false }
            return a == b && a.count == 32
        }
        var failedBoth: Bool {
            lock.lock(); defer { lock.unlock() }
            guard case .failure? = results[true], case .failure? = results[false] else { return false }; return true
        }
        var noEnrollment: Bool { lock.lock(); defer { lock.unlock() }; return approved == 0 && !enrolledPrelude }
        var noIdentity: Bool { lock.lock(); defer { lock.unlock() }; return proven.isEmpty }
        var senderKey: Data? { lock.lock(); defer { lock.unlock() }; if case .success(let value)? = results[true] { return value }; return nil }
        func identitiesMatch(_ a: String, _ b: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return proven[true]?.0 == a && proven[true]?.1 == b && proven[false]?.0 == b && proven[false]?.1 == a
        }
    }
    let miniID = "11111111-1111-4111-8111-111111111111"
    let bookID = "22222222-2222-4222-8222-222222222222"
    let strangerID = "44444444-4444-4444-8444-444444444444"
    let sessionID = "33333333-3333-4333-8333-333333333333"
    func pair() -> (MemoryStore, MemoryStore) { (MemoryStore(miniID), MemoryStore(bookID)) }
    func keyBytes(_ value: SymmetricKey?) -> Data? { value?.withUnsafeBytes { Data($0) } }
    func run(_ stores: (MemoryStore, MemoryStore), round: UInt8 = 1) -> Results {
        let toMini = Channel(), toBook = Channel(), output = Results(), group = DispatchGroup()
        for source in [true, false] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                let io = PINPairingTransport(send: { data in
                    output.capture(data); try (source ? toBook : toMini).send(data)
                }, receive: { try (source ? toMini : toBook).receive() }, cancelled: { false })
                let result = Result {
                    try performTrustedPairing(isSender: source, senderPIN: nil, sessionID: sessionID,
                        localName: "Display fixture", transport: io,
                        store: DisplayTrustStorage(base: source ? stores.0 : stores.1),
                        nonce: { Data(repeating: source ? round : round &+ 100, count: 32) },
                        allowNewTrust: false,
                        authenticatedIdentity: { local, peer in output.identity(local, peer, side: source) },
                        receiverApproval: { _ in output.approval(); throw TestError.denied })
                        .withUnsafeBytes { Data($0) }
                }
                output.finish(result, side: source)
            }
        }
        _ = group.wait(timeout: .now() + 3)
        return output
    }
    var failures = 0, checks = 0
    func check(_ valid: Bool) { checks += 1; if !valid { failures += 1 } }
    func reject(_ action: () throws -> Void) { do { try action(); check(false) } catch { check(true) } }

    for role in [false, true] {
        let preferred = MemoryStore(miniID)
        preferred.seed(17, role: !role, peer: bookID); preferred.seed(29, role: role, peer: bookID)
        let adapter = DisplayTrustStorage(base: preferred)
        do {
            check(try adapter.identity() == miniID)
            check(try keyBytes(adapter.key(isSender: role, peerID: bookID)) == Data(repeating: 17, count: 32))
            check(preferred.reads == [!role])
        } catch { check(false) }
        reject { try adapter.save(SymmetricKey(size: .bits256), isSender: role, peerID: bookID) }
        check(preferred.writeCount == 0)
        let fallback = MemoryStore(miniID); fallback.seed(29, role: role, peer: bookID)
        do { check(try keyBytes(DisplayTrustStorage(base: fallback).key(isSender: role, peerID: bookID)) == Data(repeating: 29, count: 32)) } catch { check(false) }
        check(fallback.reads == [!role, role])
        let denied = MemoryStore(miniID); denied.failingRole = !role; denied.seed(29, role: role, peer: bookID)
        reject { _ = try DisplayTrustStorage(base: denied).key(isSender: role, peerID: bookID) }
        check(denied.reads == [!role]); check(denied.writeCount == 0)
        let fallbackDenied = MemoryStore(miniID); fallbackDenied.failingRole = role
        reject { _ = try DisplayTrustStorage(base: fallbackDenied).key(isSender: role, peerID: bookID) }
        check(fallbackDenied.reads == [!role, role])
        do { check(try adapter.key(isSender: role, peerID: strangerID) == nil) } catch { check(false) }
    }
    let badIdentity = MemoryStore(miniID); badIdentity.failIdentity = true
    reject { _ = try DisplayTrustStorage(base: badIdentity).identity() }
    check(badIdentity.reads.isEmpty)

    // Natural keyboard direction: mini is input receiver, MacBook is input sender.
    let natural = pair(); natural.0.seed(71, role: false, peer: bookID); natural.1.seed(71, role: true, peer: miniID)
    let first = run(natural), fresh = run(natural, round: 2)
    check(first.succeeded); check(first.identitiesMatch(miniID, bookID)); check(first.noEnrollment)
    check(fresh.succeeded); check(first.senderKey != fresh.senderKey)
    check(natural.0.reads == [false, false] && natural.1.reads == [true, true])
    check(natural.0.writeCount == 0 && natural.1.writeCount == 0)

    // Legacy reverse input pairing remains usable only when preferred is absent.
    let legacy = pair(); legacy.0.seed(81, role: true, peer: bookID); legacy.1.seed(81, role: false, peer: miniID)
    let legacyResult = run(legacy)
    check(legacyResult.succeeded); check(legacyResult.identitiesMatch(miniID, bookID)); check(legacyResult.noEnrollment)
    check(legacy.0.reads == [false, true] && legacy.1.reads == [true, false])

    // When both keys exist, the natural direction wins on both endpoints.
    let both = pair()
    both.0.seed(91, role: false, peer: bookID); both.1.seed(91, role: true, peer: miniID)
    both.0.seed(92, role: true, peer: bookID); both.1.seed(93, role: false, peer: miniID)
    let bothResult = run(both)
    check(bothResult.succeeded); check(bothResult.noEnrollment)
    check(both.0.reads == [false] && both.1.reads == [true])

    let unknown = pair(), unknownResult = run(unknown)
    check(unknownResult.failedBoth); check(unknownResult.noIdentity); check(unknownResult.noEnrollment)
    let missing = pair(); missing.0.seed(71, role: false, peer: bookID)
    let missingResult = run(missing)
    check(missingResult.failedBoth); check(missingResult.noIdentity); check(missingResult.noEnrollment)
    let unequal = pair(); unequal.0.seed(71, role: false, peer: bookID); unequal.1.seed(72, role: true, peer: miniID)
    // Valid fallback pair must NOT be tried after preferred proof mismatch.
    unequal.0.seed(81, role: true, peer: bookID); unequal.1.seed(81, role: false, peer: miniID)
    let unequalResult = run(unequal)
    check(unequalResult.failedBoth); check(unequalResult.noIdentity); check(unequalResult.noEnrollment)
    check(unequal.0.reads == [false] && unequal.1.reads == [true])
    let deniedPair = pair(); deniedPair.0.failingRole = false
    deniedPair.0.seed(81, role: true, peer: bookID); deniedPair.1.seed(81, role: false, peer: miniID)
    let deniedResult = run(deniedPair)
    check(deniedResult.failedBoth); check(deniedResult.noIdentity); check(deniedResult.noEnrollment)
    check(deniedPair.0.reads == [false])
    for stores in [legacy, both, unknown, missing, unequal, deniedPair] {
        check(stores.0.writeCount == 0 && stores.1.writeCount == 0)
    }
    print("Display trust adapter: \(checks) checks, \(failures) failures; real two-sided in-memory proof, no Keychain/network/enrollment")
    return failures
}
