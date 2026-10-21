import AppKit
import ApplicationServices

// No raw CGEvent archives, text, application identifiers or input logging on wire.
enum DisplayRemoteInputError:Error {case invalid,unsafe,ownership,overflow,unavailable}
struct DisplayInputPacket:Equatable {
  enum Kind:UInt8 {case move=1,buttonDown=2,buttonUp=3,keyDown=4,keyUp=5,modifier=6,scroll=7,releaseAll=8}
  static let flagMask:UInt64 = CGEventFlags.maskShift.rawValue | CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskCommand.rawValue | CGEventFlags.maskSecondaryFn.rawValue | CGEventFlags.maskNumericPad.rawValue | CGEventFlags.maskAlphaShift.rawValue | 0x207f
  var kind:Kind,code:UInt16=0,flags:UInt64=0,x:UInt32=32768,y:UInt32=32768,sx:Int32=0,sy:Int32=0,detail:UInt32=0
  static let modifiers:Set<UInt16>=[54,55,56,57,58,59,60,61,62,63]
  func validate()throws {
    guard flags & ~Self.flagMask == 0,x<=65535,y<=65535,abs(Int64(sx))<=4096,abs(Int64(sy))<=4096 else{throw DisplayRemoteInputError.invalid}
    switch kind {
    case .move:guard code<=2,sx==0,sy==0,detail==0 else{throw DisplayRemoteInputError.invalid}
    case .buttonDown,.buttonUp:guard code<=2,sx==0,sy==0,(1...3).contains(detail) else{throw DisplayRemoteInputError.invalid}
    case .keyDown:guard code<=127,!Self.modifiers.contains(code),sx==0,sy==0,detail<=1 else{throw DisplayRemoteInputError.invalid}
    case .keyUp:guard code<=127,!Self.modifiers.contains(code),sx==0,sy==0,detail==0 else{throw DisplayRemoteInputError.invalid}
    case .modifier:guard Self.modifiers.contains(code),sx==0,sy==0,detail<=1 else{throw DisplayRemoteInputError.invalid}
    case .scroll:guard code==0,detail==0 else{throw DisplayRemoteInputError.invalid}
    case .releaseAll:guard code==0,flags==0,x==32768,y==32768,sx==0,sy==0,detail==0 else{throw DisplayRemoteInputError.invalid}
    }
  }
  func encoded()throws->Data {
    try validate();var d=Data([4,1,kind.rawValue,0])
    func append<T:FixedWidthInteger>(_ n:T){var be=n.bigEndian;withUnsafeBytes(of:&be){d.append(contentsOf:$0)}}
    append(code);append(UInt16(0));append(flags);append(x);append(y);append(sx);append(sy);append(detail);return d
  }
  init(kind:Kind,code:UInt16=0,flags:UInt64=0,x:UInt32=32768,y:UInt32=32768,sx:Int32=0,sy:Int32=0,detail:UInt32=0){self.kind=kind;self.code=code;self.flags=flags;self.x=x;self.y=y;self.sx=sx;self.sy=sy;self.detail=detail}
  init(data:Data)throws {
    let b=[UInt8](data);guard b.count==36,b[0]==4,b[1]==1,b[3]==0,b[6]==0,b[7]==0,let k=Kind(rawValue:b[2]) else{throw DisplayRemoteInputError.invalid}
    func u(_ start:Int,_ n:Int)->UInt64{b[start..<(start+n)].reduce(UInt64(0)){($0<<8)|UInt64($1)}}
    kind=k;code=UInt16(u(4,2));flags=u(8,8);x=UInt32(u(16,4));y=UInt32(u(20,4));sx=Int32(bitPattern:UInt32(u(24,4)));sy=Int32(bitPattern:UInt32(u(28,4)));detail=UInt32(u(32,4));try validate()
  }
}
struct DisplayInputOwnership {
  private(set) var keys=Set<UInt16>(),buttons=Set<UInt16>()
  // Modifier flags derive only from accepted downs, never peer-supplied flags.
  var heldFlags:CGEventFlags {
    var result=CGEventFlags()
    for code in keys {
      if code==57 {result.insert(.maskAlphaShift)}
      else if let descriptor=modifierDescriptors[code] {result.formUnion(descriptor.aggregate);result=CGEventFlags(rawValue:result.rawValue | descriptor.sideBit)}
    }
    return result
  }
  mutating func accept(_ p:DisplayInputPacket)throws {
    try p.validate()
    switch p.kind {
    case .keyDown:if p.detail==1{guard keys.contains(p.code) else{throw DisplayRemoteInputError.ownership}}else{guard keys.insert(p.code).inserted else{throw DisplayRemoteInputError.ownership}}
    case .keyUp:guard keys.remove(p.code) != nil else{throw DisplayRemoteInputError.ownership}
    case .modifier:if p.detail==1{guard keys.insert(p.code).inserted else{throw DisplayRemoteInputError.ownership}}else{guard keys.remove(p.code) != nil else{throw DisplayRemoteInputError.ownership}}
    case .buttonDown:guard buttons.insert(p.code).inserted else{throw DisplayRemoteInputError.ownership}
    case .buttonUp:guard buttons.remove(p.code) != nil else{throw DisplayRemoteInputError.ownership}
    case .move,.scroll:break
    case .releaseAll:keys.removeAll();buttons.removeAll()
    }
    guard keys.count<=128,buttons.count<=3 else{throw DisplayRemoteInputError.ownership}
  }
}

// AX focus is a best-effort focus gate, not a security boundary against every
// customizable macOS shortcut. Known global shortcuts are rejected explicitly.
func displayInputKeyPermitted(_ code:UInt16,flags:CGEventFlags)->Bool {
  if [72,73,74,127].contains(code) {return false}
  if flags.contains(.maskControl),[49,120,99,123,124,125,126].contains(code) {return false}
  if flags.contains(.maskCommand) {
    if flags.contains(.maskControl) {return false}
    // Ordinary application editing/navigation commands only. This rejects
    // CmdTab, CmdSpace, CmdShiftQ, CmdOptEsc and other global combinations.
    let applicationCommands:Set<UInt16>=[0,1,2,3,6,7,8,9,11,13,15,17,32,34,35,37,45]
    return applicationCommands.contains(code)
  }
  return true
}

// Before the helper exists, no remote input has ever been owned. Strictly valid
// focus-release is a harmless no-op; every other early packet remains rejected.
func displayInputSafeBeforeTarget(_ data:Data)throws->Bool {try DisplayInputPacket(data:data).kind == .releaseAll}

struct DisplayInputPendingBuffer {
  struct Item {let data:Data;let motion:Bool;let queued:Double}
  private(set) var items:[Item]=[]
  mutating func push(_ data:Data,now:Double,reset:Bool=false)->Bool {
    if reset {items.removeAll(keepingCapacity:true)}
    let motion=data.count==36 && data[data.startIndex+2]==DisplayInputPacket.Kind.move.rawValue
    let item=Item(data:data,motion:motion,queued:now)
    if motion,items.last?.motion==true {items[items.count-1]=item;return true}
    guard items.count<32 else{return false};items.append(item);return true
  }
  mutating func pop()->Item?{items.isEmpty ? nil:items.removeFirst()}
  mutating func clear(){items.removeAll()}
}
private final class DisplayInputQueue {
  let lock=NSLock(),queue=DispatchQueue(label:"ThunderControl.display.input-return",qos:.userInteractive)
  var buffer=DisplayInputPendingBuffer(),scheduled=false,stopped=false
  let send:(Data)throws->Void,failure:()->Void
  init(send:@escaping(Data)throws->Void,failure:@escaping()->Void){self.send=send;self.failure=failure}
  func enqueue(_ data:Data,reset:Bool=false)->Bool {
    lock.lock()
    guard !stopped else{lock.unlock();return false}
    guard buffer.push(data,now:ProcessInfo.processInfo.systemUptime,reset:reset) else{stopped=true;buffer.clear();lock.unlock();DispatchQueue.main.async(execute:failure);return false}
    let start = !scheduled;scheduled=true;lock.unlock()
    if start{queue.async{[self] in drain()}};return true
  }
  private func drain(){while true {
    lock.lock();guard !stopped,let next=buffer.pop() else{scheduled=false;lock.unlock();return};lock.unlock()
    let age=ProcessInfo.processInfo.systemUptime-next.queued
    if next.motion && age>0.15{continue}
    do {guard age<0.5 else{throw DisplayRemoteInputError.overflow};try send(next.data)}
    catch {lock.lock();let notify = !stopped;stopped=true;buffer.clear();lock.unlock();if notify{DispatchQueue.main.async(execute:failure)};return}
  }}
  func stop(){lock.lock();stopped=true;buffer.clear();lock.unlock()}
}

@MainActor final class DisplayRemoteInputSender {
  private let output:DisplayInputQueue
  private var ownership=DisplayInputOwnership()
  private var lastPoint=CGPoint(x:0.5,y:0.5),stopped=false,paused=false
  init(send:@escaping(Data)throws->Void,onFailure:@escaping()->Void){output=DisplayInputQueue(send:send,failure:onFailure)}
  func stop(){stopped=true;output.stop()}
  func pause(){guard !stopped,!paused else{return};paused=true;ownership=DisplayInputOwnership();do{guard output.enqueue(try DisplayInputPacket(kind:.releaseAll).encoded(),reset:true) else{throw DisplayRemoteInputError.overflow}}catch{stop();output.failure()}}
  func resume(){guard !stopped else{return};paused=false}
  func handle(_ event:NSEvent,position:CGPoint?)->Bool {
    guard !stopped,!paused else{return false}
    if let p=position {guard p.x.isFinite,p.y.isFinite,(0...1).contains(p.x),(0...1).contains(p.y) else{stop();output.failure();return false};lastPoint=p}
    let raw=UInt64(event.modifierFlags.rawValue)&DisplayInputPacket.flagMask
    let x=UInt32((lastPoint.x*65535).rounded()),y=UInt32((lastPoint.y*65535).rounded())
    var packet:DisplayInputPacket
    switch event.type {
    case .keyDown:if event.isARepeat && !ownership.keys.contains(event.keyCode){return true};packet = .init(kind:.keyDown,code:event.keyCode,flags:raw,x:x,y:y,detail:event.isARepeat ? 1:0)
    case .keyUp:guard ownership.keys.contains(event.keyCode) else{return false};packet = .init(kind:.keyUp,code:event.keyCode,flags:raw,x:x,y:y)
    case .flagsChanged:
      let code=event.keyCode;guard DisplayInputPacket.modifiers.contains(code) else{return false}
      let down:Bool
      if code==57{down=event.modifierFlags.contains(.capsLock)}else if let value=modifierDown(code,flags:CGEventFlags(rawValue:UInt64(event.modifierFlags.rawValue))){down=value}else{if ownership.keys.contains(code){stop();output.failure()};return false}
      guard down != ownership.keys.contains(code) else{return false}
      packet = .init(kind:.modifier,code:code,flags:raw,x:x,y:y,detail:down ? 1:0)
    case .leftMouseDown,.rightMouseDown,.otherMouseDown:
      guard position != nil,(0...2).contains(event.buttonNumber) else{return false};packet = .init(kind:.buttonDown,code:UInt16(event.buttonNumber),flags:raw,x:x,y:y,detail:UInt32(max(1,min(3,event.clickCount))))
    case .leftMouseUp,.rightMouseUp,.otherMouseUp:
      guard (0...2).contains(event.buttonNumber),ownership.buttons.contains(UInt16(event.buttonNumber)) else{return false};packet = .init(kind:.buttonUp,code:UInt16(event.buttonNumber),flags:raw,x:x,y:y,detail:UInt32(max(1,min(3,event.clickCount))))
    case .mouseMoved,.leftMouseDragged,.rightMouseDragged,.otherMouseDragged:
      guard position != nil else{return false};packet = .init(kind:.move,code:UInt16(max(0,min(2,event.buttonNumber))),flags:raw,x:x,y:y)
    case .scrollWheel:
      guard position != nil,event.scrollingDeltaX.isFinite,event.scrollingDeltaY.isFinite else{return false}
      let factor:CGFloat=event.hasPreciseScrollingDeltas ? 1:10
      packet = .init(kind:.scroll,flags:raw,x:x,y:y,sx:Int32(max(-4096,min(4096,event.scrollingDeltaX*factor)).rounded()),sy:Int32(max(-4096,min(4096,event.scrollingDeltaY*factor)).rounded()))
    default:return false
    }
    do{try ownership.accept(packet);packet.flags=ownership.heldFlags.rawValue;if packet.kind == .keyDown,!displayInputKeyPermitted(packet.code,flags:ownership.heldFlags){throw DisplayRemoteInputError.unsafe};return output.enqueue(try packet.encoded())}catch{stop();output.failure();return false}
  }
}

@MainActor final class DisplayRemoteInputReceiver {
  private let displayID:CGDirectDisplayID
  private let sessionPermitted:()->Bool
  private let source=CGEventSource(stateID:.privateState)
  private var ownership=DisplayInputOwnership(),stopped=false
  private var point=CGPoint.zero
  init(displayID:CGDirectDisplayID,sessionPermitted:@escaping()->Bool){self.displayID=displayID;self.sessionPermitted=sessionPermitted}
  private func bounds()throws->CGRect {
    let r=CGDisplayBounds(displayID)
    guard displayID != 0,displayID != CGMainDisplayID(),CGDisplayIsOnline(displayID) != 0,CGDisplayIsActive(displayID) != 0,CGDisplayIsInMirrorSet(displayID)==0,r.width==1920,r.height==1080,r.origin.x.isFinite,r.origin.y.isFinite else{throw DisplayRemoteInputError.unsafe};return r
  }
  private var safe:Bool {sessionPermitted() && AXIsProcessTrusted() && sessionBlockReason(snapshot:readSystemSessionSnapshot(),lockedSignal:false,sleeping:false,secureInput:isSystemSecureInputEnabled()) == nil}
  // Keyboard events have global focus, regardless of their location. Fail closed
  // unless the focused AX window's center belongs to our virtual screen.
  private func focusOnDisplay(_ rect:CGRect)->Bool {
    let system=AXUIElementCreateSystemWide();AXUIElementSetMessagingTimeout(system,0.03);var app:CFTypeRef?,window:CFTypeRef?,position:CFTypeRef?,size:CFTypeRef?
    guard AXUIElementCopyAttributeValue(system,kAXFocusedApplicationAttribute as CFString,&app) == .success,let app,CFGetTypeID(app)==AXUIElementGetTypeID() else{return false}
    let application=unsafeBitCast(app,to:AXUIElement.self);AXUIElementSetMessagingTimeout(application,0.03)
    guard AXUIElementCopyAttributeValue(application,kAXFocusedWindowAttribute as CFString,&window) == .success,let window,CFGetTypeID(window)==AXUIElementGetTypeID() else{return false}
    let w=unsafeBitCast(window,to:AXUIElement.self);AXUIElementSetMessagingTimeout(w,0.03)
    guard AXUIElementCopyAttributeValue(w,kAXPositionAttribute as CFString,&position) == .success,AXUIElementCopyAttributeValue(w,kAXSizeAttribute as CFString,&size) == .success,let position,let size,CFGetTypeID(position)==AXValueGetTypeID(),CFGetTypeID(size)==AXValueGetTypeID() else{return false}
    var p=CGPoint.zero,s=CGSize.zero
    guard AXValueGetValue(unsafeBitCast(position,to:AXValue.self),.cgPoint,&p),AXValueGetValue(unsafeBitCast(size,to:AXValue.self),.cgSize,&s),p.x.isFinite,p.y.isFinite,s.width.isFinite,s.height.isFinite,s.width>0,s.height>0 else{return false}
    return rect.contains(CGPoint(x:p.x+s.width/2,y:p.y+s.height/2))
  }
  func accept(_ data:Data)throws {
    guard !stopped,source != nil,safe else{_ = stop();throw DisplayRemoteInputError.unsafe}
    do {
      let p=try DisplayInputPacket(data:data)
      if p.kind == .releaseAll {guard releaseHeldInputs() else{throw DisplayRemoteInputError.unsafe};return}
      let r=try bounds()
      var next=ownership;try next.accept(p)
      let effectiveFlags=next.heldFlags
      if p.kind == .keyDown,!displayInputKeyPermitted(p.code,flags:effectiveFlags){throw DisplayRemoteInputError.unsafe}
      point=CGPoint(x:r.minX+Double(p.x)/65535*(r.width-1),y:r.minY+Double(p.y)/65535*(r.height-1))
      let event:CGEvent?
      switch p.kind {
      case .keyDown,.keyUp,.modifier:
        // AX window geometry gates fresh downs. It does not guarantee that a
        // customizable system shortcut cannot subsequently change global focus.
        if p.kind == .keyDown || (p.kind == .modifier && p.detail==1){guard focusOnDisplay(r) else{throw DisplayRemoteInputError.unsafe}}
        let down=p.kind == .keyDown || (p.kind == .modifier && p.detail==1)
        event=CGEvent(keyboardEventSource:source,virtualKey:p.code,keyDown:down)
        if p.kind == .modifier{event?.type = .flagsChanged}
        event?.setIntegerValueField(.keyboardEventAutorepeat,value:p.kind == .keyDown ? Int64(p.detail):0)
      case .buttonDown,.buttonUp:
        let down=p.kind == .buttonDown
        let type:CGEventType=p.code==0 ? (down ? .leftMouseDown:.leftMouseUp):p.code==1 ? (down ? .rightMouseDown:.rightMouseUp):(down ? .otherMouseDown:.otherMouseUp)
        event=CGEvent(mouseEventSource:source,mouseType:type,mouseCursorPosition:point,mouseButton:CGMouseButton(rawValue:UInt32(p.code))!)
        event?.setIntegerValueField(.mouseEventClickState,value:Int64(p.detail))
      case .move:
        let button=ownership.buttons.sorted().first
        let type:CGEventType=button==0 ? .leftMouseDragged:button==1 ? .rightMouseDragged:button==2 ? .otherMouseDragged:.mouseMoved
        event=CGEvent(mouseEventSource:source,mouseType:type,mouseCursorPosition:point,mouseButton:CGMouseButton(rawValue:UInt32(button ?? 0))!)
      case .releaseAll:throw DisplayRemoteInputError.invalid
      case .scroll:
        event=CGEvent(scrollWheelEvent2Source:source,units:.pixel,wheelCount:2,wheel1:p.sy,wheel2:p.sx,wheel3:0)
      }
      guard let e=event,try bounds()==r,safe else{throw DisplayRemoteInputError.unsafe}
      e.location=point;e.flags=effectiveFlags;e.post(tap:.cghidEventTap);ownership=next
    }catch{_ = stop();throw error}
  }
  @discardableResult func stop()->Bool {stopped=true;return releaseHeldInputs()}
  private func releaseHeldInputs()->Bool {
    var ok=true
    // Cleanup is release-only and is deliberately allowed after session loss.
    // AX revocation cannot be bypassed; report failure for the app's safety gate.
    guard ownership.keys.isEmpty && ownership.buttons.isEmpty || AXIsProcessTrusted() else{return false}
    for code in ownership.keys.sorted(){if let e=CGEvent(keyboardEventSource:source,virtualKey:code,keyDown:false){if DisplayInputPacket.modifiers.contains(code){e.type = .flagsChanged};e.flags=[];e.location=point;e.post(tap:.cghidEventTap)}else{ok=false}}
    for code in ownership.buttons.sorted(){let type:CGEventType=code==0 ? .leftMouseUp:code==1 ? .rightMouseUp:.otherMouseUp;if let e=CGEvent(mouseEventSource:source,mouseType:type,mouseCursorPosition:point,mouseButton:CGMouseButton(rawValue:UInt32(code))!){e.flags=[];e.post(tap:.cghidEventTap)}else{ok=false}}
    if ok{ownership=DisplayInputOwnership()};return ok
  }
}
