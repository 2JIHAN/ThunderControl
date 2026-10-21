import CoreGraphics
func runReturnWarpResumeTests()->Int {
  var failures=0,calls:[String]=[]
  func check(_ b:Bool){if !b{failures+=1}}
  let point=CGPoint(x:12,y:34)
  let ok=warpRestoredLocalCursor(to:point,warp:{ p in check(p==point);calls.append("warp");return .success},resume:{calls.append("resume");return .success})
  check(ok == .success);check(calls==["warp","resume"])
  calls=[]
  let warpFailed=warpRestoredLocalCursor(to:point,warp:{_ in calls.append("warp");return .failure},resume:{calls.append("resume");return .success})
  check(warpFailed == .failure);check(calls==["warp"])
  calls=[]
  let resumeFailed=warpRestoredLocalCursor(to:point,warp:{_ in calls.append("warp");return .success},resume:{calls.append("resume");return .failure})
  check(resumeFailed == .failure);check(calls==["warp","resume"])
  print("Return warp resume: success ordering, warp failure and post-warp failure failures=\(failures); memory-only, no cursor or OS input")
  return failures
}
