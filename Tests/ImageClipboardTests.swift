import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor func runImageClipboardTests() -> Int {
    var failures = 0
    func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        if !condition() { failures += 1; print("FAIL ImageClipboard: \(name)") }
    }
    func spin(_ duration: TimeInterval = 0.03) { RunLoop.current.run(until: Date().addingTimeInterval(duration)) }
    let a = NSPasteboard(name: .init("ThunderControl.ImageClipboardTests.A.\(UUID().uuidString)"))
    let b = NSPasteboard(name: .init("ThunderControl.ImageClipboardTests.B.\(UUID().uuidString)"))
    defer { a.releaseGlobally(); b.releaseGlobally() }
    let ca = ImageClipboardController(pasteboard: a)
    let cb = ImageClipboardController(pasteboard: b)
    var qa: [ImageClipboardPacket] = [], qb: [ImageClipboardPacket] = []
    var sentA: [ImageClipboardPacket] = [], sentB: [ImageClipboardPacket] = []
    var statuses: [String] = []
    ca.isSafe = { true }; cb.isSafe = { true }
    ca.send = { qa.append($0); sentA.append($0); return true }
    cb.send = { qb.append($0); sentB.append($0); return true }
    ca.onStatus = { statuses.append($0) }
    func pump(_ rounds: Int = 10) {
        for _ in 0..<rounds {
            let aa = qa; qa.removeAll()
            for packet in aa { cb.receive(ca.sendGate.packetForTransmission(packet)) }
            let bb = qb; qb.removeAll()
            for packet in bb { ca.receive(cb.sendGate.packetForTransmission(packet)) }
            ca.poll(); cb.poll(); spin(0.005)
        }
    }
    func image(_ size: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32)!
        var seed: UInt32 = 12345
        for i in 0..<(size * size * 4) {
            seed = seed &* 1664525 &+ 1013904223
            rep.bitmapData![i] = UInt8(truncatingIfNeeded: seed >> 24)
        }
        return rep.representation(using: .png, properties: [:])!
    }
    let png = image(1), large = image(180)
    func copy(_ data: Data, _ board: NSPasteboard) { board.clearContents(); _ = board.setData(data, forType: .png) }
    copy(png, a)
    let initialB = b.changeCount
    ca.start(); cb.start(); pump()
    check(b.changeCount == initialB, "off never applies")
    ca.setEnabled(true); cb.setEnabled(true); pump()
    check(b.changeCount == initialB, "enable baselines existing image")
    copy(png, a); pump(40)
    check(b.data(forType: .png) == png, "A to B exact PNG")
    let delivered = sentA.filter { $0.op == .chunk }.count
    let bCount = b.changeCount
    pump(20)
    check(sentA.filter { $0.op == .chunk }.count == delivered && b.changeCount == bCount, "no echo")
    copy(large, b); pump(120)
    check(a.data(forType: .png) == large, "B to A chunked exact PNG")
    let chunks = sentB.filter { $0.op == .chunk }
    check(chunks.count > 1 && chunks.allSatisfy { ($0.bytes?.count ?? 0) <= 32768 }, "bounded chunks")
    check(sentA.filter { $0.op == .ack }.count == chunks.count, "one ACK per chunk")
    let bitmap = NSBitmapImageRep(data: png)!
    a.clearContents(); a.setData(bitmap.tiffRepresentation!, forType: .tiff)
    pump(50)
    let converted = b.data(forType: .png).flatMap { NSBitmapImageRep(data: $0) }
    check(converted?.pixelsWide == 1 && converted?.pixelsHigh == 1 && converted?.colorAt(x: 0, y: 0) == bitmap.colorAt(x: 0, y: 0), "TIFF conversion preserves pixels")
    a.clearContents(); a.setData(png, forType: .png); a.setString("image metadata", forType: .string)
    pump(40)
    check(b.data(forType: .png) == png && b.string(forType: .string) == nil, "image selected without copying advertised text")
    let beforeText = b.changeCount
    a.clearContents(); a.setString("private", forType: .string); ca.poll(); pump()
    check(b.changeCount == beforeText, "text not copied")
    a.clearContents(); a.setString("file:///private/example.png", forType: .fileURL); ca.poll(); pump()
    check(b.changeCount == beforeText, "file URL not followed")
    let e = UUID().uuidString, pe = UUID().uuidString, id = UUID().uuidString
    let packet = ImageClipboardPacket(op: .chunk, epoch: e, peerEpoch: pe, id: id, offset: 0, totalBytes: png.count, bytes: png)
    check(packet.valid, "valid shape")
    var bad = packet; bad.enabled = true; check(!bad.valid, "extra field")
    bad = packet; bad.epoch = e.lowercased(); check(!bad.valid, "canonical UUID")
    bad = packet; bad.offset = Int.max; check(!bad.valid, "overflow rejected")
    bad = packet; bad.totalBytes = 8388609; check(!bad.valid, "total cap")
    bad = packet; bad.bytes = Data(count: 32769); check(!bad.valid, "chunk cap")
    check(!ImageClipboardPacket(op: .ack, epoch: e, peerEpoch: pe, id: id, offset: 0).valid, "ACK offset")
    check(!ImageClipboardPacket(op: .consent, epoch: e, enabled: true, bytes: png).valid, "consent field shape")
    let virginGate = ImageClipboardSendGate()
    check(virginGate.packetForTransmission(packet).op == .cancel, "gate initially safe off")
    let consent = sentA.last { $0.op == .consent }!
    let peerConsent = sentB.last { $0.op == .consent }!
    let remote = ImageClipboardPacket(op: .chunk, epoch: peerConsent.epoch, peerEpoch: consent.epoch, id: UUID().uuidString,
                                      offset: 0, totalBytes: large.count, bytes: large.prefix(32768))
    cb.setEnabled(false); pump()
    let disabledCount = a.changeCount
    ca.receive(remote)
    check(a.changeCount == disabledCount, "remote consent off cannot apply")
    cb.setEnabled(true); pump()
    copy(large, a); ca.poll()
    for _ in 0..<80 { spin(0.005); if qa.contains(where: { $0.op == .chunk }) { break } }
    let queued = qa.first { $0.op == .chunk }
    check(queued != nil, "async conversion queued chunk")
    ca.setEnabled(false)
    if let queued {
        let revoked = ca.sendGate.packetForTransmission(queued)
        check(revoked.op == .cancel && revoked.id == queued.id && revoked.epoch == queued.epoch && revoked.bytes == nil && revoked.valid, "queued revoke becomes cancel")
    }
    let staleConsent = ca.sendGate.packetForTransmission(consent)
    check(staleConsent.enabled == false && staleConsent.epoch != consent.epoch, "queued consent refreshed")
    pump(); ca.setEnabled(true); pump()
    let beforeStale = b.changeCount
    copy(large, a); ca.poll()
    a.clearContents(); a.setString("newer local copy", forType: .string)
    pump(60)
    check(b.changeCount == beforeStale, "async stale snapshot discarded")
    let old = sentB.last { $0.op == .consent }!
    var wrong = remote; wrong.epoch = UUID().uuidString; wrong.peerEpoch = sentA.last { $0.op == .consent }!.epoch
    ca.receive(wrong); check(a.string(forType: .string) == "newer local copy", "both epochs required")
    ca.receive(old)
    var safe = true
    ca.isSafe = { safe }
    safe = false; ca.poll()
    check(ca.sendGate.packetForTransmission(packet).op == .cancel, "unsafe revokes gate")
    safe = true; ca.poll(); pump()
    let beforeResume = b.changeCount; pump()
    check(b.changeCount == beforeResume, "safe resume baselines")
    ca.send = { _ in false }
    let statusIndex = statuses.count
    copy(png, a); ca.poll(); for _ in 0..<30 { spin(0.005) }
    check(!statuses.dropFirst(statusIndex).contains("Image clipboard sent"), "send false never claims sent")
    ca.send = { qa.append($0); sentA.append($0); return true }
    pump(40)
    check(b.data(forType: .png) == png && statuses.dropFirst(statusIndex).contains("Image clipboard sent"), "capacity recovery retries same copy")
    ca.stop(); cb.stop()
    let c = ImageClipboardController(pasteboard: a, enabled: true)
    var cPackets: [ImageClipboardPacket] = []
    c.isSafe = { true }; c.send = { cPackets.append($0); return true }
    c.start(); copy(png, a); c.poll(); spin()
    check(!cPackets.contains { $0.op == .chunk }, "old peer no consent no images")
    c.receive(.init(op: .consent, epoch: e, enabled: true))
    let localEpoch = cPackets.last { $0.op == .consent }!.epoch
    let first = ImageClipboardPacket(op: .chunk, epoch: e, peerEpoch: localEpoch, id: id,
                                     offset: 0, totalBytes: large.count, bytes: large.prefix(32768))
    let beforeOrder = a.changeCount
    var outOfOrder = first; outOfOrder.offset = 1
    c.receive(outOfOrder)
    check(a.changeCount == beforeOrder && cPackets.last?.op == .cancel, "first chunk ordering")
    c.receive(first)
    a.clearContents(); a.setString("new local wins", forType: .string)
    var second = first; second.offset = 32768; second.bytes = large.subdata(in: 32768..<65536)
    c.receive(second)
    check(a.string(forType: .string) == "new local wins", "incoming newer local copy wins")
    c.poll()
    let beforeInvalid = a.changeCount
    c.receive(.init(op: .chunk, epoch: e, peerEpoch: localEpoch, id: UUID().uuidString,
                    offset: 0, totalBytes: 4, bytes: Data([1, 2, 3, 4])))
    check(a.changeCount == beforeInvalid, "non-image payload rejected")
    copy(large, a); c.poll()
    for _ in 0..<60 { spin(0.005); if cPackets.contains(where: { $0.op == .chunk }) { break } }
    let pending = cPackets.last { $0.op == .chunk }
    check(pending != nil, "timeout transfer starts")
    if let pending {
        c.sendGate.revoke()
        let synchronouslyRevoked = c.sendGate.packetForTransmission(pending)
        check(synchronouslyRevoked.op == .cancel && synchronouslyRevoked.id == pending.id && synchronouslyRevoked.epoch == pending.epoch && synchronouslyRevoked.peerEpoch == pending.peerEpoch && synchronouslyRevoked.bytes == nil, "synchronous quarantine revokes queued image")
        check(c.sendGate.packetForTransmission(.init(op: .consent, epoch: localEpoch, enabled: true)).enabled == false, "synchronous quarantine revokes consent")
        let countBeforeACK = cPackets.filter { $0.op == .chunk }.count
        c.receive(.init(op: .ack, epoch: e, peerEpoch: localEpoch, id: pending.id, offset: 1))
        spin()
        check(cPackets.filter { $0.op == .chunk }.count == countBeforeACK, "wrong ACK never advances")
        spin(10.25); c.poll()
        check(cPackets.contains { $0.op == .cancel && $0.id == pending.id }, "ten-second timeout cancels")
        check(c.sendGate.packetForTransmission(pending).op == .cancel, "timeout releases queued payload")
    }
    c.stop()
    print("ImageClipboardTests: \(failures) failures")
    return failures
}
