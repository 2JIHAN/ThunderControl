import CoreGraphics
// Historical event locations are not evidence of the current cursor position.
// No time-based grace period: unavailable, invalid or displaced live samples fail closed.
enum CursorIsolationVerdict: Equatable {case stable, unavailable, displaced}
func cursorIsolationVerdict(pin:CGPoint?,live:CGPoint?)->CursorIsolationVerdict {
  guard let pin,let live,pin.x.isFinite,pin.y.isFinite,live.x.isFinite,live.y.isFinite else{return .unavailable}
  return hypot(live.x-pin.x,live.y-pin.y)<=2 ? .stable:.displaced
}
func runCursorIsolationTests()->Int {
  var errors=0
  func expect(_ x:Bool){if !x {errors+=1}}
  let pin=CGPoint(x:100,y:200)
  expect(cursorIsolationVerdict(pin:pin,live:pin) == .stable)
  expect(cursorIsolationVerdict(pin:pin,live:CGPoint(x:102,y:200)) == .stable)
  expect(cursorIsolationVerdict(pin:pin,live:CGPoint(x:102.01,y:200)) == .displaced)
  expect(cursorIsolationVerdict(pin:pin,live:CGPoint(x:102,y:202)) == .displaced)
  expect(cursorIsolationVerdict(pin:nil,live:pin) == .unavailable)
  expect(cursorIsolationVerdict(pin:pin,live:nil) == .unavailable)
  expect(cursorIsolationVerdict(pin:CGPoint(x:Double.nan,y:0),live:pin) == .unavailable)
  expect(cursorIsolationVerdict(pin:pin,live:CGPoint(x:Double.infinity,y:0)) == .unavailable)
  // Replayed pre-handoff locations cannot affect a decision based on live position.
  let historicalSamples=[CGPoint(x:0,y:0),CGPoint(x:999,y:999),CGPoint(x:-1000,y:600)]
  for old in historicalSamples {expect(hypot(old.x-pin.x,old.y-pin.y)>2);expect(cursorIsolationVerdict(pin:pin,live:pin) == .stable)}
  expect(cursorIsolationVerdict(pin:CGPoint(x:-100,y:-200),live:CGPoint(x:-100,y:-200)) == .stable)
  expect(cursorIsolationVerdict(pin:pin,live:CGPoint(x:500,y:500)) == .displaced)
  print("CursorIsolation: live-only, tolerance, delayed-event independence, missing/nonfinite fail-closed tests failures=\(errors); memory-only")
  return errors
}
