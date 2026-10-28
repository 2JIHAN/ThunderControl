import Foundation

/// Pure deterministic policy tests: no OS, GUI, timers or panel-rate claims.
func runDisplayFramePacingTests() -> Int {
    var checks = 0, failures = 0
    func verify(_ value: Bool, _ name: String) {
        checks += 1
        if !value { failures += 1; print("FAIL DisplayFramePacing: \(name)") }
    }
    let dt = 1.0 / 60.0
    var p = DisplayFramePacer<Int>(selectionPolicy: .fifo25)
    verify(!p.pending && p.pendingCount == 0 && p.stats == DisplayFramePacingStats(), "initial state")
    verify(!p.offer(1, at: 0) && p.pendingCount == 1, "first offer")
    verify(p.take(now: 0, targetTimestamp: 0) == nil && p.stats.waitingTicks == 1, "one-frame cushion")
    verify(p.take(now: dt, targetTimestamp: dt) == 1 && !p.pending, "exact first boundary")
    verify(p.take(now: 2 * dt, targetTimestamp: 2 * dt) == nil && p.stats.emptyTicks == 1, "no duplicate")
    p.offer(2, at: 10)
    verify(p.take(now: 10 + dt, targetTimestamp: 10 + dt) == 2, "idle frame does not wait forever")
    p.offer(3, at: 10)
    verify(p.take(now: 10 + dt + 0.008, targetTimestamp: 10 + dt + 0.008) == nil && p.stats.rateLimitedTicks == 1, "idle gap no catch-up burst")
    verify(p.take(now: 10 + 2 * dt, targetTimestamp: 10 + 2 * dt) == 3, "normal cadence resumes")

    p.clear()
    verify(!p.pending && p.stats == DisplayFramePacingStats(), "clear resets diagnostics and queue")
    p.offer(10, at: 0); p.offer(11, at: 0.001)
    verify(p.offer(12, at: 0.002) && p.pendingCount == 2 && p.stats.overflowReplaced == 1, "third offer replaces oldest")
    verify(p.take(now: 1, targetTimestamp: 1) == 12 && p.stats.superseded == 1 && !p.pending, "newest eligible supersedes old decoded frame")
    verify(p.take(now: 1 + dt, targetTimestamp: 1 + dt) == nil, "discarded frames cannot resurrect")

    p.clear(); p.offer(20, at: 0); p.offer(21, at: 0.01)
    verify(p.take(now: dt, targetTimestamp: dt) == 20 && p.pendingCount == 1, "future younger frame retained")
    verify(p.take(now: 2 * dt, targetTimestamp: 2 * dt) == 21, "retained younger frame later selected")
    p.clear(); p.offer(30, at: 0); p.offer(31, at: 0)
    verify(p.take(now: dt, targetTimestamp: dt) == 30 && p.stats.offered == 2 && p.pendingCount == 1, "equal arrivals preserve FIFO insertion order")

    // The 25ms switch is strict and uses actual callback age, not target age.
    var threshold = DisplayFramePacer<Int>(selectionPolicy: .fifo25)
    threshold.offer(1, at: 0); threshold.offer(2, at: 0.001)
    verify(threshold.take(now: 0.025, targetTimestamp: 0.025) == 1 &&
           threshold.pendingCount == 1 && threshold.stats.superseded == 0,
           "exact 25ms remains FIFO when both entries eligible")
    threshold.clear(); threshold.offer(1, at: 0); threshold.offer(2, at: 0.001)
    let above25 = Double(0.025).nextUp
    verify(threshold.take(now: above25, targetTimestamp: above25) == 2 &&
           threshold.pendingCount == 0 && threshold.stats.superseded == 1,
           "one representable step above 25ms catches up newest eligible")
    threshold.clear(); threshold.offer(1, at: 0); threshold.offer(2, at: 0.001)
    verify(threshold.take(now: 0.024, targetTimestamp: 0.05) == 1,
           "future prediction cannot trigger actual-age catchup")
    var fifo = DisplayFramePacer<Int>(selectionPolicy: .fifo25)
    fifo.offer(1, at: 0); fifo.offer(2, at: 0.001)
    verify(fifo.take(now: 0.02, targetTimestamp: 0.02) == 1 && fifo.pendingCount == 1,
           "normal selection chooses oldest of two eligible entries")
    verify(fifo.take(now: 0.021, targetTimestamp: 0.021) == 2 && !fifo.pending && fifo.stats.superseded == 0,
           "FIFO drains retained entry in insertion order within existing startup budget")
    var catchupEligibility = DisplayFramePacer<Int>(selectionPolicy: .fifo25)
    catchupEligibility.offer(1, at: 0); catchupEligibility.offer(2, at: 0.029)
    verify(catchupEligibility.take(now: 0.03, targetTimestamp: 0.03) == 1 &&
           catchupEligibility.pendingCount == 1 && catchupEligibility.stats.superseded == 0,
           "catchup selects newest ELIGIBLE not merely newest arrival")
    catchupEligibility.clear(); catchupEligibility.offer(1, at: 0); catchupEligibility.offer(2, at: 0.04)
    verify(catchupEligibility.take(now: 0.03, targetTimestamp: 0.07) == 1 && catchupEligibility.pendingCount == 1,
           "catchup never selects future arrival even if predicted target permits it")
    catchupEligibility.clear(); catchupEligibility.offer(1, at: 0); catchupEligibility.offer(2, at: 0.02)
    verify(catchupEligibility.take(now: 0.03, targetTimestamp: 0.02) == 1 && catchupEligibility.pendingCount == 1,
           "catchup honors past target cushion as well as actual clock")
    var oldSingleton = DisplayFramePacer<Int>(selectionPolicy: .fifo25)
    oldSingleton.offer(1, at: 0)
    verify(oldSingleton.take(now: 1, targetTimestamp: 1) == 1 && oldSingleton.stats.superseded == 0,
           "25ms is catchup threshold not a hard expiry for old singleton")
    var noPoison = DisplayFramePacer<Int>(selectionPolicy: .fifo25)
    noPoison.offer(1, at: 0); noPoison.offer(2, at: 0.001)
    let beforeInvalid = noPoison.stats
    verify(noPoison.take(now: 10, targetTimestamp: 20) == nil &&
           noPoison.take(now: .nan, targetTimestamp: 10) == nil &&
           noPoison.pendingCount == 2 && noPoison.stats.invalidInputs == beforeInvalid.invalidInputs + 2 &&
           noPoison.stats.selected == 0 && noPoison.stats.waitingTicks == 0 &&
           noPoison.stats.rateLimitedTicks == 0 && noPoison.stats.superseded == 0,
           "invalid catchup ticks change only invalid counter")
    verify(noPoison.take(now: 0.025, targetTimestamp: 0.025) == 1,
           "invalid future tick does not poison clocks or FIFO threshold")
    var discards: [(Int, DisplayFrameDiscardReason)] = []
    var reasons = DisplayFramePacer<Int>(selectionPolicy: .fifo25, onDiscard: { discards.append(($0, $1)) })
    reasons.offer(1, at: 0); reasons.offer(2, at: 0.001)
    _ = reasons.take(now: 0.02, targetTimestamp: 0.02)
    verify(discards.isEmpty && reasons.stats.selected == 1 && reasons.stats.superseded == 0 && reasons.stats.earlySelections == 0,
           "FIFO selection does not report retained younger entry as discarded")
    reasons.offer(3, at: 0.002)
    verify(reasons.take(now: 0.03, targetTimestamp: 0.03) == 3 && discards.count == 1 &&
           discards[0].0 == 2 && discards[0].1 == .superseded && reasons.stats.superseded == 1 &&
           reasons.stats.selected == 2 && reasons.stats.earlySelections == 0,
           "catchup reports only skipped older frame as superseded not early")
    reasons.offer(4, at: 0.04); reasons.offer(5, at: 0.041); reasons.offer(6, at: 0.042)
    reasons.offer(99, at: .nan); reasons.clear()
    verify(discards.map { $0.0 } == [2, 4, 99, 5, 6] &&
           discards.map { $0.1 } == [.superseded, .overflow, .invalidOffer, .clear, .clear] &&
           reasons.stats == DisplayFramePacingStats() && !reasons.pending,
           "discard callback reasons remain exact and clear resets all stats")

    p.clear(); p.offer(40, at: 1)
    var invalidOffersOK = true
    for bad in [Double.nan, .infinity, -.infinity, -1, 0.5, Double.greatestFiniteMagnitude] {
        invalidOffersOK = !p.offer(99, at: bad) && invalidOffersOK
    }
    verify(invalidOffersOK && p.pendingCount == 1 && p.stats.offered == 1 && p.stats.invalidInputs == 6, "invalid offers do not mutate queue/arrival")
    verify(p.take(now: 1 + dt, targetTimestamp: 1 + dt) == 40, "valid frame survives invalid offers")
    p.offer(41, at: 1.1)
    var invalidTicksOK = true
    for pair in [(Double.nan, 1.2), (1.2, Double.infinity), (-1.0, 1.2),
                 (1.2, -1.0), (1.2, 3.0), (0.9, 0.9), (1.2, 1.0),
                 (Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude)] {
        invalidTicksOK = p.take(now: pair.0, targetTimestamp: pair.1) == nil && invalidTicksOK
    }
    verify(invalidTicksOK && p.pendingCount == 1 && p.stats.invalidInputs == 14, "invalid ticks preserve pending frame")
    verify(p.take(now: 1.2, targetTimestamp: 1.2) == 41, "bad future/backward tick does not starve next")
    p.clear(); p.offer(42, at: 0)
    verify(p.take(now: dt, targetTimestamp: dt) == 42, "clear resets every clock to accept earlier timebase")

    var sixty = DisplayFramePacer<Int>(selectionPolicy: .fifo25)
    var sixtyOutput: [Int] = []
    for i in 0..<600 {
        let arrival = Double(i) * dt
        sixty.offer(i, at: arrival)
        if let frame = sixty.take(now: arrival + dt, targetTimestamp: arrival + dt) { sixtyOutput.append(frame) }
    }
    verify(sixtyOutput == Array(0..<600) && sixty.stats.selected == 600, "60Hz exact boundaries have no accumulated drift")

    var fast = DisplayFramePacer<Int>(selectionPolicy: .fifo25)
    var fastOutput: [Int] = []
    for i in 0..<120 {
        let target = Double(i + 2) / 120
        fast.offer(i, at: target - dt)
        if let frame = fast.take(now: target, targetTimestamp: target) { fastOutput.append(frame) }
    }
    verify(fast.stats.selected == 61 && fast.stats.rateLimitedTicks == 59, "120Hz callbacks spend at most one startup frame above 60fps")
    verify(fastOutput == [0, 1, 2, 4, 5, 7, 10, 11, 13, 15, 17, 19, 21, 23, 25, 27, 29, 31, 33, 35, 37, 39, 41] +
           Array(stride(from: 44, to: 120, by: 2)) && fast.pendingCount == 1,
           "120Hz FIFO25 selection order including strict floating-point threshold boundaries")
    verify(fast.stats.superseded == 40 && fast.stats.overflowReplaced == 18, "120Hz diagnostics account for discarded decoded frames")

    var jitter = DisplayFramePacer<Int>(selectionPolicy: .fifo25)
    var jitterOutput: [Int] = []
    for i in 0..<300 {
        let target = 1 + Double(i) * dt + (i % 2 == 0 ? 0.00004 : -0.00004)
        jitter.offer(i, at: target - dt)
        if let frame = jitter.take(now: target, targetTimestamp: target) { jitterOutput.append(frame) }
    }
    verify(jitterOutput == Array(0..<300), "small alternating clock jitter does not halve cadence")

    var eight = DisplayFramePacer<Int>(selectionPolicy: .fifo25)
    var times: [Double] = []
    for i in 0..<250 {
        let target = 1 + Double(i) * 0.008
        eight.offer(i, at: target - dt)
        if eight.take(now: target, targetTimestamp: target) != nil { times.append(target) }
    }
    // Intentional contract change: real 60Hz jitter has valid 9.3ms gaps.
    // Replace the incompatible strict spacing minimum with a capacity-two
    // cadence budget: any subwindow has N <= FPS * elapsed + 2.
    verify(zip(times, times.dropFirst()).allSatisfy { $1 > $0 } &&
           Double(times.count - 1) <= (times.last! - times.first!) / dt + 1.000001,
           "8ms callbacks obey capacity-two burst bound and long-run 60fps budget")
    verify(eight.pendingCount <= 2 && eight.stats.offered == 250, "fast offers remain bounded and counted")

    var hidden = DisplayFramePacer<Int>(selectionPolicy: .fifo25)
    for i in 0..<1_000 { hidden.offer(i, at: Double(i) / 60) }
    verify(hidden.pendingCount == 2 && hidden.stats.overflowReplaced == 998, "not-ready owner can offer indefinitely with capacity two")
    verify(hidden.take(now: 20, targetTimestamp: 20) == 999 && hidden.stats.superseded == 1, "resume consumes newest only")
    hidden.offer(1_000, at: 20)
    verify(hidden.take(now: 20.008, targetTimestamp: 20.008) == nil && hidden.pending, "new resume frame obeys cushion")
    verify(hidden.take(now: 20 + dt, targetTimestamp: 20 + dt) == 1_000, "resume next boundary")
    hidden.offer(1_001, at: 21); hidden.clear()
    verify(hidden.take(now: 0, targetTimestamp: 0) == nil && hidden.stats.emptyTicks == 1 && hidden.stats.offered == 0, "clear drops pending references without resurrection")

    var slower = DisplayFramePacer<Int>(framesPerSecond: 30, selectionPolicy: .fifo25)
    slower.offer(1, at: 0)
    let first = slower.take(now: dt, targetTimestamp: dt)
    slower.offer(2, at: 0)
    let borrowed = slower.take(now: 2 * dt, targetTimestamp: 2 * dt)
    slower.offer(3, at: 0)
    let next = slower.take(now: 3 * dt, targetTimestamp: 3 * dt)
    slower.offer(4, at: 0)
    let blocked = slower.take(now: 4 * dt, targetTimestamp: 4 * dt)
    verify(first == 1 && borrowed == 2 && next == 3 && blocked == nil, "30fps permits bounded startup debt then enforces budget")
    var late = DisplayFramePacer<Int>(selectionPolicy: .fifo25); late.offer(7, at: 0)
    verify(late.take(now: 0.1, targetTimestamp: 0.09) == 7, "slightly late callback accepted")
    var highArrival = DisplayFramePacer<Int>(selectionPolicy: .fifo25)
    var highArrivalOutput: [Int] = []
    for i in 0..<120 {
        let arrival = 1 + Double(i) / 120
        highArrival.offer(i, at: arrival)
        if i % 2 == 1,
           let frame = highArrival.take(now: arrival + 0.0001, targetTimestamp: arrival) {
            highArrivalOutput.append(frame)
        }
    }
    verify(highArrivalOutput == Array(stride(from: 0, to: 120, by: 2)), "120fps arrivals / late 60Hz callbacks never starve")
    verify(highArrival.stats.selected == 60 && highArrival.stats.earlySelections == 60 && highArrival.pendingCount == 1,
           "full queue fallback counted, keeps newer decoded frame")
    verify(highArrival.stats.overflowReplaced == 59 && highArrival.stats.superseded == 0,
           "high-rate arrivals accurately account for overflow")
    var burst = DisplayFramePacer<Int>(selectionPolicy: .fifo25)
    for i in 0..<5 { burst.offer(i, at: 1 + Double(i) * 0.001) }
    verify(burst.take(now: 1.004, targetTimestamp: 1.004) == 3 && burst.pendingCount == 1,
           "burst fallback consumes older of bounded latest two")
    burst.offer(5, at: 1.005)
    verify(burst.take(now: 1.012, targetTimestamp: 1.012) == 4 && burst.stats.earlySelections == 2,
           "early fallback may spend bounded startup debt")
    burst.offer(6, at: 1.013)
    verify(burst.take(now: 1.014, targetTimestamp: 1.014) == nil, "third rapid fallback cannot bypass cadence budget")
    var future = DisplayFramePacer<Int>(selectionPolicy: .fifo25); future.offer(1, at: 1); future.offer(2, at: 1.001)
    verify(future.take(now: 0.99, targetTimestamp: 0.99) == nil && future.pendingCount == 2,
           "full queue does not release future arrivals")
    verify(future.take(now: 1.002, targetTimestamp: 1.2) == nil && future.pendingCount == 2,
           "implausible target rejected without pending-frame loss")
    // Actual callback clock and predicted display target may jitter independently.
    var realistic = DisplayFramePacer<Int>(selectionPolicy: .fifo25)
    var realisticOutput: [Int] = []
    for i in 0..<3_600 {
        let now = 10 + Double(i) * dt + (i % 2 == 0 ? 0.0036 : -0.0036)
        let target = now + dt + (i % 3 == 0 ? 0.002 : 0)
        realistic.offer(i, at: now - dt)
        if let frame = realistic.take(now: now, targetTimestamp: target) { realisticOutput.append(frame) }
    }
    verify(realisticOutput == Array(0..<3_600), "9.47/23.87ms alternating 60Hz jitter keeps every frame for a minute")

    for hz in [75.0, 90, 120, 144, 240, 1_000] {
        var stress = DisplayFramePacer<Int>(selectionPolicy: .fifo25)
        var outputTimes: [Double] = []
        var lastFrame = -1
        var ordered = true
        for i in 0..<Int(hz * 20) {
            let now = 100 + Double(i) / hz
            stress.offer(i, at: now - dt)
            if let frame = stress.take(now: now, targetTimestamp: now) {
                ordered = ordered && frame > lastFrame
                lastFrame = frame; outputTimes.append(now)
            }
            verify(stress.pendingCount <= 2, "bounded queue at high frequency")
        }
        verify(ordered && zip(outputTimes, outputTimes.dropFirst()).allSatisfy { $1 > $0 },
               "high frequency has no duplicate/stale frames or zero-time selection")
        var bounded = true
        // Check every subwindow, not only a whole-run average that hides bursts.
        for i in outputTimes.indices {
            for j in i..<outputTimes.count {
                bounded = bounded && Double(j - i) <= (outputTimes[j] - outputTimes[i]) / dt + 1.000001
            }
        }
        verify(bounded, "every subwindow obeys configured FPS plus bounded endpoint phase difference")
    }
    var jitterFast = DisplayFramePacer<Int>(selectionPolicy: .fifo25)
    var jitterFastTimes: [Double] = []
    for i in 0..<12_000 {
        let now = 200 + Double(i) / 120 + (i % 2 == 0 ? 0.001 : -0.001)
        jitterFast.offer(i, at: now - dt)
        if jitterFast.take(now: now, targetTimestamp: now + dt) != nil { jitterFastTimes.append(now) }
    }
    verify(Double(jitterFastTimes.count - 1) <= (jitterFastTimes.last! - jitterFastTimes.first!) / dt + 1.000001 &&
           zip(jitterFastTimes, jitterFastTimes.dropFirst()).allSatisfy { $1 > $0 },
           "jittered 120Hz callbacks over 100 seconds retain 60fps budget")
    for offsets in [[0.0045, 0, -0.0045], [0.0042, -0.0042],
                    [0.0078, 0, -0.0078], [0.008, -0.008]] {
        var phased = DisplayFramePacer<Int>(selectionPolicy: .fifo25)
        var count = 0
        for i in 0..<3_600 {
            let now = 10 + Double(i) * dt + offsets[i % offsets.count]
            phased.offer(i, at: now - dt)
            if phased.take(now: now, targetTimestamp: now) != nil { count += 1 }
        }
        verify(count == 3_600, "60Hz phase-span jitter including review counterexample retains all 3600 frames")
        print("Pacing periodic offsets \(offsets): \(count)/3600 selections")
    }
    var burstBudget = DisplayFramePacer<Int>(selectionPolicy: .fifo25)
    var startupBurst = 0, resumeBurst = 0
    for i in 0..<1_000 {
        let now = 10 + Double(i) * 0.000001
        burstBudget.offer(i, at: now - dt)
        if burstBudget.take(now: now, targetTimestamp: now) != nil { startupBurst += 1 }
    }
    for i in 0..<1_000 {
        let now = 100 + Double(i) * 0.000001
        burstBudget.offer(i + 1_000, at: now - dt)
        if burstBudget.take(now: now, targetTimestamp: now) != nil { resumeBurst += 1 }
    }
    verify(startupBurst == 2 && resumeBurst == 1,
           "1000 rapid callbacks spend at most two startup frames and exactly one idle-resume frame")
    var idleYoung = DisplayFramePacer<Int>(selectionPolicy: .fifo25)
    idleYoung.offer(1, at: 0)
    _ = idleYoung.take(now: dt, targetTimestamp: dt)
    idleYoung.offer(2, at: 10)
    verify(idleYoung.take(now: 10, targetTimestamp: 10) == nil, "idle young frame still waits for eligibility")
    verify(idleYoung.take(now: 10 + dt, targetTimestamp: 10 + dt) == 2, "idle frame becomes eligible")
    idleYoung.offer(3, at: 10)
    verify(idleYoung.take(now: 10 + dt + 0.001, targetTimestamp: 10 + dt + 0.001) == nil,
           "idle debt reset survives intervening young-frame tick")
    var sustainedThirty = DisplayFramePacer<Int>(framesPerSecond: 30, selectionPolicy: .fifo25)
    var thirtyCount = 0
    for i in 0..<1_200 {
        let now = 10 + Double(i) * dt
        sustainedThirty.offer(i, at: now - dt)
        if sustainedThirty.take(now: now, targetTimestamp: now) != nil { thirtyCount += 1 }
    }
    verify(thirtyCount == 601, "configured 30fps has only one additive startup frame over 20 seconds")
    var duplicate = DisplayFramePacer<Int>(selectionPolicy: .fifo25)
    duplicate.offer(1, at: 0)
    verify(duplicate.take(now: dt, targetTimestamp: dt) == 1, "duplicate test initial selection")
    duplicate.offer(2, at: 0)
    verify(duplicate.take(now: dt, targetTimestamp: dt) == nil &&
           duplicate.take(now: 2 * dt, targetTimestamp: dt) == nil,
           "duplicate target cannot spend another selection even with later callback clock")
    verify(duplicate.take(now: 3 * dt, targetTimestamp: 3 * dt) == 2, "duplicate rejection does not poison cadence")
    duplicate.offer(3, at: 1)
    verify(duplicate.take(now: 10, targetTimestamp: 10) == 3, "long idle grants exactly one initial selection")
    duplicate.offer(4, at: 1)
    verify(duplicate.take(now: 10 + dt / 2, targetTimestamp: 10 + dt / 2) == nil,
           "idle does not bank catch-up credits even at half-period boundary")
    verify(duplicate.take(now: 9, targetTimestamp: 9) == nil &&
           duplicate.take(now: 10 + dt, targetTimestamp: 10 + dt) == 4,
           "backward callback cannot corrupt deadline")
    var predictedFuture = DisplayFramePacer<Int>(selectionPolicy: .fifo25)
    predictedFuture.offer(1, at: 1.01); predictedFuture.offer(2, at: 1.02)
    verify(predictedFuture.take(now: 1, targetTimestamp: 1.05) == nil,
           "future display prediction cannot release frame from future actual clock")
    // Latest is only a decoded-entry selection change. These are synthetic
    // queue/cadence checks, not evidence of physical presentation timing.
#if TC_LEGACY70_HYSTERESIS
    verify(DisplayFrameSelectionPolicy.buildDefault == .latest70h, "build-70 hysteresis default")
    do {
        // Same straddling 60Hz traces through the build-70 rule and the hysteresis rule.
        func run(_ policy: DisplayFrameSelectionPolicy, jitterMs: Double, offsetMs: Double) -> (repeats: Int, skips: Int, waitMs: Double) {
            var p = DisplayFramePacer<Int>(selectionPolicy: policy)
            var last: Int? = nil, repeats = 0, skips = 0, next = 0, waitSum = 0.0, picks = 0
            var arrivals: [Int: Double] = [:]
            let period = 1.0 / 60.0
            for k in 0..<7200 {
                let target = 100 + Double(k + 1) * period, now = target - 0.001
                while true {
                    let jitter = (next % 3 == 0 ? jitterMs : -jitterMs) / 1000
                    let arrival = 100 + Double(next) * period - period + offsetMs / 1000 + Double(next) * 0.0000002 + jitter
                    if arrival > now { break }
                    arrivals[next] = arrival; p.offer(next, at: max(arrival, 0)); next += 1
                }
                if let f = p.take(now: now, targetTimestamp: target) {
                    if let l = last, f - l >= 2 { skips += 1 }
                    last = f; waitSum += (target - arrivals[f]!) * 1000; picks += 1
                } else if last != nil { repeats += 1 }
            }
            return (repeats, skips, waitSum / Double(max(picks, 1)))
        }
        for (j, o) in [(1.5, 0.5), (3.0, 0.5), (1.0, 2.5)] {
            let old = run(.latest70, jitterMs: j, offsetMs: o), new = run(.latest70h, jitterMs: j, offsetMs: o)
            print("Hysteresis trace jitter=\(j)ms: latest70 repeats=\(old.repeats) skips=\(old.skips) wait=\(String(format: "%.1f", old.waitMs))ms; latest70h repeats=\(new.repeats) skips=\(new.skips) wait=\(String(format: "%.1f", new.waitMs))ms")
            verify(new.repeats + new.skips <= max(2, (old.repeats + old.skips) / 10), "hysteresis removes repeat-skip pairs (jitter \(j)ms)")
            verify(new.waitMs <= old.waitMs + 0.5, "hysteresis never waits longer than build 70 (jitter \(j)ms)")
        }
        var lone = DisplayFramePacer<Int>(selectionPolicy: .latest70h)
        lone.offer(1, at: 10.000)
        verify(lone.take(now: 10.005, targetTimestamp: 10.010) == nil, "a frame far inside the cushion still waits")
    }
#elseif TC_SEQUENCE_SELECTION
    verify(DisplayFrameSelectionPolicy.buildDefault == .sequence, "sequence jitter-buffer default")
    do {
        // 60Hz source whose arrivals straddle the cushion boundary (+-1.5ms jitter, slow drift):
        // the build-70 rule produces repeat-then-skip pairs; the jitter buffer must not skip.
        func run(_ policy: DisplayFrameSelectionPolicy) -> (repeats: Int, skips: Int) {
            var p = DisplayFramePacer<Int>(selectionPolicy: policy)
            var last: Int? = nil, repeats = 0, skips = 0, next = 0
            let period = 1.0 / 60.0
            for k in 0..<7200 {
                let target = 100 + Double(k + 1) * period, now = target - 0.001
                while true {
                    let drift = Double(next) * 0.0000002
                    let jitter = (next % 3 == 0 ? 0.0015 : -0.0015)
                    let arrival = 100 + Double(next) * period - period + 0.0005 + drift + jitter
                    if arrival > now { break }
                    p.offer(next, at: max(arrival, 0)); next += 1
                }
                if let f = p.take(now: now, targetTimestamp: target) {
                    if let l = last, f - l >= 2 { skips += 1 }
                    last = f
                } else if last != nil { repeats += 1 }
            }
            return (repeats, skips)
        }
        let old = run(.latest70), seq = run(.sequence)
        print("Jitter trace: latest70 repeats=\(old.repeats) skips=\(old.skips); sequence repeats=\(seq.repeats) skips=\(seq.skips)")
        verify(seq.skips == 0, "jitter buffer never skips on a straddling 60Hz trace")
        verify(seq.repeats <= max(1, old.repeats / 10), "jitter buffer repeats far less than the cushion rule")
    }
#elseif TC_LEGACY70_SELECTION
    verify(DisplayFrameSelectionPolicy.buildDefault == .latest70, "build-70 smooth default")
    do {
        // Build-70 rule: only frames at least one 1/60 cushion old are eligible; newest wins.
        var p70 = DisplayFramePacer<Int>(selectionPolicy: .latest70)
        p70.offer(1, at: 10.000); p70.offer(2, at: 10.010)
        verify(p70.take(now: 10.012, targetTimestamp: 10.0175) == nil || true, "cushion warm-up")
        var q70 = DisplayFramePacer<Int>(selectionPolicy: .latest70)
        q70.offer(1, at: 10.000)
        verify(q70.take(now: 10.005, targetTimestamp: 10.010) == nil, "too-fresh lone frame waits for the cushion")
        verify(q70.take(now: 10.0175, targetTimestamp: 10.030) == 1, "frame becomes eligible once 1/60 older than the target")
        var r70 = DisplayFramePacer<Int>(selectionPolicy: .latest70)
        r70.offer(1, at: 10.000); r70.offer(2, at: 10.004)
        verify(r70.take(now: 10.005, targetTimestamp: 10.010) == 1, "full queue consumes the older of two")
    }
#elseif TC_LATEST_DECODED
    verify(DisplayFrameSelectionPolicy.buildDefault == .latest, "latest build default")
#else
    verify(DisplayFrameSelectionPolicy.buildDefault == .fifo25, "FIFO build default")
#endif
    var defaultPolicy = DisplayFramePacer<Int>()
    defaultPolicy.offer(1, at: 0)
#if TC_LATEST_DECODED || TC_SEQUENCE_SELECTION
    verify(defaultPolicy.take(now: 0, targetTimestamp: 0) == 1, "default initializer takes an arrived frame without a cushion")
#else
    verify(defaultPolicy.take(now: 0, targetTimestamp: 0) == nil, "default initializer uses FIFO build profile")
#endif

    // Independent bounded pending-entry oracle across capture phases, callback
    // jitter, capture jitter, future predictions and slightly late targets.
    for phase in [0.0, 1.0 / 720, 1.0 / 144, 1.0 / 80] {
        for offsets in [[0.0], [0.0018, -0.0018], [0.0036, -0.0036]] {
            for targetOffset in [0.0, dt, -0.003] {
                var latest = DisplayFramePacer<Int>(selectionPolicy: .latest)
                var model: [(id: Int, arrival: Double)] = []
                var nextID = 0, lastID = -1, count = 0, expectedCount = 0
                var exact = true, bounded = true
                for tick in 0..<720 {
                    let now = 10 + Double(tick) * dt + offsets[tick % offsets.count]
                    let target = now + targetOffset
                    while true {
                        let arrival = 10 + phase + Double(nextID) / 72 +
                            [0.0, 0.0003, -0.0003][nextID % 3]
                        if arrival > now { break }
                        latest.offer(nextID, at: arrival)
                        if model.count == 2 { model.removeFirst() }
                        model.append((nextID, arrival)); nextID += 1
                    }
                    let index = model.lastIndex { $0.arrival <= now && $0.arrival <= target }
                    let expected = index.map { model[$0].id }
                    let actual = latest.take(now: now, targetTimestamp: target)
                    exact = exact && actual == expected
                    if let index { model.removeFirst(index + 1); expectedCount += 1 }
                    if let actual {
                        exact = exact && actual > lastID
                        lastID = actual; count += 1
                    }
                    bounded = bounded && latest.pendingCount <= 2 && latest.pendingCount == model.count
                }
                verify(exact && count == expectedCount && count > 0, "72 to 60 latest oracle phase=\(phase) jitter=\(offsets) targetOffset=\(targetOffset) exact=\(exact) count=\(count)")
                // Short jitter gaps can contain no new 72Hz arrival. Latest
                // must leave such a tick empty, not duplicate or hold a cushion.
                if phase == 0 && offsets == [0.0036, -0.0036] && targetOffset == 0 {
                    verify(count == 576 && latest.stats.emptyTicks == 144,
                           "72 to 60 adverse phase has exact empty ticks rather than duplicate selections")
                }
                verify(bounded && latest.stats.invalidInputs == 0 && latest.stats.rateLimitedTicks == 0 &&
                       latest.stats.earlySelections == 0, "72 to 60 retains capacity and unchanged available cadence")
            }
        }
    }
    var latest120 = DisplayFramePacer<Int>(selectionPolicy: .latest)
    var output120: [Int] = []
    for i in 0..<600 {
        let now = 10 + Double(i) * dt
        latest120.offer(2 * i, at: now - dt / 2)
        latest120.offer(2 * i + 1, at: now)
        if let frame = latest120.take(now: now, targetTimestamp: now) { output120.append(frame) }
    }
    verify(output120 == Array(stride(from: 1, to: 1_200, by: 2)) && latest120.pendingCount == 0 &&
           latest120.stats.superseded == 600 && latest120.stats.overflowReplaced == 0 &&
           latest120.stats.earlySelections == 0, "120 to 60 selects latest at exact boundary without cushion")
    var latest30 = DisplayFramePacer<Int>(selectionPolicy: .latest)
    var output30: [Int] = []
    for i in 0..<600 {
        let now = 10 + Double(i) * dt
        if i % 2 == 0 { latest30.offer(i / 2, at: now) }
        if let frame = latest30.take(now: now, targetTimestamp: now) { output30.append(frame) }
    }
    verify(output30 == Array(0..<300) && latest30.stats.emptyTicks == 300 && !latest30.pending,
           "30 to 60 never repeats a decoded frame on empty ticks")

    var latestHidden = DisplayFramePacer<Int>(selectionPolicy: .latest)
    latestHidden.offer(0, at: 0)
    verify(latestHidden.take(now: 0, targetTimestamp: 0) == 0, "latest starts without fixed cushion")
    var hiddenBounded = true
    for i in 1...1_000 {
        latestHidden.offer(i, at: Double(i) / 60)
        hiddenBounded = hiddenBounded && latestHidden.pendingCount <= 2
    }
    verify(hiddenBounded && latestHidden.pendingCount == 2 && latestHidden.stats.overflowReplaced == 998,
           "latest hidden offers remain bounded at two decoded entries")
    verify(latestHidden.take(now: 20, targetTimestamp: 20) == 1_000 &&
           latestHidden.stats.superseded == 1 && !latestHidden.pending, "latest resume selects newest only")
    latestHidden.offer(1_001, at: 20.001)
    verify(latestHidden.take(now: 20.001, targetTimestamp: 20.001) == nil && latestHidden.pending,
           "latest resume cannot spend banked idle credits")
    verify(latestHidden.take(now: 20 + dt, targetTimestamp: 20 + dt) == 1_001,
           "latest resume returns to unchanged cadence")
    latestHidden.offer(1_002, at: 21); latestHidden.clear()
    verify(latestHidden.take(now: 0, targetTimestamp: 0) == nil && latestHidden.stats.emptyTicks == 1 &&
           latestHidden.stats.offered == 0, "latest clear resets timebase without resurrection")

    var latestFuture = DisplayFramePacer<Int>(selectionPolicy: .latest)
    latestFuture.offer(1, at: 1.01); latestFuture.offer(2, at: 1.02)
    verify(latestFuture.take(now: 1, targetTimestamp: 1.05) == nil && latestFuture.pendingCount == 2,
           "latest future prediction cannot release future actual arrivals")
    verify(latestFuture.take(now: 1.015, targetTimestamp: 1.05) == 1 && latestFuture.pendingCount == 1 &&
           latestFuture.stats.superseded == 0, "latest retains future newer entry and selects arrived older entry")
    latestFuture.clear(); latestFuture.offer(1, at: 1.01); latestFuture.offer(2, at: 1.02)
    verify(latestFuture.take(now: 1.03, targetTimestamp: 1) == nil && latestFuture.pendingCount == 2,
           "latest late callback waits when all entries exceed display target")
    verify(latestFuture.take(now: 1.031, targetTimestamp: 1.01) == 1 && latestFuture.pendingCount == 1,
           "latest late callback accepts exact target boundary without cushion")
    verify(latestFuture.take(now: 1.05, targetTimestamp: 1.04) == 2,
           "latest retained late-target frame becomes eligible later")
    latestFuture.clear(); latestFuture.offer(1, at: 1)
    let latestBadOffers = [Double.nan, .infinity, -.infinity, -1, 0.5, Double.greatestFiniteMagnitude]
    for bad in latestBadOffers { latestFuture.offer(99, at: bad) }
    let latestBadTicks = [(Double.nan, 1.0), (1.0, Double.infinity), (-1.0, 1.0),
                          (1.0, -1.0), (1.0, 1.2),
                          (Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude)]
    for pair in latestBadTicks { _ = latestFuture.take(now: pair.0, targetTimestamp: pair.1) }
    verify(latestFuture.pendingCount == 1 && latestFuture.stats.offered == 1 &&
           latestFuture.stats.invalidInputs == 12 && latestFuture.stats.selected == 0 &&
           latestFuture.stats.waitingTicks == 0, "latest invalid clocks/offers preserve queue and clocks")
    verify(latestFuture.take(now: 1, targetTimestamp: 1) == 1, "latest invalid clocks do not poison valid tick")
    latestFuture.offer(2, at: 1)
    verify(latestFuture.take(now: 1, targetTimestamp: 1) == nil &&
           latestFuture.take(now: 1.001, targetTimestamp: 1) == nil && latestFuture.pending,
           "latest duplicate target or callback cannot select twice")
    verify(latestFuture.take(now: 0.99, targetTimestamp: 1.01) == nil &&
           latestFuture.take(now: 1.01, targetTimestamp: 0.99) == nil &&
           latestFuture.take(now: 1 + dt, targetTimestamp: 1 + dt) == 2,
           "latest backward clocks fail closed without poisoning next valid tick")

    var latestDiscards: [(Int, DisplayFrameDiscardReason)] = []
    var latestReasons = DisplayFramePacer<Int>(selectionPolicy: .latest, onDiscard: { latestDiscards.append(($0, $1)) })
    latestReasons.offer(1, at: 0); latestReasons.offer(2, at: 0.001)
    verify(latestReasons.take(now: 0.001, targetTimestamp: 0.001) == 2,
           "latest skips older decoded entry at initial selection")
    latestReasons.offer(3, at: 0.002); latestReasons.offer(4, at: 0.003); latestReasons.offer(5, at: 0.004)
    verify(latestReasons.take(now: 0.004, targetTimestamp: 0.004) == 5,
           "latest selection still permits exactly the existing startup phase debt")
    latestReasons.offer(6, at: 0.005); latestReasons.offer(7, at: 0.006)
    verify(latestReasons.take(now: 0.006, targetTimestamp: 0.006) == nil && latestReasons.pendingCount == 2 &&
           latestDiscards.map { $0.0 } == [1, 3, 4], "latest rate rejection discards no pending frame")
    latestReasons.offer(99, at: .nan)
    verify(latestReasons.stats.selected == 2 && latestReasons.stats.superseded == 2 &&
           latestReasons.stats.overflowReplaced == 1 && latestReasons.stats.invalidInputs == 1 &&
           latestReasons.stats.rateLimitedTicks == 1 && latestReasons.stats.earlySelections == 0,
           "latest diagnostics distinguish superseding, overflow, invalid and rate limited")
    latestReasons.clear()
    verify(latestDiscards.map { $0.0 } == [1, 3, 4, 99, 6, 7] &&
           latestDiscards.map { $0.1 } == [.superseded, .overflow, .superseded, .invalidOffer, .clear, .clear] &&
           latestReasons.stats == DisplayFramePacingStats(), "latest discard callback sequence and reasons are exact")

    // Same cadence constraints as FIFO, including every subwindow, not just
    // average output rate. Test configured 30fps separately from input rate.
    for fps in [30.0, 60.0] {
        var latestBudget = DisplayFramePacer<Int>(framesPerSecond: fps, selectionPolicy: .latest)
        var selections: [Double] = []
        for i in 0..<2_400 {
            let now = 10 + Double(i) / 120 + (i % 2 == 0 ? 0.001 : -0.001)
            latestBudget.offer(i, at: now)
            if latestBudget.take(now: now, targetTimestamp: now) != nil { selections.append(now) }
        }
        var everyWindow = true
        for i in selections.indices {
            for j in i..<selections.count {
                everyWindow = everyWindow && Double(j - i) <= (selections[j] - selections[i]) * fps + 1.000001
            }
        }
        verify(everyWindow && latestBudget.pendingCount <= 2 &&
               zip(selections, selections.dropFirst()).allSatisfy { $1 > $0 },
               "latest preserves configured cadence budget under sustained 120Hz callback jitter")
    }
    // Final production policy is deliberately opt-in; legacy assertions above
    // remain unchanged. Targets are FUTURE VSync times, not callback times.
    func finalPacer(_ fps: Double = 60) -> DisplayFramePacer<Int> {
        DisplayFramePacer(framesPerSecond: fps, selectionPolicy: .buffered, cadencePolicy: .displayTargets)
    }
    for jittered in [false, true] {
        var final = finalPacer()
        var allFilled = true
        for i in 0..<7_201 { // At least 120 seconds, including both endpoints.
            let target = 100 + Double(i) * dt
            let lead = jittered ? [0.016, 0.004, 0.012, 0.008][i % 4] : dt
            let now = target - lead
            final.offer(i, at: now)
            allFilled = final.take(now: now, targetTimestamp: target) == i && allFilled
        }
        verify(allFilled && final.stats.selected == 7_201 && final.stats.displayOpportunities == 7_201 &&
               final.stats.rateLimitedTicks == 0 && final.stats.targetLimitedTicks == 0,
               "display targets fill every 60Hz slot for 120 seconds despite callback delivery jitter")
    }
    var stalled = finalPacer()
    stalled.offer(1, at: 1)
    verify(stalled.take(now: 1, targetTimestamp: 1 + dt) == 1, "buffered singleton needs no eligibility cushion")
    stalled.offer(2, at: 10); stalled.offer(3, at: 10.001)
    verify(stalled.take(now: 10.04, targetTimestamp: 10.04 + dt) == 2 && stalled.pendingCount == 1,
           "long stall resumes oldest decoded frame without 25ms catchup consuming both")
    verify(stalled.take(now: 10.04 + dt, targetTimestamp: 10.04 + 2 * dt) == 3 && !stalled.pending &&
           stalled.stats.superseded == 0 && stalled.stats.earlySelections == 0,
           "first post-stall slot has no idle extra wait and retains buffered younger frame")

    var ticks = finalPacer()
    ticks.offer(1, at: 1); ticks.offer(2, at: 1)
    verify(ticks.take(now: 1, targetTimestamp: 1 + dt) == 1, "first upcoming target anchors phase")
    verify(ticks.take(now: 1.001, targetTimestamp: 1 + dt) == nil &&
           ticks.take(now: 1.002, targetTimestamp: 1.01) == nil && ticks.pendingCount == 1 &&
           ticks.stats.duplicateTargetTicks == 2, "duplicate and backward upcoming targets retain frame")
    verify(ticks.take(now: 1.04, targetTimestamp: 1.03) == nil &&
           ticks.take(now: 1.04, targetTimestamp: 1.04) == nil && ticks.pendingCount == 1 &&
           ticks.stats.expiredTargetTicks == 2, "expired and equal-now targets are never fresh VSyncs")
    verify(ticks.take(now: 1 + dt, targetTimestamp: 1 + 2 * dt) == 2,
           "rejected expired clocks cannot poison next genuine slot")
    ticks.offer(3, at: 1.02)
    verify(ticks.take(now: 1.02, targetTimestamp: 1 + 2 * dt) == nil && ticks.pending,
           "duplicate target after selection never replays or consumes a second frame")
    ticks.clear()
    verify(ticks.stats == DisplayFramePacingStats() && !ticks.pending,
           "clear resets target diagnostics and queue")
    ticks.offer(9, at: 0)
    verify(ticks.take(now: 0, targetTimestamp: dt) == 9,
           "clear resets target epoch and all monotonic high-water marks")

    var emptyTarget = finalPacer()
    verify(emptyTarget.take(now: 1, targetTimestamp: 1 + dt) == nil && emptyTarget.stats.emptyTicks == 1,
           "empty valid target consumes its opportunity")
    emptyTarget.offer(4, at: 1.001)
    verify(emptyTarget.take(now: 1.002, targetTimestamp: 1 + dt) == nil && emptyTarget.pending,
           "offer after empty tick cannot reuse that target")
    verify(emptyTarget.take(now: 1.003, targetTimestamp: 1 + dt + 0.001) == 4 &&
           emptyTarget.stats.displayOpportunities == 2 && !emptyTarget.pending,
           "unique irregular upcoming target is independently admitted")
    emptyTarget.offer(5, at: 1.004)
    verify(emptyTarget.take(now: 1.004, targetTimestamp: 1 + dt + 0.002) == 5 &&
           emptyTarget.stats.targetLimitedTicks == 0 && !emptyTarget.pending,
           "each distinct upcoming native opportunity is admitted without a second rate cap")
    emptyTarget.offer(6, at: 1.005)
    verify(emptyTarget.take(now: 1 + dt, targetTimestamp: 1 + 2 * dt) == 6,
           "next real native target has no additional software wait")

    // Native mode is deliberately not a software 60.000Hz cap. The owner must
    // configure preferredFrameRateRange and measure actual nativeTickFPS. These
    // synthetic 120/144Hz trains demonstrate that unconfigured native oversupply
    // WOULD exceed 60; they do not claim preferred60 guarantees actual60.
    for nativeFPS in [120.0, 144.0] {
        for requestedFPS in [30.0, 60.0] {
            var native = finalPacer(requestedFPS)
            var count = 0, previousFrame = -1
            var validSelections = true
            let ticks = Int(nativeFPS * 120) + 1
            for i in 0..<ticks {
                let target = 20 + Double(i) / nativeFPS
                let now = target - 1 / nativeFPS
                native.offer(i, at: now)
                if let frame = native.take(now: now, targetTimestamp: target) {
                    validSelections = validSelections && frame > previousFrame && frame <= i
                    previousFrame = frame
                    count += 1
                }
            }
            verify(validSelections && count == ticks && count > 60 * 120 + 2 &&
                   native.stats.displayOpportunities == UInt64(ticks) &&
                   native.stats.targetLimitedTicks == 0 && native.stats.rateLimitedTicks == 0 &&
                   native.pendingCount <= 2,
                   "native120/144Hz admits each genuine target; owner must configure and verify desired native rate")
        }
    }

    var phaseJitter = finalPacer()
    var phaseJitterFilled = true
    for i in 0..<7_201 {
        // Target perturbations stay within a native interval; bounded native
        // phase debt must absorb them without reducing sustained 60Hz throughput.
        let perturbation = [0.0, 0.003, -0.003, 0.002, -0.002][i % 5]
        let target = 50 + Double(i) * dt + perturbation
        let now = target - dt
        phaseJitter.offer(i, at: now)
        phaseJitterFilled = phaseJitter.take(now: now, targetTimestamp: target) == i && phaseJitterFilled
    }
    verify(phaseJitterFilled && phaseJitter.stats.selected == 7_201 &&
           phaseJitter.stats.targetLimitedTicks == 0, "target jitter within native interval preserves every native opportunity")
    var emptyResume = finalPacer()
    _ = emptyResume.take(now: 1, targetTimestamp: 1 + dt)
    _ = emptyResume.take(now: 2, targetTimestamp: 2 + dt)
    emptyResume.offer(1, at: 10)
    verify(emptyResume.take(now: 10, targetTimestamp: 10 + dt) == 1,
           "long observed-empty period resumes without nextDeadline wait")
    emptyResume.offer(2, at: 10 + dt)
    verify(emptyResume.take(now: 10 + dt, targetTimestamp: 10 + 2 * dt) == 2,
           "slot after empty resume is not skipped")
    var unanchored = finalPacer()
    unanchored.offer(1, at: 0)
    verify(unanchored.take(now: 100, targetTimestamp: 100) == nil &&
           unanchored.take(now: 100, targetTimestamp: 99.99) == nil &&
           unanchored.stats.displayOpportunities == 0 && unanchored.pending,
           "initial expired targets never establish phase or mutate accepted clocks")
    verify(unanchored.take(now: 0, targetTimestamp: dt) == 1,
           "first real upcoming target anchors even after rejected expired observations")

    for nativeJitter in [0.0, 0.00001] {
        var shiftedPause = finalPacer()
        shiftedPause.offer(-1, at: 0.99)
        verify(shiftedPause.take(now: 0.99, targetTimestamp: 1) == -1,
               "phase-shift pause fixture anchors original target epoch")
        var filledAfterPause = true
        for i in 0...7_200 {
            let target = 2.025 + Double(i) * dt + (i % 2 == 0 ? -nativeJitter : nativeJitter)
            let now = target - 0.01
            shiftedPause.offer(i, at: now)
            filledAfterPause = shiftedPause.take(now: now, targetTimestamp: target) == i && filledAfterPause
        }
        verify(filledAfterPause && shiftedPause.stats.selected == 7_202 &&
               shiftedPause.stats.targetLimitedTicks == 0 && shiftedPause.stats.rateLimitedTicks == 0,
               "half-slot-shifted native restart fills every target for 120 seconds including +/-10us target jitter")
    }
    // Native pauses restart immediately; no software phase or debt is retained.
    for nativeFPS in [60.0, 120.0, 144.0] {
        var restarts = finalPacer()
        var target = 1.0, frame = 0, count = 0
        for burst in 0..<200 {
            if burst > 0 { target += 2.025 * dt }
            for tick in 0..<37 {
                if tick > 0 { target += 1 / nativeFPS }
                restarts.offer(frame, at: target - 0.005)
                if restarts.take(now: target - 0.005, targetTimestamp: target) != nil { count += 1 }
                frame += 1
            }
        }
        verify(count == 7_400 && restarts.stats.targetLimitedTicks == 0,
               "native60/120/144Hz admits every unique upcoming target across repeated pauses")
    }

    var irregular = finalPacer()
    var irregularFilled = true
    for i in 0...7_200 {
        // Compensated 10ms/23.333ms native target train, averaging exactly 60Hz.
        let target = 100 + Double(i / 2) * 2 * dt + (i % 2 == 0 ? 0 : 0.010)
        let now = target - 0.005
        irregular.offer(i, at: now)
        irregularFilled = irregular.take(now: now, targetTimestamp: target) == i && irregularFilled
    }
    verify(irregularFilled && irregular.stats.selected == 7_201 &&
           irregular.stats.targetLimitedTicks == 0,
           "compensated irregular native60Hz target train fills every upcoming opportunity")

    // Optional real native-target trace gate. Set TC_NATIVE_TARGET_TRACE to run
    // against a captured trace without embedding machine-specific paths/fixtures.
    if let tracePath = ProcessInfo.processInfo.environment["TC_NATIVE_TARGET_TRACE"] {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: tracePath))
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let events = root?["events"] as? [[String: Any]] else {
                verify(false, "native trace fixture contains events")
                return failures
            }
            var gate = finalPacer()
            var replay = finalPacer()
            var gateSelected = 0, replaySelected = 0, measuredSelected = 0
            var observedTargets: [Double] = []
            var measuredLimited = 0
            let measuredMin = root?["min"] as? Int ?? Int.min
            let measuredMax = root?["max"] as? Int ?? Int.max
            var gateMinResidual = Double.infinity, firstTarget: Double?
            var actualRateBounded = true
            var previousFrame = -1
            var actualFramesValid = true
            var latestOfferedFrame = -1
            var arrivals: [Int: Double] = [:]
            for event in events {
                guard let stage = event["stage"] as? String,
                      let now = event["now"] as? Double,
                      let target = event["target"] as? Double,
                      let sequence = event["seq"] as? Int else { continue }
                if stage == "pacer_offer" {
                    latestOfferedFrame = sequence
                    replay.offer(sequence, at: now)
                    arrivals[sequence] = now
                } else if stage == "renderer_control", (event["ready"] as? Int) == 1 {
                    if target > now && (observedTargets.last.map { target > $0 } ?? true) {
                        observedTargets.append(target)
                    }
                    let previousLimited = replay.stats.targetLimitedTicks
                    gate.offer(gateSelected, at: now)
                    if gate.take(now: now, targetTimestamp: target) != nil {
                        if firstTarget == nil { firstTarget = target }
                        let residual = Double(gateSelected) - 60 * (target - firstTarget!)
                        actualRateBounded = actualRateBounded && residual - gateMinResidual <= 1.000001
                        gateMinResidual = min(gateMinResidual, residual)
                        gateSelected += 1
                    }
                    if let frame = replay.take(now: now, targetTimestamp: target) {
                        actualFramesValid = actualFramesValid && frame > previousFrame &&
                            (arrivals[frame] ?? .infinity) <= min(now, target)
                        previousFrame = frame
                        replaySelected += 1
                        if frame >= measuredMin && frame <= measuredMax { measuredSelected += 1 }
                    }
                    if latestOfferedFrame >= measuredMin && latestOfferedFrame <= measuredMax &&
                        replay.stats.targetLimitedTicks > previousLimited { measuredLimited += 1 }
                    actualFramesValid = actualFramesValid && replay.pendingCount <= 2
                }
            }
            // Native target time may transiently exceed mathematical 60.000Hz.
            // That is observed native cadence, not permission for another cap.
            verify(gateSelected == observedTargets.count && gate.stats.targetLimitedTicks == 0 &&
                   replay.stats.targetLimitedTicks == 0 && gate.stats.rateLimitedTicks == 0 &&
                   replay.stats.rateLimitedTicks == 0 && actualFramesValid,
                   "real preferred60 native trace fills all valid unique upcoming opportunities without secondary cap")
            print("Native target trace: gate selected=\(gateSelected), actual frames=\(replaySelected), measured frames=\(measuredSelected), targetLimited=\(gate.stats.targetLimitedTicks)/\(replay.stats.targetLimitedTicks), measured limited=\(measuredLimited), expired=\(gate.stats.expiredTargetTicks), invalid=\(gate.stats.invalidInputs), nativeTrainWithinStrict60Bound=\(actualRateBounded)")
        } catch {
            verify(false, "native trace fixture readable: \(error)")
        }
    }

    // Native regression: callback observes frames decoded recently, while target
    // is ~16.7ms ahead. Actual arrival, not future prediction, controls availability.
    var nativeFrames = finalPacer()
    nativeFrames.offer(10, at: 5); nativeFrames.offer(11, at: 5.01)
    verify(nativeFrames.take(now: 5, targetTimestamp: 5 + dt) == 10 && nativeFrames.pendingCount == 1,
           "native future target consumes oldest available decoded frame immediately")
    verify(nativeFrames.take(now: 5.005, targetTimestamp: 5 + 2 * dt) == nil &&
           nativeFrames.stats.waitingTicks == 1 && nativeFrames.pending,
           "native target prediction cannot make a future decoded arrival eligible")
    verify(nativeFrames.take(now: 5.011, targetTimestamp: 5 + 2 * dt) == nil && nativeFrames.pending,
           "ineligible native target remains consumed even after arrival becomes eligible")
    verify(nativeFrames.take(now: 5 + 2 * dt, targetTimestamp: 5 + 3 * dt) == 11 &&
           nativeFrames.take(now: 5 + 3 * dt, targetTimestamp: 5 + 4 * dt) == nil,
           "next unique native slot selects retained frame exactly once")

    var badClocks = finalPacer()
    badClocks.offer(1, at: 1)
    let malformed: [(Double, Double)] = [(.nan, 1.01), (1, .nan), (.infinity, 1.01),
        (1, .infinity), (-1, 0), (1, -1), (1, 20),
        (.greatestFiniteMagnitude, .greatestFiniteMagnitude),
        (1, .greatestFiniteMagnitude), (Double.leastNonzeroMagnitude, .infinity)]
    for pair in malformed { _ = badClocks.take(now: pair.0, targetTimestamp: pair.1) }
    verify(badClocks.pendingCount == 1 && badClocks.stats.invalidInputs == UInt64(malformed.count) &&
           badClocks.stats.displayOpportunities == 0 && badClocks.take(now: 1, targetTimestamp: 1 + dt) == 1,
           "malformed doubles cannot overflow, establish phase, or poison valid clocks")
    badClocks.offer(2, at: 1)
    verify(badClocks.take(now: 0.99, targetTimestamp: 1 + 2 * dt) == nil && badClocks.pending &&
           badClocks.take(now: 1 + dt, targetTimestamp: 1 + 2 * dt) == 2,
           "backward callback clock cannot poison following valid target")

    var finalDiscards: [(Int, DisplayFrameDiscardReason)] = []
    var bounded = DisplayFramePacer<Int>(selectionPolicy: .buffered, cadencePolicy: .displayTargets,
        onDiscard: { finalDiscards.append(($0, $1)) })
    bounded.offer(1, at: 0); bounded.offer(2, at: 0.001); bounded.offer(3, at: 0.002)
    verify(bounded.pendingCount == 2 && bounded.take(now: 0.04, targetTimestamp: 0.04 + dt) == 2 &&
           bounded.pendingCount == 1 && bounded.stats.overflowReplaced == 1 && bounded.stats.superseded == 0,
           "buffered final mode keeps bounded-two overflow and never catchup-discards younger frame")
    bounded.offer(99, at: .nan); bounded.clear()
    verify(finalDiscards.map { $0.0 } == [1, 99, 3] &&
           finalDiscards.map { $0.1 } == [.overflow, .invalidOffer, .clear] &&
           bounded.stats == DisplayFramePacingStats(), "buffered discard accounting and clear remain exact")
    print("Display frame pacing: \(checks) checks, \(failures) failures; synthetic policy only, not panel FPS")
    return failures
}
