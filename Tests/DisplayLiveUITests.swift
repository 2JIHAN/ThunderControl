import AppKit
import CoreGraphics
import Darwin

private enum DisplayLiveUITestError: Error, LocalizedError {
    case failed(String)
    var errorDescription: String? { if case let .failed(stage) = self { return "Display viewer UI test failed: " + stage }; return nil }
}

private func displayLiveRequire(_ condition: Bool, _ stage: String) throws {
    if !condition { throw DisplayLiveUITestError.failed(stage) }
}

/// Reads ONLY an explicitly supplied, bounded helper --synthetic recording. The
/// synthetic zero display ID is required; production display captures cannot be
/// accidentally accepted as this fixture. This does not open a device or socket.
private func displayLiveSyntheticFrames(_ path: String, format: DisplayVideoFormat) throws -> [Data] {
    let deadline = ProcessInfo.processInfo.systemUptime + 3
    let fd = path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
    try displayLiveRequire(fd >= 0, "fixture open")
    defer { Darwin.close(fd) }
    var info = stat()
    try displayLiveRequire(fstat(fd, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG && info.st_size > 0 && info.st_size <= 40 * 1024 * 1024, "fixture bounds")
    var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
    try bytes.withUnsafeMutableBytes { raw in
        var offset = 0
        while offset < raw.count {
            try displayLiveRequire(ProcessInfo.processInfo.systemUptime < deadline, "fixture read timeout")
            let count = Darwin.read(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            if count < 0 && errno == EINTR { continue }
            try displayLiveRequire(count > 0, "fixture truncated")
            offset += count
        }
    }
    var extra: UInt8 = 0
    try displayLiveRequire(Darwin.read(fd, &extra, 1) == 0, "fixture changed")
    var offset = 0, sawIdentity = false, frames: [Data] = []
    while offset < bytes.count {
        try displayLiveRequire(offset + 4 <= bytes.count, "fixture header")
        let size = Int(bytes[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        offset += 4
        try displayLiveRequire(size > 0 && size <= 4 * 1024 * 1024 && size <= bytes.count - offset, "fixture packet size")
        let packet = Data(bytes[offset..<(offset + size)]); offset += size
        if !sawIdentity {
            try displayLiveRequire(packet == Data([1, 0, 0, 0, 0]), "synthetic-only identity")
            sawIdentity = true
        } else {
            try displayLiveRequire([2, 9].contains(packet.first) && frames.count < 8, "fixture video count")
            _ = try DisplayH264Packet(packet, format: format)
            frames.append(packet)
        }
    }
    try displayLiveRequire(sawIdentity && frames.count == 8, "eight synthetic frames required")
    return frames
}

private func displayLiveVerifyScreenshot(_ path: String) throws -> Int {
    var info = stat()
    try displayLiveRequire(path.withCString { lstat($0, &info) } == 0 && (info.st_mode & S_IFMT) == S_IFREG && info.st_size > 0 && info.st_size <= 32 * 1024 * 1024, "own-window screenshot file")
    let data = try Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
    guard let bitmap = NSBitmapImageRep(data: data) else { throw DisplayLiveUITestError.failed("screenshot decode") }
    try displayLiveRequire(bitmap.pixelsWide >= 480 && bitmap.pixelsHigh >= 270, "screenshot dimensions")
    // Exclude native titlebar/edges: require a large colorful, opaque interior.
    // Only aggregate counts are returned. No pixels or user content are logged.
    var samples = 0, colorful = 0
    var minimum = 255, maximum = 0
    var colors = Set<UInt32>()
    for y in stride(from: bitmap.pixelsHigh / 8, to: bitmap.pixelsHigh * 7 / 8, by: max(1, bitmap.pixelsHigh / 32)) {
        for x in stride(from: bitmap.pixelsWide / 8, to: bitmap.pixelsWide * 7 / 8, by: max(1, bitmap.pixelsWide / 40)) {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            let channels = [color.redComponent, color.greenComponent, color.blueComponent].map { Int(max(0, min(255, ($0 * 255).rounded()))) }
            samples += 1
            if color.alphaComponent > 0.9 && channels.max()! > 40 && channels.max()! - channels.min()! > 15 { colorful += 1 }
            minimum = min(minimum, channels.min()!); maximum = max(maximum, channels.max()!)
            colors.insert(UInt32(channels[0] / 8) << 10 | UInt32(channels[1] / 8) << 5 | UInt32(channels[2] / 8))
        }
    }
    try displayLiveRequire(samples > 200 && colorful * 100 >= samples * 70 && maximum - minimum > 80 && colors.count >= 32, "native layer must display colorful generated video, not black")
    let attribute = "com.apple.quarantine"
    let length = path.withCString { file in attribute.withCString { name in getxattr(file, name, nil, 0, 0, XATTR_NOFOLLOW) } }
    if length >= 0 {
        try displayLiveRequire(path.withCString { file in attribute.withCString { name in removexattr(file, name, XATTR_NOFOLLOW) } } == 0, "screenshot quarantine removal")
    } else { try displayLiveRequire(errno == ENOATTR, "screenshot attribute read") }
    let remaining = path.withCString { file in attribute.withCString { name in getxattr(file, name, nil, 0, 0, XATTR_NOFOLLOW) } }
    try displayLiveRequire(remaining < 0 && errno == ENOATTR, "screenshot quarantine verification")
    return colorful
}

/// Explicit CLI-only fixture. It opens only this test's viewer and a dummy focus
/// window, uses generated H.264, and captures only the known viewer window ID.
/// It does not create a virtual display, initiate networking, or post input.
/// Parent wiring: --display-viewer-ui-test <synthetic.frames> <new-output.png>.
@MainActor func runDisplayViewerUITests(path: String, output: String, format: DisplayVideoFormat = .standard, targetScreen: NSScreen? = nil, startsFullScreen: Bool = false) async throws {
    try displayViewerStartupLifecycleTests()
    guard #available(macOS 14.0, *) else { throw DisplayLiveUITestError.failed("macOS14 required") }
    try displayLiveRequire(format.valid, "valid expected format")
    let rawFrames = try displayLiveSyntheticFrames(path, format: format)
    func number(_ value: UInt64, _ bytes: Int = 8) -> Data { Data((0..<bytes).reversed().map { UInt8(truncatingIfNeeded: value >> ($0*8)) }) }
    let frames = rawFrames.enumerated().map { index, video in Data([6])+number(UInt64(index))+number(100)+number(110)+number(150)+video }
    func cursor(_ sequence: UInt64, visible: Bool, x: UInt64 = 500_000, y: UInt64 = 500_000) -> Data { Data([7])+number(sequence)+Data([visible ? 1:0,0])+number(x,4)+number(y,4) }
    let outputURL = URL(fileURLWithPath: output).standardizedFileURL
    try displayLiveRequire(output.hasPrefix("/") && outputURL.pathExtension.lowercased() == "png" && outputURL.resolvingSymlinksInPath().path == outputURL.path && !FileManager.default.fileExists(atPath: outputURL.path), "new non-symlink PNG output required")
    let application = NSApplication.shared
    let previousApp=NSWorkspace.shared.frontmostApplication
    defer {if let previousApp,previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier,!previousApp.isTerminated {previousApp.activate(options:[])}}
    try displayLiveRequire(application.delegate == nil && application.windows.allSatisfy { !$0.isVisible }, "standalone test application required")
    // AppKit may return false when the process is already regular. Actual
    // active/key visible-window state is required below instead.
    _ = application.setActivationPolicy(CommandLine.arguments.contains("--accessory-viewer") ? .accessory:.regular)
    if !application.isRunning {application.finishLaunching()}
    let initialWindowIDs = Set(application.windows.map(\.windowNumber))
    let viewer = DisplayViewer(format: format, targetScreen: targetScreen);viewer.acceptsViewerInput=false;viewer.startsFullScreen=startsFullScreen
    var gained = 0, lost = 0, closed = 0
    viewer.onFocusGained = { gained += 1 }
    viewer.onFocusLost = { lost += 1 }
    viewer.onClose = { closed += 1 }
    let ownershipFixture=App(relay:Relay())
    ownershipFixture.sourceWindowOwnership.eligibleViewer={viewer.isOpenForSourceOwnership ? viewer:nil}
    viewer.onWillClose={ownershipFixture.relay.pauseSourceForForegroundLoss()}
    let deadline = ProcessInfo.processInfo.systemUptime + 25
    func pump(until condition: () -> Bool, maximum: Double,stage:String) async throws {
        let end = min(deadline, ProcessInfo.processInfo.systemUptime + maximum)
        while !condition() && ProcessInfo.processInfo.systemUptime < end {
            try await Task.sleep(nanoseconds:5_000_000)
        }
        try displayLiveRequire(condition(), "bounded native UI wait: "+stage)
    }
    defer { viewer.onClose = nil; viewer.onFocusLost = nil; viewer.onFocusGained = nil; viewer.close() }
    viewer.show()
    let created = application.windows.filter { !initialWindowIDs.contains($0.windowNumber) && $0.title == TCText("Mac mini Extended Display") }
    try displayLiveRequire(created.count == 1, "exact own viewer window")
    let window = created[0]
    if startsFullScreen {
        try displayLiveRequire(viewer.isVideoPresentationReadyForTests && window.alphaValue == 1 && viewer.presentationStats.submitted == 0, "usable visible video surface before native fullscreen confirmation")
        viewer.show()
        try displayLiveRequire(viewer.isVideoPresentationReadyForTests && window.alphaValue == 1, "re-show pending viewer stays visible without a second toggle")
    } else {
        try displayLiveRequire(viewer.isVideoPresentationReadyForTests && window.alphaValue == 1, "explicit windowed mode starts visibly without fullscreen wait")
    }
    // Drive the same coordinator methods as production App callbacks. No input
    // Relay is connected; these windows own only generated fixture pixels.
    ownershipFixture.sourceWindowOwnership.request(stop:{})
    var enteredFullScreen = false
    let fullScreenObserver = NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { _ in
        enteredFullScreen = true
    }
    defer { NotificationCenter.default.removeObserver(fullScreenObserver) }
    try displayLiveRequire(window.contentAspectRatio == format.size, "negotiated content aspect")
    if let targetScreen { try displayLiveRequire(targetScreen.visibleFrame.contains(window.frame), "preferred screen bounds") }
    if startsFullScreen {
        try await pump(until: { enteredFullScreen && viewer.isFullScreenForTests }, maximum: 10, stage: "native fullscreen entry")
        // Re-showing an existing viewer must not toggle it back out of fullscreen.
        viewer.show()
        try displayLiveRequire(viewer.isFullScreenForTests && viewer.isVideoPresentationReadyForTests && window.alphaValue == 1, "existing viewer remains fullscreen and visible only after confirmed entry")
    }
    try await pump(until: { window.isKeyWindow && application.isActive && gained > 0 }, maximum: 3,stage:"initial active key viewer")
    try displayLiveRequire(ownershipFixture.sourceWindowOwnership.hasStableOwnership,"actual coordinator recognizes exact key viewer")
    ownershipFixture.sourceWindowOwnership.request(stop:{})
    try displayLiveRequire(window.isKeyWindow && ownershipFixture.sourceWindowOwnership.hasStableOwnership,"HUD must not steal viewer key ownership")
    try displayLiveRequire(ownershipFixture.sourceWindowOwnership.restore() && window.isVisible,"local return keeps viewer visible")
    for (index, packet) in frames.prefix(7).enumerated() {
        try displayLiveRequire(closed == 0, "viewer unexpectedly closed")
#if TC_ADAPTIVE_PRESENTATION
        // Feed at panel rate: faster bursts are dropped by design to bound added delay.
        try await Task.sleep(nanoseconds: 17_000_000)
#endif
        try viewer.accept(packet)
        try await pump(until: { viewer.receivedFrameCount == index + 1 && viewer.presentationStats.submitted == UInt64(index + 1) }, maximum: 1,stage:"decode and submit frame \(index+1)")
#if TC_TIMED_PRESENTATION
        print("Scheduled fixture enqueue receipt frame=\(index+1) evidence=\(viewer.lastScheduledEnqueueForTests ?? [:]); enqueueNotDisplayed=true")
#endif
    }
    let dummy = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 260, height: 100), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    dummy.title = "ThunderControl focus-only test"
    dummy.isReleasedWhenClosed = false
    defer { dummy.close() }
    let gainsBefore = gained, lossesBefore = lost
#if TC_TIMED_PRESENTATION
    // Do not intentionally mutate focus while the previous sample's promised
    // PTS/duration is still future. Clock elapsed is not display confirmation.
    try await pump(until: { viewer.targetElapsed }, maximum: 1, stage: "frame seven target plus duration elapsed before focus loss")
#endif
    dummy.makeKeyAndOrderFront(nil)
    try await pump(until: { dummy.isKeyWindow && lost > lossesBefore }, maximum: 2,stage:"focus loss")
    try displayLiveRequire(closed == 0 && viewer.receivedFrameCount == 7 && viewer.presentationStats.submitted == 7 && window.isVisible, "focus loss must preserve viewer/video")
    try displayLiveRequire(!ownershipFixture.sourceWindowOwnership.hasStableOwnership,"arbitrary dummy key window cannot own source input")
    try viewer.accept(frames[7])
    try await pump(until:{viewer.receivedFrameCount==8 && viewer.presentationStats.submitted==8},maximum:1,stage:"new video while viewer lacks key focus")
    try displayLiveRequire(dummy.isKeyWindow,"video arrival must not steal keyboard focus")
#if TC_TIMED_PRESENTATION
    print("Scheduled fixture enqueue receipt frame=8 evidence=\(viewer.lastScheduledEnqueueForTests ?? [:]); enqueueNotDisplayed=true")
    try await pump(until: { viewer.targetElapsed }, maximum: 1, stage: "frame eight target plus duration elapsed before focus return")
#endif
    window.makeKeyAndOrderFront(nil)
    try await pump(until: { window.isKeyWindow && gained > gainsBefore }
, maximum: 2,stage:"focus return")
    dummy.close()
    try displayLiveRequire(closed == 0 && viewer.receivedFrameCount == 8 && viewer.presentationStats.submitted == 8, "focus return must preserve video")
    try displayLiveRequire(viewer.receivedCadenceCountForTests == 8 && viewer.submittedCadenceCountForTests == 8 && viewer.sourceEncodeSamplesForTests == 8, "all frame cadence points counted")
    try displayLiveRequire(viewer.pacingActiveForTests && viewer.pacingTicksForTests > 0 && viewer.pacingPendingForTests == 0, "actual display-link pacing active and decoded queue drained")
#if TC_TIMED_PRESENTATION
    try displayLiveRequire(viewer.hasPresentationTimebaseForTests && viewer.scheduledSampleCountForTests == 8 && viewer.lastScheduledPTSForTests.isNumeric && viewer.lastScheduledPTSForTests.seconds > 0, "host-clock timebase and eight scheduled sample PTS")
#endif
#if TC_DEADLINE_PRESENTATION
    try displayLiveRequire(viewer.deadlineMaximumFutureForTests <= 2 && viewer.deadlineMaximumFutureForTests > 0, "bounded future slot commitments")
    try displayLiveRequire(viewer.deadlineEndLeadForTests.isFinite && viewer.deadlineEndLeadForTests > 0, "every fixture enqueue ends before its host PTS")
    print("PASS deadline enqueue receipts: maxFuture=\(viewer.deadlineMaximumFutureForTests) minimumEndLeadMs=\(viewer.deadlineEndLeadForTests) last=\(viewer.deadlineLastEnqueueForTests ?? [:]); not scanout")
#endif
    let readinessBefore = viewer.readinessCallbacksForTests
    try displayLiveRequire(viewer.requestReadinessForTests(), "register actual native renderer readiness callback")
    try await pump(until:{viewer.readinessCallbacksForTests == readinessBefore+1 && !viewer.readinessRequestedForTests}, maximum:2, stage:"one-shot readiness callback with no pending pixel")
    // Exercise the real asynchronous renderer API on this native generated-video
    // surface. Delivery is cumulative/asynchronous: do not equate total with our
    // eight enqueue calls or interpret these counters as physical panel refresh.
    if #available(macOS 14.4, *) {
        let metricsStartedAt = ProcessInfo.processInfo.systemUptime
        let metricsEnd = min(deadline, metricsStartedAt + 6)
#if TC_TIMED_PRESENTATION || TC_DEADLINE_PRESENTATION || TC_IMMEDIATE_PRESENTATION
        let minimumMetricTotal: Double = 8
#else
        let minimumMetricTotal: Double = 1
#endif
        var lastMetricsRequestAt: Double?
        while ((viewer.rendererMetricsForTests?["sampleTime"] ?? 0) < metricsStartedAt || (viewer.rendererMetricsForTests?["totalNumberOfFrames"] ?? 0) < minimumMetricTotal) && ProcessInfo.processInfo.systemUptime < metricsEnd {
            let requested = viewer.requestRendererMetricsForTests()
            if requested {
                let requestedAt = ProcessInfo.processInfo.systemUptime
                if let previous = lastMetricsRequestAt { try displayLiveRequire(requestedAt - previous >= 1.999, "renderer metrics requests at most once per two seconds") }
                lastMetricsRequestAt = requestedAt
                try displayLiveRequire(viewer.rendererMetricsPendingForTests && !viewer.requestRendererMetricsForTests(), "renderer metrics single pending request")
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard let sample = viewer.rendererMetricsForTests else { throw DisplayLiveUITestError.failed("native renderer metrics callback") }
        try displayLiveRequire(sample["available"] == 1 && (sample["sampleTime"] ?? 0) >= metricsStartedAt && (sample["totalNumberOfFrames"] ?? 0) > 0, "native renderer nonnil metrics and positive cumulative total")
        for name in ["numberOfDroppedFrames", "numberOfCorruptedFrames", "totalAccumulatedFrameDelay", "sampleTime"] {
            guard let value = sample[name] else { throw DisplayLiveUITestError.failed("renderer metric missing: " + name) }
            try displayLiveRequire(value.isFinite && value >= 0, "finite nonnegative renderer metric: " + name)
        }
#if TC_TIMED_PRESENTATION || TC_DEADLINE_PRESENTATION || TC_IMMEDIATE_PRESENTATION
        try displayLiveRequire(sample["totalNumberOfFrames"] == 8 && sample["numberOfDroppedFrames"] == 0, "scheduled fixture renderer total eight, dropped zero; not scanout proof")
#endif
        // Only test the post-completion throttle while still inside the request
        // interval. A very delayed callback may legitimately finish after it.
        if let requestedAt = lastMetricsRequestAt, ProcessInfo.processInfo.systemUptime - requestedAt < 2 {
            try displayLiveRequire(!viewer.requestRendererMetricsForTests(), "renderer metrics two-second rate limit after completed sample")
        }
        print("PASS native renderer metrics: submitted=\(viewer.presentationStats.submitted) sample=\(sample); cumulative asynchronous API counts, not enqueue equality or physical-panel/stable60 proof")
    }
    try viewer.acceptCursor(cursor(0, visible:true))
    try displayLiveRequire(viewer.cursorVisibleForTests && viewer.cursorFrameForTests.width > 0 && viewer.cursorFrameForTests.height > 0, "separate cursor has actual layer and image")
    let centerCursor = viewer.cursorFrameForTests
    try viewer.acceptCursor(cursor(1, visible:true, x:750_000, y:250_000))
    try displayLiveRequire(viewer.cursorFrameForTests.minX > centerCursor.minX && viewer.cursorFrameForTests.minY > centerCursor.minY, "top-left normalized cursor mapped into bottom-left native layer")
    do { try viewer.acceptCursor(cursor(1, visible:true)); throw DisplayLiveUITestError.failed("duplicate cursor accepted") } catch DisplayVideoError.malformed {}
    try viewer.acceptCursor(cursor(2, visible:false))
    try displayLiveRequire(!viewer.cursorVisibleForTests, "explicit hidden cursor removes visible overlay")
    try viewer.acceptCursor(cursor(3, visible:true))
    try await pump(until:{!viewer.cursorVisibleForTests},maximum:1,stage:"stale cursor expiry")
    try viewer.acceptCursor(cursor(4, visible:true))
    try displayLiveRequire(viewer.cursorVisibleForTests && !viewer.readinessRequestedForTests, "fresh cursor visible and renderer readiness registration drained")
    // Let the WindowServer compositor consume the immediate sample before the
    // known-window capture. This is not a screen-wide screenshot.
    let renderedAt = ProcessInfo.processInfo.systemUptime + 0.25
    try await pump(until: { ProcessInfo.processInfo.systemUptime >= renderedAt }, maximum: 1,stage:"compositor settle")
    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), "-t", "png", outputURL.path]
    capture.standardOutput = FileHandle.nullDevice; capture.standardError = FileHandle.nullDevice
    try capture.run()
    do { try await pump(until: { !capture.isRunning }, maximum: 5,stage:"window screenshot") }
    catch { if capture.isRunning { capture.terminate() }; throw error }
    try displayLiveRequire(capture.terminationStatus == 0, "own-window screencapture")
    let colorfulSamples = try displayLiveVerifyScreenshot(outputURL.path)
    try displayLiveRequire(closed == 0 && ProcessInfo.processInfo.systemUptime < deadline, "test final state")
    try displayLiveRequire(viewer.readinessCallbacksForTests == readinessBefore+1 && !viewer.readinessRequestedForTests, "no repeated empty readiness callbacks after further native pumping")
    let wasFullscreen=viewer.isFullScreenForTests
    if #available(macOS 14.4, *) {
        // Retire a genuine pending request synchronously before its main-queue
        // completion can run. close/clear must not resurrect its metrics sample.
        var requested = viewer.requestRendererMetricsForTests()
        let requestEnd = min(deadline, ProcessInfo.processInfo.systemUptime + 3)
        while !requested && ProcessInfo.processInfo.systemUptime < requestEnd {
            try await Task.sleep(nanoseconds: 10_000_000)
            requested = viewer.requestRendererMetricsForTests()
        }
        try displayLiveRequire(requested && viewer.rendererMetricsPendingForTests, "pending renderer metrics before close")
    }
    try displayLiveRequire(viewer.requestReadinessForTests(), "pending readiness before close")
#if TC_TIMED_PRESENTATION
    let retiredPresentationGeneration = viewer.presentationGenerationForTests
#endif
    viewer.close()
    try displayLiveRequire(viewer.rendererMetricsForTests == nil, "close clears renderer metrics snapshot")
#if TC_TIMED_PRESENTATION
    try displayLiveRequire(!viewer.hasPresentationTimebaseForTests && viewer.scheduledSampleCountForTests == 0 && !viewer.lastScheduledPTSForTests.isValid && viewer.lastScheduledEnqueueForTests == nil && !viewer.targetElapsed, "close retires scheduled epoch and timebase")
#endif
    try displayLiveRequire(!viewer.cursorVisibleForTests && !viewer.readinessRequestedForTests, "close clears cursor and renderer request")
    try displayLiveRequire(!viewer.pacingActiveForTests && viewer.pacingTicksForTests == 0 && viewer.pacingPendingForTests == 0, "close invalidates display link and clears paced frames")
    try displayLiveRequire(!ownershipFixture.sourceWindowOwnership.hasStableOwnership,"closed viewer cannot leave stale source ownership or activate HUD")
    let closedSettle = ProcessInfo.processInfo.systemUptime + 0.1
    try await pump(until:{ProcessInfo.processInfo.systemUptime >= closedSettle},maximum:0.5,stage:"closed readiness late callback")
    try displayLiveRequire(viewer.rendererMetricsForTests == nil, "late renderer metrics cannot resurrect closed snapshot")
    try displayLiveRequire(!viewer.readinessRequestedForTests && viewer.readinessCallbacksForTests == 0, "no callback resurrects closed viewer readiness counters")
#if TC_TIMED_PRESENTATION
    // Reuse the viewer object, not its old layer, decoder callbacks or epoch.
    viewer.onClose = nil; viewer.onFocusLost = nil; viewer.onFocusGained = nil
    viewer.startsFullScreen = false; viewer.show()
    try displayLiveRequire(!viewer.hasPresentationTimebaseForTests && viewer.presentationGenerationForTests > retiredPresentationGeneration, "reopen starts with retired timebase generation")
    try viewer.accept(frames[0])
    try await pump(until: { viewer.presentationStats.submitted == 1 }, maximum: 1, stage: "fresh reopened scheduled sample")
    try displayLiveRequire(viewer.hasPresentationTimebaseForTests && viewer.scheduledSampleCountForTests == 1 && viewer.lastScheduledPTSForTests.isNumeric && viewer.presentationGenerationForTests > retiredPresentationGeneration, "fresh timebase and scheduled PTS after reopen")
    viewer.close()
#endif
    print("PASS native viewer: activationPolicy=\(application.activationPolicy().rawValue) coordinator=true fullscreen=\(wasFullscreen) decoded=8 submitted=8 colorfulSamples=\(colorfulSamples) focusLossCallbacks=\(lost) focusGainCallbacks=\(gained) expectedClose=1 newFrameWhileUnfocused=true stampedFrames=true separateCursor=true cursorExpiry=true cadence=true readinessCallbackOneShot=true realDisplayLinkPacing=true; own-window generated-pattern screenshot only; no network, virtual display or input posting")
}

/// Pure lifecycle regression coverage: no AppKit activation, capture or input.
/// Also usable independently of the native fullscreen test harness.
func displayViewerStartupLifecycleTests() throws {
    var startup = DisplayViewerStartup()
    try displayLiveRequire(!startup.mayPresentVideo, "idle viewer must not present video")
    startup.begin(fullScreen: true)
    try displayLiveRequire(startup.isPending && startup.mayPresentVideo, "fullscreen startup does not hold video")
    try displayLiveRequire(!startup.requestIfReady(windowReady: false), "wait for native key/active window readiness")
    try displayLiveRequire(startup.requestIfReady(windowReady: true), "ready window requests fullscreen once")
    try displayLiveRequire(!startup.requestIfReady(windowReady: true) && startup.mayPresentVideo, "in-flight transition renders without another toggle")
    startup.didEnterFullScreen()
    try displayLiveRequire(startup.mayPresentVideo && !startup.isPending && !startup.useWindowedFallback(), "confirmed entry cannot be downgraded by stale timeout")
    startup.close(); startup.didEnterFullScreen()
    try displayLiveRequire(!startup.mayPresentVideo && !startup.requestIfReady(windowReady: true), "closed viewer ignores late entry and request")
    startup.begin(fullScreen: true)
    try displayLiveRequire(startup.useWindowedFallback() && startup.mayPresentVideo, "readiness timeout falls back to usable window")
    try displayLiveRequire(!startup.useWindowedFallback() && !startup.requestIfReady(windowReady: true), "fallback is idempotent and cannot toggle")
    startup.begin(fullScreen: true)
    _ = startup.requestIfReady(windowReady: true)
    try displayLiveRequire(startup.useWindowedFallback() && startup.mayPresentVideo, "native failure/entry timeout releases held video")
    startup.didEnterFullScreen()
    try displayLiveRequire(startup.phase == .fullScreen && startup.mayPresentVideo, "late native entry after fallback remains usable without second toggle")
    startup.close(); startup.begin(fullScreen: true)
    _ = startup.requestIfReady(windowReady: true)
    try displayLiveRequire(startup.retryAfterRejection(maximumRetries: 2) && startup.phase == .waitingForWindow, "first AppKit rejection returns to waiting")
    try displayLiveRequire(!startup.retryAfterRejection(maximumRetries: 2), "no retry unless a toggle is in flight")
    _ = startup.requestIfReady(windowReady: true)
    try displayLiveRequire(startup.retryAfterRejection(maximumRetries: 2), "second rejection retries")
    _ = startup.requestIfReady(windowReady: true)
    try displayLiveRequire(!startup.retryAfterRejection(maximumRetries: 2) && startup.useWindowedFallback(), "third rejection falls back to a usable window")
    startup.begin(fullScreen: true)
    try displayLiveRequire(startup.rejectedAttempts == 0, "new viewer resets rejection budget")
    startup.close(); startup.begin(fullScreen: false)
    try displayLiveRequire(startup.mayPresentVideo && !startup.isPending && !startup.requestIfReady(windowReady: true), "explicit windowed/reopened viewer needs no native transition")
    print("PASS viewer startup: readiness gate, one native request, confirmation, bounded usable fallback, late callbacks and reopen; no network/input")
}
