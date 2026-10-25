import Foundation

/// One helper's stderr state. Draining is never conditional on the log allowance.
/// Caller owns the off-main read loop and supplies a nonblocking diagnostic sink.
struct DisplayDiagnosticLines {
    private let maxLineBytes: Int
    private let capacity: Double
    private let refillPerSecond: Double
    private let suppressionInterval: Double
    private var bytes: [UInt8] = []
    private var truncated = false
    private var afterCR = false
    private var tokens: Double
    private var lastTime: Double?
    private var lastSummaryTime: Double?
    private(set) var suppressedLineCount: UInt64 = 0
    var retainedByteCount: Int { bytes.count }

    init(maxLineBytes: Int = 2048, budgetCapacity: Int = 16384,
         refillPerSecond: Double = 4096, suppressionInterval: Double = 1) {
        precondition(maxLineBytes > 0 && budgetCapacity > 0 && refillPerSecond.isFinite && refillPerSecond >= 0)
        precondition(suppressionInterval.isFinite && suppressionInterval > 0)
        self.maxLineBytes = maxLineBytes
        self.capacity = Double(budgetCapacity)
        self.tokens = Double(budgetCapacity)
        self.refillPerSecond = refillPerSecond
        self.suppressionInterval = suppressionInterval
        bytes.reserveCapacity(maxLineBytes)
    }

    /// `now` is host-local monotonic seconds; a chunk boundary is not a line boundary.
    mutating func append(_ data: Data, now: Double, emit: (String) -> Void, raw: ((String) -> Void)? = nil) {
        refill(now)
        for byte in data {
            if afterCR {
                afterCR = false
                if byte == 10 { continue }
            }
            if byte == 10 || byte == 13 {
                finishLine(emit: emit, raw: raw)
                afterCR = byte == 13
            } else if bytes.count < maxLineBytes {
                bytes.append(byte)
            } else {
                truncated = true // Discard until the delimiter, never retain the tail.
            }
        }
    }

    mutating func finish(now: Double, emit: (String) -> Void, raw: ((String) -> Void)? = nil) {
        refill(now)
        if !bytes.isEmpty || truncated { finishLine(emit: emit, raw: raw) }
        reportSuppression(emit: emit)
        afterCR = false
    }

    private mutating func refill(_ now: Double) {
        guard now.isFinite, now >= 0 else { return }
        if let previous = lastTime {
            guard now >= previous else { return }
            tokens = min(capacity, tokens + (now - previous) * refillPerSecond)
        }
        lastTime = now
    }

    private mutating func finishLine(emit: (String) -> Void, raw: ((String) -> Void)? = nil) {
        reportSuppression(emit: emit)
        // Replace malformed UTF-8 explicitly; split valid sequences remain intact
        // because decoding occurs only at a delimiter or EOF.
        let unprefixed = String(decoding: bytes, as: UTF8.self)
        let isStructured = unprefixed.hasPrefix("TC_DIAG ")
        if isStructured && !truncated { raw?(unprefixed) }
        let line = "Display helper: " + unprefixed
            + (truncated ? " [line truncated]" : "")
        bytes.removeAll(keepingCapacity: true)
        truncated = false
        if isStructured && !line.contains("[line truncated]") { return }
        if !offer(line, emit: emit) {
            if suppressedLineCount < UInt64.max { suppressedLineCount += 1 }
            if lastSummaryTime == nil { lastSummaryTime = lastTime }
        }
    }

    private mutating func reportSuppression(emit: (String) -> Void, raw: ((String) -> Void)? = nil) {
        guard suppressedLineCount > 0, let now = lastTime,
              now - (lastSummaryTime ?? now) >= suppressionInterval else { return }
        let summary = "Display helper: suppressed \(suppressedLineCount) diagnostic lines (log rate limit)"
        if offer(summary, emit: emit) {
            suppressedLineCount = 0
            lastSummaryTime = now
        }
    }

    private mutating func offer(_ line: String, emit: (String) -> Void) -> Bool {
        let cost = Double(line.utf8.count + 1)
        guard cost <= tokens else { return false }
        tokens -= cost
        emit(line)
        return true
    }
}
