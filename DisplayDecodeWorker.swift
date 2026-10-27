import Foundation

/// Process-wide lifetime budget, not just a per-viewer queue limit. A hung VT call or
/// drain consumes a slot permanently until it returns; reconnect fails closed rather
/// than accumulating retired sessions, queues or callback mailboxes without bound.
final class DisplayDecodeWorkerLease {
    private static let lock = NSLock()
    private static var live = 0
    static let limit = 2
    static func acquire() -> DisplayDecodeWorkerLease? {
        lock.lock(); defer { lock.unlock() }
        guard live < limit else { return nil }
        live += 1; return DisplayDecodeWorkerLease()
    }
    private init() {}
    deinit { Self.lock.lock(); Self.live -= 1; Self.lock.unlock() }
}

/// Four jobs including the executing job. Callers also retain their existing codec
/// callback reservations. Retirement never waits on the caller and cleanup executes
/// after all submitted calls, on the same serial queue. A retired job cannot execute.
final class DisplayDecodeWorker {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "ThunderControl.video.decode", qos: .userInteractive)
    private var retired = false, failed = false, drained = false, outstanding = 0
    var hasFailed: Bool { lock.lock(); defer { lock.unlock() }; return failed }
    var isDrained: Bool { lock.lock(); defer { lock.unlock() }; return drained }
    private var lease: DisplayDecodeWorkerLease?
    private var cleanup: (() -> Void)?
    init(lease: DisplayDecodeWorkerLease, cleanup: @escaping () -> Void) {
        self.lease = lease; self.cleanup = cleanup
    }
    @discardableResult func submit(_ call: @escaping (Double) -> Bool, didReturn: (() -> Void)? = nil) -> Bool {
        let enqueued = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard !retired, !failed, outstanding < 4 else { lock.unlock(); return false }
        outstanding += 1
        // Enqueue while holding the gate, so retirement cannot overtake acceptance.
        queue.async { [self] in
            lock.lock(); let run = !retired && !failed; lock.unlock()
            var succeeded = false
            if run {
                let ok = call((ProcessInfo.processInfo.systemUptime - enqueued) * 1000)
                succeeded = ok
                if !ok { lock.lock(); failed = true; lock.unlock() }
            }
            lock.lock(); outstanding -= 1; lock.unlock()
            // Publish callback completions only after this job releases capacity.
            if succeeded { didReturn?() }
        }
        lock.unlock(); return true
    }
    func retire() {
        lock.lock()
        guard !retired else { lock.unlock(); return }
        retired = true
        queue.async { [self] in
            cleanup?(); cleanup = nil
            // The lifetime permit is released only AFTER the callback drain boundary.
            lease = nil
            lock.lock(); drained = true; lock.unlock()
        }
        lock.unlock()
    }
}
