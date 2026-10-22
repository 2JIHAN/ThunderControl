import Foundation
func runSavedSharingStateTests()->Int {
  var failures=0
  func expect(_ value:Bool){if !value{failures+=1}}
  let suite="ThunderControl.SavedSharingTests.\(UUID())"
  let d=UserDefaults(suiteName:suite)!;defer{d.removePersistentDomain(forName:suite)}
  let store=SavedSharingStateStore(defaults:d)
  let a=LayoutDevicePair(localID:UUID().uuidString,peerID:UUID().uuidString)!
  let b=LayoutDevicePair(localID:a.localID.uuidString,peerID:UUID().uuidString)!
  let defaultSender=SavedSharingState.authenticatedDefault(pair:a,inputIsSender:true)
  let defaultReceiver=SavedSharingState.authenticatedDefault(pair:a,inputIsSender:false)
  expect(defaultSender.valid && defaultSender.inputAuto && !defaultSender.inputForward)
  expect(!defaultSender.receiverConsent && defaultSender.videoEnabled && !defaultSender.videoSending)
  expect(defaultReceiver.valid && !defaultReceiver.inputAuto && !defaultReceiver.inputForward)
  expect(defaultReceiver.receiverConsent && defaultReceiver.videoEnabled && defaultReceiver.videoSending)
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
  // First authenticated intent is ON in both directions, but reconnect/relaunch
  // seeding must retain a previously explicit OFF and each peer's own record.
  expect(store.seedAuthenticatedDefaults(pair:a,inputIsSender:true) == .off(pair:a,inputIsSender:true))
  expect(store.seedAuthenticatedDefaults(pair:a,inputIsSender:false) == receiver)
  let seededSender=SavedSharingState.authenticatedDefault(pair:b,inputIsSender:true)
  let seededReceiver=SavedSharingState.authenticatedDefault(pair:b,inputIsSender:false)
  expect(store.seedAuthenticatedDefaults(pair:b,inputIsSender:true) == seededSender)
  expect(store.seedAuthenticatedDefaults(pair:b,inputIsSender:false) == seededReceiver)
  let reopened=SavedSharingStateStore(defaults:d)
  expect(reopened.seedAuthenticatedDefaults(pair:b,inputIsSender:true) == seededSender)
  var videoOff=seededReceiver;videoOff.videoEnabled=false
  expect(store.save(videoOff))
  expect(reopened.seedAuthenticatedDefaults(pair:b,inputIsSender:false) == videoOff)
  expect(store.load(pair:a,inputIsSender:true) == .off(pair:a,inputIsSender:true))
  d.set(Data("{}".utf8),forKey:SavedSharingStateStore.key)
  expect(store.load(pair:a,inputIsSender:true)==nil)
  expect(!store.isReadable);expect(!store.save(state))
  expect(store.seedAuthenticatedDefaults(pair:b,inputIsSender:true)==nil)
  expect(store.seedAuthenticatedDefaults(pair:b,inputIsSender:false)==nil)
  expect(d.data(forKey:SavedSharingStateStore.key)==Data("{}".utf8))
  d.removeObject(forKey:SavedSharingStateStore.key);expect(store.isReadable)
  print("Saved sharing state tests failures=\(failures)");return failures
}
