import AppKit
import IOKit
import IOKit.hidsystem

struct MotionPlan {
  let type: UInt32
  let location: CGPoint
  let dx: Double
  let dy: Double
  let point: IOGPoint
  let subx: UInt8
  let suby: UInt8
  let flags: UInt32

  static func make(type: UInt32, location: CGPoint, dx: Double, dy: Double,
                   flags: UInt64, budget: Double) -> MotionPreparation {
    guard [5,6,7,27].contains(type) else { return .useCG }
    guard budget.isFinite, budget >= 0,
      location.x.isFinite, location.y.isFinite, dx.isFinite, dy.isFinite,
      abs(Double(location.x)) <= budget, abs(Double(location.y)) <= budget,
      abs(dx) <= budget, abs(dy) <= budget
    else { return .failed(Int32(kIOReturnBadArgument)) }
    let x=floor(Double(location.x)), y=floor(Double(location.y))
    guard let ix=Int16(exactly:x), let iy=Int16(exactly:y) else { return .useCG }
    return .motion(MotionPlan(type:type,location:location,dx:dx,dy:dy,
      point:IOGPoint(x:ix,y:iy),
      // Floating-point rounding can turn a fraction just below one into 256.
      subx:UInt8(min(255,floor((Double(location.x)-x)*256))),
      suby:UInt8(min(255,floor((Double(location.y)-y)*256))),
      flags:UInt32(NX_NONCOALSESCEDMASK)))
  }
}
enum MotionPreparation { case motion(MotionPlan), useCG, failed(Int32) }

struct HIDInputPlan {
  let type: UInt32
  let location: CGPoint
  let flags: UInt32
  let options: IOOptionBits
  let motion: MotionPlan?
  let keyCode: UInt16
  let autorepeat: Bool
  let button: UInt8
  let click: Int32

  var point: IOGPoint { motion?.point ?? IOGPoint(x:0,y:0) }
  var dx: Double { motion?.dx ?? 0 }
  var dy: Double { motion?.dy ?? 0 }
  var subx: UInt8 { motion?.subx ?? 0 }
  var suby: UInt8 { motion?.suby ?? 0 }
  var payload: NXEventData {
    var data=NXEventData()
    if [10,11,12].contains(type) {
      data.key.keyCode=keyCode
      data.key.repeat=autorepeat ? 1:0
    } else {
      data.mouse.subx=subx;data.mouse.suby=suby
      data.mouse.buttonNumber=button;data.mouse.click=click
    }
    return data
  }

  static func make(event:CGEvent, keyboardFlags:CGEventFlags, budget:Double) -> HIDInputPreparation {
    let type=event.type.rawValue, location=event.location
    guard [1,2,3,4,5,6,7,10,11,12,25,26,27].contains(type) else { return .useCG }
    guard budget.isFinite, budget >= 0, location.x.isFinite, location.y.isFinite,
      abs(Double(location.x)) <= budget, abs(Double(location.y)) <= budget
    else { return .failed(Int32(kIOReturnBadArgument)) }
    if [10,11,12].contains(type) {
      guard let key=UInt16(exactly:event.getIntegerValueField(.keyboardEventKeycode)),
        let flags=UInt32(exactly:keyboardFlags.rawValue)
      else { return .failed(Int32(kIOReturnBadArgument)) }
      return .plan(HIDInputPlan(type:type,location:location,flags:flags,options:1,
        motion:nil,keyCode:key,autorepeat:event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
        button:0,click:0))
    }
    guard let button=UInt8(exactly:event.getIntegerValueField(.mouseEventButtonNumber)),button <= 31,
      let click=Int32(exactly:event.getIntegerValueField(.mouseEventClickState))
    else { return .failed(Int32(kIOReturnBadArgument)) }
    // Button events use the same public mouse union and fixed-point coordinates as motion.
    let geometryType:UInt32=[5,6,7,27].contains(type) ? type:5
    switch MotionPlan.make(type:geometryType,location:location,
      dx:event.getDoubleValueField(.mouseEventDeltaX),dy:event.getDoubleValueField(.mouseEventDeltaY),
      flags:0,budget:budget) {
    case .useCG: return .useCG
    case .failed(let code): return .failed(code)
    case .motion(let geometry):
      let motion=MotionPlan(type:type,location:location,dx:geometry.dx,dy:geometry.dy,
        point:geometry.point,subx:geometry.subx,suby:geometry.suby,flags:geometry.flags)
      return .plan(HIDInputPlan(type:type,location:location,flags:motion.flags,options:2,
        motion:motion,keyCode:0,autorepeat:false,button:button,click:[5,6,7,27].contains(type) ? 0:click))
    }
  }
}
enum HIDInputPreparation { case plan(HIDInputPlan), useCG, failed(Int32) }
enum HIDInputResult: Equatable { case posted, useCG, cancelled, failed(Int32,attempted:Bool) }

struct HIDInputAPI {
  var permissionCheck: () -> Bool
  var open: () -> (Int32, io_connect_t)
  var post: (io_connect_t, HIDInputPlan) -> Int32
  var close: (io_connect_t) -> Void
  var readFlags: () -> CGEventFlags = { [] }

  static var system: HIDInputAPI {
    HIDInputAPI(permissionCheck: {
      IOHIDCheckAccess(kIOHIDRequestTypePostEvent) == kIOHIDAccessTypeGranted
    }, open: {
      let service=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("IOHIDSystem"))
      guard service != 0 else { return (Int32(kIOReturnNotFound),0) }
      defer { IOObjectRelease(service) }
      var port:io_connect_t=0
      let result=IOServiceOpen(service,mach_task_self_,1,&port)
      return (result,port)
    }, post: { port,plan in
      var data=plan.payload
      return IOHIDPostEvent(port,plan.type,plan.point,&data,2,plan.flags,plan.options)
    }, close: { IOServiceClose($0) },readFlags: { CGEventSource.flagsState(.hidSystemState) })
  }
}

struct RelayInputAPI {
  var native: HIDInputAPI
  var postCG: (CGEvent, CGEventTapLocation) -> Void
  var warp: (CGPoint) -> CGError
  static var system: RelayInputAPI {
    RelayInputAPI(native: .system, postCG: { event, tap in event.post(tap: tap) }, warp: CGWarpMouseCursorPosition)
  }
}

final class HIDInputPoster {
  private enum Backend { case unselected, hid, cg }
  private let api: HIDInputAPI
  private var backend:Backend = .unselected
  private var connection:io_connect_t=0
  private var capsSnapshot:CGEventFlags=[]
  private var didPostKeyboard=false
  var isSelected:Bool { backend != .unselected }
  var isHID:Bool { backend == .hid }
  var hasGlobalStateToRestore:Bool { didPostKeyboard }
  init(api:HIDInputAPI = .system) { self.api=api }
  deinit { if connection != 0 { api.close(connection) } }

  func post(_ event:CGEvent,keyboardFlags:CGEventFlags,preferHID:Bool,afterOpen:()->Bool = {true},canPost:()->Bool) -> HIDInputResult {
    precondition(Thread.isMainThread)
    if backend == .cg { return .useCG }
    if !preferHID {
      guard backend == .unselected else { return .failed(Int32(kIOReturnBadArgument),attempted:false) }
      backend = .cg
      return .useCG
    }
    let plan:HIDInputPlan
    switch HIDInputPlan.make(event:event,keyboardFlags:keyboardFlags,budget:4_000_000) {
    case .plan(let value): plan=value
    case .failed(let code): return .failed(code,attempted:false)
    case .useCG:
      guard backend == .unselected else { return .failed(Int32(kIOReturnBadArgument),attempted:false) }
      backend = .cg
      return .useCG
    }
    if backend == .unselected {
      backend = .hid
      capsSnapshot=api.readFlags().intersection(.maskAlphaShift)
    }
    return postNative(plan,afterOpen:afterOpen,canPost:canPost)
  }

  private func postNative(_ plan:HIDInputPlan,afterOpen:()->Bool = {true},canPost:()->Bool) -> HIDInputResult {
    guard api.permissionCheck() else { return .failed(Int32(kIOReturnNotPermitted),attempted:false) }
    if connection == 0 {
      let (result,port)=api.open()
      guard result == 0, port != 0 else {
        if port != 0 { api.close(port) }
        return .failed(result == 0 ? Int32(kIOReturnNotOpen):result,attempted:false)
      }
      connection=port
      guard afterOpen() else { return .cancelled }
    }
    guard api.permissionCheck() else { return .failed(Int32(kIOReturnNotPermitted),attempted:false) }
    guard canPost() else { return .cancelled }
    // A failing driver call may still have changed global modifier state.
    if [10,11,12].contains(plan.type) { didPostKeyboard=true }
    let result=api.post(connection,plan)
    return result == 0 ? .posted:.failed(result,attempted:true)
  }

  func preserveLocalCaps(_ flags:CGEventFlags) {
    precondition(Thread.isMainThread)
    if isHID { capsSnapshot=flags.intersection(.maskAlphaShift) }
  }

  func restoreModifiers(preserving:CGEventFlags,canPost:()->Bool) -> HIDInputResult {
    precondition(Thread.isMainThread)
    guard isHID,didPostKeyboard else { return .posted }
    guard let flags=UInt32(exactly:capsSnapshot.union(preserving).rawValue) else {
      return .failed(Int32(kIOReturnBadArgument),attempted:false)
    }
    let plan=HIDInputPlan(type:12,location:.zero,flags:flags,options:1,motion:nil,
      keyCode:57,autorepeat:false,button:0,click:0)
    let result=postNative(plan,canPost:canPost)
    if result == .posted { didPostKeyboard=false }
    return result
  }

  func close() {
    precondition(Thread.isMainThread)
    if connection != 0 { api.close(connection);connection=0 }
    backend = .unselected;capsSnapshot=[];didPostKeyboard=false
  }
}
