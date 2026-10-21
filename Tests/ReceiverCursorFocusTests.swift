import Foundation

@MainActor
private final class MockReceiverFocusAPI: ReceiverCursorFocusAPI {
    let ownPID: Int32 = 1
    var isActive = false
    var frontmostPID: Int32? = 2
    var now: TimeInterval = 0
    var alive: Set<Int32> = [1, 2, 3]
    var selfActivations = 0
    var targetActivations: [Int32] = []
    var hides = 0
    var restores = 0
    var visible = true
    var queue: [(TimeInterval, @MainActor () -> Void)] = []
    func captureForeground() -> Int32? { frontmostPID }
    func targetIsAlive(_ pid: Int32) -> Bool { alive.contains(pid) }
    func activateSelf() { selfActivations += 1 }
    func activateTarget(_ pid: Int32) { targetActivations.append(pid) }
    func hideWindow() -> Bool { hides += 1; let old = visible; visible = false; return old }
    func restoreWindow() { restores += 1; visible = true }
    func enqueue(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        queue.append((now + delay, action))
    }
    func advance(_ seconds: TimeInterval) {
        let end = now + seconds
        var budget = 1000
        while let index = queue.indices.min(by: { queue[$0].0 < queue[$1].0 }), queue[index].0 <= end {
            budget -= 1
            precondition(budget > 0, "Unbounded scheduling")
            let step = queue.remove(at: index)
            now = step.0
            step.1()
        }
        now = end
    }
}

/// Pure deterministic tests. No NSApplication, windows, or OS activation calls.
@MainActor
enum ReceiverCursorFocusTests {
    static func run() {
        boundedRetryWaitsForDebtAndPhysicalIntent()
        delayedActivationSucceeds()
        focusTimeoutPreservesActivationDebt()
        activationObservedAfterDeadlineNeverReadies()
        typedExternalSwitchAndUnsettledActivation()
        typedMissingForegroundAndLostOwnership()
        alreadyActiveLease()
        canceledActivationSurvivesTimeout()
        restoredTargetMustBeObserved()
        externalSwitchFailsClosed()
        cancellationAndDuplicates()
        terminatedTargetAndUnknownForeground()
        activeBeforeDelegateReconciles()
        canceledClosuresAreReleased()
        noPriorLeaseBarrier()
        completedCycleUsesFreshTarget()
        lateActivationRestoresLatestUserChoice()
        physicalOverrideWhileActiveKeepsOriginalTarget()
        completedTargetDoesNotCreateReleaseDebt()
    }



    private static func boundedRetryWaitsForDebtAndPhysicalIntent() {
        let api = MockReceiverFocusAPI()
        let controller = ReceiverCursorFocusController(api: api)
        var policy = ReceiverFocusRetryPolicy()
        var needed = true; var ready = 0
        var failures: [ReceiverCursorFocusFailure] = []
        func requestIfAllowed() {
            guard needed, policy.begin(now: api.now, unsettled: controller.hasUnsettledActivation) else { return }
            controller.requestTyped(stillNeeded: { needed }, ready: { ready += 1 }, failed: {
                failures.append($0)
                policy.failed(now: api.now)
            })
        }
        requestIfAllowed()
        api.advance(1.001)
        precondition(failures == [.timeout] && policy.attempts == 1 && !controller.isOwned)
        api.advance(0.6); requestIfAllowed()
        precondition(policy.attempts == 1 && api.selfActivations == 1)
        // Cooldown elapsed, but the first activation remains uncancelable.
        api.isActive = true; api.frontmostPID = 1
        controller.didBecomeActive(); requestIfAllowed()
        precondition(policy.attempts == 1 && api.targetActivations == [2])
        api.isActive = false; api.frontmostPID = 2
        requestIfAllowed()
        precondition(policy.attempts == 2 && api.selfActivations == 2)
        api.advance(0.45)
        api.isActive = true; api.frontmostPID = 1
        controller.didBecomeActive(); api.advance(0.02)
        precondition(ready == 1 && failures == [.timeout])
        controller.release()
        api.isActive = false; api.frontmostPID = 2
        requestIfAllowed()
        precondition(policy.attempts == 2 && api.selfActivations == 2)

        // A fresh episode still obeys physical intent: cancellation cannot ready
        // later, and the parent's still-needed gate cannot spend another attempt.
        policy.reset(); requestIfAllowed()
        precondition(policy.attempts == 1 && api.selfActivations == 3)
        needed = false
        api.advance(0.02)
        precondition(!controller.isOwned && controller.hasUnsettledActivation)
        api.isActive = true; api.frontmostPID = 1
        controller.didBecomeActive()
        api.isActive = false; api.frontmostPID = 2
        api.advance(0.6); requestIfAllowed()
        precondition(ready == 1 && failures == [.timeout] && policy.attempts == 1)
        precondition(api.selfActivations == 3 && !controller.hasUnsettledActivation)
    }

    private static func delayedActivationSucceeds() {
        let api = MockReceiverFocusAPI()
        let controller = ReceiverCursorFocusController(api: api)
        var ready = 0; var failures: [ReceiverCursorFocusFailure] = []
        controller.requestTyped(stillNeeded: { true }, ready: { ready += 1 }, failed: { failures.append($0) })
        api.advance(0.45)
        precondition(ready == 0 && failures.isEmpty && controller.isOwned)
        api.isActive = true; api.frontmostPID = 1
        controller.didBecomeActive(); api.advance(0.02)
        precondition(ready == 1 && failures.isEmpty && controller.isOwned)
        precondition(api.selfActivations == 1)
        controller.release()
        precondition(api.targetActivations == [2])
    }

    private static func focusTimeoutPreservesActivationDebt() {
        let api = MockReceiverFocusAPI()
        let controller = ReceiverCursorFocusController(api: api)
        var ready = 0; var failures: [ReceiverCursorFocusFailure] = []
        controller.requestTyped(stillNeeded: { true }, ready: { ready += 1 }, failed: {
            precondition(!controller.isOwned && controller.hasUnsettledActivation)
            failures.append($0)
        })
        api.advance(0.999)
        precondition(failures.isEmpty && controller.isOwned)
        api.advance(0.002)
        precondition(failures == [.timeout] && ready == 0 && api.restores == 1)
        controller.requestTyped(stillNeeded: { true }, ready: { ready += 1 }, failed: { failures.append($0) })
        precondition(failures == [.timeout, .unsettledActivation] && api.selfActivations == 1)
        // A timeout cannot erase activation debt, even when the original target
        // is still foreground. The unchanged target barrier also fails closed.
        var result: Bool?
        controller.prepareInputTarget(stillNeeded: { true }) { result = $0 }
        api.advance(0.349)
        precondition(result == nil)
        api.advance(0.002)
        precondition(result == false && controller.hasUnsettledActivation)
        api.isActive = true; api.frontmostPID = 1
        controller.didBecomeActive(); api.advance(0.1)
        precondition(ready == 0 && api.targetActivations == [2])
        precondition(controller.hasUnsettledActivation && !controller.isOwned)
        api.isActive = false; api.frontmostPID = 2
        precondition(!controller.hasUnsettledActivation)
        api.advance(1.1)
        precondition(ready == 0 && failures == [.timeout, .unsettledActivation])
    }

    private static func activationObservedAfterDeadlineNeverReadies() {
        let api = MockReceiverFocusAPI()
        let controller = ReceiverCursorFocusController(api: api)
        var failure: ReceiverCursorFocusFailure?
        controller.requestTyped(stillNeeded: { true }, ready: { preconditionFailure() }, failed: { failure = $0 })
        // Simulate a delayed main queue: activation is observed only after the
        // deadline, before the overdue polling callback has had a chance to run.
        let queued = api.queue.removeFirst()
        api.now = 1.01; api.isActive = true; api.frontmostPID = 1
        controller.didBecomeActive()
        queued.1()
        precondition(failure == .timeout && !controller.isOwned)
        precondition(api.targetActivations == [2])
    }

    private static func typedExternalSwitchAndUnsettledActivation() {
        let api = MockReceiverFocusAPI()
        let controller = ReceiverCursorFocusController(api: api)
        var failures: [ReceiverCursorFocusFailure] = []
        controller.requestTyped(stillNeeded: { true }, ready: { preconditionFailure() }, failed: {
            precondition(!controller.isOwned)
            failures.append($0)
        })
        api.frontmostPID = 3; api.advance(0.02)
        precondition(failures == [.externalAppSwitch] && api.targetActivations.isEmpty)
        controller.requestTyped(stillNeeded: { true }, ready: { preconditionFailure() }, failed: { failures.append($0) })
        precondition(failures == [.externalAppSwitch, .unsettledActivation])
        precondition(api.selfActivations == 1 && api.hides == 1)
    }

    private static func typedMissingForegroundAndLostOwnership() {
        let unknown = MockReceiverFocusAPI(); unknown.frontmostPID = nil
        let missing = ReceiverCursorFocusController(api: unknown)
        var failure: ReceiverCursorFocusFailure?
        missing.requestTyped(stillNeeded: { true }, ready: { preconditionFailure() }, failed: { failure = $0 })
        precondition(failure == .missingForeground && !missing.isOwned && unknown.selfActivations == 0)
        let api = MockReceiverFocusAPI(); api.isActive = true; api.frontmostPID = 1
        let controller = ReceiverCursorFocusController(api: api)
        controller.requestTyped(stillNeeded: { true }, ready: {}, failed: { _ in preconditionFailure() })
        api.advance(0.02)
        api.isActive = false; api.frontmostPID = 3
        failure = nil
        controller.requestTyped(stillNeeded: { true }, ready: { preconditionFailure() }, failed: { failure = $0 })
        precondition(failure == .lostOwnership && !controller.isOwned)
    }

    private static func alreadyActiveLease() {
        let api = MockReceiverFocusAPI(); api.isActive = true; api.frontmostPID = 1
        let controller = ReceiverCursorFocusController(api: api)
        var ready = 0
        controller.request(stillNeeded: { true }, ready: { ready += 1 }, failed: { preconditionFailure() })
        precondition(controller.isOwned && ready == 0 && api.selfActivations == 0)
        api.advance(0.02)
        precondition(ready == 1)
        var result: Bool?
        controller.prepareInputTarget(stillNeeded: { true }) { result = $0 }
        precondition(!controller.isOwned && result == nil)
        api.advance(0.02)
        precondition(result == true && api.restores == 1)
    }

    private static func canceledActivationSurvivesTimeout() {
        let api = MockReceiverFocusAPI()
        let controller = ReceiverCursorFocusController(api: api)
        var ready = 0; var failed = 0
        controller.request(stillNeeded: { true }, ready: { ready += 1 }, failed: { failed += 1 })
        precondition(api.selfActivations == 1)
        controller.release()
        var result: Bool?
        controller.prepareInputTarget(stillNeeded: { true }) { result = $0 }
        api.advance(0.36)
        precondition(result == false && ready == 0 && failed == 0)
        controller.request(stillNeeded: { true }, ready: { ready += 1 }, failed: { failed += 1 })
        precondition(failed == 1 && api.selfActivations == 1 && !controller.isOwned)
        // A late OS completion is reconciled even after the barrier timed out.
        api.isActive = true; api.frontmostPID = 1
        controller.didBecomeActive()
        precondition(api.targetActivations == [2] && ready == 0)
        result = nil
        controller.prepareInputTarget(stillNeeded: { true }) { result = $0 }
        api.advance(0.02)
        precondition(result == nil)
        api.isActive = false; api.frontmostPID = 2
        api.advance(0.02)
        precondition(result == true && ready == 0)
    }

    private static func restoredTargetMustBeObserved() {
        let api = MockReceiverFocusAPI()
        let controller = ReceiverCursorFocusController(api: api)
        controller.request(stillNeeded: { true }, ready: {}, failed: { preconditionFailure() })
        api.isActive = true; api.frontmostPID = 1; controller.didBecomeActive(); api.advance(0.02)
        var result: Bool?
        controller.prepareInputTarget(stillNeeded: { true }) { result = $0 }
        precondition(api.targetActivations == [2])
        api.advance(0.1)
        precondition(result == nil, "An activation submission is not a target-ready ACK")
        api.isActive = false; api.frontmostPID = 2
        api.advance(0.02)
        precondition(result == true)
    }

    private static func externalSwitchFailsClosed() {
        let api = MockReceiverFocusAPI()
        let controller = ReceiverCursorFocusController(api: api)
        controller.request(stillNeeded: { true }, ready: { preconditionFailure() }, failed: {})
        api.frontmostPID = 3
        var result: Bool?
        controller.prepareInputTarget(stillNeeded: { true }) { result = $0 }
        api.advance(0.02)
        precondition(result == false && api.targetActivations.isEmpty)
        controller.userReopened() // explicit user intent clears old canceled intent
        api.isActive = true; api.frontmostPID = 1
        var ready = false
        controller.request(stillNeeded: { true }, ready: { ready = true }, failed: { preconditionFailure() })
        api.advance(0.02)
        precondition(ready && controller.isOwned)
    }

    private static func cancellationAndDuplicates() {
        let api = MockReceiverFocusAPI()
        let controller = ReceiverCursorFocusController(api: api)
        var needed = true; var failed = 0; var ready = 0
        controller.request(stillNeeded: { needed }, ready: { ready += 1 }, failed: { failed += 1 })
        controller.request(stillNeeded: { true }, ready: { preconditionFailure() }, failed: { preconditionFailure() })
        precondition(api.selfActivations == 1 && api.hides == 1)
        needed = false
        api.advance(0.02)
        precondition(!controller.isOwned && ready == 0 && failed == 0 && api.restores == 1)
        var result: Bool?
        controller.prepareInputTarget(stillNeeded: { false }) { result = $0 }
        api.advance(0.02)
        precondition(result == false)
    }

    private static func terminatedTargetAndUnknownForeground() {
        let api = MockReceiverFocusAPI()
        let controller = ReceiverCursorFocusController(api: api)
        controller.request(stillNeeded: { true }, ready: {}, failed: {})
        api.alive.remove(2)
        var result: Bool?
        controller.prepareInputTarget(stillNeeded: { true }) { result = $0 }
        api.advance(0.02)
        precondition(result == false && api.targetActivations.isEmpty)
        let unknown = MockReceiverFocusAPI(); unknown.frontmostPID = nil
        let other = ReceiverCursorFocusController(api: unknown)
        var failed = false
        other.request(stillNeeded: { true }, ready: { preconditionFailure() }, failed: { failed = true })
        precondition(failed && unknown.selfActivations == 0)
    }

    private static func activeBeforeDelegateReconciles() {
        let api = MockReceiverFocusAPI()
        let controller = ReceiverCursorFocusController(api: api)
        controller.request(stillNeeded: { true }, ready: { preconditionFailure() }, failed: {})
        controller.release()
        api.isActive = true; api.frontmostPID = 1
        controller.release() // late completion observed before delegate hook
        precondition(api.targetActivations == [2])
        api.isActive = false; api.frontmostPID = 2
        var result: Bool?
        controller.prepareInputTarget(stillNeeded: { true }) { result = $0 }
        api.advance(0.02)
        precondition(result == true)
    }

    private static func noPriorLeaseBarrier() {
        let api = MockReceiverFocusAPI()
        let controller = ReceiverCursorFocusController(api: api)
        var result: Bool?
        controller.prepareInputTarget(stillNeeded: { true }) { result = $0 }
        precondition(controller.hasUnsettledActivation && result == nil)
        api.advance(0.02)
        precondition(result == true && !controller.hasUnsettledActivation)
        precondition(api.hides == 0 && api.selfActivations == 0 && api.targetActivations.isEmpty)
    }

    private static func completedCycleUsesFreshTarget() {
        let api = MockReceiverFocusAPI()
        let controller = ReceiverCursorFocusController(api: api)
        controller.request(stillNeeded: { true }, ready: {}, failed: { preconditionFailure() })
        api.isActive = true; api.frontmostPID = 1
        controller.didBecomeActive(); api.advance(0.02)
        var first: Bool?
        controller.prepareInputTarget(stillNeeded: { true }) { first = $0 }
        api.isActive = false; api.frontmostPID = 2; api.advance(0.02)
        precondition(first == true && !controller.hasUnsettledActivation)
        // No hide request between commits. App 3 is now the intended target.
        api.frontmostPID = 3
        var second: Bool?
        controller.prepareInputTarget(stillNeeded: { true }) { second = $0 }
        api.advance(0.02)
        precondition(second == true && api.targetActivations == [2])
    }

    private static func lateActivationRestoresLatestUserChoice() {
        let api = MockReceiverFocusAPI()
        let controller = ReceiverCursorFocusController(api: api)
        var ready = 0
        controller.request(stillNeeded: { true }, ready: { ready += 1 }, failed: { preconditionFailure() })
        api.frontmostPID = 3
        controller.localUserOverride()
        precondition(!controller.isOwned && controller.hasUnsettledActivation)
        api.advance(0.4)
        precondition(ready == 0 && api.targetActivations.isEmpty)
        api.isActive = true; api.frontmostPID = 1
        controller.didBecomeActive()
        precondition(api.targetActivations == [3] && controller.hasUnsettledActivation)
        var result: Bool?
        controller.prepareInputTarget(stillNeeded: { true }) { result = $0 }
        api.isActive = false; api.frontmostPID = 3; api.advance(0.02)
        precondition(result == true && ready == 0 && !controller.hasUnsettledActivation)
    }

    private static func physicalOverrideWhileActiveKeepsOriginalTarget() {
        let api = MockReceiverFocusAPI()
        let controller = ReceiverCursorFocusController(api: api)
        controller.request(stillNeeded: { true }, ready: {}, failed: { preconditionFailure() })
        api.isActive = true; api.frontmostPID = 1
        controller.didBecomeActive(); api.advance(0.02)
        controller.localUserOverride()
        precondition(!controller.isOwned && api.targetActivations == [2])
    }

    private static func completedTargetDoesNotCreateReleaseDebt() {
        let api = MockReceiverFocusAPI()
        let controller = ReceiverCursorFocusController(api: api)
        controller.request(stillNeeded: { true }, ready: {}, failed: { preconditionFailure() })
        api.isActive = true; api.frontmostPID = 1
        controller.didBecomeActive(); api.advance(0.02)
        var result: Bool?
        controller.prepareInputTarget(stillNeeded: { true }) { result = $0 }
        api.isActive = false; api.frontmostPID = 2; api.advance(0.02)
        precondition(result == true && api.targetActivations == [2])
        // The user subsequently picks another external app. Stop/start/quit
        // releases are idempotent and cannot recreate the historical target debt.
        api.frontmostPID = 3
        controller.release(); controller.release()
        precondition(!controller.hasUnsettledActivation && api.targetActivations == [2])
        // Opening our own settings later is not an old focus lease either.
        api.isActive = true; api.frontmostPID = 1
        controller.didBecomeActive()
        controller.release(); controller.release()
        precondition(!controller.hasUnsettledActivation && !controller.isOwned)
        precondition(api.targetActivations == [2])
    }

    @MainActor private final class Owner {
        let controller: ReceiverCursorFocusController
        init(_ api: MockReceiverFocusAPI) { controller = ReceiverCursorFocusController(api: api) }
    }
    private static func canceledClosuresAreReleased() {
        let api = MockReceiverFocusAPI()
        var owner: Owner? = Owner(api)
        weak var weakOwner = owner
        // Use a true predicate first, then retain owner in the queued callback.
        owner!.controller.request(stillNeeded: { true }, ready: { [captured = owner!] in _ = captured.controller }, failed: {})
        owner!.controller.release()
        owner = nil
        precondition(weakOwner == nil)
        weakOwner = nil
        api.advance(0.4)
    }
}
