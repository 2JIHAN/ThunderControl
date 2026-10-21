import Foundation

/// Display text only. Never use localized text as a protocol, trust, settings or routing key.
enum TCLocalization {
    static let supportedLanguages = ["en", "ko"]
    static var preferredLanguage: String {
        Bundle.main.preferredLocalizations.first?.hasPrefix("ko") == true ? "ko" : "en"
    }

    static func normalizedLanguage(_ value: String) -> String {
        let tag = value.replacingOccurrences(of: "_", with: "-").lowercased()
        return tag == "ko" || tag.hasPrefix("ko-") ? "ko" : "en"
    }

    static func localized(_ key: String, language: String? = nil, values: [String] = []) -> String {
        let selected = normalizedLanguage(language ?? preferredLanguage)
        let resourceBundle = Bundle.main.path(forResource: selected, ofType: "lproj")
            .flatMap(Bundle.init(path:))
        let format = resourceBundle?.localizedString(forKey: key, value: key, table: nil) ?? key
        return substitute(format, values: values)
    }

    /// A single pass over the trusted template. Peer names and other values are never parsed
    /// as templates, printf directives, localization keys, commands or replacement syntax.
    static func substitute(_ format: String, values: [String]) -> String {
        guard !values.isEmpty else { return format }
        let expression = try! NSRegularExpression(pattern: #"\{([0-9]+)\}"#)
        let source = format as NSString
        let matches = expression.matches(in: format, range: NSRange(location: 0, length: source.length))
        var output = "", offset = 0
        for match in matches {
            output += source.substring(with: NSRange(location: offset, length: match.range.location - offset))
            let indexText = source.substring(with: match.range(at: 1))
            if let index = Int(indexText), values.indices.contains(index) {
                output += values[index]
            } else {
                output += source.substring(with: match.range)
            }
            offset = match.range.location + match.range.length
        }
        output += source.substring(from: offset)
        return output
    }
}

func TCText(_ key: String, _ values: String...) -> String {
    TCLocalization.localized(key, values: values)
}
