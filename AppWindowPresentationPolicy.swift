/// Showing receiver UI is not a request to stop or take local input ownership.
struct AppWindowPresentationPolicy {
  let sourceOwnsInput:Bool
  let receiverInputReady:Bool
  func perform(pauseSource:()->Void,resetLocalIntent:()->Void) {
    if sourceOwnsInput {pauseSource()}
    if !receiverInputReady {resetLocalIntent()}
  }
}
func runAppWindowPresentationPolicyTests()->Int {
  var failures=0
  for source in [false,true] {for receiver in [false,true] {
    var pauses=0,resets=0
    AppWindowPresentationPolicy(sourceOwnsInput:source,receiverInputReady:receiver).perform(pauseSource:{pauses+=1},resetLocalIntent:{resets+=1})
    if pauses != (source ? 1:0) || resets != (receiver ? 0:1) {failures+=1}
  }}
  print("App window presentation policy: receiver display preserves input; source input pauses without transport teardown failures=\(failures)")
  return failures
}
