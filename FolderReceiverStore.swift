import Foundation
import CryptoKit
import Darwin

struct FolderPeerIdentity: Equatable {
  let local: UUID
  let peer: UUID
}

/// Monotonic progress counter read by the heartbeat writer while long work runs elsewhere.
final class FolderPulse {
  private let lock = NSLock()
  private var count: UInt64 = 0
  func add(_ n: UInt64) { lock.lock(); count &+= n; lock.unlock() }
  var value: UInt64 { lock.lock(); defer { lock.unlock() }; return count }
}

private extension UUID { var bytes: Data { withUnsafeBytes(of: uuid) { Data($0) } } }
private func folderUUID(_ data: Data) -> UUID? {
  guard data.count == 16 else { return nil }
  var raw: uuid_t = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
  withUnsafeMutableBytes(of: &raw) { $0.copyBytes(from: data) }
  return UUID(uuid: raw)
}
private func folderIdentity(_ s: stat) -> (UInt64, UInt64) { (UInt64(UInt32(bitPattern: s.st_dev)), UInt64(s.st_ino)) }

final class FolderReceiverStore {
  struct Receipt: Equatable { let stat: FolderFileStat; let sha: Data }
  private enum Record: UInt8 { case header = 1, begin, expect, done, publishIntent, published }
  static let stageSuffix = ".partial", journalSuffix = ".partial.journal"
  static let journalLimit = 64 * 1024 * 1024

  let manifest: FolderManifest
  private let parent: Int32
  private let finalName: String
  private let root: Int32
  private let rootID: (UInt64, UInt64)
  private let journal: Int32
  private let journalID: (UInt64, UInt64)
  #if FOLDER_TRANSFER_SELF_TEST
  struct Crash: Error {}
  nonisolated(unsafe) static var crashPoint: String?
  nonisolated(unsafe) static var slowCommit: TimeInterval = 0
  #endif
  /// Test-only crash injection; leaked objects simulate a process that died without cleanup.
  private func point(_ name: String, leak: AnyObject? = nil) throws {
    #if FOLDER_TRANSFER_SELF_TEST
    if name == "afterExpect", Self.slowCommit > 0 { Thread.sleep(forTimeInterval: Self.slowCommit) }
    if Self.crashPoint == name { Self.crashPoint = nil; if let leak { _ = Unmanaged.passRetained(leak) }; throw Crash() }
    #endif
  }
  private(set) var receipts: [Int: Receipt] = [:]
  private(set) var published = false
  private var finished = false

  private init(manifest: FolderManifest, parent: Int32, finalName: String, root: Int32, rootID: (UInt64, UInt64), journal: Int32, journalID: (UInt64, UInt64)) {
    self.manifest = manifest; self.parent = parent; self.finalName = finalName; self.root = root; self.rootID = rootID; self.journal = journal; self.journalID = journalID
  }
  deinit { close(root); close(journal); close(parent) }

  var stageName: String { finalName + Self.stageSuffix }
  var journalName: String { finalName + Self.journalSuffix }
  var skippedFiles: Int { receipts.count }
  var neededBytes: UInt64 { manifest.entries.indices.reduce(0) { $0 + (manifest.entries[$1].kind == .file && receipts[$1] == nil ? manifest.entries[$1].size : 0) } }

  /// Opens or creates the checkpoint for `destination` and recovers every recorded file.
  static func open(destination: URL, manifest: FolderManifest, identity: FolderPeerIdentity, check: () throws -> Void = {}, pulse: FolderPulse = FolderPulse()) throws -> FolderReceiverStore {
    let name = destination.lastPathComponent
    guard folderNameIsValid(name), name.utf8.count + journalSuffix.utf8.count <= 255 else { throw FolderTransferError.invalidName(name) }
    let parent = Darwin.open(destination.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard parent >= 0 else { throw FileTransferError.io }
    var parentInfo = stat(); guard fstat(parent, &parentInfo) == 0 else { close(parent); throw FileTransferError.io }
    let parentID = folderIdentity(parentInfo)
    let stageName = name + stageSuffix, journalName = name + journalSuffix
    var probe = stat()
    func absent(_ n: String) -> Bool { fstatat(parent, n, &probe, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT }
    var journal: Int32 = -1, root: Int32 = -1
    var cleanup = true
    defer { if cleanup { if root >= 0 { close(root) }; if journal >= 0 { close(journal) }; close(parent) } }

    if absent(journalName) {
      guard absent(name), absent(stageName) else { throw FolderTransferError.destinationExists }
      journal = openat(parent, journalName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_APPEND | O_CLOEXEC, mode_t(0o600))
      guard journal >= 0 else { throw FolderTransferError.destinationExists }
      var jinfo = stat(); _ = fstat(journal, &jinfo)
      guard flock(journal, LOCK_EX | LOCK_NB) == 0, mkdirat(parent, stageName, 0o755) == 0 else {
        var now = stat(); if fstatat(parent, journalName, &now, AT_SYMLINK_NOFOLLOW) == 0, now.st_ino == jinfo.st_ino { _ = unlinkat(parent, journalName, 0) }
        throw FolderTransferError.destinationExists
      }
      root = try folderOpenDirectory(parent, stageName)
      var sinfo = stat(); guard fstat(root, &sinfo) == 0 else { throw FileTransferError.io }
      let store = FolderReceiverStore(manifest: manifest, parent: parent, finalName: name, root: root, rootID: folderIdentity(sinfo), journal: journal, journalID: folderIdentity(jinfo))
      cleanup = false
      var header = Data(); header.appendBE(UInt16(1)); header.append(identity.local.bytes); header.append(identity.peer.bytes); header.append(manifest.digest)
      for v in [parentID.0, parentID.1, store.rootID.0, store.rootID.1] { header.appendBE(v) }
      header.append(contentsOf: name.utf8)
      try store.append(.header, header); _ = fsync(parent)
      try store.prepareTree()
      return store
    }

    journal = openat(parent, journalName, O_RDWR | O_NOFOLLOW | O_APPEND | O_CLOEXEC)
    var jinfo = stat()
    guard journal >= 0, fstat(journal, &jinfo) == 0, (jinfo.st_mode & S_IFMT) == S_IFREG, jinfo.st_nlink == 1 else { throw FolderTransferError.destinationExists }
    guard flock(journal, LOCK_EX | LOCK_NB) == 0 else { throw FolderTransferError.destinationExists }
    let parsed = try parse(journal, size: Int(jinfo.st_size), manifest: manifest)
    var h = FolderReader(parsed.header)
    guard try h.int(UInt16.self) == 1, folderUUID(try h.bytes(16)) == identity.local, folderUUID(try h.bytes(16)) == identity.peer, try h.bytes(32) == manifest.digest,
      try h.int(UInt64.self) == parentID.0, try h.int(UInt64.self) == parentID.1 else { throw FolderTransferError.resumeMismatch }
    let stageID = (try h.int(UInt64.self), try h.int(UInt64.self))
    guard String(data: try h.bytes(parsed.header.count - h.offset), encoding: .utf8) == name else { throw FolderTransferError.resumeMismatch }
    if parsed.good < Int(jinfo.st_size) { guard ftruncate(journal, off_t(parsed.good)) == 0, fsync(journal) == 0 else { throw FileTransferError.io } }

    func openMatching(_ n: String) -> Int32? {
      let fd = openat(parent, n, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); guard fd >= 0 else { return nil }
      var s = stat(); if fstat(fd, &s) == 0, folderIdentity(s) == stageID { return fd }; close(fd); return nil
    }
    var atFinal = false
    if let stage = openMatching(stageName) {
      root = stage
      guard absent(name) else { throw FolderTransferError.destinationExists }
    } else if parsed.publishIntent, let final = openMatching(name) {
      root = final; atFinal = true
    } else { throw parsed.publishIntent ? FolderTransferError.unconfirmed : FolderTransferError.resumeMismatch }

    let store = FolderReceiverStore(manifest: manifest, parent: parent, finalName: name, root: root, rootID: stageID, journal: journal, journalID: folderIdentity(jinfo))
    cleanup = false
    if atFinal {
      // The stage inode now sits at the final name. Accept it only if it is exactly the manifest tree
      // and every receipt still verifies; an extra or unknown entry is never claimed as completed.
      do { try store.verifyExactTree(parsed.done, check: check, pulse: pulse) }
      catch FileTransferError.cancelled { throw FileTransferError.cancelled } catch { throw FolderTransferError.unconfirmed }
      store.published = true
      if !parsed.publishedRecord { try store.append(.published, Data()) }
      return store
    }
    try store.prepareTree()
    try store.recover(parsed, check: check, pulse: pulse)
    return store
  }

  private static func parse(_ fd: Int32, size: Int, manifest: FolderManifest) throws -> ParsedJournal {
    guard size <= journalLimit else { throw FolderTransferError.resumeMismatch }
    var data = Data(count: size)
    let read = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, size, 0) }
    guard read == size else { throw FileTransferError.io }
    var result = ParsedJournal()
    var r = FolderReader(data)
    func fileIndex(_ v: UInt32) throws -> Int {
      let i = Int(v); guard manifest.entries.indices.contains(i), manifest.entries[i].kind == .file else { throw FolderTransferError.resumeMismatch }; return i
    }
    while !r.atEnd {
      let start = r.offset
      guard let type = try? r.int(UInt8.self), let length = try? r.int(UInt32.self), length <= 65536,
        let payload = try? r.bytes(Int(length)), let sum = try? r.bytes(8) else { break }
      var covered = Data([type]); covered.appendBE(length); covered.append(payload)
      guard Data(SHA256.hash(data: covered).prefix(8)) == sum, let kind = Record(rawValue: type) else { r.offset = start; break }
      var p = FolderReader(payload)
      switch kind {
      case .header:
        guard start == 0, payload.count > 2 + 32 + 32 + 32 else { throw FolderTransferError.resumeMismatch }; result.header = payload
      case .begin, .expect:
        guard start > 0, payload.count == 4 + 16 + 16 + (kind == .expect ? 32 : 0) else { throw FolderTransferError.resumeMismatch }
        let index = try fileIndex(try p.int(UInt32.self))
        guard let id = folderUUID(try p.bytes(16)) else { throw FolderTransferError.resumeMismatch }
        let temp = FolderReceiverStoreTemp(name: ".thundercontrol-" + id.uuidString + ".partial", device: try p.int(UInt64.self), inode: try p.int(UInt64.self))
        if kind == .begin { result.begins[index, default: []].append(temp) } else { result.expects[index] = (temp, try p.bytes(32)) }
      case .done:
        guard start > 0, payload.count == 4 + 56 + 32 else { throw FolderTransferError.resumeMismatch }
        let index = try fileIndex(try p.int(UInt32.self))
        var f: [UInt64] = []; for _ in 0..<7 { f.append(try p.int(UInt64.self)) }
        let s = FolderFileStat(device: f[0], inode: f[1], size: f[2], mtime: Int64(bitPattern: f[3]), mtimeNS: Int64(bitPattern: f[4]), ctime: Int64(bitPattern: f[5]), ctimeNS: Int64(bitPattern: f[6]))
        guard s.size == manifest.entries[index].size else { throw FolderTransferError.resumeMismatch }
        result.done[index] = Receipt(stat: s, sha: try p.bytes(32))
      case .publishIntent:
        guard start > 0, payload.isEmpty else { throw FolderTransferError.resumeMismatch }; result.publishIntent = true
      case .published:
        guard result.publishIntent, payload.isEmpty else { throw FolderTransferError.resumeMismatch }; result.publishedRecord = true
      }
      result.good = r.offset
    }
    guard !result.header.isEmpty else { throw FolderTransferError.resumeMismatch }
    return result
  }

  private func append(_ kind: Record, _ payload: Data) throws {
    var record = Data([kind.rawValue]); record.appendBE(UInt32(payload.count)); record.append(payload)
    record.append(Data(SHA256.hash(data: record).prefix(8)))
    try record.withUnsafeBytes { raw in
      var offset = 0
      while offset < raw.count {
        let n = Darwin.write(journal, raw.baseAddress!.advanced(by: offset), raw.count - offset)
        if n < 0 && errno == EINTR { continue }; guard n > 0 else { throw FileTransferError.io }; offset += n
      }
    }
    guard fsync(journal) == 0 else { throw FileTransferError.io }
  }

  /// Opens the directory that holds entry `index`, walking each validated component without links.
  private func openParent(_ index: Int) throws -> Int32 {
    var current = dup(root); guard current >= 0 else { throw FileTransferError.io }
    for component in manifest.entries[index].path.dropLast() {
      do { let next = try folderOpenDirectory(current, component); close(current); current = next }
      catch { close(current); throw FolderTransferError.conflict(manifest.entries[index].displayPath) }
    }
    return current
  }

  private func prepareTree() throws {
    for (index, entry) in manifest.entries.enumerated() where entry.kind == .directory {
      let dir = try openParent(index); defer { close(dir) }
      let leaf = entry.path.last!
      if mkdirat(dir, leaf, 0o755) == 0 { _ = fsync(dir) } else if errno != EEXIST { throw FileTransferError.io }
      do { close(try folderOpenDirectory(dir, leaf)) } catch { throw FolderTransferError.conflict(entry.displayPath) }
    }
  }

  private func hash(_ dir: Int32, _ leaf: String, size: UInt64, check: () throws -> Void, pulse: FolderPulse) throws -> (Data, stat)? {
    let fd = openat(dir, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK); guard fd >= 0 else { return nil }
    defer { close(fd) }
    var info = stat(); guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, UInt64(info.st_size) == size else { return nil }
    var hasher = SHA256(); var buffer = [UInt8](repeating: 0, count: 1 << 20); var total: UInt64 = 0
    while true {
      try check()
      var n: Int; repeat { n = Darwin.read(fd, &buffer, buffer.count) } while n < 0 && errno == EINTR
      guard n >= 0 else { throw FileTransferError.io }; if n == 0 { break }
      buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0.prefix(n))) }
      total += UInt64(n); pulse.add(UInt64(n))
    }
    guard total == size else { return nil }
    return (Data(hasher.finalize()), info)
  }

  /// Unchanged stat skips the rehash; a changed or uncertain stat is rehashed against the recorded digest.
  private func verifyReceipt(_ index: Int, _ receipt: Receipt, check: () throws -> Void, pulse: FolderPulse) throws -> Bool {
    let entry = manifest.entries[index], dir = try openParent(index); defer { close(dir) }
    var info = stat()
    guard fstatat(dir, entry.path.last!, &info, AT_SYMLINK_NOFOLLOW) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return false }
    if FolderFileStat(info) == receipt.stat { receipts[index] = receipt; return true }
    guard let (digest, now) = try hash(dir, entry.path.last!, size: entry.size, check: check, pulse: pulse), digest == receipt.sha else { return false }
    try recordDone(index, Receipt(stat: FolderFileStat(now), sha: digest)); return true
  }

  /// Exact tree check through the held root: every manifest entry with its kind and receipt, nothing else.
  /// Hidden files, orphan temps, links and extra directories are refused, never moved or deleted.
  /// Reads at most one unexpected name per directory, never follows links, and unchanged stats skip the rehash.
  private func verifyExactTree(_ done: [Int: Receipt], check: () throws -> Void, pulse: FolderPulse) throws {
    var children: [[String]: [Data: Int]] = [:]
    for (index, entry) in manifest.entries.enumerated() { children[Array(entry.path.dropLast()), default: [:]][Data(entry.path.last!.utf8)] = index }
    func walk(_ dir: Int32, _ prefix: [String]) throws {
      try check()
      let expected = children[prefix] ?? [:]
      let handle = dup(dir); guard handle >= 0, let stream = fdopendir(handle) else { if handle >= 0 { close(handle) }; throw FileTransferError.io }
      defer { closedir(stream) }
      rewinddir(stream)
      while let item = readdir(stream) {
        let raw = withUnsafeBytes(of: item.pointee.d_name) { Data($0.prefix(Int(item.pointee.d_namlen))) }
        if raw == Data(".".utf8) || raw == Data("..".utf8) { continue }
        guard expected[raw] != nil else { throw FolderTransferError.conflict((prefix + [String(decoding: raw, as: UTF8.self)]).joined(separator: "/")) }
      }
      for index in expected.values.sorted() {
        let entry = manifest.entries[index]; pulse.add(1)
        if entry.kind == .directory {
          let sub: Int32; do { sub = try folderOpenDirectory(dir, entry.path.last!) } catch { throw FolderTransferError.conflict(entry.displayPath) }
          defer { close(sub) }
          try walk(sub, entry.path)
        } else {
          guard let receipt = done[index], try verifyReceipt(index, receipt, check: check, pulse: pulse) else { throw FolderTransferError.conflict(entry.displayPath) }
        }
      }
    }
    try walk(root, [])
  }

  private func recover(_ parsed: ParsedJournal, check: () throws -> Void, pulse: FolderPulse) throws {
    for (index, entry) in manifest.entries.enumerated() where entry.kind == .file {
      try check()
      let leaf = entry.path.last!, dir = try openParent(index); defer { close(dir) }
      var info = stat()
      let present = fstatat(dir, leaf, &info, AT_SYMLINK_NOFOLLOW) == 0
      if present {
        if let done = parsed.done[index] {
          guard try verifyReceipt(index, done, check: check, pulse: pulse) else { throw FolderTransferError.conflict(entry.displayPath) }
        } else if let (temp, sha) = parsed.expects[index], (info.st_mode & S_IFMT) == S_IFREG, folderIdentity(info) == (temp.device, temp.inode),
          let (digest, now) = try hash(dir, leaf, size: entry.size, check: check, pulse: pulse), digest == sha {
          // Crash after the per-file rename but before its completion record.
          try recordDone(index, Receipt(stat: FolderFileStat(now), sha: digest))
        } else { throw FolderTransferError.conflict(entry.displayPath) }
      }
      var temps = parsed.begins[index] ?? []; if let e = parsed.expects[index] { temps.append(e.0) }
      for temp in temps {
        var t = stat()
        if fstatat(dir, temp.name, &t, AT_SYMLINK_NOFOLLOW) == 0, (t.st_mode & S_IFMT) == S_IFREG, folderIdentity(t) == (temp.device, temp.inode) { _ = unlinkat(dir, temp.name, 0) }
      }
    }
  }

  private func recordDone(_ index: Int, _ receipt: Receipt) throws {
    var payload = Data(); payload.appendBE(UInt32(index)); for f in receipt.stat.fields { payload.appendBE(f) }; payload.append(receipt.sha)
    try append(.done, payload); receipts[index] = receipt
  }

  /// Space for every file still needed, checked without overflow.
  func preflight() throws {
    var space = statvfs(); guard fstatvfs(root, &space) == 0 else { throw FileTransferError.io }
    let available = UInt64(space.f_bavail).multipliedReportingOverflow(by: UInt64(space.f_frsize))
    guard available.overflow || available.partialValue >= neededBytes else { throw FolderTransferError.insufficientSpace }
  }

  /// Creates the exclusive temp file and records its identity before any byte is accepted.
  func begin(_ index: Int) throws -> FileDestination {
    guard !published, manifest.entries.indices.contains(index), manifest.entries[index].kind == .file, receipts[index] == nil else { throw FolderTransferError.invalidManifest }
    let entry = manifest.entries[index], dir = try openParent(index); defer { close(dir) }
    let destination: FileDestination
    do { destination = try FileDestination(directory: dir, name: entry.path.last!, bytes: entry.size) }
    catch {
      var info = stat(); if fstatat(dir, entry.path.last!, &info, AT_SYMLINK_NOFOLLOW) == 0 { throw FolderTransferError.conflict(entry.displayPath) }
      throw FolderTransferError.insufficientSpace
    }
    let staged = destination.staged
    let id = UUID(uuidString: String(staged.name.dropFirst(".thundercontrol-".count).dropLast(".partial".count)))!
    var payload = Data(); payload.appendBE(UInt32(index)); payload.append(id.bytes); payload.appendBE(staged.device); payload.appendBE(staged.inode)
    try append(.begin, payload)
    try point("afterBegin", leak: destination)
    return destination
  }

  /// Write-ahead expected digest, exclusive publication, then a durable completion receipt.
  func commit(_ index: Int, _ destination: FileDestination, sha: Data, admit: () throws -> Void) throws {
    let staged = destination.staged
    let id = UUID(uuidString: String(staged.name.dropFirst(".thundercontrol-".count).dropLast(".partial".count)))!
    var payload = Data(); payload.appendBE(UInt32(index)); payload.append(id.bytes); payload.appendBE(staged.device); payload.appendBE(staged.inode); payload.append(sha)
    try append(.expect, payload)
    try point("afterExpect", leak: destination)
    do { try destination.commit(admit: admit) } catch FileTransferError.cancelled { throw FileTransferError.cancelled } catch { throw FolderTransferError.conflict(manifest.entries[index].displayPath) }
    try point("afterRename")
    try recordDone(index, Receipt(stat: FolderFileStat(try destination.publishedStat()), sha: sha))
  }

  /// Durable intent, stage identity check, then RENAME_EXCL of the whole folder.
  func publish(admit: () throws -> Void) throws {
    if published { return }
    for (index, entry) in manifest.entries.enumerated() where entry.kind == .file { guard receipts[index] != nil else { throw FolderTransferError.invalidManifest } }
    try append(.publishIntent, Data())
    try point("afterIntent")
    try admit()
    // Nothing outside the manifest is published: unknown entries pause with a conflict and stay in place.
    try verifyExactTree(receipts, check: {}, pulse: FolderPulse())
    var info = stat()
    guard fstatat(parent, stageName, &info, AT_SYMLINK_NOFOLLOW) == 0, (info.st_mode & S_IFMT) == S_IFDIR, folderIdentity(info) == rootID else { throw FolderTransferError.unconfirmed }
    guard renameatx_np(parent, stageName, parent, finalName, UInt32(RENAME_EXCL)) == 0 else { throw errno == EEXIST ? FolderTransferError.destinationExists : FileTransferError.io }
    _ = fsync(parent)
    try point("afterPublish")
    try append(.published, Data()); published = true
  }

  /// Removes the owned journal once the sender acknowledged completion.
  func finish() {
    guard published, !finished else { return }
    var info = stat()
    if fstatat(parent, journalName, &info, AT_SYMLINK_NOFOLLOW) == 0, folderIdentity(info) == journalID { _ = unlinkat(parent, journalName, 0); _ = fsync(parent) }
    finished = true
  }
}

private struct FolderReceiverStoreTemp { let name: String; let device: UInt64; let inode: UInt64 }
private struct ParsedJournal {
  var header = Data()
  var good = 0
  var begins: [Int: [FolderReceiverStoreTemp]] = [:]
  var expects: [Int: (FolderReceiverStoreTemp, Data)] = [:]
  var done: [Int: FolderReceiverStore.Receipt] = [:]
  var publishIntent = false
  var publishedRecord = false
}
