/// Selection of already-decoded frames only; cadence and capacity are shared.
enum DisplayFrameSelectionPolicy {
    case fifo25, latest
    /// Build-70 rule: newest frame that arrived at least one 1/60 cushion before the
    /// display target; under a full queue, the older of two. Smoothness over latency.
    case latest70
    /// Build-70 rule with hysteresis: when a frame misses the 1/60 cushion by less than
    /// `relaxMargin`, take it anyway and keep the lowered cushion while such arrivals
    /// continue. Arrivals straddling the nominal boundary then stop flipping between
    /// "repeat one refresh" and "two eligible, newest wins, skip one".
    case latest70h
    /// Jitter buffer: one frame per panel tick in arrival order, no age cushion and no
    /// catch-up. A late frame costs one repeated refresh, after which the extra queued
    /// frame absorbs later jitter; overflow (capacity two) is the only skip.
    case sequence
    /// Jitter buffer that gives its spare frame back: when a second arrived frame has been
    /// waiting behind the shown one for `catchUpHold`, skip one frame once to drop the
    /// extra refresh of latency. A late frame inside that window is still absorbed.
    case sequenceCatchUp
    /// Oldest available decoded frame, with neither cushion nor age catchup.
    case buffered

    static var buildDefault: Self {
#if TC_SEQUENCE_CATCHUP
        .sequenceCatchUp
#elseif TC_LEGACY70_HYSTERESIS
        .latest70h
#elseif TC_SEQUENCE_SELECTION
        .sequence
#elseif TC_LEGACY70_SELECTION
        .latest70
#elseif TC_LATEST_DECODED
        .latest
#else
        .fifo25
#endif
    }
}

/// Cadence is opt-in: existing callers retain the wall-clock budget.
/// displayTargets trusts each genuine native display opportunity, not a second
/// software FPS cap. The owner configures preferredFrameRateRange (normally 60)
/// and must measure actual native cadence; a preference is not proof of 60Hz.
enum DisplayFrameCadencePolicy { case wallBudget, displayTargets }

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
    // Saturating display-target diagnostics, separate from the legacy rate budget.
    fileprivate(set) var duplicateTargetTicks: UInt64 = 0
    fileprivate(set) var expiredTargetTicks: UInt64 = 0
    fileprivate(set) var targetLimitedTicks: UInt64 = 0
    fileprivate(set) var displayOpportunities: UInt64 = 0
}

enum DisplayFrameDiscardReason: Int { case invalidOffer = 1, overflow = 2, superseded = 3, clear = 4 }

struct DisplayFramePacer<Frame> {
    /// Only already-decoded frames belong here, never compressed reference frames.
    private struct Entry {
        let frame: Frame
        let arrival: Double
    }

    private let cadencePolicy: DisplayFrameCadencePolicy
    private let selectionPolicy: DisplayFrameSelectionPolicy
    private let onDiscard: ((Frame, DisplayFrameDiscardReason) -> Void)?
    let framesPerSecond: Double
    private let interval: Double
    // One cadence period is the maximum phase debt, not a per-tick waiver.
    private let phaseAllowance: Double
    private let cushion = 1.0 / 60.0
    // 4ms covers the measured near-boundary arrivals (5.5% within 2ms in the worst run)
    // while keeping at least 12.7ms of cushion, so latency can only drop versus build 70.
    private let relaxMargin = 0.004
    // Return to the nominal cushion only after 2s without a near-boundary arrival.
    private let relaxHold = 2.0
    private var relaxedUntil = -Double.infinity
    // Long enough that ordinary jitter bursts are absorbed, short enough that a single
    // late frame does not leave a whole refresh of latency in place for long.
    private let catchUpHold = 1.0
    private var backlogSince: Double?
    /// Actual decoded queue residence above this threshold switches FIFO to
    /// newest ELIGIBLE catch-up. Exactly 25ms remains FIFO. This is not a hard
    /// maximum age: an old singleton may still be selected, never expired here.
    private let fifoCatchUpAgeThreshold: Double = 0.025
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

    init(framesPerSecond: Double = 60, selectionPolicy: DisplayFrameSelectionPolicy = .buildDefault, cadencePolicy: DisplayFrameCadencePolicy = .wallBudget, onDiscard: ((Frame, DisplayFrameDiscardReason) -> Void)? = nil) {
        self.selectionPolicy = selectionPolicy
        self.cadencePolicy = cadencePolicy
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
    /// may be slightly past (legacy only) or future, but not >0.1 seconds from now.
    /// Invalid ticks only increment invalidInputs and cannot poison later ticks.
    /// Display-target cadence additionally rejects expired/duplicate observations,
    /// and consumes each admitted target opportunity even if no frame is available.
    /// rateLimitedTicks belongs exclusively to legacy wallBudget cadence.
    /// Never call this while the presentation sink is not ready: offers remain bounded.
    mutating func take(now: Double, targetTimestamp target: Double) -> Frame? {
        if cadencePolicy == .displayTargets { return takeDisplayTarget(now: now, target: target) }
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
        let eligibleIndex: Int?
        let fallbackIndex: Int?
        switch selectionPolicy {
        case .fifo25:
            // A 1ns rounding allowance avoids losing exact 1/60 boundaries to Double
            // subtraction. This is NOT the wider cadence jitter tolerance.
            let cutoff = target - cushion
            // Ordering alone changes: eligibility, bounded fallback and cadence stay
            // identical. Measure age against actual callback time, not prediction.
            let catchingUp = now - queue[0].arrival > fifoCatchUpAgeThreshold
            let eligible: (Entry) -> Bool = { $0.arrival <= now && $0.arrival <= cutoff + 1e-9 }
            eligibleIndex = catchingUp
                ? queue.lastIndex(where: eligible)
                : queue.firstIndex(where: eligible)
            // At 120fps arrivals / 60Hz ticks, capacity two can perpetually evict every
            // cushioned frame. Under that pressure consume the OLDER of two instead,
            // preserving one newer decoded frame as a buffer. Never select a future
            // arrival, bypass the rate gate, or early-select a lone queued frame.
            fallbackIndex = queue.count == 2 && queue[0].arrival <= min(target, now) ? 0 : nil
        case .buffered:
            eligibleIndex = queue.firstIndex { $0.arrival <= now && $0.arrival <= target }
            fallbackIndex = nil
        case .sequence:
            eligibleIndex = queue.firstIndex { $0.arrival <= now }
            fallbackIndex = nil
        case .sequenceCatchUp:
            eligibleIndex = sequenceCatchUpIndex(now: now, target: target)
            fallbackIndex = nil
        case .latest70h:
            eligibleIndex = latest70HysteresisIndex(now: now, target: target)
            fallbackIndex = queue.count == 2 && queue[0].arrival <= min(target, now) ? 0 : nil
        case .latest70:
            eligibleIndex = queue.lastIndex { $0.arrival <= now && $0.arrival <= target - cushion + 1e-9 }
            fallbackIndex = queue.count == 2 && queue[0].arrival <= min(target, now) ? 0 : nil
        case .latest:
            // No fixed cushion or early fallback: use the newest decoded entry
            // already arrived by BOTH actual callback time and display target.
            // A late target waits for an eligible entry; prediction cannot make
            // a future arrival available. Cadence below is deliberately shared.
            eligibleIndex = queue.lastIndex { $0.arrival <= now && $0.arrival <= target }
            fallbackIndex = nil
        }
        guard let index = eligibleIndex ?? fallbackIndex else {
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
        if eligibleIndex == nil { stats.earlySelections += 1 }
        return frame
    }

    /// Each unique upcoming native target is inspected once, even when empty or
    /// ineligible. No wall-clock budget, target budget, fixed slot or idle wait.
    /// If the native owner delivers 120/144Hz, this mode admits 120/144Hz: native
    /// configuration and measured cadence, not a second cap here, own the rate.
    private mutating func takeDisplayTarget(now: Double, target: Double) -> Frame? {
        guard validTime(now), validTime(target), abs(target - now) <= 0.1,
              lastNow.map({ now >= $0 }) ?? true else {
            stats.invalidInputs += 1
            return nil
        }
        // Reject stale observations without changing any accepted clock or phase.
        guard target > now else {
            if stats.expiredTargetTicks < .max { stats.expiredTargetTicks += 1 }
            return nil
        }
        guard lastTarget.map({ target > $0 }) ?? true else {
            // Includes backward native targets: neither can consume a frame or
            // replace the monotonic high-water mark used by the next valid tick.
            if stats.duplicateTargetTicks < .max { stats.duplicateTargetTicks += 1 }
            return nil
        }
        // Consume the native opportunity even if no frame is available. Later
        // offers cannot retry the same VSync or replay a previously selected frame.
        lastNow = now
        lastTarget = target
        if stats.displayOpportunities < .max { stats.displayOpportunities += 1 }
        guard !queue.isEmpty else {
            stats.emptyTicks += 1
            return nil
        }
        let index: Int?
        switch selectionPolicy {
        case .buffered:
            index = queue.firstIndex { $0.arrival <= now && $0.arrival <= target }
        case .sequence:
            index = queue.firstIndex { $0.arrival <= now }
        case .sequenceCatchUp:
            index = sequenceCatchUpIndex(now: now, target: target)
        case .latest70h:
            index = latest70HysteresisIndex(now: now, target: target)
                ?? (queue.count == 2 && queue[0].arrival <= min(target, now) ? 0 : nil)
        case .latest70:
            index = queue.lastIndex { $0.arrival <= now && $0.arrival <= target - cushion + 1e-9 }
                ?? (queue.count == 2 && queue[0].arrival <= min(target, now) ? 0 : nil)
        case .latest:
            index = queue.lastIndex { $0.arrival <= now && $0.arrival <= target }
        case .fifo25:
            let eligible: (Entry) -> Bool = {
                $0.arrival <= now && $0.arrival <= target - cushion + 1e-9
            }
            index = (now - queue[0].arrival > fifoCatchUpAgeThreshold
                ? queue.lastIndex(where: eligible) : queue.firstIndex(where: eligible))
                ?? (queue.count == 2 && queue[0].arrival <= min(target, now) ? 0 : nil)
        }
        guard let index else {
            stats.waitingTicks += 1
            return nil
        }
        let frame = queue[index].frame
        stats.superseded += UInt64(index)
        if let onDiscard { for entry in queue.prefix(index) { onDiscard(entry.frame, .superseded) } }
        if selectionPolicy == .fifo25 && queue[index].arrival > target - cushion + 1e-9 {
            stats.earlySelections += 1
        }
        queue.removeFirst(index + 1)
        stats.selected += 1
        return frame
    }

    /// Use for a new stream/timebase or teardown. Drops pending decoded frames and
    /// resets ALL diagnostics and clocks, including native-target history. Keeps configured FPS.
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
        relaxedUntil = -.infinity
        backlogSince = nil
        stats = DisplayFramePacingStats()
    }

    private mutating func sequenceCatchUpIndex(now: Double, target: Double) -> Int? {
        let arrived = queue.prefix { $0.arrival <= now }.count
        guard arrived > 0 else { backlogSince = nil; return nil }
        guard arrived >= 2 else { backlogSince = nil; return 0 }
        // Two arrived frames means we are one refresh behind the source.
        guard let since = backlogSince else { backlogSince = target; return 0 }
        guard target - since >= catchUpHold else { return 0 }
        backlogSince = nil
        return 1
    }

    private mutating func latest70HysteresisIndex(now: Double, target: Double) -> Int? {
        let relaxedCutoff = target - (cushion - relaxMargin) + 1e-9
        let cutoff = target < relaxedUntil ? relaxedCutoff : target - cushion + 1e-9
        if let index = queue.lastIndex(where: { $0.arrival <= now && $0.arrival <= cutoff }) {
            // Still landing inside the nominal cushion: extend the lowered threshold.
            if queue[index].arrival > target - cushion + 1e-9 { relaxedUntil = target + relaxHold }
            return index
        }
        // A near miss: take it now instead of repeating, and lower the cushion so the
        // next frames at this phase do not pile up into a two-eligible skip.
        guard let index = queue.lastIndex(where: { $0.arrival <= now && $0.arrival <= relaxedCutoff }) else { return nil }
        relaxedUntil = target + relaxHold
        return index
    }

    private func validTime(_ value: Double) -> Bool {
        // Fail closed before huge finite timestamps lose sub-frame resolution.
        value.isFinite && value >= 0 && value.ulp <= 0.000001
    }
}
