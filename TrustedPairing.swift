import Foundation
import CryptoKit
import Security
import LocalAuthentication

/// All failures intentionally omit peer identifiers, names, PINs, and cryptographic material.
enum TrustedPairingError: Error, LocalizedError {
    case failed
    /// Local noninteractive Keychain access is temporarily unavailable; never a peer/crypto failure.
    case keychainUnavailable
    var errorDescription: String? { "Secure pairing failed. Cancel or explicitly forget trust on both Macs before pairing again." }
}

/// Internal dependency seam. Tests supply an isolated memory store and deterministic fresh nonces.
/// Keys are indexed ONLY by local protocol role and canonical peer UUID, never network/name data.
protocol TrustedPairingStorage {
    func identity() throws -> String
    func key(isSender: Bool, peerID: String) throws -> SymmetricKey?
    func save(_ key: SymmetricKey, isSender: Bool, peerID: String) throws
}

/// Public UI helpers. The identity is nonsecret; PINs and keys never enter UserDefaults.
/// hasAnyTrustedPeer is a UI hint only, never an authentication decision.
/// forgetAll deletes only this app's trust entries for the selected local role.
/// Keychain access is noninteractive. If an ad-hoc update loses item access, forget on both Macs and enroll again.
/// No userPresence requirement, synchronization, or OS approval bypass is used.
enum TrustedPairingStore {
    private static let lock = NSLock()
    private static let service = "local.experimental.ThunderControl.autoTrust.v1"
    private static let identityPreference = "ThunderControl.autoTrust.deviceID.v1"
    static func localIdentity() -> String {
        lock.lock(); defer { lock.unlock() }
        if let value = UserDefaults.standard.string(forKey: identityPreference),
           UUID(uuidString: value)?.uuidString == value { return value }
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: identityPreference)
        return value
    }
    private static func query(isSender: Bool, peerID: String? = nil) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrDescription as String: isSender ? "sender" : "receiver",
            kSecAttrSynchronizable as String: false]
        if let id = peerID { q[kSecAttrAccount as String] = (isSender ? "sender:" : "receiver:") + id }
        return q
    }
    static func hasAnyTrustedPeer(isSender: Bool) -> Bool {
        var q = query(isSender: isSender)
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecReturnData as String] = false
        let context = LAContext()
        context.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = context
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }
    static func resetForFirstSetup() throws {
        try forgetAll(isSender:true)
        try forgetAll(isSender:false)
        guard let domain=Bundle.main.bundleIdentifier,domain=="local.experimental.ThunderControl" else{throw TrustedPairingError.failed}
        UserDefaults.standard.removePersistentDomain(forName:domain)
        UserDefaults.standard.synchronize()
    }
    static func forgetAll(isSender: Bool) throws {
        let status = SecItemDelete(query(isSender: isSender) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw TrustedPairingError.failed }
    }
    final class KeychainStorage: TrustedPairingStorage {
        let allowInteraction:Bool
        private(set) var keychainUnavailable = false
        private let copyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
        private let localIdentity: () -> String
        // Injection keeps status classification tests hardware-free, including identity persistence.
        init(allowInteraction: Bool,
             copyMatching: @escaping (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemCopyMatching,
             localIdentity: @escaping () -> String = TrustedPairingStore.localIdentity) {
            self.allowInteraction = allowInteraction
            self.copyMatching = copyMatching
            self.localIdentity = localIdentity
        }
        func identity() throws -> String { localIdentity() }
        func key(isSender: Bool, peerID: String) throws -> SymmetricKey? {
            var q = query(isSender: isSender, peerID: peerID)
            let context=LAContext();context.interactionNotAllowed = !allowInteraction
            q[kSecUseAuthenticationContext as String]=context
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var value: CFTypeRef?
            let status = copyMatching(q as CFDictionary, &value)
            if status == errSecInteractionNotAllowed || status == errSecNotAvailable {
                keychainUnavailable = true
            }
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let bytes = value as? Data, bytes.count == 32 else { throw TrustedPairingError.failed }
            return SymmetricKey(data: bytes)
        }
        func save(_ key: SymmetricKey, isSender: Bool, peerID: String) throws {
            var q = query(isSender: isSender, peerID: peerID)
            let context=LAContext();context.interactionNotAllowed=true
            q[kSecUseAuthenticationContext as String]=context
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            q[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
            // Never overwrite a concurrent enrollment or existing trust. Explicit forget is required.
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw TrustedPairingError.failed }
        }
    }
}

/// 0.7.0 wire prelude, incompatible with peers without autoTrust protocol v1.
/// Call ONLY AFTER agreePairingScope. Both endpoints must use this wrapper in place of
/// performPINPairing. Existing encrypted role confirmation still runs with the returned key.
/// First enrollment always runs real SPAKE2 and receiverApproval; reconnect never asks for a PIN.
/// Automatic discovery/reconnect callers MUST pass allowNewTrust: false. Unknown UUIDs then fail
/// before PIN pairing or receiverApproval. Only explicit manual pairing may allow enrollment.
/// Partial/mismatched trust fails closed: explicitly forget on BOTH endpoints before re-pairing.
/// Caller owns message framing, short-message send buffering, deadlines and cancellation unblocking.
/// No network operations occur except through transport. receiverApproval retains PIN pairing's
/// threading contract. Use a stable signed app identity for predictable Keychain access.
/// authenticatedIdentity reports proven local/peer UUIDs as metadata only, after authentication.
/// It does not replace the caller's existing encrypted role confirmation.
func performTrustedPairing(isSender: Bool, senderPIN: String?, sessionID: String,
                          localName: String, transport: PINPairingTransport,
                          allowNewTrust: Bool = true,allowKeychainInteraction:Bool=false,
                          authenticatedIdentity: ((String,String)->Void)? = nil,
                          receiverApproval: (PINPairingRequest) throws -> String) throws -> SymmetricKey {
    try performTrustedPairing(isSender: isSender, senderPIN: senderPIN, sessionID: sessionID,
        localName: localName, transport: transport,
        keychainStore: TrustedPairingStore.KeychainStorage(allowInteraction: allowKeychainInteraction),
        allowNewTrust: allowNewTrust, authenticatedIdentity: authenticatedIdentity, receiverApproval: receiverApproval)
}

/// Concrete-store wrapper: only an actual local Keychain query can mark a failure retryable.
/// Allocate a fresh store per attempt; errors from transport, PIN, or proof validation stay generic.
func performTrustedPairing(isSender: Bool, senderPIN: String?, sessionID: String,
                          localName: String, transport: PINPairingTransport,
                          keychainStore: TrustedPairingStore.KeychainStorage,
                          allowNewTrust: Bool = true,
                          authenticatedIdentity: ((String,String)->Void)? = nil,
                          receiverApproval: (PINPairingRequest) throws -> String) throws -> SymmetricKey {
    do {
        return try performTrustedPairing(isSender: isSender, senderPIN: senderPIN, sessionID: sessionID,
            localName: localName, transport: transport, store: keychainStore,
            nonce: { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } },
            allowNewTrust: allowNewTrust, authenticatedIdentity: authenticatedIdentity, receiverApproval: receiverApproval)
    } catch {
        if keychainStore.keychainUnavailable { throw TrustedPairingError.keychainUnavailable }
        throw TrustedPairingError.failed
    }
}

/// Internal testable implementation; production always uses KeychainStorage and CSPRNG nonces.
func performTrustedPairing(isSender: Bool, senderPIN: String?, sessionID: String,
                          localName: String, transport: PINPairingTransport,
                          store: TrustedPairingStorage, nonce: () throws -> Data,
                          allowNewTrust: Bool = true,
                          authenticatedIdentity: ((String,String)->Void)? = nil,
                          receiverApproval: (PINPairingRequest) throws -> String) throws -> SymmetricKey {
    do {
        return try TrustedHandshake(isSender: isSender, session: sessionID, io: transport, store: store)
            .run(pin: senderPIN, name: localName, nonce: nonce, allowNewTrust: allowNewTrust, authenticatedIdentity: authenticatedIdentity, approval: receiverApproval)
    } catch { throw TrustedPairingError.failed }
}

private struct TrustedHello: Codable {
    let v: Int, kind: String, deviceID: String, nonce: String, role: String, session: String
}
private struct TrustedOffer: Codable {
    let v: Int, kind: String, role: String, session: String
    let trusted: Bool
}
private struct TrustedProof: Codable {
    let v: Int, kind: String, role: String, session: String, payload: String
}
private final class TrustedHandshake {
    let isSender: Bool, session: String, io: PINPairingTransport, store: TrustedPairingStorage
    var role: String { isSender ? "sender" : "receiver" }
    var otherRole: String { isSender ? "receiver" : "sender" }
    let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e }()
    init(isSender: Bool, session: String, io: PINPairingTransport, store: TrustedPairingStorage) {
        self.isSender = isSender; self.session = session; self.io = io; self.store = store
    }
    func check() throws { guard !io.cancelled() else { throw TrustedPairingError.failed } }
    func require(_ condition: Bool) throws { guard condition else { throw TrustedPairingError.failed } }
    func canonicalID(_ id: String) -> Bool { UUID(uuidString: id)?.uuidString == id }
    func encode<T: Encodable>(_ value: T) throws -> Data { try encoder.encode(value) }
    func send<T: Encodable>(_ value: T) throws {
        try check(); let data = try encode(value); try require(data.count <= 4096)
        try io.send(data); try check()
    }
    func read<T: Codable>(_ type: T.Type) throws -> T {
        try check(); let data = try io.receive(); try check()
        try require(!data.isEmpty && data.count <= 4096)
        let result = try JSONDecoder().decode(type, from: data)
        // Exact roundtrip rejects unknown/duplicate fields, whitespace, alternate escaping/types.
        try require(try encode(result) == data)
        return result
    }
    func bytes(_ base64: String) throws -> Data {
        guard let d = Data(base64Encoded: base64), d.count == 32,
              d.base64EncodedString() == base64 else { throw TrustedPairingError.failed }
        return d
    }
    func join(_ values: [Data]) -> Data {
        var out = Data()
        for value in values {
            var n = UInt32(value.count).bigEndian
            withUnsafeBytes(of: &n) { out.append(contentsOf: $0) }; out.append(value)
        }
        return out
    }
    func derive(_ key: SymmetricKey, _ transcript: Data, _ label: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: Data(SHA256.hash(data: transcript)),
            info: join([Data("ThunderControl/autoTrust/v1".utf8), Data(label.utf8), transcript]), outputByteCount: 32)
    }
    func confirm(_ key: SymmetricKey, transcript: Data, kind: String) throws {
        func message(_ direction: String) -> Data {
            join([Data("ThunderControl/autoTrust/v1".utf8), Data(kind.utf8), Data(direction.utf8), transcript])
        }
        let payload = Data(HMAC<SHA256>.authenticationCode(for: message(role), using: key))
        try send(TrustedProof(v: 1, kind: kind, role: role, session: session, payload: payload.base64EncodedString()))
        let proof = try read(TrustedProof.self)
        try require(proof.v == 1 && proof.kind == kind && proof.role == otherRole && proof.session == session)
        let received = try bytes(proof.payload)
        try require(HMAC<SHA256>.isValidAuthenticationCode(received, authenticating: message(otherRole), using: key))
        try check()
    }
    func run(pin: String?, name: String, nonce: () throws -> Data, allowNewTrust: Bool,
             authenticatedIdentity: ((String,String)->Void)?,
             approval: (PINPairingRequest) throws -> String) throws -> SymmetricKey {
        try check(); try require(canonicalID(session))
        let id = try store.identity(); try check(); try require(canonicalID(id))
        let fresh = try nonce(); try check(); try require(fresh.count == 32)
        let hello = TrustedHello(v: 1, kind: "autoHello", deviceID: id,
                                 nonce: fresh.base64EncodedString(), role: role, session: session)
        // Both sides send before receiving, so caller must buffer these bounded short messages.
        try send(hello)
        let peer = try read(TrustedHello.self)
        try require(peer.v == 1 && peer.kind == "autoHello" && peer.role == otherRole && peer.session == session)
        try require(canonicalID(peer.deviceID) && peer.deviceID != id)
        let peerNonce = try bytes(peer.nonce); try require(peerNonce != fresh)
        try check(); let stored = try store.key(isSender: isSender, peerID: peer.deviceID); try check()
        if let key = stored { try require(key.bitCount == 256) }
        let offer = TrustedOffer(v: 1, kind: "autoOffer", role: role, session: session, trusted: stored != nil)
        try send(offer)
        let peerOffer = try read(TrustedOffer.self)
        try require(peerOffer.v == 1 && peerOffer.kind == "autoOffer" && peerOffer.role == otherRole && peerOffer.session == session)
        let transcript = try join([Data("ThunderControl/autoTrust/v1/transcript".utf8),
            encode(isSender ? hello : peer), encode(isSender ? peer : hello),
            encode(isSender ? offer : peerOffer), encode(isSender ? peerOffer : offer)])
        // Never silently fall back to PIN, including when a known peer claims to have forgotten us.
        try require(offer.trusted == peerOffer.trusted)
        if let key = stored {
            try confirm(key, transcript: transcript, kind: "autoAuthenticate")
            try check()
            authenticatedIdentity?(id, peer.deviceID)
            return derive(key, transcript, "fresh-application-session-key")
        }
        try check(); try require(allowNewTrust)
        let pinKey = try performPINPairing(isSender: isSender, senderPIN: pin, sessionID: session,
            localName: name, transport: io, receiverApproval: approval)
        try check()
        let trust = derive(pinKey, transcript, "autoTrust-bound-both-identities-and-roles")
        // SPAKE's mutually confirmed key authenticates the ENTIRE prelude before stable IDs persist.
        try confirm(trust, transcript: transcript, kind: "autoStorageConfirm")
        try check(); try store.save(trust, isSender: isSender, peerID: peer.deviceID); try check()
        authenticatedIdentity?(id, peer.deviceID)
        return pinKey
    }
}
