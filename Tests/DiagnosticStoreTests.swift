import Foundation
import Darwin

// Disk-only synthetic tests: no OS input, network, UI, or production log access.
func runDiagnosticStoreTests() -> Int {
  var failures = 0
  func check(_ condition: Bool, _ label: String) {
    if !condition { failures += 1; print("DiagnosticStore FAIL: \(label)") }
  }
  let fm = FileManager.default
  guard let physicalTemp = realpath(fm.temporaryDirectory.path, nil) else { return 1 }
  let temporaryURL = URL(fileURLWithPath: String(cString: physicalTemp), isDirectory: true)
  free(physicalTemp)
  let root = temporaryURL.appendingPathComponent("ThunderControl-DiagnosticTests-" + UUID().uuidString)
  do {
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let logs = root.appendingPathComponent("logs")
    let store = DiagnosticStore(root: logs, segmentBytes: 16, maxLineBytes: 8)
    for i in 0..<6 { store.recordConnection("line\(i)"); try store.flush() }
    let snap = try store.snapshot()
    check(String(data: snap["connection"]!, encoding: .utf8) == "line2\nline3\nline4\nline5\n", "newest previous and active in order")
    check(snap["connection"]!.count <= 32 && snap["gesture"]!.isEmpty == true, "independent channel caps")
    store.recordGesture("한글🙂long\nsecret"); try store.flush()
    let unicode = try store.snapshot()["gesture"]!
    check(unicode.count <= 8 && String(data: unicode, encoding: .utf8) == "한글\n", "UTF8 intact and newline included in cap")
    for channel in ["connection", "gesture"] {
      for suffix in ["active", "previous"] {
        let url = logs.appendingPathComponent("\(channel).\(suffix).log")
        if fm.fileExists(atPath: url.path) {
          let attrs = try fm.attributesOfItem(atPath: url.path)
          check((attrs[.size] as! NSNumber).intValue <= 16, "segment exact byte bound")
          check((attrs[.posixPermissions] as! NSNumber).intValue == 0o600, "file mode 0600")
        }
      }
    }
    let attrs = try fm.attributesOfItem(atPath: logs.path)
    check((attrs[.posixPermissions] as! NSNumber).intValue == 0o700, "directory mode 0700")
    let output = root.appendingPathComponent("exports")
    try fm.createDirectory(at: output, withIntermediateDirectories: false)
    try store.export(to: output)
    let published = try fm.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
    check(published.count == 1 && !published[0].lastPathComponent.hasPrefix("."), "one atomic published export")
    let exportedConnection = try Data(contentsOf: published[0].appendingPathComponent("connection.log"))
    let exportedGesture = try Data(contentsOf: published[0].appendingPathComponent("gesture.log"))
    check(exportedConnection == snap["connection"] && exportedGesture == unicode, "export matches queue-consistent snapshot")
    let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: published[0].appendingPathComponent("manifest.json"))) as! [String: Any]
    check((manifest["connectionBytes"] as? Int) == exportedConnection.count && (manifest["gestureBytes"] as? Int) == exportedGesture.count, "manifest byte counts")
    try store.export(to: output)
    check(try fm.contentsOfDirectory(atPath: output.path).count == 2, "export never overwrites prior output")
    let missing = output.appendingPathComponent("missing/destination")
    do { try store.export(to: missing); check(false, "export failure propagated") } catch { }

    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let gateLock = NSLock(); var firstDrain = true
    let overloaded = DiagnosticStore(root: root.appendingPathComponent("overload"), segmentBytes: 256, maxLineBytes: 8, pendingLimit: 4, beforeDrain: {
      gateLock.lock(); let first = firstDrain; firstDrain = false; gateLock.unlock()
      if first { entered.signal(); release.wait() }
    })
    overloaded.recordConnection("first")
    check(entered.wait(timeout: .now() + 5) == .success, "disk queue gate entered")
    for _ in 0..<20 { overloaded.recordConnection(String(repeating: "x", count: 10000)) }
    check(overloaded.droppedLineCount == 17, "bounded pending ingress drops newest including in-flight")
    release.signal(); try overloaded.flush()
    let bounded = try overloaded.snapshot()["connection"]!
    check(bounded.split(separator: 10).count == 4 && bounded.count <= 32, "bounded queued bytes and accepted count")

    let ingressHeld = DispatchSemaphore(value: 0), releaseIngress = DispatchSemaphore(value: 0)
    let ingressDone = DispatchSemaphore(value: 0), rejectedDone = DispatchSemaphore(value: 0)
    let contended = DiagnosticStore(root: root.appendingPathComponent("contention"), nonblockingIngress: true)
    DispatchQueue.global().async {
      contended.withIngressLockForTesting {
        ingressHeld.signal(); releaseIngress.wait()
      }
      ingressDone.signal()
    }
    check(ingressHeld.wait(timeout: .now() + 5) == .success, "ingress lock held deterministically")
    DispatchQueue.global().async { contended.recordGesture("rejected"); rejectedDone.signal() }
    let returned = rejectedDone.wait(timeout: .now() + 1) == .success
    releaseIngress.signal()
    check(ingressDone.wait(timeout: .now() + 5) == .success, "ingress holder joins")
    if !returned { _ = rejectedDone.wait(timeout: .now() + 5) }
    check(returned, "nonblocking producer returns while ingress held")
    check(contended.droppedLineCount == 1, "contention drop accounted")
    contended.recordGesture("stored"); try contended.flush()

    let outside = root.appendingPathComponent("outside")
    try fm.createDirectory(at: outside, withIntermediateDirectories: false)
    let marker = outside.appendingPathComponent("marker")
    try Data("untouched".utf8).write(to: marker)
    let link = root.appendingPathComponent("link")
    try fm.createSymbolicLink(at: link, withDestinationURL: outside)
    let linked = DiagnosticStore(root: link.appendingPathComponent("nested"), segmentBytes: 16)
    linked.recordConnection("no")
    do { try linked.flush(); check(false, "symlink ancestor rejected") } catch { }
    check(!fm.fileExists(atPath: outside.appendingPathComponent("nested").path), "symlink ancestor never followed")
    let badRoot = root.appendingPathComponent("badFile")
    try fm.createDirectory(at: badRoot, withIntermediateDirectories: false)
    try fm.createSymbolicLink(at: badRoot.appendingPathComponent("connection.active.log"), withDestinationURL: marker)
    let badFile = DiagnosticStore(root: badRoot, segmentBytes: 16)
    badFile.recordConnection("no")
    do { try badFile.flush(); check(false, "symlink active rejected") } catch { }
    check(try String(contentsOf: marker, encoding: .utf8) == "untouched", "target not modified")
    badFile.recordConnection("later")
    do { try badFile.flush(); check(false, "fault remains latched") } catch { }
    check(badFile.droppedLineCount == 2, "initial and later writer-fault drops accounted")
    try fm.removeItem(at: badRoot.appendingPathComponent("connection.active.log"))
    badFile.recordGesture("still disabled")
    do { try badFile.flush(); check(false, "repair does not resume unsafe writer") } catch { }
    check(!fm.fileExists(atPath: badRoot.appendingPathComponent("gesture.active.log").path), "fault disables later writes")

    do { try store.export(to: link); check(false, "symlink export destination rejected") } catch { }
    let hardRoot = root.appendingPathComponent("hardLink")
    try fm.createDirectory(at: hardRoot, withIntermediateDirectories: false)
    try fm.linkItem(at: marker, to: hardRoot.appendingPathComponent("gesture.previous.log"))
    let hard = DiagnosticStore(root: hardRoot, segmentBytes: 16)
    do { try hard.flush(); check(false, "hard-linked files rejected") } catch { }

    let exact = DiagnosticStore(root: root.appendingPathComponent("exact"), segmentBytes: 8, maxLineBytes: 8)
    exact.recordConnection("1234567"); try exact.flush()
    exact.recordConnection("abcdefg"); try exact.flush()
    check(try exact.snapshot()["connection"]!.count == 16, "exact cap includes both newlines")
    exact.recordConnection("ABCDEFG"); try exact.flush()
    check(String(data: try exact.snapshot()["connection"]!, encoding: .utf8) == "abcdefg\nABCDEFG\n", "rotate before cap")

    let unrelated = logs.appendingPathComponent("user-notes.txt")
    try Data("preserve".utf8).write(to: unrelated)
    for _ in 0..<12 { store.recordConnection("rotate!"); try store.flush() }
    check(try String(contentsOf: unrelated, encoding: .utf8) == "preserve", "rotation preserves unrelated files")
    let invalid = DiagnosticStore(root: root.appendingPathComponent("invalid"), segmentBytes: 0)
    do { try invalid.flush(); check(false, "invalid limits fail closed") } catch { }
    let concurrent = DiagnosticStore(root: root.appendingPathComponent("parallel"), segmentBytes: 128, maxLineBytes: 32)
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global(qos: .utility).async {
      for index in 0..<2000 { concurrent.recordConnection("line=\(index)"); concurrent.recordGesture("note=enabled") }
      group.leave()
    }
    let beforeExport = Set(try fm.contentsOfDirectory(atPath: output.path))
    try concurrent.export(to: output)
    group.wait(); try concurrent.flush()
    let additions = Set(try fm.contentsOfDirectory(atPath: output.path)).subtracting(beforeExport)
    check(additions.count == 1, "one concurrent snapshot published")
    for folder in additions {
      let dir = output.appendingPathComponent(folder)
      let data = try Data(contentsOf: dir.appendingPathComponent("manifest.json"))
      let m = try JSONSerialization.jsonObject(with: data) as! [String: Any]
      for channel in ["connection", "gesture"] {
        let bytes = try Data(contentsOf: dir.appendingPathComponent(channel + ".log"))
        check(bytes.count == (m[channel + "Bytes"] as? Int), "concurrent export manifest consistent")
        check(bytes.count <= 256, "concurrent export channel cap")
      }
    }
    var time = 1.0, sinkLines: [String] = []
    let continuous = GestureTrace(testClock: { time }, continuous: true, sink: { sinkLines.append($0) })
    continuous.note(.enabled); time += 601; continuous.note(.rejected)
    check(continuous.enabled && sinkLines.count == 2, "continuous trace survives legacy TTL")
    check(sinkLines.allSatisfy { $0.utf8.count <= 512 && !$0.contains("\n") }, "sink only bounded allowlist line")
    continuous.setEnabled(false); continuous.note(.enabled)
    check(sinkLines.count == 2, "disabled trace suppresses sink")
    let legacy = GestureTrace(testClock: { time }); time += 600
    check(!legacy.enabled, "legacy TTL preserved")
  } catch { failures += 1; print("DiagnosticStore unexpected error: \(error)") }
  print("DiagnosticStore tests failures=\(failures)")
  return failures
}
