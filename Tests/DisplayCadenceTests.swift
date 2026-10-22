import Foundation
func runDisplayCadenceTests() -> Int {
    var checks = 0, failures = 0
    func verify(_ value: Bool) { checks += 1; if !value { failures += 1 } }
    var timing = DisplayTimingStats()
    verify(timing.count == 0 && timing.meanMilliseconds == 0)
    for bad in [Double.nan, .infinity, -.infinity, -1] { verify(!timing.record(bad)) }
    verify(timing.record(0) && timing.record(2) && timing.record(4))
    verify(timing.count == 3 && timing.meanMilliseconds == 2 && timing.maximumMilliseconds == 4)
    var cadence = DisplayCadenceStats()
    verify(cadence.observe(0) && cadence.intervals.count == 0)
    for time in [0.016, 0.032, 0.062, 0.122, 0.262] { verify(cadence.observe(time)) }
    verify(cadence.count == 6 && cadence.intervals.count == 5)
    verify(cadence.gapsOver25Milliseconds == 3 && cadence.gapsOver50Milliseconds == 2 && cadence.gapsOver100Milliseconds == 1)
    verify(abs(cadence.intervals.maximumMilliseconds - 140) < 0.0001)
    let before = cadence.summary
    for bad in [Double.nan, .infinity, -.infinity, -1, 0.1] { verify(!cadence.observe(bad)) }
    verify(cadence.summary == before)
    verify(cadence.observe(3)) // idle gap is reported, not declared a lost frame.
    verify(cadence.gapsOver100Milliseconds == 2 && cadence.count == 7)
    for i in 1...100_000 { verify(cadence.observe(3 + Double(i) / 60)) }
    verify(cadence.count == 100_007 && cadence.intervals.count == 100_006)
    verify(cadence.summary.contains("frames=100007"))
    print("Display cadence: \(checks) checks, \(failures) failures; constant-memory synthetic timestamps, no panel/FPS claims")
    return failures
}
