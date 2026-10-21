import Foundation
import CryptoKit
import Security
import LocalAuthentication

/// Hardware-free tests: isolated memory stores, bounded queues, real existing SPAKE2.
/// This entry point never invokes Keychain or UserDefaults and never prints credentials.
func runTrustedPairingTests() -> Int {
    enum Failure: Error { case timeout, denied }
    final class MemoryStore: TrustedPairingStorage {
        let id: String
        let lock = NSLock()
        var keys: [String: Data] = [:]
        var writes = 0
        init(_ id: String) { self.id = id }
        func identity() throws -> String { id }
        func index(_ sender: Bool, _ peer: String) -> String { (sender ? "sender:" : "receiver:") + peer }
        func key(isSender: Bool, peerID: String) throws -> SymmetricKey? {
            lock.lock(); defer { lock.unlock() }
            return keys[index(isSender, peerID)].map { SymmetricKey(data: $0) }
        }
        func save(_ key: SymmetricKey, isSender: Bool, peerID: String) throws {
            lock.lock(); defer { lock.unlock() }
            let i = index(isSender, peerID)
            guard keys[i] == nil else { throw Failure.denied }
            keys[i] = key.withUnsafeBytes { Data($0) }; writes += 1
        }
        func seed(_ key: Data, sender: Bool, peer: String) {
            lock.lock(); defer { lock.unlock() }; keys[index(sender, peer)] = key
        }
    }
    final class Channel {
        let condition = NSCondition()
        var messages: [Data] = []
        func put(_ data: Data) { condition.lock(); messages.append(data); condition.signal(); condition.unlock() }
        func get() throws -> Data {
            condition.lock(); defer { condition.unlock() }
            let limit = Date().addingTimeInterval(0.25)
            while messages.isEmpty { guard condition.wait(until: limit) else { throw Failure.timeout } }
            return messages.removeFirst()
        }
    }
    final class Box {
        let lock = NSLock()
        var results: [Bool: Result<Data, Error>] = [:]
        var captured: [Bool: [Data]] = [:]
        var approvals = 0
        var identities: [Bool: [(String, String)]] = [:]
        var identityStored: [Bool: [Bool]] = [:]
        func identity(_ local: String, _ peer: String, side: Bool, stored: Bool) {
            lock.lock(); defer { lock.unlock() }
            identities[side, default: []].append((local, peer))
            identityStored[side, default: []].append(stored)
        }
        var noIdentities: Bool {
            lock.lock(); defer { lock.unlock() }; return identities.isEmpty
        }
        func identityCount(side: Bool) -> Int {
            lock.lock(); defer { lock.unlock() }; return identities[side]?.count ?? 0
        }
        func correctIdentities(sender: String, receiver: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard let a = identities[true], let b = identities[false], a.count == 1, b.count == 1 else { return false }
            return a[0].0 == sender && a[0].1 == receiver && b[0].0 == receiver && b[0].1 == sender
                && identityStored[true] == [true] && identityStored[false] == [true]
        }
        func capture(_ data: Data, side: Bool) { lock.lock(); defer { lock.unlock() }; captured[side, default: []].append(data) }
        func finish(_ result: Result<Data, Error>, side: Bool) { lock.lock(); defer { lock.unlock() }; results[side] = result }
        func approval() { lock.lock(); defer { lock.unlock() }; approvals += 1 }
        var matched: Bool {
            guard case .success(let a)? = results[true], case .success(let b)? = results[false] else { return false }
            return a == b && a.count == 32
        }
        var failedBoth: Bool {
            guard case .failure? = results[true], case .failure? = results[false] else { return false }
            return true
        }
        var senderKey: Data? { if case .success(let data)? = results[true] { return data }; return nil }
    }
    let senderID = "11111111-1111-4111-8111-111111111111"
    let receiverID = "22222222-2222-4222-8222-222222222222"
    let session = "33333333-3333-4333-8333-333333333333"
    func stores() -> (MemoryStore, MemoryStore) { (MemoryStore(senderID), MemoryStore(receiverID)) }
    func seed(_ pair: (MemoryStore, MemoryStore), wrong: Bool = false) {
        pair.0.seed(Data(repeating: 91, count: 32), sender: true, peer: receiverID)
        pair.1.seed(Data(repeating: wrong ? 92 : 91, count: 32), sender: false, peer: senderID)
    }
    func mutate(_ data: Data, _ edit: (inout [String: Any]) -> Void) -> Data {
        guard var fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return data }
        edit(&fields)
        return (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? data
    }
    func kind(_ data: Data) -> String? {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["kind"] as? String
    }
    func run(_ pair: (MemoryStore, MemoryStore), round: UInt8 = 1, pin: String? = "0427",
             deny: Bool = false, wrongPIN: Bool = false, cancelAt: Int? = nil,
             allowNewTrust: Bool = true,
             filter: @escaping (Data, Bool) -> Data = { d, _ in d }) -> Box {
        let a = Channel(), b = Channel(), box = Box(), group = DispatchGroup()
        for sender in [true, false] {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                var boundaries = 0
                let io = PINPairingTransport(send: { data in
                    box.capture(data, side: sender)
                    (sender ? b : a).put(filter(data, sender))
                }, receive: { try (sender ? a : b).get() }, cancelled: {
                    boundaries += 1
                    return sender && cancelAt.map { boundaries >= $0 } == true
                })
                let result = Result {
                    try performTrustedPairing(isSender: sender, senderPIN: sender ? pin : nil,
                        sessionID: session, localName: sender ? "Sender" : "Receiver", transport: io,
                        store: sender ? pair.0 : pair.1,
                        nonce: { Data(repeating: sender ? round : round &+ 100, count: 32) },
                        allowNewTrust: allowNewTrust,
                        authenticatedIdentity: { local, peer in
                            let store = sender ? pair.0 : pair.1
                            let stored = (try? store.key(isSender: sender, peerID: peer)) != nil
                            box.identity(local, peer, side: sender, stored: stored)
                        },
                        receiverApproval: { _ in
                            box.approval(); if deny { throw Failure.denied }
                            return wrongPIN ? "5427" : "0427"
                        }).withUnsafeBytes { Data($0) }
                }
                box.finish(result, side: sender)
            }
        }
        if group.wait(timeout: .now() + 3) != .success { return Box() }
        return box
    }
    var failures = 0
    func check(_ valid: Bool) { if !valid { failures += 1 } }

    // First use requires explicit receiver approval AND a correct, fresh supplied PIN.
    let first = stores(), enrolled = run(first)
    check(enrolled.correctIdentities(sender: senderID, receiver: receiverID))
    check(enrolled.matched && enrolled.approvals == 1 && first.0.writes == 1 && first.1.writes == 1)
    check((try? first.0.key(isSender: true, peerID: receiverID))?.withUnsafeBytes { Data($0) }
          == (try? first.1.key(isSender: false, peerID: senderID))?.withUnsafeBytes { Data($0) })
    check((try? first.0.key(isSender: false, peerID: receiverID)) == nil) // role isolation
    let reconnect = run(first, round: 2, pin: nil, deny: true, allowNewTrust: false)
    let next = run(first, round: 3, pin: nil, deny: true)
    check(reconnect.matched && next.matched && reconnect.approvals == 0 && next.approvals == 0)
    check(reconnect.correctIdentities(sender: senderID, receiver: receiverID))
    check(next.correctIdentities(sender: senderID, receiver: receiverID))
    check(reconnect.senderKey != next.senderKey && reconnect.senderKey != enrolled.senderKey)
    check(first.0.writes == 1 && first.1.writes == 1)
    let autoUnknown = stores()
    let autoRejected = run(autoUnknown, allowNewTrust: false)
    check(autoRejected.noIdentities)
    check(autoRejected.failedBoth && autoRejected.approvals == 0 && autoUnknown.0.writes == 0 && autoUnknown.1.writes == 0)
    check(autoRejected.captured.values.flatMap { $0 }.allSatisfy { kind($0) != "hello" })
    let missingPIN = stores(), noPIN = run(missingPIN, pin: nil)
    check(noPIN.noIdentities)
    check(noPIN.failedBoth && noPIN.approvals == 0 && missingPIN.0.writes == 0 && missingPIN.1.writes == 0)
    let declined = stores(), declinedResult = run(declined, deny: true)
    check(declinedResult.noIdentities)
    check(declinedResult.failedBoth && declinedResult.approvals == 1 && declined.0.writes == 0 && declined.1.writes == 0)
    let wrongPINStores = stores()
    let wrongPINResult = run(wrongPINStores, wrongPIN: true)
    check(wrongPINResult.noIdentities)
    check(wrongPINResult.failedBoth && wrongPINStores.0.writes == 0 && wrongPINStores.1.writes == 0)

    // Partial state must not fall back to approval or PIN.
    let partial = stores(); partial.0.seed(Data(repeating: 91, count: 32), sender: true, peer: receiverID)
    let downgrade = run(partial)
    check(downgrade.noIdentities)
    check(downgrade.failedBoth && downgrade.approvals == 0 && partial.0.writes == 0 && partial.1.writes == 0)
    let wrongKeys = stores(); seed(wrongKeys, wrong: true)
    let wrongResult = run(wrongKeys)
    check(wrongResult.noIdentities)
    check(wrongResult.failedBoth && wrongResult.approvals == 0)

    // Valid UUID hellos and offers alone are never authenticated metadata.
    // Both forged MACs fail, so neither side may expose its accepted hello IDs.
    let forgedMACStores = stores(); seed(forgedMACStores)
    let forgedMAC = run(forgedMACStores, filter: { d, _ in
        kind(d) == "autoAuthenticate" ? mutate(d) {
            $0["payload"] = Data(repeating: 0, count: 32).base64EncodedString()
        } : d
    })
    check(forgedMAC.failedBoth && forgedMAC.noIdentities)
    check(forgedMAC.captured.values.allSatisfy { messages in
        messages.contains(where: { kind($0) == "autoHello" })
            && messages.contains(where: { kind($0) == "autoAuthenticate" })
    } && forgedMAC.captured.count == 2)

    // Entire prelude is bound to the SPAKE result before either stable identity can persist.
    let changedIdentity = stores()
    let tampered = run(changedIdentity, filter: { data, sender in
        sender && kind(data) == "autoHello" ? mutate(data) { $0["deviceID"] = "44444444-4444-4444-8444-444444444444" } : data
    })
    check(tampered.noIdentities)
    check(tampered.failedBoth && changedIdentity.0.writes == 0 && changedIdentity.1.writes == 0)

    let malformed: [(Data) -> Data] = [
        { mutate($0) { $0["role"] = "receiver" } },
        { mutate($0) { $0["deviceID"] = senderID.lowercased() + "x" } },
        { mutate($0) { $0["nonce"] = "not-base64" } },
        { mutate($0) { $0["nonce"] = Data(repeating: 101, count: 32).base64EncodedString() } }, // reflection nonce
        { mutate($0) { $0["session"] = receiverID } },
        { mutate($0) { $0["v"] = 2 } },
        { mutate($0) { $0["extra"] = "rejected" } },
        { Data([32]) + $0 },
        { data in var d = data; d.removeLast(); d.append(Data(",\"v\":1}".utf8)); return d },
        { _ in Data(repeating: 65, count: 4097) }
    ]
    for change in malformed {
        let pair = stores()
        let result = run(pair, filter: { d, sender in sender && kind(d) == "autoHello" ? change(d) : d })
        check(result.noIdentities)
        check(result.failedBoth && result.approvals == 0 && pair.0.writes == 0 && pair.1.writes == 0)
    }
    // Forged boolean or one-sided offer stripping cannot trigger enrollment.
    let booleanStores = stores(); seed(booleanStores)
    let booleanResult = run(booleanStores, filter: { d, _ in
        kind(d) == "autoOffer" ? mutate(d) { $0["trusted"] = "true" } : d
    })
    check(booleanResult.noIdentities)
    check(booleanResult.failedBoth && booleanResult.approvals == 0)
    let stripStores = stores(); seed(stripStores)
    let strip = run(stripStores, filter: { d, sender in
        sender && kind(d) == "autoOffer" ? mutate(d) { $0["trusted"] = false } : d
    })
    check(strip.noIdentities)
    check(strip.failedBoth && strip.approvals == 0)
    // Replay proofs from a successful connection with SAME session ID but fresh local nonces.
    let replay = run(first, round: 4, filter: { d, sender in
        guard kind(d) == "autoAuthenticate" else { return d }
        return reconnect.captured[sender]?.first(where: { kind($0) == "autoAuthenticate" }) ?? d
    })
    check(replay.noIdentities)
    check(replay.failedBoth && replay.approvals == 0)
    // Reflected proof has wrong direction even if its role field is rewritten.
    let reflectionStores = stores(); seed(reflectionStores)
    let reflect = run(reflectionStores, filter: { d, _ in
        kind(d) == "autoAuthenticate" ? mutate(d) { $0["role"] = "sender" } : d
    })
    check(!reflect.matched && reflect.approvals == 0)
    // Check cancellation at every boundary of a reconnect (before/after I/O and storage reads).
    for boundary in 1...19 {
        let pair = stores(); seed(pair)
        let result = run(pair, cancelAt: boundary)
        if case .failure? = result.results[true] {} else { check(false) }
        check(result.identityCount(side: true) == 0)
        check(result.approvals == 0 && pair.0.writes == 0 && pair.1.writes == 0)
    }
    return failures + runTrustedPairingKeychainStatusTests()
}


/// Eight bounded adapter cases. No SecItem function, UserDefaults access, or OS prompt is used.
private func runTrustedPairingKeychainStatusTests() -> Int {
    let local = "11111111-1111-4111-8111-111111111111"
    let peer = "22222222-2222-4222-8222-222222222222"
    let session = "33333333-3333-4333-8333-333333333333"
    // status, stored data, transport error injection, expected temporary-unavailability flag
    let cases: [(OSStatus, Data?, Bool, Bool)] = [
        (errSecInteractionNotAllowed, nil, false, true),
        (errSecNotAvailable, nil, false, true),
        (errSecAuthFailed, nil, false, false),
        (errSecItemNotFound, nil, false, false),
        (errSecDecode, nil, false, false),
        (errSecSuccess, Data(repeating: 1, count: 31), false, false),
        (errSecSuccess, Data(repeating: 1, count: 32), false, false), // forged proof
        (errSecSuccess, nil, true, false) // spoofed typed error outside Keychain
    ]
    var failures = 0
    for (status, data, spoofTransport, unavailable) in cases {
        var queries = 0, approvals = 0, identities = 0, reads = 0
        var noninteractive = true, forbiddenWire = false
        let store = TrustedPairingStore.KeychainStorage(allowInteraction: false,
            copyMatching: { query, result in
                queries += 1
                let fields = query as NSDictionary
                let context = fields[kSecUseAuthenticationContext as String] as? LAContext
                noninteractive = noninteractive && context?.interactionNotAllowed == true
                if let data = data { result?.pointee = data as CFData }
                return status
            }, localIdentity: { local })
        func encode(_ fields: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        }
        let io = PINPairingTransport(send: { message in
            let fields = try JSONSerialization.jsonObject(with: message) as? [String: Any]
            let kind = fields?["kind"] as? String
            forbiddenWire = forbiddenWire || !["autoHello", "autoOffer", "autoAuthenticate"].contains(kind ?? "")
            if spoofTransport { throw TrustedPairingError.keychainUnavailable }
        }, receive: {
            reads += 1
            switch reads {
            case 1:
                return try encode(["v": 1, "kind": "autoHello", "deviceID": peer,
                    "nonce": Data(repeating: 207, count: 32).base64EncodedString(),
                    "role": "receiver", "session": session])
            case 2:
                return try encode(["v": 1, "kind": "autoOffer", "role": "receiver",
                    "session": session, "trusted": data?.count == 32])
            default:
                return try encode(["v": 1, "kind": "autoAuthenticate", "role": "receiver",
                    "session": session, "payload": Data(repeating: 0, count: 32).base64EncodedString()])
            }
        }, cancelled: { false })
        var typedCorrectly = false
        do {
            _ = try performTrustedPairing(isSender: true, senderPIN: nil, sessionID: session,
                localName: "Test", transport: io, keychainStore: store, allowNewTrust: false,
                authenticatedIdentity: { _, _ in identities += 1 },
                receiverApproval: { _ in approvals += 1; return "0427" })
        } catch TrustedPairingError.keychainUnavailable { typedCorrectly = unavailable }
          catch TrustedPairingError.failed { typedCorrectly = !unavailable }
          catch { }
        if !typedCorrectly || store.keychainUnavailable != unavailable || !noninteractive
            || queries != (spoofTransport ? 0 : 1) || approvals != 0 || identities != 0 || forbiddenWire {
            failures += 1
        }
    }
    return failures
}
