import Foundation

func runLocalizationTests() -> Int {
    var failures = 0, checks = 0
    func expect(_ condition: Bool, _ name: String) {
        checks += 1
        if !condition { failures += 1; print("FAIL localization: \(name)") }
    }
    expect(TCLocalization.normalizedLanguage("ko-KR") == "ko", "regional Korean")
    expect(TCLocalization.normalizedLanguage("ko_KR") == "ko", "underscore Korean")
    expect(TCLocalization.normalizedLanguage("en-US") == "en", "regional English")
    expect(TCLocalization.normalizedLanguage("fr") == "en", "unsupported language uses English")
    expect(TCLocalization.localized("Request Connection", language: "en") == "Request Connection", "English control")
    expect(TCLocalization.localized("Request Connection", language: "ko") == "연결 요청", "Korean control")
    expect(TCLocalization.localized("Request Connection", language: "fr") == "Request Connection", "English fallback")
    expect(TCLocalization.localized("Unregistered English fallback", language: "ko") == "Unregistered English fallback", "missing key fallback")
    expect(TCLocalization.localized("Receiver display {0}", language: "ko", values: ["7"]) == "수신 화면 7", "localized substitution")
    expect(TCLocalization.substitute("{1} / {0}", values: ["first", "second"]) == "second / first", "reordered parameters")
    expect(TCLocalization.substitute("{0} / {1}", values: ["peer {1}", "100%"]) == "peer {1} / 100%", "values not interpreted")
    expect(TCLocalization.substitute("{0}", values: ["Mac Unicode 한국어 %s"]) == "Mac Unicode 한국어 %s", "Unicode and printf values unchanged")
    expect(TCLocalization.substitute("{9}", values: ["safe"]) == "{9}", "missing value remains visible")
    expect(TCLocalization.substitute("{9999999999999999999999999999}", values: ["safe"]) == "{9999999999999999999999999999}", "oversized index fails closed")
    expect(TCLocalization.substitute("literal 60% / %.1f / %@", values: ["unused"]) == "literal 60% / %.1f / %@", "printf formats preserved")
    expect(TCLocalization.substitute("Korean {0} / {0}", values: ["이름"]) == "Korean 이름 / 이름", "repeated parameter")
    var catalogs: [String: [String: String]] = [:]
    for language in TCLocalization.supportedLanguages {
        guard let folder = Bundle.main.path(forResource: language, ofType: "lproj"),
              let data = try? Data(contentsOf: URL(fileURLWithPath: folder).appendingPathComponent("Localizable.strings")),
              let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let strings = value as? [String: String] else { expect(false, "load bundled catalog \(language)"); continue }
        catalogs[language] = strings
        expect(strings.count >= 219, "complete catalog \(language)")
    }
    if let english = catalogs["en"], let korean = catalogs["ko"] {
        expect(Set(english.keys) == Set(korean.keys), "catalog key parity")
        let placeholders = try! NSRegularExpression(pattern: #"\{[0-9]+\}"#)
        let printf = try! NSRegularExpression(pattern: #"%(?:[0-9]+\$)?(?:\.[0-9]+)?[@df]"#)
        func tokens(_ text: String) -> [String] {
            let source = text as NSString
            return placeholders.matches(in: text, range: NSRange(location: 0, length: source.length))
                .map { source.substring(with: $0.range) }.sorted()
        }
        for (key, value) in english {
            expect(key == value, "English key is the readable fallback")
            expect(tokens(value) == tokens(korean[key]!), "placeholder parity")
            func printfTokens(_ text: String) -> [String] {
                let source = text as NSString
                return printf.matches(in: text, range: NSRange(location: 0, length: source.length))
                    .map { source.substring(with: $0.range) }
            }
            expect(printfTokens(value) == printfTokens(korean[key]!), "printf type and order parity")
        }
    }
    print("Localization: \(checks) checks, \(failures) failures; English fallback, bundled Korean, inert peer values; no preferences/network/input")
    return failures
}
