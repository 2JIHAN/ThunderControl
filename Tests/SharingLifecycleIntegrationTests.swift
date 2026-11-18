import Foundation
import AppKit
import CryptoKit

@MainActor func runSharingLifecycleIntegrationTests()->Int {
  var checks=0,failures=0
  func expect(_ value:Bool,_ name:String){checks+=1;if !value {failures+=1;print("FAIL sharing lifecycle \(name)")}}
  let suite="ThunderControl.SharingLifecycleTests."+UUID().uuidString
  let defaults=UserDefaults(suiteName:suite)!
  defer{defaults.removePersistentDomain(forName:suite)}
  let store=SavedSharingStateStore(defaults:defaults)
  let pair=LayoutDevicePair(localID:UUID().uuidString,peerID:UUID().uuidString)!
  let other=LayoutDevicePair(localID:pair.localID.uuidString,peerID:UUID().uuidString)!
  for sender in [false,true] {
    let relay=Relay(),app=App(relay:relay,sharingStore:store)
    relay.senderForTests=sender
    // Actual role-change preparation never writes OFF or clears a user safety stop.
    let original=SavedSharingState.authenticatedDefault(pair:pair,inputIsSender:sender)
    expect(store.save(original),"save initial")
    app.sharingPrepareRoleChange();app.tearDownConnection(userStop:false,updateUI:false)
    expect(store.load(pair:pair,inputIsSender:sender)==original,"role preparation preserves intent")
    expect(!app.sharingInputRestoreBlocked && !app.sharingResume.blocked,"normal role change no stop latch")
    app.sharingUserStoppedAll(reason:sender ? .uiStop:.emergencyStop)
    expect(app.sharingInputRestoreBlocked && app.sharingResume.blocked,"actual explicit stop latches")
    app.sharingPrepareRoleChange();app.tearDownConnection(userStop:false,updateUI:false)
    expect(app.sharingInputRestoreBlocked && app.sharingResume.blocked,"role change cannot bypass stop")
    // Existing0.8.28 all-OFF records are not migrated automatically.
    expect(store.save(.off(pair:pair,inputIsSender:sender)),"save old OFF")
    app.sharingDidStartExplicitConnection(sending:sender)
    expect(!app.sharingApplyExplicitConnectIntent(pair:pair,sender:sender),"cannot resume unauthenticated pair")
    relay.connectionForTests=OwnedSocket(-1);relay.keyForTests=SymmetricKey(size:.bits256)
    relay.sharingLifecyclePairForTests=pair
    expect(!app.sharingApplyExplicitConnectIntent(pair:other,sender:sender),"cannot resume unrelated pair")
    expect(!app.sharingApplyExplicitConnectIntent(pair:pair,sender:!sender),"cannot resume wrong role")
    expect(app.sharingApplyExplicitConnectIntent(pair:pair,sender:sender),"explicit authenticated Connect resumes")
    let resumed=store.load(pair:pair,inputIsSender:sender)!
    expect(resumed.inputAuto==sender && resumed.receiverConsent == !sender,"restores correct input role")
    expect(!resumed.videoEnabled && !resumed.inputForward,"does not resurrect videoOFF or manual mirror")
    expect(!app.sharingInputRestoreBlocked && !app.sharingResume.blocked,"explicit resume clears latches")
    expect(!app.sharingApplyExplicitConnectIntent(pair:pair,sender:sender),"resume consumed once")
    app.sharingDidStartExplicitConnection(sending:sender);app.sharingPrepareRoleChange()
    expect(!app.sharingApplyExplicitConnectIntent(pair:pair,sender:sender),"role switch invalidates pending Connect")
    app.sharingDidStartExplicitConnection(sending:sender)
    relay.stop()
    relay.senderForTests=sender;relay.connectionForTests=OwnedSocket(-1);relay.keyForTests=SymmetricKey(size:.bits256);relay.sharingLifecyclePairForTests=pair
    expect(!app.sharingApplyExplicitConnectIntent(pair:pair,sender:sender),"stale Connect generation cannot resume fresh authenticated session")
    // Drive actual packet dispatch branch, not just Boolean policy.
    relay.sharingLifecycleCapabilityForTests=true
    if !sender {
      var requests:[Bool]=[];relay.displayPreferenceChanged={requests.append($0)}
      relay.receiveControlForTests(Wire(kind:"displayPreference",session:"fixture",sequence:1,displayPreference:true))
      relay.receiveControlForTests(Wire(kind:"displayPreference",session:"fixture",sequence:2,displayPreference:false))
      expect(requests==[true,false] && relay.peerDisplayPreference==false,"actual preference receive callbacks")
      relay.sharingLifecycleCapabilityForTests=false
      relay.receiveControlForTests(Wire(kind:"displayPreference",session:"fixture",sequence:3,displayPreference:true))
      expect(requests==[true,false],"legacy capability rejects preference")
    } else {
      relay.receiveControlForTests(Wire(kind:"available",session:"fixture",sequence:1,width:1))
      expect(relay.sharingReadinessSummary.contains("receiverAvailable=true"),"actual available updates readiness")
      expect(!relay.auto,"missing geometry never auto arms")
    }
  }
  for sender in [false,true] {
    let relay=Relay(),app=App(relay:relay,sharingStore:store)
    relay.senderForTests=sender;relay.safetyObserversInstalled=true
    relay.sessionSnapshotReadForTests={SessionSafetySnapshot(onConsole:true,loginDone:true,screenLocked:false)}
    relay.desktopInputPermissionForTests={true}
    let stopped=SavedSharingState.off(pair:pair,inputIsSender:sender)
    expect(store.save(stopped),"deferred fixture saves OFF")
    app.sharingInputRestoreBlocked=true;app.sharingResume.manualStop()
    app.sharingDeferExplicitConnection(pair:pair,sender:sender)
    expect(store.load(pair:pair,inputIsSender:sender)==stopped,"defer never saves before authentication")
    expect(!app.sharingApplyExplicitConnectIntent(pair:pair,sender:sender),"deferred rejects unauthenticated peer")
    expect(app.sharingDeferredExplicitResume != nil && app.sharingExplicitResumePending==nil,"unauthenticated deferred remains unpromoted")
    relay.connectionForTests=OwnedSocket(-1);relay.keyForTests=SymmetricKey(size:.bits256)
    relay.sharingLifecyclePairForTests=other
    expect(!app.sharingApplyExplicitConnectIntent(pair:other,sender:sender),"deferred rejects authenticated wrong pair")
    relay.sharingLifecyclePairForTests=pair;relay.senderForTests = !sender
    expect(!app.sharingApplyExplicitConnectIntent(pair:pair,sender:!sender),"deferred rejects authenticated wrong role")
    relay.senderForTests=sender
    app.automaticConnectionPaused=true
    expect(!app.sharingApplyExplicitConnectIntent(pair:pair,sender:sender),"deferred direct call respects paused safety gate")
    app.automaticConnectionPaused=false;relay.automaticReconnectSuspended=true
    expect(!app.sharingApplyExplicitConnectIntent(pair:pair,sender:sender),"deferred direct call respects security suspension")
    relay.automaticReconnectSuspended=false;relay.desktopInputPermissionForTests={false}
    expect(!app.sharingApplyExplicitConnectIntent(pair:pair,sender:sender),"deferred direct call respects input permission gate")
    relay.desktopInputPermissionForTests={true};relay.sessionLockedSignal=true
    expect(!app.sharingApplyExplicitConnectIntent(pair:pair,sender:sender),"deferred direct call respects locked session")
    relay.sessionLockedSignal=false
    expect(app.sharingDeferredExplicitResume != nil && app.sharingExplicitResumePending==nil,"safety gates do not consume deferred intent")
    expect(store.load(pair:pair,inputIsSender:sender)==stopped && app.sharingInputRestoreBlocked && app.sharingResume.blocked,"rejected deferred preserves saved OFF and stop latches")
    let savedRecords=defaults.data(forKey:SavedSharingStateStore.key)!
    defaults.set(Data(),forKey:SavedSharingStateStore.key)
    expect(!app.sharingApplyExplicitConnectIntent(pair:pair,sender:sender),"deferred promotion cannot overwrite unreadable storage")
    expect(app.sharingDeferredExplicitResume==nil && app.sharingExplicitResumePending?.generation==relay.generation && app.sharingExplicitResumePending?.sender==sender,"deferred promotion creates current generation token before save")
    defaults.set(savedRecords,forKey:SavedSharingStateStore.key)
    expect(app.sharingApplyExplicitConnectIntent(pair:pair,sender:sender),"matching safe authentication promotes and saves deferred intent")
    let resumed=store.load(pair:pair,inputIsSender:sender)!
    expect(resumed.inputAuto==sender && resumed.receiverConsent == !sender && !resumed.inputForward && !resumed.videoEnabled,"deferred restores input role but preserves video OFF")
    expect(app.sharingDeferredExplicitResume==nil && app.sharingExplicitResumePending==nil && !app.sharingInputRestoreBlocked && !app.sharingResume.blocked,"deferred promotion consumed once and clears stop latches")
    expect(!app.sharingApplyExplicitConnectIntent(pair:pair,sender:sender),"consumed deferred cannot replay")
    for reason in [SharingStopReason.uiStop,.emergencyStop] {
      app.sharingDeferExplicitConnection(pair:pair,sender:sender)
      app.sharingUserStoppedAll(reason:reason)
      expect(app.sharingDeferredExplicitResume==nil && !app.sharingApplyExplicitConnectIntent(pair:pair,sender:sender),"Stop invalidates deferred intent \(reason.rawValue)")
      expect(store.load(pair:pair,inputIsSender:sender)==stopped,"Stop after defer persists OFF \(reason.rawValue)")
    }
    app.sharingDeferExplicitConnection(pair:pair,sender:sender);app.sharingPrepareRoleChange()
    expect(app.sharingDeferredExplicitResume==nil && !app.sharingApplyExplicitConnectIntent(pair:pair,sender:sender),"role change invalidates deferred intent")
    app.sharingDeferExplicitConnection(pair:pair,sender:sender);app.sharingDidStartExplicitConnection(sending:sender)
    expect(app.sharingDeferredExplicitResume==nil,"normal explicit start replaces deferred intent")
    relay.stop();relay.senderForTests=sender
    relay.connectionForTests=OwnedSocket(-1);relay.keyForTests=SymmetricKey(size:.bits256);relay.sharingLifecyclePairForTests=pair
    expect(!app.sharingApplyExplicitConnectIntent(pair:pair,sender:sender),"replaced deferred cannot revive stale generation token")
    expect(store.load(pair:pair,inputIsSender:sender)==stopped,"stale generation preserves saved OFF")
  }
  let freshPair=LayoutDevicePair(localID:UUID().uuidString,peerID:UUID().uuidString)!
  let freshRelay=Relay(),freshApp=App(relay:freshRelay,sharingStore:store)
  freshRelay.senderForTests=true;freshRelay.connectionForTests=OwnedSocket(-1);freshRelay.keyForTests=SymmetricKey(size:.bits256);freshRelay.sharingLifecyclePairForTests=freshPair
  defaults.set(false,forKey:"fixture.videoPreferred")
  freshApp.sharingNewPairVideoPreference={defaults.object(forKey:"fixture.videoPreferred") as? Bool}
  freshApp.sharingDidStartExplicitConnection(sending:true)
  expect(freshApp.sharingApplyExplicitConnectIntent(pair:freshPair,sender:true),"absent pair authenticated Connect")
  expect(store.load(pair:freshPair,inputIsSender:true)?.videoEnabled==false,"absent pair honors device videoOFF")
  expect(store.load(pair:freshPair,inputIsSender:true)?.inputAuto==true,"device videoOFF independent of explicit input resume")
  defaults.set(true,forKey:"fixture.videoPreferred")
  freshApp.sharingDidStartExplicitConnection(sending:true)
  expect(freshApp.sharingApplyExplicitConnectIntent(pair:freshPair,sender:true),"existing pair authenticated Connect")
  expect(store.load(pair:freshPair,inputIsSender:true)?.videoEnabled==false,"globalON never overwrites saved pairOFF")
  let relay=Relay(),app=App(relay:relay,sharingStore:store)
  app.discoveredPeers=[BridgePeer(id:"one",name:"test",ipv4:"169.254.1.2",port:49177)]
  app.peerPicker.addItem(withTitle:"test");app.peerPicker.selectItem(at:0)
  app.peer.stringValue="169.254.1.2";app.displayPreferencePending=true
  app.syncSelectedPeerAddress()
  expect(app.displayPreferencePending==true,"start address preparation preserves explicit checkbox")
  app.peerSelected();expect(app.displayPreferencePending==true,"same peer refresh preserves checkbox")
  app.peer.stringValue="169.254.1.3";app.peerSelected()
  expect(app.displayPreferencePending==nil,"different peer selection drops stale pending checkbox")
  print("Sharing lifecycle App/Relay integration: \(checks) checks, \(failures) failures; no network/event/cursor/display effects")
  return failures
}
