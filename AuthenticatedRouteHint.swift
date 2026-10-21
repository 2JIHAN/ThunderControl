import Foundation

/// Routing metadata only, never authentication or permission to send input.
/// Save only after authentication; the caller must independently prove and bind the pair.
struct AuthenticatedRouteHint: Codable, Equatable {
    let pair: LayoutDevicePair
    let ipv4: String
    let port: UInt16

    init?(pair: LayoutDevicePair, ipv4: String, port: UInt16) {
        guard pair.localID != pair.peerID, port == 49177,
              let validated = BridgeDiscoveryValidation.ipv4(ipv4), validated == ipv4 else { return nil }
        let octets = ipv4.split(separator: ".").compactMap { UInt8($0) }
        // Keep this restriction even if discovery validation becomes more permissive.
        // Private and link-local unicast are intentional. Directed broadcast cannot be
        // identified from an address alone without a subnet mask.
        guard octets.count == 4, octets[0] > 0, octets[0] != 127,
              octets[0] < 224, octets != [255, 255, 255, 255] else { return nil }
        self.pair = pair
        self.ipv4 = ipv4
        self.port = port
    }

    private enum CodingKeys: String, CodingKey { case pair, ipv4, port }
    private enum PairKeys: String, CodingKey { case localID, peerID }

    init(from decoder: Decoder) throws {
        try requireRouteHintKeys(decoder, ["pair", "ipv4", "port"])
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        let pairDecoder = try fields.superDecoder(forKey: .pair)
        try requireRouteHintKeys(pairDecoder, ["localID", "peerID"])
        let ids = try pairDecoder.container(keyedBy: PairKeys.self)
        let local = try ids.decode(String.self, forKey: .localID)
        let peer = try ids.decode(String.self, forKey: .peerID)
        guard let pair = LayoutDevicePair(localID: local, peerID: peer),
              let hint = AuthenticatedRouteHint(pair: pair,
                ipv4: try fields.decode(String.self, forKey: .ipv4),
                port: try fields.decode(UInt16.self, forKey: .port)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Invalid routing hint"))
        }
        self = hint
    }
}

private struct RouteHintCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func requireRouteHintKeys(_ decoder: Decoder, _ expected: Set<String>) throws {
    let fields = try decoder.container(keyedBy: RouteHintCodingKey.self)
    guard Set(fields.allKeys.map(\.stringValue)) == expected else {
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
            debugDescription: "Unexpected routing hint schema"))
    }
}

final class AuthenticatedRouteHintStore {
    static let key = "ThunderControl.authenticatedRouteHint.v1"
    static let maximumBytes = 4096
    private struct Envelope: Codable {
        let version: Int
        let hint: AuthenticatedRouteHint
        private enum CodingKeys: String, CodingKey { case version, hint }
        init(hint: AuthenticatedRouteHint) { version = 1; self.hint = hint }
        init(from decoder: Decoder) throws {
            try requireRouteHintKeys(decoder, ["version", "hint"])
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            version = try fields.decode(Int.self, forKey: .version)
            guard version == 1 else {
                throw DecodingError.dataCorruptedError(forKey: .version, in: fields,
                    debugDescription: "Unsupported routing hint version")
            }
            hint = try fields.decode(AuthenticatedRouteHint.self, forKey: .hint)
        }
    }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load(localID: UUID) -> AuthenticatedRouteHint? {
        guard let data = defaults.data(forKey: Self.key), data.count <= Self.maximumBytes,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.hint.pair.localID == localID else { return nil }
        // Revalidate at the persistence boundary, independent of Codable implementation.
        return AuthenticatedRouteHint(pair: envelope.hint.pair,
            ipv4: envelope.hint.ipv4, port: envelope.hint.port)
    }

    @discardableResult func save(_ hint: AuthenticatedRouteHint) -> Bool {
        guard let validated = AuthenticatedRouteHint(pair: hint.pair, ipv4: hint.ipv4, port: hint.port),
              let data = try? JSONEncoder().encode(Envelope(hint: validated)),
              data.count <= Self.maximumBytes else { return false }
        defaults.set(data, forKey: Self.key)
        return true
    }

    func clear() { defaults.removeObject(forKey: Self.key) }
}
