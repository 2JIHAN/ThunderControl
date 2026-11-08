import Foundation
import CryptoKit
import Darwin

enum FolderFailureCode: String, Codable, Equatable {
  case exists, resumeMismatch, conflict, space, invalid
}
enum FolderTransferError: Error, Equatable {
  case unsupportedEntry(String)
  case invalidName(String)
  case fileTooLarge(String)
  case tooManyEntries, manifestTooLarge, totalTooLarge, invalidManifest
  case sourceChanged
  case destinationExists, resumeMismatch, conflict(String), insufficientSpace
  case peerUnsupported, stalled, unconfirmed
  case peerFailed(FolderFailureCode)
  var code: FolderFailureCode {
    switch self {
    case .destinationExists: return .exists
    case .resumeMismatch: return .resumeMismatch
    case .conflict: return .conflict
    case .insufficientSpace: return .space
    default: return .invalid
    }
  }
}

enum FolderLimits {
  static let entries = 100_000
  static let manifestBytes = 32 * 1024 * 1024
  static let pathBytes = 4096
  static let depth = 128
  static let manifestPart = 60_000
}

/// Metadata identity of one file system object. Equal stats mean "unchanged" for snapshot and
/// completed-receipt checks; the version digest is the opaque form placed on the wire.
struct FolderFileStat: Equatable {
  let device: UInt64, inode: UInt64, size: UInt64
  let mtime: Int64, mtimeNS: Int64, ctime: Int64, ctimeNS: Int64
  init(_ s: stat) {
    device = UInt64(UInt32(bitPattern: s.st_dev)); inode = UInt64(s.st_ino); size = UInt64(max(0, s.st_size))
    mtime = Int64(s.st_mtimespec.tv_sec); mtimeNS = Int64(s.st_mtimespec.tv_nsec)
    ctime = Int64(s.st_ctimespec.tv_sec); ctimeNS = Int64(s.st_ctimespec.tv_nsec)
  }
  init(device: UInt64, inode: UInt64, size: UInt64, mtime: Int64, mtimeNS: Int64, ctime: Int64, ctimeNS: Int64) {
    self.device = device; self.inode = inode; self.size = size; self.mtime = mtime; self.mtimeNS = mtimeNS; self.ctime = ctime; self.ctimeNS = ctimeNS
  }
  var fields: [UInt64] { [device, inode, size, UInt64(bitPattern: mtime), UInt64(bitPattern: mtimeNS), UInt64(bitPattern: ctime), UInt64(bitPattern: ctimeNS)] }
  var version: Data { var d = Data(); for f in fields { d.appendBE(f) }; return Data(SHA256.hash(data: d)) }
  /// Directory identity only. Directory ctime, size and mtime move on metadata-only events such as
  /// `com.apple.macl` from NSOpenPanel or Finder xattrs; the namespace is already bound by the
  /// captured entry names and file versions, and a swapped directory changes dev/inode.
  var directoryIdentity: FolderFileStat { FolderFileStat(device: device, inode: inode, size: 0, mtime: 0, mtimeNS: 0, ctime: 0, ctimeNS: 0) }
}

extension Data {
  mutating func appendBE<T: FixedWidthInteger>(_ value: T) { var v = value.bigEndian; Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) } }
}
/// Bounded big-endian reader for untrusted metadata. Every read checks the remaining length.
struct FolderReader {
  let data: Data
  var offset: Int
  init(_ data: Data) { self.data = data; offset = data.startIndex }
  var atEnd: Bool { offset == data.endIndex }
  mutating func bytes(_ count: Int) throws -> Data {
    guard count >= 0, data.endIndex - offset >= count else { throw FolderTransferError.invalidManifest }
    defer { offset += count }; return data.subdata(in: offset..<(offset + count))
  }
  mutating func int<T: FixedWidthInteger>(_: T.Type) throws -> T {
    try bytes(MemoryLayout<T>.size).reduce(T(0)) { ($0 << 8) | T($1) }
  }
}

struct FolderEntry: Equatable {
  enum Kind: UInt8 { case directory = 1, file = 2 }
  let path: [String]
  let kind: Kind
  let size: UInt64
  let version: Data
  var displayPath: String { path.joined(separator: "/") }
}

func folderNameIsValid(_ name: String) -> Bool {
  !name.isEmpty && name.utf8.count <= 255 && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
    && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format })
}
/// Case and Unicode-normalization folding: two names that APFS may treat as the same name collide.
private func folderFold(_ name: String) -> String {
  name.folding(options: [.caseInsensitive], locale: nil).decomposedStringWithCanonicalMapping
}
private func folderPathLess(_ a: [String], _ b: [String]) -> Bool {
  for (x, y) in zip(a, b) where x != y { return Array(x.utf8).lexicographicallyPrecedes(Array(y.utf8)) }
  return a.count < b.count
}

struct FolderManifest {
  let rootName: String
  let rootVersion: Data
  let entries: [FolderEntry]
  let canonical: Data
  let digest: Data
  let totalBytes: UInt64
  let fileCount: Int

  /// Validates the whole tree and produces the deterministic canonical encoding.
  init(rootName: String, rootVersion: Data, entries: [FolderEntry]) throws {
    guard entries.count <= FolderLimits.entries else { throw FolderTransferError.tooManyEntries }
    guard folderNameIsValid(rootName), rootVersion.count == 32 else { throw FolderTransferError.invalidName(rootName) }
    var directories = Set<[String]>(), folded = Set<String>(), total: UInt64 = 0, files = 0
    var out = Data("TCFOLDER1".utf8)
    out.appendBE(UInt16(rootName.utf8.count)); out.append(contentsOf: rootName.utf8); out.append(rootVersion); out.appendBE(UInt32(entries.count))
    var previous: [String]? = nil
    for entry in entries {
      let joined = entry.displayPath
      guard !entry.path.isEmpty, entry.path.count <= FolderLimits.depth, entry.path.allSatisfy(folderNameIsValid), joined.utf8.count <= FolderLimits.pathBytes else { throw FolderTransferError.invalidName(joined) }
      guard previous.map({ folderPathLess($0, entry.path) }) ?? true else { throw FolderTransferError.invalidManifest }
      guard entry.path.count == 1 || directories.contains(Array(entry.path.dropLast())) else { throw FolderTransferError.invalidManifest }
      guard folded.insert(entry.path.map(folderFold).joined(separator: "/")).inserted else { throw FolderTransferError.invalidName(joined) }
      guard entry.version.count == 32 else { throw FolderTransferError.invalidManifest }
      switch entry.kind {
      case .directory:
        guard entry.size == 0 else { throw FolderTransferError.invalidManifest }; directories.insert(entry.path)
      case .file:
        guard entry.size <= FileOffer.maximum else { throw FolderTransferError.fileTooLarge(joined) }
        let (sum, overflow) = total.addingReportingOverflow(entry.size)
        guard !overflow, sum <= UInt64(Int64.max) else { throw FolderTransferError.totalTooLarge }
        total = sum; files += 1
      }
      out.append(entry.kind.rawValue); out.appendBE(entry.size); out.append(entry.version)
      out.appendBE(UInt16(joined.utf8.count)); out.append(contentsOf: joined.utf8)
      guard out.count <= FolderLimits.manifestBytes else { throw FolderTransferError.manifestTooLarge }
      previous = entry.path
    }
    self.rootName = rootName; self.rootVersion = rootVersion; self.entries = entries
    canonical = out; digest = Data(SHA256.hash(data: out)); totalBytes = total; fileCount = files
  }

  /// Parses untrusted canonical bytes; re-encoding must reproduce them exactly.
  static func decode(_ data: Data) throws -> FolderManifest {
    guard data.count <= FolderLimits.manifestBytes else { throw FolderTransferError.manifestTooLarge }
    var r = FolderReader(data)
    guard try r.bytes(9) == Data("TCFOLDER1".utf8) else { throw FolderTransferError.invalidManifest }
    guard let root = String(data: try r.bytes(Int(r.int(UInt16.self))), encoding: .utf8) else { throw FolderTransferError.invalidManifest }
    let rootVersion = try r.bytes(32)
    let count = Int(try r.int(UInt32.self)); guard count <= FolderLimits.entries else { throw FolderTransferError.tooManyEntries }
    var entries: [FolderEntry] = []; entries.reserveCapacity(min(count, 4096))
    for _ in 0..<count {
      guard let kind = FolderEntry.Kind(rawValue: try r.int(UInt8.self)) else { throw FolderTransferError.invalidManifest }
      let size = try r.int(UInt64.self), version = try r.bytes(32)
      guard let joined = String(data: try r.bytes(Int(r.int(UInt16.self))), encoding: .utf8) else { throw FolderTransferError.invalidManifest }
      entries.append(FolderEntry(path: joined.split(separator: "/", omittingEmptySubsequences: false).map(String.init), kind: kind, size: size, version: version))
    }
    guard r.atEnd else { throw FolderTransferError.invalidManifest }
    let manifest = try FolderManifest(rootName: root, rootVersion: rootVersion, entries: entries)
    guard manifest.canonical == data else { throw FolderTransferError.invalidManifest }
    return manifest
  }

  func offer(id: UUID = UUID()) -> FolderOffer {
    FolderOffer(id: id, name: rootName, totalBytes: totalBytes, fileCount: fileCount, entryCount: entries.count, manifestBytes: canonical.count, digest: digest)
  }
}

/// Approval summary sent before the manifest. Separate from FileOffer: its 64GiB cap is per file.
struct FolderOffer: Codable, Equatable {
  let id: UUID
  let name: String
  let totalBytes: UInt64
  let fileCount: Int
  let entryCount: Int
  let manifestBytes: Int
  let digest: Data
  func validate() throws {
    guard folderNameIsValid(name), totalBytes <= UInt64(Int64.max), (0...FolderLimits.entries).contains(entryCount), (0...entryCount).contains(fileCount),
      (1...FolderLimits.manifestBytes).contains(manifestBytes), digest.count == 32 else { throw FolderTransferError.invalidManifest }
  }
  func matches(_ manifest: FolderManifest) -> Bool {
    manifest.rootName == name && manifest.totalBytes == totalBytes && manifest.fileCount == fileCount && manifest.entries.count == entryCount
      && manifest.canonical.count == manifestBytes && manifest.digest == digest
  }
}

/// Opens `name` under `directory` without following a link. Returns an owned descriptor.
func folderOpenDirectory(_ directory: Int32, _ name: String) throws -> Int32 {
  let fd = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
  guard fd >= 0 else { throw errno == ENOENT ? FolderTransferError.sourceChanged : FolderTransferError.unsupportedEntry(name) }
  return fd
}

/// Source snapshot: root descriptor, manifest and the captured stat of every entry.
/// No file data is read during capture.
final class FolderSourcePlan {
  let manifest: FolderManifest
  let offer: FolderOffer
  private let root: Int32
  private let stats: [FolderFileStat]
  private let parents: [Int]

  static func capture(_ url: URL, check: () throws -> Void = {}) throws -> FolderSourcePlan {
    let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw FolderTransferError.unsupportedEntry(url.lastPathComponent) }
    do { return try FolderSourcePlan(root: fd, name: url.lastPathComponent, check: check) } catch { close(fd); throw error }
  }
  private init(root: Int32, name: String, check: () throws -> Void) throws {
    let scan = try FolderSourcePlan.scan(root: root, name: name, check: check)
    self.root = root; manifest = scan.manifest; stats = scan.stats; parents = scan.parents; offer = scan.manifest.offer()
  }
  deinit { close(root) }

  private struct Scan { let manifest: FolderManifest; let stats: [FolderFileStat]; let parents: [Int] }
  private static func scan(root: Int32, name: String, check: () throws -> Void) throws -> Scan {
    var rootInfo = stat(); guard fstat(root, &rootInfo) == 0, (rootInfo.st_mode & S_IFMT) == S_IFDIR else { throw FolderTransferError.unsupportedEntry(name) }
    var entries: [FolderEntry] = [], stats: [FolderFileStat] = [], parents: [Int] = []
    // Global bounds counted at discovery, so queued names in ancestors also count.
    var discovered = 0, encoded = 9 + 2 + name.utf8.count + 32 + 4
    func walk(_ dir: Int32, _ prefix: [String], _ parent: Int) throws {
      try check()
      let handle = dup(dir); guard handle >= 0, let stream = fdopendir(handle) else { if handle >= 0 { close(handle) }; throw FolderTransferError.sourceChanged }
      defer { closedir(stream) }
      rewinddir(stream)
      var names: [String] = []
      while let item = readdir(stream) {
        let raw = withUnsafeBytes(of: item.pointee.d_name) { Data($0.prefix(Int(item.pointee.d_namlen))) }
        guard let child = String(data: raw, encoding: .utf8), Data(child.utf8) == raw else { throw FolderTransferError.invalidName((prefix + ["?"]).joined(separator: "/")) }
        if child == "." || child == ".." { continue }
        names.append(child); discovered += 1
        encoded += 43 + prefix.reduce(0) { $0 + $1.utf8.count + 1 } + raw.count
        guard discovered <= FolderLimits.entries else { throw FolderTransferError.tooManyEntries }
        guard encoded <= FolderLimits.manifestBytes else { throw FolderTransferError.manifestTooLarge }
      }
      for child in names.sorted(by: { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }) {
        let path = prefix + [child], shown = path.joined(separator: "/")
        guard folderNameIsValid(child), shown.utf8.count <= FolderLimits.pathBytes, path.count <= FolderLimits.depth else { throw FolderTransferError.invalidName(shown) }
        var info = stat(); guard fstatat(dir, child, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw FolderTransferError.sourceChanged }
        var snapshot = FolderFileStat(info)
        switch info.st_mode & S_IFMT {
        case S_IFREG:
          guard snapshot.size <= FileOffer.maximum else { throw FolderTransferError.fileTooLarge(shown) }
          entries.append(FolderEntry(path: path, kind: .file, size: snapshot.size, version: snapshot.version)); stats.append(snapshot); parents.append(parent)
        case S_IFDIR:
          let sub = try folderOpenDirectory(dir, child); defer { close(sub) }
          var opened = stat(); guard fstat(sub, &opened) == 0, FolderFileStat(opened).device == snapshot.device, opened.st_ino == info.st_ino else { throw FolderTransferError.sourceChanged }
          snapshot = snapshot.directoryIdentity
          entries.append(FolderEntry(path: path, kind: .directory, size: 0, version: snapshot.version)); stats.append(snapshot); parents.append(parent)
          try walk(sub, path, entries.count - 1)
        default: throw FolderTransferError.unsupportedEntry(shown)
        }
      }
    }
    try walk(root, [], -1)
    let rootStat = FolderFileStat(rootInfo).directoryIdentity
    return Scan(manifest: try FolderManifest(rootName: name, rootVersion: rootStat.version, entries: entries), stats: stats, parents: parents)
  }

  /// Opens one captured file through its captured directory chain and verifies it is the same version.
  func open(_ index: Int) throws -> FileSource {
    guard manifest.entries.indices.contains(index), manifest.entries[index].kind == .file else { throw FolderTransferError.invalidManifest }
    var chain: [Int] = []; var cursor = parents[index]; while cursor >= 0 { chain.insert(cursor, at: 0); cursor = parents[cursor] }
    var current = dup(root); guard current >= 0 else { throw FileTransferError.io }
    defer { close(current) }
    for ancestor in chain {
      let next = try folderOpenDirectory(current, manifest.entries[ancestor].path.last!)
      close(current); current = next
      var info = stat(); guard fstat(current, &info) == 0, FolderFileStat(info).device == stats[ancestor].device, UInt64(info.st_ino) == stats[ancestor].inode else { throw FolderTransferError.sourceChanged }
    }
    let leaf = manifest.entries[index].path.last!
    let fd = openat(current, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard fd >= 0 else { throw FolderTransferError.sourceChanged }
    var info = stat(); guard fstat(fd, &info) == 0, FolderFileStat(info) == stats[index] else { close(fd); throw FolderTransferError.sourceChanged }
    return try FileSource(descriptor: fd, name: leaf, byteCount: stats[index].size)
  }

  /// Rescans the tree from the held root descriptor; any change to any captured version fails.
  func verifyUnchanged(check: () throws -> Void = {}) throws {
    let again: Scan
    do { again = try FolderSourcePlan.scan(root: root, name: manifest.rootName, check: check) }
    catch FileTransferError.cancelled { throw FileTransferError.cancelled }
    catch { throw FolderTransferError.sourceChanged }
    guard again.manifest.digest == manifest.digest else { throw FolderTransferError.sourceChanged }
  }
}
