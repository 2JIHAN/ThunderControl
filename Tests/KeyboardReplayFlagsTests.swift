import AppKit
import IOKit.hidsystem

func runKeyboardReplayFlagsTests() -> Int {
  var failures=0
  func check(_ ok:Bool,_ name:String) {
    if !ok { failures+=1;print("FAIL keyboard replay flags: \(name)") }
  }
  let classifications:CGEventFlags=[.maskAlphaShift,.maskNumericPad,.maskHelp,.maskSecondaryFn]
  let unowned:CGEventFlags=[.maskControl,.maskShift,.maskAlternate,.maskCommand]
  let unknown=CGEventFlags(rawValue:UInt64(1)<<31)
  for key:CGKeyCode in [123,124,0] {
    for side:UInt64 in [1,0x2000] {
      let owned=CGEventFlags(rawValue:CGEventFlags.maskControl.rawValue | side)
      let incoming=classifications.union(unowned).union(unknown)
      let replay=HIDInputPlan.replayFlags(ownedModifiers:owned,eventFlags:incoming)
      check(replay.contains(.maskSecondaryFn),"Fn classification preserved key \(key) side \(side)")
      check(replay == owned.union(classifications),"only owned modifiers and classifications key \(key) side \(side)")
      let event=CGEvent(keyboardEventSource:nil,virtualKey:key,keyDown:true)!
      event.flags=incoming
      guard case .plan(let plan)=HIDInputPlan.make(event:event,keyboardFlags:replay,budget:4_000_000) else {
        check(false,"keyboard HID plan key \(key)");continue
      }
      check(plan.flags == UInt32(owned.union(classifications).rawValue),"actual plan flags key \(key) side \(side)")
      check(plan.flags & UInt32(CGEventFlags.maskSecondaryFn.rawValue) != 0,"actual plan includes Fn key \(key)")
      check(plan.flags & UInt32(side) != 0,"tracked Control side retained key \(key)")
    }
    let noOwnership=HIDInputPlan.replayFlags(ownedModifiers:[],eventFlags:unowned.union(unknown))
    check(noOwnership.isEmpty,"incoming aggregate modifiers do not acquire ownership key \(key)")
    let ownedFn=HIDInputPlan.replayFlags(ownedModifiers:.maskSecondaryFn,eventFlags:[])
    check(ownedFn == .maskSecondaryFn,"owned physical Fn 63 retained key \(key)")
    let keyUp=CGEvent(keyboardEventSource:nil,virtualKey:key,keyDown:false)!
    keyUp.flags=[]
    let upFlags=HIDInputPlan.replayFlags(ownedModifiers:[],eventFlags:keyUp.flags)
    guard case .plan(let upPlan)=HIDInputPlan.make(event:keyUp,keyboardFlags:upFlags,budget:4_000_000) else {
      check(false,"key-up HID plan key \(key)");continue
    }
    check(upPlan.flags == 0,"empty key-up never creates Fn key \(key)")
  }
  print("Keyboard replay flags tests: \(failures) failures")
  return failures
}
