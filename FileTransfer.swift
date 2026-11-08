import Foundation
import CryptoKit
import Darwin
import Security

struct FileSession {
  let root: SymmetricKey
  let inputIDs: String
  let localIP: String
  let interfaceIndex: UInt32
  let peerIP: String
  let cancelled: () -> Bool
  let onCancel: (@escaping () -> Void) -> Void
  /// Authenticated stable device IDs from the confirmed pairing. Folder resume is bound to these,
  /// never to the per-connection inputIDs or root key.
  var localDeviceID: UUID? = nil
  var peerDeviceID: UUID? = nil
  /// Peer advertised folderTransferCodec 1 in its authenticated hello.
  var folderTransferSupported = false
  var folderIdentity: FolderPeerIdentity? {
    guard folderTransferSupported, let localDeviceID, let peerDeviceID, localDeviceID != peerDeviceID else { return nil }
    return FolderPeerIdentity(local: localDeviceID, peer: peerDeviceID)
  }
  #if FILE_TRANSFER_SELF_TEST
  var localPort: UInt16 = 49179
  var peerPort: UInt16 = 49179
  #endif
  static func purposeRoot(_ root: SymmetricKey, local: String, peer: String) -> SymmetricKey {
    HKDF<SHA256>.deriveKey(inputKeyMaterial: root, salt: Data([local, peer].sorted().joined(separator: "|").utf8), info: Data("ThunderControl.file.root.v1".utf8), outputByteCount: 32)
  }
}
/// One file or one folder. The UI remaps `id` to a local approval ID.
enum TransferItem: Equatable {
  case file(FileOffer), folder(FolderOffer)
  var id: UUID { switch self { case .file(let o): return o.id; case .folder(let o): return o.id } }
  var name: String { switch self { case .file(let o): return o.name; case .folder(let o): return o.name } }
  var byteCount: UInt64 { switch self { case .file(let o): return o.byteCount; case .folder(let o): return o.totalBytes } }
  func withID(_ id: UUID) -> TransferItem {
    switch self {
    case .file(let o): return .file(FileOffer(id: id, name: o.name, byteCount: o.byteCount))
    case .folder(let o): return .folder(FolderOffer(id: id, name: o.name, totalBytes: o.totalBytes, fileCount: o.fileCount, entryCount: o.entryCount, manifestBytes: o.manifestBytes, digest: o.digest))
    }
  }
}
enum FileTransferState {
  case unavailable(String), idle, preparing, awaitingPeer(TransferItem), incomingOffer(TransferItem)
  case transferring(FileOffer, UInt64), folderProgress(FolderOffer, FolderProgress), verifying(FileOffer), completed(TransferItem), failed(String), cancelled
}

final class FileSocket {
  let fd: Int32
  init(_ fd: Int32) { self.fd = fd }
  func interrupt() { _ = shutdown(fd, SHUT_RDWR) }
  deinit { close(fd) }
}
final class FileRun {
  private let lock = NSLock()
  private var stopped = false
  private var sockets: [FileSocket] = []
  private var decision: URL?
  private var decided = false
  let wake = DispatchSemaphore(value: 0)
  func add(_ socket: FileSocket) throws {
    lock.lock(); defer { lock.unlock() }
    guard !stopped else { throw FileTransferError.cancelled }; sockets.append(socket)
  }
  func check() throws { lock.lock(); defer { lock.unlock() }; if stopped { throw FileTransferError.cancelled } }
  func cancel() {
    lock.lock(); stopped = true; let current = sockets; sockets.removeAll(); lock.unlock()
    for socket in current { socket.interrupt() }; wake.signal()
  }
  func choose(_ url: URL?) { lock.lock(); if !decided && !stopped { decision = url; decided = true }; lock.unlock(); wake.signal() }
  func choice() throws -> URL? { try check(); lock.lock(); defer { lock.unlock() }; return decision }
  // Admission immediately before rename is the boundary. An admitted commit may finish after cancellation.
  func admitCommit() throws { lock.lock(); defer { lock.unlock() }; guard !stopped else { throw FileTransferError.cancelled } }
}

private func fileAddress(_ ip: String, _ port: UInt16) throws -> sockaddr_in {
  var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian
  guard inet_pton(AF_INET, ip, &address.sin_addr) == 1 else { throw FileTransferError.invalid }; return address
}
private func fileSocket(_ session: FileSession, run: FileRun) throws -> FileSocket {
  let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { throw FileTransferError.io }
  let owned = FileSocket(fd); try run.add(owned)
  var one: Int32 = 1; var index = session.interfaceIndex; var timeout = timeval(tv_sec: 15, tv_usec: 0)
  guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, 4) == 0,
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
    setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, 4) == 0 else { throw FileTransferError.io }
  _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
  return owned
}
private func fileWrite(_ fd: Int32, _ data: Data) throws {
  try data.withUnsafeBytes { raw in
    var offset = 0
    while offset < raw.count { let n = send(fd, raw.baseAddress!.advanced(by: offset), raw.count-offset, 0); if n < 0 && errno == EINTR { continue }; guard n > 0 else { throw FileTransferError.io }; offset += n }
  }
}
private func fileRead(_ fd: Int32, _ count: Int) throws -> Data {
  var data = Data(count: count)
  try data.withUnsafeMutableBytes { raw in
    var offset = 0
    while offset < count { let n = recv(fd, raw.baseAddress!.advanced(by: offset), count-offset, 0); if n < 0 && errno == EINTR { continue }; guard n > 0 else { throw FileTransferError.io }; offset += n }
  }; return data
}
private func fileSendFrame(_ fd: Int32, _ data: Data) throws {
  guard data.count <= 100000 else { throw FileTransferError.invalid }; var size = UInt32(data.count).bigEndian
  try fileWrite(fd, withUnsafeBytes(of: &size) { Data($0) }); try fileWrite(fd, data)
}
private func fileReadFrame(_ fd: Int32) throws -> Data {
  let header = try fileRead(fd, 4); let size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
  guard size > 0, size <= 100000 else { throw FileTransferError.invalid }; return try fileRead(fd, Int(size))
}
private struct FilePacket: Codable {
  let kind: String
  var offer: FileOffer? = nil
  var offset: UInt64? = nil
  var bytes: Data? = nil
  /// Typed folder message, encoded once inside the unchanged authenticated packet. Absent in file v1.
  var folder: FolderMessage? = nil
  func validate() throws {
    switch kind {
    case "proof", "accept", "busy", "decline":
      guard offer == nil, offset == nil, bytes == nil, folder == nil else { throw FileTransferError.invalid }
    case "offer":
      guard let offer, offset == nil, bytes == nil, folder == nil else { throw FileTransferError.invalid }; try offer.validate()
    case "chunk":
      guard offer == nil, offset != nil, let bytes, !bytes.isEmpty, bytes.count <= 65536, folder == nil else { throw FileTransferError.invalid }
    case "finish", "success":
      guard offer == nil, offset != nil, bytes?.count == 32, folder == nil else { throw FileTransferError.invalid }
    case "folder":
      guard let folder, offer == nil, offset == nil, bytes == nil else { throw FileTransferError.invalid }; try folder.validate()
    default: throw FileTransferError.invalid
    }
  }
}
private final class FileChannel {
  let socket: FileSocket
  let session: FileSession
  let run: FileRun
  private let outgoing: SymmetricKey
  private let incoming: SymmetricKey
  private var sent: UInt64 = 0
  private var received: UInt64 = 0
  private let outgoingRole: UInt32
  private let incomingRole: UInt32
  init(socket: FileSocket, session: FileSession, run: FileRun, initiator: Bool) throws {
    self.socket = socket; self.session = session; self.run = run
    var nonce = Data(count: 32)
    guard nonce.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }) == errSecSuccess else { throw FileTransferError.io }
    try fileSendFrame(socket.fd, nonce); let peer = try fileReadFrame(socket.fd)
    guard peer.count == 32 else { throw FileTransferError.invalid }
    var salt = Data(session.inputIDs.utf8); salt.append(initiator ? nonce : peer); salt.append(initiator ? peer : nonce)
    let forward = HKDF<SHA256>.deriveKey(inputKeyMaterial: session.root, salt: salt, info: Data("ThunderControl.file.initiator.v1".utf8), outputByteCount: 32)
    let reverse = HKDF<SHA256>.deriveKey(inputKeyMaterial: session.root, salt: salt, info: Data("ThunderControl.file.acceptor.v1".utf8), outputByteCount: 32)
    outgoing = initiator ? forward : reverse; incoming = initiator ? reverse : forward
    outgoingRole = initiator ? 1 : 2; incomingRole = initiator ? 2 : 1
    try send(FilePacket(kind: "proof")); guard try receive().kind == "proof" else { throw FileTransferError.authentication }
  }
  private func nonce(_ role: UInt32, _ sequence: UInt64) throws -> AES.GCM.Nonce {
    var r = role.bigEndian; var s = sequence.bigEndian; var data = withUnsafeBytes(of: &r) { Data($0) }; data.append(withUnsafeBytes(of: &s) { Data($0) }); return try AES.GCM.Nonce(data: data)
  }
  func check() throws { try run.check(); guard !session.cancelled() else { throw FileTransferError.cancelled } }
  func send(_ packet: FilePacket) throws {
    try packet.validate(); try check(); guard sent < UInt64.max else { throw FileTransferError.invalid }
    let n = try nonce(outgoingRole, sent); let aad = Data("ThunderControl.file.v1|\(outgoingRole)|\(sent)".utf8)
    let box = try AES.GCM.seal(JSONEncoder().encode(packet), using: outgoing, nonce: n, authenticating: aad)
    try fileSendFrame(socket.fd, box.ciphertext + box.tag); sent += 1
  }
  func receive() throws -> FilePacket {
    try check(); guard received < UInt64.max else { throw FileTransferError.invalid }; let data = try fileReadFrame(socket.fd)
    guard data.count >= 16 else { throw FileTransferError.invalid }
    let n = try nonce(incomingRole, received); let aad = Data("ThunderControl.file.v1|\(incomingRole)|\(received)".utf8)
    let box = try AES.GCM.SealedBox(nonce: n, ciphertext: data.dropLast(16), tag: data.suffix(16))
    let plain = try AES.GCM.open(box, using: incoming, authenticating: aad); received += 1
    guard plain.count <= 100000 else { throw FileTransferError.invalid }; let packet = try JSONDecoder().decode(FilePacket.self, from: plain); try packet.validate(); return packet
  }
}

/// Folder messages over the existing authenticated file channel; keys stay private to FileChannel.
private final class FileFolderChannel: FolderChannel {
  private let channel: FileChannel
  init(_ channel: FileChannel) { self.channel = channel }
  func send(_ message: FolderMessage) throws { try channel.send(FilePacket(kind: "folder", folder: message)) }
  func receive() throws -> FolderMessage {
    let packet = try channel.receive()
    if packet.kind == "busy" { throw FileTransferError.busy }
    guard packet.kind == "folder", let message = packet.folder else { throw FileTransferError.invalid }
    return message
  }
}

final class FileTransferService {
  private let lock = NSLock()
  private var active: FileRun?
  private var handshake: FileRun?
  private let listenerRun = FileRun()
  private let session: FileSession
  private let report: (FileTransferState) -> Void
  private var stopped = false
  private var localPort: UInt16 = 49179
  private var peerPort: UInt16 = 49179
  #if FILE_TRANSFER_SELF_TEST
  convenience init(session: FileSession, localPort: UInt16, peerPort: UInt16, report: @escaping (FileTransferState) -> Void) {
    self.init(session: session, report: report); self.localPort = localPort; self.peerPort = peerPort
  }
  #endif
  init(session: FileSession, report: @escaping (FileTransferState) -> Void) {
    self.session = session; self.report = report
    #if FILE_TRANSFER_SELF_TEST
    localPort = session.localPort; peerPort = session.peerPort
    #endif
    session.onCancel { [weak self] in self?.stop() }
  }
  func stop() { lock.lock(); stopped = true; let current = active; let pending = handshake; lock.unlock(); listenerRun.cancel(); current?.cancel(); pending?.cancel() }
  func cancel() { lock.lock(); let current = active; lock.unlock(); current?.cancel() }
  func choose(_ url: URL?) { lock.lock(); let current = active; lock.unlock(); current?.choose(url) }
  private func reserve(_ run: FileRun) -> Bool { lock.lock(); defer { lock.unlock() }; guard !stopped, active == nil else { return false }; active = run; return true }
  private func release(_ run: FileRun) { lock.lock(); if active === run { active = nil }; lock.unlock() }
  func start() {
    DispatchQueue.global(qos: .utility).async { [self] in
      do {
        let listener = try fileSocket(session, run: listenerRun)
        var reuse: Int32 = 1; _ = setsockopt(listener.fd, SOL_SOCKET, SO_REUSEADDR, &reuse, 4)
        var address = try fileAddress(session.localIP, localPort)
        var bound = false
        for _ in 0..<20 {
          try listenerRun.check(); guard !session.cancelled() else { throw FileTransferError.cancelled }
          if withUnsafePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener.fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }) == 0 { bound = true; break }
          guard errno == EADDRINUSE else { throw FileTransferError.io }; usleep(50000)
        }
        guard bound, listen(listener.fd, 2) == 0, fcntl(listener.fd, F_SETFL, O_NONBLOCK) == 0 else { throw FileTransferError.io }
        defer { listenerRun.cancel() }
        lock.lock(); if active == nil && !stopped { report(.idle) }; lock.unlock()
        while !session.cancelled() {
          try listenerRun.check()
          var waiting = pollfd(fd: listener.fd, events: Int16(POLLIN), revents: 0)
          let polled = poll(&waiting, 1, 100)
          if polled == 0 || (polled < 0 && errno == EINTR) { continue }
          try listenerRun.check(); guard polled > 0 else { throw FileTransferError.io }
          var remote = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size)
          let fd = withUnsafeMutablePointer(to: &remote) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listener.fd, $0, &length) } }
          if fd < 0 { if errno == EINTR || errno == EAGAIN { continue }; throw FileTransferError.io }
          let accepted = FileSocket(fd)
          guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0, fcntl(fd, F_SETFL, 0) == 0 else { continue }
          let expected = try fileAddress(session.peerIP, 0)
          guard remote.sin_addr.s_addr == expected.sin_addr.s_addr else { continue }
          // One accept worker at a time bounds unauthenticated resource use and handshake duration.
          let run = FileRun(); try run.add(accepted)
          var timeout = timeval(tv_sec: 15, tv_usec: 0); var one: Int32 = 1; var index = session.interfaceIndex
          _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)); _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)); _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, 4)
          guard setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, 4) == 0 else { continue }
          lock.lock(); handshake = run; let cancelled = stopped; lock.unlock()
          if cancelled { run.cancel(); return }
          defer { lock.lock(); if handshake === run { handshake = nil }; lock.unlock() }
          do {
            let channel = try FileChannel(socket: accepted, session: session, run: run, initiator: false)
            let packet = try channel.receive()
            if packet.kind == "folder", case .offer(let offer)? = packet.folder {
              guard let identity = session.folderIdentity else { throw FileTransferError.invalid }
              guard reserve(run) else { try channel.send(FilePacket(kind: "busy")); continue }
              defer { release(run) }
              do { try receiveFolder(channel, offer: offer, identity: identity) } catch { reportFailure(error, folder: true); throw error }
              continue
            }
            guard packet.kind == "offer", let offer = packet.offer else { throw FileTransferError.invalid }; try offer.validate()
            guard reserve(run) else { try channel.send(FilePacket(kind: "busy")); continue }
            defer { release(run) }
            do { try receive(channel, offer: offer) } catch { reportFailure(error); throw error }
          } catch { run.cancel() }
        }
      } catch { if !session.cancelled() { report(.unavailable("File connection unavailable.")) } }
    }
  }
  func sendURL(_ url: URL) {
    let run = FileRun(); guard reserve(run) else { return }; report(.preparing)
    var info = stat()
    let isFolder = lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    DispatchQueue.global(qos: .utility).async { [self] in
      defer { release(run) }
      do {
        try run.check()
        if isFolder { try sendFolder(url, run: run); return }
        if (info.st_mode & S_IFMT) == S_IFREG, UInt64(max(0, info.st_size)) > FileOffer.maximum { throw FolderTransferError.fileTooLarge(url.lastPathComponent) }
        let source = try FileSource(url); let channel = try openChannel(run)
        report(.awaitingPeer(.file(source.offer))); try channel.send(FilePacket(kind: "offer", offer: source.offer))
        var approvalTimeout = timeval(tv_sec: 130, tv_usec: 0); _ = setsockopt(channel.socket.fd, SOL_SOCKET, SO_RCVTIMEO, &approvalTimeout, socklen_t(MemoryLayout<timeval>.size))
        let response = try channel.receive(); approvalTimeout.tv_sec = 15; _ = setsockopt(channel.socket.fd, SOL_SOCKET, SO_RCVTIMEO, &approvalTimeout, socklen_t(MemoryLayout<timeval>.size)); guard response.kind == "accept" else { throw response.kind == "busy" ? FileTransferError.busy : FileTransferError.declined }
        try streamFile(source, over: channel)
      } catch { run.cancel(); reportFailure(error, folder: isFolder) }
    }
  }
  private func sendFolder(_ url: URL, run: FileRun) throws {
    guard session.folderIdentity != nil else { throw FolderTransferError.peerUnsupported }
    let plan = try FolderSourcePlan.capture(url, check: { try run.check() })
    let channel = try openChannel(run)
    report(.awaitingPeer(.folder(plan.offer)))
    let offer = plan.offer, report = self.report
    let outcome = try FolderTransferEngine.send(plan, over: FileFolderChannel(channel), check: { try channel.check() }, report: { report(.folderProgress(offer, $0)) })
    report(outcome == .declined ? .failed(TCText("The receiving Mac declined the folder.")) : .completed(.folder(offer)))
  }
  private func receiveFolder(_ channel: FileChannel, offer: FolderOffer, identity: FolderPeerIdentity) throws {
    try offer.validate()
    report(.incomingOffer(.folder(offer)))
    let run = channel.run, report = self.report
    let outcome = try FolderTransferEngine.receive(offer, over: FileFolderChannel(channel), identity: identity, choose: { check in
      let deadline = ProcessInfo.processInfo.systemUptime + 120
      while run.wake.wait(timeout: .now() + 0.1) != .success {
        try check(); guard ProcessInfo.processInfo.systemUptime < deadline else { throw FileTransferError.declined }
      }
      return try run.choice()
    }, check: { try channel.check() }, report: { report(.folderProgress(offer, $0)) })
    report(outcome == .declined ? .idle : .completed(.folder(offer)))
  }
  private func openChannel(_ run: FileRun) throws -> FileChannel {
        let socket = try fileSocket(session, run: run)
        var local = try fileAddress(session.localIP, 0)
        guard withUnsafePointer(to: &local, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket.fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }) == 0 else { throw FileTransferError.io }
        var remote = try fileAddress(session.peerIP, peerPort)
        let flags = fcntl(socket.fd, F_GETFL); guard flags >= 0, fcntl(socket.fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw FileTransferError.io }
        let connected = withUnsafePointer(to: &remote) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socket.fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if connected != 0 {
          guard errno == EINPROGRESS else { throw FileTransferError.io }
          let deadline = ProcessInfo.processInfo.systemUptime + 15
          while true {
            try run.check(); guard !session.cancelled() else { throw FileTransferError.cancelled }
            var p = pollfd(fd: socket.fd, events: Int16(POLLOUT), revents: 0)
            let result = poll(&p, 1, 100)
            if result > 0 { break }
            guard (result == 0 || errno == EINTR), ProcessInfo.processInfo.systemUptime < deadline else { throw FileTransferError.io }
          }
          var error: Int32 = 0; var size: socklen_t = 4; guard getsockopt(socket.fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { throw FileTransferError.io } }
        guard fcntl(socket.fd, F_SETFL, flags) == 0 else { throw FileTransferError.io }
        return try FileChannel(socket: socket, session: session, run: run, initiator: true)
  }
  private func streamFile(_ source: FileSource, over channel: FileChannel) throws {
        var hash = SHA256(); var offset: UInt64 = 0; var last = 0.0
        while true {
          try channel.check(); let chunk = try source.chunk(); if chunk.isEmpty { break }
          guard UInt64(chunk.count) <= source.offer.byteCount - offset else { throw FileTransferError.changed }
          try channel.send(FilePacket(kind: "chunk", offset: offset, bytes: chunk)); hash.update(data: chunk); offset += UInt64(chunk.count)
          let now = ProcessInfo.processInfo.systemUptime; if now-last >= 0.1 { report(.transferring(source.offer, offset)); last = now }
        }
        try source.verifyUnchanged(); guard offset == source.offer.byteCount else { throw FileTransferError.changed }
        let digest = Data(hash.finalize())
        report(.verifying(source.offer)); try channel.send(FilePacket(kind: "finish", offset: offset, bytes: digest))
        do { let response = try channel.receive(); guard response.kind == "success", response.offset == offset, response.bytes == digest else { throw FileTransferError.unconfirmed } } catch { throw FileTransferError.unconfirmed }
        report(.completed(.file(source.offer)))
  }
  private func receive(_ channel: FileChannel, offer: FileOffer) throws {
    report(.incomingOffer(.file(offer)))
    let approvalDeadline = ProcessInfo.processInfo.systemUptime + 120
    while channel.run.wake.wait(timeout: .now() + 0.1) != .success {
      try channel.check()
      guard ProcessInfo.processInfo.systemUptime < approvalDeadline else { throw FileTransferError.declined }
      var pending = pollfd(fd: channel.socket.fd, events: Int16(POLLIN), revents: 0)
      if poll(&pending, 1, 0) > 0 {
        var byte: UInt8 = 0
        let count = recv(channel.socket.fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        if count == 0 { throw FileTransferError.cancelled }
        if count > 0 || (count < 0 && errno != EAGAIN && errno != EINTR) { throw FileTransferError.invalid }
      }
    }
    guard let url = try channel.run.choice() else { try channel.send(FilePacket(kind: "decline")); report(.idle); return }
    try channel.check(); let destination = try FileDestination(url, bytes: offer.byteCount)
    try channel.send(FilePacket(kind: "accept"))
    var hash = SHA256(); var offset: UInt64 = 0; var last = 0.0
    while true {
      let packet = try channel.receive(); try channel.check()
      if packet.kind == "finish" {
        guard packet.offset == offset, offset == offer.byteCount, packet.bytes == Data(hash.finalize()) else { throw FileTransferError.authentication }
        report(.verifying(offer)); try destination.commit { try channel.check(); try channel.run.admitCommit() }
        report(.completed(.file(offer))); try? channel.send(FilePacket(kind: "success", offset: offset, bytes: packet.bytes)); return
      }
      guard packet.kind == "chunk", packet.offset == offset, let bytes = packet.bytes, !bytes.isEmpty, bytes.count <= 65536, UInt64(bytes.count) <= offer.byteCount-offset else { throw FileTransferError.invalid }
      try destination.write(bytes); hash.update(data: bytes); offset += UInt64(bytes.count)
      let now = ProcessInfo.processInfo.systemUptime; if now-last >= 0.1 { report(.transferring(offer, offset)); last = now }
    }
  }
  private func reportFailure(_ error: Error, folder: Bool = false) { report(Self.failureState(error, folder: folder)) }
  /// User-facing, localized failure text. Folder stops keep completed files for resume.
  static func failureState(_ error: Error, folder: Bool) -> FileTransferState {
    let resume = "Completed files were kept. To resume, send the same unchanged folder again and choose the same location and name on the receiving Mac."
    let rename = "Choose a different name on the receiving Mac. Nothing was replaced."
    func text(_ key: String, _ values: String...) -> FileTransferState { .failed(TCLocalization.localized(key, values: values)) }
    switch error {
    case FileTransferError.cancelled: return folder ? text("Folder transfer stopped. " + resume) : .cancelled
    case FileTransferError.unconfirmed, FolderTransferError.unconfirmed: return text("Delivery unconfirmed. Check the receiving Mac before sending again.")
    case FileTransferError.busy where folder: return text("The other Mac is busy with another transfer. Try again later.")
    case FolderTransferError.peerUnsupported: return text("Folder transfer requires ThunderControl 0.9.10 or later on both Macs.")
    case FolderTransferError.unsupportedEntry(let path): return text("Cannot send “{0}”. Folders can contain only regular files and folders, not links or special files.", path)
    case FolderTransferError.invalidName(let path): return text("Cannot send “{0}”. This name is not supported.", path)
    case FolderTransferError.fileTooLarge(let path): return text("Cannot send “{0}”. Each file can be at most 64 GiB.", path)
    case FolderTransferError.tooManyEntries: return text("Folders can contain at most 100,000 items.")
    case FolderTransferError.manifestTooLarge, FolderTransferError.totalTooLarge: return text("This folder's file list is too large to send.")
    case FolderTransferError.sourceChanged: return text("The folder changed while sending. " + resume)
    case FolderTransferError.destinationExists, FolderTransferError.peerFailed(.exists): return text("An item with that name already exists. " + rename)
    case FolderTransferError.resumeMismatch, FolderTransferError.peerFailed(.resumeMismatch): return text("The partial folder belongs to a different transfer or Mac. " + rename)
    case FolderTransferError.conflict, FolderTransferError.peerFailed(.conflict): return text("A partially received item was changed on the receiving Mac. " + rename)
    case FolderTransferError.insufficientSpace, FolderTransferError.peerFailed(.space): return text("Not enough free space on the receiving Mac.")
    default: return folder ? text("Folder transfer failed. " + resume) : text("File transfer failed or was declined. No existing destination was replaced.")
    }
  }
}

@MainActor final class FileTransferCoordinator {
  private var service: FileTransferService?
  private var configuredSession: FileSession?
  private var safetyAllowed = true
  private var generation = UUID()
  private var offerID: UUID?
  var onChange: ((FileTransferState) -> Void)?
  private(set) var state: FileTransferState = .unavailable("Connect both Macs with file transfer support.")
  var sessionToken: UUID { generation }
  private func publish(_ value: FileTransferState) {
    if case .incomingOffer(let item) = value {
      let local = item.withID(UUID())
      offerID = local.id; state = .incomingOffer(local)
    } else { offerID = nil; state = value }
    onChange?(state)
  }
  func configure(_ session: FileSession?) {
    configuredSession = session
    restart()
  }
  private func restart() {
    service?.stop(); service = nil; generation = UUID()
    guard safetyAllowed, let session = configuredSession, !session.cancelled() else { publish(.unavailable("Connect both Macs with file transfer support.")); return }
    let token = generation
    let worker = FileTransferService(session: session) { [weak self] state in DispatchQueue.main.async { guard let self, self.generation == token else { return }; self.publish(state) } }
    service = worker; worker.start()
  }
  func pollSafety(_ allowed: Bool) { guard allowed != safetyAllowed else { return }; safetyAllowed = allowed; restart() }
  func sendURL(_ url: URL) { service?.sendURL(url) }
  func acceptURL(_ url: URL, for id: UUID) { guard offerID == id else { return }; service?.choose(url) }
  func reject() { service?.choose(nil) }
  func cancel() { service?.cancel() }
}

#if FILE_TRANSFER_SELF_TEST
func runFileTransferChannelFixture(_ payload: Data, wrongRoot: Bool = false) throws {
  let listenerFD = socket(AF_INET, SOCK_STREAM, 0); guard listenerFD >= 0 else { throw FileTransferError.io }
  let listener = FileSocket(listenerFD)
  var endpoint = try fileAddress("127.0.0.1", 0)
  guard withUnsafePointer(to: &endpoint, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener.fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }) == 0, listen(listener.fd, 1) == 0 else { throw FileTransferError.io }
  var length = socklen_t(MemoryLayout<sockaddr_in>.size)
  guard withUnsafeMutablePointer(to: &endpoint, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener.fd, $0, &length) } }) == 0 else { throw FileTransferError.io }
  let root = SymmetricKey(size: .bits256)
  let done = DispatchSemaphore(value: 0)
  final class ResultBox { let lock = NSLock(); var passed = false; func set(_ value: Bool) { lock.lock(); passed = value; lock.unlock() }; func get() -> Bool { lock.lock(); defer { lock.unlock() }; return passed } }
  let result = ResultBox()
  DispatchQueue.global().async {
    defer { done.signal() }
    do {
      let acceptedFD = accept(listener.fd, nil, nil); guard acceptedFD >= 0 else { throw FileTransferError.io }
      let socket = FileSocket(acceptedFD); let run = FileRun(); try run.add(socket)
      var timeout = timeval(tv_sec: 3, tv_usec: 0); _ = setsockopt(socket.fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)); var one: Int32 = 1; _ = setsockopt(socket.fd, SOL_SOCKET, SO_NOSIGPIPE, &one, 4)
      let session = FileSession(root: wrongRoot ? SymmetricKey(size: .bits256) : root, inputIDs: "fixture-session", localIP: "127.0.0.1", interfaceIndex: 0, peerIP: "127.0.0.1", cancelled: { false }, onCancel: { _ in })
      let channel = try FileChannel(socket: socket, session: session, run: run, initiator: false)
      var received = Data(); var offset: UInt64 = 0
      while true {
        let packet = try channel.receive()
        if packet.kind == "finish" { guard received == payload else { throw FileTransferError.invalid }; try channel.send(FilePacket(kind: "success", offset: offset, bytes: Data(SHA256.hash(data: received)))); result.set(true); break }
        guard packet.kind == "chunk", packet.offset == offset, let bytes = packet.bytes else { throw FileTransferError.invalid }; received.append(bytes); offset += UInt64(bytes.count)
      }
    } catch { result.set(wrongRoot) }
  }
  let clientFD = socket(AF_INET, SOCK_STREAM, 0); guard clientFD >= 0 else { throw FileTransferError.io }
  let client = FileSocket(clientFD); let run = FileRun(); try run.add(client)
  var timeout = timeval(tv_sec: 3, tv_usec: 0); _ = setsockopt(client.fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)); var one: Int32 = 1; _ = setsockopt(client.fd, SOL_SOCKET, SO_NOSIGPIPE, &one, 4)
  guard withUnsafePointer(to: &endpoint, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client.fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }) == 0 else { throw FileTransferError.io }
  let session = FileSession(root: root, inputIDs: "fixture-session", localIP: "127.0.0.1", interfaceIndex: 0, peerIP: "127.0.0.1", cancelled: { false }, onCancel: { _ in })
  do {
    let channel = try FileChannel(socket: client, session: session, run: run, initiator: true)
    var offset = 0
    while offset < payload.count { let end = min(payload.count, offset + 65536); try channel.send(FilePacket(kind: "chunk", offset: UInt64(offset), bytes: payload.subdata(in: offset..<end))); offset = end }
    try channel.send(FilePacket(kind: "finish", offset: UInt64(payload.count), bytes: Data(SHA256.hash(data: payload)))); let response = try channel.receive(); guard response.kind == "success", response.bytes == Data(SHA256.hash(data: payload)), !wrongRoot else { throw FileTransferError.invalid }
  } catch { if !wrongRoot { throw error } }
  guard done.wait(timeout: .now() + 5) == .success, result.get() else { throw FileTransferError.invalid }
}
func runFileTransferGuardFixtures() throws {
  for packet in [FilePacket(kind: "proof", offset: 0), FilePacket(kind: "offer"), FilePacket(kind: "accept", bytes: Data()), FilePacket(kind: "busy", offer: FileOffer(id: UUID(), name: "x", byteCount: 0)), FilePacket(kind: "decline", offset: 1), FilePacket(kind: "chunk", offset: 0, bytes: Data()), FilePacket(kind: "chunk", offset: 0, bytes: Data(count: 65537)), FilePacket(kind: "finish", offset: 0, bytes: Data(count: 31)), FilePacket(kind: "success"), FilePacket(kind: "unknown")] {
    do { try packet.validate(); throw FileTransferError.authentication } catch FileTransferError.invalid {}
  }
  for packet in [FilePacket(kind: "folder"), FilePacket(kind: "folder", offset: 0, folder: .accept), FilePacket(kind: "folder", bytes: Data([1]), folder: .accept),
                 FilePacket(kind: "accept", folder: .accept), FilePacket(kind: "chunk", offset: 0, bytes: Data([1]), folder: .closed), FilePacket(kind: "folder", folder: .data(Data()))] {
    do { try packet.validate(); throw FileTransferError.authentication } catch FileTransferError.invalid {}
  }
  // File v1 bytes unchanged: no folder key; the largest folder data packet stays under the unchanged frame cap.
  guard String(data: try JSONEncoder().encode(FilePacket(kind: "accept")), encoding: .utf8) == #"{"kind":"accept"}"#,
    try JSONEncoder().encode(FilePacket(kind: "folder", folder: .data(Data(count: 65536)))).count + 16 <= 100000 else { throw FileTransferError.invalid }
  var pair: [Int32] = [0, 0]
  guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw FileTransferError.io }
  let sender = FileSocket(pair[0]), receiver = FileSocket(pair[1]); let run = FileRun(); try run.add(sender)
  var one: Int32 = 1; _ = setsockopt(sender.fd, SOL_SOCKET, SO_NOSIGPIPE, &one, 4)
  let done = DispatchSemaphore(value: 0)
  DispatchQueue.global().async { defer { done.signal() }; try? fileWrite(sender.fd, Data(count: 16 * 1024 * 1024)) }
  usleep(100000); run.cancel(); run.cancel()
  guard done.wait(timeout: .now() + 1) == .success else { throw FileTransferError.invalid }
  withExtendedLifetime(receiver) {}
  print("PASS strict packet shapes incl folder field, legacy encoding unchanged, blocked write promptly canceled")
}
#endif
