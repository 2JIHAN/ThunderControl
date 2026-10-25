/// Pure deterministic policy tests: no OS, GUI, timers or panel-rate claims.
func runDisplayFramePacingTests() -> Int {
    var checks = 0, failures = 0
    func verify(_ value: Bool, _ name: String) {
        checks += 1
        if !value { failures += 1; print("FAIL DisplayFramePacing: \(name)") }
    }
    let dt = 1.0 / 60.0
    var p = DisplayFramePacer<Int>()
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
    verify(p.take(now: dt, targetTimestamp: dt) == 31 && p.stats.offered == 2, "equal arrivals newest wins")

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

    var sixty = DisplayFramePacer<Int>()
    var sixtyOutput: [Int] = []
    for i in 0..<600 {
        let arrival = Double(i) * dt
        sixty.offer(i, at: arrival)
        if let frame = sixty.take(now: arrival + dt, targetTimestamp: arrival + dt) { sixtyOutput.append(frame) }
    }
    verify(sixtyOutput == Array(0..<600) && sixty.stats.selected == 600, "60Hz exact boundaries have no accumulated drift")

    var fast = DisplayFramePacer<Int>()
    var fastOutput: [Int] = []
    for i in 0..<120 {
        let target = Double(i + 2) / 120
        fast.offer(i, at: target - dt)
        if let frame = fast.take(now: target, targetTimestamp: target) { fastOutput.append(frame) }
    }
    verify(fast.stats.selected == 61 && fast.stats.rateLimitedTicks == 59, "120Hz callbacks spend at most one startup frame above 60fps")
    verify(fastOutput == [0, 1] + Array(stride(from: 2, to: 120, by: 2)) && fast.pendingCount == 1, "120Hz selects latest decoded frame in order")
    verify(fast.stats.superseded == 58 && fast.stats.overflowReplaced == 0, "120Hz diagnostics account for discarded decoded frames")

    var jitter = DisplayFramePacer<Int>()
    var jitterOutput: [Int] = []
    for i in 0..<300 {
        let target = 1 + Double(i) * dt + (i % 2 == 0 ? 0.00004 : -0.00004)
        jitter.offer(i, at: target - dt)
        if let frame = jitter.take(now: target, targetTimestamp: target) { jitterOutput.append(frame) }
    }
    verify(jitterOutput == Array(0..<300), "small alternating clock jitter does not halve cadence")

    var eight = DisplayFramePacer<Int>()
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

    var hidden = DisplayFramePacer<Int>()
    for i in 0..<1_000 { hidden.offer(i, at: Double(i) / 60) }
    verify(hidden.pendingCount == 2 && hidden.stats.overflowReplaced == 998, "not-ready owner can offer indefinitely with capacity two")
    verify(hidden.take(now: 20, targetTimestamp: 20) == 999 && hidden.stats.superseded == 1, "resume consumes newest only")
    hidden.offer(1_000, at: 20)
    verify(hidden.take(now: 20.008, targetTimestamp: 20.008) == nil && hidden.pending, "new resume frame obeys cushion")
    verify(hidden.take(now: 20 + dt, targetTimestamp: 20 + dt) == 1_000, "resume next boundary")
    hidden.offer(1_001, at: 21); hidden.clear()
    verify(hidden.take(now: 0, targetTimestamp: 0) == nil && hidden.stats.emptyTicks == 1 && hidden.stats.offered == 0, "clear drops pending references without resurrection")

    var slower = DisplayFramePacer<Int>(framesPerSecond: 30)
    slower.offer(1, at: 0)
    let first = slower.take(now: dt, targetTimestamp: dt)
    slower.offer(2, at: 0)
    let borrowed = slower.take(now: 2 * dt, targetTimestamp: 2 * dt)
    slower.offer(3, at: 0)
    let next = slower.take(now: 3 * dt, targetTimestamp: 3 * dt)
    slower.offer(4, at: 0)
    let blocked = slower.take(now: 4 * dt, targetTimestamp: 4 * dt)
    verify(first == 1 && borrowed == 2 && next == 3 && blocked == nil, "30fps permits bounded startup debt then enforces budget")
    var late = DisplayFramePacer<Int>(); late.offer(7, at: 0)
    verify(late.take(now: 0.1, targetTimestamp: 0.09) == 7, "slightly late callback accepted")
    var highArrival = DisplayFramePacer<Int>()
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
    var burst = DisplayFramePacer<Int>()
    for i in 0..<5 { burst.offer(i, at: 1 + Double(i) * 0.001) }
    verify(burst.take(now: 1.004, targetTimestamp: 1.004) == 3 && burst.pendingCount == 1,
           "burst fallback consumes older of bounded latest two")
    burst.offer(5, at: 1.005)
    verify(burst.take(now: 1.012, targetTimestamp: 1.012) == 4 && burst.stats.earlySelections == 2,
           "early fallback may spend bounded startup debt")
    burst.offer(6, at: 1.013)
    verify(burst.take(now: 1.014, targetTimestamp: 1.014) == nil, "third rapid fallback cannot bypass cadence budget")
    var future = DisplayFramePacer<Int>(); future.offer(1, at: 1); future.offer(2, at: 1.001)
    verify(future.take(now: 0.99, targetTimestamp: 0.99) == nil && future.pendingCount == 2,
           "full queue does not release future arrivals")
    verify(future.take(now: 1.002, targetTimestamp: 1.2) == nil && future.pendingCount == 2,
           "implausible target rejected without pending-frame loss")
    // Actual callback clock and predicted display target may jitter independently.
    var realistic = DisplayFramePacer<Int>()
    var realisticOutput: [Int] = []
    for i in 0..<3_600 {
        let now = 10 + Double(i) * dt + (i % 2 == 0 ? 0.0036 : -0.0036)
        let target = now + dt + (i % 3 == 0 ? 0.002 : 0)
        realistic.offer(i, at: now - dt)
        if let frame = realistic.take(now: now, targetTimestamp: target) { realisticOutput.append(frame) }
    }
    verify(realisticOutput == Array(0..<3_600), "9.47/23.87ms alternating 60Hz jitter keeps every frame for a minute")

    for hz in [75.0, 90, 120, 144, 240, 1_000] {
        var stress = DisplayFramePacer<Int>()
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
    var jitterFast = DisplayFramePacer<Int>()
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
        var phased = DisplayFramePacer<Int>()
        var count = 0
        for i in 0..<3_600 {
            let now = 10 + Double(i) * dt + offsets[i % offsets.count]
            phased.offer(i, at: now - dt)
            if phased.take(now: now, targetTimestamp: now) != nil { count += 1 }
        }
        verify(count == 3_600, "60Hz phase-span jitter including review counterexample retains all 3600 frames")
        print("Pacing periodic offsets \(offsets): \(count)/3600 selections")
    }
    var burstBudget = DisplayFramePacer<Int>()
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
    var idleYoung = DisplayFramePacer<Int>()
    idleYoung.offer(1, at: 0)
    _ = idleYoung.take(now: dt, targetTimestamp: dt)
    idleYoung.offer(2, at: 10)
    verify(idleYoung.take(now: 10, targetTimestamp: 10) == nil, "idle young frame still waits for eligibility")
    verify(idleYoung.take(now: 10 + dt, targetTimestamp: 10 + dt) == 2, "idle frame becomes eligible")
    idleYoung.offer(3, at: 10)
    verify(idleYoung.take(now: 10 + dt + 0.001, targetTimestamp: 10 + dt + 0.001) == nil,
           "idle debt reset survives intervening young-frame tick")
    var sustainedThirty = DisplayFramePacer<Int>(framesPerSecond: 30)
    var thirtyCount = 0
    for i in 0..<1_200 {
        let now = 10 + Double(i) * dt
        sustainedThirty.offer(i, at: now - dt)
        if sustainedThirty.take(now: now, targetTimestamp: now) != nil { thirtyCount += 1 }
    }
    verify(thirtyCount == 601, "configured 30fps has only one additive startup frame over 20 seconds")
    var duplicate = DisplayFramePacer<Int>()
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
    var predictedFuture = DisplayFramePacer<Int>()
    predictedFuture.offer(1, at: 1.01); predictedFuture.offer(2, at: 1.02)
    verify(predictedFuture.take(now: 1, targetTimestamp: 1.05) == nil,
           "future display prediction cannot release frame from future actual clock")
    print("Display frame pacing: \(checks) checks, \(failures) failures; synthetic policy only, not panel FPS")
    return failures
}
