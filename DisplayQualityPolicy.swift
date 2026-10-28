import Foundation
import CoreFoundation

/// Ordered quality ceilings, not a promise of encoder availability or throughput.
/// Wire names are deliberately strict and independent of localized UI labels.
enum DisplayQualityTier: Int, CaseIterable, Codable, Sendable {
    case compatibility = 0, standard = 1, high = 2, highest = 3

    var wireCodecName: String {
        switch self {
        case .compatibility: return "h264"
        case .standard: return "hevc"
        case .high: return "proxy"
        case .highest: return "lt"
        }
    }
    var codecDisplayName: String {
        switch self {
        case .compatibility: return "H.264"
        case .standard: return "HEVC"
        case .high: return "ProRes Proxy"
        case .highest: return "ProRes LT"
        }
    }
    init?(wireCodecName: String) {
        guard let tier = Self.allCases.first(where: { $0.wireCodecName == wireCodecName }) else { return nil }
        self = tier
    }
    /// Caller supplies mutually supported tiers. Empty intersection must fail,
    /// rather than inventing a codec that one endpoint cannot decode.
    static func select(maximumTier: Self, supported: [Self]) -> Self? {
        supported.filter { $0.rawValue <= maximumTier.rawValue }.max { $0.rawValue < $1.rawValue }
    }
}

enum DisplayPresentationMode: Int, CaseIterable, Codable, Sendable {
    case response = 0, smooth = 1
    var label: String {
        switch self {
        case .response: return "반응속도 우선"
        case .smooth: return "부드러움 우선"
        }
    }
}

/// Desired settings snapshot. Saving alone never mutates or restarts an active session.
struct DisplayQualityPreferences: Equatable, Sendable {
    static let maximumTierDefaultsKey = "ThunderControl.displayQuality.maximumTier"
    static let presentationDefaultsKey = "ThunderControl.displayQuality.presentation"
    var maximumTier: DisplayQualityTier = .highest
    var presentation: DisplayPresentationMode = .response

    static var maximumTier: DisplayQualityTier { load().maximumTier }
    static var presentation: DisplayPresentationMode { load().presentation }

    /// Pure parsing seam shared by persistence and deterministic tests. Do not
    /// let UserDefaults integer coercion turn booleans/strings into valid choices.
    static func fromStoredValues(maximumTier: Any?, presentation: Any?) -> Self {
        func integer(_ value: Any?, upperBound: Int) -> Int? {
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let value = number.doubleValue
            guard value.isFinite, value >= 0, value <= Double(upperBound), value.rounded() == value else { return nil }
            return Int(value)
        }
        return Self(maximumTier: integer(maximumTier, upperBound: 3).flatMap(DisplayQualityTier.init(rawValue:)) ?? .highest,
                    presentation: integer(presentation, upperBound: 1).flatMap(DisplayPresentationMode.init(rawValue:)) ?? .response)
    }
    static func load(from defaults: UserDefaults = .standard) -> Self {
        fromStoredValues(maximumTier: defaults.object(forKey: maximumTierDefaultsKey),
                         presentation: defaults.object(forKey: presentationDefaultsKey))
    }
    func save(to defaults: UserDefaults = .standard) {
        defaults.set(maximumTier.rawValue, forKey: Self.maximumTierDefaultsKey)
        defaults.set(presentation.rawValue, forKey: Self.presentationDefaultsKey)
    }
}
