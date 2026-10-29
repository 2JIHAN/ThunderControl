import AppKit
import IOKit
import IOKit.hidsystem

struct MotionPlan {
  let type: UInt32
  let location: CGPoint
  let dx: Int32
  let dy: Int32
  let point: IOGPoint
  let subx: UInt8
  let suby: UInt8
  let flags: UInt32

  static func make(type: UInt32, location: CGPoint, dx: Double, dy: Double,
                   flags: UInt64, budget: Double) -> MotionPreparation {
    guard [5,6,7].contains(type) else { return .useCG }
    guard location.x.isFinite, location.y.isFinite, dx.isFinite, dy.isFinite,
      abs(Double(location.x)) <= budget, abs(Double(location.y)) <= budget,
      abs(dx) <= budget, abs(dy) <= budget
    else { return .failed(Int32(kIOReturnBadArgument)) }
    guard let xDelta=Int32(exactly:dx),let yDelta=Int32(exactly:dy) else{return .useCG}
    let x=floor(Double(location.x)), y=floor(Double(location.y))
    guard let ix=Int16(exactly:x), let iy=Int16(exactly:y) else { return .useCG }
    return .motion(MotionPlan(type:type,location:location,dx:xDelta,dy:yDelta,
      point:IOGPoint(x:ix,y:iy),
      subx:UInt8(floor((Double(location.x)-x)*256)),
      suby:UInt8(floor((Double(location.y)-y)*256)),
      flags:UInt32(flags & CGEventFlags([.maskAlphaShift,.maskShift,.maskControl,.maskAlternate,.maskCommand,.maskNumericPad,.maskHelp,.maskSecondaryFn]).rawValue) | UInt32(NX_NONCOALSESCEDMASK)))
  }
  var payload: NXEventData {
    var data=NXEventData()
    data.mouseMove.dx=dx; data.mouseMove.dy=dy
    data.mouseMove.subx=subx; data.mouseMove.suby=suby
    return data
  }
}
enum MotionPreparation { case motion(MotionPlan), useCG, failed(Int32) }
enum HIDMotionResult: Equatable { case posted, useCG, cancelled, failed(Int32) }

struct HIDMotionAPI {
  var permissionCheck: () -> Bool
  var open: () -> (Int32, io_connect_t)
  var post: (io_connect_t, MotionPlan) -> Int32
  var close: (io_connect_t) -> Void

  static var system: HIDMotionAPI {
    HIDMotionAPI(permissionCheck: {
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
      return IOHIDPostEvent(port,plan.type,plan.point,&data,2,plan.flags,
                            IOOptionBits(kIOHIDSetCursorPosition))
    }, close: { IOServiceClose($0) })
  }
}

struct RelayInputAPI {
  var motion: HIDMotionAPI
  var postCG: (CGEvent, CGEventTapLocation) -> Void
  static var system: RelayInputAPI {
    RelayInputAPI(motion: .system, postCG: { event, tap in event.post(tap: tap) })
  }
}

final class HIDMouseMotionPoster {
  private let api: HIDMotionAPI
  private var connection: io_connect_t=0
  init(api: HIDMotionAPI = .system) { self.api=api }
  deinit { if connection != 0 { api.close(connection) } }
  func close() {
    precondition(Thread.isMainThread)
    if connection != 0 { api.close(connection); connection=0 }
  }
  func post(_ preparation: MotionPreparation, canPost: () -> Bool) -> HIDMotionResult {
    precondition(Thread.isMainThread)
    let plan:MotionPlan
    switch preparation {
    case .useCG: return .useCG
    case .failed(let code): return .failed(code)
    case .motion(let value): plan=value
    }
    guard api.permissionCheck() else { return .failed(Int32(kIOReturnNotPermitted)) }
    if connection == 0 {
      let (result,port)=api.open()
      guard result == 0, port != 0 else {
        if port != 0 { api.close(port) }
        return .failed(result == 0 ? Int32(kIOReturnNotOpen) : result)
      }
      connection=port
    }
    guard api.permissionCheck() else { return .failed(Int32(kIOReturnNotPermitted)) }
    guard canPost() else { return .cancelled }
    let result=api.post(connection,plan)
    return result == 0 ? .posted : .failed(result)
  }
}
