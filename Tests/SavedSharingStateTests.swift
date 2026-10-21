import Foundation
func runSavedSharingStateTests()->Int {
  var failures=0
  func expect(_ value:Bool){if !value{failures+=1}}
  let suite="ThunderControl.SavedSharingTests.\(UUID())"
  let d=UserDefaults(suiteName:suite)!;defer{d.removePersistentDomain(forName:suite)}
  let store=SavedSharingStateStore(defaults:d)
  let a=LayoutDevicePair(localID:UUID().uuidString,peerID:UUID().uuidString)!
  let b=LayoutDevicePair(localID:a.localID.uuidString,peerID:UUID().uuidString)!
  let earlyVideo=SavedSharingState.firstVideo(pair:a,inputIsSender:true,auto:false,forward:false,consent:false)
  expect(earlyVideo.valid && earlyVideo.inputAuto && earlyVideo.videoEnabled)
  let manualVideo=SavedSharingState.firstVideo(pair:a,inputIsSender:true,auto:false,forward:true,consent:false)
  expect(manualVideo.valid && manualVideo.inputForward && !manualVideo.inputAuto)
  var state=SavedSharingState.off(pair:a,inputIsSender:true)
  expect(store.load(pair:a,inputIsSender:true)==nil)
  state.inputAuto=true;state.videoEnabled=true
  expect(store.save(state));expect(store.load(pair:a,inputIsSender:true)==state)
  expect(store.load(pair:b,inputIsSender:true)==nil)
  expect(store.load(pair:a,inputIsSender:false)==nil)
  var invalid=state;invalid.videoSending=true;expect(!store.save(invalid))
  invalid=state;invalid.receiverConsent=true;expect(!store.save(invalid))
  invalid=state;invalid.inputForward=true;expect(!store.save(invalid))
  let receiver=SavedSharingState.off(pair:a,inputIsSender:false)
  expect(store.save(receiver));expect(store.load(pair:a,inputIsSender:true)==state)
  expect(store.save(.off(pair:a,inputIsSender:true)))
  expect(store.load(pair:a,inputIsSender:true)?.videoEnabled==false)
  d.set(Data("{}".utf8),forKey:SavedSharingStateStore.key)
  expect(store.load(pair:a,inputIsSender:true)==nil)
  expect(!store.isReadable);expect(!store.save(state))
  expect(d.data(forKey:SavedSharingStateStore.key)==Data("{}".utf8))
  d.removeObject(forKey:SavedSharingStateStore.key);expect(store.isReadable)
  print("Saved sharing state tests failures=\(failures)");return failures
}
