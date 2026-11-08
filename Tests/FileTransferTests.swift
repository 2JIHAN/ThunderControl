import Foundation
import CryptoKit
import Darwin

@main struct FileTransferTests {
  @MainActor static func main() async throws {
    try await coordinatorFixtures()
    try runFileTransferGuardFixtures()
    try fifoSourceFixture()
    let ready = DispatchSemaphore(value: 0)
    let session = FileSession(root: SymmetricKey(size: .bits256), inputIDs: "port-reuse", localIP: "127.0.0.1", interfaceIndex: if_nametoindex("lo0"), peerIP: "127.0.0.1", cancelled: { false }, onCancel: { _ in })
    let held = FileTransferService(session: session) { state in if case .idle = state { ready.signal() } }
    held.start(); guard ready.wait(timeout: .now() + 2) == .success else { fatalError("listener not ready") }
    held.stop(); held.stop()
    usleep(400000)
    let replacement = socket(AF_INET, SOCK_STREAM, 0)
    var one: Int32 = 1; _ = setsockopt(replacement, SOL_SOCKET, SO_REUSEADDR, &one, 4)
    var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = UInt16(49179).bigEndian; _ = inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
    let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(replacement, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    guard bound == 0 else { print("RED stopped retained service keeps listener port errno=\(errno)"); exit(1) }
    close(replacement)
    print("PASS stop repeated and port reuse while service retained")
    try serviceFixtures()
    try folderServiceFixtures()

    for count in [0, 65536, 150001] {
      let bytes = Data((0..<count).map { UInt8($0 % 251) })
      try runFileTransferChannelFixture(bytes)
      print("PASS encrypted TCP proofs + chunk AEAD + SHA256 \(count) bytes")
    }
    try runFileTransferChannelFixture(Data([1, 2, 3]), wrongRoot: true)
    print("PASS wrong root rejected before metadata")
    for name in ["..", "../bad", "bad/name", "bad\\name", "bad\u{0}", String(repeating: "a", count: 256)] {
      do { try FileOffer(id: UUID(), name: name, byteCount: 0).validate(); fatalError("accepted malformed name") } catch {}
    }
    do { try FileOffer(id: UUID(), name: "safe", byteCount: FileOffer.maximum + 1).validate(); fatalError("accepted oversize") } catch {}
    let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ThunderControl-file-fixture-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: folder) }
    let sourceURL = folder.appendingPathComponent("source")
    try Data([1, 2, 3]).write(to: sourceURL)
    let source = try FileSource(sourceURL); guard try source.chunk() == Data([1, 2, 3]) else { fatalError("source bytes") }; try source.verifyUnchanged()
    let destinationURL = folder.appendingPathComponent("saved")
    do { let destination = try FileDestination(destinationURL, bytes: 3); try destination.write(Data([1, 2, 3])); try destination.commit() }
    guard try Data(contentsOf: destinationURL) == Data([1, 2, 3]) else { fatalError("destination bytes") }
    do { _ = try FileDestination(destinationURL, bytes: 3); fatalError("overwrote existing destination") } catch {}
    let linked = folder.appendingPathComponent("linked"); guard symlink(sourceURL.path, linked.path) == 0 else { fatalError("symlink fixture") }
    do { _ = try FileSource(linked); fatalError("followed source symlink") } catch {}
    do { _ = try FileDestination(linked, bytes: 3); fatalError("followed destination symlink") } catch {}
    do { let partial = try FileDestination(folder.appendingPathComponent("cancelled"), bytes: 3); try partial.write(Data([1])) }
    guard !(try FileManager.default.contentsOfDirectory(atPath: folder.path)).contains(where: { $0.hasSuffix(".partial") }) else { fatalError("orphan partial") }
    try Data([4, 5]).write(to: sourceURL)
    do { try source.verifyUnchanged(); fatalError("source change undetected") } catch {}
    print("PASS names, size, source change, symlinks, exclusive publish, quarantine, partial cleanup")
  }
}

final class FixturePeer {
  let lock = NSLock()
  var service: FileTransferService!
  var target: URL?
  var hold = false
  var incoming = 0
  var completed = 0
  var terminal = 0
  var idle = 0
  var folder: FolderProgress?
  var maxSkipped = 0
  var lastFailure = ""
  func report(_ state: FileTransferState) {
    lock.lock()
    var choose = false
    switch state {
    case .incomingOffer: incoming += 1; choose = !hold
    case .completed: completed += 1; terminal += 1
    case .folderProgress(_, let p): folder = p; maxSkipped = max(maxSkipped, p.skippedFiles)
    case .failed(let text): lastFailure = text; terminal += 1
    case .cancelled: terminal += 1
    case .idle: idle += 1
    default: break
    }
    let url = target; lock.unlock()
    if choose { service.choose(url) }
  }
  func value(_ f: (FixturePeer) -> Int) -> Int { lock.lock(); defer { lock.unlock() }; return f(self) }
  func destination(_ url: URL?, hold: Bool = false) { lock.lock(); target = url; self.hold = hold; lock.unlock() }
}
func waitFixture(_ label: String, _ test: () -> Bool) {
  let deadline = ProcessInfo.processInfo.systemUptime + 5
  while !test() { guard ProcessInfo.processInfo.systemUptime < deadline else { fatalError("timeout " + label) }; usleep(10000) }
}
func freeFixturePort() -> UInt16 {
  let fd = socket(AF_INET, SOCK_STREAM, 0); defer { close(fd) }
  var a = sockaddr_in(); a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET); _ = inet_pton(AF_INET, "127.0.0.1", &a.sin_addr)
  var n = socklen_t(MemoryLayout<sockaddr_in>.size)
  precondition(withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, n) } } == 0)
  precondition(withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &n) } } == 0)
  return UInt16(bigEndian: a.sin_port)
}
func serviceFixtures() throws {
  let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ThunderControl-service-fixture-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: folder) }
  print("service fixture root " + folder.path)
  let p = freeFixturePort(); var q = freeFixturePort(); while q == p { q = freeFixturePort() }
  let root = SymmetricKey(size: .bits256)
  let a = FixturePeer(), b = FixturePeer()
  var sa = FileSession(root: root, inputIDs: "service-input", localIP: "127.0.0.1", interfaceIndex: if_nametoindex("lo0"), peerIP: "127.0.0.1", cancelled: { false }, onCancel: { _ in })
  sa.localPort = p; sa.peerPort = q
  var sb = sa; sb.localPort = q; sb.peerPort = p
  a.service = FileTransferService(session: sa, report: a.report); b.service = FileTransferService(session: sb, report: b.report)
  defer { a.service.stop(); b.service.stop() }
  a.service.start(); b.service.start()
  waitFixture("both listeners") { a.value { $0.idle } > 0 && b.value { $0.idle } > 0 }
  for direction in 0..<2 {
    let sender = direction == 0 ? a : b; let receiver = direction == 0 ? b : a
    for size in [0, 150001] {
      let bytes = Data((0..<size).map { UInt8($0 % 251) })
      let source = folder.appendingPathComponent("source-\(direction)-\(size)")
      let target = folder.appendingPathComponent("target-\(direction)-\(size)")
      try bytes.write(to: source); receiver.destination(target)
      let sent = sender.value { $0.completed }, received = receiver.value { $0.completed }
      sender.service.sendURL(source)
      waitFixture("round trip") { sender.value { $0.completed } == sent + 1 && receiver.value { $0.completed } == received + 1 }
      let actual = try Data(contentsOf: target); precondition(actual == bytes)
      precondition(getxattr(target.path, "com.apple.quarantine", nil, 0, 0, 0) > 0)
      print("PASS service direction \(direction) \(size) bytes exact digest + quarantine")
    }
  }
  let source = folder.appendingPathComponent("decline-source"); try Data([4,5,6]).write(to: source)
  b.destination(nil); let failed = a.value { $0.terminal }; a.service.sendURL(source)
  waitFixture("decline") { a.value { $0.terminal } > failed }
  b.destination(nil, hold: true); let offered = b.value { $0.incoming }; let oldA = a.value { $0.terminal }, oldB = b.value { $0.terminal }
  a.service.sendURL(source); waitFixture("approval pending") { b.value { $0.incoming } > offered }
  let c = FixturePeer(); var sc = sa; sc.localPort = freeFixturePort(); sc.peerPort = p
  c.service = FileTransferService(session: sc, report: c.report); c.service.sendURL(source)
  waitFixture("busy rejection") { c.value { $0.terminal } > 0 }; c.service.stop()
  a.service.cancel()
  waitFixture("approval cancel") { a.value { $0.terminal } > oldA && b.value { $0.terminal } > oldB }
  let saved = folder.appendingPathComponent("after-cancel"); b.destination(saved); let done = a.value { $0.completed }; a.service.sendURL(source)
  waitFixture("after cancel transfer") { a.value { $0.completed } > done }
  let actualSaved = try Data(contentsOf: saved); precondition(actualSaved == Data([4,5,6]))
  let existing = try Data(contentsOf: saved); b.destination(saved); let collision = a.value { $0.terminal }; a.service.sendURL(source)
  waitFixture("existing destination") { a.value { $0.terminal } > collision }
  let unchanged = try Data(contentsOf: saved); precondition(unchanged == existing)
  do {
    let output = folder.appendingPathComponent("commit-cancelled")
    do { let destination = try FileDestination(output, bytes: 1); try destination.write(Data([1])); try destination.commit { throw FileTransferError.cancelled }; fatalError("published cancelled commit") } catch FileTransferError.cancelled {}
    precondition(!FileManager.default.fileExists(atPath: output.path))
  }
  let remaining = try FileManager.default.contentsOfDirectory(atPath: folder.path); precondition(!remaining.contains { $0.hasSuffix(".partial") })
  print("PASS service decline, pending approval cancel, next transfer, existing destination unchanged, late commit cancellation, no partials")
}

@MainActor func coordinatorFixtures() async throws {
  let coordinator = FileTransferCoordinator()
  var idle = 0
  coordinator.onChange = { if case .idle = $0 { idle += 1 } }
  final class Cancellation { var stopped = false; var handler: (() -> Void)? }
  let context = Cancellation()
  var session = FileSession(root: SymmetricKey(size: .bits256), inputIDs: "coordinator", localIP: "127.0.0.1", interfaceIndex: if_nametoindex("lo0"), peerIP: "127.0.0.1", cancelled: { context.stopped }, onCancel: { context.handler = $0 })
  session.localPort = freeFixturePort(); session.peerPort = freeFixturePort()
  coordinator.configure(session)
  for _ in 0..<100 { if idle > 0 { break }; try await Task.sleep(nanoseconds: 10000000) }
  precondition(idle == 1)
  let token = coordinator.sessionToken
  coordinator.pollSafety(false); precondition(token != coordinator.sessionToken)
  coordinator.pollSafety(true)
  for _ in 0..<100 { if idle > 1 { break }; try await Task.sleep(nanoseconds: 10000000) }
  precondition(idle == 2)
  context.stopped = true; context.handler?(); coordinator.pollSafety(false); coordinator.pollSafety(true)
  try await Task.sleep(nanoseconds: 200000000); precondition(idle == 2)
  coordinator.configure(nil); coordinator.pollSafety(false); coordinator.pollSafety(true)
  try await Task.sleep(nanoseconds: 200000000); precondition(idle == 2)
  print("PASS coordinator unsafe-safe restores session, canceled context never restores, explicit disconnect clears session")
}

private final class FIFOResult: @unchecked Sendable {
  private let lock = NSLock()
  private var rejected = false
  func markRejected() { lock.lock(); rejected = true; lock.unlock() }
  func value() -> Bool { lock.lock(); defer { lock.unlock() }; return rejected }
}
func fifoSourceFixture() throws {
  let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ThunderControl-FIFO-" + UUID().uuidString)
  guard mkfifo(url.path, 0o600) == 0 else { throw FileTransferError.io }
  defer { unlink(url.path) }
  let began = DispatchSemaphore(value: 0), ended = DispatchSemaphore(value: 0), result = FIFOResult()
  DispatchQueue.global().async {
    began.signal()
    do { _ = try FileSource(url) } catch { result.markRejected() }
    ended.signal()
  }
  guard began.wait(timeout: .now() + 2) == .success else { throw FileTransferError.io }
  guard ended.wait(timeout: .now() + 1) == .success else {
    let writer = open(url.path, O_WRONLY | O_NONBLOCK)
    if writer >= 0 { close(writer) }
    _ = ended.wait(timeout: .now() + 2)
    throw FileTransferError.invalid
  }
  guard result.value() else { throw FileTransferError.invalid }
  print("PASS FIFO source rejected without blocking regular-file validation")
}

func folderServiceTree(_ url: URL) throws -> [String: Data?] {
  var out: [String: Data?] = [:]
  for rel in try FileManager.default.subpathsOfDirectory(atPath: url.path) {
    var dir: ObjCBool = false; _ = FileManager.default.fileExists(atPath: url.appendingPathComponent(rel).path, isDirectory: &dir)
    out[rel] = dir.boolValue ? nil : try Data(contentsOf: url.appendingPathComponent(rel))
    if !dir.boolValue { precondition(getxattr(url.appendingPathComponent(rel).path, "com.apple.quarantine", nil, 0, 0, 0) > 0, "quarantine on " + rel) }
  }
  return out
}
func folderServiceSource(_ root: URL, files: Int, size: Int) throws {
  try FileManager.default.createDirectory(at: root.appendingPathComponent("nested/empty"), withIntermediateDirectories: true)
  try Data("hidden".utf8).write(to: root.appendingPathComponent(".hidden"))
  try Data().write(to: root.appendingPathComponent("nested/zero"))
  for i in 0..<files { try Data((0..<size).map { UInt8(($0 &+ i) % 251) }).write(to: root.appendingPathComponent(String(format: "nested/part-%03d.bin", i))) }
}
/// Real localhost services over the authenticated file channel: both directions, stop and resume across
/// new session keys and input IDs with the same stable devices, a different peer, busy and old peers.
func folderServiceFixtures() throws {
  let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ThunderControl-folder-service-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: folder) }
  let deviceA = UUID(), deviceB = UUID(), deviceC = UUID()
  var bPort: UInt16 = 0 // the sender A listener: busy while A owns an active folder run
  var aSession: FileSession?
  func pair(_ peerOfB: UUID = deviceA) -> (FixturePeer, FixturePeer) {
    let p = freeFixturePort(); var q = freeFixturePort(); while q == p { q = freeFixturePort() }
    let root = SymmetricKey(size: .bits256), ids = UUID().uuidString + "|" + UUID().uuidString
    var sa = FileSession(root: root, inputIDs: ids, localIP: "127.0.0.1", interfaceIndex: if_nametoindex("lo0"), peerIP: "127.0.0.1", cancelled: { false }, onCancel: { _ in },
                         localDeviceID: deviceA, peerDeviceID: deviceB, folderTransferSupported: true)
    sa.localPort = p; sa.peerPort = q; bPort = p; aSession = sa
    var sb = sa; sb.localPort = q; sb.peerPort = p; sb.localDeviceID = deviceB; sb.peerDeviceID = peerOfB
    let a = FixturePeer(), b = FixturePeer()
    a.service = FileTransferService(session: sa, report: a.report); b.service = FileTransferService(session: sb, report: b.report)
    a.service.start(); b.service.start()
    waitFixture("folder listeners") { a.value { $0.idle } > 0 && b.value { $0.idle } > 0 }
    return (a, b)
  }
  let source = folder.appendingPathComponent("source")
  try folderServiceSource(source, files: 3, size: 150001)
  let expected = try folderServiceTree(source)
  do {
    let (a, b) = pair(); defer { a.service.stop(); b.service.stop() }
    for (direction, (sender, receiver)) in [(a, b), (b, a)].enumerated() {
      let target = folder.appendingPathComponent("received-\(direction)"); receiver.destination(target)
      let sent = sender.value { $0.completed }, got = receiver.value { $0.completed }
      sender.service.sendURL(source)
      waitFixture("folder direction \(direction)") { sender.value { $0.completed } == sent + 1 && receiver.value { $0.completed } == got + 1 }
      let tree = try folderServiceTree(target); precondition(tree == expected, "folder bytes")
      precondition(!FileManager.default.fileExists(atPath: target.path + ".partial") && !FileManager.default.fileExists(atPath: target.path + ".partial.journal"))
      print("PASS folder service direction \(direction): exact tree, empty and hidden entries, quarantine, no sidecars")
    }
  }
  // Stop mid-way, try from a different peer identity, then resume with fresh keys and input IDs.
  let big = folder.appendingPathComponent("big"); try folderServiceSource(big, files: 30, size: 2_000_000)
  let bigExpected = try folderServiceTree(big)
  let target = folder.appendingPathComponent("resume-target")
  do {
    let (a, b) = pair(); defer { a.service.stop(); b.service.stop() }
    b.destination(target); a.service.sendURL(big)
    waitFixture("partial progress") { (b.value { $0.folder?.doneFiles ?? 0 }) >= 3 }
    a.service.cancel()
    waitFixture("stop both") { a.value { $0.terminal } > 0 && b.value { $0.terminal } > 0 }
    precondition(a.value { $0.completed } == 0 && a.lock.withLock { a.lastFailure.contains("same location") }, "stop explains resume: " + a.lastFailure)
    precondition(FileManager.default.fileExists(atPath: target.path + ".partial.journal"))
  }
  do {
    let (a, b) = pair(deviceC); defer { a.service.stop(); b.service.stop() }
    b.destination(target); a.service.sendURL(big)
    waitFixture("different peer rejected") { a.value { $0.terminal } > 0 }
    precondition(a.value { $0.completed } == 0 && !FileManager.default.fileExists(atPath: target.path))
  }
  do {
    let (a, b) = pair(); defer { a.service.stop(); b.service.stop() }
    b.destination(target); a.service.sendURL(big)
    waitFixture("resumed") { a.value { $0.completed } == 1 && b.value { $0.completed } == 1 }
    let skipped = a.value { $0.maxSkipped }
    precondition(skipped >= 3 && skipped < 30, "skipped \(skipped)")
    let tree = try folderServiceTree(target); precondition(tree == bigExpected)
    print("PASS folder service stop keeps \(skipped) completed files, different peer rejected, resume with new session keys")
  }
  do {
    let (a, b) = pair(); defer { a.service.stop(); b.service.stop() }
    b.destination(nil, hold: true); a.service.sendURL(source)
    waitFixture("folder approval pending") { b.value { $0.incoming } > 0 }
    let c = FixturePeer(); var sc = aSession!
    sc.localPort = freeFixturePort(); sc.peerPort = bPort
    c.service = FileTransferService(session: sc, report: c.report)
    c.service.sendURL(source)
    waitFixture("folder busy") { c.value { $0.terminal } > 0 }
    precondition(c.lock.withLock { c.lastFailure.contains("busy") }, "busy reported: " + c.lastFailure)
    c.service.stop()
    a.service.cancel()
    waitFixture("pending folder cancel") { a.value { $0.terminal } > 0 && b.value { $0.terminal } > 0 }
  }
  do {
    let old = FixturePeer()
    var s = FileSession(root: SymmetricKey(size: .bits256), inputIDs: "old", localIP: "127.0.0.1", interfaceIndex: if_nametoindex("lo0"), peerIP: "127.0.0.1", cancelled: { false }, onCancel: { _ in })
    s.localPort = freeFixturePort(); s.peerPort = freeFixturePort()
    old.service = FileTransferService(session: s, report: old.report); old.service.sendURL(source)
    waitFixture("old peer folder") { old.value { $0.terminal } > 0 }
    precondition(old.lock.withLock { old.lastFailure.contains("0.9.10") }, old.lastFailure); old.service.stop()
  }
  print("PASS folder service approval cancel and 0.9.10 requirement for older peers")
}
