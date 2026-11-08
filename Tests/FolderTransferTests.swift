import Foundation
import CryptoKit
import Darwin

// Standalone folder module checks: Foundation/CryptoKit/Darwin only, no AppKit or relay.
// Build: see docs/FOLDER_TRANSFER.md. Uses a plaintext socketpair channel; the product adapter
// over the authenticated file channel is covered by Tests/FileTransferTests.swift.

final class PairChannel: FolderChannel {
  let fd: Int32
  var dropBeforeSend: (FolderMessage) -> Bool = { _ in false }
  var dropAfterReceive: (FolderMessage) -> Bool = { _ in false }
  init(_ fd: Int32, timeout: TimeInterval) {
    self.fd = fd
    var t = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000)); var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &t, socklen_t(MemoryLayout<timeval>.size)); setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, 4)
  }
  deinit { close(fd) }
  func cut() { shutdown(fd, SHUT_RDWR) }
  func send(_ m: FolderMessage) throws {
    if dropBeforeSend(m) { cut(); throw FileTransferError.io }
    let body = try JSONEncoder().encode(m); guard body.count <= 100000 else { throw FileTransferError.invalid }
    var frame = Data(); frame.appendBE(UInt32(body.count)); frame.append(body)
    try frame.withUnsafeBytes { raw in var o = 0; while o < raw.count { let n = Darwin.send(fd, raw.baseAddress! + o, raw.count - o, 0); guard n > 0 else { throw FileTransferError.io }; o += n } }
  }
  private func read(_ count: Int) throws -> Data {
    var d = Data(count: count)
    try d.withUnsafeMutableBytes { raw in var o = 0; while o < count { let n = recv(fd, raw.baseAddress! + o, count - o, 0); guard n > 0 else { throw FileTransferError.io }; o += n } }
    return d
  }
  func receive() throws -> FolderMessage {
    let size = try read(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }; guard size > 0, size <= 100000 else { throw FileTransferError.invalid }
    let m = try JSONDecoder().decode(FolderMessage.self, from: try read(Int(size))); try m.validate()
    if dropAfterReceive(m) { cut(); throw FileTransferError.io }
    return m
  }
}

func folderExpect(_ ok: Bool, _ label: String) { if !ok { print("FAIL " + label); exit(1) } }
func folderThrows(_ label: String, _ match: (Error) -> Bool = { _ in true }, _ body: () throws -> Void) {
  do { try body(); folderExpect(false, label + " (no error)") } catch { folderExpect(match(error), label + " wrong error \(error)") }
}

let folderL = UUID(), folderP = UUID(), folderOther = UUID()
let folderIdentity = FolderPeerIdentity(local: folderL, peer: folderP)
let folderFast = FolderTiming(heartbeat: 0.05, stall: 5, approval: 5)

struct FolderRun { var sender: Result<FolderOutcome, Error>; var receiver: Result<FolderOutcome, Error> }
func folderTransfer(_ source: URL, to destination: URL?, identity: FolderPeerIdentity = folderIdentity, timing: FolderTiming = folderFast, socketTimeout: TimeInterval = 2,
                    configure: (PairChannel, PairChannel) -> Void = { _, _ in }, senderCheck: @escaping () throws -> Void = {}, senderReport: @escaping (FolderProgress) -> Void = { _ in },
                    receiverReport: @escaping (FolderProgress) -> Void = { _ in }) -> FolderRun {
  var pair: [Int32] = [0, 0]; precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
  let s = PairChannel(pair[0], timeout: socketTimeout), r = PairChannel(pair[1], timeout: socketTimeout)
  configure(s, r)
  var receiverResult: Result<FolderOutcome, Error> = .failure(FileTransferError.io)
  let done = DispatchSemaphore(value: 0)
  DispatchQueue.global().async {
    receiverResult = Result {
      guard case .offer(let offer) = try r.receive() else { throw FileTransferError.invalid }
      return try FolderTransferEngine.receive(offer, over: r, identity: identity, timing: timing, choose: { _ in destination }, check: {}, report: receiverReport)
    }
    r.cut(); done.signal()
  }
  let senderResult = Result { () -> FolderOutcome in
    let plan = try FolderSourcePlan.capture(source)
    return try FolderTransferEngine.send(plan, over: s, timing: timing, check: senderCheck, report: senderReport)
  }
  s.cut(); done.wait()
  return FolderRun(sender: senderResult, receiver: receiverResult)
}

func folderTree(_ url: URL) throws -> [String: Data?] {
  var out: [String: Data?] = [:]
  for rel in try FileManager.default.subpathsOfDirectory(atPath: url.path) {
    var isDir: ObjCBool = false; _ = FileManager.default.fileExists(atPath: url.appendingPathComponent(rel).path, isDirectory: &isDir)
    out[rel] = isDir.boolValue ? nil : try Data(contentsOf: url.appendingPathComponent(rel))
  }
  return out
}
func folderFixture(_ base: URL, _ name: String = "source") throws -> URL {
  let root = base.appendingPathComponent(name)
  let fm = FileManager.default
  try fm.createDirectory(at: root.appendingPathComponent("a/b"), withIntermediateDirectories: true)
  try fm.createDirectory(at: root.appendingPathComponent("empty-dir/nested-empty"), withIntermediateDirectories: true)
  try Data([1, 2, 3]).write(to: root.appendingPathComponent(".hidden"))
  try Data((0..<150001).map { UInt8($0 % 251) }).write(to: root.appendingPathComponent("a/b/c.bin"))
  try Data((0..<70000).map { UInt8($0 % 13) }).write(to: root.appendingPathComponent("a/b/d.bin"))
  try Data().write(to: root.appendingPathComponent("a/empty.txt"))
  try Data("hello".utf8).write(to: root.appendingPathComponent("z.txt"))
  return root
}
func folderSameTree(_ a: URL, _ b: URL) throws -> Bool {
  let x = try folderTree(a), y = try folderTree(b)
  guard x == y else { print("tree differs", x.keys.sorted(), y.keys.sorted(), x.filter { y[$0.key] != $0.value }.keys); return false }
  for (path, data) in y where data != nil { guard getxattr(b.appendingPathComponent(path).path, "com.apple.quarantine", nil, 0, 0, 0) > 0 else { print("no quarantine", path); return false } }
  return true
}
func folderSiblings(_ dest: URL) -> [String] {
  ((try? FileManager.default.contentsOfDirectory(atPath: dest.deletingLastPathComponent().path)) ?? []).filter { $0.hasPrefix(dest.lastPathComponent) }.sorted()
}
func folderEntry(_ path: String, _ kind: FolderEntry.Kind = .file, _ size: UInt64 = 0) -> FolderEntry {
  FolderEntry(path: path.split(separator: "/", omittingEmptySubsequences: false).map(String.init), kind: kind, size: size, version: Data(count: 32))
}

@main struct FolderTransferTests {
  static func main() throws {
    let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ThunderControl-folder-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: base) }
    try manifestRules()
    try sourceRules(base)
    try roundTrip(base)
    try resumeAndIdentity(base)
    try crashRecovery(base)
    try destinationSafety(base)
    try heartbeats(base)
    try largeSynthetic(base)
    print("PASS all folder module checks")
  }

  static func manifestRules() throws {
    let v = Data(count: 32)
    let good = try FolderManifest(rootName: "root", rootVersion: v, entries: [folderEntry("a", .directory), folderEntry("a/.x", .file, 3), folderEntry("b", .file, 0)])
    let decoded = try FolderManifest.decode(good.canonical)
    folderExpect(decoded.digest == good.digest && decoded.entries == good.entries && good.fileCount == 2 && good.totalBytes == 3, "manifest round trip")
    var tampered = good.canonical; tampered[tampered.count - 1] ^= 1
    folderThrows("tampered manifest") { let m = try FolderManifest.decode(tampered); folderExpect(m.digest != good.digest, "digest binds bytes"); throw FileTransferError.invalid }
    folderThrows("trailing bytes") { _ = try FolderManifest.decode(good.canonical + Data([0])) }
    let bad: [[FolderEntry]] = [
      [folderEntry("/abs")], [folderEntry("")], [folderEntry(".")], [folderEntry("..")], [folderEntry("a/../b")], [folderEntry("a\\b")],
      [folderEntry("bad\u{1}")], [folderEntry("zero\u{200B}width")], [folderEntry("b"), folderEntry("a")], [folderEntry("a"), folderEntry("a")],
      [folderEntry("A"), folderEntry("a")], [folderEntry("caf\u{E9}"), folderEntry("cafe\u{301}")], [folderEntry("a"), folderEntry("a/b")],
      [folderEntry("missing/child")], [folderEntry("d", .directory, 1)], [FolderEntry(path: ["x"], kind: .file, size: 0, version: Data(count: 31))],
      [folderEntry(String(repeating: "n", count: 256))],
    ]
    for entries in bad { folderThrows("reject \(entries.map(\.displayPath))") { _ = try FolderManifest(rootName: "root", rootVersion: v, entries: entries) } }
    folderThrows("reject root name") { _ = try FolderManifest(rootName: "..", rootVersion: v, entries: []) }
    var deep: [FolderEntry] = []; var path = ""
    for i in 0...FolderLimits.depth { path += (i == 0 ? "" : "/") + "d"; deep.append(folderEntry(path, .directory)) }
    folderThrows("depth cap") { _ = try FolderManifest(rootName: "root", rootVersion: v, entries: deep) }
    folderThrows("per-file 64GiB cap", { ($0 as? FolderTransferError) == .fileTooLarge("big") }) { _ = try FolderManifest(rootName: "root", rootVersion: v, entries: [folderEntry("big", .file, FileOffer.maximum + 1)]) }
    let many = (0...FolderLimits.entries).map { folderEntry(String(format: "%06d", $0)) }
    folderThrows("entry cap", { ($0 as? FolderTransferError) == .tooManyEntries }) { _ = try FolderManifest(rootName: "root", rootVersion: v, entries: many) }
    // 15 levels of 255-byte names plus a 255-byte leaf: about 4 KB per entry, so 9000 entries exceed 32 MiB.
    var long: [FolderEntry] = []; var prefix: [String] = []
    for i in 0..<15 { prefix.append(String(repeating: Character(UnicodeScalar(UInt8(97 + i))), count: 255)); long.append(FolderEntry(path: prefix, kind: .directory, size: 0, version: v)) }
    for i in 0..<9000 { long.append(FolderEntry(path: prefix + [String(format: "%06d", i) + String(repeating: "x", count: 240)], kind: .file, size: 0, version: v)) }
    folderThrows("32 MiB canonical cap", { ($0 as? FolderTransferError) == .manifestTooLarge }) { _ = try FolderManifest(rootName: "root", rootVersion: v, entries: long) }
    folderThrows("offer cap") { try FolderOffer(id: UUID(), name: "x", totalBytes: UInt64(Int64.max) + 1, fileCount: 0, entryCount: 0, manifestBytes: 1, digest: v).validate() }
    for m in [FolderMessage.data(Data()), .data(Data(count: 65537)), .manifest(Data(count: 60001)), .fileEnd(0, Data(count: 31)), .fileBegin(-1), .plan(Data(count: 12501)), .finish(Data(count: 1))] {
      folderThrows("message shape \(m)") { try m.validate() }
    }
    let frame = try JSONEncoder().encode(FolderMessage.data(Data(count: 65536)))
    folderExpect(frame.count < 100000 - 16, "max data frame under existing 100000 cap: \(frame.count)")
    print("PASS manifest paths, collisions, caps, canonical digest, message shapes")
  }

  static func sourceRules(_ base: URL) throws {
    let src = try folderFixture(base, "rules")
    let a = try FolderSourcePlan.capture(src), b = try FolderSourcePlan.capture(src)
    folderExpect(a.manifest.digest == b.manifest.digest && a.offer.id != b.offer.id, "same unchanged source, same digest, fresh offer id")
    folderExpect(a.manifest.entries.map(\.displayPath) == [".hidden", "a", "a/b", "a/b/c.bin", "a/b/d.bin", "a/empty.txt", "empty-dir", "empty-dir/nested-empty", "z.txt"], "sorted entries incl hidden/empty")
    try a.verifyUnchanged()
    try Data("hellp".utf8).write(to: src.appendingPathComponent("z.txt"))
    folderThrows("changed file invalidates plan") { try a.verifyUnchanged() }
    folderThrows("changed file open") { _ = try a.open(a.manifest.entries.firstIndex { $0.displayPath == "z.txt" }!) }
    let c = try FolderSourcePlan.capture(src); folderExpect(c.manifest.digest != a.manifest.digest, "changed source new digest")
    // Swap an intermediate directory after capture.
    let index = c.manifest.entries.firstIndex { $0.displayPath == "a/b/c.bin" }!
    try FileManager.default.moveItem(at: src.appendingPathComponent("a/b"), to: src.appendingPathComponent("moved"))
    try FileManager.default.createDirectory(at: src.appendingPathComponent("a/b"), withIntermediateDirectories: false)
    try Data((0..<150001).map { UInt8($0 % 251) }).write(to: src.appendingPathComponent("a/b/c.bin"))
    folderThrows("directory swap rejected", { ($0 as? FolderTransferError) == .sourceChanged }) { _ = try c.open(index) }
    try FileManager.default.removeItem(at: src.appendingPathComponent("a/b"))
    precondition(symlink(src.appendingPathComponent("moved").path, src.appendingPathComponent("a/b").path) == 0)
    folderThrows("directory symlink swap rejected") { _ = try c.open(index) }
    folderThrows("symlink entry", { ($0 as? FolderTransferError) == .unsupportedEntry("a/b") }) { _ = try FolderSourcePlan.capture(src) }
    let link = base.appendingPathComponent("rootlink"); precondition(symlink(src.path, link.path) == 0)
    folderThrows("symlink root") { _ = try FolderSourcePlan.capture(link) }
    let fifoRoot = base.appendingPathComponent("fifo-root"); try FileManager.default.createDirectory(at: fifoRoot, withIntermediateDirectories: false)
    precondition(mkfifo(fifoRoot.appendingPathComponent("pipe").path, 0o600) == 0)
    let started = ProcessInfo.processInfo.systemUptime
    folderThrows("FIFO entry", { ($0 as? FolderTransferError) == .unsupportedEntry("pipe") }) { _ = try FolderSourcePlan.capture(fifoRoot) }
    folderExpect(ProcessInfo.processInfo.systemUptime - started < 1, "FIFO not opened")
    folderThrows("FIFO root") { _ = try FolderSourcePlan.capture(fifoRoot.appendingPathComponent("pipe")) }
    print("PASS source snapshot determinism, change, directory swap, symlink, FIFO, hidden and empty entries")
  }

  static func roundTrip(_ base: URL) throws {
    let src = try folderFixture(base, "rt-source")
    let dest = base.appendingPathComponent("rt-dest")
    var reports: [FolderProgress] = []
    let run = folderTransfer(src, to: dest, receiverReport: { reports.append($0) })
    guard case .success(.completed(let p)) = run.sender, case .success(.completed) = run.receiver else { folderExpect(false, "round trip \(run)"); return }
    folderExpect(p.doneFiles == 5 && p.totalFiles == 5 && p.skippedFiles == 0 && p.doneBytes == p.totalBytes, "sender progress \(p)")
    folderExpect(try folderSameTree(src, dest), "exact tree, data and quarantine")
    folderExpect(folderSiblings(dest) == ["rt-dest"], "no stage or journal left \(folderSiblings(dest))")
    folderExpect(reports.count <= 20 && reports.last?.doneFiles == 5 && reports.last?.verifying == false, "throttled receiver progress ends exact \(reports.count)")
    let declined = folderTransfer(src, to: nil)
    guard case .success(.declined) = declined.sender else { folderExpect(false, "decline"); return }
    let again = folderTransfer(src, to: dest)
    guard case .failure(FolderTransferError.peerFailed(.exists)) = again.sender else { folderExpect(false, "existing final not replaced \(again)"); return }
    folderExpect(try folderSameTree(src, dest), "existing folder untouched")
    print("PASS engine round trip: exact data, empty/hidden, quarantine, decline, no overwrite")
  }

  static func resumeAndIdentity(_ base: URL) throws {
    let src = try folderFixture(base, "resume-source"), dest = base.appendingPathComponent("resume-dest")
    // Lost ACK: receiver commits the second file but its acknowledgement never arrives.
    var acks = 0
    let first = folderTransfer(src, to: dest, configure: { _, r in r.dropBeforeSend = { if case .fileDone = $0 { acks += 1; return acks == 2 }; return false } })
    guard case .failure = first.sender else { folderExpect(false, "interrupted"); return }
    folderExpect(folderSiblings(dest) == ["resume-dest.partial", "resume-dest.partial.journal"], "stage and journal kept \(folderSiblings(dest))")
    let tempLeft = try FileManager.default.subpathsOfDirectory(atPath: dest.path + ".partial").filter { $0.contains(".thundercontrol-") }
    folderExpect(tempLeft.isEmpty, "interrupted current partial cleaned")
    let wrong = folderTransfer(src, to: dest, identity: FolderPeerIdentity(local: folderL, peer: folderOther))
    guard case .failure(FolderTransferError.peerFailed(.resumeMismatch)) = wrong.sender else { folderExpect(false, "different peer rejected \(wrong)"); return }
    // Cancel mid-way in a new run (new channel and plan), then finish in a third.
    var cancelled = false
    var doneSeen = 0
    let second = folderTransfer(src, to: dest, configure: { s, _ in s.dropAfterReceive = { if case .fileDone = $0 { doneSeen += 1; if doneSeen == 1 { cancelled = true } }; return false } },
                                senderCheck: { if cancelled { throw FileTransferError.cancelled } })
    guard case .failure(FileTransferError.cancelled) = second.sender else { folderExpect(false, "cancel \(second.sender)"); return }
    var final: FolderProgress?
    let third = folderTransfer(src, to: dest, senderReport: { final = $0 })
    guard case .success(.completed(let p)) = third.sender else { folderExpect(false, "resume \(third)"); return }
    folderExpect(p.skippedFiles == 3 && p.doneFiles == 5, "completed files skipped: \(p) \(String(describing: final))")
    folderExpect(try folderSameTree(src, dest) && folderSiblings(dest) == ["resume-dest"], "resumed tree exact")
    // Final completion ACK lost: the receiver published; a retry recognizes it by journal and inode.
    let dest2 = base.appendingPathComponent("final-ack")
    let lost = folderTransfer(src, to: dest2, configure: { _, r in r.dropBeforeSend = { if case .complete = $0 { return true }; return false } })
    guard case .failure = lost.sender else { folderExpect(false, "final ack lost"); return }
    folderExpect(folderSiblings(dest2) == ["final-ack", "final-ack.partial.journal"], "published with journal \(folderSiblings(dest2))")
    let retry = folderTransfer(src, to: dest2)
    guard case .success(.completed(let q)) = retry.sender else { folderExpect(false, "retry after final ack \(retry)"); return }
    let sameFinal = try folderSameTree(src, dest2); folderExpect(q.skippedFiles == 5 && folderSiblings(dest2) == ["final-ack"] && sameFinal, "published recognized")
    // Changed source cannot reuse the old checkpoint.
    let dest3 = base.appendingPathComponent("changed")
    acks = 0
    _ = folderTransfer(src, to: dest3, configure: { _, r in r.dropBeforeSend = { if case .fileDone = $0 { acks += 1; return acks == 1 }; return false } })
    try Data("other".utf8).write(to: src.appendingPathComponent("z.txt"))
    let changed = folderTransfer(src, to: dest3)
    guard case .failure(FolderTransferError.peerFailed(.resumeMismatch)) = changed.sender else { folderExpect(false, "changed source mismatch \(changed)"); return }
    print("PASS lost ACK, cancel and resume across new channels, different peer rejected, final ACK loss, changed source")
  }

  static func crashRecovery(_ base: URL) throws {
    let src = try folderFixture(base, "crash-source")
    for (n, point) in ["afterBegin", "afterExpect", "afterRename", "afterIntent", "afterPublish"].enumerated() {
      let dest = base.appendingPathComponent("crash-\(n)")
      FolderReceiverStore.crashPoint = point
      let crashed = folderTransfer(src, to: dest)
      guard case .failure = crashed.sender, case .failure(let e) = crashed.receiver, e is FolderReceiverStore.Crash else { folderExpect(false, "crash \(point) \(crashed)"); return }
      var p: FolderProgress?
      let resumed = folderTransfer(src, to: dest, senderReport: { p = $0 })
      guard case .success(.completed) = resumed.sender else { folderExpect(false, "recover \(point) \(resumed)"); return }
      folderExpect(try folderSameTree(src, dest) && folderSiblings(dest) == [dest.lastPathComponent], "recovered \(point) \(folderSiblings(dest))")
      let temps = try FileManager.default.subpathsOfDirectory(atPath: dest.path).filter { $0.contains(".thundercontrol-") }
      folderExpect(temps.isEmpty, "recorded temp removed \(point)")
      if point == "afterRename" { folderExpect(p?.skippedFiles == 1, "renamed file adopted by expected digest") }
      if point == "afterPublish" || point == "afterIntent" { folderExpect(p?.skippedFiles == 5, "all receipts \(point)") }
    }
    // Publish intent, then the stage is replaced by an unrelated folder: never claimed.
    let dest = base.appendingPathComponent("crash-unrelated")
    FolderReceiverStore.crashPoint = "afterIntent"
    _ = folderTransfer(src, to: dest)
    try FileManager.default.moveItem(atPath: dest.path + ".partial", toPath: base.appendingPathComponent("moved-away").path)
    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
    let unrelated = folderTransfer(src, to: dest)
    guard case .failure(FolderTransferError.peerFailed) = unrelated.sender else { folderExpect(false, "unrelated final \(unrelated)"); return }
    folderExpect((try FileManager.default.contentsOfDirectory(atPath: dest.path)).isEmpty, "unrelated folder untouched")
    // Completed receipt modified with same size: rehash detects it and nothing is overwritten.
    let dest2 = base.appendingPathComponent("tampered")
    var acks = 0
    _ = folderTransfer(src, to: dest2, configure: { _, r in r.dropBeforeSend = { if case .fileDone = $0 { acks += 1; return acks == 3 }; return false } })
    let victim = URL(fileURLWithPath: dest2.path + ".partial/.hidden")
    try Data([9, 9, 9]).write(to: victim)
    let tampered = folderTransfer(src, to: dest2)
    guard case .failure(FolderTransferError.peerFailed(.conflict)) = tampered.sender else { folderExpect(false, "tampered receipt \(tampered)"); return }
    folderExpect(try Data(contentsOf: victim) == Data([9, 9, 9]), "unknown content kept")
    // Same bytes, new stat: rehash accepts it.
    try Data([1, 2, 3]).write(to: victim)
    var p: FolderProgress?
    let touched = folderTransfer(src, to: dest2, senderReport: { p = $0 })
    guard case .success(.completed) = touched.sender else { folderExpect(false, "touched receipt rehash \(touched)"); return }
    folderExpect(p?.skippedFiles == 3, "rehashed receipt skipped")
    print("PASS crash before/after per-file rename, publish intent, final rename, unrelated final, receipt rehash")
  }

  static func destinationSafety(_ base: URL) throws {
    let src = try folderFixture(base, "safety-source")
    let user = base.appendingPathComponent("mine.partial"); try FileManager.default.createDirectory(at: user, withIntermediateDirectories: false)
    try Data([7]).write(to: user.appendingPathComponent("keep"))
    let run = folderTransfer(src, to: base.appendingPathComponent("mine"))
    guard case .failure(FolderTransferError.peerFailed(.exists)) = run.sender else { folderExpect(false, "user .partial not merged"); return }
    folderExpect(try folderTree(user) == ["keep": Data([7])], "user folder untouched")
    // A symlink planted inside the stage between attempts is never followed.
    let dest = base.appendingPathComponent("planted"); var acks = 0
    _ = folderTransfer(src, to: dest, configure: { _, r in r.dropBeforeSend = { if case .fileDone = $0 { acks += 1; return acks == 1 }; return false } })
    let outside = base.appendingPathComponent("outside"); try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
    try FileManager.default.removeItem(atPath: dest.path + ".partial/a/b")
    precondition(symlink(outside.path, dest.path + ".partial/a/b") == 0)
    let planted = folderTransfer(src, to: dest)
    guard case .failure(FolderTransferError.peerFailed(.conflict)) = planted.sender else { folderExpect(false, "planted link \(planted)"); return }
    folderExpect((try FileManager.default.contentsOfDirectory(atPath: outside.path)).isEmpty, "nothing written through link")
    // Wrong digest from a faulty sender: authentication failure, nothing published, temp cleaned.
    let hashDest = base.appendingPathComponent("hash-dest")
    var pair: [Int32] = [0, 0]; precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
    let s = PairChannel(pair[0], timeout: 2), r = PairChannel(pair[1], timeout: 2)
    var result: Result<FolderOutcome, Error> = .failure(FileTransferError.io); let done = DispatchSemaphore(value: 0)
    let plan = try FolderSourcePlan.capture(src)
    DispatchQueue.global().async {
      result = Result { guard case .offer(let o) = try r.receive() else { throw FileTransferError.invalid }; return try FolderTransferEngine.receive(o, over: r, identity: folderIdentity, timing: folderFast, choose: { _ in hashDest }, check: {}, report: { _ in }) }
      r.cut(); done.signal()
    }
    try s.send(.offer(plan.offer)); guard case .accept = try s.receive() else { fatalError() }
    try s.send(.manifest(plan.manifest.canonical))
    guard case .plan = try s.receive() else { fatalError() }
    let zIndex = plan.manifest.entries.firstIndex { $0.displayPath == "z.txt" }!
    try s.send(.fileBegin(zIndex)); try s.send(.data(Data("hello".utf8))); try s.send(.fileEnd(zIndex, Data(count: 32)))
    done.wait()
    guard case .failure(FileTransferError.authentication) = result else { folderExpect(false, "wrong hash \(result)"); return }
    folderExpect(!FileManager.default.fileExists(atPath: hashDest.path + ".partial/z.txt") && !FileManager.default.fileExists(atPath: hashDest.path), "wrong hash not published")
    let temps = try FileManager.default.subpathsOfDirectory(atPath: hashDest.path + ".partial").filter { $0.contains(".thundercontrol-") }
    folderExpect(temps.isEmpty, "wrong hash temp removed")
    print("PASS no merge with user .partial, planted stage link, wrong digest rejected")
  }

  static func heartbeats(_ base: URL) throws {
    let src = try folderFixture(base, "slow-source")
    FolderReceiverStore.slowCommit = 1.0
    defer { FolderReceiverStore.slowCommit = 0 }
    let ok = folderTransfer(src, to: base.appendingPathComponent("slow-ok"), timing: FolderTiming(heartbeat: 0.05, stall: 5, approval: 5), socketTimeout: 0.3)
    guard case .success(.completed) = ok.sender else { folderExpect(false, "slow verification with heartbeats \(ok)"); return }
    let starved = folderTransfer(src, to: base.appendingPathComponent("slow-fail"), timing: FolderTiming(heartbeat: 5, stall: 5, approval: 5), socketTimeout: 0.3)
    guard case .failure = starved.sender else { folderExpect(false, "control: no heartbeat must time out"); return }
    let stalled = folderTransfer(src, to: base.appendingPathComponent("slow-stall"), timing: FolderTiming(heartbeat: 0.05, stall: 0.5, approval: 5), socketTimeout: 0.3)
    guard case .failure(FolderTransferError.stalled) = stalled.sender else { folderExpect(false, "stall budget bounds heartbeats \(stalled.sender)"); return }
    print("PASS 1s commit over 0.3s socket timeout kept alive by working frames; control times out; stall budget enforced")
  }

  static func largeSynthetic(_ base: URL) throws {
    let root = base.appendingPathComponent("sparse-100x63GB"); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    for i in 0..<100 {
      let fd = open(root.appendingPathComponent(String(format: "part-%03d.bin", i)).path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
      precondition(fd >= 0 && ftruncate(fd, 63_000_000_000) == 0); close(fd)
    }
    let started = ProcessInfo.processInfo.systemUptime
    let plan = try FolderSourcePlan.capture(root)
    folderExpect(plan.offer.totalBytes == 6_300_000_000_000 && plan.offer.fileCount == 100, "100 x 63GB metadata valid")
    folderExpect(ProcessInfo.processInfo.systemUptime - started < 2, "capture reads no data")
    let run = folderTransfer(root, to: base.appendingPathComponent("sparse-dest"))
    guard case .failure(FolderTransferError.peerFailed(.space)) = run.sender, case .failure(FolderTransferError.insufficientSpace) = run.receiver else { folderExpect(false, "space preflight \(run)"); return }
    folderExpect(folderSiblings(base.appendingPathComponent("sparse-dest")).count == 2, "checkpoint kept, nothing written")
    let big = base.appendingPathComponent("too-big"); try FileManager.default.createDirectory(at: big, withIntermediateDirectories: false)
    let fd = open(big.appendingPathComponent("huge.bin").path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    precondition(fd >= 0 && ftruncate(fd, off_t(FileOffer.maximum + 1)) == 0); close(fd)
    folderThrows("per-file cap on capture", { ($0 as? FolderTransferError) == .fileTooLarge("huge.bin") }) { _ = try FolderSourcePlan.capture(big) }
    print("PASS sparse 100 x 63GB plan without reading data, receiver space preflight, 64GiB+1 file rejected")
  }
}
