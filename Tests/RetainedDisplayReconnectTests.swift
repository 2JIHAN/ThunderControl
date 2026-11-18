import Foundation
import CoreGraphics

func runRetainedDisplayReconnectTests()->Int {
  var failures=0
  func expect(_ value:Bool,_ name:String) {if !value {failures+=1;print("FAIL retained reconnect \(name)")}}
  let pair=LayoutDevicePair(localID:UUID().uuidString,peerID:UUID().uuidString)!
  let other=LayoutDevicePair(localID:pair.localID.uuidString,peerID:UUID().uuidString)!
  let physical=CGRect(x:0,y:0,width:1440,height:900)
  let extended=CGRect(x:1440,y:0,width:1920,height:1080)
  let original=DisplayBaseline(ids:[1],active:[1],main:1,bounds:physical,rectangles:[physical],mirrors:[0])
  let current=DisplayBaseline(ids:[1,2],active:[1,2],main:1,bounds:physical,rectangles:[physical,extended],mirrors:[0,0])
  do {
    let lease=try ConcurrentDisplayLease(original:original,current:current,ownedID:2)
    for sender in [false,true] {
      let binding=(pair:pair,inputIsSender:sender)
      expect(Relay.retainedReconnectStartAllowed(binding:binding,hasLease:!sender,hasBarrier:false,sendMode:sender,expectedPair:pair),"same peer and role may reconnect with retained screen")
      expect(!Relay.retainedReconnectStartAllowed(binding:binding,hasLease:!sender,hasBarrier:false,sendMode:!sender,expectedPair:pair),"retained role cannot change")
      expect(!Relay.retainedReconnectStartAllowed(binding:binding,hasLease:!sender,hasBarrier:false,sendMode:sender,expectedPair:other),"different expected peer cannot start")
      expect(!Relay.retainedReconnectStartAllowed(binding:binding,hasLease:!sender,hasBarrier:true,sendMode:sender,expectedPair:pair),"ordinary barrier still blocks reconnect")
      expect(Relay.retainedReconnectIdentityAllowed(pair,binding:binding,sendMode:sender),"fresh same-pair proof accepted")
      expect(!Relay.retainedReconnectIdentityAllowed(other,binding:binding,sendMode:sender),"other-pair proof rejected even without a local lease")
      expect(!Relay.retainedReconnectIdentityAllowed(pair,binding:binding,sendMode:!sender),"fresh wrong-role proof rejected")
      let relay=Relay()
      relay.retainedInputBinding={binding}
      relay.configureRetainedReconnectForTests(lease:sender ? nil:lease)
      relay.desktopBaselineReadForTests={current}
      do {
        try relay.start(name:"not-a-real-interface",peer:"",pass:"0000",port:49177,sendMode:!sender)
        expect(false,"actual start must reject retained role change")
      } catch {
        expect(!relay.hasSession && !relay.authenticated && !relay.auto && !relay.forward && !relay.inject,"rejected start never enables input")
      }
      do {
        try relay.start(name:"not-a-real-interface",peer:"",pass:"",port:49177,sendMode:sender,automaticStart:true,expectedRoutePair:other)
        expect(false,"actual start must reject retained peer change")
      } catch {
        expect(!relay.hasSession && !relay.authenticated,"wrong peer rejected before interface or authentication")
      }
      relay.configureRetainedReconnectForTests(lease:sender ? nil:lease,barrier:true)
      do {
        try relay.start(name:"not-a-real-interface",peer:"",pass:"",port:49177,sendMode:sender)
        expect(false,"actual start must reject outstanding barrier")
      } catch {expect(relay.desktopBarrierForTests != nil,"barrier is not silently cleared by start")}
    }
    let relay=Relay()
    relay.configureRetainedReconnectForTests(lease:lease)
    relay.desktopBaselineReadForTests={current}
    expect(relay.retainedDisplayLeaseValid(ownedID:2,original:original),"retained owned display matches fresh baseline and original proof")
    expect(!relay.retainedDisplayLeaseValid(ownedID:1,original:original),"another display cannot inherit ownership")
    expect(!relay.retainedDisplayLeaseValid(ownedID:2,original:current),"wrong original proof rejected")
    relay.stop()
    expect(relay.retainedDisplayLeaseValid(ownedID:2,original:original),"input stop retains same owned display lease")
    relay.desktopBaselineReadForTests={original}
    expect(!relay.retainedDisplayLeaseValid(ownedID:2,original:original),"missing owned display rejected")
  } catch {expect(false,"valid retained lease fixture")}
  expect(!Relay.retainedReconnectStartAllowed(binding:nil,hasLease:true,hasBarrier:false,sendMode:false,expectedPair:nil),"unbound retained lease never authorizes new pairing")
  expect(!Relay.retainedReconnectStartAllowed(binding:(pair:pair,inputIsSender:true),hasLease:true,hasBarrier:false,sendMode:true,expectedPair:pair),"local sender cannot adopt receiver lease")
  expect(Relay.retainedReconnectStartAllowed(binding:nil,hasLease:false,hasBarrier:false,sendMode:false,expectedPair:nil),"ordinary receiver start remains available")
  print("Retained display reconnect failures=\(failures); rejected starts use invalid interface without network or input activation")
  return failures
}
