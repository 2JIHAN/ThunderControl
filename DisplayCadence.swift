import Foundation

/// Constant-memory host-local observations. No frames, coordinates, or input are retained.
/// Submission/callback cadence is NOT panel cadence; long gaps may be idle content.
struct DisplayTimingStats {
    private(set) var count: UInt64 = 0
    private(set) var totalMilliseconds = 0.0
    private(set) var maximumMilliseconds = 0.0
    @discardableResult mutating func record(_ milliseconds: Double) -> Bool {
        guard milliseconds.isFinite, milliseconds >= 0, count < UInt64.max,
              (totalMilliseconds + milliseconds).isFinite else { return false }
        count += 1; totalMilliseconds += milliseconds
        maximumMilliseconds = max(maximumMilliseconds, milliseconds)
        return true
    }
    var meanMilliseconds: Double { count == 0 ? 0 : totalMilliseconds / Double(count) }
    var summary: String { "n=\(count) meanMs=" + String(format: "%.3f", meanMilliseconds) + " maxMs=" + String(format: "%.3f", maximumMilliseconds) }
}

struct DisplayCadenceStats {
    private(set) var count: UInt64 = 0
    private(set) var intervals = DisplayTimingStats()
    private(set) var gapsOver25Milliseconds: UInt64 = 0
    private(set) var gapsOver50Milliseconds: UInt64 = 0
    private(set) var gapsOver100Milliseconds: UInt64 = 0
    private var last: Double?
    @discardableResult mutating func observe(_ monotonicSeconds: Double) -> Bool {
        guard monotonicSeconds.isFinite, monotonicSeconds >= 0, count < UInt64.max,
              last.map({ monotonicSeconds >= $0 }) ?? true else { return false }
        if let previous = last {
            let milliseconds = (monotonicSeconds - previous) * 1000
            guard intervals.record(milliseconds) else { return false }
            if milliseconds > 25 { gapsOver25Milliseconds += 1 }
            if milliseconds > 50 { gapsOver50Milliseconds += 1 }
            if milliseconds > 100 { gapsOver100Milliseconds += 1 }
        }
        last = monotonicSeconds; count += 1
        return true
    }
    var summary: String { "frames=\(count) intervals[\(intervals.summary)] gapsOver25=\(gapsOver25Milliseconds) gapsOver50=\(gapsOver50Milliseconds) gapsOver100=\(gapsOver100Milliseconds)" }
}
