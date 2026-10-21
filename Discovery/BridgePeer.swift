import Foundation

/// A discovery hint, NOT an authenticated identity. Require selection and PAKE later.
public struct BridgePeer: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let ipv4: String
    public let port: UInt16
    public init(id: String, name: String, ipv4: String, port: UInt16) {
        self.id = id; self.name = name; self.ipv4 = ipv4; self.port = port
    }
}

enum BridgeDiscoveryValidation {
    static let maximumPeers = 31
    static func validInterface(_ index: UInt32) -> Bool {
        // Reject DNS-SD pseudo interfaces as well as the default interface (zero).
        index > 0 && index < 0x80000000
    }
    static func ipv4(_ text: String) -> String? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 3,
                  part.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  part.count == 1 || part.first != "0", let value = UInt8(part) else { return nil }
            bytes.append(value)
        }
        guard bytes[0] != 0, bytes[0] != 127, bytes[0] < 224,
              bytes != [255,255,255,255] else { return nil }
        return bytes.map(String.init).joined(separator: ".")
    }
    static func displayName(_ text: String) -> String {
        // Drop C0/C1 controls, bidi overrides, zero-width formatting and line separators.
        let clean = String(String.UnicodeScalarView(text.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) &&
            !CharacterSet.illegalCharacters.contains($0) &&
            $0.properties.generalCategory != .format &&
            $0.value != 0x2028 && $0.value != 0x2029
        })).trimmingCharacters(in: .whitespacesAndNewlines)
        // DNS-SD instance labels are limited by bytes, not grapheme count.
        // Preserve complete Unicode scalars; leave room below the 63-byte limit.
        var bounded = ""
        var byteCount = 0
        for scalar in clean.unicodeScalars {
            let next = String(scalar).utf8.count
            guard byteCount + next <= 60 else { break }
            bounded.unicodeScalars.append(scalar)
            byteCount += next
        }
        bounded = bounded.trimmingCharacters(in: .whitespacesAndNewlines)

        return bounded.isEmpty ? "Bridge peer" : bounded
    }
}
