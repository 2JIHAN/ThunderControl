import AppKit
import VideoToolbox
import CoreMedia
import CoreVideo
import AVFoundation
import QuartzCore

/// Wire decoding is deliberately separate from UI, sockets, trust, and input handling.
enum DisplayVideoError: Error, LocalizedError {
    case malformed, unsupportedFormat, decoderFailed, backlog
    var errorDescription: String? {
        switch self {
        case .malformed: return TCText("Invalid screen video frame.")
        case .unsupportedFormat: return TCText("Screen video does not match the agreed H.264 dimensions or resource limits.")
        case .decoderFailed: return TCText("Could not reconstruct the screen video. Restart the connection.")
        case .backlog: return TCText("Connection stopped because video reconstruction timed out.")
        }
    }
}

/// Pure admission accounting. Compressed reference frames are never evicted.
/// Completion cookies and epochs make duplicate/retired callbacks inert.
struct DisplayDecodeAdmission<Packet> {
    static var submissionLimit: Int { 4 }
    static var pendingLimit: Int { 8 }
    static var byteLimit: Int { 8 * 1024 * 1024 }
    private(set) var epoch: UInt64 = 0
    private(set) var pending: [(packet: Packet, bytes: Int)] = []
    private(set) var pendingBytes = 0
    private(set) var active: Set<Int64> = []
    var hasSpace: Bool { active.count < Self.submissionLimit }
    mutating func enqueue(_ packet: Packet, bytes: Int) throws {
        guard bytes > 0, bytes <= Self.byteLimit, pending.count < Self.pendingLimit,
              pendingBytes <= Self.byteLimit - bytes else { throw DisplayVideoError.backlog }
        pending.append((packet, bytes)); pendingBytes += bytes
    }
    mutating func submit(sequence: Int64) -> Packet? {
        guard hasSpace, !pending.isEmpty, !active.contains(sequence) else { return nil }
        let entry = pending.removeFirst(); pendingBytes -= entry.bytes; active.insert(sequence)
        return entry.packet
    }
    @discardableResult mutating func complete(sequence: Int64, epoch: UInt64) -> Bool {
        guard epoch == self.epoch else { return false }
        return active.remove(sequence) != nil
    }
    mutating func clear() {
        epoch &+= 1; pending.removeAll(); pendingBytes = 0; active.removeAll()
    }
}

private struct DisplayH264Bits {
    let bytes: [UInt8]
    var bit = 0
    init(_ nal: Data) throws {
        guard nal.count > 1 else { throw DisplayVideoError.malformed }
        var output = [UInt8](), zeros = 0
        let source = [UInt8](nal.dropFirst())
        var index = 0
        while index < source.count {
            let byte = source[index]
            if zeros >= 2 && byte == 3 {
                guard index + 1 < source.count, source[index + 1] <= 3 else { throw DisplayVideoError.malformed }
                zeros = 0; index += 1; continue
            }
            output.append(byte); zeros = byte == 0 ? zeros + 1 : 0; index += 1
        }
        bytes = output
    }
    mutating func read(_ count: Int) throws -> UInt32 {
        guard count >= 0, count <= 32, bit + count <= bytes.count * 8 else { throw DisplayVideoError.malformed }
        var value: UInt32 = 0
        for _ in 0..<count { value = (value << 1) | UInt32((bytes[bit / 8] >> (7 - bit % 8)) & 1); bit += 1 }
        return value
    }
    mutating func ue() throws -> UInt32 {
        var zeros = 0
        while try read(1) == 0 { zeros += 1; if zeros > 24 { throw DisplayVideoError.malformed } }
        return ((UInt32(1) << zeros) - 1) + (try read(zeros))
    }
}

/// Validates the resource-relevant SPS fields before creating a decoder. Fixed progressive
/// 8-bit 4:2:0, at most four references, exact visible size and minimal macroblock padding.
private func displayValidateSPS(_ sps: Data, pps: Data, format: DisplayVideoFormat) throws {
    guard format.valid else { throw DisplayVideoError.unsupportedFormat }
    var bits = try DisplayH264Bits(sps)
    let profile = try bits.read(8)
    let constraints = try bits.read(8)
    let level = try bits.read(8)
    guard [66, 77, 100].contains(profile), constraints & 3 == 0, level <= format.h264LevelLimit else { throw DisplayVideoError.unsupportedFormat }
    let spsID = try bits.ue()
    guard spsID <= 31 else { throw DisplayVideoError.malformed }
    if profile == 100 {
        guard try bits.ue() == 1, try bits.ue() == 0, try bits.ue() == 0,
              try bits.read(1) == 0, try bits.read(1) == 0 else { throw DisplayVideoError.unsupportedFormat }
    }
    guard try bits.ue() <= 12 else { throw DisplayVideoError.unsupportedFormat }
    let orderType = try bits.ue()
    if orderType == 0 { guard try bits.ue() <= 12 else { throw DisplayVideoError.unsupportedFormat } }
    else if orderType != 2 { throw DisplayVideoError.unsupportedFormat }
    guard try bits.ue() <= 4 else { throw DisplayVideoError.unsupportedFormat }
    _ = try bits.read(1)
    let macroWidth = try bits.ue(), macroHeight = try bits.ue()
    guard macroWidth == UInt32((format.pixelWidth + 15) / 16 - 1),
          macroHeight == UInt32((format.pixelHeight + 15) / 16 - 1),
          (macroWidth + 1) * (macroHeight + 1) <= UInt32(format.macroblockLimit),
          try bits.read(1) == 1 else { throw DisplayVideoError.unsupportedFormat }
    _ = try bits.read(1)
    var left: UInt32 = 0, right: UInt32 = 0, top: UInt32 = 0, bottom: UInt32 = 0
    if try bits.read(1) != 0 { left = try bits.ue(); right = try bits.ue(); top = try bits.ue(); bottom = try bits.ue() }
    let codedWidth = (macroWidth + 1) * 16, codedHeight = (macroHeight + 1) * 16
    guard left <= 7, right <= 7, top <= 7, bottom <= 7,
          2 * (left + right) < codedWidth, 2 * (top + bottom) < codedHeight,
          codedWidth - 2 * (left + right) == UInt32(format.pixelWidth),
          codedHeight - 2 * (top + bottom) == UInt32(format.pixelHeight) else { throw DisplayVideoError.unsupportedFormat }
    var ppsBits = try DisplayH264Bits(pps)
    guard try ppsBits.ue() <= 255, try ppsBits.ue() == spsID else { throw DisplayVideoError.malformed }
}

struct DisplayH264Packet {
    static let maximumSize = 4 * 1024 * 1024
    let sps: Data
    let pps: Data
    let avcc: Data
    let isKeyFrame: Bool
    let format: DisplayVideoFormat
    init(_ payload: Data, format: DisplayVideoFormat = .standard) throws {
        guard format.valid else { throw DisplayVideoError.unsupportedFormat }
        self.format = format
        guard payload.count >= 12, payload.count <= Self.maximumSize else { throw DisplayVideoError.malformed }
        let bytes = [UInt8](payload)
        guard bytes[0] == 2 else { throw DisplayVideoError.malformed }
        var offset = 1
        func parameter(_ type: UInt8) throws -> Data {
            guard offset + 2 <= bytes.count else { throw DisplayVideoError.malformed }
            let length = Int(bytes[offset]) * 256 + Int(bytes[offset + 1]); offset += 2
            guard length >= 2, length <= 4096, length <= bytes.count - offset,
                  bytes[offset] & 0x80 == 0, bytes[offset] & 0x1f == type else { throw DisplayVideoError.malformed }
            let result = Data(bytes[offset..<(offset + length)]); offset += length
            return result
        }
        sps = try parameter(7); pps = try parameter(8)
        try displayValidateSPS(sps, pps: pps, format: format)
        let start = offset
        var count = 0, hasSlice = false, key = false
        while offset < bytes.count {
            guard offset + 4 <= bytes.count else { throw DisplayVideoError.malformed }
            let length = bytes[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            offset += 4
            guard length > 0, length <= UInt32(bytes.count - offset), bytes[offset] & 0x80 == 0 else { throw DisplayVideoError.malformed }
            let kind = bytes[offset] & 0x1f
            // Embedded parameter sets would bypass the validated description. Refuse them.
            guard [1, 5, 6, 9, 12].contains(kind) else { throw DisplayVideoError.malformed }
            if kind == 1 || kind == 5 { hasSlice = true }; if kind == 5 { key = true }
            count += 1; guard count <= 256 else { throw DisplayVideoError.malformed }
            offset += Int(length)
        }
        guard hasSlice else { throw DisplayVideoError.malformed }
        avcc = Data(bytes[start..<offset]); isKeyFrame = key
    }
    func formatDescription() throws -> CMVideoFormatDescription {
        var result: CMFormatDescription?
        let status = sps.withUnsafeBytes { s in pps.withUnsafeBytes { p in
            let pointers = [s.baseAddress!.assumingMemoryBound(to: UInt8.self), p.baseAddress!.assumingMemoryBound(to: UInt8.self)]
            let sizes = [sps.count, pps.count]
            return pointers.withUnsafeBufferPointer { ptr in sizes.withUnsafeBufferPointer { lengths in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                    parameterSetCount: 2, parameterSetPointers: ptr.baseAddress!, parameterSetSizes: lengths.baseAddress!,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &result)
            }}
        }}
        guard status == noErr, let result else {
            displayStageLog("Display decoder failure error=malformed stage=formatDescription status=\(status) expected=\(format.pixelWidth)x\(format.pixelHeight)")
            throw DisplayVideoError.malformed
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(result)
        guard dimensions.width == Int32(format.pixelWidth), dimensions.height == Int32(format.pixelHeight) else { throw DisplayVideoError.unsupportedFormat }
        return result
    }
}

/// Immutable per-viewer diagnostic route. A nil captured stream never falls through
/// to a newer recorder stream. Hooks permit isolated tests without a real store.
struct DisplayFrameTrace {
    typealias Hook = (String, UInt64?, [String: Double], String?) -> Void
    let stream: String?
    let hook: Hook?
    init(stream: String? = DevelopmentDiagnostics.shared.currentStream, hook: Hook? = nil) {
        self.stream = stream; self.hook = hook
    }
    func record(_ stage: String, identity: DisplayFrameIdentity? = nil, sequence: UInt64? = nil, fields: [String: Double] = [:]) {
        var fields = fields
        if let identity {
            fields["decoderCookie"] = Double(identity.cookie)
            fields["decoderGeneration"] = Double(identity.generation)
        }
        if let hook { hook(stage, identity?.sourceSequence ?? sequence, fields, stream) }
        else if let stream { DevelopmentDiagnostics.shared.record(stage: stage, sequence: identity?.sourceSequence ?? sequence, fields: fields, stream: stream) }
    }
}

struct DisplayFrameIdentity: Equatable {
    let sourceSequence: UInt64?
    let cookie: Int64
    let generation: UInt64
}

/// Same single pixel reference as before; metadata never stores image contents.
struct DisplayTracedFrame {
    let pixel: CVPixelBuffer
    let identity: DisplayFrameIdentity
    let decodedMainAt: Double
}

private struct DisplayDecodePacket {
    let video: DisplayH264Packet
    let sourceSequence: UInt64?
}

/// The VT callback owns no window. At most one pixel buffer and one main-queue delivery
/// are retained, plus at most four codec submissions. Invalidating clears handlers before
/// VT is drained, so an old session cannot paint a newly opened viewer.
final class DisplayDecodeMailbox {
    let lock = NSLock()
    let format: DisplayVideoFormat
    var valid = true, scheduled = false, inFlight = 0, failed = false
    private struct Submission { let at: Double; let identity: DisplayFrameIdentity; var returned: Bool }
    private struct ProvisionalCallback { let status: OSStatus; let flags: VTDecodeInfoFlags; let pixel: CVPixelBuffer?; let at: Double }
    private var provisional: [Int64: ProvisionalCallback] = [:]
    private var submittedAt: [Int64: Submission] = [:]
    private let trace: DisplayFrameTrace
    private let generation: UInt64
    private let scheduleDrain: (@escaping () -> Void) -> Void
    private var latestIdentity: DisplayFrameIdentity?
    var latest: CVPixelBuffer?
    var latestCallbackAt: Double?
    var deliver: ((CVPixelBuffer, DisplayFrameIdentity) -> Void)?
    var failure: (() -> Void)?
    var space: (([Int64]) -> Void)?
    private var completed: [Int64] = []
    private var failureDetail: String?
    private var callbackCadence = DisplayCadenceStats()
    private var decodeTiming = DisplayTimingStats(), callbackToMain = DisplayTimingStats()
    private var mailboxReplacements: UInt64 = 0, droppedCallbacks: UInt64 = 0
    private var lastLoggedAt = ProcessInfo.processInfo.systemUptime
    init(format: DisplayVideoFormat, trace: DisplayFrameTrace, generation: UInt64, scheduleDrain: @escaping (@escaping () -> Void) -> Void = { work in DispatchQueue.main.async(execute: work) }, deliver: @escaping (CVPixelBuffer, DisplayFrameIdentity) -> Void, failure: @escaping () -> Void, space: @escaping ([Int64]) -> Void) {
        self.format = format; self.trace = trace; self.generation = generation; self.scheduleDrain = scheduleDrain
        self.deliver = deliver; self.failure = failure; self.space = space
    }
    func reserve(sequence: Int64, identity: DisplayFrameIdentity, awaitingReturn: Bool = false) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard valid, !failed, inFlight < 4, submittedAt.count < 4 else { return false }; inFlight += 1; submittedAt[sequence] = Submission(at: ProcessInfo.processInfo.systemUptime, identity: identity, returned: !awaitingReturn); trace.record("decoder_submit", identity: identity, fields: ["inFlight": Double(inFlight)]); return true
    }
    // Called only AFTER the worker releases its executing-job reservation.
    func submissionSucceeded(sequence: Int64) {
        lock.lock()
        guard valid, !failed, var submission = submittedAt[sequence] else { lock.unlock(); return }
        submission.returned = true; submittedAt[sequence] = submission
        let callback = provisional.removeValue(forKey: sequence)
        lock.unlock()
        if let callback { complete(status: callback.status, flags: callback.flags, pixel: callback.pixel, sequence: sequence, callbackAt: callback.at) }
    }
    var maySubmit: Bool {
        lock.lock(); defer { lock.unlock() }; return valid && !failed
    }
    // DecodeFrame may return an error after an inline callback. Suppress even an
    // already queued successful image before marshaling the actual submit failure.
    func submissionFailed() {
        lock.lock(); failed = true; provisional.removeAll(); latest = nil; latestIdentity = nil; latestCallbackAt = nil; lock.unlock()
    }
    func complete(status: OSStatus, flags: VTDecodeInfoFlags, pixel: CVPixelBuffer?, sequence: Int64, callbackAt: Double? = nil) {
        let now = callbackAt ?? ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard valid, !failed, let submission = submittedAt[sequence] else {
            trace.record("decoder_callback_ignored", fields: ["decoderCookie": Double(sequence), "decoderGeneration": Double(generation), "valid": valid ? 1 : 0])
            lock.unlock(); return
        }
        guard submission.returned else {
            // No image, completion or failure can escape while DecodeFrame is
            // still executing: its eventual return status remains authoritative.
            if provisional[sequence] == nil { provisional[sequence] = ProvisionalCallback(status: status, flags: flags, pixel: pixel, at: now) }
            lock.unlock(); return
        }
        submittedAt.removeValue(forKey: sequence)
        let identity = submission.identity
        trace.record("decoder_callback", identity: identity, fields: ["status": Double(status), "flags": Double(flags.rawValue), "time": now, "submitToCallbackMs": (now-submission.at)*1000])
        inFlight -= 1; completed.append(sequence)
        decodeTiming.record((now-submission.at)*1000)
        if flags.contains(.frameDropped) { droppedCallbacks &+= 1 }
        if status == noErr, let pixel, CVPixelBufferGetWidth(pixel) == format.pixelWidth,
           CVPixelBufferGetHeight(pixel) == format.pixelHeight, CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_32BGRA {
            callbackCadence.observe(now)
            if latest != nil { mailboxReplacements &+= 1; trace.record("mailbox_replace", identity: latestIdentity) }
            latest = pixel; latestCallbackAt = now; latestIdentity = identity
        } else if status != noErr || pixel != nil || !flags.contains(.frameDropped) {
            if !failed {
                failureDetail = "error=decoderFailed stage=callback status=\(status) flags=\(flags.rawValue) dimensions=\(pixel.map { "\(CVPixelBufferGetWidth($0))x\(CVPixelBufferGetHeight($0))" } ?? "none") expected=\(format.pixelWidth)x\(format.pixelHeight) inFlight=\(inFlight) limit=4"
            }
            trace.record("decoder_failure", identity: identity)
            if latest != nil { trace.record("mailbox_failure_discard", identity: latestIdentity) }
            failed = true; latest = nil; latestCallbackAt = nil; latestIdentity = nil
        }
        let enqueue = !scheduled; scheduled = true; lock.unlock()
        if enqueue { scheduleDrain { [self] in drain() } }
    }
    private func summaryLocked() -> String {
        "Display cadence decoder: callbacks[\(callbackCadence.summary)] submitToCallback[\(decodeTiming.summary)] callbackToMain[\(callbackToMain.summary)] mailboxReplaced=\(mailboxReplacements) vtDropFlag=\(droppedCallbacks); contentMayBeIdle=true panelUnmeasured=true"
    }
    private func drain() {
        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        let image = valid && !failed ? latest : nil
        let identity = latestIdentity
        let output = valid ? deliver : nil
        let error = valid && failed ? failure : nil
        let ready = valid && !failed ? space : nil
        let finished = completed; completed.removeAll(keepingCapacity: true)
        let detail = failureDetail; failureDetail = nil
        if image != nil, let readyAt = latestCallbackAt { callbackToMain.record((now-readyAt)*1000) }
        let summary: String?
        if valid, callbackCadence.count > 0, now-lastLoggedAt >= 2 { summary = summaryLocked(); lastLoggedAt = now } else { summary = nil }
        latest = nil; latestCallbackAt = nil; latestIdentity = nil; scheduled = false
        lock.unlock()
        if let summary { displayStageLog(summary) }
        if let detail { displayStageLog("Display decoder failure "+detail) }
        if let error { error() } else {
            if let image, let identity {
                trace.record("decoder_main_delivery", identity: identity, fields: ["time": now])
                output?(image, identity)
            }
            ready?(finished)
        }
    }
    func invalidate() {
        lock.lock()
        let summary = valid && callbackCadence.count > 0 ? summaryLocked() : nil
        if latest != nil { trace.record("mailbox_clear_discard", identity: latestIdentity) }
        for submission in submittedAt.values { trace.record("decoder_retire", identity: submission.identity) }
        latestIdentity = nil
        valid = false; submittedAt.removeAll(); provisional.removeAll(); latest = nil; latestCallbackAt = nil; deliver = nil; failure = nil; space = nil; completed.removeAll(); failureDetail = nil
        lock.unlock()
        if let summary { displayStageLog(summary+" final=true") }
    }
}

private let displayDecodeCallback: VTDecompressionOutputCallback = { reference, frameContext, status, flags, image, _, _ in
    guard let reference, let frameContext else { return }
    // Opaque integer cookie, never dereferenced. VT can normalize PTS timescales.
    let sequence = Int64(UInt(bitPattern: frameContext) - 1)
    Unmanaged<DisplayDecodeMailbox>.fromOpaque(reference).takeUnretainedValue().complete(status: status, flags: flags, pixel: image, sequence: sequence)
}

/// Main-thread entry points; output callbacks are coalesced onto the main queue.
/// This is also usable by a no-window synthetic integration harness.
@MainActor final class DisplayH264Decoder {
    private var session: VTDecompressionSession?
    private var worker: DisplayDecodeWorker?
    let format: DisplayVideoFormat
    private var description: CMVideoFormatDescription?
    private var parameters: (Data, Data)?
    private var mailbox: DisplayDecodeMailbox?
    private var sequence: Int64 = 0
    private var admission = DisplayDecodeAdmission<DisplayDecodePacket>()
    private static var nextTraceGeneration: UInt64 = 0
    private var traceGeneration: UInt64 = 0
    private let trace: DisplayFrameTrace
    private let tracedOutput: ((CVPixelBuffer, DisplayFrameIdentity) -> Void)?
    private(set) var completedSubmissions = 0
    var pendingFrameCount: Int { admission.pending.count }
    var inFlightFrameCount: Int { admission.active.count }
    private let output: (CVPixelBuffer) -> Void
    private let failure: () -> Void
    init(format: DisplayVideoFormat = .standard, trace: DisplayFrameTrace = DisplayFrameTrace(), tracedOutput: ((CVPixelBuffer, DisplayFrameIdentity) -> Void)? = nil, output: @escaping (CVPixelBuffer) -> Void, failure: @escaping () -> Void) { self.format = format; self.trace = trace; self.tracedOutput = tracedOutput; self.output = output; self.failure = failure }
    deinit {
        mailbox?.invalidate()
        worker?.retire()
    }
    func clear() {
        admission.clear(); completedSubmissions = 0
        retireSession()
        sequence = 0
    }
    private func retireSession() {
        Self.nextTraceGeneration &+= 1
        traceGeneration = Self.nextTraceGeneration
        mailbox?.invalidate()
        worker?.retire()
        worker = nil; session = nil; description = nil; parameters = nil; mailbox = nil
    }
    private func logFailure(_ error: Error, stage: String, status: OSStatus? = nil, flags: VTDecodeInfoFlags = []) {
        let category: Double
        switch error as? DisplayVideoError {
        case .malformed?: category = 1
        case .unsupportedFormat?: category = 2
        case .decoderFailed?: category = 3
        case .backlog?: category = 4
        case nil: category = 0
        }
        // Fixed numeric codes only, never arbitrary error descriptions or payloads.
        let stageCodes: [String: Double] = ["accept": 1, "drain": 2, "callback": 3,
            "configure": 4, "block": 5, "copy": 6, "sample": 7, "submit": 8]
        var fields: [String: Double] = ["category": category, "stageCode": stageCodes[stage] ?? 0,
            "inFlight": Double(admission.active.count), "pending": Double(admission.pending.count),
            "pendingBytes": Double(admission.pendingBytes), "flags": Double(flags.rawValue),
            "decoderGeneration": Double(traceGeneration)]
        if let status { fields["status"] = Double(status) }
        trace.record("decoder_failure_detail", fields: fields)
        displayStageLog("Display decoder failure error=\(String(describing: error)) stage=\(stage) status=\(status.map(String.init) ?? "none") flags=\(flags.rawValue) expected=\(format.pixelWidth)x\(format.pixelHeight) inFlight=\(admission.active.count)/4 pending=\(admission.pending.count)/8 pendingBytes=\(admission.pendingBytes)/8388608")
    }
    func accept(_ payload: Data, sourceSequence: UInt64? = nil) throws {
        do {
            let packet = try DisplayH264Packet(payload, format: format)
            try admission.enqueue(DisplayDecodePacket(video: packet, sourceSequence: sourceSequence), bytes: packet.sps.count + packet.pps.count + packet.avcc.count)
            try drainPending()
        } catch { logFailure(error, stage: "accept"); clear(); throw error }
    }
    private func callbacksCompleted(_ sequences: [Int64], epoch: UInt64) {
        guard epoch == admission.epoch else { return }
        for sequence in sequences {
            if admission.complete(sequence: sequence, epoch: epoch) { completedSubmissions += 1 }
        }
        do { try drainPending() }
        catch { logFailure(error, stage: "drain"); clear(); failure() }
    }
    private func drainPending() throws {
        while admission.hasSpace, let next = admission.pending.first?.packet {
            let changed = parameters?.0 != next.video.sps || parameters?.1 != next.video.pps
            // Finish every old reference before switching descriptions, without a wait.
            if changed && !admission.active.isEmpty { return }
            guard sequence >= 0, sequence < Int64.max else { throw DisplayVideoError.backlog }
            guard let packet = admission.submit(sequence: sequence) else { return }
            try submit(packet)
            sequence += 1
        }
    }
    private func submit(_ submission: DisplayDecodePacket) throws {
        let packet = submission.video
        if parameters?.0 != packet.sps || parameters?.1 != packet.pps {
            guard packet.isKeyFrame else { throw DisplayVideoError.malformed }
            let configurationStarted = ProcessInfo.processInfo.systemUptime
            retireSession()
            guard let lease = DisplayDecodeWorkerLease.acquire() else { throw DisplayVideoError.backlog }
            let description = try packet.formatDescription()
            let epoch = admission.epoch
            let box = DisplayDecodeMailbox(format: format, trace: trace, generation: traceGeneration, deliver: { [weak self] pixel, identity in
                guard let self, self.admission.epoch == epoch else { return }; if let tracedOutput = self.tracedOutput { tracedOutput(pixel, identity) } else { self.output(pixel) }
            }, failure: { [weak self] in
                guard let self, self.admission.epoch == epoch else { return }
                self.logFailure(DisplayVideoError.decoderFailed, stage: "callback"); self.clear(); self.failure()
            }, space: { [weak self] completed in self?.callbacksCompleted(completed, epoch: epoch) })
            var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: displayDecodeCallback,
                decompressionOutputRefCon: Unmanaged.passUnretained(box).toOpaque())
            var created: VTDecompressionSession?
            let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: description,
                decoderSpecification: [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true] as CFDictionary,
                imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey: format.pixelWidth, kCVPixelBufferHeightKey: format.pixelHeight,
                    kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                outputCallback: &callback, decompressionSessionOut: &created)
            guard status == noErr, let created else { logFailure(DisplayVideoError.decoderFailed, stage: "configure", status: status); throw DisplayVideoError.decoderFailed }
            worker = DisplayDecodeWorker(lease: lease) {
                VTDecompressionSessionInvalidate(created)
                VTDecompressionSessionWaitForAsynchronousFrames(created)
                withExtendedLifetime(box) {}
            }
            session = created; self.description = description; parameters = (packet.sps, packet.pps); mailbox = box
            _ = VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            displayStageLog("Display decoder configuration setupMs=\((ProcessInfo.processInfo.systemUptime-configurationStarted)*1000); reconfigurationNotSteadyState=true")
        }
        guard let session, let description, let mailbox, let worker else { throw DisplayVideoError.decoderFailed }
        var block: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: packet.avcc.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: packet.avcc.count, flags: 0, blockBufferOut: &block)
        guard blockStatus == noErr, let block else { logFailure(DisplayVideoError.decoderFailed, stage: "block", status: blockStatus); throw DisplayVideoError.decoderFailed }
        let copied = packet.avcc.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: packet.avcc.count)
        }
        guard copied == noErr else { logFailure(DisplayVideoError.decoderFailed, stage: "copy", status: copied); throw DisplayVideoError.decoderFailed }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(value: sequence, timescale: 30), decodeTimeStamp: .invalid)
        var size = packet.avcc.count
        var sample: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: description,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard sampleStatus == noErr, let sample else { logFailure(DisplayVideoError.decoderFailed, stage: "sample", status: sampleStatus); throw DisplayVideoError.decoderFailed }
        guard sequence >= 0, sequence < Int64.max, mailbox.reserve(sequence: sequence, identity: DisplayFrameIdentity(sourceSequence: submission.sourceSequence, cookie: sequence, generation: traceGeneration), awaitingReturn: true) else { throw DisplayVideoError.backlog }
        let cookie = sequence
        let identity = DisplayFrameIdentity(sourceSequence: submission.sourceSequence, cookie: cookie, generation: traceGeneration)
        let epoch = admission.epoch
        let trace = self.trace
        guard worker.submit({ [weak self] queueWaitMs in
            guard mailbox.maySubmit else { return false }
            trace.record("decoder_call", identity: identity, fields: ["time": ProcessInfo.processInfo.systemUptime, "queueWaitMs": queueWaitMs])
            var infoFlags: VTDecodeInfoFlags = []
            // Keep diagnostic logging outside the measured VT API boundary.
            let started = ProcessInfo.processInfo.systemUptime
            let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample,
                flags: [._EnableAsynchronousDecompression],
                frameRefcon: UnsafeMutableRawPointer(bitPattern: UInt(cookie) + 1), infoFlagsOut: &infoFlags)
            let ended = ProcessInfo.processInfo.systemUptime
            trace.record("decoder_return", identity: identity, fields: ["time": ended,
                "elapsedMs": (ended - started) * 1000, "queueWaitMs": queueWaitMs, "startedAt": started,
                "status": Double(status), "flags": Double(infoFlags.rawValue)])
            guard status != noErr else { return true }
            mailbox.submissionFailed()
            let returnedFlags = infoFlags
            DispatchQueue.main.async { [weak self] in
                guard let self, self.admission.epoch == epoch, self.mailbox === mailbox else { return }
                self.logFailure(DisplayVideoError.decoderFailed, stage: "submit", status: status, flags: returnedFlags)
                self.clear(); self.failure()
            }
            return false
        }, didReturn: { mailbox.submissionSucceeded(sequence: cookie) }) else { throw DisplayVideoError.backlog }
    }
}

/// Creates a reference-backed image sample: no CPU pixel readback, bitmap conversion,
/// compressed-frame discard or frame clock/preroll wait is introduced here.
func displayImmediateImageSample(_ pixel: CVPixelBuffer, format expectedFormat: DisplayVideoFormat? = nil) throws -> CMSampleBuffer {
    try displayImageSample(pixel, format: expectedFormat, timing: nil)
}

/// Explicit host-clock PTS with unspecified duration: the next PTS determines
/// replacement. No synthetic nominal duration overlapping measured display slots.
func displayDeadlineImageSample(_ pixel: CVPixelBuffer, format: DisplayVideoFormat? = nil, target: Double) throws -> CMSampleBuffer {
    guard target.isFinite, target >= 0, target.ulp <= 0.000001 else { throw DisplayVideoError.decoderFailed }
    let timing = CMSampleTimingInfo(duration: .invalid,
        presentationTimeStamp: CMTime(seconds: target, preferredTimescale: 1_000_000_000), decodeTimeStamp: .invalid)
    return try displayImageSample(pixel, format: format, timing: timing)
}

func displayScheduledImageSample(_ pixel: CVPixelBuffer, format: DisplayVideoFormat? = nil, timing: CMSampleTimingInfo) throws -> CMSampleBuffer {
    guard timing.presentationTimeStamp.isNumeric, timing.presentationTimeStamp.seconds >= 0,
          CMTimeCompare(timing.duration, CMTime(value: 1, timescale: 60)) == 0 else { throw DisplayVideoError.decoderFailed }
    return try displayImageSample(pixel, format: format, timing: timing)
}

private func displayImageSample(_ pixel: CVPixelBuffer, format expectedFormat: DisplayVideoFormat?, timing scheduledTiming: CMSampleTimingInfo?) throws -> CMSampleBuffer {
    let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel)
    // Legacy callers supply physical pixels, not a newly inferred logical format.
    guard width > 0, height > 0, width <= 3840, height <= 2880,
          width % 2 == 0, height % 2 == 0,
          width * height <= DisplayVideoFormat.maximumEncodedPixels,
          ((width + 15) / 16) * ((height + 15) / 16) <= DisplayVideoFormat.maximumEncodedMacroblocks,
          CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_32BGRA else { throw DisplayVideoError.unsupportedFormat }
    if let expectedFormat {
        guard expectedFormat.valid, width == expectedFormat.pixelWidth, height == expectedFormat.pixelHeight else {
            throw DisplayVideoError.unsupportedFormat
        }
    }
    var format: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel,
        formatDescriptionOut: &format) == noErr, let format else { throw DisplayVideoError.decoderFailed }
    var timing = scheduledTiming ?? CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel,
        formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
        let sample, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
        CFArrayGetCount(attachments) == 1 else { throw DisplayVideoError.decoderFailed }
    let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
    if scheduledTiming == nil {
        CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
    return sample
}

/// Receiver-local mapping only. SDK CADisplayLink.h defines CA timestamps as
/// Mach host time in seconds; AVSampleBufferDisplayLayer.h explicitly equates
/// CACurrentMediaTime with its host clock. Bracket a CM host-clock observation
/// with CA observations, accepting <=1 ms read skew, rather than assuming epochs.
/// The renderer timebase is zero at hostAnchor and runs at rate 1. No source-host
/// timestamp, wall clock, or network offset participates in this mapping.
struct DisplayScheduledTimeline {
    private(set) var generation: UInt64 = 0
    private(set) var hostAnchor: CMTime = .invalid
    private(set) var caAnchor: Double = .nan
    private(set) var lastPTS: CMTime = .invalid
    mutating func reset() { generation &+= 1; hostAnchor = .invalid; caAnchor = .nan; lastPTS = .invalid }
    mutating func calibrate(caBefore: Double, host: CMTime, caAfter: Double) -> Bool {
        reset()
        guard caBefore.isFinite, caAfter.isFinite, caBefore >= 0, caAfter >= caBefore,
              caAfter-caBefore <= 0.001, host.isNumeric, host.seconds >= 0 else { return false }
        caAnchor = caBefore + (caAfter-caBefore)/2; hostAnchor = host
        return true
    }
    /// Reject late/equal, nonfinite or >one nominal frame ahead targets. Also
    /// reject a changed clock relation (>2 ms). Never bump a stale target forward:
    /// strictly increasing PTS comes only from a fresh upcoming display target.
    /// A selected frame rejected here is discarded, not requeued. At most one
    /// future sample is admitted; this adds no queue to the existing bounded pacer.
    func timing(target: Double, caNow: Double, hostNow: CMTime, generation token: UInt64) -> CMSampleTimingInfo? {
        guard token == generation, hostAnchor.isNumeric, hostNow.isNumeric,
              target.isFinite, caNow.isFinite, caNow >= caAnchor,
              target > caNow, target-caNow <= 1.0/60.0 + 0.001 else { return nil }
        let elapsed = CMTimeSubtract(hostNow, hostAnchor)
        guard elapsed.isNumeric, elapsed.seconds >= 0,
              abs(elapsed.seconds-(caNow-caAnchor)) <= 0.002 else { return nil }
        let pts = CMTime(seconds: target-caAnchor, preferredTimescale: 1_000_000_000)
        guard pts.isNumeric, CMTimeCompare(pts, elapsed) > 0,
              !lastPTS.isNumeric || (CMTimeCompare(pts, lastPTS) > 0 && CMTimeCompare(lastPTS, elapsed) <= 0) else { return nil }
        return CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
    }
    mutating func commit(_ timing: CMSampleTimingInfo) { lastPTS = timing.presentationTimeStamp }
}

/// Aggregate local counters only. 'submitted' is renderer enqueue, NOT proof that
/// a physical panel displayed the frame or an end-to-end latency measurement.
struct DisplayPresentationStats {
    var decoded: UInt64 = 0
    var submitted: UInt64 = 0
    var replacedDecoded: UInt64 = 0
    var readinessDeferrals: UInt64 = 0
    var totalEnqueueMilliseconds: Double = 0
    var maximumEnqueueMilliseconds: Double = 0
}

/// Only decoded buffers may be replaced. H.264 dependency frames are never dropped.
struct DisplayLatestDecodedFrame {
    private(set) var pixel: CVPixelBuffer?
    mutating func replace(_ next: CVPixelBuffer) -> Bool { let replaced = pixel != nil; pixel = next; return replaced }
    mutating func take() -> CVPixelBuffer? { defer { pixel = nil }; return pixel }
    mutating func clear() { pixel = nil }
}

@MainActor private final class DisplayVideoSurface: NSView {
    override func makeBackingLayer() -> CALayer {
        let video = AVSampleBufferDisplayLayer(); video.videoGravity = .resizeAspect
        video.backgroundColor = NSColor.black.cgColor
        return video
    }
    var videoLayer: AVSampleBufferDisplayLayer? { layer as? AVSampleBufferDisplayLayer }
}

@MainActor private final class DisplayViewerWindow: NSWindow {
    var escapeCloses=true
    override func cancelOperation(_ sender: Any?) {if escapeCloses{performClose(sender)}}
}

/// Pure geometry matching AVSampleBufferDisplayLayer.videoGravity=.resizeAspect. Point origin is
/// the TOP LEFT of the actual video image, independent of AppKit's bottom-left view.
func displayVideoNormalizedPoint(_ point: CGPoint, bounds: CGRect, clamp: Bool, format: DisplayVideoFormat = .standard) -> CGPoint? {
    guard format.valid, bounds.origin.x.isFinite, bounds.origin.y.isFinite, bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0,
          point.x.isFinite, point.y.isFinite else { return nil }
    let scale = min(bounds.width / CGFloat(format.width), bounds.height / CGFloat(format.height))
    let width = CGFloat(format.width) * scale, height = CGFloat(format.height) * scale
    let image = CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    guard clamp || (point.x >= image.minX && point.x <= image.maxX && point.y >= image.minY && point.y <= image.maxY) else { return nil }
    return CGPoint(x: min(1, max(0, (point.x - image.minX) / width)),
                   y: min(1, max(0, (image.maxY - point.y) / height)))
}

/// Aspect-correct initial content; leaves space for native window decoration.
func displayVideoInitialContentRect(format: DisplayVideoFormat = .standard, visibleFrame: CGRect) -> CGRect {
    guard format.valid, visibleFrame.origin.x.isFinite, visibleFrame.origin.y.isFinite,
          visibleFrame.width.isFinite, visibleFrame.height.isFinite,
          visibleFrame.width > 0, visibleFrame.height > 40 else { return .zero }
    let scale = min(0.5, min(visibleFrame.width * 0.9 / CGFloat(format.width),
                             (visibleFrame.height - 40) * 0.9 / CGFloat(format.height)))
    let size = CGSize(width: CGFloat(format.width) * scale, height: CGFloat(format.height) * scale)
    return CGRect(x: visibleFrame.midX - size.width / 2, y: visibleFrame.midY - size.height / 2,
                  width: size.width, height: size.height)
}

/// One native transition request per viewer lifetime. A bounded failure exposes a
/// usable window; never issue another toggle while AppKit may still be entering.
struct DisplayViewerStartup {
    enum Phase: Equatable { case idle, waitingForWindow, enteringFullScreen, fullScreen, windowed, closed }
    private(set) var phase: Phase = .idle
    var mayPresentVideo: Bool { phase != .idle && phase != .closed }
    var isPending: Bool { phase == .waitingForWindow || phase == .enteringFullScreen }
    mutating func begin(fullScreen: Bool) { phase = fullScreen ? .waitingForWindow : .windowed; rejectedAttempts = 0 }
    mutating func requestIfReady(windowReady: Bool) -> Bool {
        guard phase == .waitingForWindow, windowReady else { return false }
        phase = .enteringFullScreen; return true
    }
    mutating func didEnterFullScreen() {
        guard phase != .closed, phase != .idle else { return }
        phase = .fullScreen
    }
    /// AppKit can reject a toggle while another Space transition settles. Return to
    /// waiting (never issues a toggle itself); the owner bounds attempts and timing.
    private(set) var rejectedAttempts = 0
    mutating func retryAfterRejection(maximumRetries: Int) -> Bool {
        guard phase == .enteringFullScreen, rejectedAttempts < maximumRetries else { return false }
        rejectedAttempts += 1; phase = .waitingForWindow; return true
    }
    @discardableResult mutating func useWindowedFallback() -> Bool {
        guard isPending else { return false }
        phase = .windowed; return true
    }
    mutating func close() { phase = .closed }
}

/// Display link retains its target, so the target must not retain the viewer.
@MainActor private final class DisplayPacingLinkTarget: NSObject {
    weak var owner: DisplayViewer?
    let generation: UInt64
    init(owner: DisplayViewer, generation: UInt64) { self.owner=owner; self.generation=generation }
    @objc func tick(_ sender: AnyObject) {
        guard #available(macOS 14.0, *), let link=sender as? CADisplayLink else { return }
        owner?.displayPacingTick(generation:generation, targetTimestamp:link.targetTimestamp, period:link.targetTimestamp-link.timestamp)
    }
}

@MainActor final class DisplayViewer: NSObject, NSWindowDelegate {
    let format: DisplayVideoFormat
    private let targetScreen: NSScreen?
    private let frameTrace: DisplayFrameTrace
    init(format: DisplayVideoFormat = .standard, targetScreen: NSScreen? = nil, diagnosticStream: String? = DevelopmentDiagnostics.shared.currentStream) {
        self.format = format; self.targetScreen = targetScreen; self.frameTrace = DisplayFrameTrace(stream: diagnosticStream); super.init()
    }
    var startsFullScreen = true
    private var windowEpoch: UInt64 = 0
    private var startup = DisplayViewerStartup()
    private var startupTimer: Timer?
    private var startupDeadline: TimeInterval = 0
    private var entryDeadline: TimeInterval?
    private var fullScreenRetryNotBefore: TimeInterval = 0
    var isVideoPresentationReadyForTests: Bool { startup.mayPresentVideo }
    var acceptsViewerInput=true
    var onClose: (() -> Void)?
    var onWillClose: (() -> Void)?
    /// Only explicit native-window close or locally handled Escape, never codec teardown.
    var onUserClose: (() -> Void)?
    /// Synchronous MAIN-thread local event. Return true ONLY if accepted for remote
    /// forwarding; true consumes it locally. Pointer coordinates use top-left [0,1].
    /// Keys/flags carry nil. Escape is always local stop and is never forwarded.
    var onInput: ((NSEvent, CGPoint?) -> Bool)?
    /// Main-thread signal to release/pause remote INPUT only. Video remains connected.
    var onFocusLost: (() -> Void)?
    /// Parent may re-arm input when the key viewer becomes active again.
    var onFocusGained: (() -> Void)?
    private var localInputMonitor: Any?
    private var forwardedButtons = Set<Int>()
    private var focusArmed = false
    private var viewerWindow: DisplayViewerWindow?
    private var surface: DisplayVideoSurface?
#if TC_NATIVE_VSYNC
    private lazy var pacedFrames = DisplayFramePacer<DisplayTracedFrame>(selectionPolicy: .buffered, cadencePolicy: .displayTargets, onDiscard: { [frameTrace] frame, reason in
        frameTrace.record("pacer_discard", identity: frame.identity, fields: ["reason": Double(reason.rawValue)])
    })
#else
    private lazy var pacedFrames = DisplayFramePacer<DisplayTracedFrame>(onDiscard: { [frameTrace] frame, reason in
        frameTrace.record("pacer_discard", identity: frame.identity, fields: ["reason": Double(reason.rawValue)])
    })
#endif
#if TC_TIMED_PRESENTATION
    private var presentationTimebase: CMTimebase?
    private var scheduledTimeline = DisplayScheduledTimeline()
    private(set) var scheduledSampleCountForTests: UInt64 = 0
    private(set) var lastScheduledPTSForTests: CMTime = .invalid
    private(set) var lastScheduledEnqueueForTests: [String: Double]?
    /// Only promised PTS + nominal duration has elapsed on the attached control
    /// timebase. This is NOT a displayed-frame or physical-scanout observation.
    var targetElapsed: Bool {
        guard let base = surface?.videoLayer?.controlTimebase, lastScheduledPTSForTests.isNumeric else { return false }
        let now = CMTimebaseGetTime(base)
        let end = CMTimeAdd(lastScheduledPTSForTests, CMTime(value: 1, timescale: 60))
        return now.isNumeric && end.isNumeric && CMTimeCompare(now, end) >= 0
    }
    var presentationGenerationForTests: UInt64 { scheduledTimeline.generation }
    var hasPresentationTimebaseForTests: Bool { presentationTimebase != nil && surface?.videoLayer?.controlTimebase != nil }
#endif
    private var pacingLink: AnyObject?
    private var pacingTarget: DisplayPacingLinkTarget?
    private var pacingGeneration: UInt64 = 0
    // Keep an in-flight request occupied across clear/reopen until its callback
    // returns. pacingGeneration retires its result without overlapping requests.
    private var rendererMetricsPending = false
#if TC_DEADLINE_PRESENTATION
    // Two waiting decoded buffers plus at most two future renderer commitments.
    // These are separate explicit bounds, not proof of renderer/panel consumption.
    private var deadlineFrames: [DisplayTracedFrame] = []
    private var deadlinePlan = DisplayDeadlinePlan()
    private var deadlineWake: DispatchWorkItem?
    private var deadlineWakeAt: Double?
    private var deadlineWakeEpoch: UInt64 = 0
    private var deadlineOffered: UInt64 = 0
    private var deadlineOverflow: UInt64 = 0
    private var deadlineLateSkips: UInt64 = 0
    private var deadlineMinimumLeadMs: Double = .infinity
    var maySubmitPresentation: (() -> Bool)?
    private var deadlineMaximumFutureCount = 0
    private var deadlineLastEnqueue: [String: Double]?
    var deadlineFutureCountForTests: Int { deadlinePlan.futureCount }
    var deadlineMaximumFutureForTests: Int { deadlineMaximumFutureCount }
    var deadlineEndLeadForTests: Double { deadlineMinimumLeadMs }
    var deadlineLastEnqueueForTests: [String: Double]? { deadlineLastEnqueue }
#endif
#if TC_IMMEDIATE_PRESENTATION
    // One newest decoded frame only. No app FPS cap, no future PTS wait:
    // macOS composites the latest submitted image at the panel's own refresh.
    private var immediatePending: DisplayTracedFrame?
    private var immediateOffered: UInt64 = 0
    private var immediateReplaced: UInt64 = 0
#if TC_ADAPTIVE_PRESENTATION
    private var adaptiveSlots = DisplayAdaptiveSlots()
    private var adaptiveLastDrops: Double?
#endif
#endif
    private var rendererMetricsRequestedAt: Double?
    private var rendererMetricsSample: [String: Double]?
#if TC_RENDERER_HEALTH
    // Valid-generation native callbacks, not diagnostic rows or panel scanout.
    private var nativeDisplayLinkTicks: UInt64 = 0
    private var nativeTargetGaps: UInt64 = 0
    private var nativePreviousTarget: Double?
    private var nativeTargetGeneration: UInt64?
#endif
    private var displayLinkCadence = DisplayCadenceStats()
    private var readinessRequested = false
    private var readinessEpoch: UInt64 = 0
    private var lastStreamSequence: UInt64?
    private var lastCursorSequence: UInt64?
    private var cursorExpiry: DispatchWorkItem?
    private let cursorOverlay = CALayer()
    private var cursorGlyphs: [UInt8: (CGImage, CGSize, CGPoint)] = [:]
    private var cursorMetadata: DisplayCursorMetadata?
    private var lastDecodedAt: Double = 0
    private var mainVideoCadence = DisplayCadenceStats(), decodedMainCadence = DisplayCadenceStats(), rendererCadence = DisplayCadenceStats()
    private var readinessWait = DisplayTimingStats()
    private var sourceAdmissionTiming = DisplayTimingStats(), sourceEncodeTiming = DisplayTimingStats()
    private var readinessStartedAt: Double?
    private var readinessRegistrations: UInt64 = 0, readinessCallbacks: UInt64 = 0, readinessCancelled: UInt64 = 0
    private var sourceSequenceSkips: UInt64 = 0
    private var cadenceLoggedAt = ProcessInfo.processInfo.systemUptime
    private(set) var presentationStats = DisplayPresentationStats()
    private var decoder: DisplayH264Decoder?
    private var closing = false
    private(set) var receivedFrameCount = 0
    var cursorVisibleForTests: Bool { cursorOverlay.superlayer != nil && cursorOverlay.contents != nil && !cursorOverlay.isHidden }
    var cursorFrameForTests: CGRect { cursorOverlay.frame }
    var readinessRequestedForTests: Bool { readinessRequested }
    var readinessCallbacksForTests: UInt64 { readinessCallbacks }
    var receivedCadenceCountForTests: UInt64 { mainVideoCadence.count }
    var submittedCadenceCountForTests: UInt64 { rendererCadence.count }
    var sourceEncodeSamplesForTests: UInt64 { sourceEncodeTiming.count }
    @discardableResult func requestReadinessForTests() -> Bool {
        guard !closing, !pacedFrames.pending, #available(macOS 14.0, *), let renderer = surface?.videoLayer?.sampleBufferRenderer, renderer.isReadyForMoreMediaData else { return false }
        requestRendererReadiness(renderer); return true
    }
    var isFullScreenForTests: Bool { viewerWindow?.styleMask.contains(.fullScreen) == true }
    var isOpenForSourceOwnership:Bool { !closing && viewerWindow != nil }
    var hasStableSourceOwnership:Bool {
        !closing && viewerWindow?.isVisible == true && viewerWindow?.isKeyWindow == true && NSApp.isActive
    }
    func requestSourceOwnership() {
        guard !closing,let window=viewerWindow else{return}
        if !window.isKeyWindow {window.makeKeyAndOrderFront(nil)}
        if !NSApp.isActive {NSApp.activate(ignoringOtherApps:true)}
    }
    private func startupDiagnostic(_ reason:String,_ window:NSWindow) {
        connectionLog("Viewer fullscreen reason=\(reason) phase=\(startup.phase) active=\(NSApp.isActive) key=\(window.isKeyWindow) visible=\(window.isVisible) fullscreen=\(window.styleMask.contains(.fullScreen))")
    }
    func show() {
        if let viewerWindow { viewerWindow.makeKeyAndOrderFront(nil); return }
        guard format.valid else { return }
        closing = false
        windowEpoch &+= 1
        let epoch = windowEpoch
        startup.begin(fullScreen: startsFullScreen)
        let screen = targetScreen ?? NSScreen.main ?? NSScreen.screens.first
        let available = screen.map { $0.visibleFrame.intersection($0.frame) } ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let content = displayVideoInitialContentRect(format: format, visibleFrame: available)
        guard content.width > 0, content.height > 0 else { return }
        let window = DisplayViewerWindow(contentRect: content,
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.escapeCloses=acceptsViewerInput
        window.title = TCText("Mac mini Extended Display")
        window.backgroundColor = .black; window.isReleasedWhenClosed = false
        // Keep video visible independently of native fullscreen/keyboard ownership.
        window.alphaValue = 1
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.fullScreenPrimary]; window.contentMinSize = NSSize(width: min(320, content.width), height: min(320, content.width) * CGFloat(format.height) / CGFloat(format.width))
        window.contentAspectRatio = format.size
        let view = DisplayVideoSurface(frame: window.contentView?.bounds ?? .zero)
        view.autoresizingMask = [.width, .height]; view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        window.contentView = view; window.delegate = self
        surface = view; viewerWindow = window;installFocusObservers();if acceptsViewerInput{installLocalInputMonitor()}
        // Center the decorated frame on the preferred screen, not NSWindow.center().
        var frame = window.frame
        frame.origin = CGPoint(x: available.midX - frame.width / 2, y: available.midY - frame.height / 2)
        window.setFrame(frame, display: false); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if startsFullScreen {
            startupDeadline = ProcessInfo.processInfo.systemUptime + 5; entryDeadline=nil
            startupDiagnostic("waiting-window",window)
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let self, let window, !self.closing, self.windowEpoch == epoch,
                          self.viewerWindow === window else { return }
                    self.advanceFullScreenStartup(window)
                }
            }
            startupTimer = timer; RunLoop.main.add(timer, forMode: .common)
        }
    }
    private func advanceFullScreenStartup(_ window: NSWindow) {
        guard startup.isPending else { return }
        let now=ProcessInfo.processInfo.systemUptime
        if let deadline=entryDeadline,now>=deadline {
            finishFullScreenFallback(window,reason:"entry-timeout");return
        }
        if entryDeadline==nil,now>=startupDeadline {
            finishFullScreenFallback(window,reason:"window-readiness-timeout");return
        }
        guard now >= fullScreenRetryNotBefore else { return }
        if startup.requestIfReady(windowReady: window.isVisible && window.isKeyWindow && NSApp.isActive) {
            entryDeadline=now+8
            startupDiagnostic("native-request",window)
            window.toggleFullScreen(nil)
        }
    }
    private func finishFullScreenFallback(_ window: NSWindow,reason:String) {
        guard startup.useWindowedFallback() else { return }
        startupDiagnostic(reason,window)
        startupTimer?.invalidate(); startupTimer = nil
        window.alphaValue = 1
        window.title = TCText("Mac mini Extended Display") + " (" + TCText("Full screen unavailable; using a window") + ")"
        NSLog("ThunderControl: native fullscreen startup failed or timed out; keeping a usable viewer window (no automatic toggle retry).")
        drainPresentation()
    }
    func windowDidEnterFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === viewerWindow, !closing else { return }
        startup.didEnterFullScreen()
        startupDiagnostic("entered",window)
        startupTimer?.invalidate(); startupTimer = nil
        window.title = TCText("Mac mini Extended Display"); window.alphaValue = 1
        drainPresentation()
    }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        guard window === viewerWindow, !closing else { return }
        if startup.retryAfterRejection(maximumRetries: 2) {
            let now = ProcessInfo.processInfo.systemUptime
            fullScreenRetryNotBefore = now + 0.75
            entryDeadline = nil; startupDeadline = now + 5
            startupDiagnostic("appkit-rejected-retry-\(startup.rejectedAttempts)", window)
            if startupTimer == nil {
                let epoch = windowEpoch
                let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self, weak window] _ in
                    MainActor.assumeIsolated {
                        guard let self, let window, !self.closing, self.windowEpoch == epoch,
                              self.viewerWindow === window else { return }
                        self.advanceFullScreenStartup(window)
                    }
                }
                startupTimer = timer; RunLoop.main.add(timer, forMode: .common)
            }
            return
        }
        finishFullScreenFallback(window,reason:"appkit-rejected")
    }
    func accept(_ payload: Data, guardMilliseconds: Double? = nil) throws {
        let preAcceptStartedAt = ProcessInfo.processInfo.systemUptime
        guard viewerWindow != nil, !closing else { throw DisplayVideoError.decoderFailed }
        if decoder == nil {
            decoder = DisplayH264Decoder(format: self.format, trace: frameTrace, tracedOutput: { [weak self] pixel, identity in self?.present(pixel, identity: identity) }, output: { _ in }, failure: { [weak self] in self?.close() })
        }
        var video = payload
        var packetSequence: UInt64?
        if payload.first == 6 {
            let frame = try DisplayStreamFrame(payload)
            guard lastStreamSequence.map({frame.sequence > $0}) ?? true else { throw DisplayVideoError.malformed }
            if let previous = lastStreamSequence, frame.sequence-previous > 1 { sourceSequenceSkips &+= frame.sequence-previous-1 }
            lastStreamSequence = frame.sequence; video = frame.video; packetSequence = frame.sequence
            sourceAdmissionTiming.record(Double(frame.encodeStart-frame.capture)/1000)
            sourceEncodeTiming.record(Double(frame.encodeEnd-frame.encodeStart)/1000)
            if frame.sequence % 120 == 0 {
                displayStageLog("Display source stages us: captureArrivalToEncode=\(frame.encodeStart-frame.capture) encode=\(frame.encodeEnd-frame.encodeStart); remoteClockOffset=unknown panelLatency=unmeasured")
            }
        }
        mainVideoCadence.observe(ProcessInfo.processInfo.systemUptime)
        logCadence()
        let acceptedAt = ProcessInfo.processInfo.systemUptime
        var acceptFields: [String: Double] = ["time": acceptedAt, "preAcceptMs": (acceptedAt-preAcceptStartedAt)*1000, "preAcceptStart": preAcceptStartedAt]
        if let guardMilliseconds, guardMilliseconds.isFinite, guardMilliseconds >= 0 { acceptFields["guardMs"] = guardMilliseconds }
        frameTrace.record("receiver_accept", sequence: packetSequence, fields: acceptFields)
        do { try decoder!.accept(video, sourceSequence: packetSequence) } catch { clear(); throw error }
    }
    private func present(_ pixel: CVPixelBuffer, identity: DisplayFrameIdentity) {
        guard !closing, surface != nil, viewerWindow != nil else { return }
        lastDecodedAt = ProcessInfo.processInfo.systemUptime
        decodedMainCadence.observe(lastDecodedAt)
        receivedFrameCount += 1; presentationStats.decoded &+= 1
        // Record the exact receiver-local clock passed to the pacing policy.
        let pacingArrival = CACurrentMediaTime()
        frameTrace.record("pacer_offer", identity: identity, fields: ["time": lastDecodedAt, "offerTime": pacingArrival, "pending": Double(pacedFrames.pendingCount)])
#if TC_DEADLINE_PRESENTATION
        deadlineOffered &+= 1
        if deadlineFrames.count == 2 {
            let old = deadlineFrames.removeFirst(); deadlineOverflow &+= 1
            presentationStats.replacedDecoded &+= 1
            frameTrace.record("pacer_discard", identity: old.identity, fields: ["reason": 2])
        }
        deadlineFrames.append(DisplayTracedFrame(pixel: pixel, identity: identity, decodedMainAt: lastDecodedAt))
#elseif TC_IMMEDIATE_PRESENTATION
        immediateOffered &+= 1
        if let old = immediatePending {
            immediateReplaced &+= 1; presentationStats.replacedDecoded &+= 1
            frameTrace.record("pacer_discard", identity: old.identity, fields: ["reason": 2])
        }
        immediatePending = DisplayTracedFrame(pixel: pixel, identity: identity, decodedMainAt: lastDecodedAt)
#else
        if pacedFrames.offer(DisplayTracedFrame(pixel: pixel, identity: identity, decodedMainAt: lastDecodedAt), at:pacingArrival) { presentationStats.replacedDecoded &+= 1 }
#endif
        drainPresentation()
    }
    private func ensurePacingLink() {
        guard pacingLink == nil, !closing, let surface, #available(macOS 14.0, *) else { return }
#if TC_TIMED_PRESENTATION
        guard configurePresentationTimebase() else { close(); return }
#endif
        pacingGeneration &+= 1
        let target=DisplayPacingLinkTarget(owner:self,generation:pacingGeneration)
        let link=surface.displayLink(target:target,selector:#selector(DisplayPacingLinkTarget.tick(_:)))
        link.preferredFrameRateRange=CAFrameRateRange(minimum:60,maximum:60,preferred:60)
        pacingTarget=target; pacingLink=link
        link.add(to:.main,forMode:.common)
    }
#if TC_TIMED_PRESENTATION
    private func configurePresentationTimebase() -> Bool {
        guard let layer = surface?.videoLayer else { return false }
        let clock = CMClockGetHostTimeClock()
        let before = CACurrentMediaTime(), host = CMClockGetTime(clock), after = CACurrentMediaTime()
        guard scheduledTimeline.calibrate(caBefore: before, host: host, caAfter: after) else { return false }
        var base: CMTimebase?
        guard CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: clock, timebaseOut: &base) == noErr,
              let base, CMTimebaseSetRateAndAnchorTime(base, rate: 1, anchorTime: .zero, immediateSourceTime: host) == noErr else { return false }
        presentationTimebase = base; layer.controlTimebase = base
        return true
    }
#endif
    private func stopPacingLink() {
        pacingGeneration &+= 1
        if #available(macOS 14.0, *) { (pacingLink as? CADisplayLink)?.invalidate() }
        pacingLink=nil; pacingTarget=nil
#if TC_TIMED_PRESENTATION
        // Flush relative-PTS samples before removing their interpreting timebase.
        if #available(macOS 14.0, *) {
            surface?.videoLayer?.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        }
        surface?.videoLayer?.controlTimebase = nil
        presentationTimebase = nil; scheduledTimeline.reset()
        scheduledSampleCountForTests = 0; lastScheduledPTSForTests = .invalid; lastScheduledEnqueueForTests = nil
#endif
    }
    fileprivate func displayPacingTick(generation:UInt64,targetTimestamp:Double,period:Double = 1.0/60.0) {
        frameTrace.record("displaylink_tick", fields: ["time": CACurrentMediaTime(), "target": targetTimestamp, "generation": Double(generation), "currentGeneration": Double(pacingGeneration), "closing": closing ? 1 : 0, "active": pacingLink != nil ? 1 : 0, "pending": Double(pacedFrames.pendingCount)])
        guard !closing, generation == pacingGeneration, pacingLink != nil else { return }
#if TC_RENDERER_HEALTH
        nativeDisplayLinkTicks &+= 1
        // Diagnostic only: delivered callbacks can omit/coalesce nominal slots.
        // Never use this observation to gate enqueue or claim panel scanout.
        if nativeTargetGeneration != generation {
            nativeTargetGeneration = generation; nativePreviousTarget = nil
        }
        if targetTimestamp.isFinite, targetTimestamp >= 0 {
            if let previous = nativePreviousTarget, targetTimestamp - previous > 1.5 / 60 {
                nativeTargetGaps &+= 1
            }
            nativePreviousTarget = targetTimestamp
        }
#endif
        displayLinkCadence.observe(ProcessInfo.processInfo.systemUptime)
#if TC_DEADLINE_PRESENTATION
        guard deadlinePlan.observe(now: CACurrentMediaTime(), target: targetTimestamp, period: period) else {
            if deadlinePlan.needsReset { close() }
            return
        }
#endif
#if TC_ADAPTIVE_PRESENTATION
        adaptiveSlots.observe(target: targetTimestamp, period: period, now: CACurrentMediaTime())
#endif
        drainPresentation(targetTimestamp:targetTimestamp)
    }
    var rendererMetricsForTests: [String: Double]? { rendererMetricsSample }
    var rendererMetricsPendingForTests: Bool { rendererMetricsPending }
    @discardableResult func requestRendererMetricsForTests() -> Bool { requestRendererMetrics() }
    var pacingActiveForTests: Bool { pacingLink != nil }
    var pacingTicksForTests: UInt64 { displayLinkCadence.count }
    var pacingPendingForTests: Int {
#if TC_DEADLINE_PRESENTATION
        deadlineFrames.count
#elseif TC_IMMEDIATE_PRESENTATION
        immediatePending == nil ? 0 : 1
#else
        pacedFrames.pendingCount
#endif
    }
    private func drainPresentation(targetTimestamp:Double? = nil) {
        guard !closing, startup.mayPresentVideo, let layer = surface?.videoLayer else { return }
        ensurePacingLink()
#if TC_DEADLINE_PRESENTATION
        drainDeadlinePresentation()
        return
#endif
#if TC_IMMEDIATE_PRESENTATION
        drainImmediatePresentation(layer)
        return
#endif
        // Decode and renderer-readiness callbacks only queue/wake. Enqueue happens
        // exclusively on the display-link callback, never on packet arrival.
        guard let targetTimestamp else { return }
        guard #available(macOS 14.0, *) else { close(); return }
        let renderer = layer.sampleBufferRenderer
        guard renderer.status != .failed else {
            frameTrace.record("renderer_failure", fields: ["status": Double(renderer.status.rawValue)])
            close(); return
        }
        let rendererReady = renderer.isReadyForMoreMediaData
        let pacingNow = CACurrentMediaTime()
        frameTrace.record("renderer_control", fields: ["time": pacingNow, "pacingNow": pacingNow, "target": targetTimestamp, "ready": rendererReady ? 1 : 0, "status": Double(renderer.status.rawValue), "pending": Double(pacedFrames.pendingCount), "readinessRequested": readinessRequested ? 1 : 0, "deferrals": Double(presentationStats.readinessDeferrals), "registrations": Double(readinessRegistrations), "callbacks": Double(readinessCallbacks)])
        guard rendererReady else {
            presentationStats.readinessDeferrals &+= 1
            requestRendererReadiness(renderer)
            return
        }
        stopReadiness(ready: true)
        guard let frame = pacedFrames.take(now:pacingNow,targetTimestamp:targetTimestamp) else { return }
        frameTrace.record("pacer_select", identity: frame.identity, fields: ["target": targetTimestamp, "time": CACurrentMediaTime(), "pacingNow": pacingNow, "pending": Double(pacedFrames.pendingCount)])
        let started = ProcessInfo.processInfo.systemUptime
        do {
#if TC_TIMED_PRESENTATION
            // Re-read clocks after sample selection: a delayed tick must not enqueue
            // an old target. No immediate fallback in the timed experiment.
            let caNow = CACurrentMediaTime(), hostNow = CMClockGetTime(CMClockGetHostTimeClock())
            guard presentationTimebase != nil,
                  let timing = scheduledTimeline.timing(target: targetTimestamp, caNow: caNow, hostNow: hostNow, generation: scheduledTimeline.generation) else {
                frameTrace.record("renderer_control", identity: frame.identity, fields: ["target": targetTimestamp, "time": caNow, "scheduledSkipped": 1, "targetLeadMs": (targetTimestamp-caNow)*1000]); return
            }
            let sample = try displayScheduledImageSample(frame.pixel, format: self.format, timing: timing)
            guard targetTimestamp > CACurrentMediaTime(),
                  CMTimeCompare(timing.presentationTimeStamp, CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), scheduledTimeline.hostAnchor)) > 0 else {
                frameTrace.record("renderer_control", identity: frame.identity, fields: ["target": targetTimestamp, "time": CACurrentMediaTime(), "scheduledSkipped": 1, "targetLeadMs": (targetTimestamp-CACurrentMediaTime())*1000]); return
            }
            scheduledTimeline.commit(timing)
            scheduledSampleCountForTests &+= 1; lastScheduledPTSForTests = timing.presentationTimeStamp
#else
            let sample = try displayImmediateImageSample(frame.pixel, format: self.format)
#endif
#if TC_TIMED_PRESENTATION
            let enqueueCA = CACurrentMediaTime(), enqueueHost = CMClockGetTime(CMClockGetHostTimeClock())
#endif
            renderer.enqueue(sample)
            var enqueueFields = ["time": ProcessInfo.processInfo.systemUptime, "decodedMainToEnqueueMs": (ProcessInfo.processInfo.systemUptime-frame.decodedMainAt)*1000]
#if TC_TIMED_PRESENTATION
            enqueueFields["scheduled"] = 1
            enqueueFields["scheduledPTS"] = timing.presentationTimeStamp.seconds
            enqueueFields["scheduledDuration"] = timing.duration.seconds
            enqueueFields["target"] = targetTimestamp
            enqueueFields["targetHostTime"] = CMTimeAdd(scheduledTimeline.hostAnchor, timing.presentationTimeStamp).seconds
            enqueueFields["enqueueHostTime"] = enqueueHost.seconds
            enqueueFields["enqueueCA"] = enqueueCA
            enqueueFields["enqueueEndCA"] = CACurrentMediaTime()
            enqueueFields["targetLeadMs"] = (targetTimestamp-enqueueCA)*1000
            enqueueFields["presentationGeneration"] = Double(scheduledTimeline.generation)
            lastScheduledEnqueueForTests = enqueueFields
#endif
            frameTrace.record("renderer_enqueue", identity: frame.identity, fields: enqueueFields)
            rendererCadence.observe(ProcessInfo.processInfo.systemUptime)
            presentationStats.submitted &+= 1
            updateCursorOverlay()
            if presentationStats.submitted % 120 == 0 {
                displayStageLog("Display receiver stages ms: decodedMainToRendererSubmit=\((ProcessInfo.processInfo.systemUptime-frame.decodedMainAt)*1000); enqueueNotPanel=true crossHostLatency=unknown")
            }
            let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1000
            presentationStats.totalEnqueueMilliseconds += elapsed
            presentationStats.maximumEnqueueMilliseconds = max(presentationStats.maximumEnqueueMilliseconds, elapsed)
            logCadence()
        } catch { close() }
    }
#if TC_DEADLINE_PRESENTATION
    /// Uses receiver-local host PTS directly, per AVSampleBufferDisplayLayer's nil
    /// controlTimebase contract. AppKit ownership stays on main. Already queued
    /// samples can survive a short main stall; main itself is not made realtime.
    private func drainDeadlinePresentation() {
        guard !closing, startup.mayPresentVideo, let layer = surface?.videoLayer,
              #available(macOS 14.0, *) else { return }
        guard maySubmitPresentation?() ?? true else { close(); return }
        let renderer = layer.sampleBufferRenderer
        guard renderer.status != .failed else { close(); return }
        // Retirement is clock accounting, not a readiness or scanout result.
        // Do it even when the renderer is backpressured to avoid stale wakes.
        _ = deadlinePlan.nextTarget(now: CACurrentMediaTime())
        for _ in 0..<2 {
            guard !deadlineFrames.isEmpty else { break }
            guard renderer.isReadyForMoreMediaData else {
                presentationStats.readinessDeferrals &+= 1
                deadlineWake?.cancel(); deadlineWake = nil; deadlineWakeAt = nil
                deadlineWakeEpoch &+= 1
                requestRendererReadiness(renderer); return
            }
            let now = CACurrentMediaTime()
            guard let target = deadlinePlan.nextTarget(now: now) else { break }
            // Validate the slot before removing a frame. Never backdate, duplicate
            // an image, or feed unbounded future PTS to a ready renderer.
            guard maySubmitPresentation?() ?? true else { close(); return }
            let frame = deadlineFrames[0]
            do {
                let sample = try displayDeadlineImageSample(frame.pixel, format: format, target: target)
                let enqueueCA = CACurrentMediaTime()
                guard let period = deadlinePlan.period, target-enqueueCA >= period else {
                    deadlineLateSkips &+= 1; break
                }
                guard deadlinePlan.commit(target: target, now: enqueueCA) else { break }
                deadlineFrames.removeFirst()
                renderer.enqueue(sample)
                let end = CACurrentMediaTime()
                deadlineMaximumFutureCount = max(deadlineMaximumFutureCount, deadlinePlan.futureCount)
                deadlineLastEnqueue = ["target": target, "enqueueCA": enqueueCA, "enqueueEndCA": end,
                    "targetEndLeadMs": (target-end)*1000, "future": Double(deadlinePlan.futureCount)]
                deadlineMinimumLeadMs = min(deadlineMinimumLeadMs, (target-end)*1000)
                presentationStats.submitted &+= 1
                rendererCadence.observe(ProcessInfo.processInfo.systemUptime)
                frameTrace.record("renderer_enqueue", identity: frame.identity, fields: [
                    "time": ProcessInfo.processInfo.systemUptime,
                    "decodedMainToEnqueueMs": (ProcessInfo.processInfo.systemUptime-frame.decodedMainAt)*1000,
                    "scheduled": 1, "scheduledPTS": target, "target": target,
                    "enqueueCA": enqueueCA, "enqueueEndCA": end,
                    "targetLeadMs": (target-enqueueCA)*1000,
                    "targetEndLeadMs": (target-end)*1000,
                    "future": Double(deadlinePlan.futureCount), "waiting": Double(deadlineFrames.count)])
                updateCursorOverlay(); logCadence()
            } catch { close(); return }
        }
        armDeadlineWake()
    }
    private func armDeadlineWake() {
        let now = CACurrentMediaTime()
        guard !closing, let at = deadlinePlan.nextRetirement,
              let delay = DisplayDeadlinePlan.wakeDelay(now: now, retirement: at,
                hasWaiting: !deadlineFrames.isEmpty, waitingForReadiness: readinessRequested) else { return }
        if let previous = deadlineWakeAt, previous <= at { return }
        deadlineWake?.cancel()
        let token = pacingGeneration
        deadlineWakeEpoch &+= 1
        let wakeEpoch = deadlineWakeEpoch
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.closing, self.pacingGeneration == token, self.deadlineWakeEpoch == wakeEpoch else { return }
                self.deadlineWake = nil; self.deadlineWakeAt = nil
                self.drainDeadlinePresentation()
            }
        }
        deadlineWake = work; deadlineWakeAt = at
        DispatchQueue.main.asyncAfter(deadline: .now()+delay, execute: work)
    }
#endif
#if TC_IMMEDIATE_PRESENTATION
    /// Decode arrival and renderer readiness submit immediately. The display
    /// link remains only as a diagnostic clock; it never gates submission.
    private func drainImmediatePresentation(_ layer: AVSampleBufferDisplayLayer) {
        guard #available(macOS 14.0, *), let frame = immediatePending else { return }
        let renderer = layer.sampleBufferRenderer
        guard renderer.status != .failed else {
            frameTrace.record("renderer_failure", fields: ["status": Double(renderer.status.rawValue)])
            close(); return
        }
        guard renderer.isReadyForMoreMediaData else {
            presentationStats.readinessDeferrals &+= 1
            requestRendererReadiness(renderer); return
        }
        stopReadiness(ready: true)
        immediatePending = nil
        let started = ProcessInfo.processInfo.systemUptime
        do {
#if TC_ADAPTIVE_PRESENTATION
            // Spread bunched arrivals one per panel slot with the smallest safe lead.
            let decision = adaptiveSlots.decide(now: CACurrentMediaTime())
            if decision == .drop {
                presentationStats.replacedDecoded &+= 1
                frameTrace.record("pacer_discard", identity: frame.identity, fields: ["reason": 2])
                return
            }
            var slotTarget: Double?
            if case .slot(let t) = decision { slotTarget = t }
            let sample = try slotTarget.map { try displayDeadlineImageSample(frame.pixel, format: self.format, target: $0) }
                ?? displayImmediateImageSample(frame.pixel, format: self.format)
            let traceTarget = slotTarget ?? 0
#else
            let sample = try displayImmediateImageSample(frame.pixel, format: self.format)
            let traceTarget = 0.0
#endif
            renderer.enqueue(sample)
            let now = ProcessInfo.processInfo.systemUptime
            frameTrace.record("renderer_enqueue", identity: frame.identity, fields: [
                "time": now, "decodedMainToEnqueueMs": (now-frame.decodedMainAt)*1000, "immediate": 1, "target": traceTarget])
            rendererCadence.observe(now)
            presentationStats.submitted &+= 1
            updateCursorOverlay()
            let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1000
            presentationStats.totalEnqueueMilliseconds += elapsed
            presentationStats.maximumEnqueueMilliseconds = max(presentationStats.maximumEnqueueMilliseconds, elapsed)
            logCadence()
        } catch { close() }
    }
#endif
    @available(macOS 14.0, *) private func requestRendererReadiness(_ renderer: AVSampleBufferVideoRenderer) {
        guard !readinessRequested, !closing else { return }
        readinessRequested = true; readinessStartedAt = ProcessInfo.processInfo.systemUptime; readinessRegistrations &+= 1
        let token = readinessEpoch
        renderer.requestMediaDataWhenReady(on: .main) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.readinessEpoch == token, !self.closing else { return }
                self.readinessCallbacks &+= 1
                let ready = self.surface?.videoLayer?.sampleBufferRenderer.isReadyForMoreMediaData == true
                self.stopReadiness(ready: ready)
                self.drainPresentation()
            }
        }
    }
    private func stopReadiness(ready: Bool = false) {
        readinessEpoch &+= 1
        if readinessRequested {
            if ready, let start = readinessStartedAt { readinessWait.record((ProcessInfo.processInfo.systemUptime-start)*1000) }
            else { readinessCancelled &+= 1 }
            if #available(macOS 14.0, *) { surface?.videoLayer?.sampleBufferRenderer.stopRequestingMediaData() }
        }
        readinessRequested = false; readinessStartedAt = nil
    }
    /// Renderer-reported cumulative quality counters, not physical-panel frame
    /// timestamps. Total includes frames that would have displayed without drops;
    /// neither it nor enqueue counts alone establishes stable 60 Hz presentation.
    @discardableResult private func requestRendererMetrics() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        guard !closing, !rendererMetricsPending,
              rendererMetricsRequestedAt.map({ now - $0 >= 2 }) ?? true,
              #available(macOS 14.4, *), let renderer = surface?.videoLayer?.sampleBufferRenderer else { return false }
        rendererMetricsPending = true; rendererMetricsRequestedAt = now
        let generation = pacingGeneration
        renderer.loadVideoPerformanceMetrics { [weak self] metrics in
            // Capture the receiver-local callback time, not when main gets around
            // to logging it. Do not wait on the renderer from the frame path.
            let sampledAt = ProcessInfo.processInfo.systemUptime
            var fields: [String: Double] = ["available": metrics == nil ? 0 : 1, "sampleTime": sampledAt]
            if let metrics {
                fields["totalNumberOfFrames"] = Double(metrics.totalNumberOfFrames)
                fields["numberOfDroppedFrames"] = Double(metrics.numberOfDroppedFrames)
                fields["numberOfCorruptedFrames"] = Double(metrics.numberOfCorruptedFrames)
                fields["totalAccumulatedFrameDelay"] = metrics.totalAccumulatedFrameDelay
            }
            let sample = fields
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.rendererMetricsPending = false
                    guard !self.closing, self.pacingGeneration == generation else { return }
                    var snapshot = sample
#if TC_ADAPTIVE_PRESENTATION
                    if let drops = sample["numberOfDroppedFrames"] {
                        self.adaptiveSlots.adapt(newRendererDrops: drops - (self.adaptiveLastDrops ?? drops))
                        self.adaptiveLastDrops = drops
                    }
#endif
#if TC_RENDERER_HEALTH
                    // Native counters are sampled on their owner (main). Preserve
                    // AV callback sampleTime separately; never conflate rates
                    // across different observation times, even on the same host.
                    snapshot["counterSampleTime"] = ProcessInfo.processInfo.systemUptime
                    snapshot["generation"] = Double(self.pacingGeneration)
                    snapshot["displayLinkTicks"] = Double(self.nativeDisplayLinkTicks)
                    snapshot["submitted"] = Double(self.presentationStats.submitted)
                    let pacing = self.pacedFrames.stats
                    snapshot["pacerOffered"] = Double(pacing.offered)
                    snapshot["pacerSelected"] = Double(pacing.selected)
                    snapshot["pacerOverflow"] = Double(pacing.overflowReplaced)
                    snapshot["pacerSuperseded"] = Double(pacing.superseded)
                    snapshot["pacerEmpty"] = Double(pacing.emptyTicks)
                    snapshot["pacerWaiting"] = Double(pacing.waitingTicks)
                    snapshot["pacerInvalid"] = Double(pacing.invalidInputs)
#if TC_IMMEDIATE_PRESENTATION
                    snapshot["pacerOffered"] = Double(self.immediateOffered)
                    snapshot["pacerSelected"] = Double(self.presentationStats.submitted)
                    snapshot["pacerOverflow"] = Double(self.immediateReplaced)
#endif
#if TC_DEADLINE_PRESENTATION
                    snapshot["pacerOffered"] = Double(self.deadlineOffered)
                    snapshot["pacerSelected"] = Double(self.presentationStats.submitted)
                    snapshot["pacerOverflow"] = Double(self.deadlineOverflow)
                    snapshot["scheduledMode"] = 1
                    snapshot["scheduledFuture"] = Double(self.deadlinePlan.futureCount)
                    snapshot["scheduledLateSkips"] = Double(self.deadlineLateSkips)
                    snapshot["scheduledMinLeadMs"] = self.deadlineMinimumLeadMs.isFinite ? self.deadlineMinimumLeadMs : 0
#elseif TC_ADAPTIVE_PRESENTATION
                    snapshot["scheduledMode"] = 2
                    snapshot["scheduledFuture"] = Double(self.adaptiveSlots.scheduled)
                    snapshot["scheduledLateSkips"] = Double(self.adaptiveSlots.dropped)
                    snapshot["scheduledMinLeadMs"] = self.adaptiveSlots.averageAddedDelay * 1000
#else
                    snapshot["targetDuplicate"] = Double(pacing.duplicateTargetTicks)
                    snapshot["targetExpired"] = Double(pacing.expiredTargetTicks)
                    snapshot["targetLimited"] = Double(pacing.targetLimitedTicks)
                    snapshot["pacerRateLimited"] = Double(pacing.rateLimitedTicks)
#endif
                    snapshot["targetGaps"] = Double(self.nativeTargetGaps)
                    snapshot["readinessDeferrals"] = Double(self.presentationStats.readinessDeferrals)
                    if let sequence = self.lastStreamSequence { snapshot["lastSourceSequence"] = Double(sequence) }
#endif
                    // Platform metrics must not poison a finite JSON record.
                    snapshot = snapshot.filter { $0.value.isFinite }
                    self.rendererMetricsSample = snapshot
                    self.frameTrace.record("renderer_metrics", fields: snapshot)
                    if let total = sample["totalNumberOfFrames"], let dropped = sample["numberOfDroppedFrames"],
                       let corrupted = sample["numberOfCorruptedFrames"], let delay = sample["totalAccumulatedFrameDelay"] {
                        displayStageLog("Display renderer metrics: available=true total=\(total) dropped=\(dropped) corrupted=\(corrupted) accumulatedFrameDelaySeconds=\(delay) receiverSampleTime=\(sampledAt); rendererCountersNotPanel=true stable60Unproven=true")
                    } else {
                        displayStageLog("Display renderer metrics: available=false receiverSampleTime=\(sampledAt); rendererCountersNotPanel=true")
                    }
                }
            }
        }
        return true
    }
    private func logCadence(force: Bool = false) {
#if TC_NATIVE_VSYNC
        let pacingPolicyDescription = "buffered display-target-slots no-wall-budget hardAgeCap=false pacingHoldNominalMs=0"
#elseif TC_LATEST_DECODED
        let pacingPolicyDescription = "latest-decoded hardAgeCap=false pacingHoldNominalMs=0"
#else
        let pacingPolicyDescription = "fifo25 catchUpAgeMs=25 hardAgeCap=false pacingHoldNominalMs=16.667"
#endif
        let now = ProcessInfo.processInfo.systemUptime
        guard mainVideoCadence.count > 0, force || now-cadenceLoggedAt >= 2 else { return }
        cadenceLoggedAt = now
        if !force { requestRendererMetrics() }
        displayStageLog("Display cadence viewer: encodedMain[\(mainVideoCadence.summary)] decodedMain[\(decodedMainCadence.summary)] rendererEnqueue[\(rendererCadence.summary)] sourceAdmission[\(sourceAdmissionTiming.summary)] sourceEncode[\(sourceEncodeTiming.summary)] sourceEncodeSequenceSkips=\(sourceSequenceSkips) latestDecodedReplaced=\(presentationStats.replacedDecoded) readinessDeferrals=\(presentationStats.readinessDeferrals) registrations=\(readinessRegistrations) callbacks=\(readinessCallbacks) cancelled=\(readinessCancelled) readinessWait[\(readinessWait.summary)] displayLink[\(displayLinkCadence.summary)] pacedPending=\(pacedFrames.pendingCount) pacing=\(pacedFrames.stats); pacingPolicy=\(pacingPolicyDescription) contentMayBeIdle=true enqueueNotPanel=true final=\(force)")
    }
    func acceptCursor(_ payload: Data) throws {
        let next = try DisplayCursorMetadata(payload)
        guard !closing, viewerWindow != nil, lastCursorSequence.map({next.sequence > $0}) ?? true else { throw DisplayVideoError.malformed }
        lastCursorSequence = next.sequence; cursorMetadata = next
        cursorExpiry?.cancel()
        let token = windowEpoch, cursorSequence = next.sequence
        let expiry = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { guard let self, self.windowEpoch == token, self.lastCursorSequence == cursorSequence else { return }; self.cursorOverlay.isHidden = true; self.cursorMetadata = nil }
        }
        cursorExpiry = expiry; DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: expiry)
        updateCursorOverlay()
    }
    private func updateCursorOverlay() {
        guard let surface, let m = cursorMetadata else { cursorOverlay.isHidden = true; return }
        let bounds = surface.bounds
        let scale = min(bounds.width / CGFloat(format.width), bounds.height / CGFloat(format.height))
        let width = CGFloat(format.width)*scale, height = CGFloat(format.height)*scale
        if cursorGlyphs[m.shape] == nil {
            // Cache hit avoids AppKit cursor lookup; image and hotspot unchanged.
            let cursor: NSCursor
            switch m.shape { case 1: cursor = .iBeam; case 2: cursor = .crosshair; case 3: cursor = .pointingHand; case 4: cursor = .closedHand; default: cursor = .arrow }
            var rect = CGRect(origin: .zero, size: cursor.image.size)
            guard let image = cursor.image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { cursorOverlay.isHidden = true; return }
            cursorGlyphs[m.shape] = (image, cursor.image.size, cursor.hotSpot)
        }
        guard let (image, size, hotSpot) = cursorGlyphs[m.shape], let layer = surface.layer else { cursorOverlay.isHidden = true; return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if cursorOverlay.superlayer !== layer { layer.addSublayer(cursorOverlay) }
        cursorOverlay.contents = image; cursorOverlay.contentsGravity = .resize
        cursorOverlay.frame = CGRect(x: (bounds.width-width)/2 + m.x*width-hotSpot.x,
            y: (bounds.height-height)/2 + (1-m.y)*height-(size.height-hotSpot.y), width: size.width, height: size.height)
        cursorOverlay.zPosition = 100; cursorOverlay.isHidden = !m.visible
        CATransaction.commit()
    }
    func clear() {
        forwardedButtons.removeAll()
        stopReadiness(); stopPacingLink()
        rendererMetricsSample = nil
        logCadence(force: true)
        pacedFrames.clear(); displayLinkCadence=DisplayCadenceStats()
#if TC_IMMEDIATE_PRESENTATION
        immediatePending = nil; immediateOffered = 0; immediateReplaced = 0
#if TC_ADAPTIVE_PRESENTATION
        adaptiveSlots.reset(); adaptiveLastDrops = nil
#endif
#endif
#if TC_DEADLINE_PRESENTATION
        deadlineWake?.cancel(); deadlineWake = nil; deadlineWakeAt = nil
        deadlineWakeEpoch &+= 1
        deadlineFrames.removeAll(); deadlinePlan.reset()
        deadlineOffered = 0; deadlineOverflow = 0; deadlineLateSkips = 0
        deadlineMinimumLeadMs = .infinity
        deadlineMaximumFutureCount = 0; deadlineLastEnqueue = nil
#endif
#if TC_RENDERER_HEALTH
        nativeDisplayLinkTicks = 0; nativeTargetGaps = 0
        nativePreviousTarget = nil; nativeTargetGeneration = nil
#endif
        cursorExpiry?.cancel(); cursorExpiry = nil; cursorMetadata = nil; cursorOverlay.removeFromSuperlayer(); cursorGlyphs.removeAll()
        lastCursorSequence = nil; lastStreamSequence = nil; lastDecodedAt = 0
        mainVideoCadence = DisplayCadenceStats(); decodedMainCadence = DisplayCadenceStats(); rendererCadence = DisplayCadenceStats()
        readinessWait = DisplayTimingStats(); sourceAdmissionTiming = DisplayTimingStats(); sourceEncodeTiming = DisplayTimingStats(); readinessRegistrations = 0; readinessCallbacks = 0; readinessCancelled = 0; sourceSequenceSkips = 0
        cadenceLoggedAt = ProcessInfo.processInfo.systemUptime
        decoder?.clear(); decoder = nil; receivedFrameCount = 0
        presentationStats = DisplayPresentationStats()
#if !TC_TIMED_PRESENTATION
        if #available(macOS 14.0, *), let layer = surface?.videoLayer {
            layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        }
#endif
    }
    func close() {
        guard !closing else { return }; onWillClose?(); closing = true
        startup.close(); startupTimer?.invalidate(); startupTimer = nil
        removeLocalInputMonitor(); reportFocusLost()
        clear()
        let old = viewerWindow; viewerWindow = nil; surface = nil; old?.delegate = nil; old?.close()
        onClose?()
    }
    private func installLocalInputMonitor() {
        guard localInputMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged, .mouseMoved,
            .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp,
            .rightMouseDragged, .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel]
        localInputMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }; return self.handleLocalInput(event)
        }
    }
    private func installFocusObservers() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(appDidResignActive), name: NSApplication.didResignActiveNotification, object: NSApp)
        center.addObserver(self, selector: #selector(appDidBecomeActive), name: NSApplication.didBecomeActiveNotification, object: NSApp)
    }
    @objc private func appDidResignActive(_ notification: Notification) { reportFocusLost() }
    @objc private func appDidBecomeActive(_ notification: Notification) {
        reportFocusGained()
    }
    private func removeLocalInputMonitor() {
        if let localInputMonitor { NSEvent.removeMonitor(localInputMonitor) }; localInputMonitor = nil
        NotificationCenter.default.removeObserver(self, name: NSApplication.didResignActiveNotification, object: NSApp)
        NotificationCenter.default.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: NSApp)
        forwardedButtons.removeAll()
    }
    private func reportFocusLost() {
        forwardedButtons.removeAll()
        guard focusArmed else { return }; focusArmed = false
        onFocusLost?()
    }
    private func reportFocusGained() {
        guard !closing, NSApp.isActive, viewerWindow?.isKeyWindow == true, !focusArmed else { return }
        focusArmed = true; onFocusGained?()
    }
    func windowDidBecomeKey(_ notification: Notification) { reportFocusGained() }
    func windowDidResignKey(_ notification: Notification) { reportFocusLost() }
    private func handleLocalInput(_ event: NSEvent) -> NSEvent? {
        guard !closing, NSApp.isActive, let window = viewerWindow, window.isKeyWindow,
              event.window === window else { return event }
        if (event.type == .keyDown || event.type == .keyUp), event.keyCode == 53 {
            if event.type == .keyDown { if acceptsViewerInput { onUserClose?() }; close() }; return nil
        }
        guard receivedFrameCount > 0, let onInput else { return event }
        switch event.type {
        case .keyDown, .keyUp, .flagsChanged:
            return onInput(event, nil) ? nil : event
        case .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
             .leftMouseUp, .rightMouseUp, .otherMouseUp, .leftMouseDragged,
             .rightMouseDragged, .otherMouseDragged, .scrollWheel:
            guard let surface else { return event }
            let isUp = [.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(event.type)
            let isDown = [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type)
            let isDrag = [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(event.type)
            // Only a drag/release belonging to an accepted video-area down is clamped.
            // New clicks in the titlebar or letterboxing remain native window actions.
            let held = forwardedButtons.contains(event.buttonNumber)
            if (isUp || isDrag) && !held { return event }
            let point = surface.convert(event.locationInWindow, from: nil)
            guard let normalized = displayVideoNormalizedPoint(point, bounds: surface.bounds,
                clamp: held && (isUp || isDrag), format: self.format) else { return event }
            let accepted = onInput(event, normalized)
            if accepted && isDown && !closing && viewerWindow === window { forwardedButtons.insert(event.buttonNumber) }
            if isUp { forwardedButtons.remove(event.buttonNumber) }
            return accepted ? nil : event
        default: return event
        }
    }
    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === viewerWindow,!closing else { return }; onWillClose?(); closing = true
        startup.close(); startupTimer?.invalidate(); startupTimer = nil
        removeLocalInputMonitor(); reportFocusLost()
        clear(); viewerWindow?.delegate = nil; viewerWindow = nil; surface = nil
        onUserClose?()
        onClose?()
    }
}
