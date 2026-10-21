import Foundation
import Darwin

// Only this queue touches disk. Ingress owns at most pendingLimit bounded lines,
// including the batch currently being written. Failure disables writes, never crashes.
final class DiagnosticStore: @unchecked Sendable {
  static let shared = DiagnosticStore(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("ThunderControl/Diagnostics", isDirectory: true),nonblockingIngress:true)
  enum StoreError: Error { case unsafePath, invalidLimits, io(Int32) }
  private let nonblockingIngress:Bool
  private let root: URL
  private let segmentBytes: Int, maxLineBytes: Int, pendingLimit: Int
  private let queue = DispatchQueue(label: "ThunderControl.Diagnostics", qos: .utility)
  private let ingress = NSLock()
  private var pending: [(String, Data)] = []
  private var outstanding = 0, scheduled = false
  private var dropped: UInt64 = 0
  private var failure: Error?
  private var directoryFD: Int32 = -1
  // Optional gate is strictly a deterministic test seam, invoked on the disk queue.
  private let beforeDrain: (() -> Void)?
  init(root: URL, segmentBytes: Int = 2_621_440, maxLineBytes: Int = 4096,
       pendingLimit: Int = 256, beforeDrain: (() -> Void)? = nil,nonblockingIngress:Bool=false) {
    self.nonblockingIngress=nonblockingIngress
    self.root = root; self.segmentBytes = segmentBytes
    self.maxLineBytes = min(maxLineBytes, segmentBytes); self.pendingLimit = pendingLimit
    self.beforeDrain = beforeDrain
    if segmentBytes < 2 || maxLineBytes < 2 || pendingLimit < 1 { failure = StoreError.invalidLimits }
  }
  deinit { if directoryFD >= 0 { Darwin.close(directoryFD) } }
  func recordConnection(_ text: String) { enqueue("connection", text) }
  func recordGesture(_ text: String) { enqueue("gesture", text) }
  private func enqueue(_ channel: String, _ text: String) {
    // Truncate before normalization: even a huge caller string cannot grow ingress.
    var bytes = Array(text.utf8.prefix(max(0, maxLineBytes - 1)))
    while String(bytes: bytes, encoding: .utf8) == nil && !bytes.isEmpty { bytes.removeLast() }
    for i in bytes.indices where bytes[i] < 32 || bytes[i] == 127 { bytes[i] = 32 }
    bytes.append(10)
    if nonblockingIngress {guard ingress.try() else{return}} else {ingress.lock()} // Production never waits on event tap.
    defer { ingress.unlock() }
    guard outstanding < pendingLimit else { dropped &+= 1; return }
    pending.append((channel, Data(bytes))); outstanding += 1
    if !scheduled { scheduled = true; queue.async { self.drain() } }
  }
  private func drain() {
    beforeDrain?()
    ingress.lock(); let batch = pending; pending.removeAll(keepingCapacity: true); ingress.unlock()
    for (channel, data) in batch {
      if failure == nil {
        do { try prepare(); try append(channel, data) } catch { failure = error }
      }
    }
    ingress.lock(); outstanding -= batch.count
    if pending.isEmpty { scheduled = false } else { queue.async { self.drain() } }
    ingress.unlock()
  }
  // Call off the event tap/main thread. Includes all already accepted ingress.
  func flush() throws {
    try queue.sync { try drainPending(); try prepare(); try cleanQuarantine(); if let error = failure { throw error } }
  }
  private func drainPending() throws {
    ingress.lock(); let batch = pending; pending.removeAll(keepingCapacity: true); ingress.unlock()
    defer { ingress.lock(); outstanding -= batch.count; ingress.unlock() }
    if let error = failure { throw error }
    do {
      try prepare()
      for (channel, data) in batch { try append(channel, data) }
    } catch { failure = error; throw error }
  }
  var droppedLineCount: UInt64 { ingress.lock(); defer { ingress.unlock() }; return dropped }
  // Complete snapshot (previous then active) also serves deterministic small-cap tests.
  func snapshot() throws -> [String: Data] {
    try queue.sync { try drainPending(); return try snapshotLocked() }
  }
  private func snapshotLocked() throws -> [String: Data] {
    try prepare()
    var result: [String: Data] = [:]
    for channel in ["connection", "gesture"] {
      var bytes = try read(channel + ".previous.log")
      bytes.append(try read(channel + ".active.log")); result[channel] = bytes
    }
    return result
  }
  // destination is an existing selected folder. Publish one unique child directory
  // by rename, so readers never observe a partially written export. No overwrite.
  func export(to directory: URL) throws {
    try queue.sync {
      try drainPending()
      let snapshot = try snapshotLocked()
      try cleanQuarantine()
      let parent = try Self.openDirectory(directory, create: false)
      defer { Darwin.close(parent) }
      let id = UUID().uuidString
      let staging = ".ThunderControl-Diagnostics-" + id
      let final = "ThunderControl-Diagnostics-" + id
      guard mkdirat(parent, staging, 0o700) == 0 else { throw StoreError.io(errno) }
      let fd = openat(parent, staging, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard fd >= 0 else { throw StoreError.io(errno) }
      defer { Darwin.close(fd) }
      do {
        for name in ["connection", "gesture"] {
          try Self.writeNew(fd, name + ".log", snapshot[name]!)
        }
        let manifest: [String: Any] = ["formatVersion": 1, "createdAt": ISO8601DateFormatter().string(from: Date()),
          "segmentBytes": segmentBytes, "channelCapBytes": segmentBytes * 2,
          "maxLineBytesIncludingNewline": maxLineBytes, "droppedIngressLines": droppedLineCount,
          "connectionBytes": snapshot["connection"]!.count, "gestureBytes": snapshot["gesture"]!.count,
          "order": "oldest-to-newest; previous then active"]
        try Self.writeNew(fd, "manifest.json", JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .prettyPrinted]))
        guard fsync(fd) == 0 else { throw StoreError.io(errno) }
        guard renameatx_np(parent, staging, parent, final, UInt32(RENAME_EXCL)) == 0 else { throw StoreError.io(errno) }
      } catch {
        // Only files this export created in its exclusive private staging directory.
        for name in ["connection.log", "gesture.log", "manifest.json"] { _ = unlinkat(fd, name, 0) }
        _ = unlinkat(parent, staging, AT_REMOVEDIR)
        throw error
      }
    }
  }
  private func prepare() throws {
    if let error = failure { throw error }
    if directoryFD < 0 { directoryFD = try Self.openDirectory(root, create: true) }
    guard fchmod(directoryFD, 0o700) == 0 else { throw StoreError.io(errno) }
    for channel in ["connection", "gesture"] {
      for suffix in [".active.log", ".previous.log"] {
        let fd = try openLog(channel + suffix, create: false)
        if fd >= 0 { Darwin.close(fd) }
      }
    }
  }
  // Walk every component using directory descriptors, never following symlinks,
  // including symlinked ancestors. Existing ancestor permissions are not changed.
  private static func openDirectory(_ url: URL, create: Bool) throws -> Int32 {
    guard url.isFileURL, url.path.hasPrefix("/"), !url.pathComponents.contains("..") else { throw StoreError.unsafePath }
    var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard fd >= 0 else { throw StoreError.io(errno) }
    do {
      for component in url.pathComponents where component != "/" && component != "." {
        if create && mkdirat(fd, component, 0o700) != 0 && errno != EEXIST { throw StoreError.io(errno) }
        let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard next >= 0 else { throw StoreError.io(errno) }
        Darwin.close(fd); fd = next
      }
      var info = stat()
      guard fstat(fd, &info) == 0, info.st_uid == geteuid() else { throw StoreError.unsafePath }
      return fd
    } catch { Darwin.close(fd); throw error }
  }
  private func openLog(_ name: String, create: Bool) throws -> Int32 {
    let fd = openat(directoryFD, name, O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (create ? O_CREAT : 0), 0o600)
    if fd < 0 { if !create && errno == ENOENT { return -1 }; throw StoreError.io(errno) }
    var info = stat()
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
      info.st_nlink == 1, info.st_uid == geteuid(), info.st_size <= segmentBytes,
      fchmod(fd, 0o600) == 0 else { Darwin.close(fd); throw StoreError.unsafePath }
    return fd
  }
  private func append(_ channel: String, _ bytes: Data) throws {
    let active = channel + ".active.log", previous = channel + ".previous.log"
    var fd = try openLog(active, create: true)
    defer { if fd >= 0 { Darwin.close(fd) } }
    var info = stat()
    guard fstat(fd, &info) == 0 else { throw StoreError.io(errno) }
    if info.st_size + Int64(bytes.count) > Int64(segmentBytes) {
      let old = try openLog(previous, create: false)
      if old >= 0 { Darwin.close(old); guard unlinkat(directoryFD, previous, 0) == 0 else { throw StoreError.io(errno) } }
      guard renameat(directoryFD, active, directoryFD, previous) == 0 else { throw StoreError.io(errno) }
      Darwin.close(fd); fd = -1
      fd = try openLog(active, create: true)
    }
    guard lseek(fd, 0, SEEK_END) >= 0 else { throw StoreError.io(errno) }
    try Self.writeAll(fd, bytes)
  }
  private func read(_ name: String) throws -> Data {
    let fd = try openLog(name, create: false)
    if fd < 0 { return Data() }; defer { Darwin.close(fd) }
    var result = Data(), buffer = [UInt8](repeating: 0, count: min(segmentBytes, 65536))
    while true {
      let n = Darwin.read(fd, &buffer, buffer.count)
      if n == 0 { return result }
      if n < 0 { if errno == EINTR { continue }; throw StoreError.io(errno) }
      guard result.count + n <= segmentBytes else { throw StoreError.unsafePath }
      result.append(contentsOf: buffer.prefix(n))
    }
  }
  private static func writeNew(_ dir: Int32, _ name: String, _ data: Data) throws {
    let fd = openat(dir, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw StoreError.io(errno) }; defer { Darwin.close(fd) }
    try writeAll(fd, data)
    guard fsync(fd) == 0 else { throw StoreError.io(errno) }
    try clearQuarantine(fd)
  }
  private func cleanQuarantine() throws {
    for channel in ["connection", "gesture"] {
      for suffix in [".active.log", ".previous.log"] {
        let fd = try openLog(channel + suffix, create: false)
        if fd >= 0 { defer { Darwin.close(fd) }; try Self.clearQuarantine(fd) }
      }
    }
  }
  private static func clearQuarantine(_ fd: Int32) throws {
    if fremovexattr(fd, "com.apple.quarantine", 0) != 0 && errno != ENOATTR { throw StoreError.io(errno) }
    if fgetxattr(fd, "com.apple.quarantine", nil, 0, 0, 0) >= 0 { throw StoreError.unsafePath }
    guard errno == ENOATTR else { throw StoreError.io(errno) }
  }
  private static func writeAll(_ fd: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
        if n < 0 && errno == EINTR { continue }
        guard n > 0 else { throw StoreError.io(errno) }; offset += n
      }
    }
  }
}
