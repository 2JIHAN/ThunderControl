import AppKit
import ImageIO
import UniformTypeIdentifiers

/// One serial pasteboard worker carries both kinds; each kind has its own consent and wire envelope.
enum ClipboardTransferKind: Sendable { case png, textUTF8 }

struct ImageClipboardPacket: Codable, Equatable {
    enum Operation: String, Codable { case consent, chunk, ack, cancel }
    var op: Operation
    var epoch: String
    var peerEpoch: String? = nil
    var enabled: Bool? = nil
    var id: String? = nil
    var offset: Int? = nil
    var totalBytes: Int? = nil
    var bytes: Data? = nil
    var valid: Bool { valid(maxTotal: 8388608) }
    func valid(maxTotal: Int) -> Bool {
        func uuid(_ s: String?) -> Bool { guard let s else { return false }; return UUID(uuidString: s)?.uuidString == s }
        guard uuid(epoch) else { return false }
        if op == .consent {
            return enabled != nil && peerEpoch == nil && id == nil && offset == nil && totalBytes == nil && bytes == nil
        }
        guard uuid(peerEpoch), uuid(id), enabled == nil else { return false }
        switch op {
        case .chunk:
            guard let offset, let totalBytes, let bytes else { return false }
            return (1...32768).contains(bytes.count) && (1...maxTotal).contains(totalBytes) && offset >= 0 && offset <= totalBytes - bytes.count
        case .ack:
            return offset.map { (1...maxTotal).contains($0) } == true && totalBytes == nil && bytes == nil
        case .cancel:
            return offset == nil && totalBytes == nil && bytes == nil
        case .consent: return false
        }
    }
}

/// Distinct wire packet for plain UTF-8 text; the legacy image packet stays byte-for-byte unchanged.
struct TextClipboardPacket: Codable, Equatable {
    static let maxBytes = 1048576
    var format: String
    var op: ImageClipboardPacket.Operation
    var epoch: String
    var peerEpoch: String? = nil
    var enabled: Bool? = nil
    var id: String? = nil
    var offset: Int? = nil
    var totalBytes: Int? = nil
    var bytes: Data? = nil
    init(_ body: ImageClipboardPacket) {
        format = "utf8"; op = body.op; epoch = body.epoch; peerEpoch = body.peerEpoch; enabled = body.enabled
        id = body.id; offset = body.offset; totalBytes = body.totalBytes; bytes = body.bytes
    }
    var body: ImageClipboardPacket {
        .init(op: op, epoch: epoch, peerEpoch: peerEpoch, enabled: enabled, id: id, offset: offset, totalBytes: totalBytes, bytes: bytes)
    }
    var valid: Bool { format == "utf8" && body.valid(maxTotal: Self.maxBytes) }
}

final class ImageClipboardSendGate: @unchecked Sendable {
    private let lock = NSLock()
    private var epoch: String
    private var consents: Set<ClipboardTransferKind> = []
    private var peer: String?
    private var allowed: Set<ClipboardTransferKind> = []
    private var outgoing: (id: String, kind: ClipboardTransferKind)?
    private var incoming: (id: String, kind: ClipboardTransferKind)?
    private var revision = 0
    var currentRevision: Int { lock.lock(); defer { lock.unlock() }; return revision }
    init() { epoch = UUID().uuidString }
    fileprivate func update(revision: Int, epoch: String, consents: Set<ClipboardTransferKind>, peer: String?,
                            allowed: Set<ClipboardTransferKind>, outgoing: (String, ClipboardTransferKind)?,
                            incoming: (String, ClipboardTransferKind)?) {
        lock.lock(); defer { lock.unlock() }
        guard revision == self.revision else { return }
        self.epoch = epoch; self.consents = consents
        self.peer = peer; self.allowed = allowed; self.outgoing = outgoing; self.incoming = incoming
    }
    /// Revokes both kinds at once; every root guard calls this synchronously.
    func revoke(renewEpoch: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        revision += 1; allowed = []; consents = []; outgoing = nil; incoming = nil
        if renewEpoch { epoch = UUID().uuidString }
    }
    func mayRead(epoch: String, peerEpoch: String, kind: ClipboardTransferKind = .png) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return allowed.contains(kind) && self.epoch == epoch && peer == peerEpoch
    }
    func packetForTransmission(_ original: ImageClipboardPacket) -> ImageClipboardPacket { transmit(original, kind: .png) }
    func packetForTransmission(_ original: TextClipboardPacket) -> TextClipboardPacket {
        TextClipboardPacket(transmit(original.body, kind: .textUTF8, valid: original.valid))
    }
    private func transmit(_ original: ImageClipboardPacket, kind: ClipboardTransferKind, valid: Bool? = nil) -> ImageClipboardPacket {
        lock.lock(); defer { lock.unlock() }
        if original.op == .consent { return .init(op: .consent, epoch: epoch, enabled: consents.contains(kind)) }
        let bound = allowed.contains(kind) && (valid ?? original.valid) && original.epoch == epoch && original.peerEpoch == peer
        let current = original.op == .chunk ? (outgoing?.id == original.id && outgoing?.kind == kind)
            : original.op == .ack ? (incoming?.id == original.id && incoming?.kind == kind) : true
        if bound && current { return original }
        // Preserve the outer sequence slot, but never retain revoked clipboard bytes.
        return .init(op: .cancel, epoch: original.epoch, peerEpoch: original.peerEpoch, id: original.id)
    }
}

private final class ImageClipboardWorker: @unchecked Sendable {
    typealias Kind = ClipboardTransferKind
    let queue: DispatchQueue
    var revision = 0
    var currentSafe = false
    var beforeIPC: (() -> Void)?
    var isCurrent: Bool { sendGate.currentRevision == revision }
    var send: ((Kind, ImageClipboardPacket) -> Bool)?
    var isSafe: () -> Bool { { self.currentSafe && self.isCurrent } }
    var onStatus: ((Kind, String) -> Void)?
    let sendGate: ImageClipboardSendGate
    nonisolated static let receivedImageType = NSPasteboard.PasteboardType("local.thundercontrol.received-image")
    nonisolated private static func blocked(_ types: [NSPasteboard.PasteboardType]) -> Bool {
        let markers = ["com.apple.is-remote-clipboard", "org.nspasteboard.ConcealedType",
                       "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
                       receivedImageType.rawValue]
        return types.contains { markers.contains($0.rawValue) }
    }
    /// Finder copies expose the path as .string; never share text from file or promise items.
    nonisolated private static func fileLike(_ types: [NSPasteboard.PasteboardType]) -> Bool {
        types.contains { type in
            let raw = type.rawValue
            return raw == NSPasteboard.PasteboardType.fileURL.rawValue || raw == "NSFilenamesPboardType"
                || raw == "Apple URL pasteboard type" || raw.lowercased().contains("promise")
        }
    }
    private let boardName: String
    private lazy var board = NSPasteboard(name: .init(boardName))
    private var enabled: Set<Kind>
    private let supported: Set<Kind>
    private var running = false
    private var safe = false
    private var active: Set<Kind> = []
    private var epoch = UUID().uuidString
    private var peerEpoch: String?
    private var peerEnabled: Set<Kind> = []
    private var retiredEpochs: [String] = []
    nonisolated private static let conversionPermit = DispatchSemaphore(value: 1)
    private var seenCount: Int?
    private var generation = 0
    private var converting = false
    private var ack: (id: String, kind: Kind)?
    private struct Outgoing {
        var id: String; var kind: Kind; var data: Data; var offset = 0; var pending = 0; var touched = Date()
    }
    private struct Incoming {
        var id: String; var kind: Kind; var total: Int; var count: Int; var data = Data(); var touched = Date()
    }
    private var outgoing: Outgoing?
    private var incoming: Incoming?

    init(boardName: String, enabled: Set<Kind>, supported: Set<Kind>, gate: ImageClipboardSendGate, queue: DispatchQueue) {
        self.boardName = boardName; self.enabled = enabled; self.supported = supported; self.sendGate = gate; self.queue = queue
    }
    private func updateGate() {
        let consents = running && safe ? enabled.intersection(supported) : []
        sendGate.update(revision: revision, epoch: epoch, consents: consents, peer: peerEpoch,
                        allowed: running && safe ? active : [],
                        outgoing: outgoing.map { ($0.id, $0.kind) }, incoming: ack.map { ($0.id, $0.kind) })
    }
    private func clearTransfers() {
        generation += 1; outgoing = nil; incoming = nil; ack = nil; updateGate()
    }
    private func reconcile() {
        let nowSafe = running && isSafe()
        if nowSafe != safe {
            safe = nowSafe; active = []; seenCount = nil; peerEpoch = nil; peerEnabled = []
            epoch = UUID().uuidString; clearTransfers()
            if safe { sendConsent() }
        }
        let next: Set<Kind> = running && safe && peerEpoch != nil ? enabled.intersection(supported).intersection(peerEnabled) : []
        if next != active {
            let textChanged = next.contains(.textUTF8) != active.contains(.textUTF8)
            active = next; clearTransfers()
            // "Ready" only when both capabilities, both text consents, epochs and the safe context agree.
            if textChanged, supported.contains(.textUTF8) {
                onStatus?(.textUTF8, active.contains(.textUTF8) ? "Text clipboard ready"
                          : enabled.contains(.textUTF8) ? "Text clipboard: waiting for both Macs to update and enable text sharing." : "Text clipboard off")
            }
            seenCount = active.isEmpty ? nil : board.changeCount
            snapshotCount = seenCount
        }
        updateGate()
    }
    private func emit(_ kind: Kind, _ packet: ImageClipboardPacket) -> Bool {
        let limit = kind == .png ? 8388608 : TextClipboardPacket.maxBytes
        guard running, safe, isSafe(), supported.contains(kind), packet.valid(maxTotal: limit) else { return false }
        return send?(kind, packet) ?? false
    }
    private func sendConsent() {
        updateGate()
        // Legacy order: image consent first, so 0.9.10 peers see the exact old frames.
        for kind in [Kind.png, .textUTF8] where supported.contains(kind) {
            _ = emit(kind, .init(op: .consent, epoch: epoch, enabled: enabled.contains(kind)))
        }
    }
    func start() {
        guard !running else { return }
        running = true; reconcile()
    }
    func stop() {
        guard running else { return }
        active = []; clearTransfers()
        for kind in [Kind.png, .textUTF8] where supported.contains(kind) {
            _ = emit(kind, .init(op: .consent, epoch: epoch, enabled: false))
        }
        running = false; safe = false; epoch = UUID().uuidString
        peerEpoch = nil; peerEnabled = []; seenCount = nil
        updateGate()
    }
    func setEnabled(_ value: Bool, kind: Kind) {
        guard enabled.contains(kind) != value else { return }
        if value { enabled.insert(kind) } else { enabled.remove(kind) }
        epoch = UUID().uuidString; active = []; seenCount = nil
        clearTransfers(); reconcile(); sendConsent()
        if supported.contains(kind) {
            onStatus?(kind, kind == .png ? (value ? "Image clipboard enabled" : "Image clipboard off")
                                         : (value ? "Text clipboard enabled" : "Text clipboard off"))
        }
    }
    private func cancel(_ id: String, _ kind: Kind) {
        guard let peerEpoch else { return }
        _ = emit(kind, .init(op: .cancel, epoch: epoch, peerEpoch: peerEpoch, id: id))
    }
    private func rebaseRemoteMetadata() {
        let count = board.changeCount
        guard count != seenCount, let types = board.types,
              types.contains(.init("com.apple.is-remote-clipboard")) || types.contains(Self.receivedImageType),
              !types.contains(where: { ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
                                        "org.nspasteboard.AutoGeneratedType"].contains($0.rawValue) }),
              incoming == nil || incoming?.count == seenCount,
              board.changeCount == count, board.types == types, board.changeCount == count else { return }
        // Only origin metadata can advance an incoming transfer's local-copy baseline.
        seenCount = count; snapshotCount = count; incoming?.count = count
        if let outgoing { cancel(outgoing.id, outgoing.kind); self.outgoing = nil; updateGate() }
    }
    private func status(_ kind: Kind, _ image: String, _ text: String) { onStatus?(kind, kind == .png ? image : text) }
    func poll() {
        guard running else { return }
        reconcile()
        guard !active.isEmpty, isSafe() else { return }
        beforeIPC?()
        guard isCurrent else { return }
        rebaseRemoteMetadata()
        let count = board.changeCount
        if count != seenCount {
            if let outgoing { cancel(outgoing.id, outgoing.kind) }
            if let incoming { cancel(incoming.id, incoming.kind) }
            clearTransfers(); seenCount = count
        }
        let now = Date()
        if let outgoing, now.timeIntervalSince(outgoing.touched) >= 10 {
            cancel(outgoing.id, outgoing.kind); self.outgoing = nil; updateGate()
            status(outgoing.kind, "Image clipboard timed out", "Text clipboard timed out")
        }
        if let incoming, now.timeIntervalSince(incoming.touched) >= 10 { cancel(incoming.id, incoming.kind); self.incoming = nil; ack = nil; updateGate() }
        if outgoing?.pending == 0 { sendNext() }
        guard !converting, outgoing == nil, count != snapshotCount else { return }
        guard let types = board.types, !Self.blocked(types) else { snapshotCount = count; return }
        // Exactly one representation is ever requested: an allowed image wins without text fallback.
        let type: NSPasteboard.PasteboardType, kind: Kind
        if active.contains(.png), types.contains(.png) || types.contains(.tiff) {
            type = types.contains(.png) ? .png : .tiff; kind = .png
        } else if active.contains(.textUTF8), types.contains(.string), !Self.fileLike(types) {
            type = .string; kind = .textUTF8
        } else { snapshotCount = count; return }
        // A promised representation can invoke Handoff. Never request a second format eagerly.
        guard Self.conversionPermit.wait(timeout: .now()) == .success else { return }
        snapshotCount = count
        let token = generation, readEpoch = epoch, readPeer = peerEpoch!
        let boardName = board.name.rawValue, gate = sendGate
        converting = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { Self.conversionPermit.signal() }
            let result: Data? = autoreleasepool {
                // Use a worker-local object; no main-thread pasteboard object crosses this boundary.
                func usable(_ types: [NSPasteboard.PasteboardType]?) -> Bool {
                    guard let types, !Self.blocked(types), types.contains(type) else { return false }
                    return kind == .png || !Self.fileLike(types)
                }
                guard gate.mayRead(epoch: readEpoch, peerEpoch: readPeer, kind: kind) else { return nil }
                let workerBoard = NSPasteboard(name: .init(boardName))
                guard workerBoard.changeCount == count, usable(workerBoard.types),
                      gate.mayRead(epoch: readEpoch, peerEpoch: readPeer, kind: kind) else { return nil }
                let data = workerBoard.data(forType: type)
                guard workerBoard.changeCount == count, usable(workerBoard.types),
                      gate.mayRead(epoch: readEpoch, peerEpoch: readPeer, kind: kind),
                      let data, data.count <= 67108864 else { return nil }
                if kind == .textUTF8 { return Self.validText(data) ? data : nil }
                return Self.canonicalPNG(png: type == .png ? data : nil, tiff: type == .tiff ? data : nil)
            }
            self?.queue.async { [weak self] in
                guard let self else { return }
                self.converting = false
                self.reconcile()
                guard self.active.contains(kind), self.isSafe(), self.generation == token,
                      self.board.changeCount == count, let result else { return }
                self.outgoing = Outgoing(id: UUID().uuidString, kind: kind, data: result)
                self.updateGate(); self.sendNext()
            }
        }
    }
    private var snapshotCount: Int? // Last snapshot attempted, including unsupported clipboard contents.
    private func sendNext() {
        reconcile()
        guard var transfer = outgoing, active.contains(transfer.kind), isSafe(), transfer.pending == 0, let peerEpoch else { return }
        guard board.changeCount == seenCount else { poll(); return }
        let end = min(transfer.offset + 32768, transfer.data.count)
        let packet = ImageClipboardPacket(op: .chunk, epoch: epoch, peerEpoch: peerEpoch, id: transfer.id,
                                         offset: transfer.offset, totalBytes: transfer.data.count,
                                         bytes: transfer.data.subdata(in: transfer.offset..<end))
        transfer.pending = end; outgoing = transfer; updateGate()
        if emit(transfer.kind, packet) { outgoing?.touched = Date() }
        else { outgoing?.pending = 0; updateGate(); status(transfer.kind, "Image clipboard unavailable", "Text clipboard unavailable") }
    }
    func receive(_ packet: ImageClipboardPacket, kind: Kind) {
        guard running else { return }
        reconcile()
        guard safe, isSafe(), supported.contains(kind),
              packet.valid(maxTotal: kind == .png ? 8388608 : TextClipboardPacket.maxBytes) else { return }
        if packet.op == .consent {
            guard !retiredEpochs.contains(packet.epoch) else { return }
            let changed = packet.epoch != peerEpoch
            if changed || (packet.enabled == true) != peerEnabled.contains(kind) {
                if changed, let peerEpoch {
                    retiredEpochs.append(peerEpoch)
                    if retiredEpochs.count > 128 { retiredEpochs.removeFirst() }
                }
                clearTransfers(); active = []; seenCount = nil
                if changed { peerEnabled = [] }
                peerEpoch = packet.epoch
                if packet.enabled == true { peerEnabled.insert(kind) } else { peerEnabled.remove(kind) }
                reconcile()
                if changed { sendConsent() }
            }
            return
        }
        guard active.contains(kind), packet.epoch == peerEpoch, packet.peerEpoch == epoch, let id = packet.id else { return }
        switch packet.op {
        case .cancel:
            if outgoing?.id == id, outgoing?.kind == kind { outgoing = nil }
            if incoming?.id == id, incoming?.kind == kind { incoming = nil; ack = nil }
            updateGate()
        case .ack:
            guard var transfer = outgoing, transfer.id == id, transfer.kind == kind, transfer.pending != 0,
                  packet.offset == transfer.pending else { return }
            transfer.offset = transfer.pending; transfer.pending = 0; transfer.touched = Date()
            if transfer.offset == transfer.data.count {
                outgoing = nil; updateGate(); status(kind, "Image clipboard sent", "Text clipboard sent")
            } else {
                outgoing = transfer
                queue.async { [weak self] in self?.sendNext() }
            }
        case .chunk:
            guard let offset = packet.offset, let total = packet.totalBytes, let bytes = packet.bytes else { return }
            beforeIPC?()
            guard isCurrent else { return }
            rebaseRemoteMetadata()
            if incoming == nil {
                guard let count = seenCount, offset == 0, board.changeCount == count else { cancel(id, kind); return }
                incoming = Incoming(id: id, kind: kind, total: total, count: count)
            }
            guard var transfer = incoming, transfer.id == id, transfer.kind == kind, transfer.total == total,
                  transfer.data.count == offset, board.changeCount == transfer.count else {
                cancel(id, kind); incoming = nil; ack = nil; updateGate(); return
            }
            transfer.data.append(bytes); transfer.touched = Date(); incoming = transfer
            if transfer.data.count == total {
                // UTF-8 is validated only on the full payload; chunks may split a code point.
                let valid = kind == .png ? Self.validImage(transfer.data, pngOnly: true) : Self.validText(transfer.data)
                guard valid, active.contains(kind), isSafe(), board.changeCount == transfer.count else {
                    cancel(id, kind); incoming = nil; ack = nil; updateGate(); return
                }
                let item = NSPasteboardItem()
                item.setData(transfer.data, forType: kind == .png ? .png : .string)
                item.setData(Data(), forType: Self.receivedImageType)
                // Limit only this received write, not system-wide Handoff preferences.
                guard isCurrent, board.changeCount == transfer.count, isCurrent else { return }
                board.prepareForNewContents(with: .currentHostOnly)
                guard isCurrent else { return }
                guard board.writeObjects([item]) else {
                    incoming = nil; ack = nil; updateGate(); cancel(id, kind); return
                }
                seenCount = board.changeCount; snapshotCount = seenCount
                if let outgoing { cancel(outgoing.id, outgoing.kind) }
                outgoing = nil; incoming = nil; generation += 1
                status(kind, "Image clipboard received", "Text clipboard received")
            }
            ack = (id, kind); updateGate()
            if !emit(kind, .init(op: .ack, epoch: epoch, peerEpoch: peerEpoch, id: id, offset: transfer.data.count)) {
                incoming = nil; ack = nil; updateGate()
            }
        case .consent: break
        }
    }
    func sendFailed(_ packet: ImageClipboardPacket, kind: Kind, revision: Int) {
        guard isCurrent, self.revision == revision else { return }
        if packet.op == .chunk, outgoing?.id == packet.id, outgoing?.kind == kind {
            outgoing?.pending = 0; updateGate(); status(kind, "Image clipboard unavailable", "Text clipboard unavailable")
        } else if packet.op == .ack, ack?.kind == kind {
            incoming = nil; ack = nil; updateGate()
        }
    }
    /// Non-empty strict UTF-8 up to the wire limit; bytes are kept exactly, including NUL.
    nonisolated static func validText(_ data: Data) -> Bool {
        !data.isEmpty && data.count <= TextClipboardPacket.maxBytes && String(data: data, encoding: .utf8) != nil
    }
    nonisolated private static func validImage(_ data: Data, pngOnly: Bool) -> Bool {
        guard !data.isEmpty, data.count <= (pngOnly ? 8388608 : 67108864),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let kind = CGImageSourceGetType(source) as String?,
              kind == UTType.png.identifier || (!pngOnly && kind == UTType.tiff.identifier),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return false }
        return width > 0 && height > 0 && width <= 16384 && height <= 16384 && width <= 32000000 / height
    }
    nonisolated private static func canonicalPNG(png: Data?, tiff: Data?) -> Data? {
        if let png, validImage(png, pngOnly: true) { return png }
        guard let tiff, validImage(tiff, pngOnly: false),
              let source = CGImageSourceCreateWithData(tiff as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
              let output = CFDataCreateMutable(nil, 0),
              let dest = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        let result = output as Data
        return validImage(result, pngOnly: true) ? result : nil
    }
}

@MainActor final class ImageClipboardController {
    var send: ((ImageClipboardPacket) -> Bool)?
    var sendText: ((TextClipboardPacket) -> Bool)?
    var isSafe: () -> Bool = { false }
    var onStatus: ((String) -> Void)?
    var onTextStatus: ((String) -> Void)?
    let sendGate = ImageClipboardSendGate()
    static let receivedImageType = ImageClipboardWorker.receivedImageType
    private let queue = DispatchQueue(label: "ThunderControl.ImageClipboard", qos: .utility)
    private let worker: ImageClipboardWorker
    private let supported: Set<ClipboardTransferKind>
    private var timer: Timer?
    private var running = false
    private var enabled: Bool
    private var textEnabled: Bool
    private var wasSafe = false
    private var pollPending = false
    private var pendingReceives = 0
    private var authorizationRevision = 0

    init(pasteboard: NSPasteboard = .general, enabled: Bool = false, textEnabled: Bool = false,
         textSupported: Bool = false, imageSupported: Bool = true, beforeWorkerIPC: (() -> Void)? = nil) {
        self.enabled = enabled; self.textEnabled = textEnabled
        let supported: Set<ClipboardTransferKind> = Set((imageSupported ? [.png] : []) + (textSupported ? [.textUTF8] : []))
        self.supported = supported
        let on: Set<ClipboardTransferKind> = Set((enabled ? [.png] : []) + (textEnabled ? [.textUTF8] : []))
        worker = ImageClipboardWorker(boardName: pasteboard.name.rawValue, enabled: on, supported: supported, gate: sendGate, queue: queue)
        worker.beforeIPC = beforeWorkerIPC
        worker.send = { [weak self, weak worker] kind, packet in
            guard let worker else { return false }
            let revision = worker.revision
            DispatchQueue.main.async { [weak self, weak worker] in
                guard let self, self.sendGate.currentRevision == revision, self.running else { return }
                guard self.isSafe() else {
                    self.sendGate.revoke(); self.authorizationRevision = self.sendGate.currentRevision
                    self.wasSafe = false; return
                }
                let accepted = self.transmit(kind, packet)
                if !accepted {
                    self.queue.async { [weak worker] in worker?.sendFailed(packet, kind: kind, revision: revision) }
                }
            }
            return true
        }
        worker.onStatus = { [weak self, weak worker] kind, status in
            guard let worker else { return }
            let revision = worker.revision
            DispatchQueue.main.async { [weak self] in
                guard let self, self.sendGate.currentRevision == revision else { return }
                (kind == .png ? self.onStatus : self.onTextStatus)?(status)
            }
        }
    }
    private func transmit(_ kind: ClipboardTransferKind, _ packet: ImageClipboardPacket) -> Bool {
        switch kind {
        case .png: return send?(sendGate.packetForTransmission(packet)) ?? false
        case .textUTF8: return sendText?(sendGate.packetForTransmission(TextClipboardPacket(packet))) ?? false
        }
    }
    private func submit(_ operation: @escaping @Sendable (ImageClipboardWorker) -> Void) {
        let safe = running && isSafe()
        if wasSafe && !safe { sendGate.revoke(); authorizationRevision = sendGate.currentRevision }
        if !wasSafe && safe { authorizationRevision = sendGate.currentRevision }
        wasSafe = safe
        let revision = authorizationRevision
        queue.async { [worker] in
            worker.revision = revision
            worker.currentSafe = safe
            operation(worker)
        }
    }
    func start() {
        guard !running else { return }
        running = true; authorizationRevision = sendGate.currentRevision
        submit { $0.start() }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
    }
    func stop() {
        guard running else { return }
        sendGate.revoke(); authorizationRevision = sendGate.currentRevision
        if isSafe() {
            let off = ImageClipboardPacket(op: .consent, epoch: UUID().uuidString, enabled: false)
            for kind in [ClipboardTransferKind.png, .textUTF8] where supported.contains(kind) { _ = transmit(kind, off) }
        }
        submit { $0.stop() }
        running = false; wasSafe = false
        timer?.invalidate(); timer = nil
    }
    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        sendGate.revoke(renewEpoch: true); authorizationRevision = sendGate.currentRevision
        submit { $0.setEnabled(value, kind: .png) }
    }
    func setTextEnabled(_ value: Bool) {
        guard textEnabled != value else { return }
        textEnabled = value
        sendGate.revoke(renewEpoch: true); authorizationRevision = sendGate.currentRevision
        submit { $0.setEnabled(value, kind: .textUTF8) }
    }
    func poll() {
        guard running else { return }
        if wasSafe && !isSafe() {
            sendGate.revoke(); authorizationRevision = sendGate.currentRevision; wasSafe = false
            submit { $0.poll() }
            return
        }
        guard !pollPending else { return }
        pollPending = true
        submit { [weak self] worker in
            worker.poll()
            DispatchQueue.main.async { [weak self] in self?.pollPending = false }
        }
    }
    func receive(_ packet: ImageClipboardPacket) {
        guard packet.valid else { return }
        enqueueReceive(packet, kind: .png)
    }
    func receive(_ packet: TextClipboardPacket) {
        guard packet.valid else { return }
        enqueueReceive(packet.body, kind: .textUTF8)
    }
    private func enqueueReceive(_ packet: ImageClipboardPacket, kind: ClipboardTransferKind) {
        guard running, supported.contains(kind) else { return }
        guard pendingReceives < 32 else { sendGate.revoke(); return }
        pendingReceives += 1
        submit { [weak self] worker in
            worker.receive(packet, kind: kind)
            DispatchQueue.main.async { [weak self] in self?.pendingReceives -= 1 }
        }
    }
}

/// Test-only access to the worker's text validator.
enum ImageClipboardWorkerProbe { static func validText(_ data: Data) -> Bool { ImageClipboardWorker.validText(data) } }
