import Foundation

/// Pure byte-stream tests: no helper, network, UI, or production diagnostics.
func runDisplayDiagnosticLinesTests() -> Int {
    var failures = 0, checks = 0
    func check(_ value: Bool, _ label: String) {
        checks += 1
        if !value { failures += 1; print("FAIL DisplayDiagnosticLines: \(label)") }
    }
    var output: [String] = []
    func emit(_ text: String) { output.append(text) }

    var tail = DisplayDiagnosticLines(budgetCapacity: 100_000)
    let stream = Data((String(repeating: "startup record\n", count: 800) + "TAIL_AFTER_8192\n").utf8)
    var offset = 0
    while offset < stream.count {
        let end = min(stream.count, offset + 1024)
        tail.append(stream.subdata(in: offset..<end), now: 0, emit: emit)
        offset = end
    }
    tail.finish(now: 0, emit: emit)
    check(stream.count > 8192 && output.count == 801 && output.last == "Display helper: TAIL_AFTER_8192", "drain and frame tail beyond 8192 bytes")

    let unicode = Data("가나다 café\n".utf8)
    for split in 0...unicode.count {
        output = []
        var parser = DisplayDiagnosticLines()
        parser.append(unicode.prefix(split), now: 0, emit: emit)
        parser.append(unicode.dropFirst(split), now: 0, emit: emit)
        parser.finish(now: 0, emit: emit)
        check(output == ["Display helper: 가나다 café"], "UTF8 every split \(split)")
    }
    output = []
    var crlf = DisplayDiagnosticLines()
    crlf.append(Data("first\r".utf8), now: 0, emit: emit)
    crlf.append(Data("\nsecond\r\n\nlast".utf8), now: 0, emit: emit)
    crlf.finish(now: 0, emit: emit)
    crlf.finish(now: 0, emit: emit)
    check(output == ["Display helper: first", "Display helper: second", "Display helper: ", "Display helper: last"], "split CRLF, blank line, EOF flush exactly once")

    output = []
    var huge = DisplayDiagnosticLines()
    let block = Data(repeating: 65, count: 1024)
    var maximumRetained = 0
    for _ in 0..<4096 {
        huge.append(block, now: 0, emit: emit)
        maximumRetained = max(maximumRetained, huge.retainedByteCount)
    }
    check(maximumRetained == 2048 && output.isEmpty, "4 MiB unterminated line retains only 2048 bytes")
    huge.append(Data("\ntail\n".utf8), now: 0, emit: emit)
    check(output.count == 2 && output[0] == "Display helper: " + String(repeating: "A", count: 2048) + " [line truncated]" && output[1] == "Display helper: tail", "overlong marker and next line recovered")
    check(huge.retainedByteCount == 0, "retained state empty after delimiter")

    output = []
    var boundary = DisplayDiagnosticLines(maxLineBytes: 4)
    boundary.append(Data("1234\r\n12345".utf8), now: 0, emit: emit)
    boundary.finish(now: 0, emit: emit)
    check(output == ["Display helper: 1234", "Display helper: 1234 [line truncated]"], "exact-cap CRLF and oversized EOF")
    output = []
    var malformed = DisplayDiagnosticLines()
    malformed.append(Data([0xff, 10]), now: 0, emit: emit)
    check(output == ["Display helper: \u{fffd}"], "malformed UTF8 uses replacement rather than dropping chunk")

    output = []
    var limited = DisplayDiagnosticLines(budgetCapacity: 128, refillPerSecond: 128)
    limited.append(Data(String(repeating: "x\n", count: 1000).utf8), now: 10, emit: emit)
    check(output.count == 7 && limited.suppressedLineCount == 993, "startup byte allowance and suppressed count")
    check(limited.retainedByteCount == 0, "budget exhaustion still consumes all delimiters")
    let beforeCooldown = output.count
    limited.append(Data("early\n".utf8), now: 10.25, emit: emit)
    check(!output.dropFirst(beforeCooldown).contains(where: { $0.contains("suppressed") }), "no suppression summary before cooldown")
    limited.append(Data("recovered\n".utf8), now: 11, emit: emit)
    check(output.contains("Display helper: suppressed 993 diagnostic lines (log rate limit)") && output.last == "Display helper: recovered" && limited.suppressedLineCount == 0, "cooldown summary and refill recovery")
    let used = output.reduce(0) { $0 + $1.utf8.count + 1 }
    check(used <= 256, "emitted bytes including summary respect startup plus elapsed refill")

    output = []
    var clock = DisplayDiagnosticLines(budgetCapacity: 128, refillPerSecond: 128)
    clock.append(Data(String(repeating: "x\n", count: 10).utf8), now: 20, emit: emit)
    let originalCount = output.count
    clock.append(Data("backward\n".utf8), now: 19, emit: emit)
    clock.append(Data("invalid\n".utf8), now: .nan, emit: emit)
    check(output.count == originalCount, "backwards or invalid clock grants no refill")
    clock.finish(now: 21, emit: emit)
    check(output.last == "Display helper: suppressed 5 diagnostic lines (log rate limit)", "EOF reports pending suppression after cooldown")
    clock.append(Data(String(repeating: "y\n", count: 1000).utf8), now: 1_000_000, emit: emit)
    check(output.suffix(7).allSatisfy { $0 == "Display helper: y" } && clock.suppressedLineCount == 993, "long idle refill capped at bucket capacity")

    var rawRows=[String](), plainRows=[String]();var rawParser=DisplayDiagnosticLines(budgetCapacity:32,refillPerSecond:0)
    let traceLine="TC_DIAG stage=frame seq=18446744073709551615 us=123\n"
    for _ in 0..<1000 {rawParser.append(Data(traceLine.utf8),now:0,emit:{plainRows.append($0)},raw:{rawRows.append($0)})}
    check(rawRows.count==1000 && plainRows.isEmpty,"structured helper traces bypass summary budget without truncation")
    var partial=DisplayDiagnosticLines();var splitRows=[String]()
    partial.append(Data("TC_DIAG stage=frame seq=".utf8),now:0,emit:{_ in},raw:{splitRows.append($0)})
    partial.append(Data("7 us=1\n".utf8),now:1,emit:{_ in},raw:{splitRows.append($0)})
    check(splitRows==["TC_DIAG stage=frame seq=7 us=1"],"structured split chunks reassembled exactly")
    print("DisplayDiagnosticLines: \(checks) checks, \(failures) failures; pure in-memory tests")
    return failures
}
