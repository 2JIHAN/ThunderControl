import Foundation

// Isolated, offline real-trace regression. No application, capture or network.
// swiftc -O -D PACING_REPLAY_MAIN -parse-as-library DisplayFramePacing.swift \
//   Tests/DisplayFramePacingReplayTests.swift -o /tmp/PacingReplay
// /tmp/PacingReplay Tests/DisplayFramePacingTrace.json
// Snapshot: diagnostics/live-2026-10-25/replay-events.json and
// replay/selected-sequences.json. renderer_control.time approximates the original
// later take() clock; candidate integration now records the EXACT pacingNow.
private struct PacingReplayEvent: Decodable {
    let stage: String, seq: Int, now: Double, target: Double, ready: Double
}
private struct PacingReplayFixture: Decodable {
    let events: [PacingReplayEvent], measuredSequences: [Int]
    let observedBaselineSelected: Int
}

func runDisplayFramePacingReplayTests(path: String) throws -> Int {
    let fixture = try JSONDecoder().decode(PacingReplayFixture.self,
        from: Data(contentsOf: URL(fileURLWithPath: path)))
    let measured = Set(fixture.measuredSequences)
    var measuredDiscards: [String: Int] = [:]
    var pacer = DisplayFramePacer<Int>(selectionPolicy: .fifo25, onDiscard: { frame, reason in
        if measured.contains(frame) { measuredDiscards[String(reason.rawValue), default: 0] += 1 }
    })
    var arrivals: [Int: Double] = [:]
    var selected: [Int] = [], times: [Double] = [], measuredTimes: [Double] = []
    var failures = 0, previous = -1
    for e in fixture.events {
        if e.stage == "pacer_offer" {
            arrivals[e.seq] = e.now; pacer.offer(e.seq, at: e.now)
        }
        else if e.ready == 1, let frame = pacer.take(now: e.now, targetTimestamp: e.target) {
            if frame <= previous || (arrivals[frame] ?? .infinity) > min(e.now, e.target) { failures += 1 }
            previous = frame; times.append(e.now)
            if measured.contains(frame) { selected.append(frame); measuredTimes.append(e.now) }
        }
        if pacer.pendingCount > 2 { failures += 1 }
    }
    let gaps = zip(times, times.dropFirst()).map { ($1 - $0) * 1_000 }
    if !gaps.allSatisfy({ $0 > 0 }) { failures += 1 }
    for i in times.indices {
        for j in i..<times.count {
            if Double(j - i) > (times[j] - times[i]) * 60 + 1.000001 { failures += 1 }
        }
    }
    // Meaningful improvement without assuming replay predicts panel presentation.
    if selected.count < 1_450 || fixture.observedBaselineSelected != 1_299 { failures += 1 }
    let counters = Dictionary(uniqueKeysWithValues: Mirror(reflecting: pacer.stats).children.compactMap {
        child -> (String, NSNumber)? in
        guard let name = child.label, let n = child.value as? UInt64 else { return nil }
        return (name, NSNumber(value: n))
    })
    let measuredGaps = zip(measuredTimes, measuredTimes.dropFirst()).map { ($1 - $0) * 1_000 }.sorted()
    let output: [String: Any] = [
        "approximateReplay": true, "panelPresentationMeasured": false,
        "baselineObservedSelectedInMeasuredWindow": fixture.observedBaselineSelected,
        "candidateSelectedInMeasuredWindow": selected.count,
        "candidateMeasuredSelectionFPS": Double(selected.count - 1) / (measuredTimes.last! - measuredTimes.first!),
        "allTraceCounters": counters, "measuredDiscardsByReason": measuredDiscards,
        "measuredGapP95Ms": measuredGaps[Int(Double(measuredGaps.count - 1) * 0.95)],
        "measuredMaximumGapMs": measuredGaps.last!,
        "minimumSelectionGapMs": gaps.min()!,
        "maximumSelectionGapMs": gaps.max()!, "failures": failures
    ]
    print(String(data: try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
    return failures
}
#if PACING_REPLAY_MAIN
@main private struct PacingReplayMain {
    static func main() throws {
        let failures = try runDisplayFramePacingReplayTests(path: CommandLine.arguments[1])
        if failures != 0 { exit(1) }
    }
}
#endif
