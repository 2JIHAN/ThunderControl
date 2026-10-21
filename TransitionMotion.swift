// Scalar-only transition state. Callers admit mouse MOVE deltas only while the
// matching transaction is pending/committed, then take once after ownership is
// active and the cursor pin is acquired. Keys/buttons must never enter here.
struct EntryMotionBuffer {
  private var token: String?
  private var dx: Double = 0
  private var dy: Double = 0
  private var grossX: Double = 0
  private var grossY: Double = 0
  private var samples: [(dx: Double, dy: Double)] = []
  var count: Int { samples.count }
  var hasMotion: Bool { !samples.isEmpty }

  mutating func begin(token: String) {
    reset()
    self.token = token
  }

  @discardableResult
  mutating func append(token: String, dx: Double, dy: Double) -> Bool {
    let limit = 131_072.0
    guard self.token == token, dx.isFinite, dy.isFinite,
      abs(dx) <= limit, abs(dy) <= limit, count < 2_048
    else { return false }
    let nextX = self.dx + dx
    let nextY = self.dy + dy
    let nextGrossX = grossX + abs(dx)
    let nextGrossY = grossY + abs(dy)
    guard nextX.isFinite, nextY.isFinite,
      nextGrossX.isFinite, nextGrossY.isFinite,
      abs(nextX) <= limit, abs(nextY) <= limit,
      nextGrossX <= limit, nextGrossY <= limit
    else { return false }
    self.dx = nextX
    self.dy = nextY
    grossX = nextGrossX
    grossY = nextGrossY
    samples.append((dx: dx, dy: dy))
    return true
  }

  // Replay each scalar pair through handoff.relative in order before posting
  // one absolute event. Net-only replay loses intermediate boundary clamps.
  mutating func takeMoves(token: String) -> [(dx: Double, dy: Double)]? {
    guard self.token == token else { return nil }
    let result = hasMotion ? samples : nil
    reset()
    return result
  }

  // Compatibility only: do not use this aggregate to replay clamped motion.
  mutating func take(token: String) -> (dx: Double, dy: Double)? {
    guard self.token == token else { return nil }
    let result = hasMotion ? (dx: dx, dy: dy) : nil
    reset()
    return result
  }

  mutating func reset() {
    token = nil
    dx = 0
    dy = 0
    grossX = 0
    grossY = 0
    samples.removeAll(keepingCapacity: false)
  }
}

// `edge` is the SOURCE's selected edge, not the receiver's entry edge.
// Returned carry has the same sign as dx; add it to the source edge inset.
struct ReturnMotionCarry {
  private var carry: Double = 0
  private var edge: Edge?
  private var windowStart: Double?
  private var lastTime: Double?
  private let lifetime = 0.020

  mutating func observe(
    edge: Edge, x: Double, width: Double, dx: Double, now: Double, held: Bool
  ) {
    guard !held, x.isFinite, width.isFinite, dx.isFinite, now.isFinite,
      width >= 64, width <= 32_768, x >= 0, x <= width - 1
    else { reset(); return }
    if let lastTime = lastTime, now < lastTime { reset(); return }

    // Compare against remaining distance before arithmetic so huge finite
    // deltas never overflow x + dx. Only the unapplied excess is carried.
    let excess: Double
    switch edge {
    case .right:
      guard dx < -x else { reset(); return }
      excess = dx + x
    case .left:
      let remaining = (width - 1) - x
      guard dx > remaining else { reset(); return }
      excess = dx - remaining
    }
    guard excess.isFinite else { reset(); return }

    // An expired accumulation is replaced, never revived by a new sample.
    // Anchored windows also ensure continuous motion cannot retain old carry.
    if self.edge != edge || windowStart.map({ now > $0 + lifetime }) != false {
      reset()
      self.edge = edge
      windowStart = now
    }
    carry = min(64, max(-64, carry + min(64, max(-64, excess))))
    lastTime = now
  }

  mutating func take(now: Double) -> Double {
    defer { reset() }
    guard now.isFinite, let start = windowStart, let last = lastTime,
      now >= last, now <= start + lifetime
    else { return 0 }
    return carry
  }

  mutating func reset() {
    carry = 0
    edge = nil
    windowStart = nil
    lastTime = nil
  }
}
