import Foundation

/// Deterministic handshakes, no VT, windows or network. Runs on main so a
/// blocked fake submit demonstrates that retire itself does not wait for the worker.
func runDisplayDecodeWorkerTests() -> Int {
    var failures = 0, cases = 0
    func check(_ ok: Bool, _ name: String) { cases += 1; if !ok { failures += 1; print("FAIL worker: \(name)") } }
    func wait(_ signal: DispatchSemaphore) -> Bool { signal.wait(timeout: .now() + 3) == .success }
    func drained(_ w: DisplayDecodeWorker) -> Bool {
        let until = Date().addingTimeInterval(3)
        while !w.isDrained && Date() < until { Thread.sleep(forTimeInterval: 0.001) }; return w.isDrained
    }
    final class State {
        let lock = NSLock(); var events: [Int] = []; var offMain = true
        func add(_ n: Int) { lock.lock(); events.append(n); offMain = offMain && !Thread.isMainThread; lock.unlock() }
        var snapshot: [Int] { lock.lock(); defer { lock.unlock() }; return events }
    }
    func worker(_ cleanup: @escaping () -> Void) -> DisplayDecodeWorker? {
        guard let lease = DisplayDecodeWorkerLease.acquire() else { return nil }
        return DisplayDecodeWorker(lease: lease, cleanup: cleanup)
    }
    // FIFO and strict maximum, including the blocked executing call.
    do {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let fourth = DispatchSemaphore(value: 0), cleaned = DispatchSemaphore(value: 0), state = State()
        guard let w = worker({ state.add(9); cleaned.signal() }) else { return 1 }
        check(w.submit { delay in state.add(0); entered.signal(); _ = release.wait(timeout: .now() + 3); return delay >= 0 }, "first accepted")
        check(wait(entered), "worker entered")
        for n in 1...3 { check(w.submit { delay in state.add(n); if n == 3 { fourth.signal() }; return delay >= 0 }, "FIFO enqueue") }
        check(!w.submit { _ in state.add(99); return true }, "fifth rejected")
        release.signal(); check(wait(fourth), "FIFO finished")
        w.retire(); check(wait(cleaned), "FIFO cleanup"); check(drained(w), "FIFO permit release")
        check(state.snapshot == [0, 1, 2, 3, 9], "FIFO order")
        check(state.offMain, "all calls and cleanup off main")
    }
    // Clear-before-run, idempotent retirement, ordered cleanup, strong owner lifetime.
    do {
        final class Owner {}
        var owner: Owner? = Owner(); weak var weakOwner = owner
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let cleaned = DispatchSemaphore(value: 0), state = State()
        guard let w = worker({ [held = owner!] in withExtendedLifetime(held) {}; state.add(9); cleaned.signal() }) else { return 1 }
        owner = nil
        check(w.submit { _ in entered.signal(); _ = release.wait(timeout: .now() + 3); state.add(0); return true }, "blocked accepted")
        check(wait(entered), "blocked entered")
        for n in 1...3 { check(w.submit { _ in state.add(n); return true }, "retire pending accepted") }
        // This must return before release.signal(), otherwise the deterministic
        // three-second fake timeout produces unexpected queued calls/order failure.
        let began = ProcessInfo.processInfo.systemUptime
        w.retire(); w.retire()
        check(ProcessInfo.processInfo.systemUptime - began < 0.5, "retirement does not wait on main")
        check(weakOwner != nil, "callback owner retained during call")
        check(state.snapshot.isEmpty, "cleanup not concurrent with call")
        check(!w.submit { _ in true }, "retired refuses jobs")
        release.signal(); check(wait(cleaned), "retirement finished"); check(drained(w), "retirement permit release"); check(weakOwner == nil, "callback owner released after drain")
        check(state.snapshot == [0, 9], "queued calls retired before execution")
    }
    do {
        final class EncodedOwner { let bytes = Data(repeating: 0x5a, count: 4096) }
        var owner: EncodedOwner? = EncodedOwner()
        weak var held = owner
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0), cleaned = DispatchSemaphore(value: 0)
        guard let w = worker({ cleaned.signal() }) else { return 1 }
        check(w.submit({ [encoded = owner!] _ in
            entered.signal(); _ = release.wait(timeout: .now() + 3)
            let intact = encoded.bytes.count == 4096 && encoded.bytes.allSatisfy { $0 == 0x5a }
            finished.signal(); return intact
        }), "encoded materialization accepted")
        owner = nil
        check(wait(entered), "encoded materialization blocked")
        w.retire()
        check(held != nil, "encoded owner survives reset while materialization blocked")
        release.signal(); check(wait(finished), "encoded bytes remain intact through call")
        check(wait(cleaned), "encoded materialization cleanup"); check(drained(w), "encoded permit released")
        check(held == nil, "encoded owner released after worker drains")
    }
    // Failure closes submission gate before the next queued call starts.
    do {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let cleaned = DispatchSemaphore(value: 0), state = State()
        guard let w = worker({ state.add(9); cleaned.signal() }) else { return 1 }
        check(w.submit { _ in state.add(0); entered.signal(); _ = release.wait(timeout: .now() + 3); return false }, "error accepted")
        check(wait(entered), "error entered")
        for n in 1...3 { check(w.submit { _ in state.add(n); return true }, "error queued") }
        release.signal()
        let until = Date().addingTimeInterval(3)
        while !w.hasFailed && Date() < until { Thread.sleep(forTimeInterval: 0.001) }
        check(w.hasFailed, "failure visible before retirement")
        check(!w.submit { _ in state.add(88); return true }, "failure closes gate independently of retire")
        w.retire(); check(wait(cleaned), "error cleanup"); check(drained(w), "error permit release")
        check(state.snapshot == [0, 9], "failed queue never submits successors")
        check(!w.submit { _ in true }, "failed worker refuses jobs")
    }
    // A stuck retirement consumes a lifetime permit. No third session can be
    // created even across independent decoder objects or rapid reconnects.
    do {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let cleaned = DispatchSemaphore(value: 0), secondCleaned = DispatchSemaphore(value: 0)
        guard let a = worker({ entered.signal(); _ = release.wait(timeout: .now() + 3); cleaned.signal() }) else { return 1 }
        a.retire(); check(wait(entered), "drain blocked")
        guard let b = worker({ secondCleaned.signal() }) else { return 1 }
        for _ in 0..<100 { check(DisplayDecodeWorkerLease.acquire() == nil, "global lifetime budget") }
        release.signal(); check(wait(cleaned), "drain released"); check(drained(a), "first permit released")
        b.retire(); check(wait(secondCleaned), "second drain"); check(drained(b), "second permit released")
    }
    print("\(failures == 0 ? "PASS" : "FAIL") display decode worker \(cases) cases")
    return failures
}
