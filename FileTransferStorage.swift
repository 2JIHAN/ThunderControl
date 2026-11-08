import Foundation
import CryptoKit
import Darwin

struct FileOffer: Codable, Equatable {
  let id: UUID
  let name: String
  let byteCount: UInt64
  static let maximum: UInt64 = 64 * 1024 * 1024 * 1024
  func validate() throws {
    guard byteCount <= Self.maximum, folderNameIsValid(name) else { throw FileTransferError.invalid }
  }
}
enum FileTransferError: Error { case invalid, cancelled, io, authentication, busy, declined, changed, unconfirmed }

final class FileSource {
  let fd: Int32
  let offer: FileOffer
  private let initial: stat
  convenience init(_ url: URL) throws {
    let opened = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard opened >= 0 else { throw FileTransferError.io }
    try self.init(descriptor: opened, name: url.lastPathComponent)
  }
  /// Takes ownership of `descriptor`, closing it on failure. `byteCount` optionally pins the expected size.
  init(descriptor opened: Int32, name: String, byteCount expected: UInt64? = nil) throws {
    var info = stat()
    guard fstat(opened, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0, expected.map({ $0 == UInt64(info.st_size) }) ?? true else { close(opened); throw FileTransferError.invalid }
    let candidate = FileOffer(id: UUID(), name: name, byteCount: UInt64(info.st_size))
    do { try candidate.validate() } catch { close(opened); throw error }
    fd = opened; initial = info; offer = candidate
  }
  deinit { close(fd) }
  func chunk() throws -> Data {
    var bytes = [UInt8](repeating: 0, count: 65536)
    var count: Int
    repeat { count = read(fd, &bytes, bytes.count) } while count < 0 && errno == EINTR
    guard count >= 0 else { throw FileTransferError.io }
    return Data(bytes.prefix(count))
  }
  func verifyUnchanged() throws {
    var now = stat()
    guard fstat(fd, &now) == 0, now.st_size == initial.st_size,
      now.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec, now.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec,
      now.st_ctimespec.tv_sec == initial.st_ctimespec.tv_sec, now.st_ctimespec.tv_nsec == initial.st_ctimespec.tv_nsec
    else { throw FileTransferError.changed }
  }
}

final class FileDestination {
  private let directory: Int32
  private let fd: Int32
  private let temporary: String
  private let destination: String
  private let device: dev_t
  private let inode: ino_t
  private var published = false
  /// Name and identity of the exclusive temp file, for write-ahead records.
  var staged: (name: String, device: UInt64, inode: UInt64) { (temporary, UInt64(UInt32(bitPattern: device)), UInt64(inode)) }
  convenience init(_ url: URL, bytes: UInt64) throws {
    let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard parent >= 0 else { throw FileTransferError.io }
    defer { close(parent) }
    try self.init(directory: parent, name: url.lastPathComponent, bytes: bytes)
  }
  /// Borrows `directory` (it is duplicated). The staged temp identity is available before any byte is written.
  init(directory borrowed: Int32, name: String, bytes: UInt64) throws {
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { throw FileTransferError.invalid }
    let parent = dup(borrowed); guard parent >= 0 else { throw FileTransferError.io }
    _ = fcntl(parent, F_SETFD, FD_CLOEXEC)
    var existing = stat()
    guard fstatat(parent, name, &existing, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { close(parent); throw FileTransferError.io }
    var space = statvfs()
    guard fstatvfs(parent, &space) == 0 else { close(parent); throw FileTransferError.io }
    let available = UInt64(space.f_bavail).multipliedReportingOverflow(by: UInt64(space.f_frsize))
    guard available.overflow || available.partialValue >= bytes else { close(parent); throw FileTransferError.io }
    let temp = ".thundercontrol-" + UUID().uuidString + ".partial"
    let output = openat(parent, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
    guard output >= 0 else { close(parent); throw FileTransferError.io }
    var info = stat()
    guard fstat(output, &info) == 0 else { close(output); unlinkat(parent, temp, 0); close(parent); throw FileTransferError.io }
    directory = parent; fd = output; temporary = temp; destination = name; device = info.st_dev; inode = info.st_ino
  }
  func write(_ bytes: Data) throws {
    try bytes.withUnsafeBytes { raw in
      var offset = 0
      while offset < raw.count {
        let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw FileTransferError.io }; offset += count
      }
    }
  }
  func commit(admit: () throws -> Void = {}) throws {
    let quarantine = "0083;" + String(Int(Date().timeIntervalSince1970), radix: 16) + ";ThunderControl;"
    guard quarantine.withCString({ fsetxattr(fd, "com.apple.quarantine", $0, strlen($0), 0, 0) }) == 0, fgetxattr(fd, "com.apple.quarantine", nil, 0, 0, 0) > 0, fsync(fd) == 0 else { throw FileTransferError.io }
    try admit()
    var info = stat()
    guard fstatat(directory, temporary, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_dev == device, info.st_ino == inode else { throw FileTransferError.io }
    guard renameatx_np(directory, temporary, directory, destination, UInt32(RENAME_EXCL)) == 0 else { throw FileTransferError.io }
    published = true
    _ = fsync(directory)
  }
  /// Stat of the published name; fails unless it is still the staged inode.
  func publishedStat() throws -> stat {
    var info = stat()
    guard published, fstatat(directory, destination, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_dev == device, info.st_ino == inode else { throw FileTransferError.io }
    return info
  }
  deinit {
    if !published {
      var info = stat()
      if fstatat(directory, temporary, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_dev == device, info.st_ino == inode { _ = unlinkat(directory, temporary, 0) }
    }
    close(fd); close(directory)
  }
}
