import AppKit
import CoreGraphics
import CryptoKit

// Synthetic fixtures are memory-only classifier inputs. They have no HID queue
// payload and do NOT establish that native injection or system gestures work.
func runNativeGestureTests() -> Int {
  var failures = 0
  var checks = 0
  func check(_ value: Bool, _ label: String) {
    checks += 1
    if !value { failures += 1; print("NativeGesture FAIL: \(label)") }
  }
  func descriptor(_ kind: NativeGestureDescriptor.Kind,
                  _ phase: NativeGestureDescriptor.Phase) -> NativeGestureDescriptor {
    NativeGestureDescriptor(kind: kind, phase: phase)
  }
  func fixture(_ subtype: Int64, _ phase: Int64, outer: UInt32 = 29,
               scalar: Double = 0, direction: Int64 = 1) -> CGEvent {
    let event = CGEvent(source: nil)!
    event.type = CGEventType(rawValue: outer)!
    event.setIntegerValueField(CGEventField(rawValue: 110)!, value: subtype)
    event.setIntegerValueField(CGEventField(rawValue: 132)!, value: phase)
    if subtype == 16 {
      event.setIntegerValueField(CGEventField(rawValue: 115)!, value: direction)
    } else if subtype == 8 || subtype == 5 {
      event.setDoubleValueField(CGEventField(rawValue: 113)!, value: scalar)
    }
    return event
  }
  for outer: UInt32 in [29, 30] {
    for (subtype, kind): (Int64, NativeGestureDescriptor.Kind) in [(8,.pinch),(5,.rotate),(16,.swipe)] {
      for (raw, phase): (Int64, NativeGestureDescriptor.Phase) in
        [(1,.began),(2,.changed),(4,.ended),(8,.cancelled),(128,.mayBegin)] {
        let expected: NativeGestureDescriptor? = outer == 30 && subtype != 8 ? nil : descriptor(kind, phase)
        check(NativeGestureDescriptor.decode(fixture(subtype, raw, outer: outer)) == expected, "kind/phase \(outer) \(subtype) \(raw)")
      }
    }
    check(NativeGestureDescriptor.decode(fixture(22, 0, outer: outer)) == (outer == 29 ? descriptor(.smartMagnify,.none) : nil), "smart atomic/mismatched public kind")
    check(NativeGestureDescriptor.decode(fixture(23, 1, outer: outer)) == nil, "contact excluded")
  }
  check(NativeGestureDescriptor.decode(fixture(8, 1, outer: 1)) == nil, "outer type rejected")
  check(NativeGestureDescriptor.decode(fixture(99, 1)) == nil, "unknown subtype")
  for raw: Int64 in [0,3,16,64] {
    check(NativeGestureDescriptor.decode(fixture(8, raw)) == nil, "unsupported pinch phase")
  }
  check(NativeGestureDescriptor.decode(fixture(22, 1)) == nil, "smart not stream")
  for scalar in [Double.nan, Double.infinity, -Double.infinity, 4.1, -4.1] {
    check(NativeGestureDescriptor.decode(fixture(8, 2, scalar: scalar)) == nil, "bad magnify scalar")
  }
  for scalar in [Double.nan, Double.infinity, 361, -361] {
    check(NativeGestureDescriptor.decode(fixture(5, 2, scalar: scalar)) == nil, "bad rotation scalar")
  }
  check(NativeGestureDescriptor.decode(fixture(8, 2, scalar: -4)) != nil, "magnify boundary")
  check(NativeGestureDescriptor.decode(fixture(5, 2, scalar: 360)) != nil, "rotation boundary")
  for direction: Int64 in [1,2,4,8] {
    check(NativeGestureDescriptor.decode(fixture(16, 0, direction: direction)) == descriptor(.swipe,.none), "atomic swipe direction")
  }
  for direction: Int64 in [0,3,16,-1] {
    check(NativeGestureDescriptor.decode(fixture(16, 0, direction: direction)) == nil, "invalid swipe direction")
  }
  let begin = descriptor(.pinch,.began), change = descriptor(.pinch,.changed)
  let end = descriptor(.pinch,.ended), may = descriptor(.pinch,.mayBegin)
  let rotate = descriptor(.rotate,.began), rotateEnd = descriptor(.rotate,.cancelled)
  let atomic = descriptor(.smartMagnify,.none)
  do {
    let data = try JSONEncoder().encode(begin)
    check(try JSONDecoder().decode(NativeGestureDescriptor.self, from: data) == begin, "descriptor codec")
    check((try? JSONDecoder().decode(NativeGestureDescriptor.self, from: Data("{\"kind\":\"unknown\",\"phase\":\"began\"}".utf8))) == nil, "codec unknown enum")
    let original = fixture(8, 1, scalar: 0.25)
    let before = original.data!
    _ = NativeGestureDescriptor.decode(original)
    check((original.data! as Data) == (before as Data), "classifier preserves original")
    check(CGEvent(withDataAllocator: nil, data: before).flatMap { NativeGestureDescriptor.decode($0) } == begin, "CG data codec")
  } catch { check(false, "codec error \(error)") }
  var source = SourceGestureState()
  check(!source.blockAuto, "initial clean")
  let start = source.route(may, remote: true, now: 0)
  check(start.forward && start.suppress && start.id != nil, "mayBegin ID")
  check(!source.route(change, remote: true, now: 1).forward, "changed before began rejected")
  check(source.route(begin, remote: true, now: 2).id == start.id, "mayBegin to began")
  check(!source.route(begin, remote: true, now: 3).forward, "duplicate begin")
  check(source.route(change, remote: true, now: 4).id == start.id, "changed stable ID")
  let second = source.route(rotate, remote: true, now: 5)
  check(second.forward && second.id != start.id, "mixed pinch rotate")
  check(!source.expired(now: 29) && source.expired(now: 30), "absolute stream timeout")
  check(source.route(end, remote: true, now: 31).forward && source.remoteActive, "one terminal preserves overlap")
  check(source.route(rotateEnd, remote: true, now: 32).forward && !source.remoteActive, "cancel clears")
  _ = source.route(begin, remote: false, now: 40)
  check(source.localActive && source.blockAuto, "local blocks auto")
  check(!source.route(change, remote: true, now: 41).forward, "no local transfer")
  check(!source.route(end, remote: true, now: 42).suppress && !source.localActive, "local finish passes")
  _ = source.route(begin, remote: true, now: 50)
  _ = source.route(rotate, remote: true, now: 50)
  _ = source.route(descriptor(.swipe,.began), remote: true, now: 50)
  check(source.remoteActive, "three semantic streams")
  source.forceLocal()
  check(source.hasOrphans && !source.remoteActive && source.blockAuto, "force quarantine")
  source.reset()
  check(source.hasOrphans, "reset preserves quarantine")
  check(source.route(change, remote: false, now: 500).suppress, "orphan no remote context")
  check(source.route(begin, remote: true, now: 501).suppress && !source.remoteActive, "no held restart")
  _ = source.expired(now: 1000)
  check(source.hasOrphans, "timeout never releases orphans")
  check(source.route(end, remote: false, now: 1001).suppress, "terminal suppressed")
  check(source.hasOrphans, "other orphan kinds retained")
  _ = source.route(rotateEnd, remote: false, now: 1002)
  _ = source.route(descriptor(.swipe,.ended), remote: false, now: 1002)
  check(!source.hasOrphans, "all lifted")
  check(!source.route(change, remote: true, now: 1003).forward && source.hasOrphans, "unknown changed quarantined")
  source.clearOrphans()
  check(!source.hasOrphans, "explicit orphan recovery")
  let a = source.route(atomic, remote: true, now: 1004)
  let b = source.route(atomic, remote: true, now: 1005)
  check(a.forward && b.forward && a.id != b.id && !source.remoteActive, "atomic fresh IDs no state")
  check(!source.route(begin, remote: true, now: .nan).forward, "invalid clock")
  var receiver = ReceiverGestureState()
  let id = UUID().uuidString, other = UUID().uuidString
  check(!receiver.accept(change, id: id, now: 0), "receiver unknown changed")
  check(!receiver.accept(begin, id: "not-a-uuid", now: 0), "receiver malformed UUID")
  check(!receiver.accept(begin, id: id.lowercased(), now: 0), "receiver noncanonical UUID")
  check(receiver.accept(may, id: id, now: 0), "receiver mayBegin")
  check(!receiver.accept(change, id: id, now: 1), "receiver changed before began")
  check(receiver.accept(begin, id: id, now: 1), "receiver begin")
  check(!receiver.accept(begin, id: id, now: 1), "receiver duplicate begin")
  check(!receiver.accept(change, id: other, now: 2), "receiver wrong changed ID")
  check(!receiver.accept(end, id: other, now: 2), "receiver wrong terminal ID")
  check(!receiver.accept(rotate, id: id, now: 2), "receiver crosskind ID collision")
  check(receiver.accept(rotate, id: other, now: 2), "receiver overlap")
  check(receiver.accept(change, id: id, now: 3), "receiver ordered changed")
  check(!receiver.expired(now: 29) && receiver.expired(now: 30), "receiver deadline")
  check(receiver.accept(end, id: id, now: 31) && receiver.active, "receiver one end")
  check(receiver.accept(rotateEnd, id: other, now: 31) && !receiver.active, "receiver cancel")
  check(receiver.accept(atomic, id: id, now: 32) && !receiver.active, "receiver atomic no lingering")
  check(!receiver.accept(descriptor(.pinch,.none), id: id, now: 33), "receiver invalid semantic pair")
  _ = receiver.accept(begin, id: id, now: 34)
  receiver.reset()
  check(!receiver.active && !receiver.accept(change, id: id, now: 35), "receiver reset")
  let map=ReceiverDesktop(revision:7,mainID:11,displays:[
    ReceiverDisplay(id:11,bounds:CGRect(x:0,y:0,width:1920,height:1080)),
    ReceiverDisplay(id:99,bounds:CGRect(x:-1512,y:-945,width:1512,height:945))],virtualDisplayID:99)
  let point=CGPoint(x:-400,y:-300),token=UUID().uuidString,session=UUID().uuidString
  func packet(_ phase:Int64,_ scalar:Double,_ stream:String)->Wire {
    let event=fixture(8,phase,scalar:scalar)
    var w=Wire(kind:"appGesture",session:session,sequence:1,raw:29,data:event.data! as Data,token:token,
      appGesture:NativeGestureDescriptor.decode(event),appGestureID:stream,appGestureCodec:1)
    w.desktopMapRevision=7;w.desktopGlobalX=Double(point.x);w.desktopGlobalY=Double(point.y);w.desktopGestureTargetID=99
    return w
  }
  let r=Relay()
  r.connectionForTests=OwnedSocket(-1);r.contextForTests=SessionContext(OwnedSocket(-1));r.keyForTests=SymmetricKey(size:.bits256)
  r.safetyObserversInstalled=true;r.desktopEnqueueForTests={_ in true};r.gestureTrace.setEnabled(false)
  var epoch:UInt64=0,posts=[CGEvent]()
  r.desktopEpochForTests={epoch};r.desktopMapReadForTests={_,_ in map}
  r.appGesturePermissionForTests={true};r.appGesturePostForTests={posts.append($0)}
  for scalar in [0.25,-0.25] {
    r.prepareDesktopAppGestureForTests(map:map,point:point,token:token)
    let stream=UUID().uuidString,before=posts.count
    for phase:Int64 in [128,1,2,4] {r.receive(packet(phase,scalar,stream))}
    check(posts.count==before+4,"actual Relay complete signed zoom stream reaches record-only post hook")
    check(posts.suffix(4).allSatisfy{$0.location==point && $0.getDoubleValueField(CGEventField(rawValue:113)!)==scalar},"desktop pinch preserves scalar and virtual destination")
  }
  func rejected(_ w:Wire,_ label:String,negotiated:Bool=true) {
    r.prepareDesktopAppGestureForTests(map:map,point:point,token:token,negotiated:negotiated)
    let before=posts.count;r.receive(w);check(posts.count==before,label)
  }
  let stream=UUID().uuidString,valid=packet(1,0.25,UUID().uuidString)
  rejected(valid,"absent desktop app negotiation",negotiated:false)
  var bad=valid;bad.desktopGestureTargetID=11;rejected(bad,"wrong display")
  bad=valid;bad.desktopMapRevision=8;rejected(bad,"stale map")
  bad=valid;bad.desktopGlobalX = .nan;rejected(bad,"nonfinite global point")
  bad=valid;bad.desktopGlobalX = -401;rejected(bad,"gesture cannot relocate pointer")
  bad=valid;bad.token=UUID().uuidString;rejected(bad,"stale token")
  bad=valid;bad.x=0.5;bad.y=0.5;rejected(bad,"mixed normalized and desktop shape")
  bad=valid;bad.desktopPortalSide="left";rejected(bad,"portal fields cannot be smuggled")
  for subtype:Int64 in [5,16] {
    let event=fixture(subtype,1,scalar:0.25)
    bad=valid;bad.data=event.data! as Data;bad.appGesture=NativeGestureDescriptor.decode(event)
    rejected(bad,"nonpinch desktop blocked")
  }
  rejected(packet(2,0.25,stream),"unknown change cannot post")
  r.prepareDesktopAppGestureForTests(map:map,point:point,token:token)
  r.appGesturePermissionForTests={false};let beforePermission=posts.count;r.receive(valid)
  check(posts.count==beforePermission,"permission gate")
  r.appGesturePermissionForTests={true}
  r.prepareDesktopAppGestureForTests(map:map,point:point,token:token)
  r.desktopBeforeGateForTests={epoch+=1};let beforeEpoch=posts.count;r.receive(valid)
  check(posts.count==beforeEpoch,"final epoch gate")
  r.desktopBeforeGateForTests=nil
  r.contextForTests?.cancel(reason:"Native pinch memory fixture end")
  print("NativeGesture: \(checks) checks, \(failures) failures (memory-only, not native injection validation)")
  return failures
}
