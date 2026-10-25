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
    private let chunkBytes: Int, diskBytes: Int, maxAge: TimeInterval
    private let ingress = NSLock()
    private let queue = DispatchQueue(label: "ThunderControl.DevelopmentDiagnostics", qos: .utility)
    private var active: Context?, pending: [Event] = [], outstanding = 0, drainScheduled = false
    private var cachedLocalDirectory: URL?, cachedCloudDirectory: URL?
    private var timer: DispatchSourceTimer?
    private var directory: Int32 = -1
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
         maxAge: TimeInterval = 15 * 60, beforeDrain: (() -> Void)? = nil) {
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ThunderControl/DevelopmentDiagnostics")
        self.cloudRoot = root == nil ? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs") : cloudRoot
        self.clock = clock; self.monotonicClock = monotonicClock; self.beforeDrain = beforeDrain
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
        queue.async { self.drain(); self.latest = context; self.activateTimer(); do { try self.prepare() } catch { self.localError = true }; self.publishStatus() }
    }
    func stop(stream: String? = nil) {
        ingress.lock()
        defer { ingress.unlock() }
        if let stream = stream, stream != active?.stream { stale.add(); return }
        active = nil
        queue.async { self.drain(); self.publishStatus() }
    }
    func record(stage: String, sequence: UInt64? = nil, fields: [String: Double] = [:], stream: String? = nil) {
        guard Self.identifier(stage, limit: 48), fields.count <= 24,
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
    private func chunkFiles(_ directory: Int32) throws -> [(String, Int64, Double)] {
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
    private func retain(_ selectedDirectory: Int32? = nil) throws {
        let directory = selectedDirectory ?? self.directory
        let entries = try chunkFiles(directory)
        var total = entries.reduce(Int64(0)) { $0 + $1.1 }
        for e in entries where clock().timeIntervalSince1970 - e.2 > maxAge || total > diskBytes {
            if unlinkat(directory, e.0, 0) == 0 {
                total -= e.1; evictions += 1
                if selectedDirectory == nil {
                    if !mirrorKnown.contains(e.0) { mirrorEvictedCount += 1 }
                    mirrorKnown.remove(e.0)
                }
            }
        }
    }
    private func status() -> [String: Any] {
        ingress.lock();let sessionActive=active != nil,pendingCount=outstanding;ingress.unlock()
        var result: [String: Any] = ["version": version, "build": build, "accepted": accepted.count, "manifestWrittenAt":clock().timeIntervalSince1970,"sessionActive":sessionActive,"pendingEvents":pendingCount,
            "written": written, "dropped": contention.count + overflow.count + stale.count + nonfinite.count + invalid.count + ioDrops.count,
            "lockContention": contention.count, "overflow": overflow.count, "stale": stale.count,
            "nonfinite": nonfinite.count, "invalid": invalid.count, "ioDrops": ioDrops.count, "retentionEvictions": evictions,
            "mirrorDisabled": mirrorDisabled, "mirrorError": mirrorError, "localError": localError,
            "mirroredCount": mirroredCount, "mirrorPendingCount": mirrorPendingCount,
            "mirrorMissCount": mirrorMissCount, "mirrorEvictedBeforeCopy": mirrorEvictedCount]
        if let latest = latest { result["session"] = latest.session; result["role"] = latest.role; result["stream"] = latest.stream }
        if let lastCloudCopy = lastCloudCopy { result["cloudLastSuccessfulLocalCopy"] = lastCloudCopy }
        return result
    }
    private func publishStatus(forceMirror:Bool=false) {
        guard directory >= 0 else { return }
        mirror(force:forceMirror)
        do { try Self.atomicWrite(try JSONSerialization.data(withJSONObject: status(), options: [.sortedKeys]), directory: directory, name: "manifest.json") }
        catch { localError = true }
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
    private func mirror(force:Bool=false) {
        // Local immutable retained chunks ARE the retry queue. No unbounded Data backlog.
        let files: [(String, Int64, Double)]
        do { files = try chunkFiles(directory) } catch { mirrorError = true; mirrorMissCount += 1; return }
        mirrorKnown.formIntersection(Set(files.map { $0.0 }))
        mirrorPendingCount = files.filter { !mirrorKnown.contains($0.0) }.count
        let now = monotonicClock()
        guard force || now - lastMirrorAttempt >= 5 else { return }; lastMirrorAttempt = now
        guard let cloudRoot = cloudRoot, let deviceID = deviceID else {
            mirrorDisabled = true; if mirrorPendingCount > 0 { mirrorMissCount += 1 }; return
        }
        let cloudFD: Int32
        // Never create CloudDocs itself. A later successful probe retries retained chunks.
        do { cloudFD = try Self.openDirectory(cloudRoot, create: false) }
        catch {
            mirrorDisabled = true; if mirrorPendingCount > 0 { mirrorMissCount += 1 }
            ingress.lock(); cachedCloudDirectory = nil; ingress.unlock(); return
        }
        defer { close(cloudFD) }
        do {
            var fd = dup(cloudFD); guard fd >= 0 else { throw Failure.io(errno) }; defer { close(fd) }
            for name in ["ThunderControl-진단", deviceID] {
                if mkdirat(fd, name, 0o700) != 0 && errno != EEXIST { throw Failure.io(errno) }
                let next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard next >= 0 else { throw Failure.unsafePath }; close(fd); fd = next
                guard fchmod(fd, 0o700) == 0 else { throw Failure.io(errno) }
            }
            mirrorDisabled = false
            ingress.lock(); cachedCloudDirectory = cloudRoot.appendingPathComponent("ThunderControl-진단").appendingPathComponent(deviceID); ingress.unlock()
            var byteBudget: Int64 = 4 * 1024 * 1024, fileBudget = 64
            for file in files where !mirrorKnown.contains(file.0) {
                guard fileBudget > 0, file.1 <= byteBudget else { break }
                byteBudget -= file.1; fileBudget -= 1
                do {
                    let data = try Self.readChunk(directory, file.0)
                    var st = stat()
                    if fstatat(fd, file.0, &st, AT_SYMLINK_NOFOLLOW) == 0 {
                        // Idempotent retry: an existing immutable chunk must be byte-identical.
                        guard st.st_mode & S_IFMT == S_IFREG, st.st_size == file.1,
                              try Self.readChunk(fd, file.0) == data else { throw Failure.unsafePath }
                    } else {
                        guard errno == ENOENT else { throw Failure.io(errno) }
                        try Self.atomicWrite(data, directory: fd, name: file.0, immutable: true)
                    }
                    mirrorKnown.insert(file.0); mirroredCount += 1
                    lastCloudCopy = clock().timeIntervalSince1970
                } catch { mirrorMissCount += 1; mirrorError = true }
            }
            mirrorPendingCount = files.filter { !mirrorKnown.contains($0.0) }.count
            // Historical failures/gaps stay visible through cumulative miss/eviction counters.
            mirrorError = mirrorPendingCount > 0
            try retain(fd)
            try Self.atomicWrite(try JSONSerialization.data(withJSONObject: status(), options: [.sortedKeys]), directory: fd, name: "manifest.json")
            lastCloudCopy = clock().timeIntervalSince1970
        } catch { mirrorError = true; mirrorMissCount += 1 }
    }
    // Call off the UI/event-tap thread. No implicit singleton disk activity.
    func flushForTests() throws {
        try queue.sync {
            drain()
            if latest != nil { do { try prepare(); try retain(); publishStatus() } catch { localError = true; throw error } }
            if localError { throw Failure.io(EIO) }
        }
    }
    // Blocking only at applicationWillTerminate/tests. False means deadline/error,
    // not a claim that the background queue has finished.
    func shutdown(timeout: TimeInterval = 2) -> Bool {
        final class Result: @unchecked Sendable { var success = false }
        let result = Result(), done = DispatchSemaphore(value: 0)
        queue.async {
            self.ingress.lock(); self.active = nil; self.ingress.unlock()
            self.timer?.cancel(); self.timer = nil
            self.drain()
            do {
                if self.latest != nil { try self.prepare(); try self.retain(); self.publishStatus(forceMirror:true) }
                result.success = !self.localError
            } catch { self.localError = true }
            done.signal()
        }
        let bounded = timeout.isFinite ? max(0, min(timeout, 30)) : 0
        guard done.wait(timeout: .now() + bounded) == .success else { return false }
        return result.success
    }
    func snapshotForTests() -> [String: Any] { queue.sync { status() } }
    func withIngressLockedForTests(_ body: () -> Void) { ingress.lock(); defer { ingress.unlock() }; body() }
}
