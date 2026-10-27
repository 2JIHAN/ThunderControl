import Foundation
import CryptoKit
import Darwin

// Dedicated v6 video protocol. A bounded format proposal and exact echo are
// exchanged only after trust confirmation, before streaming. No input packets,
// new enrollment, PIN, fallback interface, or plaintext format are accepted.
enum DisplayTransportError: Error { case invalid, stopped, unavailable }
struct DisplayChannelCipher {
  static let maximumPayload = 4 * 1024 * 1024
  static let maximumFrame = maximumPayload + 128
  let key: SymmetricKey
  let binding: Data
  let direction: UInt32
  private(set) var sequence: UInt64 = 0
  init(root: SymmetricKey, senderNonce: String, receiverNonce: String, senderToReceiver: Bool) {
    let domain = Data("ThunderControl/display/v6".utf8)
    binding = Data(SHA256.hash(data: domain + Data((senderNonce + receiverNonce).utf8)))
    direction = senderToReceiver ? 1 : 2
    key = HKDF<SHA256>.deriveKey(inputKeyMaterial: root, salt: binding,
      info: domain + Data(senderToReceiver ? "/sender-to-receiver".utf8 : "/receiver-to-sender".utf8), outputByteCount: 32)
  }
  private func nonce(_ seq: UInt64) throws -> AES.GCM.Nonce {
    var d = direction.bigEndian; var s = seq.bigEndian
    return try AES.GCM.Nonce(data: withUnsafeBytes(of: &d) { Data($0) } + withUnsafeBytes(of: &s) { Data($0) })
  }
  private func aad(_ seq: UInt64) -> Data {
    var d = direction.bigEndian; var s = seq.bigEndian
    return binding + withUnsafeBytes(of: &d) { Data($0) } + withUnsafeBytes(of: &s) { Data($0) }
  }
  mutating func seal(_ plain: Data) throws -> Data {
    guard !plain.isEmpty, plain.count <= Self.maximumPayload, sequence < UInt64.max else { throw DisplayTransportError.invalid }
    var seq = sequence.bigEndian
    let box = try AES.GCM.seal(plain, using: key, nonce: nonce(sequence), authenticating: aad(sequence))
    sequence += 1
    return withUnsafeBytes(of: &seq) { Data($0) } + box.ciphertext + box.tag
  }
  mutating func open(_ frame: Data) throws -> Data {
    guard frame.count >= 25, frame.count <= Self.maximumPayload + 24, sequence < UInt64.max else { throw DisplayTransportError.invalid }
    let seq = frame.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    guard seq == sequence else { throw DisplayTransportError.invalid }
    let box = try AES.GCM.SealedBox(nonce: nonce(seq), ciphertext: frame.dropFirst(8).dropLast(16), tag: frame.suffix(16))
    let result = try AES.GCM.open(box, using: key, authenticating: aad(seq))
    sequence += 1
    return result
  }
  static func validPayload(_ data: Data) -> Bool {
    guard !data.isEmpty, data.count <= maximumPayload else { return false }
    switch data.first {
    case 1: return data.count == 5 && data.dropFirst().contains(where: { $0 != 0 })
    case 6: return (try? DisplayStreamFrameHeader(data)) != nil
    case 7: return (try? DisplayCursorMetadata(data)) != nil
    case 2: return data.count >= 10 // Codec parses parameter sets and NAL bounds before decoding.
    default: return false
    }
  }
  static func validInputPayload(_ data: Data) -> Bool {
    false // v6 is video-only. Existing authenticated Relay owns ALL input.
  }
  static func allowedPayload(_ data: Data, fromSender: Bool) -> Bool {
    fromSender && validPayload(data)
  }
  static func hello(sending: Bool, nonce: String) throws -> Data {
    guard UUID(uuidString: nonce)?.uuidString == nonce else { throw DisplayTransportError.invalid }
    return Data("TDSP6".utf8) + Data([sending ? 1 : 2]) + Data(nonce.utf8)
  }
  static func parseHello(_ data: Data, expectSender: Bool) throws -> String {
    guard data.count == 42, data.prefix(5) == Data("TDSP6".utf8), data[data.startIndex + 5] == (expectSender ? 1 : 2),
      let nonce = String(data: data.suffix(36), encoding: .utf8), UUID(uuidString: nonce)?.uuidString == nonce
    else { throw DisplayTransportError.invalid }
    return nonce
  }
  static func confirmation(sending: Bool) -> Data {
    Data([3]) + Data((sending ? "ThunderControl/display/v6/source" : "ThunderControl/display/v6/viewer").utf8)
  }
}

func displayStartPermitted(sameEpoch: Bool, pending: Bool, hasRun: Bool, now: Double, deadline: Double) -> Bool {
  sameEpoch && pending && !hasRun && now.isFinite && deadline.isFinite && now < deadline
}

// Bounded counterpart of bridge(): same Thunderbolt membership and IPv4 rules,
// without a blocking readDataToEndOfFile/waitUntilExit on the UI or monitor queue.
private func displayVerifiedBridge(cancelled: () -> Bool) throws -> Bridge {
  guard !cancelled() else { throw DisplayTransportError.stopped }
  let process = Process(), pipe = Pipe()
  process.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
  process.arguments = ["bridge0"]
  process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
  let deadline = ProcessInfo.processInfo.systemUptime + 2
  try process.run()
  defer {
    if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
    try? pipe.fileHandleForReading.close()
  }
  let fd = pipe.fileHandleForReading.fileDescriptor
  let flags = fcntl(fd, F_GETFL)
  guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw DisplayTransportError.unavailable }
  var output = Data(), eof = false
  while !eof || process.isRunning {
    if eof { usleep(25_000) }
    guard !cancelled(), ProcessInfo.processInfo.systemUptime < deadline else { throw DisplayTransportError.unavailable }
    var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    let ready = poll(&p, 1, 25)
    if ready < 0 { if errno == EINTR { continue }; throw DisplayTransportError.unavailable }
    if ready > 0 {
      var buffer = [UInt8](repeating: 0, count: 4096)
      let count = Darwin.read(fd, &buffer, buffer.count)
      if count == 0 { eof = true }
      else if count > 0 {
        guard output.count + count <= 65536 else { throw DisplayTransportError.unavailable }
        output.append(contentsOf: buffer.prefix(count))
      } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { throw DisplayTransportError.unavailable }
    }
  }
  guard !cancelled(), process.terminationStatus == 0, let text = String(data: output, encoding: .utf8) else { throw DisplayTransportError.unavailable }
  var members = Set<String>(), active = false
  for line in text.components(separatedBy: .newlines) {
    let words = line.split(whereSeparator: { $0.isWhitespace })
    if words.count >= 2, words[0] == "member:" { members.insert(String(words[1])) }
    if words.count == 2, words[0] == "status:", words[1] == "active" { active = true }
  }
  try validateThunderboltMembers(members, thunderboltHardwareNames(), active: active)
  guard !cancelled(), ProcessInfo.processInfo.systemUptime < deadline else { throw DisplayTransportError.unavailable }
  var list: UnsafeMutablePointer<ifaddrs>?
  guard getifaddrs(&list) == 0 else { throw DisplayTransportError.unavailable }
  defer { freeifaddrs(list) }
  var entry = list
  while let item = entry {
    defer { entry = item.pointee.ifa_next }
    let value = item.pointee
    guard String(cString: value.ifa_name) == "bridge0", let addr = value.ifa_addr,
      Int32(addr.pointee.sa_family) == AF_INET, (value.ifa_flags & UInt32(IFF_UP)) != 0,
      (value.ifa_flags & UInt32(IFF_RUNNING)) != 0 else { continue }
    var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    var sin = UnsafeRawPointer(addr).assumingMemoryBound(to: sockaddr_in.self).pointee
    guard inet_ntop(AF_INET, &sin.sin_addr, &host, socklen_t(host.count)) != nil else { throw DisplayTransportError.unavailable }
    let ip = String(cString: host), index = if_nametoindex("bridge0")
    _ = try address(ip, 49178)
    guard index > 0, !cancelled() else { throw DisplayTransportError.unavailable }
    return Bridge(name: "bridge0", index: index, ip: ip)
  }
  throw DisplayTransportError.unavailable
}

private func displayWriteFrame(_ fd: Int32, _ data: Data) throws {
  guard !data.isEmpty, data.count <= DisplayChannelCipher.maximumFrame else { throw DisplayTransportError.invalid }
  var n = UInt32(data.count).bigEndian
  let bytes = withUnsafeBytes(of: &n) { Data($0) } + data
  let deadline = ProcessInfo.processInfo.systemUptime + 3
  try bytes.withUnsafeBytes { ptr in
    var offset = 0
    while offset < ptr.count {
      guard ProcessInfo.processInfo.systemUptime < deadline else { throw DisplayTransportError.unavailable }
      let sent = Darwin.send(fd, ptr.baseAddress!.advanced(by: offset), ptr.count - offset, 0)
      if sent < 0 && errno == EINTR { continue }
      guard sent > 0 else { throw DisplayTransportError.unavailable }
      offset += sent
    }
  }
}
private func displayReadExact(_ fd: Int32, _ count: Int, deadline: Double) throws -> Data {
  guard count > 0, count <= DisplayChannelCipher.maximumFrame else { throw DisplayTransportError.invalid }
  var data = Data(count: count)
  try data.withUnsafeMutableBytes { ptr in
    var offset = 0
    while offset < count {
      guard ProcessInfo.processInfo.systemUptime < deadline else { throw DisplayTransportError.unavailable }
      let got = Darwin.recv(fd, ptr.baseAddress!.advanced(by: offset), count - offset, 0)
      if got < 0 && errno == EINTR { continue }
      guard got > 0 else { throw DisplayTransportError.unavailable }
      offset += got
    }
  }
  return data
}
private func displayReadFrame(_ fd: Int32, maximum: Int = DisplayChannelCipher.maximumFrame) throws -> Data {
  let deadline = ProcessInfo.processInfo.systemUptime + 5
  let h = try displayReadExact(fd, 4, deadline: deadline)
  let size = h.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
  guard size > 0, size <= maximum else { throw DisplayTransportError.invalid }
  return try displayReadExact(fd, Int(size), deadline: deadline)
}
private func displaySocketIPv4(_ fd: Int32, peer: Bool) throws -> String {
  var a = sockaddr_in(); var n = socklen_t(MemoryLayout<sockaddr_in>.size)
  let r = withUnsafeMutablePointer(to: &a) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      peer ? getpeername(fd, $0, &n) : getsockname(fd, $0, &n)
    }
  }
  guard r == 0, a.sin_family == AF_INET else { throw DisplayTransportError.unavailable }
  var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
  guard inet_ntop(AF_INET, &a.sin_addr, &text, socklen_t(text.count)) != nil else { throw DisplayTransportError.unavailable }
  let ip = String(cString: text); _ = try address(ip, 49178); return ip
}
private func displayVerifySocket(_ fd: Int32, bridge b: Bridge, remote: String?) throws {
  var idx: UInt32 = 0; var size = socklen_t(MemoryLayout<UInt32>.size)
  guard getsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &idx, &size) == 0, idx == b.index,
    try displaySocketIPv4(fd, peer: false) == b.ip else { throw DisplayTransportError.unavailable }
  let actual = try displaySocketIPv4(fd, peer: true)
  guard actual != b.ip, remote == nil || actual == remote else { throw DisplayTransportError.unavailable }
}

private final class DisplayTransportRun {
  let id = UUID(), context: SessionContext, initial: OwnedSocket, bridge: Bridge, sending: Bool, remote: String?
  let state = NSLock(), txLock = NSLock()
  var socket: OwnedSocket?, outgoing: DisplayChannelCipher?
  private var sentDisplayIdentity = false // Protected by txLock.
  var latency=DisplayHeartbeatState()
  var diagnosticStream:String? // Diagnostic correlation only; not authentication or routing.
  private var diagnosticStopRecorded=false
  let diagnosticRecorder:DevelopmentDiagnostics
  var diagnosticActivationHookForTests:(()->Void)?
  func activateDiagnostics(stream:String)->Bool {
    state.lock();defer{state.unlock()}
    guard !context.cancelled,diagnosticStream==nil else{return false}
    diagnosticActivationHookForTests?()
    authenticated=true;lastRX=ProcessInfo.processInfo.systemUptime;diagnosticStream=stream
    // Only a short memory lock; no disk or cloud calls. Cancellation captures the
    // same stream under state, so it cannot return before this activation is retired.
    diagnosticRecorder.start(role:sending ? "source":"viewer",stream:stream)
    return true
  }
  var authenticated = false, authStart: Double?, lastRX = ProcessInfo.processInfo.systemUptime
  var lastBridgeProof = ProcessInfo.processInfo.systemUptime
  var timers: [DispatchSourceTimer] = []
  let expectedPair:LayoutDevicePair
  let viewerFormat:DisplayVideoFormat
  init(initial: OwnedSocket, bridge: Bridge, sending: Bool, remote: String?,expectedPair:LayoutDevicePair,viewerFormat:DisplayVideoFormat,diagnosticRecorder:DevelopmentDiagnostics = .shared) {
    self.diagnosticRecorder=diagnosticRecorder
    self.expectedPair=expectedPair;self.viewerFormat=viewerFormat
    self.initial = initial; context = SessionContext(initial); self.bridge = bridge; self.sending = sending; self.remote = remote
  }
  func cancel() {
    context.cancel(reason: "Display session stopped")
    state.lock(); let sources = timers; timers.removeAll(); let stream=diagnosticStopRecorded ? nil:diagnosticStream;diagnosticStopRecorded=true;state.unlock()
    if let stream{diagnosticRecorder.record(stage:"transport_stop",stream:stream);diagnosticRecorder.stop(stream:stream)}
    for source in sources { source.cancel() }
  }
  func timer(interval: Double, queue: DispatchQueue, action: @escaping () -> Void) {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + interval, repeating: interval)
    timer.setEventHandler(handler: action)
    state.lock(); timers.append(timer); timer.resume(); let stopped = context.cancelled; state.unlock()
    if stopped { timer.cancel() }
  }
  func transmit(_ data: Data, requireAuthentication: Bool = true) throws {
    // A synchronous video/control caller and one heartbeat are the only writers.
    // No transport-side backlog is allocated.
    let diagnosticStarted=ProcessInfo.processInfo.systemUptime
    txLock.lock(); defer { txLock.unlock() }
    let diagnosticLocked=ProcessInfo.processInfo.systemUptime
    state.lock(); let sock = socket; let ready = authenticated; let stream=diagnosticStream;state.unlock()
    guard !context.cancelled, let socket = sock, !requireAuthentication || ready, var cipher = outgoing else { throw DisplayTransportError.stopped }
    if data.first == 1 || data.first == 2 || data.first == 6 || data.first == 7 {
      guard sending, DisplayChannelCipher.validPayload(data),
        data.first == 1 ? !sentDisplayIdentity : sentDisplayIdentity else { throw DisplayTransportError.invalid }
      if data.first == 1 { sentDisplayIdentity = true }
    } else if data.first == 5 {
      guard !requireAuthentication, !ready else { throw DisplayTransportError.invalid }
      _ = try DisplayVideoFormat.decode(data)
    } else if data.first == 4 {
      guard !sending, DisplayChannelCipher.validInputPayload(data) else { throw DisplayTransportError.invalid }
    }
    let diagnosticSequence=data.first==6 ? (try? DisplayStreamFrameHeader(data))?.sequence:nil
    let diagnosticSealStart=ProcessInfo.processInfo.systemUptime
    let frame = try cipher.seal(data); outgoing = cipher
    if let sequence=diagnosticSequence,let stream{DevelopmentDiagnostics.shared.record(stage:"tx_seal",sequence:sequence,fields:["lockWaitMs":(diagnosticLocked-diagnosticStarted)*1000,"sealMs":(ProcessInfo.processInfo.systemUptime-diagnosticSealStart)*1000,"bytes":Double(frame.count)],stream:stream)}
    let writeStarted = ProcessInfo.processInfo.systemUptime
    do{try displayWriteFrame(socket.fd, frame)}catch{
      if let sequence=diagnosticSequence,let stream{DevelopmentDiagnostics.shared.record(stage:"tx_write_error",sequence:sequence,fields:["elapsedMs":(ProcessInfo.processInfo.systemUptime-writeStarted)*1000],stream:stream)}
      throw error
    }
    if let sequence=diagnosticSequence,let stream{DevelopmentDiagnostics.shared.record(stage:"tx_write",sequence:sequence,fields:["elapsedMs":(ProcessInfo.processInfo.systemUptime-writeStarted)*1000],stream:stream)}
    if data.first == 6, let measured = try? DisplayStreamFrameHeader(data), measured.sequence % 120 == 0 {
      displayStageLog("Display source socketWriteMs=\((ProcessInfo.processInfo.systemUptime-writeStarted)*1000); deliveryNotMeasured=true")
    }
  }
}

// Mutable transport state is lock-protected. Callback installation and delivery
// are main-thread-only; payload delivery never exposes an unsynchronized queue.
final class DisplayTransport: @unchecked Sendable {
  // Install callbacks before start, from main. Invocations are serialized on main.
  var onAuthenticated: ((DisplayVideoFormat) -> Void)?
  var onPayload: ((Data) -> Void)?
  var onFailure: ((String) -> Void)?
  var onLatency: ((Double?) -> Void)?
  private let lock = NSLock()
  private var current: DisplayTransportRun?
  private var generation = UUID()
  private var pendingStart = false
  var diagnosticStreamID:String? {lock.lock();let run=current;lock.unlock();guard let run else{return nil};run.state.lock();defer{run.state.unlock()};return run.diagnosticStream}
  deinit { stop() }
  private func isCurrent(_ run: DisplayTransportRun) -> Bool {
    lock.lock(); defer { lock.unlock() }; return current === run && !run.context.cancelled
  }
  func stop() {
    lock.lock(); let old = current; current = nil; pendingStart = false; generation = UUID(); lock.unlock(); old?.cancel()
  }
  private func isPending(_ epoch: UUID, deadline: Double) -> Bool {
    lock.lock(); defer { lock.unlock() }
    return displayStartPermitted(sameEpoch: generation == epoch, pending: pendingStart, hasRun: current != nil,
      now: ProcessInfo.processInfo.systemUptime, deadline: deadline)
  }
  private func failPending(_ epoch: UUID) {
    lock.lock()
    guard generation == epoch, pendingStart, current == nil else { lock.unlock(); return }
    pendingStart = false
    lock.unlock()
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.lock.lock(); let valid = self.generation == epoch && !self.pendingStart && self.current == nil; self.lock.unlock()
      if valid { self.onFailure?(TCText("Could not prepare the Thunderbolt screen connection. Check the cable and bridge0 status.")) }
    }
  }
  func start(sending: Bool, peer: String,expectedPair:LayoutDevicePair,viewerFormat:DisplayVideoFormat = .standard) throws {
    guard viewerFormat.valid else { throw DisplayTransportError.invalid }
    stop()
    let remote = sending ? try address(peer, 49178) : nil // Pure validation only.
    let deadline = ProcessInfo.processInfo.systemUptime + 15
    lock.lock(); let epoch = generation; pendingStart = true; lock.unlock()
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) { [weak self] in self?.failPending(epoch) }
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      do {
        let b = try displayVerifiedBridge(cancelled: { !self.isPending(epoch, deadline: deadline) })
        // Socket creation is atomic with epoch validation: stop cannot return and
        // then have this old request create a new socket or resurrect a listener.
        self.lock.lock()
        let run: DisplayTransportRun
        do {
          guard displayStartPermitted(sameEpoch: self.generation == epoch, pending: self.pendingStart, hasRun: self.current != nil,
            now: ProcessInfo.processInfo.systemUptime, deadline: deadline) else { throw DisplayTransportError.stopped }
          let initial = OwnedSocket(try boundSocket(b, sending ? 0 : 49178))
          if !sending { guard listen(initial.fd, 1) == 0 else { throw DisplayTransportError.unavailable } }
          run = DisplayTransportRun(initial: initial, bridge: b, sending: sending, remote: sending ? peer : nil,expectedPair:expectedPair,viewerFormat:viewerFormat)
          self.current = run; self.pendingStart = false; self.lock.unlock()
        } catch { self.lock.unlock(); throw error }
        self.begin(run, remote: remote, startupDeadline: sending ? deadline : nil)
      } catch { self.failPending(epoch) }
    }
  }
  private func begin(_ run: DisplayTransportRun, remote: sockaddr_in?, startupDeadline: Double?) {
    guard isCurrent(run) else { run.cancel(); return }
    run.timer(interval: 0.25, queue: DispatchQueue(label: "ThunderControl.display.watchdog")) { [weak self, weak run] in
      guard let self, let run, self.isCurrent(run) else { return }
      run.state.lock(); let auth = run.authStart; let ready = run.authenticated; let rx = run.lastRX; let proof = run.lastBridgeProof; run.state.unlock()
      let now = ProcessInfo.processInfo.systemUptime
      if (startupDeadline != nil && !ready && now >= startupDeadline!) || now - proof > 4 || (auth != nil && !ready && now - auth! > 15) || (ready && now - rx > 6) {
        self.fail(run, TCText("The screen connection stopped responding. Check the cable and the app on the other Mac, then restart."),diagnosticReason:1)
      }
    }
    run.timer(interval: 1, queue: DispatchQueue(label: "ThunderControl.display.bridge")) { [weak self, weak run] in
      guard let self, let run, self.isCurrent(run) else { return }
      do {
        guard try displayVerifiedBridge(cancelled: { !self.isCurrent(run) }) == run.bridge else { throw DisplayTransportError.unavailable }
        run.state.lock(); let socket = run.socket; run.state.unlock()
        if let socket { try displayVerifySocket(socket.fd, bridge: run.bridge, remote: run.remote) }
        run.state.lock(); run.lastBridgeProof = ProcessInfo.processInfo.systemUptime; run.state.unlock()
      } catch { self.fail(run, TCText("Screen transmission stopped because the Thunderbolt connection changed."),diagnosticReason:2) }
    }
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { run.cancel(); return }
      do { try self.connect(run, remote: remote) }
      catch { self.fail(run, TCText("Screen connection or authentication failed. Check that both Macs are running 0.8.22 or later, complete the input connection between the same two Macs first, then try again."),diagnosticReason:3) }
    }
  }
  func send(_ payload: Data) throws {
    guard !Thread.isMainThread, DisplayChannelCipher.validPayload(payload) else { throw DisplayTransportError.invalid }
    lock.lock(); let run = current; lock.unlock()
    guard let run, run.sending else { throw DisplayTransportError.stopped }
    do { try run.transmit(payload) }
    catch { fail(run, TCText("Screen transmission interrupted. Reconnect to continue."),diagnosticReason:4); throw error }
  }
  func sendInput(_ payload: Data) throws {
    guard !Thread.isMainThread, DisplayChannelCipher.validInputPayload(payload) else { throw DisplayTransportError.invalid }
    lock.lock(); let run = current; lock.unlock()
    guard let run, !run.sending else { throw DisplayTransportError.stopped }
    do { try run.transmit(payload) }
    catch { fail(run, TCText("Screen control transmission interrupted. Reconnect to continue."),diagnosticReason:5); throw error }
  }
  private func fail(_ run: DisplayTransportRun, _ message: String, diagnosticReason:Double = 0) {
    lock.lock(); guard current === run else { lock.unlock(); return }; current = nil; let failedGeneration = generation; lock.unlock()
    run.state.lock();let diagnosticStream=run.diagnosticStream;run.state.unlock()
    if let diagnosticStream{DevelopmentDiagnostics.shared.record(stage:"transport_failure",fields:["reasonCode":diagnosticReason],stream:diagnosticStream)}
    run.cancel()
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.lock.lock(); let noNewSession = self.current == nil && self.generation == failedGeneration; self.lock.unlock()
      if noNewSession { self.onFailure?(message) }
    }
  }
  private func connect(_ run: DisplayTransportRun, remote: sockaddr_in?) throws {
    let connected: OwnedSocket
    if let remote { try connectBound(run.initial, remote, run.context, timeout: 5); connected = run.initial }
    else { connected = try acceptBound(run.initial, run.context); run.initial.interrupt() }
    guard isCurrent(run) else { throw DisplayTransportError.stopped }
    try setBlocking(connected.fd)
    let fd = connected.fd
    var idx = run.bridge.index; var one: Int32 = 1
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    guard setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &idx, socklen_t(MemoryLayout.size(ofValue: idx))) == 0,
      setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, 4) == 0,
      setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, 4) == 0,
      setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else { throw DisplayTransportError.unavailable }
    timeout.tv_sec = 5
    guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else { throw DisplayTransportError.unavailable }
    try displayVerifySocket(fd, bridge: run.bridge, remote: run.remote)
    run.state.lock(); run.socket = connected; run.authStart = ProcessInfo.processInfo.systemUptime; run.state.unlock()
    run.context.beginAuthentication()
    let localNonce = UUID().uuidString
    try displayWriteFrame(fd, DisplayChannelCipher.hello(sending: run.sending, nonce: localNonce))
    let peerNonce = try DisplayChannelCipher.parseHello(displayReadFrame(fd, maximum: 128), expectSender: !run.sending)
    guard peerNonce != localNonce else { throw DisplayTransportError.invalid }
    let senderNonce = run.sending ? localNonce : peerNonce
    let receiverNonce = run.sending ? peerNonce : localNonce
    let io = PINPairingTransport(send: { data in
      guard !run.context.cancelled, data.count <= 4096 else { throw DisplayTransportError.stopped }
      try displayWriteFrame(fd, data)
    }, receive: {
      guard !run.context.cancelled else { throw DisplayTransportError.stopped }
      return try displayReadFrame(fd, maximum: 4096)
    }, cancelled: { run.context.cancelled })
    var verified = false
    let key = try performTrustedPairing(isSender: run.sending, senderPIN: nil, sessionID: senderNonce,
      localName: "ThunderControl Display", transport: io, store:DisplayTrustStorage(),nonce:{SymmetricKey(size:.bits256).withUnsafeBytes{Data($0)}},allowNewTrust:false,
      authenticatedIdentity: { local, peer in verified = displayPeerBindingMatches(expected:run.expectedPair,local:local,peer:peer) }, receiverApproval: { _ in throw DisplayTransportError.invalid })
    guard verified, isCurrent(run) else { throw DisplayTransportError.stopped }
    DisplayPeerRoute.rememberAuthenticatedSocket(fd)
    var incoming = DisplayChannelCipher(root: key, senderNonce: senderNonce, receiverNonce: receiverNonce, senderToReceiver: !run.sending)
    run.txLock.lock()
    run.outgoing = DisplayChannelCipher(root: key, senderNonce: senderNonce, receiverNonce: receiverNonce, senderToReceiver: run.sending)
    run.txLock.unlock()
    try run.transmit(DisplayChannelCipher.confirmation(sending: run.sending), requireAuthentication: false)
    let confirm = try incoming.open(displayReadFrame(fd, maximum: 256))
    guard confirm == DisplayChannelCipher.confirmation(sending: !run.sending), run.context.finishAuthentication(now: ProcessInfo.processInfo.systemUptime), isCurrent(run) else { throw DisplayTransportError.invalid }
    // Both peers have proven their existing identity. Negotiate exactly once,
    // before onAuthenticated can create a viewer or a virtual display.
    let agreedFormat = try displayNegotiateVideoFormat(sending: run.sending, viewerFormat: run.viewerFormat,
      send: { try run.transmit($0, requireAuthentication: false) },
      receive: { try incoming.open(displayReadFrame(fd, maximum: 64)) })
    // Separate exact authenticated capability echo. Old peers fail closed before
    // onAuthenticated creates a display/helper; the input Relay is untouched.
    let capabilities = Data([8]) + Data("TC/display/stages-cursor/1".utf8)
    try run.transmit(capabilities, requireAuthentication: false)
    guard try incoming.open(displayReadFrame(fd, maximum: 64)) == capabilities else { throw DisplayTransportError.invalid }
    guard isCurrent(run) else { throw DisplayTransportError.stopped }
    let diagnosticStream=SHA256.hash(data:Data(("ThunderControl/development-diagnostics/v1/"+senderNonce+receiverNonce).utf8)).map{String(format:"%02x",$0)}.joined()
    guard run.activateDiagnostics(stream:diagnosticStream) else{throw DisplayTransportError.stopped}
    DevelopmentDiagnostics.shared.record(stage:"stream_authenticated",fields:["width":Double(agreedFormat.width),"height":Double(agreedFormat.height),"scale":Double(agreedFormat.pixelScale)],stream:diagnosticStream)
    run.timer(interval: 1, queue: DispatchQueue(label: "ThunderControl.display.heartbeat")) { [weak self, weak run] in
      guard let self, let run, self.isCurrent(run) else { return }
      do {
        run.state.lock();let next=run.latency.next(now:ProcessInfo.processInfo.systemUptime);run.state.unlock()
        if next.expired{DispatchQueue.main.async{[weak self] in guard let self,self.isCurrent(run) else{return};self.onLatency?(nil)}}
        try run.transmit(next.token.map{DisplayHeartbeatState.packet(token:$0,reply:false)} ?? Data([0]))
      }
      catch { self.fail(run, TCText("Screen connection keepalive signal lost."),diagnosticReason:6) }
    }
    DispatchQueue.main.sync { if self.isCurrent(run) { self.onAuthenticated?(agreedFormat) } }
    var receivedDisplayIdentity = false
    var frameReadCadence = DisplayCadenceStats()
    var lastCadenceLog = ProcessInfo.processInfo.systemUptime
    // One scalar boundary, not a frame queue. A heartbeat may consume the next
    // read; in that case the following video correctly has no post-main field.
    var priorMainReturn: (time:Double,sequence:UInt64?)?
    while isCurrent(run) {
      let diagnosticReadStarted=ProcessInfo.processInfo.systemUptime
      let diagnosticPriorMainReturn=priorMainReturn
      priorMainReturn=nil
      let encrypted=try displayReadFrame(fd,maximum:run.sending ? 4096+24:DisplayChannelCipher.maximumFrame)
      let diagnosticReadFinished=ProcessInfo.processInfo.systemUptime
      let payload=try incoming.open(encrypted)
      let diagnosticOpened=ProcessInfo.processInfo.systemUptime
      let diagnosticFrame=payload.first==6 ? (try? DisplayStreamFrameHeader(payload)):nil
      if let frame=diagnosticFrame {
        var fields:[String:Double] = ["blockingReadMs":(diagnosticReadFinished-diagnosticReadStarted)*1000,"openMs":(diagnosticOpened-diagnosticReadFinished)*1000,"bytes":Double(encrypted.count),"readStart":diagnosticReadStarted]
        if let previous=diagnosticPriorMainReturn {
          fields["postMainReturnMs"]=(diagnosticReadStarted-previous.time)*1000
          fields["priorMainReturn"]=previous.time
          if let sequence=previous.sequence {fields["priorMainSeq"]=Double(sequence)}
        }
        DevelopmentDiagnostics.shared.record(stage:"rx_open",sequence:frame.sequence,fields:fields,stream:diagnosticStream)
      }
      run.state.lock(); run.lastRX = ProcessInfo.processInfo.systemUptime; run.state.unlock()
      if payload == Data([0]) { continue }
      if payload.first==0 {
        let heartbeat=try DisplayHeartbeatState.parse(payload)
        if !heartbeat.reply {try run.transmit(DisplayHeartbeatState.packet(token:heartbeat.token,reply:true))}
        else {
          run.state.lock();let ms=run.latency.accept(token:heartbeat.token,now:ProcessInfo.processInfo.systemUptime);run.state.unlock()
          if let ms {DispatchQueue.main.async{[weak self] in guard let self,self.isCurrent(run) else{return};self.onLatency?(ms)}}
        }
        continue
      }
      guard DisplayChannelCipher.allowedPayload(payload, fromSender: !run.sending) else { throw DisplayTransportError.invalid }
      if !run.sending {
        guard payload.first == 1 ? !receivedDisplayIdentity : receivedDisplayIdentity else { throw DisplayTransportError.invalid }
        if payload.first == 1 { receivedDisplayIdentity = true }
      }
      // v6 delivers video and cursor metadata only. Raw Relay is the single input owner.
      // No frame dispatch backlog: next network read waits for main's acceptance.
      let receivedAt = ProcessInfo.processInfo.systemUptime
      if payload.first == 6 {
        frameReadCadence.observe(receivedAt)
        if receivedAt - lastCadenceLog >= 2 {
          lastCadenceLog = receivedAt
          displayStageLog("Display cadence read: \(frameReadCadence.summary); contentMayBeIdle=true panelUnmeasured=true")
        }
      }
      let diagnosticSyncStarted=ProcessInfo.processInfo.systemUptime
      var diagnosticBlockStarted=diagnosticSyncStarted,diagnosticBlockEnded=diagnosticSyncStarted
      DispatchQueue.main.sync {
        diagnosticBlockStarted=ProcessInfo.processInfo.systemUptime
        defer {diagnosticBlockEnded=ProcessInfo.processInfo.systemUptime}
        if self.isCurrent(run) {
          if payload.first == 6, let measured = try? DisplayStreamFrameHeader(payload), measured.sequence % 120 == 0 {
            displayStageLog("Display receiver authenticatedReadToMainMs=\((ProcessInfo.processInfo.systemUptime-receivedAt)*1000); oneWayNetworkMs=unknown")
          }
          if let frame=diagnosticFrame{DevelopmentDiagnostics.shared.record(stage:"rx_main",sequence:frame.sequence,fields:["queueMs":(ProcessInfo.processInfo.systemUptime-receivedAt)*1000],stream:diagnosticStream)}
          self.onPayload?(payload)
        }
      }
      let diagnosticSyncReturned=ProcessInfo.processInfo.systemUptime
      priorMainReturn=(diagnosticSyncReturned,diagnosticFrame?.sequence)
      let diagnosticSyncMs=(diagnosticSyncReturned-diagnosticSyncStarted)*1000
      if diagnosticSyncMs>=2 {
        DevelopmentDiagnostics.shared.record(stage:"rx_main_return",sequence:diagnosticFrame?.sequence,fields:["kind":Double(payload.first ?? 255),"elapsedMs":diagnosticSyncMs,"blockMs":(diagnosticBlockEnded-diagnosticBlockStarted)*1000,"waitMs":(diagnosticBlockStarted-diagnosticSyncStarted)*1000,"returnMs":(diagnosticSyncReturned-diagnosticBlockEnded)*1000,"startedAt":diagnosticSyncStarted,"time":diagnosticSyncReturned],stream:diagnosticStream)
      }
    }
  }
}

func displayPeerBindingMatches(expected:LayoutDevicePair,local:String,peer:String)->Bool {LayoutDevicePair(localID:local,peerID:peer)==expected}

// Isolated recorder + invalid descriptors only: no bridge/network/native UI.
func verifyDisplayDiagnosticActivationForTests()->Bool {
  guard let physical=realpath(FileManager.default.temporaryDirectory.path,nil) else{return false}
  let root=URL(fileURLWithPath:String(cString:physical)).appendingPathComponent("tc-diag-activation-"+UUID().uuidString);free(physical)
  let recorder=DevelopmentDiagnostics(root:root)
  defer{_ = recorder.shutdown(timeout:2);try? FileManager.default.removeItem(at:root)}
  let pair=LayoutDevicePair(localID:UUID().uuidString,peerID:UUID().uuidString)!
  func fixture()->DisplayTransportRun{DisplayTransportRun(initial:OwnedSocket(-1),bridge:Bridge(name:"fixture",index:0,ip:"169.254.1.1"),sending:true,remote:nil,expectedPair:pair,viewerFormat:.standard,diagnosticRecorder:recorder)}
  let a=fixture(),b=fixture(),streamA=String(repeating:"a",count:64),streamB=String(repeating:"b",count:64)
  a.cancel()
  guard !a.activateDiagnostics(stream:streamA),b.activateDiagnostics(stream:streamB),!a.activateDiagnostics(stream:streamA) else{return false}
  do{try recorder.flushForTests()}catch{return false}
  guard recorder.currentStream==streamB else{return false}
  a.cancel();guard recorder.currentStream==streamB else{return false};b.cancel()
  guard b.diagnosticStream==streamB else{return false} // Late events stay bound to retired B.
  do{try recorder.flushForTests()}catch{return false}
  guard recorder.currentStream==nil else{return false}
  let racing=fixture(),entered=DispatchSemaphore(value:0),proceed=DispatchSemaphore(value:0),activated=DispatchSemaphore(value:0),cancelled=DispatchSemaphore(value:0)
  racing.diagnosticActivationHookForTests={entered.signal();_ = proceed.wait(timeout:.now()+3)}
  DispatchQueue.global().async{_ = racing.activateDiagnostics(stream:streamA);activated.signal()}
  guard entered.wait(timeout:.now()+2) == .success else{proceed.signal();return false}
  DispatchQueue.global().async{racing.cancel();cancelled.signal()}
  let deadline=ProcessInfo.processInfo.systemUptime+1
  while !racing.context.cancelled && ProcessInfo.processInfo.systemUptime<deadline{usleep(1000)}
  let sawCancellation=racing.context.cancelled;proceed.signal()
  guard activated.wait(timeout:.now()+3) == .success,cancelled.wait(timeout:.now()+3) == .success,sawCancellation else{return false}
  do{try recorder.flushForTests()}catch{return false}
  return recorder.currentStream==nil && !racing.activateDiagnostics(stream:streamA)
}
