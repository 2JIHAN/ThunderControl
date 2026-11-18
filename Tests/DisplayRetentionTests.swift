import Foundation

@MainActor func runDisplayRetentionTests()->Int {
  var valid=DisplayModeController.verifyRetentionLifecycleForTests()
  let progress=DisplayConnectionWarningProgress(startedAt: 100)
  let cases: [(Double, Int, Bool)] = [
    (0, 1, false), (0.499, 1, false), (0.5, 2, false),
    (0.999, 2, false), (1, 3, false), (1.499, 3, false),
    (1.5, 1, false), (2.5, 3, false), (4.999, 1, false),
    (5, 2, true), (5.001, 2, true), (9.999, 2, true),
    (10, 3, true), (10.001, 3, true)
  ]
  for (elapsed, dots, canClose) in cases {
    valid = (progress.dots(at: 100 + elapsed) == dots) && valid
    valid = (progress.canClose(at: 100 + elapsed) == canClose) && valid
  }
  for now in [99.0, Double.nan, Double.infinity, -Double.infinity] {
    valid = (progress.dots(at: now) == 1) && valid
    valid = !progress.canClose(at: now) && valid
  }
  for start in [Double.nan, Double.infinity, -Double.infinity] {
    let invalid=DisplayConnectionWarningProgress(startedAt: start)
    valid = (invalid.dots(at: 100) == 1) && valid
    valid = !invalid.canClose(at: 100) && valid
  }
  let overflow=DisplayConnectionWarningProgress(startedAt: -Double.greatestFiniteMagnitude)
  valid = (overflow.dots(at: Double.greatestFiniteMagnitude) == 1) && valid
  valid = !overflow.canClose(at: Double.greatestFiniteMagnitude) && valid
  print("\(valid ? "PASS":"FAIL") retained display lifecycle")
  return valid ? 0:1
}
