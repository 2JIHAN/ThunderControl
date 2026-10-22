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

/// The VT callback owns no window. At most one pixel buffer and one main-queue delivery
/// are retained, plus at most four codec submissions. Invalidating clears handlers before
/// VT is drained, so an old session cannot paint a newly opened viewer.
private final class DisplayDecodeMailbox {
    let lock = NSLock()
    let format: DisplayVideoFormat
    var valid = true, scheduled = false, inFlight = 0, failed = false
    var submittedAt: [Int64: Double] = [:]
    var latest: CVPixelBuffer?
    var latestCallbackAt: Double?
    var deliver: ((CVPixelBuffer) -> Void)?
    var failure: (() -> Void)?
    var space: (([Int64]) -> Void)?
    private var completed: [Int64] = []
    private var failureDetail: String?
    private var callbackCadence = DisplayCadenceStats()
    private var decodeTiming = DisplayTimingStats(), callbackToMain = DisplayTimingStats()
    private var mailboxReplacements: UInt64 = 0, droppedCallbacks: UInt64 = 0
    private var lastLoggedAt = ProcessInfo.processInfo.systemUptime
    init(format: DisplayVideoFormat, deliver: @escaping (CVPixelBuffer) -> Void, failure: @escaping () -> Void, space: @escaping ([Int64]) -> Void) { self.format = format; self.deliver = deliver; self.failure = failure; self.space = space }
    func reserve(sequence: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard valid, !failed, inFlight < 4, submittedAt.count < 4 else { return false }; inFlight += 1; submittedAt[sequence] = ProcessInfo.processInfo.systemUptime; return true
    }
    func complete(status: OSStatus, flags: VTDecodeInfoFlags, pixel: CVPixelBuffer?, sequence: Int64) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard valid, let started = submittedAt.removeValue(forKey: sequence) else { lock.unlock(); return }
        inFlight -= 1; completed.append(sequence)
        decodeTiming.record((now-started)*1000)
        if flags.contains(.frameDropped) { droppedCallbacks &+= 1 }
        if status == noErr, let pixel, CVPixelBufferGetWidth(pixel) == format.pixelWidth,
           CVPixelBufferGetHeight(pixel) == format.pixelHeight, CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_32BGRA {
            callbackCadence.observe(now)
            if latest != nil { mailboxReplacements &+= 1 }
            latest = pixel; latestCallbackAt = now
        } else if status != noErr || pixel != nil || !flags.contains(.frameDropped) {
            if !failed {
                failureDetail = "error=decoderFailed stage=callback status=\(status) flags=\(flags.rawValue) dimensions=\(pixel.map { "\(CVPixelBufferGetWidth($0))x\(CVPixelBufferGetHeight($0))" } ?? "none") expected=\(format.pixelWidth)x\(format.pixelHeight) inFlight=\(inFlight) limit=4"
            }
            failed = true; latest = nil; latestCallbackAt = nil
        }
        let enqueue = !scheduled; scheduled = true; lock.unlock()
        if enqueue { DispatchQueue.main.async { [self] in drain() } }
    }
    private func summaryLocked() -> String {
        "Display cadence decoder: callbacks[\(callbackCadence.summary)] submitToCallback[\(decodeTiming.summary)] callbackToMain[\(callbackToMain.summary)] mailboxReplaced=\(mailboxReplacements) vtDropFlag=\(droppedCallbacks); contentMayBeIdle=true panelUnmeasured=true"
    }
    private func drain() {
        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        let image = valid && !failed ? latest : nil
        let output = valid ? deliver : nil
        let error = valid && failed ? failure : nil
        let ready = valid && !failed ? space : nil
        let finished = completed; completed.removeAll(keepingCapacity: true)
        let detail = failureDetail; failureDetail = nil
        if image != nil, let readyAt = latestCallbackAt { callbackToMain.record((now-readyAt)*1000) }
        let summary: String?
        if valid, callbackCadence.count > 0, now-lastLoggedAt >= 2 { summary = summaryLocked(); lastLoggedAt = now } else { summary = nil }
        latest = nil; latestCallbackAt = nil; scheduled = false
        lock.unlock()
        if let summary { displayStageLog(summary) }
        if let detail { displayStageLog("Display decoder failure "+detail) }
        if let error { error() } else {
            if let image { output?(image) }
            ready?(finished)
        }
    }
    func invalidate() {
        lock.lock()
        let summary = valid && callbackCadence.count > 0 ? summaryLocked() : nil
        valid = false; submittedAt.removeAll(); latest = nil; latestCallbackAt = nil; deliver = nil; failure = nil; space = nil; completed.removeAll(); failureDetail = nil
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
    let format: DisplayVideoFormat
    private var description: CMVideoFormatDescription?
    private var parameters: (Data, Data)?
    private var mailbox: DisplayDecodeMailbox?
    private var sequence: Int64 = 0
    private var admission = DisplayDecodeAdmission<DisplayH264Packet>()
    private(set) var completedSubmissions = 0
    var pendingFrameCount: Int { admission.pending.count }
    var inFlightFrameCount: Int { admission.active.count }
    private let output: (CVPixelBuffer) -> Void
    private let failure: () -> Void
    init(format: DisplayVideoFormat = .standard, output: @escaping (CVPixelBuffer) -> Void, failure: @escaping () -> Void) { self.format = format; self.output = output; self.failure = failure }
    deinit {
        mailbox?.invalidate()
        // Teardown retains the callback box through the existing VT drain boundary.
        if let session { VTDecompressionSessionInvalidate(session); VTDecompressionSessionWaitForAsynchronousFrames(session) }
        withExtendedLifetime(mailbox) {}
    }
    func clear() {
        admission.clear(); completedSubmissions = 0
        retireSession()
        sequence = 0
    }
    private func retireSession() {
        let oldBox = mailbox
        oldBox?.invalidate()
        if let session { VTDecompressionSessionInvalidate(session); VTDecompressionSessionWaitForAsynchronousFrames(session) }
        withExtendedLifetime(oldBox) {}
        session = nil; description = nil; parameters = nil; mailbox = nil
    }
    private func logFailure(_ error: Error, stage: String, status: OSStatus? = nil, flags: VTDecodeInfoFlags = []) {
        displayStageLog("Display decoder failure error=\(String(describing: error)) stage=\(stage) status=\(status.map(String.init) ?? "none") flags=\(flags.rawValue) expected=\(format.pixelWidth)x\(format.pixelHeight) inFlight=\(admission.active.count)/4 pending=\(admission.pending.count)/8 pendingBytes=\(admission.pendingBytes)/8388608")
    }
    func accept(_ payload: Data) throws {
        do {
            let packet = try DisplayH264Packet(payload, format: format)
            try admission.enqueue(packet, bytes: packet.sps.count + packet.pps.count + packet.avcc.count)
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
            let changed = parameters?.0 != next.sps || parameters?.1 != next.pps
            // Finish every old reference before switching descriptions, without a wait.
            if changed && !admission.active.isEmpty { return }
            guard sequence >= 0, sequence < Int64.max else { throw DisplayVideoError.backlog }
            guard let packet = admission.submit(sequence: sequence) else { return }
            try submit(packet)
            sequence += 1
        }
    }
    private func submit(_ packet: DisplayH264Packet) throws {
        if parameters?.0 != packet.sps || parameters?.1 != packet.pps {
            guard packet.isKeyFrame else { throw DisplayVideoError.malformed }
            let configurationStarted = ProcessInfo.processInfo.systemUptime
            retireSession()
            let description = try packet.formatDescription()
            let epoch = admission.epoch
            let box = DisplayDecodeMailbox(format: format, deliver: { [weak self] pixel in
                guard let self, self.admission.epoch == epoch else { return }; self.output(pixel)
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
            session = created; self.description = description; parameters = (packet.sps, packet.pps); mailbox = box
            _ = VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            displayStageLog("Display decoder configuration setupMs=\((ProcessInfo.processInfo.systemUptime-configurationStarted)*1000); reconfigurationNotSteadyState=true")
        }
        guard let session, let description, let mailbox else { throw DisplayVideoError.decoderFailed }
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
        guard sequence >= 0, sequence < Int64.max, mailbox.reserve(sequence: sequence) else { throw DisplayVideoError.backlog }
        var infoFlags: VTDecodeInfoFlags = []
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [._EnableAsynchronousDecompression], frameRefcon: UnsafeMutableRawPointer(bitPattern: UInt(sequence) + 1), infoFlagsOut: &infoFlags)
        guard status == noErr else { logFailure(DisplayVideoError.decoderFailed, stage: "submit", status: status, flags: infoFlags); throw DisplayVideoError.decoderFailed }
    }
}

/// Creates a reference-backed image sample: no CPU pixel readback, bitmap conversion,
/// compressed-frame discard or frame clock/preroll wait is introduced here.
func displayImmediateImageSample(_ pixel: CVPixelBuffer, format expectedFormat: DisplayVideoFormat? = nil) throws -> CMSampleBuffer {
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
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel,
        formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
        let sample, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
        CFArrayGetCount(attachments) == 1 else { throw DisplayVideoError.decoderFailed }
    let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
    CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    return sample
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
    mutating func begin(fullScreen: Bool) { phase = fullScreen ? .waitingForWindow : .windowed }
    mutating func requestIfReady(windowReady: Bool) -> Bool {
        guard phase == .waitingForWindow, windowReady else { return false }
        phase = .enteringFullScreen; return true
    }
    mutating func didEnterFullScreen() {
        guard phase != .closed, phase != .idle else { return }
        phase = .fullScreen
    }
    @discardableResult mutating func useWindowedFallback() -> Bool {
        guard isPending else { return false }
        phase = .windowed; return true
    }
    mutating func close() { phase = .closed }
}

@MainActor final class DisplayViewer: NSObject, NSWindowDelegate {
    let format: DisplayVideoFormat
    private let targetScreen: NSScreen?
    init(format: DisplayVideoFormat = .standard, targetScreen: NSScreen? = nil) {
        self.format = format; self.targetScreen = targetScreen; super.init()
    }
    var startsFullScreen = true
    private var windowEpoch: UInt64 = 0
    private var startup = DisplayViewerStartup()
    private var startupTimer: Timer?
    private var startupDeadline: TimeInterval = 0
    private var entryDeadline: TimeInterval?
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
    private var latestDecoded = DisplayLatestDecodedFrame()
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
        guard !closing, latestDecoded.pixel == nil, #available(macOS 14.0, *), let renderer = surface?.videoLayer?.sampleBufferRenderer, renderer.isReadyForMoreMediaData else { return false }
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
        finishFullScreenFallback(window,reason:"appkit-rejected")
    }
    func accept(_ payload: Data) throws {
        guard viewerWindow != nil, !closing else { throw DisplayVideoError.decoderFailed }
        if decoder == nil {
            decoder = DisplayH264Decoder(format: self.format, output: { [weak self] pixel in self?.present(pixel) }, failure: { [weak self] in self?.close() })
        }
        var video = payload
        if payload.first == 6 {
            let frame = try DisplayStreamFrame(payload)
            guard lastStreamSequence.map({frame.sequence > $0}) ?? true else { throw DisplayVideoError.malformed }
            if let previous = lastStreamSequence, frame.sequence-previous > 1 { sourceSequenceSkips &+= frame.sequence-previous-1 }
            lastStreamSequence = frame.sequence; video = frame.video
            sourceAdmissionTiming.record(Double(frame.encodeStart-frame.capture)/1000)
            sourceEncodeTiming.record(Double(frame.encodeEnd-frame.encodeStart)/1000)
            if frame.sequence % 120 == 0 {
                displayStageLog("Display source stages us: captureArrivalToEncode=\(frame.encodeStart-frame.capture) encode=\(frame.encodeEnd-frame.encodeStart); remoteClockOffset=unknown panelLatency=unmeasured")
            }
        }
        mainVideoCadence.observe(ProcessInfo.processInfo.systemUptime)
        logCadence()
        do { try decoder!.accept(video) } catch { clear(); throw error }
    }
    private func present(_ pixel: CVPixelBuffer) {
        guard !closing, surface != nil, viewerWindow != nil else { return }
        lastDecodedAt = ProcessInfo.processInfo.systemUptime
        decodedMainCadence.observe(lastDecodedAt)
        receivedFrameCount += 1; presentationStats.decoded &+= 1
        if latestDecoded.replace(pixel) { presentationStats.replacedDecoded &+= 1 }
        drainPresentation()
    }
    private func drainPresentation() {
        guard !closing, startup.mayPresentVideo, let layer = surface?.videoLayer, latestDecoded.pixel != nil else { return }
        guard #available(macOS 14.0, *) else { close(); return }
        let renderer = layer.sampleBufferRenderer
        guard renderer.status != .failed else { close(); return }
        guard renderer.isReadyForMoreMediaData else {
            presentationStats.readinessDeferrals &+= 1
            requestRendererReadiness(renderer)
            return
        }
        stopReadiness(ready: true)
        guard let pixel = latestDecoded.take() else { return }
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let sample = try displayImmediateImageSample(pixel, format: self.format)
            renderer.enqueue(sample)
            rendererCadence.observe(ProcessInfo.processInfo.systemUptime)
            presentationStats.submitted &+= 1
            updateCursorOverlay()
            if presentationStats.submitted % 120 == 0 {
                displayStageLog("Display receiver stages ms: decodedMainToRendererSubmit=\((ProcessInfo.processInfo.systemUptime-lastDecodedAt)*1000); enqueueNotPanel=true crossHostLatency=unknown")
            }
            let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1000
            presentationStats.totalEnqueueMilliseconds += elapsed
            presentationStats.maximumEnqueueMilliseconds = max(presentationStats.maximumEnqueueMilliseconds, elapsed)
            logCadence()
        } catch { close() }
    }
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
    private func logCadence(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard mainVideoCadence.count > 0, force || now-cadenceLoggedAt >= 2 else { return }
        cadenceLoggedAt = now
        displayStageLog("Display cadence viewer: encodedMain[\(mainVideoCadence.summary)] decodedMain[\(decodedMainCadence.summary)] rendererEnqueue[\(rendererCadence.summary)] sourceAdmission[\(sourceAdmissionTiming.summary)] sourceEncode[\(sourceEncodeTiming.summary)] sourceEncodeSequenceSkips=\(sourceSequenceSkips) latestDecodedReplaced=\(presentationStats.replacedDecoded) readinessDeferrals=\(presentationStats.readinessDeferrals) registrations=\(readinessRegistrations) callbacks=\(readinessCallbacks) cancelled=\(readinessCancelled) readinessWait[\(readinessWait.summary)]; contentMayBeIdle=true enqueueNotPanel=true final=\(force)")
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
        let cursor: NSCursor
        switch m.shape { case 1: cursor = .iBeam; case 2: cursor = .crosshair; case 3: cursor = .pointingHand; case 4: cursor = .closedHand; default: cursor = .arrow }
        if cursorGlyphs[m.shape] == nil {
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
        stopReadiness(); latestDecoded.clear()
        logCadence(force: true)
        cursorExpiry?.cancel(); cursorExpiry = nil; cursorMetadata = nil; cursorOverlay.removeFromSuperlayer(); cursorGlyphs.removeAll()
        lastCursorSequence = nil; lastStreamSequence = nil; lastDecodedAt = 0
        mainVideoCadence = DisplayCadenceStats(); decodedMainCadence = DisplayCadenceStats(); rendererCadence = DisplayCadenceStats()
        readinessWait = DisplayTimingStats(); sourceAdmissionTiming = DisplayTimingStats(); sourceEncodeTiming = DisplayTimingStats(); readinessRegistrations = 0; readinessCallbacks = 0; readinessCancelled = 0; sourceSequenceSkips = 0
        cadenceLoggedAt = ProcessInfo.processInfo.systemUptime
        decoder?.clear(); decoder = nil; receivedFrameCount = 0
        presentationStats = DisplayPresentationStats()
        if #available(macOS 14.0, *), let layer = surface?.videoLayer {
            layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        }
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
