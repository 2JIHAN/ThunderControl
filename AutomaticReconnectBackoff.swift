// In-memory retry pacing only. No persistence, network or credential access.
struct AutomaticReconnectBackoff {
  private var step=0
  mutating func nextDelay(enabled:Bool)->Double {
    guard enabled else{reset();return 5}
    return nextDelayAndAdvance()
  }
  mutating func nextDelayAndAdvance()->Double {
    let delays:[Double]=[5,10,20,40,60]
    let delay=delays[step]
    if step<delays.count-1 {step+=1}
    return delay
  }
  mutating func reset() {step=0}
}
