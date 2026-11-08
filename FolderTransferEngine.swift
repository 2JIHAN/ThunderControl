import Foundation
import CryptoKit
import Darwin

// Sequential folder protocol over an opaque authenticated channel. No keys, sockets, AppKit or relay.
//
//   sender                          receiver
//   offer ─────────────────────────▶ (approval; working heartbeats)
//         ◀───────────────────────── accept | decline
//   manifest × n ──────────────────▶ (checkpoint open + recovery; working)
//         ◀───────────────────────── plan(needed bitmap) | failed
//   fileBegin, data × n, fileEnd ──▶ (durable commit; working)
//         ◀───────────────────────── fileDone          (repeat per needed file)
//   (tree rescan; working) finish ─▶ (publication; working)
//         ◀───────────────────────── complete
//   closed ────────────────────────▶ (journal removed)
//
// One thread writes the channel. Long work runs on a helper while that thread sends `working`.

enum FolderMessage: Codable, Equatable {
  case offer(FolderOffer)
  case accept, decline
  case working(UInt64)
  case manifest(Data)
  case plan(Data)
  case fileBegin(Int)
  case data(Data)
  case fileEnd(Int, Data)
  case fileDone(Int)
  case finish(Data)
  case complete(Data)
  case closed
  case failed(FolderFailureCode)

  func validate() throws {
    let indices = 0..<FolderLimits.entries
    switch self {
    case .offer(let offer): try offer.validate()
    case .manifest(let part): guard (1...FolderLimits.manifestPart).contains(part.count) else { throw FileTransferError.invalid }
    case .plan(let bits): guard bits.count <= (FolderLimits.entries + 7) / 8 else { throw FileTransferError.invalid }
    case .fileBegin(let i), .fileDone(let i): guard indices.contains(i) else { throw FileTransferError.invalid }
    case .data(let bytes): guard (1...65536).contains(bytes.count) else { throw FileTransferError.invalid }
    case .fileEnd(let i, let sha): guard indices.contains(i), sha.count == 32 else { throw FileTransferError.invalid }
    case .finish(let d), .complete(let d): guard d.count == 32 else { throw FileTransferError.invalid }
    case .accept, .decline, .working, .closed, .failed: break
    }
  }
}

/// Authenticated ordered message channel. Implementations validate each message and must be
/// interruptible by cancellation; `receive` fails after the transport idle timeout.
protocol FolderChannel: AnyObject {
  func send(_ message: FolderMessage) throws
  func receive() throws -> FolderMessage
}

struct FolderTiming {
  /// Interval between `working` frames; must stay well below the transport idle timeout.
  var heartbeat: TimeInterval = 2
  /// A wait fails after this long without progress, even if heartbeats continue.
  var stall: TimeInterval = 600
  /// Absolute budget for the receiver's approval.
  var approval: TimeInterval = 130
  static let standard = FolderTiming()
}

struct FolderProgress: Equatable {
  var totalFiles = 0, doneFiles = 0, skippedFiles = 0
  var totalBytes: UInt64 = 0, doneBytes: UInt64 = 0
  var currentPath: String? = nil
  var verifying = false
}
enum FolderOutcome: Equatable { case completed(FolderProgress), declined }

/// Producer-side progress throttle (at most 10 Hz) so a fast link cannot flood the main queue.
private final class FolderThrottle {
  private let report: (FolderProgress) -> Void
  private var last = -1.0
  init(_ report: @escaping (FolderProgress) -> Void) { self.report = report }
  func callAsFunction(_ p: FolderProgress, force: Bool = false) {
    let now = ProcessInfo.processInfo.systemUptime
    if force || now - last >= 0.1 { last = now; report(p) }
  }
}
private final class FolderResultBox<T> { var value: Result<T, Error>? }
private final class FolderAbort { private let lock = NSLock(); private var set = false
  func raise() { lock.lock(); set = true; lock.unlock() }
  func check() throws { lock.lock(); defer { lock.unlock() }; if set { throw FileTransferError.cancelled } }
}

enum FolderTransferEngine {
  static func send(_ plan: FolderSourcePlan, over channel: FolderChannel, timing: FolderTiming = .standard,
                   check: @escaping () throws -> Void, report: @escaping (FolderProgress) -> Void) throws -> FolderOutcome {
    let manifest = plan.manifest
    try channel.send(.offer(plan.offer))
    let accepted: Bool = try wait(channel, budget: timing.approval, extends: false, check: check) {
      switch $0 { case .accept: return true; case .decline: return false; default: return nil }
    }
    guard accepted else { return .declined }
    var offset = 0
    while offset < manifest.canonical.count {
      let end = min(manifest.canonical.count, offset + FolderLimits.manifestPart)
      try channel.send(.manifest(manifest.canonical.subdata(in: offset..<end))); offset = end
    }
    let bits: Data = try wait(channel, budget: timing.stall, extends: true, check: check) { if case .plan(let b) = $0 { return b }; return nil }
    let needed = try decodePlan(bits, manifest)
    var progress = FolderProgress(totalFiles: manifest.fileCount, doneFiles: manifest.fileCount - needed.count, skippedFiles: manifest.fileCount - needed.count,
                                  totalBytes: manifest.totalBytes, doneBytes: manifest.totalBytes - needed.reduce(0) { $0 + manifest.entries[$1].size })
    let emit = FolderThrottle(report); emit(progress, force: true)
    for index in needed {
      try check()
      let entry = manifest.entries[index], source = try plan.open(index)
      progress.currentPath = entry.displayPath; emit(progress)
      try channel.send(.fileBegin(index))
      var hasher = SHA256(), sent: UInt64 = 0
      while true {
        try check()
        let chunk = try source.chunk(); if chunk.isEmpty { break }
        guard UInt64(chunk.count) <= entry.size - sent else { throw FolderTransferError.sourceChanged }
        try channel.send(.data(chunk)); hasher.update(data: chunk); sent += UInt64(chunk.count); progress.doneBytes += UInt64(chunk.count)
        emit(progress)
      }
      do { try source.verifyUnchanged() } catch { throw FolderTransferError.sourceChanged }
      guard sent == entry.size else { throw FolderTransferError.sourceChanged }
      try channel.send(.fileEnd(index, Data(hasher.finalize())))
      try wait(channel, budget: timing.stall, extends: true, check: check) { if case .fileDone(let i) = $0, i == index { return () }; return nil }
      progress.doneFiles += 1; emit(progress)
    }
    progress.currentPath = nil; progress.verifying = true; emit(progress, force: true)
    try heartbeat(channel, timing, check) { _, c in try plan.verifyUnchanged(check: c) }
    try channel.send(.finish(manifest.digest))
    do {
      try wait(channel, budget: timing.stall, extends: true, check: check) { if case .complete(let d) = $0, d == manifest.digest { return () }; return nil }
    } catch FileTransferError.cancelled { throw FileTransferError.cancelled } catch let e as FolderTransferError { throw e } catch { throw FolderTransferError.unconfirmed }
    try? channel.send(.closed)
    progress.verifying = false; emit(progress, force: true)
    return .completed(progress)
  }

  static func receive(_ offer: FolderOffer, over channel: FolderChannel, identity: FolderPeerIdentity, timing: FolderTiming = .standard,
                      choose: @escaping (_ check: () throws -> Void) throws -> URL?, check: @escaping () throws -> Void,
                      report: @escaping (FolderProgress) -> Void) throws -> FolderOutcome {
    try offer.validate()
    guard let url = try heartbeat(channel, timing, check, { _, c in try choose(c) }) else { try channel.send(.decline); return .declined }
    try channel.send(.accept)
    var bytes = Data()
    while bytes.count < offer.manifestBytes {
      try check()
      guard case .manifest(let part) = try channel.receive(), part.count <= offer.manifestBytes - bytes.count else { throw FileTransferError.invalid }
      bytes.append(part)
    }
    guard Data(SHA256.hash(data: bytes)) == offer.digest else { throw FileTransferError.authentication }
    let manifest = try FolderManifest.decode(bytes)
    guard offer.matches(manifest) else { throw FileTransferError.invalid }
    do {
      let store = try heartbeat(channel, timing, check) { pulse, c -> FolderReceiverStore in
        let store = try FolderReceiverStore.open(destination: url, manifest: manifest, identity: identity, check: c, pulse: pulse)
        try store.preflight(); return store
      }
      var bits = Data(count: (manifest.entries.count + 7) / 8)
      for (i, entry) in manifest.entries.enumerated() where entry.kind == .file && store.receipts[i] == nil { bits[i / 8] |= UInt8(1 << (i % 8)) }
      try channel.send(.plan(bits))
      var progress = FolderProgress(totalFiles: manifest.fileCount, doneFiles: store.skippedFiles, skippedFiles: store.skippedFiles,
                                    totalBytes: manifest.totalBytes, doneBytes: manifest.totalBytes - store.neededBytes)
      let emit = FolderThrottle(report); emit(progress, force: true)
      var previous = -1
      while true {
        let next: FolderMessage = try wait(channel, budget: timing.stall, extends: true, check: check) {
          switch $0 { case .fileBegin, .finish: return $0; default: return nil }
        }
        if case .finish(let digest) = next {
          guard digest == manifest.digest, store.receipts.count == manifest.fileCount else { throw FileTransferError.invalid }
          progress.currentPath = nil; progress.verifying = true; emit(progress, force: true)
          try heartbeat(channel, timing, check) { _, c in try store.publish(admit: c) }
          try channel.send(.complete(digest))
          if (try? wait(channel, budget: timing.stall, extends: false, check: check, { $0 == .closed ? () : nil })) != nil { store.finish() }
          progress.verifying = false; emit(progress, force: true)
          return .completed(progress)
        }
        guard case .fileBegin(let index) = next, index > previous, index < manifest.entries.count,
          manifest.entries[index].kind == .file, store.receipts[index] == nil else { throw FileTransferError.invalid }
        previous = index
        let entry = manifest.entries[index]
        progress.currentPath = entry.displayPath; emit(progress)
        let destination = try store.begin(index)
        var hasher = SHA256(), received: UInt64 = 0
        while received < entry.size {
          try check()
          guard case .data(let chunk) = try channel.receive(), UInt64(chunk.count) <= entry.size - received else { throw FileTransferError.invalid }
          try destination.write(chunk); hasher.update(data: chunk); received += UInt64(chunk.count); progress.doneBytes += UInt64(chunk.count)
          emit(progress)
        }
        let digest = Data(hasher.finalize())
        guard case .fileEnd(index, let sha) = try channel.receive(), sha == digest else { throw FileTransferError.authentication }
        try heartbeat(channel, timing, check) { _, c in try store.commit(index, destination, sha: sha, admit: c) }
        try channel.send(.fileDone(index))
        progress.doneFiles += 1; emit(progress)
      }
    } catch let error as FolderTransferError {
      try? channel.send(.failed(error.code)); throw error
    }
  }

  /// Receives until `accept` returns a value. Only `working` and `failed` are handled here.
  /// Non-extending budgets are absolute; extending ones reset whenever the peer's progress advances.
  @discardableResult
  static func wait<T>(_ channel: FolderChannel, budget: TimeInterval, extends: Bool, check: () throws -> Void, _ accept: (FolderMessage) throws -> T?) throws -> T {
    var deadline = ProcessInfo.processInfo.systemUptime + budget, lastProgress: UInt64? = nil
    while true {
      try check()
      let message = try channel.receive()
      if case .working(let value) = message {
        if extends, value != lastProgress { lastProgress = value; deadline = ProcessInfo.processInfo.systemUptime + budget }
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw FolderTransferError.stalled }
        continue
      }
      if case .failed(let code) = message { throw FolderTransferError.peerFailed(code) }
      guard let value = try accept(message) else { throw FileTransferError.invalid }
      return value
    }
  }

  /// Runs `work` off the channel thread while this thread alone sends throttled `working` frames.
  /// Always waits for `work` to end so no stale worker can touch the checkpoint afterward.
  static func heartbeat<T>(_ channel: FolderChannel, _ timing: FolderTiming, _ check: @escaping () throws -> Void,
                           _ work: @escaping (FolderPulse, () throws -> Void) throws -> T) throws -> T {
    let pulse = FolderPulse(), abort = FolderAbort(), done = DispatchSemaphore(value: 0), box = FolderResultBox<T>()
    DispatchQueue.global(qos: .utility).async {
      box.value = Result { try work(pulse) { try check(); try abort.check() } }; done.signal()
    }
    var failure: Error?
    while done.wait(timeout: .now() + timing.heartbeat) == .timedOut {
      guard failure == nil else { continue }
      do { try check(); try channel.send(.working(pulse.value)) } catch { failure = error; abort.raise() }
    }
    if let failure { throw failure }
    return try box.value!.get()
  }

  private static func decodePlan(_ bits: Data, _ manifest: FolderManifest) throws -> [Int] {
    guard bits.count == (manifest.entries.count + 7) / 8 else { throw FileTransferError.invalid }
    var needed: [Int] = []
    for i in 0..<(bits.count * 8) where bits[i / 8] & UInt8(1 << (i % 8)) != 0 {
      guard i < manifest.entries.count, manifest.entries[i].kind == .file else { throw FileTransferError.invalid }
      needed.append(i)
    }
    return needed
  }
}
