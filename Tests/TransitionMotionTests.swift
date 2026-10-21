// Memory-only tests: no event objects, I/O, hardware, or ownership side effects.
func runTransitionMotionTests() -> Int {
  var failures = 0
  func check(_ condition: Bool) { if !condition { failures += 1 } }
  func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.000_001 }

  var entry = EntryMotionBuffer()
  check(!entry.append(token: "a", dx: 1, dy: 2))
  entry.begin(token: "a")
  check(entry.append(token: "a", dx: 12, dy: -3))
  check(entry.append(token: "a", dx: 8, dy: 5))
  check(entry.hasMotion && entry.count == 2)
  check(!entry.append(token: "old", dx: 99, dy: 99))
  check(entry.take(token: "old") == nil && entry.count == 2)
  let first = entry.take(token: "a")
  check(first?.dx == 20 && first?.dy == 2)
  check(!entry.hasMotion && entry.count == 0)
  check(entry.take(token: "a") == nil)
  check(!entry.append(token: "a", dx: 1, dy: 1))
  entry.begin(token: "a")
  check(entry.append(token: "a", dx: 7, dy: 8))
  entry.begin(token: "b")
  check(entry.take(token: "a") == nil)
  check(entry.append(token: "b", dx: -2, dy: 9))
  check(entry.take(token: "b")?.dx == -2)
  entry.begin(token: "limit")
  check(entry.append(token: "limit", dx: 131_072, dy: -131_072))
  check(!entry.append(token: "limit", dx: 1, dy: 0))
  check(!entry.append(token: "limit", dx: 0, dy: -1))
  for invalid in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, 131_073] {
    check(!entry.append(token: "limit", dx: invalid, dy: 0))
    check(!entry.append(token: "limit", dx: 0, dy: invalid))
  }
  check(entry.count == 1)
  let bounded = entry.take(token: "limit")
  check(bounded?.dx == 131_072 && bounded?.dy == -131_072)
  entry.begin(token: "zero")
  check(entry.append(token: "zero", dx: 0, dy: 0))
  check(entry.take(token: "zero")?.dx == 0)
  entry.begin(token: "reset")
  check(entry.append(token: "reset", dx: 1, dy: 2))
  entry.reset()
  check(entry.take(token: "reset") == nil)

  // Ordered replay preserves intermediate clamps, unlike one net delta.
  entry.begin(token: "ordered")
  check(entry.append(token: "ordered", dx: 2, dy: -30))
  check(entry.append(token: "ordered", dx: 2, dy: 30))
  check(!entry.append(token: "wrong", dx: 9, dy: 9))
  check(entry.takeMoves(token: "wrong") == nil && entry.count == 2)
  let moves = entry.takeMoves(token: "ordered")
  check(moves?.count == 2)
  var replayX = 1.0
  var replayY = 10.0
  var lastNonzeroDX = 0.0
  for move in moves ?? [] {
    replayX = min(99, max(0, replayX + move.dx))
    replayY = min(99, max(0, replayY + move.dy))
    if move.dx != 0 { lastNonzeroDX = move.dx }
  }
  check(replayY == 30 && replayY != 10)
  check(replayX == 5 && lastNonzeroDX == 2) // outward: no source retract
  check(entry.takeMoves(token: "ordered") == nil)
  check(entry.take(token: "ordered") == nil)
  check(!entry.append(token: "ordered", dx: 1, dy: 1))

  entry.begin(token: "gross")
  check(entry.append(token: "gross", dx: 65_536, dy: -65_536))
  check(entry.append(token: "gross", dx: -65_536, dy: 65_536))
  check(!entry.append(token: "gross", dx: 1, dy: 0))
  check(!entry.append(token: "gross", dx: 0, dy: -1))
  check(!entry.append(token: "gross", dx: .nan, dy: 0))
  check(!entry.append(token: "gross", dx: .greatestFiniteMagnitude, dy: 0))
  check(!entry.append(token: "wrong", dx: 0, dy: 0))
  check(entry.count == 2)
  let grossMoves = entry.takeMoves(token: "gross")
  check(grossMoves?.count == 2)
  check(grossMoves?[0].dx == 65_536 && grossMoves?[0].dy == -65_536)
  check(grossMoves?[1].dx == -65_536 && grossMoves?[1].dy == 65_536)

  entry.begin(token: "capacity")
  for _ in 0..<1_500 { check(entry.append(token: "capacity", dx: 1, dy: -1)) }
  check(entry.count == 1_500)
  for _ in 1_500..<2_048 { check(entry.append(token: "capacity", dx: 1, dy: -1)) }
  check(entry.count == 2_048)
  check(!entry.append(token: "capacity", dx: 0, dy: 0))
  let fullMoves = entry.takeMoves(token: "capacity")
  check(fullMoves?.count == 2_048)
  check(fullMoves?.allSatisfy { $0.dx == 1 && $0.dy == -1 } == true)
  check(entry.count == 0 && !entry.hasMotion)

  entry.begin(token: "old")
  check(entry.append(token: "old", dx: 1, dy: 2))
  entry.begin(token: "fresh")
  check(entry.takeMoves(token: "old") == nil)
  check(entry.append(token: "fresh", dx: 3, dy: 4))
  check(entry.takeMoves(token: "fresh")?.first?.dx == 3)
  entry.begin(token: "resetMoves")
  check(entry.append(token: "resetMoves", dx: 1, dy: 2))
  entry.reset()
  check(entry.takeMoves(token: "resetMoves") == nil)
  entry.begin(token: "compat")
  check(entry.append(token: "compat", dx: 1, dy: 2))
  check(entry.take(token: "compat")?.dx == 1)
  check(entry.takeMoves(token: "compat") == nil)
  entry.begin(token: "empty")
  check(entry.takeMoves(token: "empty") == nil)
  check(!entry.append(token: "empty", dx: 1, dy: 1))

  var carry = ReturnMotionCarry()
  func sample(_ edge: Edge = .right, _ x: Double = 1, _ width: Double = 100,
              _ dx: Double = -5, _ now: Double = 1, _ held: Bool = false) {
    carry.observe(edge: edge, x: x, width: width, dx: dx, now: now, held: held)
  }
  sample()
  check(near(carry.take(now: 1.01), -4))
  check(carry.take(now: 1.01) == 0)
  sample(.left, 98, 100, 5)
  check(near(carry.take(now: 1.01), 4))
  sample(.right, 2, 100, -7)
  sample(.right, 0, 100, -8, 1.01)
  check(carry.take(now: 1.015) == -13)
  sample(.right, 0, 100, -60)
  sample(.right, 0, 100, -60, 1.01)
  check(carry.take(now: 1.015) == -64)
  sample(.left, 99, 100, 1000)
  check(carry.take(now: 1) == 64)
  sample(.right, 0, 100, -.greatestFiniteMagnitude)
  check(carry.take(now: 1) == -64)
  sample(.left, 99, 100, .greatestFiniteMagnitude)
  check(carry.take(now: 1) == 64)
  sample()
  check(carry.take(now: 1.021) == 0)
  sample()
  carry.reset()
  check(carry.take(now: 1) == 0)
  sample()
  sample(.right, 1, 100, 2, 1.001) // inward, not far-boundary carry
  check(carry.take(now: 1.002) == 0)
  sample()
  sample(.left, 98, 100, -200, 1.001)
  check(carry.take(now: 1.002) == 0)
  sample()
  sample(.right, 1, 100, -5, 1.001, true)
  check(carry.take(now: 1.002) == 0)
  sample()
  sample(.right, 5, 100, -5, 1.001) // exactly on boundary: no excess
  check(carry.take(now: 1.002) == 0)
  sample(.left, 94, 100, 5)
  check(carry.take(now: 1) == 0)
  sample()
  sample(.right, 0, 100, -2, 1.03) // expired old accumulation
  check(carry.take(now: 1.031) == -2)
  sample()
  sample(.left, 99, 100, 3, 1.001) // edge change starts fresh
  check(carry.take(now: 1.002) == 3)
  sample()
  sample(.right, 0, 100, -9, 0.99)
  check(carry.take(now: 1) == 0)
  sample()
  check(carry.take(now: 0.99) == 0)
  check(carry.take(now: 1) == 0)
  for invalid in [Double.nan, .infinity, -.infinity] {
    sample(); sample(.right, invalid)
    check(carry.take(now: 1) == 0)
    sample(); sample(.right, 1, invalid)
    check(carry.take(now: 1) == 0)
    sample(); sample(.right, 1, 100, invalid)
    check(carry.take(now: 1) == 0)
    sample(); sample(.right, 1, 100, -5, invalid)
    check(carry.take(now: 1) == 0)
    sample()
    check(carry.take(now: invalid) == 0)
    check(carry.take(now: 1) == 0)
  }
  for width in [63.0, 32_769, Double.greatestFiniteMagnitude] {
    sample(); sample(.right, 1, width)
    check(carry.take(now: 1) == 0)
  }
  for x in [-1.0, 100, Double.greatestFiniteMagnitude] {
    sample(); sample(.right, x)
    check(carry.take(now: 1) == 0)
  }
  sample(.right, 1, 64, -5)
  check(carry.take(now: 1) == -4)
  sample(.left, 32_766, 32_768, 5)
  check(carry.take(now: 1) == 4)
  sample(.right, 0, 100, -1, 1)
  check(carry.take(now: 1.020) == -1)
  sample(.right, 0, 100, -1, 0)
  check(carry.take(now: 0.020) == -1)
  sample(.right, 0, 100, -1, 0)
  sample(.right, 0, 100, -2, 0.019)
  check(carry.take(now: 0.021) == 0) // oldest sample cannot be revived
  return failures
}
