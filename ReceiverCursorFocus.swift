import AppKit

/// Injectable boundary: tests use no running applications or OS activation.
@MainActor
protocol ReceiverCursorFocusAPI: AnyObject {
    var ownPID: Int32 { get }
    var isActive: Bool { get }
    var frontmostPID: Int32? { get }
    var now: TimeInterval { get }
    func captureForeground() -> Int32?
    func targetIsAlive(_ pid: Int32) -> Bool
    func activateSelf()
    func activateTarget(_ pid: Int32)
    func hideWindow() -> Bool
    func restoreWindow()
    func enqueue(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void)
}

@MainActor
private final class AppKitReceiverCursorFocusAPI: ReceiverCursorFocusAPI {
    private weak var window: NSWindow?
    private var rememberedApplication: NSRunningApplication?
    init(window: NSWindow) { self.window = window }
    var ownPID: Int32 { NSRunningApplication.current.processIdentifier }
    var isActive: Bool { NSApp.isActive }
    var frontmostPID: Int32? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    func captureForeground() -> Int32? {
        rememberedApplication = NSWorkspace.shared.frontmostApplication
        return rememberedApplication?.processIdentifier
    }
    func targetIsAlive(_ pid: Int32) -> Bool {
        rememberedApplication?.processIdentifier == pid && rememberedApplication?.isTerminated == false
    }
    func activateSelf() { NSApp.activate(ignoringOtherApps: true) }
    func activateTarget(_ pid: Int32) {
        guard targetIsAlive(pid) else { return }
        rememberedApplication?.activate(options: [.activateIgnoringOtherApps])
    }
    func hideWindow() -> Bool {
        let visible = window?.isVisible == true
        if visible { window?.orderOut(nil) }
        return visible
    }
    func restoreWindow() { window?.orderBack(nil) }
    func enqueue(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { action() }
    }
}

enum ReceiverCursorFocusFailure: String {
    case timeout, externalAppSwitch, unsettledActivation, missingForeground, lostOwnership
}

/// Foreground lease, not proof of cursor invisibility. The parent balances cursor
/// visibility even on show failure, then calls prepareInputTarget before an ACK.
/// Receiver activation occurs only while Source owns input. No input is injected.
@MainActor
final class ReceiverCursorFocusController {
    private enum Kind { case focus, target }
    private final class Attempt {
        let id: UUID
        let kind: Kind
        let deadline: TimeInterval
        var needed: (() -> Bool)?
        var done: ((ReceiverCursorFocusFailure?) -> Void)?
        init(id: UUID, kind: Kind, deadline: TimeInterval,
             needed: @escaping () -> Bool, done: @escaping (ReceiverCursorFocusFailure?) -> Void) {
            self.id = id; self.kind = kind; self.deadline = deadline
            self.needed = needed; self.done = done
        }
        func clear() { needed = nil; done = nil }
    }

    private let api: ReceiverCursorFocusAPI
    private var generation = UUID()
    // The queue retains callbacks; this weak reference avoids owner/controller cycles.
    private weak var pending: Attempt?
    private var targetPID: Int32?
    private var targetCaptured = false
    private var showWindowOnRelease = false
    private var selfActivationOutstanding = false
    private var canceledActivation = false
    private var restorationPending = false
    private var restorationSubmitted = false
    // Replacing a target cannot revoke a restoration already sent to macOS.
    // Keep that ambiguity fail-closed until explicit user reopen.
    private var supersededRestorationOutstanding = false
    private var delivering = false
    private(set) var isOwned = false
    var hasUnsettledActivation: Bool {
        pending != nil || selfActivationOutstanding || canceledActivation ||
        supersededRestorationOutstanding ||
        ((restorationPending || restorationSubmitted) && !targetConfirmed())
    }

    convenience init(window: NSWindow) { self.init(api: AppKitReceiverCursorFocusAPI(window: window)) }
    init(api: ReceiverCursorFocusAPI) { self.api = api }

    func request(stillNeeded: @escaping () -> Bool,
                 ready: @escaping () -> Void, failed: @escaping () -> Void) {
        requestTyped(stillNeeded: stillNeeded, ready: ready, failed: { _ in failed() })
    }

    /// Typed failures distinguish bounded activation latency from user intent.
    /// Timeout releases ownership but never clears uncancelable activation debt.
    func requestTyped(stillNeeded: @escaping () -> Bool,
                      ready: @escaping () -> Void,
                      failed: @escaping (ReceiverCursorFocusFailure) -> Void) {
        guard pending == nil, !delivering else { return }
        let token = generation
        let needed = stillNeeded()
        guard token == generation else { return }
        guard needed else { release(); return }
        reconcile()
        // Uncancelable OS activation from an older lease must be consumed before
        // another lease can begin. A timeout NEVER erases this cancellation record.
        guard !hasUnsettledActivation else { release(); failed(.unsettledActivation); return }
        if isOwned {
            guard api.isActive else { release(); failed(.lostOwnership); return }
            delivering = true
            ready()
            delivering = false
            return
        }
        generation = UUID()
        targetPID = api.captureForeground()
        // A missing foreground is interpretable as our own target only if active.
        if targetPID == nil, api.isActive { targetPID = api.ownPID }
        targetCaptured = true
        guard targetPID != nil else {
            targetCaptured = false
            release()
            failed(.missingForeground)
            return
        }
        isOwned = true
        let attempt = Attempt(id: generation, kind: .focus, deadline: api.now + 1.0,
                              needed: stillNeeded) { failure in
            if let failure { failed(failure) } else { ready() }
        }
        pending = attempt
        showWindowOnRelease = api.hideWindow()
        guard check(attempt) else { return }
        if !api.isActive {
            selfActivationOutstanding = true // before activation's reentrant callbacks
            api.activateSelf()
        }
        schedule(attempt)
    }

    func release() {
        // A remembered target is history, not a restoration obligation. Repeated
        // terminal release must not resurrect a successfully completed old lease.
        let hadFocusDebt = isOwned || selfActivationOutstanding || canceledActivation ||
            restorationPending || restorationSubmitted || supersededRestorationOutstanding
        invalidate()
        isOwned = false // before any operation can notify the app delegate
        if selfActivationOutstanding {
            if api.isActive {
                selfActivationOutstanding = false
                canceledActivation = false
            } else { canceledActivation = true }
        }
        if showWindowOnRelease {
            showWindowOnRelease = false
            api.restoreWindow()
        }
        restorationPending = hadFocusDebt && targetCaptured && targetPID != api.ownPID
        restoreIfSafe()
        // Keep the remembered target through asynchronous restoration and until
        // prepareInputTarget confirms it. Inactive release never discards it.
    }

    /// Parent calls only on commit, AFTER balancing cursor visibility. Completion
    /// true is the sole permission to advance targetReady/active ACK, and the
    /// parent's generation/stillNeeded checks remain mandatory after this callback.
    func prepareInputTarget(stillNeeded: @escaping () -> Bool,
                            completion: @escaping (Bool) -> Void) {
        // A commit without any preceding hide lease must target the CURRENT app,
        // not an absent or stale target left by an earlier completed cycle.
        if !isOwned, !hasUnsettledActivation {
            targetPID = api.captureForeground()
            if targetPID == nil, api.isActive { targetPID = api.ownPID }
            targetCaptured = true
        }
        release() // invalidate all hide/focus callbacks first
        let attempt = Attempt(id: generation, kind: .target, deadline: api.now + 0.35,
                              needed: stillNeeded, done: { completion($0 == nil) })
        pending = attempt
        // Always asynchronous, including an already-confirmed target.
        schedule(attempt)
    }

    /// Local physical input wins over the old pre-hide foreground. Preserve a
    /// pending self-activation cancellation, but reconcile it to the latest user app.
    /// If we are still foreground, keep the original pre-hide target instead.
    func localUserOverride() {
        if let foreground = api.frontmostPID, foreground != api.ownPID {
            if restorationSubmitted, targetPID != foreground {
                supersededRestorationOutstanding = true
            }
            targetPID = api.captureForeground()
            targetCaptured = targetPID != nil
            restorationSubmitted = false
        }
        release()
    }

    /// App delegate must call this even when no input/focus lease is owned.
    /// A late activation of a canceled request can only restore, never ready/ACK.
    func didBecomeActive() { reconcile() }

    /// Explicit user reopen is a new user intent, NOT an activation notification.
    /// Parent must stop/override input first. This abandons old restoration intent;
    /// it cannot revoke an activation request already submitted to macOS.
    func userReopened() {
        invalidate()
        isOwned = false
        selfActivationOutstanding = false
        canceledActivation = false
        supersededRestorationOutstanding = false
        restorationPending = false
        restorationSubmitted = false
        targetCaptured = false
        targetPID = nil
        if showWindowOnRelease {
            showWindowOnRelease = false
            api.restoreWindow()
        }
    }

    private func invalidate() {
        generation = UUID()
        pending?.clear()
        pending = nil
    }
    private func current(_ attempt: Attempt) -> Bool {
        attempt.id == generation && pending === attempt
    }
    private func check(_ attempt: Attempt) -> Bool {
        guard current(attempt), let predicate = attempt.needed else { return false }
        let needed = predicate()
        guard current(attempt) else { return false }
        if !needed {
            let callback = attempt.kind == .target ? attempt.done : nil
            release()
            callback?(.lostOwnership)
            return false
        }
        return true
    }
    private func targetConfirmed() -> Bool {
        guard targetCaptured, let target = targetPID else { return false }
        if target == api.ownPID { return api.isActive && api.frontmostPID == api.ownPID }
        return api.targetIsAlive(target) && api.frontmostPID == target
    }
    private func restoreIfSafe() {
        if targetConfirmed() {
            restorationPending = false
            restorationSubmitted = false
            return
        }
        guard restorationPending, !restorationSubmitted, api.isActive,
              api.frontmostPID == api.ownPID, let target = targetPID,
              target != api.ownPID, api.targetIsAlive(target) else { return }
        restorationSubmitted = true
        api.activateTarget(target) // asynchronous; not target confirmation
    }
    private func reconcile() {
        if api.isActive, selfActivationOutstanding {
            selfActivationOutstanding = false
            if canceledActivation {
                canceledActivation = false
                restorationPending = targetCaptured && targetPID != api.ownPID
            }
        }
        if !isOwned { restoreIfSafe() }
    }
    private func schedule(_ attempt: Attempt) {
        guard current(attempt) else { return }
        let remaining = attempt.deadline - api.now
        guard remaining > 0 else {
            if check(attempt) { finish(attempt, success: false, failure: .timeout) }
            return
        }
        api.enqueue(after: min(0.016, remaining)) { [weak self] in
            guard let self else { attempt.clear(); return }
            self.advance(attempt)
        }
    }
    private func advance(_ attempt: Attempt) {
        guard check(attempt) else { return }
        reconcile()
        guard current(attempt) else { return }
        guard api.now <= attempt.deadline else { finish(attempt, success: false, failure: .timeout); return }
        switch attempt.kind {
        case .focus:
            if api.isActive {
                guard check(attempt) else { return }
                guard api.isActive else { schedule(attempt); return }
                finish(attempt, success: true)
                return
            }
            if let foreground = api.frontmostPID, foreground != targetPID, foreground != api.ownPID {
                finish(attempt, success: false, failure: .externalAppSwitch)
                return
            }
        case .target:
            // A currently correct target is insufficient if a canceled self-
            // activation can still arrive and steal it immediately after ACK.
            if !canceledActivation, !selfActivationOutstanding,
               !supersededRestorationOutstanding, targetConfirmed() {
                guard check(attempt) else { return }
                guard !canceledActivation, !selfActivationOutstanding,
                      !supersededRestorationOutstanding, targetConfirmed() else {
                    schedule(attempt); return
                }
                finish(attempt, success: true)
                return
            }
            if !targetCaptured || targetPID == nil {
                finish(attempt, success: false); return
            }
            if let target = targetPID, target != api.ownPID, !api.targetIsAlive(target) {
                finish(attempt, success: false); return
            }
            if let foreground = api.frontmostPID, foreground != targetPID, foreground != api.ownPID {
                // Do not activate over an unrelated external app switch.
                finish(attempt, success: false); return
            }
        }
        schedule(attempt)
    }
    private func finish(_ attempt: Attempt, success: Bool,
                        failure: ReceiverCursorFocusFailure = .lostOwnership) {
        guard current(attempt) else { return }
        let callback = attempt.done
        pending = nil
        attempt.clear()
        if !success { release() } // failure callback always sees released ownership
        delivering = true
        callback?(success ? nil : failure)
        delivering = false
    }
}
