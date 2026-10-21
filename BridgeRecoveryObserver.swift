import Foundation
import SystemConfiguration

/// Network-state change hints only. The caller must independently validate bridge
/// identity and readiness before acting; a notification is never authentication.
/// Lifecycle and callbacks are serialized on the main queue. Background callers
/// must not call start/stop while the main thread is synchronously waiting on them.
final class BridgeRecoveryObserver {
    private var store: SCDynamicStore?
    private var callbackBox: CallbackBox?

    // Not actor-isolated: usable from SystemConfiguration's C callback in Swift 5.
    private final class CallbackBox {
        // Accessed only on the main queue.
        private var onChange: (() -> Void)?

        init(onChange: @escaping () -> Void) {
            self.onChange = onChange
        }

        func notify() {
            // The store is scheduled on main. Also retain this box explicitly if
            // delivery ever needs forwarding, so no queued closure uses raw info.
            if Thread.isMainThread {
                onChange?()
            } else {
                DispatchQueue.main.async { [self] in
                    self.onChange?()
                }
            }
        }

        func invalidate() {
            onChange = nil
        }
    }

    @discardableResult
    func start(onChange: @escaping () -> Void) -> Bool {
        onMain {
            self.stopOnMain()

            let box = CallbackBox(onChange: onChange)
            var context = SCDynamicStoreContext(
                version: 0,
                info: Unmanaged.passUnretained(box).toOpaque(),
                retain: { info in
                    let box = Unmanaged<CallbackBox>.fromOpaque(info)
                    _ = box.retain()
                    return info
                },
                release: { info in
                    Unmanaged<CallbackBox>.fromOpaque(info).release()
                },
                copyDescription: nil
            )

            guard let newStore = SCDynamicStoreCreate(
                nil,
                "ThunderControl.BridgeRecoveryObserver" as CFString,
                { _, _, info in
                    guard let info = info else { return }
                    // CF owns the context retain for the duration of this call.
                    let box = Unmanaged<CallbackBox>.fromOpaque(info)
                        .takeUnretainedValue()
                    box.notify()
                },
                &context
            ) else {
                box.invalidate()
                return false
            }

            self.callbackBox = box
            self.store = newStore
            let patterns = [
                "^State:/Network/Interface/bridge0/.*$",
                "^State:/Network/Interface/.*/Link$",
                "^State:/Network/Service/.*/IPv4$"
            ] as CFArray

            guard SCDynamicStoreSetNotificationKeys(newStore, nil, patterns),
                  SCDynamicStoreSetDispatchQueue(newStore, DispatchQueue.main)
            else {
                self.stopOnMain()
                return false
            }
            // Initial readiness is checked separately by the caller.
            return true
        }
    }

    func stop() {
        onMain { self.stopOnMain() }
    }

    private func stopOnMain() {
        // Invalidate first: queued notifications retaining an old store/context
        // cannot call application code, including after a subsequent start.
        callbackBox?.invalidate()
        if let store = store {
            _ = SCDynamicStoreSetDispatchQueue(store, nil)
        }
        store = nil
        callbackBox = nil
    }

    private func onMain<T>(_ body: () -> T) -> T {
        if Thread.isMainThread {
            return body()
        }
        return DispatchQueue.main.sync(execute: body)
    }

    deinit {
        stop()
    }
}
