import CoreGraphics
func automaticConnectionMayStart(configured:Bool,paused:Bool,suspended:Bool,permissions:Bool,sessionSafe:Bool,recovery:Bool,hasSession:Bool)->Bool {
  configured && !paused && !suspended && permissions && sessionSafe && !recovery && !hasSession
}
func runAutomaticConnectionPolicyTests()->Int {
  var failed=0
  func check(_ x:Bool){if !x {failed+=1}}
  for mask in 0..<128 {
    let result=automaticConnectionMayStart(configured:mask&1 != 0,paused:mask&2 != 0,suspended:mask&4 != 0,permissions:mask&8 != 0,sessionSafe:mask&16 != 0,recovery:mask&32 != 0,hasSession:mask&64 != 0)
    check(result == (mask==25))
  }
  let relay=Relay()
  if let stop=CGEvent(keyboardEventSource:nil,virtualKey:53,keyDown:true) {
    stop.flags=[.maskControl,.maskAlternate]
    _ = relay.handle(.keyDown,stop)
    check(relay.automaticReconnectSuspended && !relay.hasSession)
    for _ in 0..<5 {check(!automaticConnectionMayStart(configured:true,paused:false,suspended:relay.automaticReconnectSuspended,permissions:true,sessionSafe:true,recovery:false,hasSession:false))}
  } else {failed+=1}
  print("AutoConnection 128 guard combinations and emergency-stop latch failures=\(failed); no input posting/network")
  return failed
}
