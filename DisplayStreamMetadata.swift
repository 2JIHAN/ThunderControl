import Foundation

/// Header-only v6 envelope validation. Reads a fixed 34-byte prefix and never
/// materializes or retains the inner video. Codec parsing remains the decoder's job.
/// All source timestamps share SOURCE monotonic uptime, not receiver uptime.
struct DisplayStreamFrameHeader {
    static let videoOffset = 33
    let sequence: UInt64
    let capture: UInt64
    let encodeStart: UInt64
    let encodeEnd: UInt64
    init(_ data: Data) throws {
        guard data.count >= 43, data.count <= DisplayChannelCipher.maximumPayload,
              data.first == 6, [2, 9].contains(data[data.startIndex + Self.videoOffset]) else { throw DisplayTransportError.invalid }
        sequence = Self.number(data, 1, 8); capture = Self.number(data, 9, 8)
        encodeStart = Self.number(data, 17, 8); encodeEnd = Self.number(data, 25, 8)
        guard capture > 0, capture <= encodeStart, encodeStart <= encodeEnd,
              encodeEnd - capture <= 30_000_000 else { throw DisplayTransportError.invalid }
    }
    static func number(_ d: Data, _ offset: Int, _ size: Int) -> UInt64 {
        d.dropFirst(offset).prefix(size).reduce(0) { ($0 << 8) | UInt64($1) }
    }
}

/// Actual decoder unwrap: copy the inner video only when it is consumed.
/// Network clock offset and physical panel latency are unknown.
struct DisplayStreamFrame {
    let sequence: UInt64
    let capture: UInt64
    let encodeStart: UInt64
    let encodeEnd: UInt64
    let video: Data
    init(_ data: Data) throws {
        let header = try DisplayStreamFrameHeader(data)
        sequence = header.sequence; capture = header.capture
        encodeStart = header.encodeStart; encodeEnd = header.encodeEnd
        video = Data(data.dropFirst(DisplayStreamFrameHeader.videoOffset))
    }
    static func number(_ d: Data, _ offset: Int, _ size: Int) -> UInt64 {
        DisplayStreamFrameHeader.number(d, offset, size)
    }
}

/// Authoritative, normalized top-left cursor, no local input prediction. Shapes
/// are bounded public standard shapes; unsupported/currentSystem unavailable = arrow.
struct DisplayCursorMetadata {
    let sequence: UInt64
    let visible: Bool
    let shape: UInt8
    let x: Double
    let y: Double
    init(_ data: Data) throws {
        guard data.count == 19, data.first == 7, data[9] <= 1, data[10] <= 4 else { throw DisplayTransportError.invalid }
        sequence = DisplayStreamFrame.number(data, 1, 8); visible = data[9] == 1; shape = data[10]
        let px = DisplayStreamFrame.number(data, 11, 4), py = DisplayStreamFrame.number(data, 15, 4)
        guard px <= 1_000_000, py <= 1_000_000 else { throw DisplayTransportError.invalid }
        x = Double(px) / 1_000_000; y = Double(py) / 1_000_000
    }
}

/// Test fixtures log only to their redirected stdout, never the user diagnostics.
func displayStageLog(_ text: String) {
    let arguments = CommandLine.arguments
    if arguments.contains("--self-test") || arguments.contains(where: { $0.hasPrefix("--display-") }) { print(text); return }
    connectionLog(text)
}
