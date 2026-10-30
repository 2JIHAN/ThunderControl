import Foundation
import Darwin

// Standalone: swiftc -swift-version 5 -D DEVELOPMENT_DIAGNOSTICS_TEST_MAIN
// DevelopmentDiagnostics.swift Tests/DevelopmentDiagnosticsTests.swift -o <temporary test executable>
@discardableResult func runDevelopmentDiagnosticsTests() -> Int {
    var failures = 0, checks = 0
    func check(_ condition: Bool, _ label: String) {
        checks += 1; if !condition { failures += 1; print("DevelopmentDiagnostics FAIL: \(label)") }
    }
    let fm = FileManager.default
    guard let physical = realpath(fm.temporaryDirectory.path, nil) else { return 1 }
    let temp = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent("tc-development-tests-" + UUID().uuidString)
    free(physical)
    let stream = String(repeating:"0123456789abcdef",count:4), second = String(repeating:"fedcba9876543210",count:4)
    do {
        try fm.createDirectory(at: temp, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: temp) }
        func own(_ root: URL) throws -> URL {
            let id = try String(contentsOf: root.appendingPathComponent("device-uuid"), encoding: .utf8)
            return root.appendingPathComponent(id)
        }
        func chunks(_ root: URL) throws -> [URL] {
            try fm.contentsOfDirectory(at: own(root), includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("chunk-") && $0.pathExtension == "jsonl" }
        }
        func rows(_ root: URL) throws -> [[String: Any]] {
            try chunks(root).flatMap { url in
                try Data(contentsOf: url).split(separator: 10).map { try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any] }
            }
        }
        // record() deliberately drops rather than waiting for ingress.try(). A
        // fixture requiring a persisted row must first establish acceptance, unlike
        // load, overflow and explicit contention tests whose attempts stay exact.
        // snapshotForTests serializes behind the writer, so a retry follows any
        // contending writer activity without sleeps or changing production policy.
        enum FixtureError: Error { case acceptanceTimedOut(String) }
        func accepted(_ recorder: DevelopmentDiagnostics, _ label: String, record: () -> Void) throws {
            let before = recorder.snapshotForTests()["accepted"] as? Int64 ?? -1
            for _ in 0..<32 {
                record()
                let after = recorder.snapshotForTests()["accepted"] as? Int64 ?? -1
                if after == before + 1 { return }
                guard after == before else { throw FixtureError.acceptanceTimedOut("unexpected accepted delta: " + label) }
            }
            throw FixtureError.acceptanceTimedOut(label)
        }
        func rejectedAsStale(_ recorder: DevelopmentDiagnostics, _ label: String, record: () -> Void) throws {
            let before = recorder.snapshotForTests()
            let acceptedBefore = before["accepted"] as? Int64 ?? -1
            let staleBefore = before["stale"] as? Int64 ?? -1
            for _ in 0..<32 {
                record()
                let after = recorder.snapshotForTests()
                // Never turn privacy validation into an eventual-accept fixture.
                guard after["accepted"] as? Int64 == acceptedBefore else {
                    throw FixtureError.acceptanceTimedOut("stale input was accepted: " + label)
                }
                if after["stale"] as? Int64 == staleBefore + 1 { return }
                guard after["stale"] as? Int64 == staleBefore else {
                    throw FixtureError.acceptanceTimedOut("unexpected stale delta: " + label)
                }
            }
            throw FixtureError.acceptanceTimedOut("missing stale rejection: " + label)
        }
        // Manifest summaries use only the existing async renderer_metrics path.
        check(DevelopmentDiagnostics.receiverPerformanceFields.count == 25 && DevelopmentDiagnostics.receiverPerformanceFields.contains("targetGaps") && !DevelopmentDiagnostics.receiverPerformanceFields.contains("pending") && DevelopmentDiagnostics.receiverPerformanceFields.allSatisfy { $0.utf8.count <= 32 }, "performance numeric schema respects event bounds")
        let performanceRoot = temp.appendingPathComponent("receiver-performance")
        let performance = DevelopmentDiagnostics(root: performanceRoot, diskBytes: 0)
        performance.start(role: "viewer", stream: stream); try performance.flushForTests()
        let performanceSession = performance.snapshotForTests()["session"] as? String
        for index in 0..<140 {
            try accepted(performance, "performance sample") {
                performance.record(stage: "renderer_metrics", sequence: UInt64(index), fields: ["sampleTime": Double(index), "counterSampleTime": Double(index)+0.001, "displayLinkTicks": Double(index*60), "submitted": Double(index*59), "lastSourceSequence": Double(index), "targetGaps": Double(index/3), "privateHostname": 7], stream: stream)
            }
            try performance.flushForTests()
        }
        var performanceStatus = performance.snapshotForTests()
        var ring = performanceStatus["receiverPerformance"] as? [[String: Any]] ?? []
        check(ring.count == 128, "receiver performance hard bound 128")
        check((ring.first?["fields"] as? [String: Double])?["sampleTime"] == 12 && (ring.last?["fields"] as? [String: Double])?["sampleTime"] == 139, "receiver performance retains newest ordered samples")
        check(ring.allSatisfy { $0["stream"] as? String == stream && $0["session"] as? String == performanceSession }, "performance carries exact stream and session")
        check(ring.allSatisfy { ($0["fields"] as? [String: Double])?["privateHostname"] == nil }, "performance explicit privacy allowlist")
        check((ring.last?["fields"] as? [String: Double])?["targetGaps"] == 46, "native target gap counter retained in performance schema")
        performance.start(role: "viewer", stream: stream); try performance.flushForTests()
        check((performance.snapshotForTests()["receiverPerformance"] as? [Any])?.count == 128, "idempotent start preserves performance history")
        check(ring.allSatisfy { ($0["fields"] as? [String: Double])?.values.allSatisfy { $0.isFinite } == true }, "performance fields remain finite")
        check(try chunks(performanceRoot).isEmpty, "performance survives ordinary chunk retention")
        let performanceManifest = try JSONSerialization.jsonObject(with: Data(contentsOf: own(performanceRoot).appendingPathComponent("manifest.json"))) as! [String: Any]
        check((performanceManifest["receiverPerformance"] as? [Any])?.count == 128, "performance ring included in existing manifest")
        performance.record(stage: "renderer_metrics", fields: ["sampleTime": .nan], stream: stream)
        performance.record(stage: "renderer_metrics", fields: ["sampleTime": 140, "submitted": .infinity], stream: stream)
        try accepted(performance, "unrelated stage") { performance.record(stage: "capture", fields: ["sampleTime": 141], stream: stream) }
        try accepted(performance, "missing sample time") { performance.record(stage: "renderer_metrics", fields: ["submitted": 999], stream: stream) }
        try performance.flushForTests()
        check((performance.snapshotForTests()["receiverPerformance"] as? [Any])?.count == 128, "invalid/missing-time/nonrenderer rows do not disturb ring")
        check((performance.snapshotForTests()["nonfinite"] as? Int64 ?? 0) == 2, "performance uses existing nonfinite rejection")
        performance.start(role: "viewer", stream: second); try performance.flushForTests()
        check((performance.snapshotForTests()["receiverPerformance"] as? [Any])?.isEmpty == true, "new stream immediately has empty summary")
        try rejectedAsStale(performance, "old renderer context") { performance.record(stage: "renderer_metrics", fields: ["sampleTime": 142], stream: stream) }
        try accepted(performance, "new renderer context") { performance.record(stage: "renderer_metrics", fields: ["sampleTime": 143, "submitted": 1], stream: second) }
        try performance.flushForTests()
        ring = performance.snapshotForTests()["receiverPerformance"] as? [[String: Any]] ?? []
        check(ring.count == 1 && ring[0]["stream"] as? String == second && ring[0]["session"] as? String != performanceSession, "new ring never carries previous stream identity")
        performance.stop(stream: second); try performance.flushForTests()
        performance.start(role: "viewer", stream: second); try performance.flushForTests()
        check((performance.snapshotForTests()["receiverPerformance"] as? [Any])?.isEmpty == true, "same stream new session resets ring")
        performance.start(role: "source", stream: stream)
        try accepted(performance, "source metrics ignored") { performance.record(stage: "renderer_metrics", fields: ["sampleTime": 145], stream: stream) }
        try performance.flushForTests()
        check((performance.snapshotForTests()["receiverPerformance"] as? [Any])?.isEmpty == true, "source cannot populate receiver summary")
        performanceStatus = performance.snapshotForTests()
        check(performanceStatus["accepted"] as? Int64 == 144 && performanceStatus["overflow"] as? Int64 == 0, "ring does not alter event acceptance accounting")
        check(performance.shutdown(), "performance recorder shutdown")

        let root = temp.appendingPathComponent("privacy")
        let recorder = DevelopmentDiagnostics(root: root)
        check(!fm.fileExists(atPath: root.path), "init has no disk effects")
        try recorder.flushForTests()
        check(!fm.fileExists(atPath: root.path), "unused flush has no disk effects")
        recorder.start(role: "invalid", stream: stream)
        recorder.start(role: "source", stream: "private-hostname")
        check(recorder.currentStream == nil, "invalid role and stream rejected")
        recorder.start(role: "source", stream: stream); try recorder.flushForTests()
        let session = recorder.snapshotForTests()["session"] as? String
        recorder.start(role: "source", stream: stream); try recorder.flushForTests()
        check(recorder.snapshotForTests()["session"] as? String == session, "idempotent start")
        try accepted(recorder, "capture") { recorder.record(stage: "capture", sequence: UInt64.max, fields: ["duration_ms": 2.5], stream: stream) }
        recorder.record(stage: "secret input text", fields: [:])
        recorder.record(stage: "valid", fields: ["raw key text": 1])
        recorder.record(stage: "valid", fields: ["nan": .nan])
        recorder.record(stage: "valid", fields: ["infinity": .infinity])
        try accepted(recorder, "helper capture") { recorder.recordHelperLine("TC_DIAG stage=capture seq=9 capture=1 duration_ms=2.0", stream: stream) }
        try accepted(recorder, "helper failure") { recorder.recordHelperLine("TC_DIAG stage=helper_failure reason_code=4294967295", stream: stream) }
        recorder.recordHelperLine("TC_DIAG stage=capture seq=123456789",stream:nil)
        for line in ["private input", "TC_DIAG stage=privatehostname capture=1", "TC_DIAG stage=encode host=private-host.example", "TC_DIAG stage=encode x=nan", "TC_DIAG stage=encode seq=-1", "TC_DIAG stage=encode x=1 x=2", "TC_DIAG stage=encode bad-key=3", "TC_DIAG stage=encode x=1\ninput"] {
            recorder.recordHelperLine(line, stream: stream)
        }
        try rejectedAsStale(recorder, "wrong stream") { recorder.record(stage: "stale", stream: second) }
        recorder.stop(stream: second)
        check(recorder.currentStream == stream, "stale stop rejected")
        try accepted(recorder, "old context") { recorder.record(stage: "old_context", sequence: 10) }
        recorder.start(role: "viewer", stream: second)
        try accepted(recorder, "new context") { recorder.record(stage: "new_context", sequence: 11) }
        try rejectedAsStale(recorder, "old helper stream") { recorder.recordHelperLine("TC_DIAG stage=encode capture=2", stream: stream) }
        recorder.stop(stream: second); try recorder.flushForTests()
        check(recorder.currentStream == nil, "stop clears active stream and flushes")
        let events = try rows(root)
        check(events.count == 5, "only accepted structured events persisted")
        check(events.first(where: { $0["stage"] as? String == "old_context" })?["stream"] as? String == stream, "old queued context never relabeled")
        check(events.first(where: { $0["stage"] as? String == "new_context" })?["role"] as? String == "viewer", "new role captured")
        check(events.allSatisfy { $0["wall"] != nil && $0["monotonic"] != nil && $0["session"] != nil }, "event timestamps and session")
        let serialized = String(data: try JSONSerialization.data(withJSONObject: events), encoding: .utf8)!
        check(!serialized.contains("private") && !serialized.contains("hostname") && !serialized.contains("input"), "raw payload absent")
        let status = recorder.snapshotForTests()
        check((status["nonfinite"] as? Int64 ?? 0) >= 3 && (status["stale"] as? Int64 ?? 0) >= 3, "explicit drop counters")
        check(status["mirrorDisabled"] as? Bool == true, "absent cloud disabled")
        check(recorder.localDirectoryURL == (try own(root)) && recorder.cloudDirectoryURL == nil, "cached paths")
        check(recorder.shutdown(), "bounded successful shutdown")
        for url in try chunks(root) + [own(root).appendingPathComponent("manifest.json"), root.appendingPathComponent("device-uuid")] {
            let attrs = try fm.attributesOfItem(atPath: url.path)
            check((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "private file permissions")
        }
        check((try fm.attributesOfItem(atPath: own(root).path)[.posixPermissions] as? NSNumber)?.intValue == 0o700, "private directory permissions")
        let contentionBefore = recorder.snapshotForTests()["lockContention"] as? Int64 ?? -1
        recorder.withIngressLockedForTests { recorder.record(stage: "contended"); _ = recorder.currentStream }
        let contentionAfter = recorder.snapshotForTests()["lockContention"] as? Int64 ?? -1
        check(contentionAfter - contentionBefore == 2, "contention counted without waiting")

        // Unlike accepted()-observed fixtures, this writer handshake deliberately
        // holds the old row before persistence while role/stream and pending data
        // change. Never snapshot/flush synchronously while the writer is gated.
        let queuedRoot = temp.appendingPathComponent("queued-context")
        let queuedGate = DispatchSemaphore(value: 0), queuedRelease = DispatchSemaphore(value: 0)
        let queuedFlushDone = DispatchSemaphore(value: 0), queuedProgress = DispatchSemaphore(value: 0)
        defer { for _ in 0..<4 { queuedRelease.signal() } }
        final class FlushOutcome: @unchecked Sendable {
            let lock = NSLock(); private var errors = 0
            func failed() { lock.lock(); errors += 1; lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return errors }
        }
        let queuedOutcome = FlushOutcome()
        let queued = DevelopmentDiagnostics(root: queuedRoot, beforeDrain: {
            queuedGate.signal(); queuedProgress.signal(); queuedRelease.wait()
        })
        queued.start(role: "source", stream: stream); try queued.flushForTests()
        // Empty flushes finish immediately. A nonempty old batch signals the gate
        // and cannot finish until released, proving acceptance without a snapshot.
        var oldBatchHeld = false
        for _ in 0..<32 {
            queued.record(stage: "old_context", sequence: 10, stream: stream)
            DispatchQueue.global(qos: .utility).async {
                do { try queued.flushForTests() } catch { queuedOutcome.failed() }
                queuedFlushDone.signal(); queuedProgress.signal()
            }
            guard queuedProgress.wait(timeout: .now() + 3) == .success else { break }
            if queuedGate.wait(timeout: .now()) == .success { oldBatchHeld = true; break }
            check(queuedFlushDone.wait(timeout: .now()) == .success, "empty queued fixture retry completes")
        }
        check(oldBatchHeld, "old accepted batch held before persistence")
        if oldBatchHeld {
            // Both lifecycle calls must return while the disk writer is blocked.
            queued.start(role: "viewer", stream: second)
            queued.record(stage: "new_context", sequence: 11, stream: second)
            queued.stop(stream: second)
            // First old batch and second new batch each invoke beforeDrain.
            // Surplus permits make all queued cleanup paths safe, including defer.
            for _ in 0..<4 { queuedRelease.signal() }
            check(queuedFlushDone.wait(timeout: .now() + 3) == .success, "old queued flush completes after release")
            try queued.flushForTests()
            let queuedRows = try rows(queuedRoot)
            let old = queuedRows.first { $0["stage"] as? String == "old_context" }
            let new = queuedRows.first { $0["stage"] as? String == "new_context" }
            check(queuedOutcome.count == 0, "gated queued flush has no runtime error")
            check(queuedRows.count == 2 && queued.currentStream == nil, "gated queued lifecycle retains both events and stops")
            check(old?["stream"] as? String == stream && old?["role"] as? String == "source", "held old batch keeps original context")
            check(new?["stream"] as? String == second && new?["role"] as? String == "viewer", "queued new batch keeps new context")
            check(old?["session"] as? String != new?["session"] as? String, "queued context sessions remain distinct")
        }

        let gate = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let boundedRoot = temp.appendingPathComponent("bounded")
        let bounded = DevelopmentDiagnostics(root: boundedRoot, beforeDrain: { gate.signal(); release.wait() })
        bounded.start(role: "source", stream: stream); try bounded.flushForTests()
        for _ in 0..<512 { bounded.record(stage: "frame") }
        check(gate.wait(timeout: .now() + 3) == .success, "disk drain blocked deterministically")
        let begin = ProcessInfo.processInfo.systemUptime
        for _ in 0..<1512 { bounded.record(stage: "frame") }
        let elapsed = ProcessInfo.processInfo.systemUptime - begin
        // pending + in-flight bounded together, with exactly 1000 overflow drops.
        check(elapsed < 2, "hot path independent of blocked filesystem queue")
        check(!bounded.shutdown(timeout: 0.01), "shutdown deadline reports blocked disk queue")
        release.signal()
        // The second queued batch also reaches the deterministic hook.
        release.signal(); release.signal()
        bounded.stop(); try bounded.flushForTests()
        check(bounded.snapshotForTests()["accepted"] as? Int64 == 1024, "1024 outstanding cap including in-flight")
        check(bounded.snapshotForTests()["overflow"] as? Int64 == 1000, "overflow count exact")
        check(try rows(boundedRoot).count == 1024, "accepted records drained")

        let rotationRoot = temp.appendingPathComponent("rotation")
        var date = Date()
        let rotation = DevelopmentDiagnostics(root: rotationRoot, clock: { date }, chunkBytes: 900, diskBytes: 2200)
        rotation.start(role: "source", stream: stream)
        for i in 0..<20 { try accepted(rotation, "rotation frame") { rotation.record(stage: "frame", sequence: UInt64(i)) } }
        try rotation.flushForTests()
        let files = try chunks(rotationRoot)
        check(files.count >= 2, "immutable numbered rotation")
        var bytes = 0
        for url in files { let n = try Data(contentsOf: url).count; bytes += n; check(n <= 900, "chunk byte cap") }
        check(bytes <= 2200 && (rotation.snapshotForTests()["retentionEvictions"] as? Int64 ?? 0) > 0, "device disk budget enforced")
        let unknown = try own(rotationRoot).appendingPathComponent("user-notes.jsonl")
        try Data("preserve me".utf8).write(to: unknown)
        date = date.addingTimeInterval(901)
        try rotation.flushForTests()
        check(try chunks(rotationRoot).isEmpty, "age retention")
        check(try String(contentsOf: unknown, encoding: .utf8) == "preserve me", "unknown user files preserved")
        let previousDevice = try own(rotationRoot)
        let next = DevelopmentDiagnostics(root: rotationRoot, diskBytes: 2200)
        next.start(role: "viewer", stream: second); try accepted(next, "next session frame") { next.record(stage: "frame") }; try next.flushForTests()
        check(try own(rotationRoot) == previousDevice, "stable private device folder")
        let third = DevelopmentDiagnostics(root: rotationRoot, diskBytes: 500)
        third.start(role: "source", stream: stream)
        for i in 0..<10 { try accepted(third, "retention frame") { third.record(stage: "frame", sequence: UInt64(i)) } }
        try third.flushForTests()
        let acrossSessionBytes = try chunks(rotationRoot).reduce(0) { try $0 + Data(contentsOf: $1).count }
        check(acrossSessionBytes <= 500 && (third.snapshotForTests()["retentionEvictions"] as? Int64 ?? 0) > 0, "retention spans previous sessions")

        let outside = temp.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: false)
        let link = temp.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        let unsafe = DevelopmentDiagnostics(root: link.appendingPathComponent("nested"))
        unsafe.start(role: "source", stream: stream); try accepted(unsafe, "unsafe-root frame") { unsafe.record(stage: "frame") }
        do { try unsafe.flushForTests(); check(false, "symlink root refused") } catch { }
        check(try fm.contentsOfDirectory(atPath: outside.path).isEmpty, "no symlink traversal")
        let missingCloud = temp.appendingPathComponent("missing-cloud")
        let absent = DevelopmentDiagnostics(root: temp.appendingPathComponent("absent"), cloudRoot: missingCloud)
        absent.start(role: "viewer", stream: stream); try accepted(absent, "absent-cloud frame") { absent.record(stage: "frame") }; try absent.flushForTests()
        check(!fm.fileExists(atPath: missingCloud.path), "never creates fake cloud root")
        let cloud = temp.appendingPathComponent("cloud")
        try fm.createDirectory(at: cloud, withIntermediateDirectories: false)
        let broken = cloud.appendingPathComponent("ThunderControl-진단")
        try fm.createSymbolicLink(at: broken, withDestinationURL: outside)
        let mirrorFailure = DevelopmentDiagnostics(root: temp.appendingPathComponent("mirror-error"), cloudRoot: cloud)
        mirrorFailure.start(role: "source", stream: stream); try accepted(mirrorFailure, "mirror-error frame") { mirrorFailure.record(stage: "frame") }; try mirrorFailure.flushForTests()
        check(mirrorFailure.snapshotForTests()["mirrorError"] as? Bool == true, "cloud error local status")
        check(try fm.contentsOfDirectory(atPath: outside.path).isEmpty, "cloud symlink not followed")
        try fm.removeItem(at: broken)
        var cloudDate = Date()
        let mirroredRoot = temp.appendingPathComponent("mirrored")
        let mirrored = DevelopmentDiagnostics(root: mirroredRoot, cloudRoot: cloud, clock: { cloudDate }, monotonicClock: { cloudDate.timeIntervalSince1970 })
        mirrored.start(role: "source", stream: stream); try mirrored.flushForTests()
        try accepted(mirrored, "mirrored frame") { mirrored.record(stage: "frame") }; cloudDate = cloudDate.addingTimeInterval(6); try mirrored.flushForTests()
        let cloudDevice = cloud.appendingPathComponent("ThunderControl-진단").appendingPathComponent(try own(mirroredRoot).lastPathComponent)
        check(try fm.contentsOfDirectory(atPath: cloudDevice.path).contains(where: { $0.hasPrefix("chunk-") }), "new chunk mirrored")
        check(mirrored.snapshotForTests()["cloudLastSuccessfulLocalCopy"] != nil, "local cloud copy timestamp, not delivery claim")
        // Lifecycle cannot be silently skipped when a recorder lock is momentarily busy.
        let lifecycle = DevelopmentDiagnostics(root: temp.appendingPathComponent("lifecycle"))
        lifecycle.start(role: "source", stream: stream); try lifecycle.flushForTests()
        try accepted(lifecycle, "before lifecycle switch") { lifecycle.record(stage: "before_switch", stream: stream) }
        let entered = DispatchSemaphore(value: 0), completed = DispatchSemaphore(value: 0)
        lifecycle.withIngressLockedForTests {
            DispatchQueue.global(qos: .utility).async {
                entered.signal(); lifecycle.start(role: "viewer", stream: second); completed.signal()
            }
            check(entered.wait(timeout: .now() + 1) == .success, "concurrent start entered")
            check(completed.wait(timeout: .now() + 0.02) == .timedOut, "lifecycle reliably waits for short memory lock")
            lifecycle.record(stage: "contended_hot_event")
        }
        check(completed.wait(timeout: .now() + 2) == .success, "concurrent start completes after unlock")
        try accepted(lifecycle, "after lifecycle switch") { lifecycle.record(stage: "after_switch", stream: second) }
        lifecycle.withIngressLockedForTests {
            DispatchQueue.global(qos: .utility).async {
                entered.signal(); lifecycle.stop(stream: second); completed.signal()
            }
            check(entered.wait(timeout: .now() + 1) == .success, "concurrent stop entered")
            check(completed.wait(timeout: .now() + 0.02) == .timedOut, "stop cannot be silently lost")
        }
        check(completed.wait(timeout: .now() + 2) == .success, "concurrent stop completes")
        try lifecycle.flushForTests()
        let lifecycleRows = try rows(temp.appendingPathComponent("lifecycle"))
        check(lifecycleRows.count == 2 && lifecycle.currentStream == nil, "concurrent lifecycle preserves both contexts and stops")
        check(lifecycleRows.first(where: { $0["stage"] as? String == "before_switch" })?["stream"] as? String == stream,
              "concurrent switch does not relabel old event")

        final class TestClock: @unchecked Sendable {
            private let lock = NSLock(); private var value = Date()
            func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
            func advance(_ seconds: Double) { lock.lock(); value.addTimeInterval(seconds); lock.unlock() }
        }
        let loadClock = TestClock(), loadRoot = temp.appendingPathComponent("sustained")
        let delayedCloud = temp.appendingPathComponent("delayed-cloud")
        let load = DevelopmentDiagnostics(root: loadRoot, cloudRoot: delayedCloud, clock: { loadClock.now() }, monotonicClock: { loadClock.now().timeIntervalSince1970 })
        load.start(role: "source", stream: stream); try load.flushForTests()
        // 600 realistic structured frame events/sec for ten wall-clock seconds.
        for tick in 0..<100 {
            for frame in 0..<60 {
                load.record(stage: "encoded_callback", sequence: UInt64(tick * 60 + frame),
                            fields: ["capture": Double(tick * 60 + frame), "us": Double(tick * 100000), "duration_us": 1500], stream: stream)
            }
            if tick == 50 { try fm.createDirectory(at: delayedCloud, withIntermediateDirectories: false) }
            usleep(100_000); loadClock.advance(0.1)
            if tick % 10 == 9 { try load.flushForTests() }
        }
        load.stop(stream: stream); try load.flushForTests()
        // Bounded 4 MiB/64-file mirror passes catch up retained local chunks after cloud recovery.
        for _ in 0..<6 { loadClock.advance(6); try load.flushForTests() }
        let loadStatus = load.snapshotForTests()
        let loadAccepted = loadStatus["accepted"] as? Int64 ?? -1
        let loadDropped = loadStatus["dropped"] as? Int64 ?? -1
        check(loadAccepted + loadDropped == 6000, "sustained ingress complete accepted/drop accounting")
        check(loadStatus["written"] as? Int64 == loadAccepted, "sustained accepted records all written")
        check(try rows(loadRoot).count == Int(loadAccepted), "sustained on-disk no silent loss")
        check(loadStatus["mirrorPendingCount"] as? Int == 0, "retained mirror backlog catches up")
        check((loadStatus["mirrorMissCount"] as? Int64 ?? 0) > 0, "cloud outage remains in cumulative status")
        let loadCloudDevice = delayedCloud.appendingPathComponent("ThunderControl-진단").appendingPathComponent(try own(loadRoot).lastPathComponent)
        let loadCloudFiles = try fm.contentsOfDirectory(at: loadCloudDevice, includingPropertiesForKeys: nil).filter { $0.pathExtension == "jsonl" }
        let loadCloudRows = try loadCloudFiles.reduce(0) { try $0 + Data(contentsOf: $1).split(separator: 10).count }
        check(loadCloudRows == Int(loadAccepted), "sustained cloud recovery no silent record loss")
        print("DevelopmentDiagnostics sustained 6000 submissions: accepted=\(loadAccepted), dropped=\(loadDropped), cloudRows=\(loadCloudRows)")
        let copiedBefore = loadStatus["mirroredCount"] as? Int64
        loadClock.advance(6); try load.flushForTests()
        check(load.snapshotForTests()["mirroredCount"] as? Int64 == copiedBefore, "already mirrored chunks not duplicated")
        check(load.shutdown(), "sustained recorder shuts down cleanly")
        let steadyClock=TestClock(),steadyRoot=temp.appendingPathComponent("steady"),steadyCloud=temp.appendingPathComponent("steady-cloud")
        try fm.createDirectory(at:steadyCloud,withIntermediateDirectories:false)
        let steady=DevelopmentDiagnostics(root:steadyRoot,cloudRoot:steadyCloud,clock:{steadyClock.now()},monotonicClock:{steadyClock.now().timeIntervalSince1970})
        steady.start(role:"source",stream:stream);try steady.flushForTests()
        let productionFields=Dictionary(uniqueKeysWithValues:(0..<16).map{("metric\($0)",Double(123456789+$0))})
        var steadyPeakBacklog:Int=0
        // Controlled monotonic seconds, no catch-up period without ingestion.
        // 64-character production stream and deliberately realistic metadata size.
        for second in 1...60 {
            for frame in 0..<600 {steady.record(stage:"encoded_callback",sequence:UInt64(second*600+frame),fields:productionFields,stream:stream)}
            steadyClock.advance(1);try steady.flushForTests()
            if second % 5 == 0 {steadyPeakBacklog=max(steadyPeakBacklog,steady.snapshotForTests()["mirrorPendingCount"] as? Int ?? Int.max)}
        }
        let steadyStatus=steady.snapshotForTests(),steadyWritten=steadyStatus["written"] as? Int64 ?? -1
        let steadyBytes=try chunks(steadyRoot).reduce(0){try $0+Data(contentsOf:$1).count}
        check(steadyBytes>60*1024*1024/5,"steady test exceeds old 1MiB per five seconds ceiling")
        check(steadyWritten>30000,"steady producer maintains substantial production load")
        check(steadyPeakBacklog<=2,"no accumulating backlog at sustained production throughput")
        check(steadyStatus["mirrorEvictedBeforeCopy"] as? Int64==0,"steady mirror never loses retained chunks")
        check(steady.shutdown(timeout:10),"termination flush bypasses mirror cadence safely")
        let steadyOwn=steadyCloud.appendingPathComponent("ThunderControl-진단").appendingPathComponent(try own(steadyRoot).lastPathComponent)
        let steadyCopied=try fm.contentsOfDirectory(at:steadyOwn,includingPropertiesForKeys:nil).filter{$0.pathExtension=="jsonl"}.reduce(0){try $0+Data(contentsOf:$1).split(separator:10).count}
        check(steadyCopied==Int(steadyWritten),"final cloud folder includes last partial interval")
        check(steady.snapshotForTests()["sessionActive"] as? Bool==false,"stopped recorder manifest is not active")
        print("DevelopmentDiagnostics steady mirror: written=\(steadyWritten), bytes=\(steadyBytes), peakFiveSecondBacklog=\(steadyPeakBacklog), cloudRows=\(steadyCopied); simulated60s, not WAN upload proof")

    } catch { failures += 1; print("DevelopmentDiagnostics unexpected: \(error)") }
    print("DevelopmentDiagnostics: \(checks) checks, \(failures) failures")
    return failures
}
#if DEVELOPMENT_DIAGNOSTICS_TEST_MAIN
@main private struct DevelopmentDiagnosticsTestMain {
    static func main() { exit(Int32(runDevelopmentDiagnosticsTests() == 0 ? 0 : 1)) }
}
#endif

#if RENDERER_DIAGNOSTICS_TEST_MAIN
@main private struct RendererDiagnosticsTestMain {
    static func main() throws {
        var failures = 0, checks = 0
        func check(_ condition: Bool, _ label: String) {
            checks += 1
            if !condition { failures += 1; print("Renderer FAIL: \(label)") }
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let recorder = DevelopmentDiagnostics(root: root, cloudRoot: nil)
        let stream = String(repeating: "0123456789abcdef", count: 4)
        recorder.start(role: "viewer", stream: stream)
        try recorder.flushForTests()
        // Matches requestRendererMetrics' quality-tier, renderer-health snapshot.
        let producer: [String: Double] = [
            "available": 1, "sampleTime": 100, "totalNumberOfFrames": 60,
            "numberOfDroppedFrames": 1, "numberOfCorruptedFrames": 0,
            "totalAccumulatedFrameDelay": 0.1, "presentationMode": 0,
            "counterSampleTime": 100.001, "generation": 2, "displayLinkTicks": 61,
            "submitted": 60, "pacerOffered": 61, "pacerSelected": 60,
            "pacerOverflow": 1, "pacerSuperseded": 0, "pacerEmpty": 0,
            "pacerWaiting": 0, "pacerInvalid": 0, "targetDuplicate": 0,
            "targetExpired": 0, "targetLimited": 0, "pacerRateLimited": 0,
            "targetGaps": 0, "readinessDeferrals": 0, "lastSourceSequence": 99
        ]
        var full = producer
        check(full.count == 25, "producer snapshot has 25 fields")
        func record(_ fields: [String: Double], stage: String = "renderer_metrics", sequence: UInt64? = nil) throws {
            for _ in 0..<32 {
                let before = recorder.snapshotForTests()
                recorder.record(stage: stage, sequence: sequence, fields: fields, stream: stream)
                try recorder.flushForTests()
                let after = recorder.snapshotForTests()
                if after["accepted"] as? Int64 != before["accepted"] as? Int64 || after["invalid"] as? Int64 != before["invalid"] as? Int64 { return }
            }
            check(false, "record made no progress")
        }
        try record(full, sequence: 99)
        full.removeValue(forKey: "lastSourceSequence")
        try record(full)
        for key in ["totalNumberOfFrames", "numberOfDroppedFrames", "numberOfCorruptedFrames", "totalAccumulatedFrameDelay"] { full.removeValue(forKey: key) }
        full["available"] = 0
        try record(full)
        full["lastSourceSequence"] = 100
        try record(full, sequence: 100)
        var status = recorder.snapshotForTests()
        let ring = status["receiverPerformance"] as? [[String: Any]] ?? []
        check(status["accepted"] as? Int64 == 4, "nil/nonnil AV metrics with/without source sequence accepted")
        check(ring.count == 4, "all four producer shapes retained")
        if ring.count == 4 {
            check((ring[0]["fields"] as? [String: Double])?.count == 25, "complete snapshot retained")
            check((ring[0]["fields"] as? [String: Double])?["presentationMode"] == 0, "mode not silently dropped")
            check((ring[0]["seq"] as? NSNumber)?.uint64Value == 99 && ring[1]["seq"] == nil, "event sequence preserved")
        }
        var oversized = producer
        oversized["extraField"] = 1
        try record(oversized)
        oversized.removeValue(forKey: "extraField")
        try record(oversized, stage: "capture")
        status = recorder.snapshotForTests()
        check(status["invalid"] as? Int64 == 2, "renderer 26 and other-stage 25 rejected")
        check(status["accepted"] as? Int64 == 4, "oversized events not accepted")
        oversized.removeValue(forKey: "presentationMode")
        try record(oversized, stage: "capture")
        check(recorder.snapshotForTests()["accepted"] as? Int64 == 5, "other-stage 24 remains accepted")
        check(DevelopmentDiagnostics.receiverPerformanceFields.count == 25 && DevelopmentDiagnostics.receiverPerformanceFields.contains("presentationMode"), "explicit bounded mode schema")
        check(recorder.shutdown(), "bounded shutdown")
        print("Renderer diagnostics: \(checks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
#endif
