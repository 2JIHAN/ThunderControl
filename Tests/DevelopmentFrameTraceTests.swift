import Foundation
import CoreVideo

/// Synthetic mailbox/cookie/pacer checks only. No viewer, decoder session, store,
/// capture or renderer is started. Hook events carry numeric metadata, never pixels.
func runDevelopmentFrameTraceTests() -> Int {
    var checks = 0, failures = 0
    func check(_ ok: Bool, _ name: String) {
        checks += 1
        if !ok { failures += 1; print("FAIL DevelopmentFrameTrace: \(name)") }
    }
    typealias Event = (stage: String, sequence: UInt64?, fields: [String: Double], stream: String?)
    var events: [Event] = []
    let trace = DisplayFrameTrace(stream: "old-session", hook: { events.append(($0, $1, $2, $3)) })
    let a = DisplayFrameIdentity(sourceSequence: 900, cookie: 0, generation: 7)
    let b = DisplayFrameIdentity(sourceSequence: 901, cookie: 1, generation: 7)
    var work: [() -> Void] = []
    var outputs: [DisplayFrameIdentity] = []
    var completed: [Int64] = []
    let format = DisplayVideoFormat.standard
    var pixel: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault, format.pixelWidth, format.pixelHeight,
                                    kCVPixelFormatType_32BGRA, nil, &pixel)
    guard status == kCVReturnSuccess, let pixel else {
        check(false, "synthetic pixel allocation"); return failures
    }
    let mailbox = DisplayDecodeMailbox(format: format, trace: trace, generation: 7,
        scheduleDrain: { work.append($0) }, deliver: { _, identity in outputs.append(identity) },
        failure: { check(false, "unexpected decode failure") }, space: { completed += $0 })
    check(mailbox.reserve(sequence: 0, identity: a), "reserve a")
    check(mailbox.reserve(sequence: 1, identity: b), "reserve b")
    // The second submission completes FIRST. Metadata must follow callback cookie,
    // not an admission FIFO or the most recent received source sequence.
    mailbox.complete(status: 0, flags: [], pixel: pixel, sequence: 1)
    mailbox.complete(status: 0, flags: [], pixel: pixel, sequence: 0)
    check(work.count == 1, "coalescing unchanged")
    work.removeFirst()()
    check(outputs == [a] && completed == [1, 0], "reordered callbacks preserve actual latest completion")
    check(events.filter { $0.stage == "decoder_callback" }.map { $0.sequence } == [901, 900], "cookie correlation")
    check(events.first { $0.stage == "mailbox_replace" }?.sequence == 901, "replaced identity is victim")
    check(events.first { $0.stage == "decoder_main_delivery" }?.sequence == 900, "main delivery identity")
    mailbox.complete(status: 0, flags: [], pixel: pixel, sequence: 0)
    check(work.isEmpty && outputs == [a], "duplicate callback inert")
    let c = DisplayFrameIdentity(sourceSequence: 902, cookie: 2, generation: 7)
    check(mailbox.reserve(sequence: 2, identity: c), "reserve before close")
    mailbox.complete(status: 0, flags: [], pixel: pixel, sequence: 2)
    mailbox.invalidate()
    work.removeFirst()()
    mailbox.complete(status: 0, flags: [], pixel: pixel, sequence: 2)
    check(outputs == [a], "queued and late callbacks after close do not deliver")
    check(events.last?.stage == "decoder_callback_ignored" && events.last?.sequence == nil &&
          events.last?.fields["decoderGeneration"] == 7, "retired callback does not borrow a new identity")
    check(events.allSatisfy { $0.stream == "old-session" }, "old callback stream remains captured")

    var discards: [(UInt64?, DisplayFrameDiscardReason)] = []
    var pacer = DisplayFramePacer<DisplayTracedFrame>(onDiscard: { frame, reason in
        discards.append((frame.identity.sourceSequence, reason))
        trace.record("pacer_discard", identity: frame.identity, fields: ["reason": Double(reason.rawValue)])
    })
    let frameA = DisplayTracedFrame(pixel: pixel, identity: a, decodedMainAt: 1)
    let frameB = DisplayTracedFrame(pixel: pixel, identity: b, decodedMainAt: 2)
    let frameC = DisplayTracedFrame(pixel: pixel, identity: c, decodedMainAt: 3)
    pacer.offer(frameA, at: 0); pacer.offer(frameB, at: 0.001); pacer.offer(frameC, at: 0.002)
    let selected = pacer.take(now: 1, targetTimestamp: 1)
    check(selected?.identity == c && selected?.decodedMainAt == 3, "selected frame retains its own identity and main time")
    check(discards.count == 2 && discards[0].0 == 900 && discards[0].1 == .overflow &&
          discards[1].0 == 901 && discards[1].1 == .superseded, "overflow and supersession victims")
    check(pacer.stats.offered == 3 && pacer.stats.selected == 1 && pacer.stats.overflowReplaced == 1 &&
          pacer.stats.superseded == 1, "original counters unchanged")
    pacer.offer(frameA, at: 2); pacer.offer(frameB, at: 1)
    check(discards.last?.0 == 901 && discards.last?.1 == .invalidOffer, "invalid offer only discards incoming frame")
    pacer.clear()
    check(discards.last?.0 == 900 && discards.last?.1 == .clear && pacer.pendingCount == 0 &&
          pacer.stats == DisplayFramePacingStats(), "clear victims and reset unchanged")
    // Capacity-pressure fallback deliberately selects the OLDER buffered frame,
    // not the latest received frame. The trace must carry that older identity/time.
    pacer.offer(frameA, at: 5); pacer.offer(frameB, at: 5.001)
    let older = pacer.take(now: 5.002, targetTimestamp: 5.002)
    check(older?.identity == a && older?.decodedMainAt == 1 && pacer.pendingCount == 1 &&
          pacer.stats.earlySelections == 1, "fallback identity is actual older selection, not latest frame")
    pacer.clear()
    let freshIdentity = DisplayFrameIdentity(sourceSequence: 1000, cookie: 0, generation: 8)
    let freshTrace = DisplayFrameTrace(stream: "new-session", hook: { events.append(($0, $1, $2, $3)) })
    let fresh = DisplayDecodeMailbox(format: format, trace: freshTrace, generation: 8,
        scheduleDrain: { work.append($0) }, deliver: { _, identity in outputs.append(identity) },
        failure: { check(false, "fresh failure") }, space: { _ in })
    check(fresh.reserve(sequence: 0, identity: freshIdentity), "new generation can reuse cookie")
    mailbox.complete(status: 0, flags: [], pixel: pixel, sequence: 0)
    check(events.last?.stage == "decoder_callback_ignored" && events.last?.stream == "old-session" &&
          events.last?.sequence == nil, "late old cookie cannot inherit fresh stream/source")
    fresh.complete(status: 0, flags: [], pixel: pixel, sequence: 0)
    work.removeFirst()()
    check(outputs.last == freshIdentity && events.last?.stream == "new-session" &&
          events.last?.sequence == 1000, "fresh generation remains independently correlated")
    fresh.invalidate()
    var nilEvents = 0
    DisplayFrameTrace(stream: nil, hook: { _, sequence, _, stream in
        if sequence == nil && stream == nil { nilEvents += 1 }
    }).record("legacy")
    check(nilEvents == 1, "legacy identity stays unknown")
    print("Development frame trace: \(checks) checks, \(failures) failures; synthetic stages, not panel presentation")
    return failures
}
