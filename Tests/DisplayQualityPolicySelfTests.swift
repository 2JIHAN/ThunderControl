import Foundation

/// Deterministic: no preferences writes, windows, codecs, network, or device probes.
func runDisplayQualityPolicySelfTests() -> Int {
    var checks = 0, failures = 0
    func expect(_ condition: Bool) { checks += 1; if !condition { failures += 1 } }
    let tiers = DisplayQualityTier.allCases
    expect(tiers.map(\.rawValue) == [0, 1, 2, 3])
    expect(tiers.map(\.wireCodecName) == ["h264", "hevc", "proxy", "lt"])
    for tier in tiers {
        expect(DisplayQualityTier(wireCodecName: tier.wireCodecName) == tier)
        let encoded = try? JSONEncoder().encode(tier)
        expect(encoded.flatMap { try? JSONDecoder().decode(DisplayQualityTier.self, from: $0) } == tier)
    }
    for invalid in ["", "H264", "H.264", "HEVC", "prores", "proxy ", " lt", "h265"] {
        expect(DisplayQualityTier(wireCodecName: invalid) == nil)
    }
    expect(DisplayQualityTier(rawValue: -1) == nil)
    expect(DisplayQualityTier(rawValue: 4) == nil)
    // Exhaustively test all supported subsets and caps, including empty support.
    for mask in 0..<16 {
        let supported = tiers.filter { mask & (1 << $0.rawValue) != 0 }
        for cap in tiers {
            let expected = tiers.reversed().first { $0.rawValue <= cap.rawValue && supported.contains($0) }
            expect(DisplayQualityTier.select(maximumTier: cap, supported: supported) == expected)
            expect(DisplayQualityTier.select(maximumTier: cap, supported: Array(supported.reversed()) + supported) == expected)
        }
    }
    let defaults = DisplayQualityPreferences()
    expect(defaults.maximumTier == .highest && defaults.presentation == .response)
    expect(DisplayQualityPreferences.fromStoredValues(maximumTier: nil, presentation: nil) == defaults)
    expect(DisplayPresentationMode.allCases.map(\.rawValue) == [0, 1])
    expect(DisplayPresentationMode.allCases.map(\.label) == ["반응속도 우선", "부드러움 우선"])
    for tier in tiers {
        for mode in DisplayPresentationMode.allCases {
            expect(DisplayQualityPreferences.fromStoredValues(maximumTier: tier.rawValue, presentation: mode.rawValue)
                   == DisplayQualityPreferences(maximumTier: tier, presentation: mode))
        }
    }
    let invalid: [Any] = [true, false, "0", "1", -1, 99, 0.5, Double.nan, Double.infinity, [1], ["x": 1], Data([0])]
    for value in invalid {
        expect(DisplayQualityPreferences.fromStoredValues(maximumTier: value, presentation: value) == defaults)
        expect(DisplayQualityPreferences.fromStoredValues(maximumTier: value, presentation: 1)
               == DisplayQualityPreferences(maximumTier: .highest, presentation: .smooth))
        expect(DisplayQualityPreferences.fromStoredValues(maximumTier: 0, presentation: value)
               == DisplayQualityPreferences(maximumTier: .compatibility, presentation: .response))
    }
    print("Display quality policy tests checks=\(checks) failures=\(failures)")
    return failures
}
