import Foundation
import Darwin

// Diagnostics only. No pairing identity, input payload, or user-provided paths enter logs.
// record/accessors never wait. Lifecycle start/stop use a short in-memory lock, never disk.
// flushForTests/shutdown are deliberately blocking shutdown/test APIs.
final class DevelopmentDiagnostics: @unchecked Sendable {
    static let shared = DevelopmentDiagnostics()
    enum Failure: Error { case unsafePath, io(Int32) }
    private final class Counter: @unchecked Sendable {
        private var value: Int64 = 0
        func add(_ n: Int64 = 1) { OSAtomicAdd64Barrier(n, &value) }
        var count: Int64 { OSAtomicAdd64Barrier(0, &value) }
    }
    private struct Context: Equatable {
        let session: String, role: String, stream: String
    }
    private struct Event {
        let context: Context, stage: String, sequence: UInt64?, fields: [String: Double]
        let monotonic: Double, wall: Double
    }
    private let root: URL, cloudRoot: URL?
    private let clock: () -> Date
    private let monotonicClock: () -> TimeInterval
    private let beforeDrain: (() -> Void)?
    private let beforeCloudRead: (() -> Void)?
    private let mirrorQueue = DispatchQueue(label: "ThunderControl.DiagnosticsMirror", qos: .utility)
    private let mirrorGroup = DispatchGroup()
    private var mirrorInFlight = false
    private var unverifiedEvictions: Int64 = 0, cloudEvictions: Int64 = 0, retentionFailures: Int64 = 0
    private let chunkBytes: Int, diskBytes: Int, maxAge: TimeInterval
    private let ingress = NSLock()
    private let queue = DispatchQueue(label: "ThunderControl.DevelopmentDiagnostics", qos: .utility)
    private var active: Context?, pending: [Event] = [], outstanding = 0, drainScheduled = false
    private var cachedLocalDirectory: URL?, cachedCloudDirectory: URL?
    private var timer: DispatchSourceTimer?
    private var directory: Int32 = -1
    // Logger-queue-only summary; no extra writes, timers, or main-thread work.
    private var receiverPerformance: [[String: Any]] = []
    private var receiverPerformanceContext: Context?
    private var deviceID: String?, latest: Context?, number: UInt64 = 0
    private var written: Int64 = 0, evictions: Int64 = 0
    private var mirrorDisabled = true, mirrorError = false, localError = false
    private var lastCloudCopy: Double?, lastMirrorAttempt: Double = -.infinity
    private var mirrorKnown = Set<String>()
    private var mirroredCount: Int64 = 0, mirrorPendingCount = 0
    private var mirrorMissCount: Int64 = 0, mirrorEvictedCount: Int64 = 0
    private let accepted = Counter(), contention = Counter(), overflow = Counter(), stale = Counter()
    private let nonfinite = Counter(), invalid = Counter(), ioDrops = Counter()
    private let version = String((Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown").prefix(32))
    private let build = String((Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown").prefix(32))

    // Injected roots are used exclusively by tests. nil cloudRoot means unavailable, not a fake cloud.
    init(root: URL? = nil, cloudRoot: URL? = nil, clock: @escaping () -> Date = Date.init,
         monotonicClock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         chunkBytes: Int = 512 * 1024, diskBytes: Int = 64 * 1024 * 1024,
         maxAge: TimeInterval = 15 * 60, beforeDrain: (() -> Void)? = nil,
         beforeCloudRead: (() -> Void)? = nil) {
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ThunderControl/DevelopmentDiagnostics")
        self.cloudRoot = root == nil ? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs") : cloudRoot
        self.clock = clock; self.monotonicClock = monotonicClock; self.beforeDrain = beforeDrain
        self.beforeCloudRead = beforeCloudRead
        self.chunkBytes = max(256, min(chunkBytes, 512 * 1024))
        self.diskBytes = max(0, min(diskBytes, 64 * 1024 * 1024)); self.maxAge = min(max(0, maxAge), 900)
    }
    deinit { timer?.cancel(); if directory >= 0 { close(directory) } }
    // Cached paths only. Never stat, create, or wait for disk/cloud.
    var localDirectoryURL: URL {
        guard ingress.try() else { return root }; defer { ingress.unlock() }
        return cachedLocalDirectory ?? root
    }
    var cloudDirectoryURL: URL? {
        guard ingress.try() else { return nil }; defer { ingress.unlock() }
        return cachedCloudDirectory
    }
    var currentStream: String? {

        guard ingress.try() else { contention.add(); return nil }
        defer { ingress.unlock() }; return active?.stream
    }
    func start(role: String, stream: String) {
        guard ["source", "viewer"].contains(role), Self.validStream(stream) else { invalid.add(); return }
        ingress.lock()
        defer { ingress.unlock() }
        if active?.role == role && active?.stream == stream { return }
        let context = Context(session: UUID().uuidString.lowercased(), role: role, stream: stream)
        active = context
        queue.async { self.latest = context; self.resetReceiverPerformance(for: context); self.drain(); self.activateTimer(); do { try self.prepare() } catch { self.localError = true }; self.publishStatus() }
    }
    func stop(stream: String? = nil) {
        ingress.lock()
        defer { ingress.unlock() }
        if let stream = stream, stream != active?.stream { stale.add(); return }
        active = nil
        queue.async { self.drain(); self.publishStatus() }
    }
    func record(stage: String, sequence: UInt64? = nil, fields: [String: Double] = [:], stream: String? = nil) {
        guard Self.identifier(stage, limit: 48), fields.count <= (stage == "renderer_metrics" ? 25 : 24),
              fields.keys.allSatisfy({ Self.identifier($0, limit: 32) }) else { invalid.add(); return }
        guard fields.values.allSatisfy({ $0.isFinite }) else { nonfinite.add(); return }
        guard ingress.try() else { contention.add(); return }
        defer { ingress.unlock() }
        guard let context = active, stream == nil || stream == context.stream else { stale.add(); return }
        guard outstanding < 1024 else { overflow.add(); return }
        pending.append(Event(context: context, stage: stage, sequence: sequence, fields: fields,
                             monotonic: monotonicClock(), wall: clock().timeIntervalSince1970))
        outstanding += 1; accepted.add()
        if pending.count >= 512 && !drainScheduled {
            drainScheduled = true; queue.async { self.drain() }
        }
    }
    // Explicit protocol allowlist; unknown stages are rejected, never logged as arbitrary strings.
    static let helperStages: Set<String> = ["capture", "encode", "encoded", "send", "frame", "drop", "heartbeat", "capture_callback", "encode_submit", "encode_callback", "helper_capture", "helper_encode", "helper_send", "encoder_admission", "encode_call_start", "encode_call_end", "encoded_callback", "pipe_start", "pipe_complete", "capture_replaced", "capture_suspended", "encoder_busy_drop", "capture_no_pixel", "encoder_drop", "capture_aggregate", "capture_drop_aggregate", "capture_gap_aggregate", "diagnostics_aggregate", "helper_failure"]
    func recordHelperLine(_ text: String, stream: String?) {
        guard let stream else{stale.add();return}
        guard text.utf8.prefix(4097).count <= 4096, text.hasPrefix("TC_DIAG ") else { invalid.add(); return }
        let tokens = text.dropFirst(8).split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard tokens.count <= 27 else { invalid.add(); return }
        var stage: String?, seq: UInt64?, fields: [String: Double] = [:], seen = Set<String>()
        for token in tokens {
            let pair = token.split(separator: "=", omittingEmptySubsequences: false)
            guard pair.count == 2 else { invalid.add(); return }
            let key = String(pair[0]), value = String(pair[1])
            guard Self.identifier(key, limit: 32), seen.insert(key).inserted else { invalid.add(); return }
            if key == "stage" {
                guard Self.helperStages.contains(value) else { invalid.add(); return }; stage = value
            } else if key == "seq" {
                guard !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let n = UInt64(value) else { invalid.add(); return }; seq = n
            } else {
                // Optional extension keys are identifiers, values are ONLY finite numeric scalars.
                guard value.utf8.count <= 32, let n = Double(value), n.isFinite else { nonfinite.add(); return }
                fields[key] = n
            }
        }
        guard let stage = stage else { invalid.add(); return }
        record(stage: stage, sequence: seq, fields: fields, stream: stream)
    }
    private static func identifier(_ s: String, limit: Int) -> Bool {
        let b = Array(s.utf8.prefix(limit + 1))
        guard !b.isEmpty, b.count <= limit, (b[0] >= 65 && b[0] <= 90 || b[0] >= 97 && b[0] <= 122 || b[0] == 95) else { return false }
        return b.allSatisfy { $0 >= 65 && $0 <= 90 || $0 >= 97 && $0 <= 122 || $0 >= 48 && $0 <= 57 || $0 == 95 }
    }
    private static func validStream(_ s: String) -> Bool {
        let b = Array(s.utf8.prefix(65))
        return (16...64).contains(b.count) && b.allSatisfy { $0 >= 48 && $0 <= 57 || $0 >= 97 && $0 <= 102 || $0 >= 65 && $0 <= 70 }
    }
    private func activateTimer() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in
            guard let self = self else { return }; self.drain()
            do { if self.directory >= 0 { try self.retain() } } catch { self.localError = true }
            self.publishStatus()
        }
        timer = t; t.resume()
    }
    private func drain() { autoreleasepool { drainBatch() } }
    private func drainBatch() {
        ingress.lock(); let batch = pending; pending.removeAll(keepingCapacity: true); drainScheduled = false; ingress.unlock()
        guard !batch.isEmpty else { return }
        beforeDrain?()
        // Consume before filesystem work: local/cloud IO failures cannot erase
        // cumulative renderer snapshots from the bounded manifest summary.
        for event in batch { consumeReceiverPerformance(event) }
        let writtenBefore = written
        defer { ingress.lock(); outstanding -= batch.count; ingress.unlock() }
        do {
            try prepare()
            var data = Data(), context: Context?
            for event in batch {
                var row: [String: Any] = ["session": event.context.session, "role": event.context.role,
                    "stream": event.context.stream, "stage": event.stage, "monotonic": event.monotonic,
                    "wall": event.wall, "fields": event.fields, "version": version, "build": build]
                if let seq = event.sequence { row["seq"] = NSNumber(value: seq) }
                var line = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]); line.append(10)
                if !data.isEmpty && (context != event.context || data.count + line.count > chunkBytes) {
                    try emit(data); data.removeAll(keepingCapacity: true)
                }
                // A record is never split or allowed to exceed the hard chunk bound.
                guard line.count <= chunkBytes else { overflow.add(); continue }
                context = event.context; data.append(line)
            }
            if !data.isEmpty { try emit(data) }
            try retain(); localError = false
        } catch { ioDrops.add(max(0, Int64(batch.count) - (written - writtenBefore))); localError = true }
        publishStatus()
    }
    private func emit(_ data: Data) throws {
        number += 1
        let name = String(format: "chunk-%@-%08llu.jsonl", runID, number)
        try Self.atomicWrite(data, directory: directory, name: name, immutable: true)
        written += Int64(data.reduce(0) { $1 == 10 ? $0 + 1 : $0 })

    }
    private let runID = UUID().uuidString.lowercased()
    private func prepare() throws {
        if directory >= 0 { return }
        let rootFD = try Self.openDirectory(root, create: true); defer { close(rootFD) }
        guard fchmod(rootFD, 0o700) == 0 else { throw Failure.io(errno) }
        let idName = "device-uuid"
        let fd = openat(rootFD, idName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        let id: String
        if fd >= 0 {
            defer { close(fd) }; var st = stat()
            guard fchmod(fd, 0o600) == 0 else { throw Failure.io(errno) }
            guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size == 36 else { throw Failure.unsafePath }
            var bytes = [UInt8](repeating: 0, count: 36)
            guard read(fd, &bytes, 36) == 36, let s = String(bytes: bytes, encoding: .utf8), UUID(uuidString: s) != nil else { throw Failure.unsafePath }; id = s
        } else {
            guard errno == ENOENT else { throw Failure.unsafePath }
            id = UUID().uuidString.lowercased()
            try Self.atomicWrite(Data(id.utf8), directory: rootFD, name: idName, immutable: true)
        }
        if mkdirat(rootFD, id, 0o700) != 0 && errno != EEXIST { throw Failure.io(errno) }
        let own = openat(rootFD, id, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard own >= 0 else { throw Failure.unsafePath }
        guard fchmod(own, 0o700) == 0 else { close(own); throw Failure.io(errno) }
        directory = own; deviceID = id
        ingress.lock(); cachedLocalDirectory = root.appendingPathComponent(id); ingress.unlock()
        try retain()
    }
    // Traverse each component with O_NOFOLLOW, including existing ancestors. Never resolve symlinks.
    private static func openDirectory(_ url: URL, create: Bool) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw Failure.unsafePath }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw Failure.io(errno) }
        do {
            for part in url.path.split(separator: "/") {
                let name = String(part)
                guard name != ".", name != ".." else { throw Failure.unsafePath }
                if create && mkdirat(fd, name, 0o700) != 0 && errno != EEXIST { throw Failure.io(errno) }
                let next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard next >= 0 else { throw Failure.unsafePath }; close(fd); fd = next
            }
            return fd
        } catch { close(fd); throw error }
    }
    private static func atomicWrite(_ data: Data, directory: Int32, name: String, immutable: Bool = false) throws {
        var existing = stat()
        if fstatat(directory, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 && existing.st_mode & S_IFMT != S_IFREG { throw Failure.unsafePath }
        let temp = ".diag-" + UUID().uuidString
        let fd = openat(directory, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure.io(errno) }
        defer { close(fd); unlinkat(directory, temp, 0) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw Failure.io(errno) }; offset += n
            }
        }
        guard fsync(fd) == 0 else { throw Failure.io(errno) }
        let result = immutable ? linkat(directory, temp, directory, name, 0) : renameat(directory, temp, directory, name)
        guard result == 0 else { throw Failure.io(errno) }
    }
    private static func chunkFiles(_ directory: Int32) throws -> [(String, Int64, Double)] {
        let duplicate = dup(directory)
        guard duplicate >= 0, let listing = fdopendir(duplicate) else { if duplicate >= 0 { close(duplicate) }; throw Failure.io(errno) }
        defer { closedir(listing) }; rewinddir(listing)
        var entries: [(String, Int64, Double)] = []
        while let item = readdir(listing) {
            let name = withUnsafePointer(to: &item.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) } }
            guard name.range(of: "^chunk-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}-[0-9]{8}\\.jsonl$", options: .regularExpression) != nil else { continue }
            var st = stat()
            guard fstatat(directory, name, &st, AT_SYMLINK_NOFOLLOW) == 0, st.st_mode & S_IFMT == S_IFREG else { continue }
            entries.append((name, st.st_size, Double(st.st_mtimespec.tv_sec)))
        }
        entries.sort { $0.2 == $1.2 ? $0.0 < $1.0 : $0.2 < $1.2 }
        return entries
    }
    private func retain() throws {
        let directory = self.directory
        let entries = try Self.chunkFiles(directory)
        var total = entries.reduce(Int64(0)) { $0 + $1.1 }
        for e in entries where clock().timeIntervalSince1970 - e.2 > maxAge || total > diskBytes {
            if unlinkat(directory, e.0, 0) == 0 {
                total -= e.1; evictions += 1
                if !mirrorKnown.contains(e.0) { unverifiedEvictions += 1 }
                mirrorKnown.remove(e.0)
            } else { retentionFailures += 1 }
        }
    }
    // Exact numeric schema only. Unknown extension keys remain in ordinary
    // structured event logs but never enter the performance manifest summary.
    static let receiverPerformanceFields: Set<String> = {
        let common: Set<String> = [
            "available", "sampleTime", "presentationMode", "totalNumberOfFrames", "numberOfDroppedFrames",
            "numberOfCorruptedFrames", "totalAccumulatedFrameDelay", "generation",
            "displayLinkTicks", "submitted", "pacerOffered", "pacerSelected",
            "pacerOverflow", "pacerSuperseded", "pacerEmpty", "pacerWaiting",
            "pacerInvalid", "targetGaps", "counterSampleTime", "readinessDeferrals", "lastSourceSequence"
        ]
#if TC_DEADLINE_PRESENTATION || TC_ADAPTIVE_PRESENTATION
        return common.union(["scheduledMode", "scheduledFuture", "scheduledLateSkips", "scheduledMinLeadMs"])
#else
        return common.union(["targetDuplicate", "targetExpired", "targetLimited", "pacerRateLimited"])
#endif
    }()
    private func resetReceiverPerformance(for context: Context) {
        guard receiverPerformanceContext != context else { return }
        receiverPerformanceContext = context
        receiverPerformance.removeAll(keepingCapacity: true)
    }
    private func consumeReceiverPerformance(_ event: Event) {
        guard event.stage == "renderer_metrics", event.context.role == "viewer" else { return }
        let fields = event.fields.filter { Self.receiverPerformanceFields.contains($0.key) && $0.value.isFinite }
        guard let time = fields["sampleTime"], time >= 0 else { return }
        resetReceiverPerformance(for: event.context)
        var sample: [String: Any] = ["session": event.context.session, "stream": event.context.stream, "fields": fields]
        if let sequence = event.sequence { sample["seq"] = NSNumber(value: sequence) }
        if receiverPerformance.count == 128 { receiverPerformance.removeFirst() }
        receiverPerformance.append(sample)
    }
    private func status() -> [String: Any] {
        ingress.lock();let currentContext=active,sessionActive=active != nil,pendingCount=outstanding;ingress.unlock()
        var result: [String: Any] = ["version": version, "build": build, "accepted": accepted.count, "manifestWrittenAt":clock().timeIntervalSince1970,"sessionActive":sessionActive,"pendingEvents":pendingCount,
            "written": written, "dropped": contention.count + overflow.count + stale.count + nonfinite.count + invalid.count + ioDrops.count,
            "lockContention": contention.count, "overflow": overflow.count, "stale": stale.count,
            "nonfinite": nonfinite.count, "invalid": invalid.count, "ioDrops": ioDrops.count, "retentionEvictions": evictions,
            "mirrorDisabled": mirrorDisabled, "mirrorError": mirrorError, "localError": localError,
            "mirroredCount": mirroredCount, "mirrorPendingCount": mirrorPendingCount,
            "mirrorMissCount": mirrorMissCount, "mirrorEvictedBeforeCopy": mirrorEvictedCount]
        if let latest = latest { result["session"] = latest.session; result["role"] = latest.role; result["stream"] = latest.stream }
        // Never advertise a prior context ring as belonging to a new stream,
        // including the short interval before its queued start is consumed.
        result["receiverPerformance"] = receiverPerformanceContext == latest && (currentContext == nil || currentContext == latest) ? receiverPerformance : []
        result["mirrorJobsOutstanding"] = mirrorInFlight ? 1 : 0
        result["mirrorUnverifiedEvictions"] = unverifiedEvictions
        result["cloudRetentionEvictions"] = cloudEvictions
        result["retentionFailures"] = retentionFailures
        if let lastCloudCopy = lastCloudCopy { result["cloudLastSuccessfulLocalCopy"] = lastCloudCopy }
        return result
    }
    private func publishStatus(forceMirror:Bool=false) {
        guard directory >= 0 else { return }
        writeLocalStatus()
        mirror(force: forceMirror)
    }
    private static func readChunk(_ directory: Int32, _ name: String) throws -> Data {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw Failure.io(errno) }; defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG,
              st.st_size >= 0, st.st_size <= 512 * 1024 else { throw Failure.unsafePath }
        var bytes = [UInt8](repeating: 0, count: Int(st.st_size)), offset = 0
        try bytes.withUnsafeMutableBytes { raw in
            while offset < raw.count {
                let n = read(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw Failure.io(errno) }; offset += n
            }
        }
        return Data(bytes)
    }
    private struct MirrorResult {
        var copied: [String] = []
        var misses: Int64 = 0, evictions: Int64 = 0, retentionFailures: Int64 = 0
        var disabled = false, failed = false
        var url: URL?
    }
    private func writeLocalStatus() {
        guard directory >= 0 else { return }
        do { try Self.atomicWrite(try JSONSerialization.data(withJSONObject: status(), options: [.sortedKeys]), directory: directory, name: "manifest.json") }
        catch { localError = true }
    }
    private func mirror(force: Bool = false) {
        let files: [(String, Int64, Double)]
        do { files = try Self.chunkFiles(directory) } catch { mirrorError = true; mirrorMissCount += 1; return }
        mirrorKnown.formIntersection(Set(files.map { $0.0 }))
        mirrorPendingCount = files.filter { !mirrorKnown.contains($0.0) }.count
        guard !mirrorInFlight else { return }
        let now = monotonicClock()
        guard force || now - lastMirrorAttempt >= 5 else { return }
        lastMirrorAttempt = now
        guard let cloudRoot = cloudRoot, let deviceID = deviceID else {
            mirrorDisabled = true; if mirrorPendingCount > 0 { mirrorMissCount += 1 }; return
        }
        var snapshot: [(String, Data)] = [], bytes: Int64 = 4 * 1024 * 1024
        for file in files where !mirrorKnown.contains(file.0) {
            guard snapshot.count < 64, file.1 >= 0, file.1 <= bytes else { break }
            do { let data = try Self.readChunk(directory, file.0); snapshot.append((file.0, data)); bytes -= Int64(data.count) }
            catch { mirrorError = true; mirrorMissCount += 1 }
        }
        guard let manifest = try? JSONSerialization.data(withJSONObject: status(), options: [.sortedKeys]) else { return }
        let maxAge = self.maxAge, diskBytes = self.diskBytes, wall = clock().timeIntervalSince1970
        let readBarrier = beforeCloudRead
        mirrorInFlight = true; mirrorGroup.enter()
        mirrorQueue.async {
            let result = Self.copyMirror(snapshot, manifest: manifest, cloudRoot: cloudRoot, deviceID: deviceID,
                                         wall: wall, maxAge: maxAge, diskBytes: diskBytes, beforeRead: readBarrier)
            self.queue.async {
                self.mirrorInFlight = false
                self.mirrorDisabled = result.disabled; self.mirrorError = result.failed
                self.mirrorMissCount += result.misses; self.cloudEvictions += result.evictions
                self.retentionFailures += result.retentionFailures
                self.mirrorKnown.formUnion(result.copied); self.mirroredCount += Int64(result.copied.count)
                if !result.failed && !result.disabled { self.lastCloudCopy = self.clock().timeIntervalSince1970 }
                self.ingress.lock(); self.cachedCloudDirectory = result.url; self.ingress.unlock()
                if let retained = try? Self.chunkFiles(self.directory) {
                    self.mirrorKnown.formIntersection(Set(retained.map { $0.0 }))
                    self.mirrorPendingCount = retained.filter { !self.mirrorKnown.contains($0.0) }.count
                }
                self.writeLocalStatus()
                self.mirrorGroup.leave()
            }
        }
    }
    private static func copyMirror(_ files: [(String, Data)], manifest: Data, cloudRoot: URL, deviceID: String,
                                   wall: Double, maxAge: TimeInterval, diskBytes: Int,
                                   beforeRead: (() -> Void)?) -> MirrorResult {
        var result = MirrorResult()
        let cloudFD: Int32
        do { cloudFD = try openDirectory(cloudRoot, create: false) }
        catch { result.disabled = true; result.misses = files.isEmpty ? 0 : 1; return result }
        defer { close(cloudFD) }
        do {
            var fd = dup(cloudFD); guard fd >= 0 else { throw Failure.io(errno) }; defer { close(fd) }
            for name in ["ThunderControl-진단", deviceID] {
                if mkdirat(fd, name, 0o700) != 0 && errno != EEXIST { throw Failure.io(errno) }
                let next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard next >= 0 else { throw Failure.unsafePath }; close(fd); fd = next
                guard fchmod(fd, 0o700) == 0 else { throw Failure.io(errno) }
            }
            result.url = cloudRoot.appendingPathComponent("ThunderControl-진단").appendingPathComponent(deviceID)
            for (name, data) in files {
                do {
                    var st = stat()
                    if fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 {
                        guard st.st_mode & S_IFMT == S_IFREG, st.st_size == data.count else { throw Failure.unsafePath }
                        beforeRead?()
                        guard try readChunk(fd, name) == data else { throw Failure.unsafePath }
                    } else {
                        guard errno == ENOENT else { throw Failure.io(errno) }
                        try atomicWrite(data, directory: fd, name: name, immutable: true)
                    }
                    result.copied.append(name)
                } catch { result.misses += 1; result.failed = true }
            }
            let retained = try chunkFiles(fd)
            var total = retained.reduce(Int64(0)) { $0 + $1.1 }
            for file in retained where wall - file.2 > maxAge || total > diskBytes {
                if unlinkat(fd, file.0, 0) == 0 { total -= file.1; result.evictions += 1 }
                else { result.retentionFailures += 1 }
            }
            try atomicWrite(manifest, directory: fd, name: "manifest.json")
        } catch { result.failed = true; result.misses += 1 }
        return result
    }
    // Call off the UI/event-tap thread. No implicit singleton disk activity.
    func flushForTests(mirrorTimeout: TimeInterval = 2) throws {
        try queue.sync {
            drain()
            if latest != nil { do { try prepare(); try retain(); publishStatus() } catch { localError = true; throw error } }
            if localError { throw Failure.io(EIO) }
        }
        let bounded = mirrorTimeout.isFinite ? max(0, min(mirrorTimeout, 30)) : 0
        guard mirrorGroup.wait(timeout: .now() + bounded) == .success else { throw Failure.io(ETIMEDOUT) }
    }
    // Blocking only at applicationWillTerminate/tests. False means deadline/error,
    // not a claim that the background queue has finished.
    func shutdown(timeout: TimeInterval = 2) -> Bool {
        final class Result: @unchecked Sendable { var success = false }
        let result = Result(), done = DispatchSemaphore(value: 0)
        let bounded = timeout.isFinite ? max(0, min(timeout, 30)) : 0
        let deadline = DispatchTime.now() + bounded
        ingress.lock(); active = nil
        queue.async {
            self.timer?.cancel(); self.timer = nil
            self.drain()
            do {
                if self.latest != nil { try self.prepare(); try self.retain(); self.publishStatus(forceMirror:true) }
                result.success = !self.localError
            } catch { self.localError = true }
            done.signal()
        }
        ingress.unlock()
        guard done.wait(timeout: deadline) == .success else { return false }
        guard mirrorGroup.wait(timeout: deadline) == .success else { return false }
        return result.success
    }
    func snapshotForTests() -> [String: Any] { queue.sync { status() } }
    func withIngressLockedForTests(_ body: () -> Void) { ingress.lock(); defer { ingress.unlock() }; body() }
}
