#if TC_QUALITY_TIERS
import Foundation

/// Deterministic policy routing and bounded-queue checks. No renderer/panel claims.
func runDisplayRuntimePresentationTests() -> Int {
    var failures = 0
    func verify(_ value: Bool, _ name: String) {
        if !value { failures += 1; print("FAIL DisplayRuntimePresentation: \(name)") }
    }
    verify(DisplayFrameSelectionPolicy.forPresentationMode(.response) == .latest, "response fallback is newest-only")
    verify(DisplayFrameSelectionPolicy.forPresentationMode(.smooth) == .sequenceCatchUp, "smooth explicitly selects sequenceCatchUp")
    var pacer = DisplayFramePacer<Int>(selectionPolicy: .forPresentationMode(.smooth))
    pacer.offer(1, at: 0); pacer.offer(2, at: 0)
    verify(pacer.take(now: 0, targetTimestamp: 0) == 1, "smooth FIFO has no initial age cushion")
    verify(pacer.pendingCount == 1, "smooth retains spare decoded frame")
    for index in 3...100 { pacer.offer(index, at: 0) }
    verify(pacer.pendingCount == 2, "smooth queue remains bounded at two")
    verify(pacer.stats.overflowReplaced == 97, "overflow retires oldest decoded frames")
    pacer.clear()
    verify(!pacer.pending && pacer.stats == DisplayFramePacingStats(), "transition clear resets queue and clock statistics")
    verify(pacer.take(now: 1, targetTimestamp: 1) == nil, "cleared frame cannot reappear")
    pacer.offer(101, at: 2)
    verify(pacer.take(now: 2, targetTimestamp: 2) == 101, "new epoch resumes without old pacing budget")
    return failures
}

/// Main-actor lifecycle test without creating an NSWindow or invoking VT decode.
/// Parent test harness must call this separately on main, as with viewer tests.
@MainActor func runDisplayRuntimeViewerModeTests() -> Int {
    var failures = 0
    func verify(_ value: Bool, _ name: String) {
        if !value { failures += 1; print("FAIL DisplayRuntimeViewerMode: \(name)") }
    }
    let viewer = DisplayViewer()
    verify(viewer.presentationMode == DisplayQualityPreferences.presentation, "initial mode snapshots current preference")
    let initial = viewer.presentationMode
    let other: DisplayPresentationMode = initial == .response ? .smooth : .response
    let before = viewer.qualityPresentationGenerationForTests
    viewer.setPresentationMode(other)
    verify(viewer.presentationMode == other, "live selection is applied")
    verify(viewer.qualityPresentationGenerationForTests != before, "mode change retires pacing generation")
    verify(viewer.pacingPendingForTests == 0 && !viewer.readinessRequestedForTests, "transition clears queues and readiness")
    verify(!viewer.pacingActiveForTests, "mode change never opens a closed viewer")
    let changed = viewer.qualityPresentationGenerationForTests
    viewer.setPresentationMode(other)
    verify(viewer.qualityPresentationGenerationForTests == changed, "same mode is an idempotent no-op")
    viewer.setPresentationMode(initial); viewer.setPresentationMode(other)
    verify(viewer.presentationMode == other, "last serialized choice wins")
    viewer.clear()
    verify(viewer.pacingPendingForTests == 0 && !viewer.pacingActiveForTests, "stop clears presentation resources")
    verify(viewer.receivedFrameCount == 0, "mode-only changes never create decoder output")
    return failures
}
#endif
