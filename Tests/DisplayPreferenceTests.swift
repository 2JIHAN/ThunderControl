import Foundation
func runDisplayPreferenceTests()->Int {
  var failures=0,checks=0
  func expect(_ v:Bool){checks+=1;if !v{failures+=1}}
  let id=UUID().uuidString
  let a=LayoutDevicePair(localID:UUID().uuidString,peerID:UUID().uuidString)!
  let b=LayoutDevicePair(localID:a.localID.uuidString,peerID:UUID().uuidString)!
  expect(DisplayPreferencePolicy.pendingApplies(expected:nil,current:a))
  expect(DisplayPreferencePolicy.pendingApplies(expected:a,current:a))
  expect(!DisplayPreferencePolicy.pendingApplies(expected:a,current:b))
  expect(DisplayPreferencePolicy.senderControlVisible(selectedRole:0))
  expect(!DisplayPreferencePolicy.senderControlVisible(selectedRole:1))
  expect(!DisplayPreferencePolicy.senderControlVisible(selectedRole:-1))
  let frame=Wire(kind:"displayPreference",session:id,sequence:1,displayPreference:true)
  expect(DisplayPreferencePolicy.validEnvelope(frame))
  var off=frame;off.displayPreference=false;expect(DisplayPreferencePolicy.validEnvelope(off))
  var missing=frame;missing.displayPreference=nil;expect(!DisplayPreferencePolicy.validEnvelope(missing))
  var bad=frame;bad.x=0;expect(!DisplayPreferencePolicy.validEnvelope(bad))
  bad=frame;bad.token=UUID().uuidString;expect(!DisplayPreferencePolicy.validEnvelope(bad))
  bad=frame;bad.displayPreferenceCodec=1;expect(!DisplayPreferencePolicy.validEnvelope(bad))
  for sender in [false,true] {for compatible in [false,true] {for local in [false,true] {for remote:Bool? in [nil,false,true] {
    expect(DisplayPreferencePolicy.canStart(inputIsSender:sender,compatible:compatible,localIntent:local,remoteIntent:remote)==(compatible && (sender ? local:remote==true)))
  }}}}
  func accepted(_ w:Wire,_ sender:Bool,_ capability:Bool)->Bool {
    var validator=PeerValidator(senderPeer:sender,session:id,displayPreferenceSupported:capability)
    return (try? validator.accept(w)) != nil
  }
  expect(accepted(frame,true,true));expect(accepted(off,true,true))
  expect(!accepted(frame,false,true));expect(!accepted(frame,true,false));expect(!accepted(bad,true,true))
  var replay=PeerValidator(senderPeer:true,session:id,displayPreferenceSupported:true)
  expect((try? replay.accept(frame)) != nil);expect((try? replay.accept(frame)) == nil)
  var wrong=frame;wrong.session=UUID().uuidString;expect(!accepted(wrong,true,true))
  var reducer=AutomaticSharingResume();reducer.bind(.init(pair:a,inputIsSender:false,host:"169.254.1.2"))
  var staleOff=SavedSharingState.off(pair:a,inputIsSender:false)
  // Effective remote ON can override stale receiver OFF, but never a safety latch or cleanup.
  staleOff.videoEnabled=DisplayPreferencePolicy.canStart(inputIsSender:false,compatible:true,localIntent:false,remoteIntent:true)
  expect(!reducer.shouldStart(now:0,intent:staleOff,safe:true,active:false,cleaning:true))
  expect(reducer.shouldStart(now:0,intent:staleOff,safe:true,active:false,cleaning:false))
  reducer.manualStop();expect(!reducer.shouldStart(now:100,intent:staleOff,safe:true,active:false,cleaning:false))
  reducer.bind(nil);reducer.bind(.init(pair:a,inputIsSender:false,host:"169.254.1.3"))
  expect(!reducer.shouldStart(now:200,intent:staleOff,safe:true,active:false,cleaning:false))
  print("Display preference protocol/policy tests checks=\(checks) failures=\(failures)")
  return failures
}
