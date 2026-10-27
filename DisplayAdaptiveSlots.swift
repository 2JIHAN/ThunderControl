/// Receiver-side jitter absorption with the smallest added delay that keeps one new
/// frame per panel refresh. Owned by one thread (main). Pure: clocks are passed in.
///
/// Immediate presentation loses a frame whenever two decoded frames land inside the
/// same panel refresh (the second replaces the first) and leaves the next refresh
/// empty. Here each frame takes the next free panel slot that is at least `lead`
/// ahead of now, so bunched arrivals are spread one per slot. Delay grows only while
/// arrivals bunch and shrinks back to `lead` as soon as an arrival gap frees a slot.
struct DisplayAdaptiveSlots {
    enum Decision: Equatable { case slot(Double), immediate, drop }
    private(set) var period: Double?
    private var anchor: Double?
    private var observedAt: Double?
    private var reserved: [Double] = []
    /// Seconds between enqueue and the reserved slot; adapted from renderer drops.
    private(set) var lead: Double = 0.006
    static let minimumLead = 0.003, maximumLead = 0.016
    /// Never hold more than this many future slots: bounds the added delay.
    static let maximumQueued = 2
    private(set) var scheduled: UInt64 = 0, immediate: UInt64 = 0, dropped: UInt64 = 0
    private(set) var addedDelaySum: Double = 0, addedDelayMax: Double = 0

    mutating func observe(target: Double, period newPeriod: Double, now: Double) {
        guard target.isFinite, now.isFinite, newPeriod.isFinite,
              newPeriod >= 1.0 / 240.0, newPeriod <= 1.0 / 24.0, target > now - newPeriod else { return }
        period = newPeriod; anchor = target; observedAt = now
    }
    /// One decision per decoded frame, in arrival order.
    mutating func decide(now: Double) -> Decision {
        reserved.removeAll { $0 <= now }
        // Without a fresh panel clock there is nothing to align to: show immediately.
        guard let p = period, let a = anchor, let seen = observedAt, now - seen <= 0.1, now.isFinite else {
            immediate &+= 1; return .immediate
        }
        let earliestIndex = ((now + lead - a) / p).rounded(.up)
        let earliest = a + earliestIndex * p
        var slot = earliest
        if let last = reserved.last { slot = max(slot, last + p) }
        // A third queued slot would mean steadily growing delay: drop this frame instead.
        guard reserved.count < Self.maximumQueued, slot - earliest <= p * 1.0001 else {
            dropped &+= 1; return .drop
        }
        reserved.append(slot)
        scheduled &+= 1
        let added = slot - now
        addedDelaySum += added; addedDelayMax = max(addedDelayMax, added)
        return .slot(slot)
    }
    /// Renderer reported new drops since the last call: give the compositor more time.
    /// A clean interval lets the lead decay slowly toward the minimum.
    mutating func adapt(newRendererDrops: Double) {
        if newRendererDrops > 0 { lead = min(Self.maximumLead, lead + 0.002) }
        else { lead = max(Self.minimumLead, lead - 0.0005) }
    }
    mutating func reset() {
        period = nil; anchor = nil; observedAt = nil; reserved.removeAll(); lead = 0.006
        scheduled = 0; immediate = 0; dropped = 0; addedDelaySum = 0; addedDelayMax = 0
    }
    var averageAddedDelay: Double { scheduled == 0 ? 0 : addedDelaySum / Double(scheduled) }
}

func runDisplayAdaptiveSlotsTests() -> Int {
    var failures = 0, checks = 0
    func check(_ ok: Bool, _ name: String) { checks += 1; if !ok { failures += 1; print("FAIL adaptive slots: " + name) } }
    let p = 1.0 / 60.0
    var s = DisplayAdaptiveSlots()
    check(s.decide(now: 1) == .immediate, "no clock yet shows immediately")
    s.observe(target: 1.0 + p, period: p, now: 1.0)
    // Two frames inside one refresh go to two consecutive slots, never the same one.
    guard case .slot(let a) = s.decide(now: 1.001), case .slot(let b) = s.decide(now: 1.002) else { check(false, "bunched frames scheduled"); return failures }
    check(abs(b - a - p) < 1e-9, "second bunched frame takes the next slot")
    check(a - 1.001 >= s.lead - 1e-9, "slot keeps at least the lead")
    check(s.decide(now: 1.003) == .drop, "a third queued frame is dropped to bound delay")
    // After a gap the delay returns to the minimum: earliest slot again.
    s.observe(target: 1.0 + 10 * p, period: p, now: 1.0 + 9 * p)
    if case .slot(let c) = s.decide(now: 1.0 + 9 * p + 0.001) { check(c - (1.0 + 9 * p + 0.001) <= p + s.lead, "delay recovers after a gap") } else { check(false, "post-gap slot") }
    // Steady 60fps arrivals at a fixed phase keep a constant delay below one period.
    var t = DisplayAdaptiveSlots(); var maxDelay = 0.0, drops = 0
    for i in 0..<7200 {
        let now = 10 + Double(i) * p + 0.004 + (i % 7 == 0 ? 0.003 : 0)    // jitter up to 3ms
        t.observe(target: 10 + Double(i + 1) * p, period: p, now: 10 + Double(i) * p)
        switch t.decide(now: now) { case .slot(let x): maxDelay = max(maxDelay, x - now); case .drop: drops += 1; case .immediate: break }
    }
    check(drops == 0, "steady jittered 60fps never drops (\(drops))")
    check(maxDelay <= p + 0.0001, "steady delay stays within one period (\(maxDelay))")
    // Stale clock falls back to immediate; adaptation stays within bounds.
    var u = DisplayAdaptiveSlots(); u.observe(target: 1 + p, period: p, now: 1)
    check(u.decide(now: 1.2) == .immediate, "stale panel clock shows immediately")
    for _ in 0..<50 { u.adapt(newRendererDrops: 1) }
    check(u.lead <= DisplayAdaptiveSlots.maximumLead + 1e-12, "lead capped")
    for _ in 0..<200 { u.adapt(newRendererDrops: 0) }
    check(u.lead >= DisplayAdaptiveSlots.minimumLead - 1e-12, "lead floored")
    for bad in [Double.nan, .infinity, 1.0] { var v = DisplayAdaptiveSlots(); v.observe(target: 2, period: bad, now: 1); check(v.decide(now: 1) == .immediate, "invalid period ignored") }
    print("DisplayAdaptiveSlots: \(checks) checks, \(failures) failures; offline model, not panel proof")
    return failures
}
