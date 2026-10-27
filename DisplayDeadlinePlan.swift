/// Owner-thread-only reservation clock, driven exclusively by native observations.
/// A returned offer is not a reservation: call commit only after an actual enqueue.
/// The owner must flush native queued work before reset when needsReset is true.
struct DisplayDeadlinePlan {
    private(set) var period: Double?
    private(set) var generation: UInt64 = 0
    private(set) var needsReset = false
    var futureCount: Int { reservations.count }
    /// Owner may schedule one coalesced wake here, then call nextTarget to retire.
    var nextRetirement: Double? { reservations.first }

    private var anchor: Double?
    private var observationNow: Double?
    private var observationTarget: Double?
    private var ownerNow: Double?
    private var highwater: Double?
    private var reservations: [Double] = []
    private var offered: Double?
    private let staleInterval = 0.100

    /// Credit expiry may wake an active producer, never poll a backpressured one.
    /// Retire due reservations via nextTarget before checking renderer readiness.
    static func wakeDelay(now: Double, retirement: Double?, hasWaiting: Bool,
                          waitingForReadiness: Bool) -> Double? {
        guard hasWaiting, !waitingForReadiness, now.isFinite,
              let retirement = retirement, retirement.isFinite,
              retirement > now else { return nil }
        let delay = retirement - now
        return delay.isFinite && delay > 0 ? delay : nil
    }

    /// Invalid inputs never refresh the observation's 100 ms lease.
    @discardableResult
    mutating func observe(now: Double, target: Double, period newPeriod: Double) -> Bool {
        guard advance(now), !needsReset,
              target.isFinite, target > now,
              newPeriod.isFinite, newPeriod >= 1.0 / 240.0,
              newPeriod <= 1.0 / 24.0,
              target - now <= 3 * newPeriod else { return false }
        // A genuine rate change must request a flush even if its first callback
        // names an earlier opportunity; an otherwise old callback is just stale.
        if let p = period, !reservations.isEmpty,
           abs(newPeriod - p) > p * 0.02 + p * 1e-9 {
            needsReset = true
            offered = nil
            return false
        }
        if let previous = observationTarget, target <= previous { return false }
        var reanchor = false
        if let p = period, let a = anchor {
            // Freeze the grid during normal phase noise. Updating its anchor on
            // every callback would silently retime or collapse already-used slots.
            let nearest = ((target - a) / p).rounded()
            let phaseError = abs(target - (a + nearest * p))
            let discontinuity = abs(newPeriod - p) > p * 0.02 + p * 1e-9
                || phaseError > p * 0.25 + p * 1e-9
            if discontinuity {
                guard reservations.isEmpty else {
                    needsReset = true
                    offered = nil
                    return false
                }
                reanchor = true
            }
        } else {
            reanchor = true
        }
        if reanchor {
            anchor = target
            period = newPeriod
            // Keep highwater: a re-anchor is not permission to reuse a PTS.
            offered = nil
        }
        observationNow = now
        observationTarget = target
        return true
    }

    mutating func nextTarget(now: Double) -> Double? {
        guard advance(now) else { return nil }
        offered = candidate(now: now)
        return offered
    }

    @discardableResult
    mutating func commit(target: Double, now: Double) -> Bool {
        guard advance(now), target.isFinite, let offer = offered,
              target == offer, let expected = candidate(now: now),
              target == expected else { return false }
        reservations.append(target)
        highwater = target
        offered = nil
        return true
    }

    /// Only a deliberate owner flush/reset permits a new reservation epoch.
    mutating func reset() {
        period = nil
        anchor = nil
        observationNow = nil
        observationTarget = nil
        ownerNow = nil
        highwater = nil
        reservations.removeAll(keepingCapacity: true)
        offered = nil
        needsReset = false
        generation &+= 1
    }

    private mutating func advance(_ now: Double) -> Bool {
        guard now.isFinite, ownerNow.map({ now >= $0 }) ?? true else { return false }
        ownerNow = now
        reservations.removeAll { $0 <= now }
        return true
    }

    private func candidate(now: Double) -> Double? {
        guard !needsReset, reservations.count < 2,
              let p = period, let a = anchor, let observed = observationNow,
              now - observed <= staleInterval else { return nil }
        let epsilon = p * 1e-9
        // Skip the very next native opportunity, leaving at least one full
        // observed period to enqueue. Arithmetic jumps over idle time in O(1).
        var slot = ((now - a + epsilon) / p).rounded(.down) + 2
        if let used = highwater {
            slot = max(slot, ((used - a + epsilon) / p).rounded(.down) + 1)
        }
        let result = a + slot * p
        guard result.isFinite, result > now,
              result - now >= p - epsilon,
              result - now <= 3 * p + epsilon,
              result <= observed + staleInterval + epsilon,
              highwater.map({ result > $0 + epsilon }) ?? true,
              !reservations.contains(result) else { return nil }
        return result
    }
}
