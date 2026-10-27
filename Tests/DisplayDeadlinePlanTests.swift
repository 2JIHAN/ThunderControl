/// Standalone deterministic checks. No frameworks, display, timers, or fabricated
/// decoded frames: commits below model an owner that really accepted an enqueue.
@discardableResult
func runDisplayDeadlinePlanTests() -> Int {
    var failures = 0
    var checks = 0
    func expect(_ value: Bool, _ name: String) {
        checks += 1
        if !value { failures += 1; print("FAIL: \(name)") }
    }
    expect(DisplayDeadlinePlan.wakeDelay(now: 1, retirement: 0.9, hasWaiting: true,
                                         waitingForReadiness: false) == nil, "past retirement never polls")
    expect(DisplayDeadlinePlan.wakeDelay(now: 1, retirement: 1, hasWaiting: true,
                                         waitingForReadiness: false) == nil, "due retirement never polls")
    expect(DisplayDeadlinePlan.wakeDelay(now: 1, retirement: 2, hasWaiting: true,
                                         waitingForReadiness: true) == nil, "readiness pending blocks wake")
    expect(DisplayDeadlinePlan.wakeDelay(now: 1, retirement: 0.9, hasWaiting: true,
                                         waitingForReadiness: true) == nil, "backpressure plus past retirement cannot spin")
    expect(DisplayDeadlinePlan.wakeDelay(now: 1, retirement: 2, hasWaiting: false,
                                         waitingForReadiness: false) == nil, "no waiting work no wake")
    expect(DisplayDeadlinePlan.wakeDelay(now: 1, retirement: nil, hasWaiting: true,
                                         waitingForReadiness: false) == nil, "missing retirement no wake")
    expect(DisplayDeadlinePlan.wakeDelay(now: 1, retirement: 1.25, hasWaiting: true,
                                         waitingForReadiness: false) == 0.25, "positive future wake")
    expect(DisplayDeadlinePlan.wakeDelay(now: 1, retirement: Double(1).nextUp, hasWaiting: true,
                                         waitingForReadiness: false) == Double(1).ulp, "tiny positive delay not rounded to zero")
    for bad in [Double.nan, Double.infinity, -Double.infinity] {
        expect(DisplayDeadlinePlan.wakeDelay(now: bad, retirement: 2, hasWaiting: true,
                                             waitingForReadiness: false) == nil, "invalid wake now")
        expect(DisplayDeadlinePlan.wakeDelay(now: 1, retirement: bad, hasWaiting: true,
                                             waitingForReadiness: false) == nil, "invalid wake retirement")
    }
    expect(DisplayDeadlinePlan.wakeDelay(now: -Double.greatestFiniteMagnitude,
                                         retirement: Double.greatestFiniteMagnitude,
                                         hasWaiting: true, waitingForReadiness: false) == nil,
           "overflowing wake difference rejected")
    let p = 1.0 / 60.0
    var plan = DisplayDeadlinePlan()
    expect(plan.observe(now: 0, target: p, period: p), "initial observation")
    let first = plan.nextTarget(now: 0)!
    expect(abs(first - 2 * p) < 1e-12, "prequeue beyond next native opportunity")
    expect(plan.nextTarget(now: 0) == first && plan.futureCount == 0, "offers do not consume")
    expect(plan.commit(target: first, now: 0), "first commit")
    expect(!plan.commit(target: first, now: 0), "double commit rejected")
    let second = plan.nextTarget(now: 0)!
    expect(plan.commit(target: second, now: 0), "second commit")
    expect(plan.futureCount == 2 && plan.nextTarget(now: 0) == nil, "exactly two future reservations")
    expect(!plan.commit(target: second + p, now: 0), "unoffered target rejected")
    expect(plan.nextTarget(now: -p) == nil && plan.futureCount == 2, "backwards now cannot retire")
    expect(!plan.observe(now: 0, target: p, period: p), "duplicate observation rejected")
    expect(!plan.observe(now: 0, target: p / 2, period: p), "backwards observation rejected")
    _ = plan.nextTarget(now: first)
    expect(plan.futureCount == 1, "native exact expiry retires only due slot")
    expect(!plan.commit(target: first, now: first), "expired PTS cannot be reused")
    expect(plan.nextTarget(now: 0.055) != nil && plan.futureCount == 0, "missed native observation allows bounded prequeue")
    expect(plan.nextTarget(now: 0.099) == nil, "target cannot exceed observation lease")
    expect(plan.nextTarget(now: 1000) == nil, "long idle no extrapolation")
    expect(plan.observe(now: 1000, target: 1000 + p, period: p), "fresh observation after idle")
    expect(plan.nextTarget(now: 1000) != nil, "fresh native observation resumes")

    var missed = DisplayDeadlinePlan()
    _ = missed.observe(now: 0, target: p, period: p)
    let queuedA = missed.nextTarget(now: 0)!
    _ = missed.commit(target: queuedA, now: 0)
    let queuedB = missed.nextTarget(now: 0)!
    _ = missed.commit(target: queuedB, now: 0)
    expect(missed.nextRetirement == queuedA, "earliest credit release exposed")
    expect(missed.nextTarget(now: 1.5 * p) == nil && missed.futureCount == 2,
           "both prequeued slots survive missed native observation")
    expect(missed.observe(now: 1.5 * p, target: 2.05 * p, period: p), "ordinary noisy phase accepted")
    expect(missed.futureCount == 2, "phase observation leaves queued slots intact")
    _ = missed.nextTarget(now: queuedA)
    expect(missed.futureCount == 1, "first original immutable PTS expires exactly")
    _ = missed.nextTarget(now: queuedB)
    expect(missed.futureCount == 0, "second original immutable PTS expires exactly")
    let resumed = missed.nextTarget(now: queuedB)!
    expect(resumed > queuedB && abs(resumed / p - (resumed / p).rounded()) < 1e-8,
           "ordinary noise preserves original grid and reserved highwater")

    plan.reset()
    expect(plan.generation == 1 && plan.period == nil && !plan.needsReset, "reset epoch")
    _ = plan.observe(now: 0, target: p, period: p)
    _ = plan.commit(target: plan.nextTarget(now: 0)!, now: 0)
    expect(!plan.observe(now: p, target: 2 * p, period: 1.0 / 72), "mode change rejected outstanding")
    expect(plan.needsReset && plan.futureCount == 1, "mode change requests owner flush without retiming")
    expect(plan.nextTarget(now: p) == nil, "reset latch blocks offers")
    expect(!plan.observe(now: p, target: 2 * p, period: p), "reset latch blocks observations")
    plan.reset()
    expect(plan.observe(now: p, target: p + 1.0 / 72, period: 1.0 / 72), "mode accepted after owner reset")

    plan.reset()
    _ = plan.observe(now: 0, target: p, period: p)
    _ = plan.commit(target: plan.nextTarget(now: 0)!, now: 0)
    expect(!plan.observe(now: p, target: 2.4 * p, period: p) && plan.needsReset, "quarter-period discontinuity requests reset")
    plan.reset()
    _ = plan.observe(now: 0, target: p, period: p)
    expect(plan.observe(now: p, target: 2.4 * p, period: p) && !plan.needsReset, "empty plan reanchors discontinuity")

    var idleMode = DisplayDeadlinePlan()
    _ = idleMode.observe(now: 0, target: p, period: p)
    _ = idleMode.commit(target: idleMode.nextTarget(now: 0)!, now: 0)
    expect(idleMode.observe(now: 50, target: 50 + 1.0 / 72, period: 1.0 / 72),
           "long idle retires old queue before mode reanchor")
    expect(!idleMode.needsReset && idleMode.futureCount == 0 && idleMode.nextRetirement == nil,
           "expired native reservations need no flush")
    expect(idleMode.period == 1.0 / 72 && idleMode.nextTarget(now: 50) != nil,
           "new native mode resumes after idle")

    for bad in [Double.nan, Double.infinity, -Double.infinity, 0, -p, 1.0 / 241, 1.0 / 23] {
        var invalid = DisplayDeadlinePlan()
        expect(!invalid.observe(now: 0, target: p, period: bad), "bad period \(bad)")
    }
    for bad in [Double.nan, Double.infinity, -Double.infinity] {
        var invalid = DisplayDeadlinePlan()
        expect(!invalid.observe(now: bad, target: p, period: p), "bad now")
        expect(!invalid.observe(now: 0, target: bad, period: p), "bad target")
        expect(invalid.nextTarget(now: bad) == nil, "bad offer clock")
        expect(!invalid.commit(target: bad, now: 0), "bad commit")
    }
    for boundary in [1.0 / 240, 1.0 / 24] {
        var valid = DisplayDeadlinePlan()
        expect(valid.observe(now: 0, target: boundary, period: boundary), "period inclusive boundary")
    }

    // Merge real native 60 Hz opportunities and 72 Hz arrival offers. Count
    // reserved PTS in the 120-second window after two seconds of warmup.
    var steady = DisplayDeadlinePlan()
    var native = 0
    var arrival = 0
    var measured = 0
    var last = -1.0
    while native <= 60 * 123 || arrival <= 72 * 123 {
        let nt = Double(native) / 60
        let at = Double(arrival) / 72
        if nt <= at {
            expect(steady.observe(now: nt, target: nt + p, period: p), "steady native observation")
            native += 1
        } else {
            if let target = steady.nextTarget(now: at) {
                expect(target > last, "steady strictly increasing PTS")
                expect(steady.commit(target: target, now: at), "steady enqueue")
                last = target
                if target >= 2 - 1e-9 && target < 122 - 1e-9 { measured += 1 }
            }
            expect(steady.futureCount <= 2, "steady bounded future")
            arrival += 1
        }
    }
    expect(measured == 7200, "72 offers / 60 clock: 120 seconds = 7200 slots, got \(measured)")

    // Seeded phase noise must not drift the anchor or reuse native grid slots.
    var noisy = DisplayDeadlinePlan()
    var seed: UInt64 = 0xD15A1A7
    var previous = -1.0
    var successful = 0
    for i in 0..<12000 {
        let now = Double(i) * p
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let jitter = (Double(seed >> 11) / 9007199254740992.0 - 0.5) * p * 0.1
        expect(noisy.observe(now: now, target: now + p + jitter, period: p), "random observation")
        if let target = noisy.nextTarget(now: now) {
            expect(target > previous, "random monotonically reserved")
            expect(noisy.commit(target: target, now: now), "random commit")
            expect(!noisy.commit(target: target, now: now), "random double commit rejected")
            previous = target
            successful += 1
        }
        expect(noisy.futureCount <= 2, "random bounded")
        expect(!noisy.commit(target: previous - p, now: now), "random backwards commit rejected")
    }
    expect(successful > 11000, "noise does not collapse grid slots")
    // Random event spacing, skipped callbacks, stale offers, and invalid clocks.
    // There is no catch-up loop: a fresh native event jumps to its real next PTS.
    var events = DisplayDeadlinePlan()
    var eventNow = 0.0
    var lastNativeSlot = -1
    var eventHighwater = -1.0
    for _ in 0..<10000 {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        eventNow += Double((seed >> 32) % 19 + 1) * p / 10
        let nativeSlot = Int((eventNow / p).rounded(.down))
        if nativeSlot > lastNativeSlot && seed & 3 != 0 {
            expect(events.observe(now: eventNow, target: Double(nativeSlot + 1) * p, period: p),
                   "random spaced native event")
            lastNativeSlot = nativeSlot
        }
        let eventOffer = events.nextTarget(now: eventNow)
        let before = events.futureCount
        expect(events.nextTarget(now: eventNow - p) == nil, "random backwards owner clock")
        expect(events.futureCount == before, "invalid clock preserves queued state")
        if let target = eventOffer {
            expect(target > eventHighwater && target > eventNow, "random events increasing future PTS")
            expect(target - eventNow >= p - 1e-9 && target - eventNow <= 3 * p + 1e-9,
                   "random events lead and horizon")
            expect(events.commit(target: target, now: eventNow), "random event commit")
            expect(!events.commit(target: target, now: eventNow), "random event double commit")
            eventHighwater = target
        }
        expect(events.futureCount <= 2, "random event bound")
    }
    print("DisplayDeadlinePlanTests: \(checks) checks, \(failures) failures; steady measurement \(measured)/7200")
    return failures
}

#if DEADLINE_PLAN_MAIN
@main
struct DisplayDeadlinePlanTestMain {
    static func main() {
        precondition(runDisplayDeadlinePlanTests() == 0, "Deadline plan tests failed")
    }
}
#endif
