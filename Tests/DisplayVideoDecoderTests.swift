import Foundation
import CoreMedia
import CoreVideo

/// Pure bounded-wire/SPS parser tests. No windows, decoder instances, capture, network or input.
func runDisplayVideoDecoderTests() -> Int {
    var failures = 0, cases = 0
    func check(_ result: Bool) { cases += 1; if !result { failures += 1 } }
    func rejected(_ data: Data, format: DisplayVideoFormat = .standard) -> Bool { do { _ = try DisplayH264Packet(data, format: format); return false } catch { return true } }
    // Minimal baseline progressive SPS. Synthetic headers exercise resource preflight;
    // full real VT decode is tested separately with the helper's hardware-encoded frames.
    func sps(width: UInt32 = 119, height: UInt32 = 67, cropBottom: UInt32 = 4, refs: UInt32 = 1, progressive: Bool = true, cropRight: UInt32 = 0, profile: UInt32 = 66, chroma: UInt32 = 1, bitDepth: UInt32 = 0, level: UInt32 = 40) -> Data {
        var bits = [UInt8]()
        func raw(_ n: UInt32, _ count: Int) { for index in (0..<count).reversed() { bits.append(UInt8((n >> index) & 1)) } }
        func ue(_ value: UInt32) { let n = value + 1; let count = 32 - n.leadingZeroBitCount; for _ in 1..<count { bits.append(0) }; raw(n, count) }
        raw(profile, 8); raw(0, 8); raw(level, 8); ue(0)
        if profile == 100 { ue(chroma); ue(bitDepth); ue(bitDepth); raw(0, 1); raw(0, 1) }
        ue(0); ue(0); ue(0); ue(refs); raw(0, 1)
        ue(width); ue(height); raw(progressive ? 1 : 0, 1); raw(1, 1); raw(1, 1)
        ue(0); ue(cropRight); ue(0); ue(cropBottom); raw(0, 1); raw(1, 1)
        while bits.count % 8 != 0 { bits.append(0) }
        var data = Data([0x67]); for offset in stride(from: 0, to: bits.count, by: 8) { data.append(bits[offset..<(offset + 8)].reduce(0) { ($0 << 1) | $1 }) }
        return data
    }
    func packet(_ sequence: Data? = nil, pps: Data = Data([0x68, 0xe0]), nal: Data = Data([0x65, 0x88])) -> Data {
        let sequence = sequence ?? sps(); var data = Data([2])
        data.append(UInt8(sequence.count >> 8)); data.append(UInt8(sequence.count & 255)); data.append(sequence)
        data.append(UInt8(pps.count >> 8)); data.append(UInt8(pps.count & 255)); data.append(pps)
        var length = UInt32(nal.count).bigEndian; withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }; data.append(nal); return data
    }
    // Deterministic saturation, FIFO, byte accounting and stale completion policy proof.
    var admission = DisplayDecodeAdmission<Int>()
    let epoch = admission.epoch
    do {
        for n in 0..<4 { try admission.enqueue(n, bytes: 10); check(admission.submit(sequence: Int64(n)) == n) }
        for n in 4..<12 { try admission.enqueue(n, bytes: 10) }
        check(admission.active.count == 4 && admission.pending.count == 8 && admission.pendingBytes == 80)
        check(admission.submit(sequence: 12) == nil)
        do { try admission.enqueue(12, bytes: 1); check(false) } catch { check(true) }
        check(admission.pending.count == 8 && admission.pendingBytes == 80)
        check(admission.complete(sequence: 1, epoch: epoch))
        check(!admission.complete(sequence: 1, epoch: epoch))
        check(admission.submit(sequence: 4) == 4)
        check(admission.active.count == 4 && admission.pending.first?.packet == 5)
        for n in [0, 2, 3, 4] { check(admission.complete(sequence: Int64(n), epoch: epoch)) }
        for n in 5..<12 {
            check(admission.submit(sequence: Int64(n)) == n)
            check(admission.complete(sequence: Int64(n), epoch: epoch))
        }
        check(admission.pendingBytes == 0 && admission.pending.isEmpty && admission.active.isEmpty)
        try admission.enqueue(1, bytes: 8 * 1024 * 1024)
        do { try admission.enqueue(2, bytes: 1); check(false) } catch { check(true) }
        check(admission.pending.count == 1 && admission.pendingBytes == 8 * 1024 * 1024)
        admission.clear()
        check(admission.pendingBytes == 0 && admission.pending.isEmpty && admission.active.isEmpty)
        try admission.enqueue(99, bytes: 1); check(admission.submit(sequence: 0) == 99)
        check(!admission.complete(sequence: 0, epoch: epoch))
        check(admission.active.count == 1)
        admission.clear()
        for bad in [0, -1, Int.max] {
            do { try admission.enqueue(0, bytes: bad); check(false) } catch { check(true) }
        }
        check(admission.pending.isEmpty && admission.pendingBytes == 0)
    } catch { check(false) }
    let valid = packet()
    check(!rejected(valid))
    do { let parsed = try DisplayH264Packet(valid); check(parsed.isKeyFrame); check(parsed.avcc.count == 6) } catch { check(false) }
    for length in 0..<valid.count { check(rejected(Data(valid.prefix(length)))) }
    var wrongType = valid; wrongType[0] = 1; check(rejected(wrongType))
    var length = valid; length[1] = 0xff; length[2] = 0xff; check(rejected(length))
    check(rejected(Data(repeating: 0, count: DisplayH264Packet.maximumSize + 1)))
    check(rejected(packet(sps(width: 79, height: 44, cropBottom: 0))))
    check(rejected(packet(sps(width: 10000))))
    check(rejected(packet(sps(cropBottom: 0))))
    check(rejected(packet(sps(cropBottom: 10000))))
    check(rejected(packet(sps(refs: 5))))
    check(rejected(packet(sps(progressive: false))))
    check(rejected(packet(pps: Data([0x68, 0xa0])))) // PPS refers to SPS1, not SPS0.
    for kind: UInt8 in [0, 2, 3, 4, 7, 8, 10, 11, 13, 24, 31, 0x85] { check(rejected(packet(nal: Data([kind, 0x88])))) }
    check(rejected(packet(nal: Data([0x06, 0x80])))) // no VCL slice
    var trailing = valid; trailing.append(0); check(rejected(trailing))
    var zeroNAL = valid; zeroNAL.replaceSubrange((valid.count - 6)..<(valid.count - 2), with: [0, 0, 0, 0]); check(rejected(zeroNAL))
    var largeNAL = valid; largeNAL.replaceSubrange((valid.count - 6)..<(valid.count - 2), with: [0xff, 0xff, 0xff, 0xff]); check(rejected(largeNAL))
    var many = Data(valid.dropLast(6)); for _ in 0..<257 { many.append(contentsOf: [0, 0, 0, 2, 0x65, 0x88]) }; check(rejected(many))
    var sliced = Data([0, 0, 0]); sliced.append(valid)
    check(!rejected(sliced.dropFirst(3))) // Data need not have a zero startIndex.
    // Negotiated format is immutable: valid SPS from another session is still refused.
    let formats = [DisplayVideoFormat(width: 1440, height: 900),
                   DisplayVideoFormat(width: 1728, height: 1116),
                   DisplayVideoFormat(width: 1536, height: 1024),
                   DisplayVideoFormat(width: 1440, height: 1440),
                   DisplayVideoFormat(width: 640, height: 480),
                   DisplayVideoFormat(width: 1512, height: 945, pixelScale: 2),
                   DisplayVideoFormat(width: 1808, height: 1130, pixelScale: 2),
                   DisplayVideoFormat(width: 1920, height: 1080, pixelScale: 2)]
    for format in formats {
        check(format.valid)
        let mw = (format.pixelWidth + 15) / 16, mh = (format.pixelHeight + 15) / 16
        let sequence = sps(width: UInt32(mw - 1), height: UInt32(mh - 1),
                           cropBottom: UInt32((mh * 16 - format.pixelHeight) / 2),
                           cropRight: UInt32((mw * 16 - format.pixelWidth) / 2), profile: 100, level: format.h264LevelLimit)
        let frame = packet(sequence)
        check(!rejected(frame, format: format)); check(rejected(frame))
        do {
            let description = try DisplayH264Packet(frame, format: format).formatDescription()
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            check(dimensions.width == format.pixelWidth && dimensions.height == format.pixelHeight)
        } catch { check(false) }
        check(rejected(valid, format: format))
        // Exact visible size is insufficient if coded allocation adds extra macroblocks.
        let padded = sps(width: UInt32(mw), height: UInt32(mh - 1),
                         cropBottom: UInt32((mh * 16 - format.pixelHeight) / 2),
                         cropRight: UInt32((mw * 16 + 16 - format.pixelWidth) / 2))
        check(rejected(packet(padded), format: format))
        for length in 0..<frame.count { check(rejected(Data(frame.prefix(length)), format: format)) }
        let bounds = CGRect(x: 30, y: 50, width: 1000, height: 1000)
        let scale = min(bounds.width / CGFloat(format.width), bounds.height / CGFloat(format.height))
        let width = CGFloat(format.width) * scale, height = CGFloat(format.height) * scale
        let topLeft = CGPoint(x: bounds.midX - width / 2, y: bounds.midY + height / 2)
        check(displayVideoNormalizedPoint(topLeft, bounds: bounds, clamp: false, format: format) == .zero)
        let center = displayVideoNormalizedPoint(CGPoint(x: bounds.midX, y: bounds.midY), bounds: bounds, clamp: false, format: format)
        check(center != nil && abs(center!.x - 0.5) < 0.000001 && abs(center!.y - 0.5) < 0.000001)
        let wide = CGRect(x: 0, y: 0, width: 2000, height: 500)
        check(displayVideoNormalizedPoint(CGPoint(x: 0, y: 250), bounds: wide, clamp: false, format: format) == nil)
        check(displayVideoNormalizedPoint(CGPoint(x: 0, y: 250), bounds: wide, clamp: true, format: format)?.x == 0)
        if height < bounds.height {
            check(displayVideoNormalizedPoint(CGPoint(x: bounds.midX, y: bounds.minY), bounds: bounds, clamp: false, format: format) == nil)
        }
        check(displayVideoNormalizedPoint(CGPoint(x: bounds.minX - 100, y: bounds.maxY + 100), bounds: bounds, clamp: true, format: format) == .zero)
        // Negative-origin secondary display: no fallback to primary/zero coordinates.
        let screen = CGRect(x: -1800, y: 200, width: 1440, height: 860)
        let initial = displayVideoInitialContentRect(format: format, visibleFrame: screen)
        check(screen.contains(initial))
        check(abs(initial.width / initial.height - CGFloat(format.width) / CGFloat(format.height)) < 0.000001)
        check(initial.height + 40 < screen.height)
        var pixel: CVPixelBuffer?
        check(CVPixelBufferCreate(nil, format.pixelWidth, format.pixelHeight, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
        if let pixel {
            do { check(CMSampleBufferGetImageBuffer(try displayImmediateImageSample(pixel, format: format)) === pixel) } catch { check(false) }
        }
    }
    // Same logical rectangle across 1x and 2x must retain identical window/input geometry.
    let logical = DisplayVideoFormat(width: 1808, height: 1130)
    let retina = DisplayVideoFormat(width: 1808, height: 1130, pixelScale: 2)
    check(retina.pixelSize == CGSize(width: 3616, height: 2260))
    check(retina.size == logical.size && retina.pixelWidth == logical.width * 2)
    let geometryBounds = CGRect(x: -400, y: 50, width: 1234, height: 987)
    check(displayVideoInitialContentRect(format: logical, visibleFrame: geometryBounds) ==
          displayVideoInitialContentRect(format: retina, visibleFrame: geometryBounds))
    for point in [CGPoint(x: 100, y: 500), CGPoint(x: -500, y: 2000)] {
        check(displayVideoNormalizedPoint(point, bounds: geometryBounds, clamp: true, format: logical) ==
              displayVideoNormalizedPoint(point, bounds: geometryBounds, clamp: true, format: retina))
    }
    // High 5.2 is valid only against the negotiated 2x allocation and level budget.
    let hd = DisplayVideoFormat(width: 1512, height: 945, pixelScale: 2)
    check(hd.pixelSize == CGSize(width: 3024, height: 1890))
    let hiSequence = sps(width: 188, height: 118, cropBottom: 7, profile: 100, level: 52)
    let hiFrame = packet(hiSequence)
    check(!rejected(hiFrame, format: hd))
    check(rejected(hiFrame, format: DisplayVideoFormat(width: 1512, height: 945)))
    check(rejected(hiFrame, format: retina))
    for sequence in [sps(width: 188, height: 118, cropBottom: 7, profile: 100, level: 53),
                     sps(width: 188, height: 118, cropBottom: 7, profile: 100, chroma: 2, level: 52),
                     sps(width: 188, height: 118, cropBottom: 7, profile: 100, bitDepth: 1, level: 52),
                     sps(width: 188, height: 118, cropBottom: 7, refs: 5, profile: 100, level: 52),
                     sps(width: 239, height: 179, cropBottom: 0, profile: 100, level: 52)] {
        check(rejected(packet(sequence), format: hd))
    }
    check(rejected(packet(hiSequence, pps: Data([0x68, 0xa0])), format: hd))
    // Unnegotiated legacy image samples are bounded physical images, not 1x formats.
    func imageAccepted(_ width: Int, _ height: Int, expected: DisplayVideoFormat? = nil) -> Bool {
        var pixel: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess,
              let pixel else { check(false); return false }
        do {
            let sample = try displayImmediateImageSample(pixel, format: expected)
            let dimensions = CMVideoFormatDescriptionGetDimensions(CMSampleBufferGetFormatDescription(sample)!)
            check(dimensions.width == width && dimensions.height == height)
            return CMSampleBufferGetImageBuffer(sample) === pixel
        } catch { return false }
    }
    check(imageAccepted(3024, 1890))
    check(imageAccepted(3024, 1890, expected: hd))
    check(imageAccepted(3616, 2260, expected: retina))
    check(!imageAccepted(3024, 1890, expected: retina))
    check(!imageAccepted(1512, 945, expected: hd))
    check(!imageAccepted(3840, 2162)) // over encoded pixel budget
    check(!imageAccepted(3842, 1080)) // over physical width bound
    check(!imageAccepted(1920, 2882)) // over physical height bound
    check(!imageAccepted(1921, 1080)) // odd physical width
    check(!imageAccepted(1920, 1081)) // odd physical height
    for invalid in [DisplayVideoFormat(width: 1920, height: 1082),
                    DisplayVideoFormat(width: 1800, height: 1200),
                    DisplayVideoFormat(width: 1920, height: 480),
                    DisplayVideoFormat(width: 640, height: 1440),
                    DisplayVideoFormat(width: 1441, height: 900),
                    DisplayVideoFormat(width: 0, height: 0),
                    DisplayVideoFormat(width: Int.max, height: Int.max),
                    DisplayVideoFormat(width: 1920, height: 1082, pixelScale: 2),
                    DisplayVideoFormat(width: 1920, height: 1440, pixelScale: 2),
                    DisplayVideoFormat(width: 1440, height: 900, pixelScale: 3)] {
        check(!invalid.valid); check(rejected(valid, format: invalid))
        check(displayVideoNormalizedPoint(.zero, bounds: CGRect(x: 0, y: 0, width: 100, height: 100), clamp: true, format: invalid) == nil)
        check(displayVideoInitialContentRect(format: invalid, visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000)) == .zero)
    }
    for sequence in [sps(profile: 100, chroma: 2), sps(profile: 100, bitDepth: 2),
                     sps(profile: 110), sps(level: 43)] { check(rejected(packet(sequence))) }
    check(!rejected(packet(sps(profile: 100))))
    check(!rejected(packet(sps(refs: 4))))
    check(rejected(packet(Data([0x67, 0, 0, 3, 4])))) // Invalid escape byte.
    let full = CGRect(x: 0, y: 0, width: 960, height: 540)
    check(displayVideoNormalizedPoint(CGPoint(x: 0, y: 540), bounds: full, clamp: false) == CGPoint(x: 0, y: 0))
    check(displayVideoNormalizedPoint(CGPoint(x: 960, y: 0), bounds: full, clamp: false) == CGPoint(x: 1, y: 1))
    check(displayVideoNormalizedPoint(CGPoint(x: 480, y: 270), bounds: full, clamp: false) == CGPoint(x: 0.5, y: 0.5))
    check(displayVideoNormalizedPoint(CGPoint(x: 10, y: 550), bounds: full, clamp: false) == nil)
    check(displayVideoNormalizedPoint(CGPoint(x: -20, y: 600), bounds: full, clamp: true) == CGPoint(x: 0, y: 0))
    let letterbox = CGRect(x: 0, y: 0, width: 960, height: 700)
    check(displayVideoNormalizedPoint(CGPoint(x: 100, y: 30), bounds: letterbox, clamp: false) == nil)
    check(displayVideoNormalizedPoint(CGPoint(x: 480, y: 350), bounds: letterbox, clamp: false) == CGPoint(x: 0.5, y: 0.5))
    check(displayVideoNormalizedPoint(CGPoint(x: 0, y: 620), bounds: letterbox, clamp: false) == CGPoint(x: 0, y: 0))
    check(displayVideoNormalizedPoint(.zero, bounds: .zero, clamp: true) == nil)
    check(displayVideoNormalizedPoint(CGPoint(x: CGFloat.nan, y: 0), bounds: full, clamp: true) == nil)
    // Metadata-only presentation tests: no window, pixel readback or rendering.
    var pixel: CVPixelBuffer?, wrongSize: CVPixelBuffer?, wrongFormat: CVPixelBuffer?
    check(CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel) == kCVReturnSuccess)
    check(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &wrongSize) == kCVReturnSuccess)
    check(CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &wrongFormat) == kCVReturnSuccess)
    if let pixel, let wrongSize, let wrongFormat {
        do {
            let sample = try displayImmediateImageSample(pixel)
            check(CMSampleBufferGetImageBuffer(sample) === pixel) // Same buffer retained, not copied/read back.
            check(CMSampleBufferDataIsReady(sample))
            check(CMSampleBufferGetNumSamples(sample) == 1)
            check(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), .zero) == 0)
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]]
            check(attachments?.first?[kCMSampleAttachmentKey_DisplayImmediately as String] as? Bool == true)
        } catch { check(false) }
        do { _ = try displayImmediateImageSample(wrongSize, format: .standard); check(false) } catch { check(true) }
        do { _ = try displayImmediateImageSample(wrongFormat); check(false) } catch { check(true) }
        var latest = DisplayLatestDecodedFrame()
        check(latest.pixel == nil)
        check(!latest.replace(pixel))
        check(latest.replace(wrongSize))
        check(latest.pixel === wrongSize)
        check(latest.take() === wrongSize)
        check(latest.pixel == nil)
        check(latest.take() == nil)
        check(!latest.replace(pixel)); latest.clear(); check(latest.pixel == nil)
        let stats = DisplayPresentationStats()
        check(stats.decoded == 0 && stats.submitted == 0 && stats.replacedDecoded == 0 && stats.readinessDeferrals == 0)
    }
    // Main delivery queued before clear, late callbacks and submit-return errors
    // cannot resurrect an old image or open a failed submission gate.
    if let pixel {
        var drains: [() -> Void] = [], delivered = 0, errors = 0, spaces = 0
        let box = DisplayDecodeMailbox(format: .standard, trace: DisplayFrameTrace(stream: nil), generation: 91,
            scheduleDrain: { drains.append($0) }, deliver: { _, _ in delivered += 1 },
            failure: { errors += 1 }, space: { _ in spaces += 1 })
        let identity = DisplayFrameIdentity(sourceSequence: 42, cookie: 0, generation: 91)
        check(box.reserve(sequence: 0, identity: identity))
        box.complete(status: 0, flags: [], pixel: pixel, sequence: 0)
        check(drains.count == 1)
        box.invalidate()
        for drain in drains { drain() }; drains.removeAll()
        box.complete(status: 0, flags: [], pixel: pixel, sequence: 0)
        check(delivered == 0 && errors == 0 && spaces == 0 && drains.isEmpty)
        check(!box.maySubmit)
        let failed = DisplayDecodeMailbox(format: .standard, trace: DisplayFrameTrace(stream: nil), generation: 92,
            scheduleDrain: { drains.append($0) }, deliver: { _, _ in delivered += 1 },
            failure: { errors += 1 }, space: { _ in spaces += 1 })
        check(failed.reserve(sequence: 0, identity: identity))
        failed.complete(status: 0, flags: [], pixel: pixel, sequence: 0)
        failed.submissionFailed()
        check(!failed.maySubmit)
        for drain in drains { drain() }; drains.removeAll()
        check(delivered == 0 && errors == 1 && spaces == 0)
        failed.complete(status: 0, flags: [], pixel: pixel, sequence: 0)
        check(drains.isEmpty)
        failed.invalidate()
    }
    // Regression: a callback that arrives before DecodeFrame returns is not a
    // completion yet. Drain the main delivery lane while a fake submit is blocked.
    if let pixel {
        final class Drains {
            let lock = NSLock(); var work: [() -> Void] = []
            let ready = DispatchSemaphore(value: 0)
            func enqueue(_ f: @escaping () -> Void) { lock.lock(); work.append(f); lock.unlock(); ready.signal() }
            func drain() { lock.lock(); let batch = work; work.removeAll(); lock.unlock(); for f in batch { f() } }
        }
        for returnsSuccess in [false, true] {
            let drains = Drains(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let nextEntered = DispatchSemaphore(value: 0), nextRelease = DispatchSemaphore(value: 0)
            let cleaned = DispatchSemaphore(value: 0)
            var delivered = 0, completed = 0, refillAccepted = false
            guard let lease = DisplayDecodeWorkerLease.acquire() else { check(false); continue }
            let worker = DisplayDecodeWorker(lease: lease, cleanup: { cleaned.signal() })
            let box = DisplayDecodeMailbox(format: .standard, trace: DisplayFrameTrace(stream: nil), generation: 93,
                scheduleDrain: { drains.enqueue($0) }, deliver: { _, _ in delivered += 1 }, failure: {},
                space: { cookies in
                    completed += cookies.count
                    // Three old jobs remain reserved while main refills the slot
                    // released by the completed first call. This must NOT backlog.
                    refillAccepted = worker.submit { _ in true }
                })
            let identity = DisplayFrameIdentity(sourceSequence: 43, cookie: 0, generation: 93)
            check(box.reserve(sequence: 0, identity: identity, awaitingReturn: true))
            check(worker.submit({ _ in
                box.complete(status: 0, flags: [], pixel: pixel, sequence: 0)
                entered.signal(); _ = release.wait(timeout: .now() + 3)
                if !returnsSuccess { box.submissionFailed() }
                return returnsSuccess
            }, didReturn: { box.submissionSucceeded(sequence: 0) }))
            check(entered.wait(timeout: .now() + 3) == .success)
            for n in 1...3 {
                check(worker.submit { _ in
                    if n == 1 { nextEntered.signal(); _ = nextRelease.wait(timeout: .now() + 3) }
                    return true
                })
            }
            drains.drain()
            check(delivered == 0 && completed == 0)
            check(!worker.submit { _ in true })
            release.signal()
            if returnsSuccess {
                check(drains.ready.wait(timeout: .now() + 3) == .success)
                check(nextEntered.wait(timeout: .now() + 3) == .success)
                drains.drain()
                check(delivered == 1 && completed == 1 && refillAccepted)
                nextRelease.signal()
            } else {
                let until = Date().addingTimeInterval(3)
                while !worker.hasFailed && Date() < until { Thread.sleep(forTimeInterval: 0.001) }
                check(worker.hasFailed)
                drains.drain()
                check(delivered == 0 && completed == 0 && !refillAccepted)
            }
            box.invalidate(); worker.retire()
            check(cleaned.wait(timeout: .now() + 3) == .success)
            let until = Date().addingTimeInterval(3)
            while !worker.isDrained && Date() < until { Thread.sleep(forTimeInterval: 0.001) }
            check(worker.isDrained)
        }
    }
    print("\(failures == 0 ? "PASS" : "FAIL") display video parser \(cases) cases: bounded negotiated SPS/PPS/AVCC and varied-aspect geometry, malformed lengths, reference limits, direct-buffer sample and latest decoded bounds; no UI/network/capture")
    return failures
}
