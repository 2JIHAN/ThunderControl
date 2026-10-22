import Foundation
func runAutomaticSharingResumeTests()->Int {
  var failures=0
  func expect(_ value:Bool){if !value{failures+=1}}
  let pair=LayoutDevicePair(localID:UUID().uuidString,peerID:UUID().uuidString)!
  let binding=AutomaticSharingResume.Binding(pair:pair,inputIsSender:false,host:"169.254.1.2")
  var state=SavedSharingState.off(pair:pair,inputIsSender:false);state.videoEnabled=true
  var reducer=AutomaticSharingResume();reducer.bind(binding)
  func tick(_ time:Double,_ safe:Bool=true,_ active:Bool=false,_ cleaning:Bool=false)->Bool {
    reducer.shouldStart(now:time,intent:state,safe:safe,active:active,cleaning:cleaning)
  }
  expect(!tick(0,false));expect(!tick(0,true,true));expect(!tick(0,true,false,true));expect(reducer.attempts==0)
  for time:Double in [0,1,3,7,15,30] {expect(tick(time));expect(!tick(time))}
  expect(tick(100));expect(reducer.attempts==6)
  reducer.bind(binding);expect(!tick(101));expect(tick(115)) // Duplicate callbacks never reset the capped backoff.
  expect(!tick(.infinity));expect(!tick(.nan))
  reducer.bind(nil);expect(!tick(201)) // Stale completion has no live binding.
  reducer.bind(binding);expect(tick(202)) // Normal disconnect preserves ON intent.
  reducer.manualStop();expect(!tick(300)) // Emergency/manual-off epoch blocked.
  reducer.bind(nil);reducer.bind(binding);expect(!tick(400))
  reducer.manualResume();state.videoEnabled=false;expect(!tick(500))
  state.videoEnabled=true;expect(tick(501))
  let wrong=LayoutDevicePair(localID:pair.localID.uuidString,peerID:UUID().uuidString)!
  reducer.bind(.init(pair:wrong,inputIsSender:false,host:"169.254.1.2"));expect(!tick(600))
  reducer.bind(.init(pair:pair,inputIsSender:true,host:"169.254.1.2"));expect(!tick(601))
  // Source and receiver INPUT OFF are independent from video intent.
  reducer.bind(binding);reducer.manualResume();expect(!state.receiverConsent && tick(700))
  let copy=state;reducer.bind(nil);expect(state==copy) // Quit/disconnect never writes OFF.
  // Observer order: sync metadata capture of B, then queued disconnect, then
  // deferred activation. Disconnected Stop must address B, never old pair A.
  let pairB=LayoutDevicePair(localID:pair.localID.uuidString,peerID:UUID().uuidString)!
  let bindingB=AutomaticSharingResume.Binding(pair:pairB,inputIsSender:false,host:"169.254.1.3")
  reducer.bind(binding);reducer.bind(bindingB);reducer.bind(nil)
  expect(reducer.lastBinding==bindingB && reducer.binding==nil)
  // First authenticated defaults require no manual video button on either Mac.
  // Ordinary disconnect and repeated cleanup preserve intent; user OFF and the
  // emergency/manual stop latch remain authoritative through route rebinding.
  for sender in [false,true] {
    let live=AutomaticSharingResume.Binding(pair:pair,inputIsSender:sender,host:"169.254.1.2")
    var initial=SavedSharingState.authenticatedDefault(pair:pair,inputIsSender:sender)
    var alwaysOn=AutomaticSharingResume();alwaysOn.bind(live)
    func restore(_ time:Double,_ safe:Bool=true,_ active:Bool=false,_ cleaning:Bool=false)->Bool {
      alwaysOn.shouldStart(now:time,intent:initial,safe:safe,active:active,cleaning:cleaning)
    }
    expect(!restore(0,false));expect(!restore(0,true,true));expect(!restore(0,true,false,true))
    expect(restore(0))
    alwaysOn.bind(nil);expect(!restore(1))
    alwaysOn.bind(live);expect(restore(2))
    alwaysOn.manualStop();alwaysOn.bind(nil);alwaysOn.bind(live)
    expect(!restore(100))
    alwaysOn.manualResume();expect(restore(101))
    initial.videoEnabled=false
    alwaysOn.bind(nil);alwaysOn.bind(live);expect(!restore(200))
    // Rebinding to an address is never sufficient to start a different peer.
    alwaysOn.bind(.init(pair:pairB,inputIsSender:sender,host:"169.254.1.2"))
    initial.videoEnabled=true;expect(!restore(300))
  }
  print("Automatic sharing resume reducer tests failures=\(failures)");return failures
}
