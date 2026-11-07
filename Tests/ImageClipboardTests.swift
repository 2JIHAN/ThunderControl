import AppKit
import ImageIO
import UniformTypeIdentifiers

private final class ClipboardReadSpy: NSObject, NSPasteboardItemDataProvider {
    private let lock = NSLock()
    private var requested: [NSPasteboard.PasteboardType] = []
    let png: Data
    init(_ png: Data) { self.png = png }
    var reads: [NSPasteboard.PasteboardType] { lock.lock(); defer { lock.unlock() }; return requested }
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        lock.lock(); requested.append(type); lock.unlock()
        item.setData(png, forType: type)
    }
}

private final class ClipboardIPCBlocker: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var armed = false
    private var entered = false
    func arm() { lock.lock(); armed = true; entered = false; lock.unlock() }
    var isBlocked: Bool { lock.lock(); defer { lock.unlock() }; return entered }
    func blockIfArmed() {
        lock.lock()
        guard armed else { lock.unlock(); return }
        armed = false; entered = true; lock.unlock()
        _ = release.wait(timeout: .now() + 5)
    }
    func resume() { release.signal() }
}

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
    func metadataDuringTransfer(_ marker: String?, midChunk: Bool, pollChange: Bool, localImage: Bool = false, protectiveMarker: String? = nil) {
        let source = NSPasteboard(name: .init("ThunderControl.MetadataSource.\(UUID().uuidString)"))
        let target = NSPasteboard(name: .init("ThunderControl.MetadataTarget.\(UUID().uuidString)"))
        let sender = ImageClipboardController(pasteboard: source, enabled: true)
        let receiver = ImageClipboardController(pasteboard: target, enabled: true)
        defer { sender.stop(); receiver.stop(); source.releaseGlobally(); target.releaseGlobally() }
        var forward: [ImageClipboardPacket] = [], backward: [ImageClipboardPacket] = []
        sender.isSafe = { true }; receiver.isSafe = { true }
        sender.send = { forward.append($0); return true }
        receiver.send = { backward.append($0); return true }
        sender.start(); receiver.start()
        for _ in 0..<5 {
            let sent = forward; forward.removeAll(); sent.forEach { receiver.receive($0) }
            let replies = backward; backward.removeAll(); replies.forEach { sender.receive($0) }
            spin(0.01)
        }
        copy(large, source); sender.poll()
        for _ in 0..<100 { if forward.contains(where: { $0.op == .chunk }) { break }; spin(0.005) }
        check(forward.contains { $0.op == .chunk }, "metadata fixture queues real sender PNG")
        if midChunk, let index = forward.firstIndex(where: { $0.op == .chunk }) {
            receiver.receive(sender.sendGate.packetForTransmission(forward.remove(at: index)))
            spin()
        }
        let spy = ClipboardReadSpy(png)
        let item = NSPasteboardItem()
        if let marker {
            item.setDataProvider(spy, forTypes: [.png])
            item.setData(Data(), forType: .init(marker))
        } else if localImage { item.setData(png, forType: .png) }
        else { item.setString("new local copy", forType: .string) }
        if let protectiveMarker { item.setData(Data(), forType: .init(protectiveMarker)) }
        target.clearContents(); target.writeObjects([item])
        let changed = target.changeCount
        if pollChange { receiver.poll() }
        for _ in 0..<100 {
            let sent = forward; forward.removeAll()
            sent.filter { $0.op == .chunk }.forEach { receiver.receive(sender.sendGate.packetForTransmission($0)) }
            let replies = backward; backward.removeAll()
            replies.filter { $0.op == .ack || $0.op == .cancel }.forEach { sender.receive(receiver.sendGate.packetForTransmission($0)) }
            spin(0.002)
        }
        let label = "\(marker ?? (localImage ? "local image" : "local text")) mid=\(midChunk) poll=\(pollChange)"
        let remote = protectiveMarker == nil && (marker == "com.apple.is-remote-clipboard" || marker == ImageClipboardController.receivedImageType.rawValue)
        if remote {
            check(target.changeCount != changed && target.types?.contains(ImageClipboardController.receivedImageType) == true,
                  "remote metadata preserves transfer \(label)")
            if target.changeCount != changed { check(target.data(forType: .png) == large, "remote metadata receives exact PNG \(label)") }
        } else { check(target.changeCount == changed, "local/private clipboard wins \(label)") }
        check(spy.reads.isEmpty, "metadata provider never read \(label)")
    }
    for marker in ["com.apple.is-remote-clipboard", ImageClipboardController.receivedImageType.rawValue] {
        metadataDuringTransfer(marker, midChunk: false, pollChange: false)
        metadataDuringTransfer(marker, midChunk: false, pollChange: true)
        metadataDuringTransfer(marker, midChunk: true, pollChange: false)
        metadataDuringTransfer(marker, midChunk: true, pollChange: true)
    }
    for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"] {
        metadataDuringTransfer(marker, midChunk: false, pollChange: false)
        metadataDuringTransfer(marker, midChunk: true, pollChange: true)
    }
    for origin in ["com.apple.is-remote-clipboard", ImageClipboardController.receivedImageType.rawValue] {
        for protective in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"] {
            metadataDuringTransfer(origin, midChunk: false, pollChange: false, protectiveMarker: protective)
            metadataDuringTransfer(origin, midChunk: true, pollChange: true, protectiveMarker: protective)
        }
    }
    for localImage in [false, true] {

        metadataDuringTransfer(nil, midChunk: false, pollChange: false, localImage: localImage)
        metadataDuringTransfer(nil, midChunk: true, pollChange: true, localImage: localImage)
    }

    copy(png, a)
    let initialB = b.changeCount
    ca.start(); cb.start(); pump()
    check(b.changeCount == initialB, "off never applies")
    ca.setEnabled(true); cb.setEnabled(true); pump()
    check(b.changeCount == initialB, "enable baselines existing image")
    for marker in ["com.apple.is-remote-clipboard", "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType", "local.thundercontrol.received-image"] {
        let spy = ClipboardReadSpy(png)
        let item = NSPasteboardItem()
        item.setDataProvider(spy, forTypes: [.png])
        item.setData(Data(), forType: .init(marker))
        let before = b.changeCount
        a.clearContents(); a.writeObjects([item]); pump(20)
        check(spy.reads.isEmpty && b.changeCount == before, "blocked marker never fetches or exports \(marker)")
    }
    let preferredSpy = ClipboardReadSpy(png)
    let preferredItem = NSPasteboardItem()
    preferredItem.setDataProvider(preferredSpy, forTypes: [.png, .tiff])
    a.clearContents(); a.writeObjects([preferredItem]); pump(40)
    check(preferredSpy.reads == [.png], "PNG advertised never requests TIFF provider")
    copy(png, a); pump(40)
    check(b.data(forType: .png) == png, "A to B exact PNG")
    check(b.types?.contains(.init("local.thundercontrol.received-image")) == true, "received image has local-only marker")
    let delivered = sentA.filter { $0.op == .chunk }.count
    let bCount = b.changeCount
    pump(20)
    check(sentA.filter { $0.op == .chunk }.count == delivered && b.changeCount == bCount, "no echo")
    let beforeMarked = sentB.filter { $0.op == .chunk }.count
    let receivedItem = NSPasteboardItem()
    receivedItem.setData(png, forType: .png)
    receivedItem.setData(Data(), forType: .init("local.thundercontrol.received-image"))
    b.clearContents(); b.writeObjects([receivedItem]); pump(20)
    check(sentB.filter { $0.op == .chunk }.count == beforeMarked, "received marker survives count change without echo")

    copy(large, b); pump(120)
    check(a.data(forType: .png) == large, "B to A chunked exact PNG")
    let chunks = sentB.filter { $0.op == .chunk }
    check(chunks.count > 1 && chunks.allSatisfy { ($0.bytes?.count ?? 0) <= 32768 }, "bounded chunks")
    check(sentA.filter { $0.op == .ack }.count == chunks.count, "one ACK per chunk")
    let bitmap = NSBitmapImageRep(data: png)!
    let beforeTIFF = b.changeCount
    a.clearContents(); a.setData(bitmap.tiffRepresentation!, forType: .tiff)
    let tiffDeadline = Date().addingTimeInterval(2)
    while Date() < tiffDeadline && (b.changeCount == beforeTIFF || b.types?.contains(ImageClipboardController.receivedImageType) != true) { pump(1) }
    let converted = b.data(forType: .png).flatMap { NSBitmapImageRep(data: $0) }
    check(converted?.pixelsWide == 1 && converted?.pixelsHigh == 1 && converted?.colorAt(x: 0, y: 0) == bitmap.colorAt(x: 0, y: 0), "TIFF conversion preserves pixels")
    let beforeReverseTIFF = a.changeCount
    b.clearContents(); b.setData(bitmap.tiffRepresentation!, forType: .tiff)
    let reverseDeadline = Date().addingTimeInterval(2)
    while Date() < reverseDeadline && (a.changeCount == beforeReverseTIFF || a.types?.contains(ImageClipboardController.receivedImageType) != true) { pump(1) }
    let reverseConverted = a.data(forType: .png).flatMap { NSBitmapImageRep(data: $0) }
    check(reverseConverted?.colorAt(x: 0, y: 0) == bitmap.colorAt(x: 0, y: 0), "reverse TIFF conversion preserves pixels")
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
    c.receive(.init(op: .consent, epoch: e, enabled: true)); spin()
    let localEpoch = cPackets.last { $0.op == .consent }!.epoch
    let first = ImageClipboardPacket(op: .chunk, epoch: e, peerEpoch: localEpoch, id: id,
                                     offset: 0, totalBytes: large.count, bytes: large.prefix(32768))
    let beforeOrder = a.changeCount
    var outOfOrder = first; outOfOrder.offset = 1
    c.receive(outOfOrder); spin()
    check(a.changeCount == beforeOrder && cPackets.last?.op == .cancel, "first chunk ordering")
    c.receive(first); spin()
    a.clearContents(); a.setString("new local wins", forType: .string)
    var second = first; second.offset = 32768; second.bytes = large.subdata(in: 32768..<65536)
    c.receive(second); spin()
    check(a.string(forType: .string) == "new local wins", "incoming newer local copy wins")
    c.poll()
    let beforeInvalid = a.changeCount
    c.receive(.init(op: .chunk, epoch: e, peerEpoch: localEpoch, id: UUID().uuidString,
                    offset: 0, totalBytes: 4, bytes: Data([1, 2, 3, 4])))
    spin()
    check(a.changeCount == beforeInvalid, "non-image payload rejected")
    copy(large, a); c.poll()
    for _ in 0..<60 { spin(0.005); if cPackets.contains(where: { $0.op == .chunk }) { break } }
    let pending = cPackets.last { $0.op == .chunk }
    check(pending != nil, "timeout transfer starts")
    if let pending {
        let countBeforeACK = cPackets.filter { $0.op == .chunk }.count
        c.receive(.init(op: .ack, epoch: e, peerEpoch: localEpoch, id: pending.id, offset: 1))
        spin()
        check(cPackets.filter { $0.op == .chunk }.count == countBeforeACK, "wrong ACK never advances")
        spin(10.25); c.poll()
        check(cPackets.contains { $0.op == .cancel && $0.id == pending.id }, "ten-second timeout cancels")
        check(c.sendGate.packetForTransmission(pending).op == .cancel, "timeout releases queued payload")
        let previousID = pending.id
        copy(png, a); c.poll()
        for _ in 0..<80 { spin(0.005); if cPackets.contains(where: { $0.op == .chunk && $0.id != previousID }) { break } }
        let quarantinePacket = cPackets.last { $0.op == .chunk && $0.id != previousID }
        check(quarantinePacket != nil, "quarantine fixture queues live image")
        if let pending = quarantinePacket {
            c.sendGate.revoke()
            let synchronouslyRevoked = c.sendGate.packetForTransmission(pending)
            check(synchronouslyRevoked.op == .cancel && synchronouslyRevoked.id == pending.id && synchronouslyRevoked.epoch == pending.epoch && synchronouslyRevoked.peerEpoch == pending.peerEpoch && synchronouslyRevoked.bytes == nil, "synchronous quarantine revokes queued image")
            check(c.sendGate.packetForTransmission(.init(op: .consent, epoch: localEpoch, enabled: true)).enabled == false, "synchronous quarantine revokes consent")
        }
    }
    c.stop(); spin()
    for mode in 0..<5 {
        let revoke = mode != 0
        let board = NSPasteboard(name: .init("ThunderControl.BlockedClipboard.\(UUID().uuidString)"))
        let blocker = ClipboardIPCBlocker()
        let controller = ImageClipboardController(pasteboard: board, enabled: true, beforeWorkerIPC: { blocker.blockIfArmed() })
        var packets: [ImageClipboardPacket] = []
        var callbacksOnMain = true
        var safe = true
        controller.isSafe = { callbacksOnMain = callbacksOnMain && Thread.isMainThread; return safe }
        controller.send = { callbacksOnMain = callbacksOnMain && Thread.isMainThread; packets.append($0); return true }
        controller.onStatus = { _ in callbacksOnMain = callbacksOnMain && Thread.isMainThread }
        controller.start(); spin()
        let peer = UUID().uuidString
        controller.receive(.init(op: .consent, epoch: peer, enabled: true)); spin()
        let local = packets.last { $0.op == .consent }!.epoch
        blocker.arm()
        let transferID = UUID().uuidString
        controller.receive(.init(op: .chunk, epoch: peer, peerEpoch: local, id: transferID, offset: 0, totalBytes: png.count, bytes: png))
        for _ in 0..<100 { if blocker.isBlocked { break }; spin(0.002) }
        check(blocker.isBlocked, "synthetic clipboard IPC entered off main")
        var heartbeat = false
        DispatchQueue.main.async { heartbeat = true }
        spin(0.01)
        check(heartbeat, "main responsive while clipboard IPC blocked")
        if mode == 0 { board.clearContents(); board.setString("new local wins", forType: .string) }
        let count = board.changeCount
        if mode == 1 { controller.setEnabled(false) }
        if mode == 2 { controller.stop() }
        if mode == 3 { controller.sendGate.revoke() }
        if mode == 4 {
            safe = false; controller.poll()
            controller.sendGate.revoke(); controller.poll()
            controller.sendGate.revoke(); controller.poll()
        }
        check(!revoke || controller.sendGate.packetForTransmission(.init(op: .consent, epoch: local, enabled: true)).enabled == false,
              "OFF revokes synchronously during blocked clipboard IPC")
        blocker.resume(); spin(0.1)
        check(board.changeCount == count && (mode != 0 || board.string(forType: .string) == "new local wins"), "blocked clipboard never writes after revoke/new copy \(mode)")
        check(!packets.contains { $0.op == .ack && $0.id == transferID }, "blocked stale write never ACKs \(mode)")
        if mode == 3 {
            controller.poll(); spin(0.05)
            check(controller.sendGate.packetForTransmission(.init(op: .consent, epoch: local, enabled: true)).enabled == false,
                  "continuously safe polling never rearms external revocation")
        }
        if mode == 4 {
            let consentCount = packets.filter { $0.op == .consent }.count
            safe = true; controller.poll(); spin(0.05)
            check(packets.filter { $0.op == .consent }.count > consentCount, "repeated unsafe revocation recovers consent")
            let recoveredLocal = packets.last { $0.op == .consent }!.epoch
            let recoveredPeer = UUID().uuidString
            controller.receive(.init(op: .consent, epoch: recoveredPeer, enabled: true)); spin(0.05)
            copy(png, board); controller.poll()
            for _ in 0..<100 { if packets.contains(where: { $0.op == .chunk }) { break }; spin(0.005) }
            check(packets.contains { $0.op == .chunk && controller.sendGate.packetForTransmission($0).bytes == png },
                  "fresh image copy sends after repeated unsafe revocation")
            controller.receive(.init(op: .chunk, epoch: recoveredPeer, peerEpoch: recoveredLocal, id: UUID().uuidString,
                                     offset: 0, totalBytes: png.count, bytes: png))
            spin(0.1)
            check(board.data(forType: .png) == png && board.types?.contains(ImageClipboardController.receivedImageType) == true,
                  "fresh image writes after repeated unsafe revocation")
        }
        check(callbacksOnMain, "safety send and status callbacks remain main")
        controller.stop(); spin(); board.releaseGlobally()
    }
    print("ImageClipboardTests: \(failures) failures")
    return failures
}
