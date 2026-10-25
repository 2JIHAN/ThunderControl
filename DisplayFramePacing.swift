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
    // Allow sub-millisecond display-clock jitter, not a second 120Hz selection.
    private let gateTolerance: Double
    private let cushion = 1.0 / 60.0
    private var queue: [Entry] = []
    private var lastArrival: Double?
    private var lastNow: Double?
    private var lastTarget: Double?
    private var epoch: Double?
    private var lastSelectedSlot: Double?
    private var lastSelectedTarget: Double?
    private(set) var stats = DisplayFramePacingStats()

    init(framesPerSecond: Double = 60, onDiscard: ((Frame, DisplayFrameDiscardReason) -> Void)? = nil) {
        self.onDiscard = onDiscard
        precondition(framesPerSecond.isFinite && framesPerSecond > 0 &&
                     framesPerSecond <= 60 && (1 / framesPerSecond).isFinite,
                     "Decoded-frame pacing requires finite 0 < FPS <= 60")
        self.framesPerSecond = framesPerSecond
        interval = 1 / framesPerSecond
        gateTolerance = min(interval * 0.01, 0.00025)
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
        lastNow = now
        lastTarget = target
        guard !queue.isEmpty else {
            stats.emptyTicks += 1
            return nil
        }
        // A 1ns rounding allowance avoids losing exact 1/60 boundaries to Double
        // subtraction. This is NOT the wider cadence jitter tolerance.
        let cutoff = target - cushion
        let cushionedIndex = queue.lastIndex(where: { $0.arrival <= cutoff + 1e-9 })
        // At 120fps arrivals / 60Hz ticks, capacity two can perpetually evict every
        // cushioned frame. Under that pressure consume the OLDER of two instead,
        // preserving one newer decoded frame as a buffer. Never select a future
        // arrival, bypass the rate gate, or early-select a lone queued frame.
        let fallbackIndex: Int? = queue.count == 2 && queue[0].arrival <= target ? 0 : nil
        guard let index = cushionedIndex ?? fallbackIndex else {
            stats.waitingTicks += 1
            return nil
        }
        let origin = epoch ?? target
        let slot = ((target - origin + gateTolerance) / interval).rounded(.down)
        if let previousSlot = lastSelectedSlot, let previousTarget = lastSelectedTarget,
           slot <= previousSlot || target - previousTarget < interval - gateTolerance {
            stats.rateLimitedTicks += 1
            return nil
        }
        // Fixed target-clock slots avoid timer drift. The separation check prevents
        // two adjacent slots from producing a short catch-up burst after jitter/idle.
        // Skipped slots are lost, never accumulated as credits. Empty/young ticks do
        // not establish the epoch, so the first eligible frame needs no extra tick.
        epoch = origin
        lastSelectedSlot = slot
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
        epoch = nil
        lastSelectedSlot = nil
        lastSelectedTarget = nil
        stats = DisplayFramePacingStats()
    }

    private func validTime(_ value: Double) -> Bool {
        // Fail closed before huge finite timestamps lose sub-frame resolution.
        value.isFinite && value >= 0 && value.ulp <= 0.000001
    }
}
