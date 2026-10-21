func runAutomaticReconnectBackoffTests()->Int {
  var failed=0
  func check(_ condition:Bool){if !condition {failed+=1}}
  var backoff=AutomaticReconnectBackoff()
  for expected:Double in [5,10,20,40,60,60,60] {check(backoff.nextDelayAndAdvance()==expected)}
  for _ in 0..<1000 {check(backoff.nextDelayAndAdvance()==60)}
  backoff.reset();check(backoff.nextDelayAndAdvance()==5)
  check(backoff.nextDelayAndAdvance()==10)
  backoff.reset();backoff.reset();check(backoff.nextDelayAndAdvance()==5)
  // A copied schedule is independent, allowing each App to own its retry state.
  var independent=AutomaticReconnectBackoff()
  check(independent.nextDelayAndAdvance()==5)
  check(backoff.nextDelayAndAdvance()==10)
  print("Automatic reconnect backoff memory tests failures=\(failed); delays 5/10/20/40/60, reset and cap")
  return failed
}
