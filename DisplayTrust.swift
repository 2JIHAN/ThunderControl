import Foundation
import CryptoKit

/// The display protocol's sending role describes VIDEO direction. Existing input
/// pairing normally used the opposite direction (MacBook keyboard -> Mac mini).
/// Resolve that exact peer's opposite role first. Only an absent item permits
/// the legacy same-direction lookup; access failures and bad proofs never retry.
/// This adapter cannot enroll, overwrite, reset, or export trust.
final class DisplayTrustStorage: TrustedPairingStorage {
    private let base: TrustedPairingStorage
    init(base: TrustedPairingStorage = TrustedPairingStore.KeychainStorage(allowInteraction: false)) {
        self.base = base
    }
    func identity() throws -> String { try base.identity() }
    func key(isSender: Bool, peerID: String) throws -> SymmetricKey? {
        if let preferred = try base.key(isSender: !isSender, peerID: peerID) { return preferred }
        return try base.key(isSender: isSender, peerID: peerID)
    }
    func save(_ key: SymmetricKey, isSender: Bool, peerID: String) throws {
        // Defense in depth even if a future caller accidentally enables enrollment.
        throw TrustedPairingError.failed
    }
}
