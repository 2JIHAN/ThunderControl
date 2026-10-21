/// Showing receiver UI is not a request to stop or take local input ownership.
struct AppWindowPresentationPolicy {
  let sourceOwnsInput:Bool
  let receiverInputReady:Bool
  func perform(stopSource:()->Void,resetLocalIntent:()->Void) {
    if sourceOwnsInput {stopSource()}
    if !receiverInputReady {resetLocalIntent()}
  }
}
func runAppWindowPresentationPolicyTests()->Int {
  var failures=0
  for source in [false,true] {for receiver in [false,true] {
    var stops=0,resets=0
    AppWindowPresentationPolicy(sourceOwnsInput:source,receiverInputReady:receiver).perform(stopSource:{stops+=1},resetLocalIntent:{resets+=1})
    if stops != (source ? 1:0) || resets != (receiver ? 0:1) {failures+=1}
  }}
  print("App window presentation policy: receiver display preserves input; source safety retained failures=\(failures)")
  return failures
}
