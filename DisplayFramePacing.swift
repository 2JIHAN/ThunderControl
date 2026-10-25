/// Local decoded-frame policy only. Call on one serial executor. The owner retains
/// responsibility for decoder dependencies, display readiness and real presentation.
struct DisplayFramePacingStats: Equatable {
    fileprivate(set) var offered: UInt64 = 0
    fileprivate(set) var overflowReplaced: UInt64 = 0
    fileprivate(set) var superseded: UInt64 = 0
    fileprivate(set) var selected: UInt64 = 0
    /// Subset of selected: bounded full-queue fallback before the nominal cushion.
    fileprivate(set) var earlySelections: UInt64 = 0
    fileprivate(set) var emptyTicks: UInt64 = 0
    fileprivate(set) var waitingTicks: UInt64 = 0
    fileprivate(set) var invalidInputs: UInt64 = 0
    fileprivate(set) var rateLimitedTicks: UInt64 = 0
}

enum DisplayFrameDiscardReason: Int { case invalidOffer = 1, overflow = 2, superseded = 3, clear = 4 }

struct DisplayFramePacer<Frame> {
    /// Only already-decoded frames belong here, never compressed reference frames.
    private struct Entry {
        let frame: Frame
        let arrival: Double
    }

    private let onDiscard: ((Frame, DisplayFrameDiscardReason) -> Void)?
    let framesPerSecond: Double
    private let interval: Double
    // One cadence period is the maximum phase debt, not a per-tick waiver.
    private let phaseAllowance: Double
    private let cushion = 1.0 / 60.0
    private var queue: [Entry] = []
    private var lastArrival: Double?
    private var lastNow: Double?
    private var lastTarget: Double?
    private var emptySince: Double?
    private var idleResetPending = false
    private var nextDeadline: Double?
    private var lastSelectedNow: Double?
    private var lastSelectedTarget: Double?
    private(set) var stats = DisplayFramePacingStats()

    init(framesPerSecond: Double = 60, onDiscard: ((Frame, DisplayFrameDiscardReason) -> Void)? = nil) {
        self.onDiscard = onDiscard
        precondition(framesPerSecond.isFinite && framesPerSecond > 0 &&
                     framesPerSecond <= 60 && (1 / framesPerSecond).isFinite,
                     "Decoded-frame pacing requires finite 0 < FPS <= 60")
        self.framesPerSecond = framesPerSecond
        interval = 1 / framesPerSecond
        phaseAllowance = interval
    }

    var pendingCount: Int { queue.count }
    var pending: Bool { !queue.isEmpty }

    /// True means this accepted offer evicted the oldest of two queued frames.
    /// False means either no overflow or rejection; stats.invalidInputs distinguishes
    /// rejection. Rejection changes no queue/clock state and does not count as offered.
    @discardableResult
    mutating func offer(_ frame: Frame, at arrival: Double) -> Bool {
        guard validTime(arrival), lastArrival.map({ arrival >= $0 }) ?? true else {
            stats.invalidInputs += 1
            onDiscard?(frame, .invalidOffer)
            return false
        }
        lastArrival = arrival
        stats.offered += 1
        let replaced = queue.count == 2
        if replaced {
            onDiscard?(queue[0].frame, .overflow)
            queue.removeFirst()
            stats.overflowReplaced += 1
        }
        queue.append(Entry(frame: frame, arrival: arrival))
        return replaced
    }

    /// Clocks must share a nonnegative monotonic seconds domain. A display target
    /// may be slightly past (late callback) or future, but not >0.1 seconds from now.
    /// Invalid ticks only increment invalidInputs and cannot poison later ticks.
    /// Tick outcome counters are exclusive: invalid, empty, waiting, limited, selected.
    /// Never call this while the presentation sink is not ready: offers remain bounded.
    mutating func take(now: Double, targetTimestamp target: Double) -> Frame? {
        guard validTime(now), validTime(target), abs(target - now) <= 0.1,
              lastNow.map({ now >= $0 }) ?? true,
              lastTarget.map({ target >= $0 }) ?? true else {
            stats.invalidInputs += 1
            return nil
        }
        let missedCallbacks = lastNow.map { now - $0 >= 2 * interval } ?? false
        if missedCallbacks { idleResetPending = true }
        if emptySince.map({ now - $0 >= 2 * interval }) == true { idleResetPending = true }
        lastNow = now
        lastTarget = target
        guard !queue.isEmpty else {
            if emptySince == nil { emptySince = now }
            stats.emptyTicks += 1
            return nil
        }
        // A 1ns rounding allowance avoids losing exact 1/60 boundaries to Double
        // subtraction. This is NOT the wider cadence jitter tolerance.
        let cutoff = target - cushion
        let cushionedIndex = queue.lastIndex(where: { $0.arrival <= now && $0.arrival <= cutoff + 1e-9 })
        // At 120fps arrivals / 60Hz ticks, capacity two can perpetually evict every
        // cushioned frame. Under that pressure consume the OLDER of two instead,
        // preserving one newer decoded frame as a buffer. Never select a future
        // arrival, bypass the rate gate, or early-select a lone queued frame.
        let fallbackIndex: Int? = queue.count == 2 && queue[0].arrival <= min(target, now) ? 0 : nil
        guard let index = cushionedIndex ?? fallbackIndex else {
            stats.waitingTicks += 1
            return nil
        }
        // Prediction controls frame eligibility; actual monotonic callback time
        // controls a two-frame-capacity cadence budget. Permit one full period
        // of phase debt: a 60Hz callback train can legitimately contain multiple
        // short gaps, even gaps below half a period. Each selection nevertheless
        // advances the deadline by a FULL period. No minimum-spacing heuristic.
        if let previous = lastSelectedNow, let deadline = nextDeadline {
            guard now > previous,
                  target > (lastSelectedTarget ?? target),
                  now + phaseAllowance + 1e-9 >= deadline else {
                stats.rateLimitedTicks += 1
                return nil
            }
            if idleResetPending {
                // Two missing callback periods or two observed empty periods
                // identify idle, NOT a mere gap between selected frames.
                // Idle supplies exactly one immediate frame, NOT two banked
                // credits: the next frame must wait a full period. A long pause
                // cannot finance a catch-up burst on resume.
                nextDeadline = now + 2 * interval
            } else {
                // A late callback discards unused past budget. An early one
                // spends phase debt; subsequent calls must repay that debt.
                // This is equivalent to a capacity-two token bucket when active:
                // ANY subwindow has N <= FPS * elapsed + 2 (roundoff aside).
                nextDeadline = max(deadline + interval, now + interval)
            }
        } else {
            // Startup may borrow one frame, a bounded additive allowance, not
            // sustained 120fps. Idle resume deliberately gets no such allowance.
            nextDeadline = now + interval
        }
        emptySince = nil
        idleResetPending = false
        lastSelectedNow = now
        lastSelectedTarget = target
        let frame = queue[index].frame
        stats.superseded += UInt64(index)
        if let onDiscard { for entry in queue.prefix(index) { onDiscard(entry.frame, .superseded) } }
        queue.removeFirst(index + 1)
        stats.selected += 1
        if cushionedIndex == nil { stats.earlySelections += 1 }
        return frame
    }

    /// Use for a new stream/timebase or teardown. Drops pending decoded frames and
    /// resets ALL diagnostics and clocks. Does not change configured FPS.
    mutating func clear() {
        if let onDiscard { for entry in queue { onDiscard(entry.frame, .clear) } }
        queue.removeAll(keepingCapacity: true)
        lastArrival = nil
        lastNow = nil
        lastTarget = nil
        emptySince = nil
        idleResetPending = false
        nextDeadline = nil
        lastSelectedNow = nil
        lastSelectedTarget = nil
        stats = DisplayFramePacingStats()
    }

    private func validTime(_ value: Double) -> Bool {
        // Fail closed before huge finite timestamps lose sub-frame resolution.
        value.isFinite && value >= 0 && value.ulp <= 0.000001
    }
}
