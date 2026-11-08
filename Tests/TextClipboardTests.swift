import AppKit

/// Records which representations a pasteboard provider was asked for; contents never leave the test.
private final class TextReadSpy: NSObject, NSPasteboardItemDataProvider {
    private let lock = NSLock()
    private var requested: [NSPasteboard.PasteboardType] = []
    let values: [NSPasteboard.PasteboardType: Data]
    init(_ values: [NSPasteboard.PasteboardType: Data]) { self.values = values }
    var reads: [NSPasteboard.PasteboardType] { lock.lock(); defer { lock.unlock() }; return requested }
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        lock.lock(); requested.append(type); lock.unlock()
        item.setData(values[type] ?? Data(), forType: type)
    }
}

private enum Sent { case image(ImageClipboardPacket), text(TextClipboardPacket) }

/// Two controllers on named pasteboards only; never touches the general pasteboard.
@MainActor private final class TextPair {
    let a: NSPasteboard, b: NSPasteboard
    let ca: ImageClipboardController, cb: ImageClipboardController
    var qa: [Sent] = [], qb: [Sent] = []
    var sentA: [Sent] = [], sentB: [Sent] = []
    var textStatusA: [String] = []
    init(imageA: Bool = false, textA: Bool = true, imageB: Bool = false, textB: Bool = true, textSupportedB: Bool = true) {
        a = NSPasteboard(name: .init("ThunderControl.TextClipboardTests.A.\(UUID().uuidString)"))
        b = NSPasteboard(name: .init("ThunderControl.TextClipboardTests.B.\(UUID().uuidString)"))
        ca = ImageClipboardController(pasteboard: a, enabled: imageA, textEnabled: textA, textSupported: textSupportedB)
        cb = ImageClipboardController(pasteboard: b, enabled: imageB, textEnabled: textB, textSupported: textSupportedB)
        ca.isSafe = { true }; cb.isSafe = { true }
        ca.send = { [unowned self] in qa.append(.image($0)); sentA.append(.image($0)); return true }
        ca.sendText = { [unowned self] in qa.append(.text($0)); sentA.append(.text($0)); return true }
        cb.send = { [unowned self] in qb.append(.image($0)); sentB.append(.image($0)); return true }
        cb.sendText = { [unowned self] in qb.append(.text($0)); sentB.append(.text($0)); return true }
        ca.onTextStatus = { [unowned self] in textStatusA.append($0) }
        ca.start(); cb.start()
    }
    func spin(_ d: TimeInterval = 0.005) { RunLoop.current.run(until: Date().addingTimeInterval(d)) }
    func deliver(_ packets: [Sent], from: ImageClipboardController, to: ImageClipboardController) {
        for p in packets {
            switch p {
            case .image(let x): to.receive(from.sendGate.packetForTransmission(x))
            case .text(let x): to.receive(from.sendGate.packetForTransmission(x))
            }
        }
    }
    func pump(_ rounds: Int = 20) {
        for _ in 0..<rounds {
            let aa = qa; qa.removeAll(); deliver(aa, from: ca, to: cb)
            let bb = qb; qb.removeAll(); deliver(bb, from: cb, to: ca)
            ca.poll(); cb.poll(); spin()
        }
    }
    func pumpUntil(_ rounds: Int = 400, _ done: () -> Bool) { for _ in 0..<rounds { if done() { return }; pump(1) } }
    var textChunksA: Int { sentA.filter { if case .text(let p) = $0 { return p.op == .chunk }; return false }.count }
    var textChunksB: Int { sentB.filter { if case .text(let p) = $0 { return p.op == .chunk }; return false }.count }
    var textAnyA: Int { sentA.filter { if case .text = $0 { return true }; return false }.count }
    func close() { ca.stop(); cb.stop(); a.releaseGlobally(); b.releaseGlobally() }
}

@MainActor func runTextClipboardTests() -> Int {
    var failures = 0
    func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        if !condition() { failures += 1; print("FAIL TextClipboard: \(name)") }
    }
    let marker = ImageClipboardController.receivedImageType
    let sample = Data("  line1\n\ttab 한글 👩‍👩‍👧‍👦 end\u{0} \r\n".utf8)
    func copyText(_ data: Data, _ board: NSPasteboard) { board.clearContents(); _ = board.setData(data, forType: .string) }

    // Bidirectional exact text, own marker, no echo.
    do {
        let t = TextPair(); defer { t.close() }
        t.pump()
        check(t.textStatusA.contains("Text clipboard ready"), "ready status after both text consents")
        copyText(sample, t.a)
        t.pumpUntil { t.b.data(forType: .string) == sample }
        check(t.b.data(forType: .string) == sample, "A to B exact whitespace/Korean/emoji/NUL")
        check(t.b.types?.contains(marker) == true, "received text carries own marker")
        check((t.b.pasteboardItems ?? []).count == 1 && !(t.b.types ?? []).contains { [.html, .rtf, .png, .fileURL].contains($0) },
              "received item is one plain string item plus marker")
        let chunksB = t.textChunksB
        t.pump(20)
        check(t.textChunksB == chunksB, "received text is not echoed back")
        let back = Data("B → A 회신 ✅".utf8)
        copyText(back, t.b)
        t.pumpUntil { t.a.data(forType: .string) == back }
        check(t.a.data(forType: .string) == back, "B to A exact")
        check(!t.sentA.contains { if case .image(let p) = $0 { return p.op != .consent }; return false }, "text never rides image packets")
    }
    // One side text OFF: no provider reads, no text chunks.
    for (textA, textB) in [(true, false), (false, true)] {
        let t = TextPair(textA: textA, textB: textB); defer { t.close() }
        t.pump()
        let spy = TextReadSpy([.string: sample])
        let item = NSPasteboardItem(); item.setDataProvider(spy, forTypes: [.string])
        t.a.clearContents(); t.a.writeObjects([item])
        t.pump(20)
        check(spy.reads.isEmpty && t.textChunksA == 0, "no text read or send when one side off a=\(textA) b=\(textB)")
        check(t.b.changeCount >= 0 && t.b.data(forType: .string) == nil, "receiver unchanged when consent missing")
    }
    // Image consent never implies text; old peer receives image packets only.
    do {
        let t = TextPair(imageA: true, textA: false, imageB: true, textB: true); defer { t.close() }
        t.pump()
        copyText(sample, t.a); t.pump(20)
        check(t.textChunksA == 0, "image ON does not enable text")
    }
    do {
        let t = TextPair(imageA: true, textA: true, imageB: true, textB: true, textSupportedB: false); defer { t.close() }
        t.pump()
        copyText(sample, t.a); t.pump(20)
        check(t.textAnyA == 0, "no text packet or consent to an image-only (0.9.10) peer")
        check(t.sentA.contains { if case .image(let p) = $0 { return p.op == .consent && p.enabled == true }; return false }, "old peer still gets image consent")
    }
    // Private, remote, own and file-like mixes are never read.
    for extra in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
                  "com.apple.is-remote-clipboard", marker.rawValue, NSPasteboard.PasteboardType.fileURL.rawValue,
                  "com.apple.pasteboard.promised-file-url"] {
        let t = TextPair(); defer { t.close() }
        t.pump()
        let spy = TextReadSpy([.string: Data("/Users/secret/path".utf8)])
        let item = NSPasteboardItem(); item.setDataProvider(spy, forTypes: [.string])
        item.setData(Data("x".utf8), forType: .init(extra))
        t.a.clearContents(); t.a.writeObjects([item])
        t.pump(15)
        check(spy.reads.isEmpty && t.textChunksA == 0, "no provider read for \(extra)")
    }
    // Image wins when both kinds are allowed (no text fallback); image OFF reads plain text only.
    do {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32)!
        let png = rep.representation(using: .png, properties: [:])!
        for imageOn in [true, false] {
            let t = TextPair(imageA: imageOn, textA: true, imageB: imageOn, textB: true); defer { t.close() }
            t.pump()
            let spy = TextReadSpy([.png: png, .string: sample, .html: Data("<b>x</b>".utf8), .rtf: Data("{\\rtf1}".utf8)])
            let item = NSPasteboardItem(); item.setDataProvider(spy, forTypes: [.png, .string, .html, .rtf])
            t.a.clearContents(); t.a.writeObjects([item])
            t.pumpUntil(200) { t.b.data(forType: imageOn ? .png : .string) != nil }
            if imageOn {
                check(spy.reads == [.png], "image wins with one provider read")
                check(t.textChunksA == 0, "no text fallback when image selected")
            } else {
                check(spy.reads == [.string], "image off reads only plain string, never HTML/RTF")
                check(t.b.data(forType: .string) == sample, "plain text received with formatted source")
            }
        }
        // Image fails validation: still no text fallback.
        let t = TextPair(imageA: true, textA: true, imageB: true, textB: true); defer { t.close() }
        t.pump()
        let spy = TextReadSpy([.png: Data("not png".utf8), .string: sample])
        let item = NSPasteboardItem(); item.setDataProvider(spy, forTypes: [.png, .string])
        t.a.clearContents(); t.a.writeObjects([item])
        t.pump(20)
        check(spy.reads == [.png] && t.textChunksA == 0, "invalid image does not fall back to text")
    }
    // Empty, size limits and invalid UTF-8.
    do {
        let t = TextPair(); defer { t.close() }
        t.pump()
        for (data, label) in [(Data(), "empty"), (Data([0xff, 0xfe, 0x41]), "invalid UTF-8"),
                              (Data(repeating: 0x61, count: TextClipboardPacket.maxBytes + 1), "1 MiB + 1")] {
            let before = t.textChunksA
            copyText(data, t.a); t.pump(15)
            check(t.textChunksA == before, "\(label) not sent")
        }
        // Multi-byte code points split across 32 KiB chunks assemble exactly at 1 MiB.
        let unit = Data("한".utf8)
        var big = Data(); while big.count + unit.count <= TextClipboardPacket.maxBytes { big.append(unit) }
        while big.count < TextClipboardPacket.maxBytes { big.append(0x20) }
        copyText(big, t.a)
        t.pumpUntil(600) { t.b.data(forType: .string) == big }
        check(t.b.data(forType: .string) == big, "exact 1 MiB with split code points")
        check(!ImageClipboardWorkerProbe.validText(Data([0xed, 0x95])), "truncated code point rejected")
    }
    // Forged image-kind ACK/cancel with the text id cannot touch the text transfer.
    do {
        let t = TextPair(); defer { t.close() }
        t.pump()
        copyText(Data(repeating: 0x62, count: 70000), t.a)
        t.pumpUntil(100) { t.qa.contains { if case .text(let p) = $0 { return p.op == .chunk }; return false } }
        guard case .text(let chunk)? = t.qa.first(where: { if case .text(let p) = $0 { return p.op == .chunk }; return false }) else {
            check(false, "text chunk fixture"); return failures
        }
        let forgedAck = ImageClipboardPacket(op: .ack, epoch: chunk.peerEpoch!, peerEpoch: chunk.epoch, id: chunk.id, offset: 32768)
        check(t.cb.sendGate.packetForTransmission(forgedAck).op == .cancel, "image gate cancels text ack id")
        t.ca.receive(forgedAck); t.spin(0.05)
        let chunksBefore = t.textChunksA
        t.spin(0.05)
        check(t.textChunksA == chunksBefore, "image ack does not advance text transfer")
        let stale = t.ca.sendGate.packetForTransmission(ImageClipboardPacket(op: .chunk, epoch: chunk.epoch, peerEpoch: chunk.peerEpoch,
            id: chunk.id, offset: 0, totalBytes: 70000, bytes: Data(repeating: 0x62, count: 32768)))
        check(stale.op == .cancel && stale.bytes == nil, "text bytes cannot leave as image chunk")
        t.ca.setTextEnabled(false)
        let revoked = t.ca.sendGate.packetForTransmission(chunk)
        check(revoked.op == .cancel && revoked.bytes == nil && revoked.format == "utf8", "OFF converts queued text chunk to same-kind cancel")
        // Repeated toggles must keep working (0.9.8 revision regression).
        for _ in 0..<3 { t.ca.setTextEnabled(true); t.pump(4); t.ca.setTextEnabled(false); t.pump(4) }
        t.ca.setTextEnabled(true); t.pump()
        let again = Data("again".utf8)
        copyText(again, t.a); t.pumpUntil { t.b.data(forType: .string) == again }
        check(t.b.data(forType: .string) == again, "text works after repeated toggles")
    }
    // A new local copy of either kind wins over an incoming text transfer.
    do {
        let t = TextPair(); defer { t.close() }
        t.pump()
        copyText(Data(repeating: 0x63, count: 100000), t.a)
        t.pumpUntil(100) { t.qa.contains { if case .text(let p) = $0 { return p.op == .chunk }; return false } }
        let first = t.qa; t.qa.removeAll(); t.deliver(first, from: t.ca, to: t.cb); t.spin(0.05)
        let local = Data("local wins".utf8)
        copyText(local, t.b)
        t.pump(40)
        check(t.b.data(forType: .string) == local, "local copy wins during incoming text")
    }
    // Packet validation.
    let e = UUID().uuidString, pe = UUID().uuidString, id = UUID().uuidString
    var tp = TextClipboardPacket(ImageClipboardPacket(op: .chunk, epoch: e, peerEpoch: pe, id: id, offset: 0, totalBytes: 10, bytes: Data([1])))
    check(tp.valid, "text chunk valid")
    tp.format = "utf16"; check(!tp.valid, "unknown format rejected")
    let big = TextClipboardPacket(ImageClipboardPacket(op: .chunk, epoch: e, peerEpoch: pe, id: id, offset: 0, totalBytes: TextClipboardPacket.maxBytes + 1, bytes: Data([1])))
    check(!big.valid, "text total above 1 MiB rejected")
    for op in [ImageClipboardPacket.Operation.consent, .ack, .cancel] {
        let body = op == .consent ? ImageClipboardPacket(op: op, epoch: e, enabled: true)
            : ImageClipboardPacket(op: op, epoch: e, peerEpoch: pe, id: id, offset: op == .ack ? 1 : nil)
        let json = String(data: try! JSONEncoder().encode(TextClipboardPacket(body)), encoding: .utf8)!
        check(json.contains("\"format\":\"utf8\""), "format on every text op \(op)")
    }
    print("Text clipboard: \(failures) failures; named pasteboards only")
    return failures
}
