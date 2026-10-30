import Foundation
import CryptoKit
import CoreVideo
import Darwin

private enum DisplayPipelineTestError: Error { case failed }

/// Offline generated-pattern integration only. No window, socket, event construction,
/// event capture/posting, Keychain, or user desktop. A zero helper identity is REQUIRED
/// and replaced with fixture ID1 before passing the real production wire validators.
#if !DISPLAY_PIPELINE_PIXEL_TEST_MAIN
@MainActor func runDisplayPipelineTests(path: String, format: DisplayVideoFormat = .standard) throws {
    func require(_ value: Bool) throws { if !value { throw DisplayPipelineTestError.failed } }
    try require(format.valid)
    let deadline = ProcessInfo.processInfo.systemUptime + 10
    let fd = path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
    try require(fd >= 0)
    defer { Darwin.close(fd) }
    var info = stat()
    try require(fstat(fd, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG && info.st_size > 0 && info.st_size <= 40 * 1024 * 1024)
    var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
    try bytes.withUnsafeMutableBytes { raw in
        var position = 0
        while position < raw.count {
            try require(ProcessInfo.processInfo.systemUptime < deadline)
            let count = Darwin.read(fd, raw.baseAddress!.advanced(by: position), raw.count - position)
            if count < 0 && errno == EINTR { continue }
            try require(count > 0); position += count
        }
    }
    var extra: UInt8 = 0
    try require(Darwin.read(fd, &extra, 1) == 0)
    let root = SymmetricKey(size: .bits256)
    let senderNonce = UUID().uuidString, receiverNonce = UUID().uuidString
    func channel(_ forward: Bool) -> DisplayChannelCipher {
        DisplayChannelCipher(root: root, senderNonce: senderNonce, receiverNonce: receiverNonce, senderToReceiver: forward)
    }
    var sender = channel(true), receiver = channel(true)
    var reverseSender = channel(false), reverseReceiver = channel(false)
    var offset = 0, frames = 0, delivered = 0, identitySeen = false, decoderFailed = false
    var firstVideo: Data?, firstEncrypted: Data?
    var startupFrames: [Data] = []
    let decoder = DisplayH264Decoder(format: format, output: { pixel in
        guard displayPipelineHasContent(pixel, width: format.pixelWidth, height: format.pixelHeight) else { decoderFailed = true; return }
        delivered += 1
    }, failure: { decoderFailed = true })
    defer { decoder.clear() }
    func integer(_ n: UInt64) -> Data { Data((0..<8).reversed().map { UInt8(truncatingIfNeeded:n >> ($0*8)) }) }
    while offset < bytes.count {
        try require(ProcessInfo.processInfo.systemUptime < deadline && offset + 4 <= bytes.count)
        let length = Int(bytes[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }); offset += 4
        try require(length > 0 && length <= DisplayChannelCipher.maximumPayload && length <= bytes.count - offset)
        var plain = Data(bytes[offset..<(offset + length)]); offset += length
        if !identitySeen {
            try require(plain == Data([1, 0, 0, 0, 0]))
            plain = Data([1, 0, 0, 0, 1]); identitySeen = true
        } else { try require([2, 9, 10].contains(plain.first) && frames < 8) }
        if [2, 9, 10].contains(plain.first) { plain = Data([6])+integer(UInt64(frames))+integer(100)+integer(110)+integer(150)+plain }
        try require(DisplayChannelCipher.allowedPayload(plain, fromSender: true))
        let encrypted = try sender.seal(plain)
        if firstEncrypted == nil { firstEncrypted = encrypted }
        let restored = try receiver.open(encrypted)
        try require(restored == plain && DisplayChannelCipher.allowedPayload(restored, fromSender: true))
        if restored.first == 1 { try require(restored == Data([1, 0, 0, 0, 1])); continue }
        let stamped = try DisplayStreamFrame(restored)
        try require(stamped.sequence == UInt64(frames))
        if firstVideo == nil { firstVideo = stamped.video }
        startupFrames.append(stamped.video); frames += 1
    }
    try require(identitySeen && frames == 8)
    // One actor turn: no per-frame waits, compressed references must all complete.
    for frame in startupFrames { try decoder.accept(frame) }
    try require(decoder.inFlightFrameCount == 4 && decoder.pendingFrameCount == 4)
    while decoder.completedSubmissions < 8 && !decoderFailed && ProcessInfo.processInfo.systemUptime < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.005))
    }
    try require(!decoderFailed && decoder.completedSubmissions == 8 && delivered > 0 && delivered <= 8)
    try require(decoder.inFlightFrameCount == 0 && decoder.pendingFrameCount == 0)
    guard let originalCiphertext = firstEncrypted, firstVideo != nil else { throw DisplayPipelineTestError.failed }
    var rejected = 0
    do { _ = try receiver.open(originalCiphertext) } catch { rejected += 1 }
    var damaged = originalCiphertext; damaged[damaged.count - 1] ^= 1
    var tamperReceiver = channel(true)
    do { _ = try tamperReceiver.open(damaged) } catch { rejected += 1 }
    try require(tamperReceiver.sequence == 0)
    var wrongDirection = channel(false)
    do { _ = try wrongDirection.open(originalCiphertext) } catch { rejected += 1 }
    try require(wrongDirection.sequence == 0)
    var ownership = DisplayInputOwnership()
    let input = [DisplayInputPacket(kind: .keyDown, code: 0), DisplayInputPacket(kind: .keyUp, code: 0)]
    var reverseFirst: Data?
    for packet in input {
        let plain = try packet.encoded()
        try require(!DisplayChannelCipher.allowedPayload(plain, fromSender: false) && !DisplayChannelCipher.allowedPayload(plain, fromSender: true))
        let encrypted = try reverseSender.seal(plain)
        if reverseFirst == nil { reverseFirst = encrypted }
        let restored = try reverseReceiver.open(encrypted)
        let parsed = try DisplayInputPacket(data: restored)
        try require(parsed == packet)
        try ownership.accept(parsed)
    }
    try require(ownership.keys.isEmpty && ownership.buttons.isEmpty)
    guard let reverseFirst else { throw DisplayPipelineTestError.failed }
    do { _ = try reverseReceiver.open(reverseFirst) } catch { rejected += 1 }
    var reverseDamaged = reverseFirst; reverseDamaged[reverseDamaged.count - 1] ^= 1
    var reverseTamper = channel(false)
    do { _ = try reverseTamper.open(reverseDamaged) } catch { rejected += 1 }
    var reverseWrongDirection = channel(true)
    do { _ = try reverseWrongDirection.open(reverseFirst) } catch { rejected += 1 }
    try require(rejected == 6 && reverseTamper.sequence == 0 && reverseWrongDirection.sequence == 0)
    decoder.clear()
    var staleCallbacks = 0
    let retired = DisplayH264Decoder(format: format, output: { _ in staleCallbacks += 1 }, failure: { staleCallbacks += 1 })
    for frame in startupFrames { try retired.accept(frame) }
    try require(retired.inFlightFrameCount == 4 && retired.pendingFrameCount == 4)
    retired.clear()
    try require(retired.inFlightFrameCount == 0 && retired.pendingFrameCount == 0)
    let staleDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + 0.15)
    while ProcessInfo.processInfo.systemUptime < staleDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
    try require(staleCallbacks == 0 && ProcessInfo.processInfo.systemUptime < deadline)
    print("PASS display offline pipeline: helper H264 -> stamped v6 metadata -> AEAD -> negotiated-size decoder startup burst 8/8 completed with nonempty latest-only output; legacy input denied by v5 for both roles; codec memory-only 2/2; replay/tamper/direction rejected 6/6; stale callbacks=0; no real network/window/capture/input posting")
}

#endif

private func displayPipelineHasContent(_ pixel: CVPixelBuffer, width: Int, height: Int) -> Bool {
    guard CVPixelBufferGetWidth(pixel) == width, CVPixelBufferGetHeight(pixel) == height,
          CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_32BGRA,
          CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess else { return false }
    defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pixel) else { return false }
    let strideBytes = CVPixelBufferGetBytesPerRow(pixel)
    guard strideBytes >= width * 4 else { return false }
    let source = base.assumingMemoryBound(to: UInt8.self)
    var minimum: UInt8 = 255, maximum: UInt8 = 0, sum: UInt64 = 0
    for y in stride(from: 20, to: height - 20, by: 80) {
        for x in stride(from: 20, to: width - 20, by: 80) {
            for color in 0..<3 {
                let value = source[y * strideBytes + x * 4 + color]
                minimum = min(minimum, value); maximum = max(maximum, value); sum += UInt64(value)
            }
        }
    }
    guard sum > 0, maximum > minimum else { return false }
    return true
}

#if DISPLAY_PIPELINE_PIXEL_TEST_MAIN
@main private struct DisplayPipelinePixelTestMain {
    static func main() {
        var checks = 0, failures = 0
        func check(_ condition: Bool, _ label: String) {
            checks += 1
            if !condition { failures += 1; print("Pixel FAIL: \(label)") }
        }
        let width = 256, height = 256
        for format in [kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_422YpCbCr8, kCVPixelFormatType_OneComponent8] {
            var pixel: CVPixelBuffer?
            let result = CVPixelBufferCreate(nil, width, height, format, nil, &pixel)
            check(result == kCVReturnSuccess && pixel != nil, "allocate real buffer \(format)")
            guard let pixel else { continue }
            let supported = format != kCVPixelFormatType_OneComponent8
            for patterned in [false, true] {
                CVPixelBufferLockBaseAddress(pixel, [])
                let planar = CVPixelBufferIsPlanar(pixel)
                for plane in 0..<(planar ? CVPixelBufferGetPlaneCount(pixel) : 1) {
                    let base = planar ? CVPixelBufferGetBaseAddressOfPlane(pixel, plane) : CVPixelBufferGetBaseAddress(pixel)
                    let strideBytes = planar ? CVPixelBufferGetBytesPerRowOfPlane(pixel, plane) : CVPixelBufferGetBytesPerRow(pixel)
                    let rows = planar ? CVPixelBufferGetHeightOfPlane(pixel, plane) : height
                    if let base {
                        memset(base, plane == 0 ? 0 : 128, strideBytes * rows)
                        let bytes = base.assumingMemoryBound(to: UInt8.self)
                        for y in 0..<rows {
                            for x in 0..<width {
                                let value: UInt8 = patterned && x >= 128 ? 200 : (format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || format == kCVPixelFormatType_422YpCbCr8 ? 16 : 0)
                                if format == kCVPixelFormatType_32BGRA {
                                    for c in 0..<3 { bytes[y * strideBytes + x * 4 + c] = patterned && x >= 128 ? 200 : 0 }
                                } else if format == kCVPixelFormatType_422YpCbCr8 {
                                    bytes[y * strideBytes + x * 2] = 128
                                    bytes[y * strideBytes + x * 2 + 1] = value
                                } else if plane == 0 { bytes[y * strideBytes + x] = value }
                            }
                        }
                    }
                }
                CVPixelBufferUnlockBaseAddress(pixel, [])
                check(displayPipelineHasContent(pixel, width: width, height: height) == (supported && patterned), "format \(format) patterned=\(patterned)")
                check(!displayPipelineHasContent(pixel, width: width + 1, height: height), "bad width \(format)")
                check(!displayPipelineHasContent(pixel, width: width, height: height + 1), "bad height \(format)")
            }
        }
        print("Display pipeline pixels: \(checks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
#endif
