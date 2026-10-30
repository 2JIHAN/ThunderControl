import AppKit
import IOKit
import IOKit.hidsystem

func runHIDMouseMotionTests() -> Int {
  var failures=0
  func check(_ ok:Bool,_ name:String) { if !ok { failures+=1;print("FAIL HID input: \(name)") } }
  func event(_ type:UInt32=5,_ x:Double=10.25,_ y:Double = -20.5) -> CGEvent {
    let e=CGEvent(source:nil)!;e.type=CGEventType(rawValue:type)!;e.location=CGPoint(x:x,y:y)
    e.setIntegerValueField(.mouseEventDeltaX,value:120)
    e.setIntegerValueField(.mouseEventDeltaY,value:-40)
    return e
  }
  func plan(_ e:CGEvent,_ flags:CGEventFlags=[]) -> HIDInputPreparation {
    HIDInputPlan.make(event:e,keyboardFlags:flags,budget:4_000_000)
  }
  for type:UInt32 in [1,2,3,4,5,6,7,25,26,27] {
    let e=event(type);e.flags=[.maskShift];e.setIntegerValueField(.mouseEventButtonNumber,value:2)
    e.setIntegerValueField(.mouseEventClickState,value:3)
    guard case .plan(let p)=plan(e) else {check(false,"pointer type \(type)");continue}
    check(p.type==type && p.location==e.location,"pointer geometry")
    check(p.point.x==10 && p.point.y == -21 && p.subx==64 && p.suby==128,"floor fractions")
    check(p.dx==120 && p.dy == -40,"event deltas preserved")
    let data=p.payload
    check(data.mouse.subx==64 && data.mouse.suby==128 && data.mouse.buttonNumber==2 && data.mouse.click==([5,6,7,27].contains(type) ? 0:3),"mouse union ABI")
    check(data.mouse.eventNum==0 && data.mouse.pressure==0,"no raw delta union alias")
    check(p.options==2 && p.flags==UInt32(NX_NONCOALSESCEDMASK),"pointer flags and options")
  }
  for type:UInt32 in [10,11,12] {
    let e=event(type);e.setIntegerValueField(.keyboardEventKeycode,value:56)
    e.setIntegerValueField(.keyboardEventAutorepeat,value:1)
    guard case .plan(let p)=plan(e,[.maskShift]) else {check(false,"keyboard plan");continue}
    check(p.point.x==0 && p.point.y==0 && p.location==e.location,"keyboard location invalid but scope retained")
    check(p.options==1 && p.flags==UInt32(CGEventFlags.maskShift.rawValue),"keyboard flags and options")
    check(p.payload.key.keyCode==56 && p.payload.key.repeat==1,"keyboard union and repeat")
  }
  for type:UInt32 in [14,22] {
    if case .useCG=plan(event(type)) {} else {check(false,"explicit CG exceptions")}
  }
  for type:UInt32 in [5,6,7,27] {
    if case .motion(let p)=MotionPlan.make(type:type,location:CGPoint(x:-0.25,y:0.75),dx:0.5,dy:-1.25,flags:CGEventFlags.maskShift.rawValue,budget:4_000_000) {
      check(p.point.x == -1 && p.subx==192 && p.suby==192 && p.dx==0.5,"modifier motion remains HID")
    } else {check(false,"pure motion type \(type)")}
  }
  for type:UInt32 in [1,10,22] {
    if case .useCG=MotionPlan.make(type:type,location:.zero,dx:0,dy:0,flags:0,budget:4_000_000) {} else {check(false,"pure motion whitelist")}
  }
  for x in [32768.0,-32768.5] {
    if case .useCG=plan(event(5,x)) {} else {check(false,"Int16 fallback")}
  }
  for x in [Double.nan,Double.infinity,4_000_001] {
    if case .failed=plan(event(5,x)) {} else {check(false,"invalid position rejected")}
  }
  if case .failed=HIDInputPlan.make(event:event(),keyboardFlags:[],budget:100) {} else {check(false,"delta budget rejected")}
  for delta in [Double.nan,Double.infinity,4_000_001] {
    if case .failed=MotionPlan.make(type:5,location:.zero,dx:delta,dy:0,flags:0,budget:4_000_000) {} else {check(false,"invalid pure delta rejected")}
  }
  for budget in [Double.nan,Double.infinity,-1] {
    if case .failed=HIDInputPlan.make(event:event(),keyboardFlags:[],budget:budget) {} else {check(false,"invalid budget rejected")}
  }

  var allowed=true,opens=0,closes=0,reads=0
  var openResult:Int32=0,postResult:Int32=0
  var afterOpen:()->Void = {}
  var sent:[(io_connect_t,HIDInputPlan)]=[]
  let api=HIDInputAPI(permissionCheck:{allowed},open:{
    opens+=1;afterOpen();return (openResult,openResult==0 ? 42:0)
  },post:{port,p in sent.append((port,p));return postResult},close:{_ in closes+=1},readFlags:{reads+=1;return [.maskAlphaShift,.maskCommand]})
  let p=HIDInputPoster(api:api)
  check(!p.isSelected,"backend starts unselected")
  let key=event(10);key.setIntegerValueField(.keyboardEventKeycode,value:56)
  key.setIntegerValueField(.keyboardEventAutorepeat,value:1)
  allowed=false
  check(p.post(key,keyboardFlags:[.maskShift],preferHID:true,canPost:{true}) == .failed(Int32(kIOReturnNotPermitted),attempted:false),"permission failure")
  check(opens==0 && sent.isEmpty,"denied no open or post")
  allowed=true;openResult = -7
  check(p.post(key,keyboardFlags:[],preferHID:true,canPost:{true}) == .failed(-7,attempted:false),"open failure")
  openResult=0;var fresh=true;afterOpen={fresh=false}
  check(p.post(key,keyboardFlags:[],preferHID:true,canPost:{fresh}) == .cancelled,"fresh gate after open")
  check(sent.isEmpty,"cancelled never posted")
  afterOpen={};postResult = -8
  check(p.post(key,keyboardFlags:[.maskShift],preferHID:true,canPost:{true}) == .failed(-8,attempted:true),"attempted post failure")
  check(sent.count==1 && p.hasGlobalStateToRestore,"no duplicate and conservative keyboard state")
  postResult=0
  check(p.post(key,keyboardFlags:[.maskShift],preferHID:true,canPost:{true}) == .posted,"keyboard success")
  check(sent.last!.1.payload.key.repeat==1 && p.isSelected,"repeat transmitted on selected backend")
  let drag=event(6);drag.flags=[.maskShift]
  check(p.post(drag,keyboardFlags:[.maskShift],preferHID:true,canPost:{true}) == .posted,"Shift drag stays HID")
  check(sent.count==3 && Set(sent.map{$0.0})==[42] && reads==1,"same port and one initial snapshot")
  check(p.post(event(5,40000),keyboardFlags:[],preferHID:true,canPost:{true}) == .failed(Int32(kIOReturnBadArgument),attempted:false),"late unsupported fails closed")
  check(sent.count==3,"unsupported never retries")
  check(p.post(drag,keyboardFlags:[],preferHID:false,canPost:{true}) == .failed(Int32(kIOReturnBadArgument),attempted:false),"HID backend cannot switch to CG")
  allowed=false
  check(p.restoreModifiers(preserving:[.maskControl],canPost:{true}) == .failed(Int32(kIOReturnNotPermitted),attempted:false),"cleanup permission failure")
  check(p.hasGlobalStateToRestore,"failed cleanup retained")
  allowed=true
  check(p.restoreModifiers(preserving:[],canPost:{false}) == .cancelled && p.hasGlobalStateToRestore,"cleanup gate retained")
  postResult = -9
  check(p.restoreModifiers(preserving:[],canPost:{true}) == .failed(-9,attempted:true) && p.hasGlobalStateToRestore,"cleanup attempted failure retained")
  postResult=0
  check(p.restoreModifiers(preserving:[.maskControl],canPost:{true}) == .posted,"cleanup retry success")
  let restored=sent.last!.1
  check(restored.type==12 && restored.keyCode==57 && restored.options==1,"fresh flagsChanged Caps key")
  check(restored.flags==UInt32(CGEventFlags([.maskAlphaShift,.maskControl]).rawValue),"initial Caps and physical flags only")
  let count=sent.count
  check(p.restoreModifiers(preserving:[],canPost:{false}) == .posted && sent.count==count,"restore idempotent")
  check(!p.hasGlobalStateToRestore,"cleanup cleared")
  p.preserveLocalCaps([])
  check(reads==1,"physical Caps preservation does not reread flags")
  _=p.post(key,keyboardFlags:[],preferHID:true,canPost:{true})
  _=p.restoreModifiers(preserving:[.maskCommand],canPost:{true})
  check(sent.last!.1.flags==UInt32(CGEventFlags.maskCommand.rawValue),"physical Caps event updates baseline")
  p.close();p.close();check(closes==1 && !p.isHID && !p.isSelected,"close idempotent")

  let cg=HIDInputPoster(api:api);let prior=opens
  check(cg.post(key,keyboardFlags:[],preferHID:false,canPost:{true}) == .useCG,"all-map CG selection")
  check(cg.post(drag,keyboardFlags:[],preferHID:true,canPost:{true}) == .useCG && opens==prior,"CG pinned no open")
  let unrepresentable=HIDInputPoster(api:api)
  check(unrepresentable.post(event(5,40000),keyboardFlags:[],preferHID:true,canPost:{true}) == .useCG,"first unsupported pins CG")
  check(unrepresentable.post(key,keyboardFlags:[],preferHID:true,canPost:{true}) == .useCG && opens==prior,"initial unsupported remains CG")
  var permissionCalls=0
  let revoked=HIDInputPoster(api:HIDInputAPI(permissionCheck:{permissionCalls+=1;return permissionCalls==1},open:{(0,77)},post:{_,_ in check(false,"revoked posted");return 0},close:{_ in}))
  check(revoked.post(key,keyboardFlags:[],preferHID:true,canPost:{true}) == .failed(Int32(kIOReturnNotPermitted),attempted:false),"fresh permission after open")
  revoked.close()
  var defaultPlans:[HIDInputPlan]=[]
  var deinitCloses=0
  do {
    let defaultFlags=HIDInputPoster(api:HIDInputAPI(permissionCheck:{true},open:{(0,88)},post:{_,plan in defaultPlans.append(plan);return 0},close:{_ in deinitCloses+=1}))
    _=defaultFlags.post(key,keyboardFlags:[.maskShift],preferHID:true,canPost:{true})
    _=defaultFlags.restoreModifiers(preserving:[],canPost:{true})
    check(defaultPlans.last!.flags==0,"mock flags default empty, never live flags")
    _=defaultFlags.post(key,keyboardFlags:[.maskShift],preferHID:true,canPost:{true})
  }
  check(defaultPlans.count==3 && deinitCloses==1,"deinit closes port without synthetic input")
  print("HID input: \(failures) failures; fake API only, no real input posting")
  return failures
}
