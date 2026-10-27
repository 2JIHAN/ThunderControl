import AppKit
import CryptoKit
import Darwin
import IOKit
import OSLog

// Callback owns no Relay pointer. Static epoch storage outlives every callback.
// Lifecycle changes occur on the main thread; callback only takes the epoch lock.
// No native registration, posting or warp is performed under that lock.
final class DesktopInjectionEpoch {
  static let shared=DesktopInjectionEpoch()
  private let lock=NSLock()
  private var value:UInt64=0
  private var users=0
  private var registered=false
  private static let callback:CGDisplayReconfigurationCallBack = {_,_,_ in shared.invalidate()}
  func invalidate(){lock.lock();value &+= 1;lock.unlock()}
  func snapshot()->UInt64 {lock.lock();defer{lock.unlock()};return value}
  func acquire()->Bool {
    guard Thread.isMainThread else{return false}
    if !registered {
      guard CGDisplayRegisterReconfigurationCallback(Self.callback,nil) == .success else{return false}
      registered=true
    }
    users+=1;return true
  }
  func release(){
    guard Thread.isMainThread else{DispatchQueue.main.async{self.release()};return}
    guard users>0 else{return};users-=1
    if users==0,registered {CGDisplayRemoveReconfigurationCallback(Self.callback,nil);registered=false;invalidate()}
  }
  static func allows(validated:UInt64?,current:UInt64)->Bool {validated==current}
}

func connectionLog(_ text:String) {
  guard !CommandLine.arguments.contains("--self-test"),!CommandLine.arguments.contains("--pairing-integration-test"),!CommandLine.arguments.contains("--ui-smoke-test"),!CommandLine.arguments.contains("--ui-ownership-test") else{return}
  DiagnosticStore.shared.recordConnection("t=\(Date().timeIntervalSince1970) "+text)
}
func safeConnectionError(_ error: Error) -> String {
  if let e=error as? TrustedPairingError,case .keychainUnavailable=e {return TCText("Keychain access is restricted while locked. Waiting to retry automatically without changing security settings.")}
  if error is TrustedPairingError {return TCText("Saved device authentication failed. Verify the peer with a manual connection before considering an explicit pairing reset.")}
  if let failure = error as? Failure { return failure.description }
  if error is PINPairingError {return "PIN pairing failed or cancelled. Use a fresh code and retry; no input was enabled."}
  if error is CryptoKitError {
    return
      "Session authentication failed: mismatched version or corrupted encrypted frame"
  }
  if error is DecodingError { return "Invalid protocol encoding (payload omitted)" }
  return "Internal connection error (details omitted)"
}
// Only public, explicit unsupported gestures block pointer-only auto handoff.
// Generic touch/begin/end packets are not evidence of a multi-finger gesture.
func blocksPointerHandoff(_ type: NSEvent.EventType?, changed: Bool = true) -> Bool {
  guard changed else { return false }
  switch type {
  case .magnify?, .rotate?, .swipe?: return true
  default: return false
  }
}
func explicitGestureMotion(_ cg: CGEvent) -> Bool {
  guard let event = NSEvent(cgEvent: cg) else { return false }
  let changed: Bool
  switch event.type {
  case .magnify: changed = event.magnification.isFinite && event.magnification != 0
  case .rotate: changed = event.rotation.isFinite && event.rotation != 0
  case .swipe:
    changed =
      event.deltaX.isFinite && event.deltaY.isFinite && (event.deltaX != 0 || event.deltaY != 0)
  default: changed = false
  }
  return blocksPointerHandoff(event.type, changed: changed)
}
func edgeHeldReason(keys: Bool, buttons: Bool, modifiers: Bool, gesture: Bool) -> String? {
  if keys { return "keyboard input still held" }
  if buttons { return "mouse button still held" }
  if modifiers { return "modifier still held" }
  if gesture { return "explicit gesture cooldown" }
  return nil
}
func isTransientTransportFailure(_ error:Error)->Bool {
  guard let failure=error as? Failure else{return false}
  let text=failure.description
  return text=="Peer closed the TCP connection (EOF)" || text=="Receive timed out waiting for peer frame" || text.hasPrefix("Receive failed: errno=") || text.hasPrefix("Send failed: errno=")
}
func shouldSuspendAutomaticReconnect(stage:String,error:Error,terminalReason:String?)->Bool {
  if terminalReason=="Fast route budget expired" {return false}
  // Locally detected saturation is not a peer-authentication failure. Teardown,
  // held-input cleanup and all automatic safety gates still run before retry.
  if stage=="Authenticated stream",let failure=error as? Failure,failure.description=="Inbound queue overload" {return false}
  if let e=error as? TrustedPairingError,case .keychainUnavailable=e {return false}
  return ["Trusted pairing","Encrypted role confirmation","Authenticated stream"].contains(stage) && !isTransientTransportFailure(error) && terminalReason != "Pairing transport interrupted"
}
func inputPermissionsReady()->Bool {AXIsProcessTrusted() && CGPreflightListenEventAccess()}
func heartbeatExpired(authenticated: Bool, idle: Double) -> Bool { authenticated && idle > 6 }
func setBlocking(_ fd: Int32) throws {
  let flags = fcntl(fd, F_GETFL)
  guard flags >= 0, fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) == 0 else {
    throw Failure("Cannot set blocking connected socket: errno=\(errno)")
  }
}
let cap = 128 * 1024
let marker: Int64 = 0x54_4855_4E44_4552
struct Failure: Error, CustomStringConvertible {
  let description: String
  init(_ s: String) { description = s }
}
struct Wire: Codable {
  var concurrentDisplayCodec:Int? = nil
  var kind: String
  var session: String
  var sequence: UInt64
  var raw: UInt32?
  var data: Data?
  var x: Double?
  var y: Double?
  var os: Int?
  var token: String?
  var edge: Edge?
  var width: Double?
  var height: Double?
  var screenWidth: Double?
  var screenHeight: Double?
  var layoutY: Double?
  var osBuild:String?
  var gestureCodec:Int?
  var dock:DockGestureDescriptor?
  var dockID:String?
  var appGesture:NativeGestureDescriptor?
  var appGestureID:String?
  var appGestureCodec:Int?
  var cursorVisibilityCodec:Int?
  var cursorMode:Bool?
  var peerDisplayName:String?
  // Serialized ReceiverDesktop (JSON Codable). Only valid on "available"
  // packets from the authenticated receiver, bounded to keep framing cheap.
  var receiverDesktopMap:Data?
  // Separate capability bit for the 0.8.20 multi-target desktop coordinate
  // protocol. 0.8.19 peers already advertise concurrentDisplayCodec=1 but do
  // not understand ReceiverDesktop maps or source-origin snapping; this gate
  // keeps the new coordinate wire off any legacy peer.
  var multiDisplayDesktopCodec:Int?
  // 4-edge DesktopHandoff fields. Carried only on begin and event packets in
  // the authenticated new mode. begin: full portal attestation + entry point.
  // event: global receiver desktop pointer coordinate. The receiver validates
  // every field against its freshly read desktop map and current revision.
  var desktopPortalSide:String?
  var desktopPortalTargetID:UInt32?
  var desktopPortalIntervalStart:Double?
  var desktopPortalIntervalEnd:Double?
  var desktopPortalSourceOriginX:Double?
  var desktopPortalSourceOriginY:Double?
  var desktopPortalSourceWidth:Double?
  var desktopPortalSourceHeight:Double?
  var desktopPortalTargetOriginX:Double?
  var desktopPortalTargetOriginY:Double?
  var desktopPortalTargetWidth:Double?
  var desktopPortalTargetHeight:Double?
  var desktopMapRevision:UInt64?
  var desktopGlobalX:Double?
  var desktopGlobalY:Double?
  // Separately negotiated: old map peers intentionally discard system gestures.
  var desktopGestureCodec:Int? = nil
  var displayPreferenceCodec:Int? = nil
  var displayPreference:Bool? = nil
  var desktopGestureTargetID:UInt32? = nil
}
struct DesktopSystemGestureTarget:Equatable {
  let revision:UInt64
  let displayID:UInt32
  static func attach(_ input:Wire,desktop:ReceiverDesktop,revision:UInt64,point:CGPoint)->Wire? {
    guard input.kind=="dock",desktop.valid,desktop.revision==revision,revision>0,
      let display=desktop.displays.first(where:{ReceiverDesktop.has($0.bounds,point)}) else{return nil}
    var w=input;w.desktopMapRevision=revision;w.desktopGlobalX=Double(point.x);w.desktopGlobalY=Double(point.y);w.desktopGestureTargetID=display.id;return w
  }
  static func resolve(_ w:Wire,desktop:ReceiverDesktop,revision:UInt64,previous:CGPoint)->Self? {
    guard w.kind=="dock",let point=DesktopHandoffRouting.point(w,desktop:desktop,revision:revision),point==previous,
      let id=w.desktopGestureTargetID,let display=desktop.displays.first(where:{$0.id==id}),ReceiverDesktop.has(display.bounds,point) else{return nil}
    return Self(revision:revision,displayID:id)
  }
  static func continues(phase:Int,requested:Self,current:Self?)->Bool {
    if phase==1{return current==nil}
    return [2,4,8].contains(phase) && current==requested
  }
}
// Pure adapter shared by production routing and no-input-post tests.
enum DesktopHandoffRouting {
  static func beginFrame(session:String,token:String,portal:DesktopPortal,entry:CGPoint,revision:UInt64)->Wire {
    Wire(kind:"begin",session:session,sequence:0,y:0,token:token,edge:.right,
      screenWidth:portal.sourceRect.width,screenHeight:portal.sourceRect.height,layoutY:0,
      desktopPortalSide:portal.sourceSide.rawValue,desktopPortalTargetID:portal.displayID,
      desktopPortalIntervalStart:portal.intervalStart,desktopPortalIntervalEnd:portal.intervalEnd,
      desktopPortalSourceOriginX:portal.sourceRect.minX,desktopPortalSourceOriginY:portal.sourceRect.minY,
      desktopPortalSourceWidth:portal.sourceRect.width,desktopPortalSourceHeight:portal.sourceRect.height,
      desktopPortalTargetOriginX:portal.targetRect.minX,desktopPortalTargetOriginY:portal.targetRect.minY,
      desktopPortalTargetWidth:portal.targetRect.width,desktopPortalTargetHeight:portal.targetRect.height,
      desktopMapRevision:revision,desktopGlobalX:entry.x,desktopGlobalY:entry.y)
  }
  static func point(_ w:Wire,desktop:ReceiverDesktop,revision:UInt64)->CGPoint? {
    guard desktop.valid,revision>0,desktop.revision==revision,w.desktopMapRevision==revision,
      let x=w.desktopGlobalX,let y=w.desktopGlobalY else{return nil}
    let p=CGPoint(x:x,y:y)
    return desktop.contains(p) ? p:nil
  }
  static func portal(_ w:Wire,desktop:ReceiverDesktop,publishedRevision:UInt64)->DesktopPortal? {
    guard ["begin","return"].contains(w.kind),let entry=point(w,desktop:desktop,revision:publishedRevision),
      let side=w.desktopPortalSide,let id=w.desktopPortalTargetID,
      let sx=w.desktopPortalSourceOriginX,let sy=w.desktopPortalSourceOriginY,
      let sw=w.desktopPortalSourceWidth,let sh=w.desktopPortalSourceHeight,
      let tx=w.desktopPortalTargetOriginX,let ty=w.desktopPortalTargetOriginY,
      let tw=w.desktopPortalTargetWidth,let th=w.desktopPortalTargetHeight,
      let a=w.desktopPortalIntervalStart,let b=w.desktopPortalIntervalEnd else{return nil}
    let source=CGRect(x:sx,y:sy,width:sw,height:sh)
    guard ReceiverDesktop.sane(source),EdgeHandoff.dimensions(sw,sh),
      let canonical=desktop.portals(sourceRect:source).first(where:{$0.displayID==id && $0.sourceSide.rawValue==side}),
      canonical.targetRect==CGRect(x:tx,y:ty,width:tw,height:th),
      canonical.intervalStart==a,canonical.intervalEnd==b,
      canonical.targetPoint(fromSourceEdge:entry)==entry else{return nil}
    return canonical
  }
  static func returnFrame(session:String,token:String,portal:DesktopPortal,point:CGPoint,revision:UInt64)->Wire {
    var w=beginFrame(session:session,token:token,portal:portal,entry:portal.targetPoint(fromSourceEdge:point),revision:revision)
    w.kind="return";w.edge=nil;w.y=nil;w.screenWidth=nil;w.screenHeight=nil;w.layoutY=nil
    return w
  }
  static func returnPortal(_ w:Wire,desktop:ReceiverDesktop,revision:UInt64,sourceRect:CGRect)->DesktopPortal? {
    guard w.kind=="return",let portal=portal(w,desktop:desktop,publishedRevision:revision),portal.sourceRect==sourceRect else{return nil}
    return portal
  }
  static func reverse(desktop:ReceiverDesktop,sourceRect:CGRect,previous:CGPoint,delta:CGVector,held:Bool)->(DesktopPortal,CGPoint)? {
    for portal in desktop.portals(sourceRect:sourceRect) {
      if let p=reversePoint(portal:portal,previous:previous,delta:delta,held:held) {return (portal,p)}
    };return nil
  }
  static func moved(_ p:CGPoint,delta:CGVector,desktop:ReceiverDesktop)->CGPoint {
    desktop.moved(from:p,delta:delta)
  }
  static func eventPoint(_ w:Wire,desktop:ReceiverDesktop,revision:UInt64,previous:CGPoint,delta:CGVector,moving:Bool)->CGPoint? {
    guard desktop.contains(previous),let p=point(w,desktop:desktop,revision:revision),
      delta.dx.isFinite,delta.dy.isFinite else{return nil}
    let expected=moving ? moved(previous,delta:delta,desktop:desktop):previous
    return p==expected ? p:nil
  }
  static func reversePoint(portal:DesktopPortal,previous:CGPoint,delta:CGVector,held:Bool)->CGPoint? {
    let intended=CGPoint(x:previous.x+delta.dx,y:previous.y+delta.dy)
    guard !held,portal.isReverseCrossing(from:previous,to:intended) else{return nil}
    let vertical=portal.sourceSide == .left || portal.sourceSide == .right
    let edge:CGFloat
    switch portal.sourceSide {case .left:edge=portal.sourceRect.minX;case .right:edge=portal.sourceRect.maxX;case .top:edge=portal.sourceRect.minY;case .bottom:edge=portal.sourceRect.maxY}
    let u=(edge-(vertical ? previous.x:previous.y))/(vertical ? delta.dx:delta.dy)
    return portal.sourcePoint(fromTargetEdge:CGPoint(x:previous.x+delta.dx*u,y:previous.y+delta.dy*u))
  }
  static func localReturn(portal:DesktopPortal,point:CGPoint,bounds:CGRect)->CGPoint {
    let p=portal.sourcePoint(fromTargetEdge:point)
    // Re-clamp after translation: floating-point cancellation at negative
    // desktop origins must never produce a source max-edge coordinate.
    return CGPoint(x:min(max(bounds.minX+p.x-portal.sourceRect.minX,bounds.minX),bounds.maxX.nextDown),
      y:min(max(bounds.minY+p.y-portal.sourceRect.minY,bounds.minY),bounds.maxY.nextDown))
  }
}
// Opaque public CGEvent serialization; no private-field construction or shortcuts.
enum AppGestureCodec {
  static let maximumDataSize = 64 * 1024
  static var supported:Bool { systemBuildIdentifier() != nil }
  static func compatible(build:String?,codec:Int?)->Bool {
    supported && codec == 1 && build != nil && build == systemBuildIdentifier()
  }
  static func decode(_ w:Wire)->CGEvent? {
    guard w.kind == "appGesture",w.appGestureCodec == 1,
      let descriptor=w.appGesture,descriptor.valid,
      let id=w.appGestureID,UUID(uuidString:id)?.uuidString == id,
      let token=w.token,UUID(uuidString:token)?.uuidString == token,
      let x=w.x,let y=w.y,x.isFinite,y.isFinite,(0...1).contains(x),(0...1).contains(y),
      let raw=w.raw,[UInt32(29),30].contains(raw),
      let data=w.data,!data.isEmpty,data.count <= maximumDataSize,
      let event=CGEvent(withDataAllocator:nil,data:data as CFData),
      event.type.rawValue == raw,NativeGestureDescriptor.decode(event) == descriptor
    else{return nil}
    return event
  }
}

final class PairingReplayLedger {
  static let shared=PairingReplayLedger()
  private let lock=NSLock();private var seen:[String:Double]=[:]
  func consume(_ id:String,now:Double=ProcessInfo.processInfo.systemUptime)->Bool {lock.lock();defer{lock.unlock()};seen=seen.filter{now-$0.value<600};guard seen[id]==nil,seen.count<256 else{return false};seen[id]=now;return true}
}
func agreePairingScope(sendMode:Bool,localSession:String,send:(Data)throws->Void,receive:()throws->Data)throws->String {
  guard UUID(uuidString:localSession)?.uuidString==localSession else{throw Failure("Invalid local pairing scope")}
  let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
  if sendMode {try send(encoder.encode(["v":"5","kind":"pin-intro","role":"sender","pairingSession":localSession]));return localSession}
  let intro=try receive()
  guard intro.count<=256,let fields=try? JSONDecoder().decode([String:String].self,from:intro),Set(fields.keys)==Set(["v","kind","role","pairingSession"]),fields["v"]=="5",fields["kind"]=="pin-intro",fields["role"]=="sender",let scope=fields["pairingSession"],UUID(uuidString:scope)?.uuidString==scope,try encoder.encode(fields)==intro,PairingReplayLedger.shared.consume(scope) else{throw Failure("Invalid or replayed pairing introduction")}
  return scope
}
func derive(_ pass: String) -> SymmetricKey {
  HKDF<SHA256>.deriveKey(
    inputKeyMaterial: SymmetricKey(data: Data(pass.utf8)),
    salt: Data("ThunderControl.experimental.v5".utf8), info: Data("AES256GCM".utf8),
    outputByteCount: 32)
}
func connectionKey(_ key: SymmetricKey, sender: String, receiver: String, reverse: Bool = false)
  -> SymmetricKey
{
  HKDF<SHA256>.deriveKey(
    inputKeyMaterial: key, salt: Data((sender + receiver).utf8),
    info: Data(
      (reverse ? "ThunderControl.v5.receiver-to-sender" : "ThunderControl.v5.sender-to-receiver")
        .utf8), outputByteCount: 32)
}
func seal(_ w: Wire, _ k: SymmetricKey) throws -> Data {
  let d = try AES.GCM.seal(JSONEncoder().encode(w), using: k).combined!
  guard d.count <= cap else { throw Failure("Frame too large") }
  return d
}
func unseal(_ d: Data, _ k: SymmetricKey) throws -> Wire {
  guard d.count <= cap else { throw Failure("Frame too large") }
  return try JSONDecoder().decode(
    Wire.self, from: AES.GCM.open(AES.GCM.SealedBox(combined: d), using: k))
}
let standard: Set<UInt32> = [1, 2, 3, 4, 5, 6, 7, 10, 11, 12, 22, 25, 26, 27]
func allowed(_ t: UInt32, _ experimental: Bool) -> Bool {
  standard.contains(t) // Native DockSwipe uses its own bounded channel, not raw replay.
}
let positionalMouseTypes: Set<UInt32> = [1, 2, 3, 4, 5, 6, 7, 25, 26, 27]
func physicalInputsHeld() -> Bool {
  (0...255).contains { CGEventSource.keyState(.hidSystemState, key: CGKeyCode($0)) }
    || (0...31).contains { number in
      guard let button = CGMouseButton(rawValue: UInt32(number)) else { return false }
      return CGEventSource.buttonState(.hidSystemState, button: button)
    }
}
func validMouseCoordinates(_ w: Wire) -> Bool {
  if w.desktopMapRevision != nil || w.desktopGlobalX != nil || w.desktopGlobalY != nil {
    guard let r=w.desktopMapRevision,r>0,let x=w.desktopGlobalX,let y=w.desktopGlobalY else{return false}
    return x.isFinite && y.isFinite && abs(x)<=ReceiverDesktop.coordinateLimit && abs(y)<=ReceiverDesktop.coordinateLimit
  }
  guard let raw = w.raw, positionalMouseTypes.contains(raw) || raw == 22 else { return true }
  guard let x = w.x, let y = w.y else { return false }
  return x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y)
}
struct Validator {
  var session: String?
  var next: UInt64 = 0
  mutating func accept(_ w: Wire) throws {
    if session == nil {
      guard w.kind == "hello", w.sequence == 0, let id = UUID(uuidString: w.session),
        id.uuidString == w.session, w.data == nil
      else { throw Failure("Invalid hello") }
      session = w.session
      next = 1
    } else {
      guard w.session == session, w.sequence == next, w.kind == "event", next < UInt64.max else {
        throw Failure("Replay or invalid sequence")
      }
      next += 1
    }
  }
}
// Original experimental policy, not Apple's constants: 3px strip, 180ms outward
// dwell, 20px inward rearm, 1.5s transaction timeout. Single main display only.
enum Edge: String, Codable {
  case left, right
  var opposite: Edge { self == .left ? .right : .left }
  func distance(_ x: Double, _ width: Double) -> Double { self == .left ? x : width - 1 - x }
  func outward(_ dx: Double) -> Bool { self == .left ? dx < 0 : dx > 0 }
  func inset(_ width: Double) -> Double { self == .left ? 1 : width - 2 }
}
enum EdgeAction: Equatable { case none, begin, commit, activate, remote, restore, requestReturn }
struct EdgeHandoff {
  enum Phase: Equatable {
    case local, pending, committed, remote, targetReady, targetActive, returning
  }
  var phase: Phase = .local
  var token: String?
  var edge: Edge = .right
  var offset = 0.5
  var width = 1.0
  var height = 1.0
  var x = 0.0
  var y = 0.0
  var latched = true
  var dwell: Double?
  var deadline = 0.0
  var arrangement: ScreenArrangement?
  var entryY: Double?
  var activationDelay = 0.180
  var activationDistance = 3.0
  var rearmDistance = 20.0
  var startedAt = 0.0
  static func dimensions(_ w: Double, _ h: Double) -> Bool {
    w.isFinite && h.isFinite && (64...32768).contains(w) && (64...32768).contains(h)
  }
  mutating func reset() -> EdgeAction {
    self = EdgeHandoff(edge: edge)
    return .restore
  }
  mutating func tick(_ now: Double, preserveState: Bool = false) -> EdgeAction {
    if [.pending, .committed, .targetReady, .returning].contains(phase), now >= deadline {
      return preserveState ? .restore : reset()
    }
    return .none
  }
  mutating func motion(
    x px: Double, y py: Double, dx: Double, now: Double, held: Bool,
    w: Double, h: Double
  ) -> EdgeAction {
    guard Self.dimensions(w, h), px.isFinite, py.isFinite, dx.isFinite, px >= 0, px < w,
      py >= 0, py < h
    else { return .none }
    guard phase == .local || phase == .targetActive else { return .none }
    let distance = edge.distance(px, w)
    if distance >= rearmDistance { latched = false }
    if let arrangement {
      let connected =
        phase == .local ? arrangement.remoteY(sourceY: py) : arrangement.sourceY(remoteY: py)
      guard connected != nil else {
        dwell = nil
        return .none
      }
    }
    guard !latched, !held, distance <= activationDistance, edge.outward(dx) else {
      dwell = nil
      return .none
    }
    if dwell == nil { dwell = now }
    guard now - dwell! >= activationDelay else { return .none }
    dwell = nil
    latched = true
    if phase == .targetActive {
      phase = .returning
      deadline = now + 1.5
      return .requestReturn
    }
    phase = .pending
    startedAt = now
    token = UUID().uuidString
    offset = min(1, max(0, py / h))
    deadline = now + 1.5
    return .begin
  }
  mutating func begin(
    _ id: String, edge source: Edge, offset value: Double, enabled: Bool,
    w: Double, h: Double, now: Double, sourceSize: CGSize? = nil, layoutY: Double = 0
  ) -> EdgeAction {
    guard phase == .local, enabled, UUID(uuidString: id)?.uuidString == id,
      value.isFinite, (0...1).contains(value), Self.dimensions(w, h)
    else { return .none }
    if let sourceSize {
      let layout = ScreenArrangement(
        sourceSize: sourceSize, remoteSize: CGSize(width: w, height: h),
        remoteOnRight: source == .right, offsetY: layoutY)
      guard let mapped = layout.remoteY(sourceY: value * sourceSize.height) else { return .none }
      arrangement = layout
      activationDelay = 0
      activationDistance = 1
      rearmDistance = 2
      entryY = min(h - 1, max(0, mapped))
    }
    token = id
    edge = source.opposite
    offset = value
    width = w
    height = h
    phase = .targetReady
    deadline = now + 1.5
    return .activate
  }
  mutating func ready(_ id: String, w: Double, h: Double, now: Double) -> EdgeAction {
    guard phase == .pending, token == id, now < deadline, Self.dimensions(w, h) else {
      return .none
    }
    if let layout = arrangement {
      let verified = ScreenArrangement(
        sourceSize: layout.sourceSize, remoteSize: CGSize(width: w, height: h),
        remoteOnRight: layout.remoteOnRight, offsetY: layout.offsetY)
      guard let mapped = verified.remoteY(sourceY: offset * verified.sourceSize.height) else {
        return .none
      }
      arrangement = verified
      entryY = min(h - 1, max(0, mapped))
    }
    width = w
    height = h
    x = edge.opposite.inset(w)
    y = entryY ?? offset * (h - 1)
    phase = .committed
    return .commit
  }
  mutating func commit(_ id: String, now: Double) -> EdgeAction {
    guard phase == .targetReady, token == id, now < deadline else { return .none }
    phase = .targetActive
    latched = true
    x = edge.inset(width)
    y = entryY ?? offset * (height - 1)
    return .activate
  }
  mutating func active(_ id: String, now: Double) -> EdgeAction {
    guard phase == .committed, token == id, now < deadline else { return .none }
    phase = .remote
    return .remote
  }
  mutating func relative(_ dx: Double, _ dy: Double) {
    guard phase == .remote, dx.isFinite, dy.isFinite else { return }
    x = min(width - 1, max(0, x + dx))
    y = min(height - 1, max(0, y + dy))
  }
}
// Authenticated direction/role validation precedes main-thread dispatch. Counters
// include control and input alike; hello nonces are independently fresh UUIDs.
func sourceCursorReturnPoint(bounds: CGRect, edge: Edge, handoff: EdgeHandoff, xCarry:Double=0) -> CGPoint {
  let y =
    handoff.arrangement.map { handoff.y + $0.offsetY }
    ?? (min(1, max(0, handoff.offset)) * (bounds.height - 1))
  return CGPoint(
    x: bounds.minX + min(bounds.width-1,max(0,edge.inset(bounds.width)+xCarry)), y: bounds.minY + min(bounds.height - 1, max(0, y)))
}
struct PeerValidator {
  let senderPeer: Bool
  let session: String
  var next: UInt64 = 1
  var cursorVisibilitySupported=false
  var concurrentDisplaySupported=false
  var multiDisplayDesktopSupported=false
  var desktopGesturesSupported=false
  var displayPreferenceSupported=false
  mutating func accept(_ w: Wire) throws {
    guard w.session == session, w.sequence == next, next < UInt64.max else {
      throw Failure("Replay or sequence mismatch")
    }
    if w.kind == "displayPreference" {
      guard senderPeer,displayPreferenceSupported,DisplayPreferencePolicy.validEnvelope(w) else{throw Failure("Invalid display preference")}
      next += 1;return
    }
    guard w.displayPreference==nil,w.displayPreferenceCodec==nil else{throw Failure("Unexpected display preference fields")}
    let permitted =
      senderPeer
      ? (concurrentDisplaySupported ? ["displayPaused"]:[]) + ["event", "dock", "appGesture", "begin", "commit", "cancel", "returnAck", "ping"] + (cursorVisibilitySupported ? ["cursorMode"]:[])
      : (concurrentDisplaySupported ? ["displayPause","displayResume"]:[]) + ["ready", "active", "return", "cancel", "available"]
    guard permitted.contains(w.kind) else { throw Failure("Invalid packet role") }
    guard w.concurrentDisplayCodec == nil else{throw Failure("Unexpected display capability")}
    guard w.multiDisplayDesktopCodec == nil,w.desktopGestureCodec==nil else{throw Failure("Unexpected desktop coordinate capability")}
    if w.desktopGestureTargetID != nil {guard w.kind=="dock",senderPeer,multiDisplayDesktopSupported,desktopGesturesSupported,w.desktopGestureTargetID != 0 else{throw Failure("Unexpected system gesture target")}}
    if w.kind=="dock",multiDisplayDesktopSupported {guard desktopGesturesSupported,w.desktopGestureTargetID != nil,w.desktopMapRevision != nil,w.desktopGlobalX != nil,w.desktopGlobalY != nil else{throw Failure("System gesture target capability required")}}
    // Collect new 4-edge handoff fields; they are only valid on begin and
    // event packets when the new capability was negotiated. On any other
    // packet all must be nil.
    let hasDesktopPortalFields:Bool = w.desktopPortalSide != nil || w.desktopPortalTargetID != nil ||
      w.desktopPortalIntervalStart != nil || w.desktopPortalIntervalEnd != nil ||
      w.desktopPortalSourceOriginX != nil || w.desktopPortalSourceOriginY != nil ||
      w.desktopPortalSourceWidth != nil || w.desktopPortalSourceHeight != nil ||
      w.desktopPortalTargetOriginX != nil || w.desktopPortalTargetOriginY != nil ||
      w.desktopPortalTargetWidth != nil || w.desktopPortalTargetHeight != nil
    let hasDesktopGlobal:Bool = w.desktopGlobalX != nil || w.desktopGlobalY != nil
    let hasDesktopRevision:Bool = w.desktopMapRevision != nil
    if hasDesktopPortalFields || hasDesktopGlobal || hasDesktopRevision {
      guard multiDisplayDesktopSupported else { throw Failure("Desktop portal fields without capability") }
      guard w.kind == "begin" || w.kind == "event" || (w.kind == "dock" && desktopGesturesSupported) || (w.kind == "return" && !senderPeer) else { throw Failure("Desktop fields on invalid kind") }
    }
    if hasDesktopPortalFields {
      // Begin-only full portal attestation. All eight portal + two interval +
      // revision + global entry fields must be present and finite.
      guard w.kind == "begin" || (w.kind == "return" && !senderPeer),
        let side = w.desktopPortalSide, ["left","right","top","bottom"].contains(side),
        let tid = w.desktopPortalTargetID, tid != 0,
        let a = w.desktopPortalIntervalStart, a.isFinite,
        let b = w.desktopPortalIntervalEnd, b.isFinite, b > a,
        let sx = w.desktopPortalSourceOriginX, sx.isFinite,
        let sy = w.desktopPortalSourceOriginY, sy.isFinite,
        let sw = w.desktopPortalSourceWidth, sw.isFinite, sw >= 64,
        let sh = w.desktopPortalSourceHeight, sh.isFinite, sh >= 64,
        let tx = w.desktopPortalTargetOriginX, tx.isFinite,
        let ty = w.desktopPortalTargetOriginY, ty.isFinite,
        let tw = w.desktopPortalTargetWidth, tw.isFinite, tw >= 64,
        let th = w.desktopPortalTargetHeight, th.isFinite, th >= 64,
        w.desktopMapRevision != nil,
        let gx = w.desktopGlobalX, gx.isFinite,
        let gy = w.desktopGlobalY, gy.isFinite else { throw Failure("Incomplete desktop portal envelope") }
      _ = (side,tid,gx,gy)
    } else if hasDesktopGlobal || hasDesktopRevision {
      // Event path: both coords present, revision present.
      guard (w.kind == "event" || (w.kind == "dock" && desktopGesturesSupported)),
        let gx = w.desktopGlobalX, gx.isFinite,
        let gy = w.desktopGlobalY, gy.isFinite,
        w.desktopMapRevision != nil else { throw Failure("Incomplete desktop global coord") }
      _ = (gx,gy)
    }
    if w.kind == "return",multiDisplayDesktopSupported {
      guard !senderPeer,hasDesktopPortalFields,w.x==nil,w.y==nil,w.edge==nil,w.screenWidth==nil,w.screenHeight==nil,w.layoutY==nil,w.width==nil,w.height==nil else{throw Failure("Invalid authoritative desktop return")}
    }
    if ["displayPause","displayPaused","displayResume"].contains(w.kind) {
      guard concurrentDisplaySupported,let token=w.token,UUID(uuidString:token)?.uuidString==token,
        w.raw==nil,w.data==nil,w.x==nil,w.y==nil,w.os==nil,w.edge==nil,(w.kind == "displayResume" ? (w.width==0 || w.width==1):w.width==nil),w.height==nil,
        w.screenWidth==nil,w.screenHeight==nil,w.layoutY==nil,w.osBuild==nil,w.dock==nil,w.dockID==nil,
        w.appGesture==nil,w.appGestureID==nil,w.cursorMode==nil,w.cursorVisibilityCodec==nil,w.peerDisplayName==nil,w.receiverDesktopMap==nil,
        w.desktopPortalSide==nil,w.desktopPortalTargetID==nil,w.desktopPortalIntervalStart==nil,w.desktopPortalIntervalEnd==nil,
        w.desktopPortalSourceOriginX==nil,w.desktopPortalSourceOriginY==nil,w.desktopPortalSourceWidth==nil,w.desktopPortalSourceHeight==nil,
        w.desktopPortalTargetOriginX==nil,w.desktopPortalTargetOriginY==nil,w.desktopPortalTargetWidth==nil,w.desktopPortalTargetHeight==nil,
        w.desktopMapRevision==nil,w.desktopGlobalX==nil,w.desktopGlobalY==nil,
        (w.gestureCodec==nil || w.gestureCodec==0),(w.appGestureCodec==nil || w.appGestureCodec==0)
        else{throw Failure("Invalid display barrier envelope")}
    }
    guard w.cursorVisibilityCodec == nil else{throw Failure("Unexpected cursor codec outside hello")}
    if w.kind == "cursorMode" {guard cursorVisibilitySupported,w.cursorMode != nil,w.token == nil,w.dock == nil,w.dockID == nil,w.appGesture == nil,w.appGestureID == nil,w.x == nil,w.y == nil,w.width == nil,w.height == nil,w.edge == nil else{throw Failure("Invalid cursor mode")}}
    else {guard w.cursorMode == nil else{throw Failure("Unexpected cursor mode field")}}
    if w.kind != "appGesture" {
      guard w.appGesture == nil,w.appGestureID == nil else{throw Failure("Unexpected app gesture fields")}
    }
    guard w.appGestureCodec == nil || w.appGestureCodec == 0 || w.appGestureCodec == 1 else{throw Failure("Invalid app codec")}
    if w.kind == "appGesture" {
      guard AppGestureCodec.decode(w) != nil,w.dock == nil,w.dockID == nil else{throw Failure("Invalid app gesture envelope")}
    } else if w.kind == "event" {
      guard w.raw != nil, let d = w.data, !d.isEmpty,
        w.token == nil || UUID(uuidString: w.token!)?.uuidString == w.token
      else { throw Failure("Malformed input") }
      guard validMouseCoordinates(w) else {
        throw Failure("Missing or invalid destination mouse coordinates")
      }
    } else {
      guard w.data == nil, w.raw == nil else { throw Failure("Control contains input") }
      if w.kind != "available" && w.kind != "ping" && w.kind != "cursorMode" {
        guard let t = w.token, UUID(uuidString: t)?.uuidString == t else {
          throw Failure("Invalid transfer token")
        }
      }
      if w.kind == "dock" {
        guard let d=w.dock,DockTransferState.valid(d),let id=w.dockID,UUID(uuidString:id)?.uuidString==id else{throw Failure("Invalid system gesture envelope")}
      }
      if w.kind == "begin" {
        guard w.edge != nil, let y = w.y, y.isFinite, (0...1).contains(y),
          let sw = w.screenWidth, let sh = w.screenHeight, EdgeHandoff.dimensions(sw, sh),
          let ly = w.layoutY, ly.isFinite, abs(ly) <= 32768
        else {
          throw Failure("Invalid begin")
        }
      }
      if w.kind == "ready" {
        guard let a = w.width, let b = w.height, EdgeHandoff.dimensions(a, b) else {
          throw Failure("Invalid dimensions")
        }
      }
    }
    if w.kind == "available" {
      guard w.width == 0 || w.width == 1,
        let sw = w.screenWidth, let sh = w.screenHeight, EdgeHandoff.dimensions(sw, sh)
      else { throw Failure("Invalid consent/display state") }
      // Only the authenticated receiver carries the full desktop map, keyed
      // by role. Bounded tightly: the on-wire ReceiverDesktop JSON for the
      // maximum of eight displays easily fits well below 8 KiB.
      if let map = w.receiverDesktopMap {
        // Legacy 0.8.19 peers must never see a map, because they neither
        // advertise multiDisplayDesktopCodec=1 nor know how to validate the
        // encoded ReceiverDesktop. Fail closed if the bit is missing.
        guard !senderPeer, multiDisplayDesktopSupported, map.count <= 8192, !map.isEmpty else {
          throw Failure("Invalid receiver desktop envelope")
        }
      }
    } else {
      guard w.receiverDesktopMap == nil else { throw Failure("Unexpected desktop map") }
    }
    if w.kind != "begin" && w.kind != "available" {
      guard w.screenWidth == nil, w.screenHeight == nil, w.layoutY == nil else {
        throw Failure("Unexpected geometry fields")
      }
    }
    next += 1
  }
}
struct Bridge: Equatable {
  var name: String
  var index: UInt32
  var ip: String
}
func validateThunderboltMembers(_ members: Set<String>, _ hardware: Set<String>, active: Bool)
  throws
{
  guard active, !members.isEmpty, !hardware.isEmpty, members.isSubset(of: hardware) else {
    throw Failure(
      "Bridge must be active and contain only verified Thunderbolt IP hardware; no fallback")
  }
}
func thunderboltHardwareNames() throws -> Set<String> {
  var ports: io_iterator_t = 0
  guard
    IOServiceGetMatchingServices(
      kIOMainPortDefault, IOServiceMatching("AppleThunderboltIPPort"), &ports) == KERN_SUCCESS
  else {
    throw Failure("Cannot verify Thunderbolt hardware")
  }
  defer { IOObjectRelease(ports) }
  var names = Set<String>()
  while true {
    let port = IOIteratorNext(ports)
    if port == 0 { break }
    defer { IOObjectRelease(port) }
    var children: io_iterator_t = 0
    guard IORegistryEntryGetChildIterator(port, kIOServicePlane, &children) == KERN_SUCCESS else {
      continue
    }
    defer { IOObjectRelease(children) }
    while true {
      let child = IOIteratorNext(children)
      if child == 0 { break }
      defer { IOObjectRelease(child) }
      if let value = IORegistryEntryCreateCFProperty(
        child, "BSD Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
      {
        names.insert(value)
      }
    }
  }
  return names
}
func verifyThunderboltBridge(_ name: String) throws {
  guard name == "bridge0" else { throw Failure("Only bridge0 is supported") }
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
  process.arguments = [name]
  let pipe = Pipe()
  process.standardOutput = pipe
  process.standardError = FileHandle.nullDevice
  try process.run()
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  guard process.terminationStatus == 0, data.count < 65536,
    let text = String(data: data, encoding: .utf8)
  else {
    throw Failure("Cannot verify bridge membership")
  }
  var members = Set<String>()
  var active = false
  for line in text.components(separatedBy: .newlines) {
    let words = line.split(whereSeparator: { $0.isWhitespace })
    if words.count >= 2, words[0] == "member:" { members.insert(String(words[1])) }
    if words.count == 2, words[0] == "status:", words[1] == "active" { active = true }
  }
  try validateThunderboltMembers(members, thunderboltHardwareNames(), active: active)
}
func bridge(_ name: String) throws -> Bridge {
  try verifyThunderboltBridge(name)
  guard !name.isEmpty, name == "bridge0", name.utf8.count < IFNAMSIZ else {
    throw Failure("Only an explicit bridge interface is permitted")
  }
  var list: UnsafeMutablePointer<ifaddrs>?
  guard getifaddrs(&list) == 0 else { throw Failure("getifaddrs failed") }
  defer { freeifaddrs(list) }
  var p = list
  while let a = p {
    defer { p = a.pointee.ifa_next }
    let v = a.pointee
    guard String(cString: v.ifa_name) == name, let addr = v.ifa_addr,
      Int32(addr.pointee.sa_family) == AF_INET, (v.ifa_flags & UInt32(IFF_UP)) != 0,
      (v.ifa_flags & UInt32(IFF_RUNNING)) != 0
    else { continue }
    var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    var sin = UnsafeRawPointer(addr).assumingMemoryBound(to: sockaddr_in.self).pointee
    inet_ntop(AF_INET, &sin.sin_addr, &host, socklen_t(host.count))
    let ip = String(cString: host)
    guard !ip.hasPrefix("127."), ip != "0.0.0.0" else { continue }
    return Bridge(name: name, index: if_nametoindex(name), ip: ip)
  }
  throw Failure("Named bridge is not running with IPv4; no fallback")
}
func address(_ ip: String, _ port: UInt16) throws -> sockaddr_in {
  var a = sockaddr_in()
  a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  a.sin_family = sa_family_t(AF_INET)
  a.sin_port = port.bigEndian
  guard inet_pton(AF_INET, ip, &a.sin_addr) == 1, ip != "0.0.0.0", !ip.hasPrefix("127."),
    !(224...255).contains(Int(ip.split(separator: ".").first ?? "0") ?? 0), ip != "255.255.255.255"
  else { throw Failure("Enter a unicast IPv4 address") }
  return a
}
func boundSocket(_ b: Bridge, _ port: UInt16) throws -> Int32 {
  let fd = socket(AF_INET, SOCK_STREAM, 0)
  guard fd >= 0 else { throw Failure("socket failed") }
  do {
    var idx = b.index
    guard idx > 0 else { throw Failure("Invalid bridge interface index") }
    guard
      setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &idx, socklen_t(MemoryLayout.size(ofValue: idx))) == 0
    else { throw Failure("IP_BOUND_IF failed") }
    var one: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, 4)
    _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, 4)
    var a = try address(b.ip, port)
    let r = withUnsafePointer(to: &a) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard r == 0 else { throw Failure("Bridge address bind failed: \(errno)") }
    return fd
  } catch {
    close(fd)
    throw error
  }
}
func readExact(_ fd: Int32, _ n: Int) throws -> Data {
  var d = Data(count: n)
  try d.withUnsafeMutableBytes { b in
    var o = 0
    while o < n {
      let r = recv(fd, b.baseAddress!.advanced(by: o), n - o, 0)
      if r == 0 { throw Failure("Peer closed the TCP connection (EOF)") }
      if r < 0 {
        let code = errno
        if code == EINTR { continue }
        if code == EAGAIN || code == EWOULDBLOCK {
          throw Failure("Receive timed out waiting for peer frame")
        }
        throw Failure("Receive failed: errno=\(code)")
      }
      o += r
    }
  }
  return d
}
func readFrame(_ fd: Int32, maximum:Int=cap) throws -> Data {
  let h = try readExact(fd, 4)
  let n = h.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
  guard n > 0, n <= maximum else { throw Failure("Invalid frame length") }
  return try readExact(fd, Int(n))
}
func sendFrame(_ fd: Int32, _ d: Data) throws {
  guard !d.isEmpty, d.count <= cap else { throw Failure("Invalid frame length") }
  var n = UInt32(d.count).bigEndian
  var f = withUnsafeBytes(of: &n) { Data($0) }
  f.append(d)
  try f.withUnsafeBytes { b in
    var o = 0
    while o < f.count {
      let r = send(fd, b.baseAddress!.advanced(by: o), f.count - o, 0)
      if r < 0 && errno == EINTR { continue }
      guard r > 0 else { throw Failure("Send failed: errno=\(errno)") }
      o += r
    }
  }
}

final class OwnedSocket {
  let fd: Int32
  init(_ fd: Int32) { self.fd = fd }
  func interrupt() { _ = shutdown(fd, SHUT_RDWR) }
  deinit { close(fd) }
}
final class SessionContext {
  private let lock = NSLock()
  private var stopped = false
  private var authStartedAt:Double?
  private var authenticationCompleted=false
  let fastRoute:Bool
  var authenticationTimeoutReason:String {fastRoute ? "Fast route budget expired":"Pairing timeout"}
  func beginAuthentication(){
    lock.lock();authStartedAt=ProcessInfo.processInfo.systemUptime;lock.unlock()
    if fastRoute {DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+3.01) {[weak self] in self?.cancel(reason:"Fast route budget expired",onlyIfAuthenticationExpired:true)}}
  }
  private func authenticationExpiredLocked(now:Double)->Bool {guard !authenticationCompleted,let start=authStartedAt else{return false};return now-start >= (fastRoute ? 3:90)}
  func authenticationExpired(now:Double)->Bool{lock.lock();defer{lock.unlock()};return authenticationExpiredLocked(now:now)}
  func finishAuthentication(now:Double)->Bool {
    lock.lock();defer{lock.unlock()}
    guard !stopped,!authenticationCompleted,authStartedAt != nil,!authenticationExpiredLocked(now:now) else{return false}
    authenticationCompleted=true;return true
  }
  private var reason: String?
  var terminalReason: String? {lock.lock();defer{lock.unlock()};return reason}
  private var sockets: [OwnedSocket]
  init(_ initial: OwnedSocket,fastRoute:Bool=false) { self.fastRoute=fastRoute;sockets = [initial] }
  var cancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return stopped
  }
  func add(_ socket: OwnedSocket) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !stopped else {
      socket.interrupt()
      return false
    }
    sockets.append(socket)
    return true
  }
  func cancel(reason value:String = "Session cancelled",onlyIfAuthenticationExpired:Bool=false) {
    lock.lock()
    if onlyIfAuthenticationExpired && !authenticationExpiredLocked(now:ProcessInfo.processInfo.systemUptime) {lock.unlock();return}
    guard !stopped else{lock.unlock();return}
    reason=value;stopped=true
    let current=sockets
    lock.unlock()
    connectionLog("First transport termination: \(value)")
    for socket in current{socket.interrupt()}
  }
}
func connectBound(_ socket: OwnedSocket, _ address: sockaddr_in, _ context: SessionContext,timeout:Double=5) throws {
  let fd = socket.fd
  let flags = fcntl(fd, F_GETFL)
  guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
    throw Failure("Nonblocking connect setup failed")
  }
  defer { _ = fcntl(fd, F_SETFL, flags) }
  var a = address
  let result = withUnsafePointer(to: &a) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
  }
  if result == 0 { return }
  guard errno == EINPROGRESS else { throw Failure("Connect failed") }
  let connectDeadline=ProcessInfo.processInfo.systemUptime+timeout
  while ProcessInfo.processInfo.systemUptime<connectDeadline {
    guard !context.cancelled else { throw Failure("Cancelled") }
    var state = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    let remaining=max(1,min(200,Int((connectDeadline-ProcessInfo.processInfo.systemUptime)*1000)))
    let ready = poll(&state, 1, Int32(remaining))
    if ready < 0 {
      if errno == EINTR { continue }
      throw Failure("Connect poll failed")
    }
    if ready > 0 {
      var error: Int32 = 0
      var size = socklen_t(MemoryLayout<Int32>.size)
      guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
        throw Failure("Connect failed")
      }
      return
    }
  }
  throw Failure("Connect timed out")
}
func acceptBound(_ listener: OwnedSocket, _ context: SessionContext) throws -> OwnedSocket {
  let fd = listener.fd
  guard listen(fd, 1) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
    throw Failure("Listen failed")
  }
  while !context.cancelled {
    var state = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    let ready = poll(&state, 1, 200)
    if ready < 0 {
      if errno == EINTR { continue }
      throw Failure("Accept poll failed")
    }
    guard ready > 0 else { continue }
    let accepted = accept(fd, nil, nil)
    if accepted < 0 {
      if errno == EAGAIN || errno == EINTR { continue }
      throw Failure("Accept failed")
    }
    let socket = OwnedSocket(accepted)
    guard context.add(socket) else { throw Failure("Cancelled") }
    return socket
  }
  throw Failure("Cancelled")
}

// Pure source ownership: only accepted AND locally suppressed downs belong here.
struct RemoteInputOwnership {
  enum Input: Hashable {
    case key(UInt16)
    case button(Int64)
    case modifier(UInt16)
  }
  var owned = Set<Input>()
  var orphans = Set<Input>()
  var pendingReturn: String?
  var ambiguousModifiers = Set<UInt64>()
  var blocked: Bool { !orphans.isEmpty || !ambiguousModifiers.isEmpty }
  mutating func quarantineModifierGroup(_ code: CGKeyCode) {
    if let d = modifierDescriptors[code] { ambiguousModifiers.insert(d.aggregate.rawValue) }
  }
  mutating func reconcileModifierGroups(_ code: CGKeyCode?, flags: CGEventFlags) -> Bool {
    let consume =
      code.flatMap { modifierDescriptors[$0]?.aggregate.rawValue }.map {
        ambiguousModifiers.contains($0)
      } ?? false
    for group in Array(ambiguousModifiers) where modifierGroupIsUp(group, flags: flags) {
      ambiguousModifiers.remove(group)
      orphans = Set(
        orphans.filter { input in
          if case .modifier(let key) = input {
            return modifierDescriptors[key]?.aggregate.rawValue != group
          }
          return true
        })
    }
    return consume
  }
  mutating func accepted(_ input: Input?, down: Bool, suppressed: Bool) {
    guard suppressed, let input else { return }
    if down { owned.insert(input) } else { owned.remove(input) }
  }
  mutating func force() {
    orphans.formUnion(owned)
    owned.removeAll()
    pendingReturn = nil
  }
  mutating func filter(_ input: Input?, down: Bool, repeatKey: Bool) -> Bool {
    guard let input, orphans.contains(input) else { return false }
    if !down {
      orphans.remove(input)
      return true
    }
    if repeatKey { return true }
    // A new nonrepeat down proves a missed old release. Do not eat the new press.
    orphans.remove(input)
    return false
  }
  mutating func request(_ token: String, current: String?, remote: Bool) {
    if remote && token == current { pendingReturn = token }
  }
  func ready(_ token: String?, held: Bool) -> Bool {
    pendingReturn != nil && pendingReturn == token && owned.isEmpty && !held
  }
}
let heldModifierMask: CGEventFlags = [
  .maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn,
]
let modifierFlags = modifierDescriptors.mapValues { $0.aggregate }

func acceptsToken(_ handoff: EdgeHandoff, _ token: String) -> Bool {
  handoff.token == token && [.targetActive, .returning].contains(handoff.phase)
}
func returnTimeoutMustCancel(_ phase: EdgeHandoff.Phase) -> Bool { phase == .returning }

final class Relay {
  let gestureTrace=GestureTrace(persistSystemLog:false,recordingInitially:true,continuous:true,sink:{line in
    guard !CommandLine.arguments.contains("--self-test"),!CommandLine.arguments.contains("--pairing-integration-test"),!CommandLine.arguments.contains("--ui-smoke-test"),!CommandLine.arguments.contains("--ui-ownership-test") else{return}
    DiagnosticStore.shared.recordGesture(line)
  })
  var gestureDebugConfiguration:String {"auto=\(auto) inject=\(inject) systemOptIn=\(experimental) appOptIn=\(appGestureExperimental) systemCompatible=\(gestureCompatible) appCompatible=\(appGestureCompatible) receiverInput=\(receiverAvailable) receiverSystem=\(receiverGestureAvailable) receiverApp=\(receiverAppGestureAvailable) invertVertical=\(invertVerticalSystemGestures) invertHorizontal=\(invertHorizontalSystemGestures) cursorModeSupported=\(cursorVisibilityCompatible) receiverHideOwned=\(receiverCursor.isHidden) receiverLocalOverride=\(receiverCursorLocalOverride) phase=\(handoff.phase)"}
  var changed: ((String) -> Void)?
  var bridgeBecameUnavailable:(()->Void)?
  var forward = false
  var inject = false
  var experimental = true
  var appGestureExperimental = true
  private var appGestureCompatible = false
  private var receiverAppGestureAvailable = false
  private var sourceGesture = SourceGestureState()
  private var receiverAppGesture = ReceiverGestureState()
  func configureAppGestures(_ enabled:Bool) {
    if enabled != appGestureExperimental && (sourceGesture.remoteActive || receiverAppGesture.active) {
      stop(reason:"App gesture consent revoked; lift fingers before reconnecting")
    }
    appGestureExperimental = enabled
    if !sender && authenticated { _ = control("available",width:inject ? 1 : 0) }
    if enabled {status(appGestureCompatible ? "Experimental app gesture codec enabled; native behavior unverified. Real two-Mac testing required." : "App gesture codec disabled: matching exact OS builds and peer codec required.")}
  }
  let invertVerticalSystemGestures=true
  let invertHorizontalSystemGestures=true
  var systemGestureActive:Bool {dockReceiver.active}
  private(set) var automaticSuspensionEpoch:UInt64=0
  var automaticReconnectSuspended=false {didSet {if automaticReconnectSuspended {automaticSuspensionEpoch &+= 1;automaticSuspensionOrigin = .independent}}}
  private(set) var automaticSuspensionOrigin:SessionSuspensionOrigin = .independent
  var sessionTransitionSuspended:((UInt64)->Void)?
  var auto = false
  var selectedEdge: Edge = .right
  private var handoff = EdgeHandoff()
  private var ownership = RemoteInputOwnership()
  private var streamFlags: CGEventFlags = []
  var authenticatedLocalIsSender:Bool {sender}
  var inputIsSender:Bool {sender}
  private(set) var authenticatedDevicePair:LayoutDevicePair?
  private(set) var authenticatedSharingPeerHost:String?
  var automaticInputSharingPermitted:((LayoutDevicePair,Bool)->Bool)?
  var sharingEmergencyStopped:(()->Void)?
  private(set) var displayPreferenceCompatible=false
  private(set) var peerDisplayPreference:Bool?
  var displayPreferenceChanged:((Bool)->Void)?
  @discardableResult func sendDisplayPreference(_ enabled:Bool)->Bool {
    guard authenticated,sender,displayPreferenceCompatible else{return false}
    return enqueue(Wire(kind:"displayPreference",session:session,sequence:0,displayPreference:enabled))
  }
  var sharingLifecyclePairForTests:LayoutDevicePair? {get{authenticatedDevicePair} set{authenticatedDevicePair=newValue}}
  var sharingLifecycleCapabilityForTests:Bool {get{displayPreferenceCompatible} set{displayPreferenceCompatible=newValue}}
  var sharingReadinessSummary:String {"sender=\(sender) auto=\(auto) inject=\(inject) receiverAvailable=\(receiverAvailable) geometry=\(remoteDisplaySize != nil) desktop=\(receiverDesktop != nil) origin=\(sourceOrigin != nil) peerVideo=\(peerDisplayPreference.map(String.init) ?? "none") compatible=\(displayPreferenceCompatible)"}
  private func automaticSharingInputAllowed(_ sending:Bool)->Bool {
    guard let pair=authenticatedDevicePair else{return automaticInputSharingPermitted == nil}
    return automaticInputSharingPermitted?(pair,sending) != false
  }
  func restoreSavedSharingAutoIfReady() {
    guard authenticated,sender,receiverAvailable,sessionAllowed,!automaticReconnectSuspended,!lockedTransportOnly,
      !hasUnresolvedLocalRecovery,!displayTopologyTransitionActive,!ownership.blocked,dockOrphanMotion==nil,
      !sourceGesture.blockAuto,cursorResources.canAcquire,topologyUnchanged(),inputPermissionsReady() else{return}
    if multiDisplayDesktopCompatible {
      guard let map=receiverDesktop,map.valid,let origin=sourceOrigin,let bounds=topology?.bounds,
        !map.portals(sourceRect:CGRect(origin:origin,size:bounds.size)).isEmpty else{return}
    } else {
      guard let size=remoteDisplaySize,let bounds=topology?.bounds,
        ScreenArrangement(sourceSize:bounds.size,remoteSize:size,remoteOnRight:selectedEdge == .right,offsetY:layoutOffsetY).isValid else{return}
    }
    configureAuto(true,edge:selectedEdge)
  }
  func restoreSavedSharingForwardIfReady() {
    guard authenticated,sender,receiverAvailable,sessionAllowed,!automaticReconnectSuspended,!lockedTransportOnly,
      !hasUnresolvedLocalRecovery,!displayTopologyTransitionActive,inputPermissionsReady(),NSApp.isActive else{return}
    forward=true
  }
  private var concurrentDisplayCompatible=false
  // Only ever true when both peers advertised multiDisplayDesktopCodec=1 in
  // the authenticated hello. Legacy 0.8.19 peers must stay on the single-
  // target coordinate protocol regardless of concurrentDisplayCodec state.
  #if TC_FRESH_RECEIVER_SAFETY
  private var multiDisplayDesktopCompatible=false {didSet {if oldValue != multiDisplayDesktopCompatible {displaySafetyRevision=UUID()}}}
  #else
  private var multiDisplayDesktopCompatible=false
  #endif
  private var desktopSystemGestureCompatible=false
  private var displayBarrier:ConcurrentDisplayBarrier?
  private var displayBarrierCompletion:((Result<Void,Error>)->Void)?
  private var displayLease:ConcurrentDisplayLease?
  private var sourceBarrierMapReady=false
  private var desktopFocusIntent:DesktopMapFocusIntent?
  private var sourceBarrierRevision:UInt64=0
  // Test-only hooks replace permission/foreground observation, never input injection.
  var desktopFocusSafetyForTests:(()->Bool)?
  var desktopFocusBeginForTests:((String)->Void)?
  var desktopFocusFlushForTests:(()->Bool)?
  var desktopFocusRemoteForTests:Bool {handoff.phase == .remote}
  var desktopFocusPendingForTests:Bool {handoff.phase == .pending}
  var desktopFocusPointForTests:CGPoint? {desktopGlobalPointer}
  func desktopPrepareFocusForTests(map:ReceiverDesktop,origin:CGPoint,point:CGPoint) {
    receiverDesktop=map;receiverDesktopAdoptedRevision=map.revision;sourceOrigin=origin
    auto=true;receiverAvailable=true;handoff.phase = .remote;desktopGlobalPointer=point;desktopHandoffRevision=map.revision
  }
  private var desktopFocusSafety:Bool {desktopFocusSafetyForTests?() ?? (inputPermissionsReady() && NSApp.isActive && currentSessionBlockReason(forceRefresh:true)==nil && sourceOwnershipConfirmed?()==true)}
  /// Unmarked follow-through while the peer is rearranging is still remote
  /// intent. Quarantine it without posting locally or forwarding stale geometry.
  @discardableResult func drainDesktopPauseInput(type:CGEventType,code:CGKeyCode=0,button:Int64=0,flags:CGEventFlags=[])->Bool {
    guard sender,desktopFocusIntent != nil,displayBarrier != nil else{return false}
    let input:RemoteInputOwnership.Input?,down:Bool
    if type == .keyDown || type == .keyUp {
      input = .key(code);down = type == .keyDown
      if down {localKeys.insert(code)} else{localKeys.remove(code)}
    } else if [1,2,3,4,25,26].contains(type.rawValue) {
      input = .button(button);down = [1,3,25].contains(type.rawValue)
      if down {localButtons.insert(button)} else{localButtons.remove(button)}
    } else if type == .flagsChanged,modifierDescriptors[code] != nil {
      input = .modifier(code);down=modifierDown(code,flags:flags) ?? false
    } else {input=nil;down=false}
    if let input {if down {ownership.orphans.insert(input)} else{ownership.orphans.remove(input)}}
    _ = ownership.reconcileModifierGroups(type == .flagsChanged ? code:nil,flags:flags)
    localFlags=flags.intersection(heldModifierMask)
    return true
  }
  private func cancelDesktopFocusRestore() {
    desktopFocusIntent=nil
    displayBarrier?.savedAuto=false;displayBarrier?.savedForward=false
  }
  private var receiverOwnsMapTransition=false
  private var receiverMapPublicationCandidate:ReceiverDesktop?
  // Narrow dependency seams: production always uses native reads and monotonic time.
  var desktopMapReadForTests:((UInt64,CGDirectDisplayID?)->ReceiverDesktop?)?
  var desktopBaselineReadForTests:(()->DisplayBaseline?)?
  var desktopClockForTests:(()->Double)?
  var desktopEnqueueForTests:((Wire)->Bool)?
  var desktopPhysicalInputsForTests:(()->Bool)?
  var desktopInputPermissionForTests:(()->Bool)?
  var desktopInputPostForTests:((CGEvent)->Void)?
  private var inputTimingGeneration:UUID?
  private var inputQueueTiming=DisplayTimingStats(),inputMapTiming=DisplayTimingStats(),inputPostTiming=DisplayTimingStats()
  private var inputTimingLoggedAt:Double=0
  private func prepareInputTiming() {
    if inputTimingGeneration != generation {
      inputTimingGeneration=generation;inputQueueTiming=DisplayTimingStats();inputMapTiming=DisplayTimingStats();inputPostTiming=DisplayTimingStats()
      inputTimingLoggedAt=ProcessInfo.processInfo.systemUptime
    }
  }
  private func noteInputQueue(_ w:Wire,queuedAt:Double) {
    guard !sender,w.kind=="event",let raw=w.raw,[UInt32(5),6,7,27].contains(raw) else{return}
    prepareInputTiming();inputQueueTiming.record((ProcessInfo.processInfo.systemUptime-queuedAt)*1000)
  }
  private func noteMousePost(_ raw:UInt32,startedAt:Double) {
    guard !sender,[UInt32(5),6,7,27].contains(raw) else{return}
    prepareInputTiming();let now=ProcessInfo.processInfo.systemUptime
    inputPostTiming.record((now-startedAt)*1000)
    if now-inputTimingLoggedAt>=2 {
      inputTimingLoggedAt=now
      connectionLog("Input receiver timing: mainQueue[\(inputQueueTiming.summary)] freshMap[\(inputMapTiming.summary)] receiveToPost[\(inputPostTiming.summary)]; hostLocal=true networkAndPhysicalCursorLatencyUnmeasured=true")
    }
  }
  var desktopGenerationForTests:UUID {generation}
  var desktopSourceReadForTests:(()->DisplayTopologySnapshot?)?
  private var desktopNow:Double {desktopClockForTests?() ?? ProcessInfo.processInfo.systemUptime}
  private func freshReceiverDesktop(_ revision:UInt64)->ReceiverDesktop? {
    if let read=desktopMapReadForTests {return read(revision,displayLease?.ownedID)}
    return try? readReceiverDesktop(revision:revision,virtualDisplayID:displayLease?.ownedID)
  }
  private func freshDisplayBaseline()->DisplayBaseline? {
    if let read=desktopBaselineReadForTests {return read()};return DisplayBaseline.read()
  }
  private func adoptReceiverMain(_ map:ReceiverDesktop)throws {
    guard map.valid,let main=map.displays.first(where:{$0.id==map.mainID}) else{throw Failure("Invalid receiver desktop")}
    topology=DisplayTopologySnapshot(mainID:map.mainID,activeIDs:map.displays.map{$0.id}.sorted(),bounds:main.bounds)
    displayBounds=main.bounds
  }
  private func stableReceiverDesktop()->ReceiverDesktop? {
    guard let first=freshReceiverDesktop(max(1,receiverDesktopPublishRevision)),
      let second=freshReceiverDesktop(max(1,receiverDesktopPublishRevision)),first.valid,first==second else{return nil}
    return second
  }
  // Called before timer topology enforcement and before any received input can post.
  @discardableResult private func detectReceiverMapTransition()->Bool {
    guard !sender,authenticated,multiDisplayDesktopCompatible else{return false}
    if displayBarrier != nil {return true}
    guard receiverDesktopPublishedFingerprint != nil else{return false}
    if let fresh=freshReceiverDesktop(max(1,receiverDesktopPublishRevision)),fresh.valid,
      desktopFingerprintForPublication(fresh)==receiverDesktopPublishedFingerprint {return false}
    startReceiverDisplayPause(ownedByMap:true,completion:nil)
    return true
  }
  private func startReceiverDisplayPause(ownedByMap:Bool,completion:((Result<Void,Error>)->Void)?) {
    let barrier=ConcurrentDisplayBarrier(phase:.awaitingAck,now:desktopNow,consent:inject)
    receiverOwnsMapTransition=ownedByMap;displayBarrier=barrier;displayBarrierCompletion=completion;inject=false
    forceLocal()
    guard !hasUnresolvedLocalRecovery else{abortDisplayTopologyTransition();return}
    // No new desktop may be published while the source is still draining.
    _ = control("displayPause",token:barrier.token)
  }
  private var displayBarrierTokens=ConcurrentDisplayNonceCache()
  private var displayRemoteGeometryTemporary=false
  private var displayRemoteOriginalLayout:(Edge,Double)?
  var displayTopologyTransitionActive:Bool {displayBarrier != nil}
  /// Public read-only view of the negotiated 0.8.20 multi-target desktop
  /// capability. The owned-helper video flow is gated on both peers being
  /// 0.8.20; legacy single-target input relay still works to 0.8.19 peers.
  var multiDisplayDesktopReady:Bool { multiDisplayDesktopCompatible }
  var authenticatedPeerDisplayName:String?
  var authenticated:Bool {connection != nil && key != nil}
  var hasSession: Bool { context != nil }
  var hasUnresolvedLocalRecovery: Bool { ownership.blocked || cursorResources.needsRecovery || receiverCursor.needsRecovery || receiverFocusRecoveryPending?() == true }
  var receiverCursorFocusOwned:(()->Bool)?
  var receiverFocusRecoveryPending:(()->Bool)?
  var cancelReceiverCursorFocus:(()->Void)?
  var receiverLocalUserIntent:(()->Void)?
  var prepareReceiverInputTarget:((@escaping ()->Bool,@escaping (Bool)->Void)->Void)?
  private var receiverActivationPendingToken:String?
  private var receiverActivationDeadline:Double?
  var requestReceiverCursorFocus:(()->Void)?
  var releaseReceiverCursorFocus:(()->Void)?
  private var lastCursorDiagnostic=""
  var receiverFocusRetry=ReceiverFocusRetryPolicy()
  let receiverCursor:CursorVisibilityController
  private var cursorVisibilityCompatible=false
  private var sourceAutoCursorMode=false
  private var receiverCursorLocalOverride=false
  private var receiverAvailable = false
  #if TC_FRESH_RECEIVER_SAFETY
  var safetyObserversInstalled = false {didSet {if oldValue != safetyObserversInstalled {displaySafetyRevision=UUID()}}}
  #else
  var safetyObserversInstalled = false
  #endif
  private(set) var lockedTransportOnly=false
  #if TC_FRESH_RECEIVER_SAFETY
  var transportScreenLockObserved = false {didSet {if oldValue != transportScreenLockObserved {displaySafetyRevision=UUID()}}}
  #else
  var transportScreenLockObserved = false
  #endif
  var lockedTransportEligible:Bool {lockedTransportSessionAllowed(snapshot:readSystemSessionSnapshot(),lockedSignal:transportScreenLockObserved,systemSleeping:systemSleeping,observersInstalled:safetyObserversInstalled)}
  #if TC_FRESH_RECEIVER_SAFETY
  var sessionLockedSignal = false {didSet {if oldValue != sessionLockedSignal {displaySafetyRevision=UUID()}}}
  #else
  var sessionLockedSignal = false
  #endif
  #if TC_FRESH_RECEIVER_SAFETY
  var screenSleeping = false {didSet {if oldValue != screenSleeping {displaySafetyRevision=UUID()}}}
  #else
  var screenSleeping = false
  #endif
  #if TC_FRESH_RECEIVER_SAFETY
  var systemSleeping = false {didSet {if oldValue != systemSleeping {displaySafetyRevision=UUID()}}}
  #else
  var systemSleeping = false
  #endif
  private var sessionSnapshot = SessionSafetySnapshot(
    onConsole: nil, loginDone: nil, screenLocked: nil)
  private var lastSessionPoll = 0.0
  private var pendingForegroundToken: String?
  private var entryMotion=EntryMotionBuffer()
  private var returnMotion=ReturnMotionCarry()
  private var activationRestorePending=false
  private var returnStartedAt:Double?
  private var sourceReturnRestoredAt:Double?
  private var receiverReturnRequestAt:Double?
  private var sourceActivationCheckScheduled=false
  var approvePIN:((PINPairingRequest,@escaping()->Bool)throws->String)?
  var sourceOwnershipConfirmed:(()->Bool)?
  var lastStopReason=""
  var lastEnqueueFailure=""
  var requestSourceActivation: (() -> Void)?
  var restoreSourceActivation: (() -> Void)?
  var hasLocalInputsForAppearance:Bool {!localKeys.isEmpty || !localButtons.isEmpty || !localFlags.isEmpty}
  var appWindowPresentationPolicy:AppWindowPresentationPolicy {
    .init(sourceOwnsInput:sender && (isTransferring || forward),receiverInputReady:!sender && authenticated && handoff.phase == .targetActive && receiverActivationPendingToken == nil)
  }
  var isReceivingActiveInput:Bool {!sender && (handoff.phase == .targetActive || receiverActivationPendingToken != nil)}
  var isTransferring: Bool { sender && handoff.phase != .local }
  var awaitingSourceActivation: Bool { pendingForegroundToken != nil }
  #if TC_FRESH_RECEIVER_SAFETY
  private var displaySafetyRevision=UUID()
  func displaySafetyTicket(epoch:UUID)->DisplaySafetyTicket? {
    dispatchPrecondition(condition:.onQueue(.main))
    guard displaySafetyCurrent else{return nil}
    return DisplaySafetyTicket(relayGeneration:generation,safetyRevision:displaySafetyRevision,displayEpoch:epoch)
  }
  // Main-only gate. No native queries and no mutation of the input safety cache.
  private var displaySafetyCurrent:Bool {
    context != nil && context?.cancelled == false && authenticated && safetyObserversInstalled &&
      !sessionLockedSignal && !transportScreenLockObserved && !screenSleeping && !systemSleeping && multiDisplayDesktopReady
  }
  func displaySafetyTicketCurrent(_ ticket:DisplaySafetyTicket)->Bool {
    dispatchPrecondition(condition:.onQueue(.main))
    return displaySafetyCurrent && ticket.relayGeneration==generation && ticket.safetyRevision==displaySafetyRevision
  }
  static func verifyFreshDisplaySafetyForTests()->Bool {
    // Invalid descriptors and metadata only: no GUI, input, lock or sleep APIs.
    let r=Relay(),socket=OwnedSocket(-1)
    r.context=SessionContext(socket);r.connection=socket;r.key=SymmetricKey(size:.bits256)
    r.safetyObserversInstalled=true;r.multiDisplayDesktopCompatible=true
    let epoch=UUID(),now=ProcessInfo.processInfo.systemUptime
    let sample=FreshSessionSafetySample(snapshot:.init(onConsole:true,loginDone:true,screenLocked:false),secureInput:false,startedAt:now,snapshotFinishedAt:now,finishedAt:now)
    guard let ticket=r.displaySafetyTicket(epoch:epoch),r.sampledDisplaySessionPermitted(sample,ticket:ticket,now:now) else{return false}
    let unknown=FreshSessionSafetySample(snapshot:.init(onConsole:nil,loginDone:nil,screenLocked:nil),secureInput:false,startedAt:now,snapshotFinishedAt:now,finishedAt:now)
    guard !r.sampledDisplaySessionPermitted(unknown,ticket:ticket,now:now) else{return false}
    r.transportScreenLockObserved=true;r.transportScreenLockObserved=false
    guard !r.displaySafetyTicketCurrent(ticket),let transportUnlocked=r.displaySafetyTicket(epoch:epoch) else{return false}
    r.sessionLockedSignal=true
    guard !r.displaySafetyTicketCurrent(transportUnlocked) else{return false}
    r.sessionLockedSignal=false // ABA must not resurrect a fixed ticket.
    guard !r.sampledDisplaySessionPermitted(sample,ticket:ticket,now:now),let unlocked=r.displaySafetyTicket(epoch:epoch) else{return false}
    r.safetyObserversInstalled=false;r.safetyObserversInstalled=true
    guard !r.displaySafetyTicketCurrent(unlocked),let observed=r.displaySafetyTicket(epoch:epoch) else{return false}
    r.screenSleeping=true;r.screenSleeping=false
    guard !r.displaySafetyTicketCurrent(observed),let awake=r.displaySafetyTicket(epoch:epoch) else{return false}
    r.systemSleeping=true;r.systemSleeping=false
    guard !r.displaySafetyTicketCurrent(awake),let ready=r.displaySafetyTicket(epoch:epoch) else{return false}
    r.multiDisplayDesktopCompatible=false;r.multiDisplayDesktopCompatible=true
    guard !r.displaySafetyTicketCurrent(ready),let oldRun=r.displaySafetyTicket(epoch:epoch) else{return false}
    r.context?.cancel(reason:"fixture cancellation")
    guard !r.displaySafetyTicketCurrent(oldRun),r.displaySafetyTicket(epoch:epoch)==nil else{return false}
    r.context=SessionContext(socket)
    r.generation=UUID() // An old completion must not affect replacement context.
    guard !r.displaySafetyTicketCurrent(oldRun) else{return false}
    return true
  }
  func sampledDisplaySessionPermitted(_ sample:FreshSessionSafetySample,ticket:DisplaySafetyTicket,now:Double)->Bool {
    displaySafetyTicketCurrent(ticket) && sample.valid(at:now) &&
      sessionBlockReason(snapshot:sample.snapshot,lockedSignal:sessionLockedSignal,sleeping:screenSleeping || systemSleeping,secureInput:sample.secureInput)==nil
  }
  #endif
  var sessionAllowed: Bool { currentSessionBlockReason() == nil }
  func currentSessionBlockReason(forceRefresh: Bool = false) -> String? {
    let now = ProcessInfo.processInfo.systemUptime
    if forceRefresh || now - lastSessionPoll >= 0.02 {
      sessionSnapshot = readSystemSessionSnapshot()
#if TC_RENDERER_HEALTH
      DevelopmentDiagnostics.shared.record(stage: "relay_session_query", fields: [
        "elapsedMs": (ProcessInfo.processInfo.systemUptime - now) * 1000,
        "forced": forceRefresh ? 1 : 0
      ])
#endif
      lastSessionPoll = now
    }
    guard safetyObserversInstalled else { return "session safety monitor unavailable" }
    return sessionBlockReason(
      snapshot: sessionSnapshot, lockedSignal: sessionLockedSignal,
      sleeping: screenSleeping || systemSleeping,
      secureInput: isSystemSecureInputEnabled())
  }
  func safetyStop(_ reason:String) {automaticReconnectSuspended=true;stop(reason:reason)}
  static func verifySessionSuspensionOriginsForTests()->Bool {
    let r=Relay();var permit=SessionAutoResumePermit(),reports=0
    r.sessionTransitionSuspended={epoch in reports+=1;permit.adoptTransition(epoch:epoch)}
    r.suspendAutomaticForSession(.transition)
    let first=r.automaticSuspensionEpoch
    r.suspendAutomaticForSession(.transition)
    guard reports==2,r.automaticSuspensionEpoch==first else{return false}
    permit.observedUnlock();r.suspendAutomaticForSession(.transition)
    guard permit.permits(paused:false,epoch:first) else{return false}
    // Auth, emergency, permission, cursor and unknown foreground stops use the
    // independent setter. Secure Input alone no longer stops the connection.
    for _ in 0..<6 {
      r.automaticReconnectSuspended=true
      let independent=r.automaticSuspensionEpoch
      r.suspendAutomaticForSession(.transition)
      guard r.automaticSuspensionEpoch>independent,r.automaticSuspensionOrigin == .independent,
        !permit.permits(paused:false,epoch:r.automaticSuspensionEpoch) else{return false}
    }
    r.automaticReconnectSuspended=false;permit.revoke()
    r.suspendAutomaticForSession(.transition);permit.observedUnlock()
    guard permit.permits(paused:false,epoch:r.automaticSuspensionEpoch),!permit.permits(paused:true,epoch:r.automaticSuspensionEpoch) else{return false}
    permit.clearUnlockProof() // new sleep/resign/lock notification
    r.suspendAutomaticForSession(.transition)
    guard !permit.permits(paused:false,epoch:r.automaticSuspensionEpoch) else{return false}
    permit.observedUnlock();guard permit.permits(paused:false,epoch:r.automaticSuspensionEpoch) else{return false}
    print("PASS Relay lock polling-first, idempotent reports, new-transition proof reset, manual pause and independent blockers; no network/input")
    return true
  }
  var freshSessionSuspensionOrigin:SessionSuspensionOrigin {
    let fresh=readSystemSessionSnapshot()
    return screenSleeping || systemSleeping || fresh.screenLocked==true || fresh.onConsole==false || fresh.loginDone==false ? .transition:.independent
  }
  var polledSessionSuspensionOrigin:SessionSuspensionOrigin {
    // Repeated reports of an already-confirmed transition retain its permit.
    // The latch alone cannot adopt an existing independent suspension.
    if automaticReconnectSuspended,automaticSuspensionOrigin == .transition,sessionLockedSignal {return .transition}
    return freshSessionSuspensionOrigin
  }
  func suspendAutomaticForSession(_ origin:SessionSuspensionOrigin) {
    let old=automaticSuspensionOrigin,wasSuspended=automaticReconnectSuspended
    if wasSuspended,old == .transition,origin == .transition {
      sessionTransitionSuspended?(automaticSuspensionEpoch);return
    }
    let eligible=mayAdoptSessionTransition(suspended:wasSuspended,origin:old)
    automaticReconnectSuspended=true
    if origin == .transition,eligible {automaticSuspensionOrigin = .transition;sessionTransitionSuspended?(automaticSuspensionEpoch)}
  }
  func sessionBecameUnsafe(_ reason: String,origin:SessionSuspensionOrigin = .independent) {
    suspendAutomaticForSession(origin)
    if context != nil || auto || forward || inject {
      stop(reason:"Session safety: "+reason)
    }
    status(TCText("Safety stop: ") + reason + TCText(". Check the safety state, then click Connect or Resume Listening."))
  }
  func prepareSessionForExplicitStart() throws {
    guard NSApp.isActive else { throw Failure("Activate ThunderControl before starting a session") }
    let fresh = readSystemSessionSnapshot()
    guard
      sessionBlockReason(
        snapshot: fresh, lockedSignal: false, sleeping: screenSleeping || systemSleeping,
        secureInput: isSystemSecureInputEnabled()) == nil
    else {
      throw Failure("Session is inactive, locked or asleep")
    }
    transportScreenLockObserved=false
    sessionLockedSignal = false
    sessionSnapshot = fresh
    lastSessionPoll = ProcessInfo.processInfo.systemUptime
    guard currentSessionBlockReason() == nil else {
      throw Failure("Session safety monitor not ready")
    }
  }
  func sourceBecameActive() {
    guard let token=pendingForegroundToken,handoff.phase == .pending,handoff.token==token,!sourceActivationCheckScheduled else{return}
    sourceActivationCheckScheduled=true
    let g=generation
    DispatchQueue.main.async { [weak self] in
      guard let self,self.generation==g,self.pendingForegroundToken==token else{return}
      guard self.handoff.phase == .pending,self.handoff.token==token else{return}
      guard self.currentSessionBlockReason(forceRefresh:true)==nil,self.localKeys.isEmpty,self.localButtons.isEmpty,self.localFlags.isEmpty,!self.dockLocalActive,self.dockOrphanMotion==nil else{self.forceLocal();self.status("Handoff cancelled: input/session changed");return}
      guard NSApp.isActive,self.sourceOwnershipConfirmed?()==true else{self.retrySourceOwnership(token:token,generation:g);return}
      DispatchQueue.main.async { [weak self] in
        guard let self,self.generation==g,self.pendingForegroundToken==token,self.handoff.phase == .pending,self.handoff.token==token else{return}
        guard self.currentSessionBlockReason(forceRefresh:true)==nil,self.localKeys.isEmpty,self.localButtons.isEmpty,self.localFlags.isEmpty,!self.dockLocalActive,self.dockOrphanMotion==nil,!physicalInputsHeld() else{self.forceLocal();self.status("Handoff cancelled: input/session changed on confirmation turn");return}
        guard NSApp.isActive,self.sourceOwnershipConfirmed?()==true else{self.retrySourceOwnership(token:token,generation:g);return}
        self.sourceActivationCheckScheduled=false;self.pendingForegroundToken=nil
        if (self.multiDisplayDesktopCompatible ? self.sendDesktopBeginControl(token:token) : self.control("begin",token:token,edge:self.selectedEdge,y:self.handoff.offset)){self.status("Handoff: stable source foreground; begin queued without fixed dwell")}
      }
    }
  }
  private func retrySourceOwnership(token:String,generation expected:UUID) {
    sourceActivationCheckScheduled=false
    guard generation==expected,pendingForegroundToken==token,handoff.phase == .pending else{return}
    guard ProcessInfo.processInfo.systemUptime<handoff.deadline else{forceLocal();status("Handoff cancelled: source ownership did not become ready");return}
    // Never reactivate on a retry. Wait only for the already-requested OS state.
    DispatchQueue.main.asyncAfter(deadline:.now()+0.001) { [weak self] in
      guard let self,self.generation==expected,self.pendingForegroundToken==token else{return}
      self.sourceBecameActive()
    }
  }
  func prepareSourceForeground() {
    guard let token = handoff.token else { return }
    pendingForegroundToken = token
    requestSourceActivation?()
    if NSApp.isActive { sourceBecameActive() }
  }
  /// Focus changes revoke active remote ownership, not authenticated transport
  /// or saved sharing intent. Lock/sleep/session checks still take precedence.
  func pauseSourceForForegroundLoss() {
    guard sender else{return}
    if let token=handoff.token {_ = control("cancel",token:token)}
    forward=false
    forceLocal()
    status("Local input active after focus change; connection and screen sharing maintained.")
  }
  func sourceResignedActive() {
    if desktopFocusIntent != nil {cancelDesktopFocusRestore();_ = restoreLocal()}
    if sender && (forward || (isTransferring && !awaitingSourceActivation)) {
      if let reason=currentSessionBlockReason(forceRefresh:true) {
        sessionBecameUnsafe(reason,origin:freshSessionSuspensionOrigin)
      } else {pauseSourceForForegroundLoss()}
    }
  }
  var remoteDisplaySize: CGSize?
  var displayGeometryChanged: ((CGSize?) -> Void)?
  var layoutEligibilityChanged:(()->Void)?
  private var lastLayoutEligibility:Bool?
  func publishLayoutEligibility() {let allowed=canEditScreenLayout;if lastLayoutEligibility != allowed {lastLayoutEligibility=allowed;layoutEligibilityChanged?()}}
  private let savedScreenLayouts:SavedScreenLayoutStore
  private let savedDesktopPlacements:SavedDesktopPlacementStore
  private var layoutDevicePair:LayoutDevicePair?
  private var pendingInitialLayoutRestore=false
  // Sender's view of the authenticated receiver's full desktop map. The
  // receiver remains the sole publisher via its "available" packets; the
  // sender treats this as read-only input for pointer geometry and UI.
  private(set) var receiverDesktop:ReceiverDesktop? {didSet{if receiverDesktop != oldValue {desktopEntryPolicy.reset()}}}
  private(set) var sourceOrigin:CGPoint? {didSet{if sourceOrigin != oldValue {desktopEntryPolicy.reset()}}}
  // Highest adopted revision keeps older echoed maps from overwriting a
  // newer one if frames arrive out of order on the receive queue.
  private var receiverDesktopAdoptedRevision:UInt64=0
  private var receiverDesktopAdoptedFingerprint:Data?
  // Receiver-side revision counter. Monotonic across the authenticated
  // session; a reconnect starts over at zero.
  private var receiverDesktopPublishRevision:UInt64=0
  // Receiver's last published map snapshot (identity+rect fingerprint) so the
  // tick can coalesce idle polls without re-encoding on every available ping.
  private var receiverDesktopPublishedFingerprint:Data?
  // Called whenever the sender adopts a new map or source origin. Owner UI
  // reads via receiverDesktop/sourceOrigin properties; model stays read-only.
  var onReceiverDesktopChanged:(()->Void)?
  // Guard against duplicated anchor restoration after the first authenticated
  // map arrives. The sender persists only on explicit user drag.
  private var pendingInitialSourceOriginRestore=false
  // 4-edge DesktopHandoff state. Independent of the legacy left/right
  // EdgeHandoff geometry; only the shared phase/token/foreground pathway is
  // reused from the legacy state machine. desktopHandoffActive becomes true
  // once a new-mode begin has been proposed and remains true through the
  // whole phase cycle, so legacy edge gating sits out of this cycle.
  private var desktopObserverActive=false
  private var desktopValidatedEpoch:UInt64?
  var desktopEpochForTests:(()->UInt64)?
  var desktopBeforeGateForTests:(()->Void)?
  private var desktopEpoch:UInt64 {desktopEpochForTests?() ?? DesktopInjectionEpoch.shared.snapshot()}
  deinit {if desktopObserverActive {DesktopInjectionEpoch.shared.release()}}
  private func finalDesktopInjectionGate()->Bool {
    guard multiDisplayDesktopCompatible,!sender else{return true}
    desktopBeforeGateForTests?()
    guard displayBarrier==nil,DesktopInjectionEpoch.allows(validated:desktopValidatedEpoch,current:desktopEpoch) else{_ = pauseReceiverTopologyFailure();return false}
    return true
  }
  private var desktopPortal:DesktopPortal?
  private var desktopGlobalPointer:CGPoint?
  private var desktopHandoffRevision:UInt64?
  private var desktopEntryPolicy=DesktopEntryPolicy()
  // Receiver side: previous global pointer used by portal.isReverseCrossing
  // to detect the user crossing back through the authenticated edge. Caching
  // the pre-event pointer avoids the already-clamped-returns-early race.
  private var desktopReceiverPreviousPointer:CGPoint?
  private var desktopReturnPoint:CGPoint?
  var layoutOffsetY = 0.0
  var canEditScreenLayout:Bool {displayBarrier==nil && (!hasSession || sender) && handoff.phase == .local && !forward && !hasUnresolvedLocalRecovery && !sourceGesture.blockAuto && ProcessInfo.processInfo.systemUptime >= gestureUntil && !dockLocalActive && !dockSource.active && !dockReceiver.active && dockOrphanMotion == nil}
  @discardableResult func editScreenLayout(edge:Edge,offset:Double)->Bool {
    guard canEditScreenLayout,let remote=remoteDisplaySize else{status(TCText("Return to local control and finish the gesture before changing the layout. The connection stays active."));return false}
    let bounds=topology?.bounds ?? CGDisplayBounds(CGMainDisplayID())
    let layout=ScreenArrangement(sourceSize:bounds.size,remoteSize:remote,remoteOnRight:edge == .right,offsetY:offset)
    guard layout.isValid else{status(TCText("Only valid layouts with vertically overlapping screens can be applied."));return false}
    guard handoff.reconfigureLocal(edge:edge,arrangement:layout) else{return false}
    layoutOffsetY=offset;selectedEdge=edge;entryMotion.reset();returnMotion.reset();pendingForegroundToken=nil;sourceActivationCheckScheduled=false;lastEdgeGateReason=""
    if sender,!displayRemoteGeometryTemporary,displayBarrier==nil,let pair=layoutDevicePair {_ = savedScreenLayouts.save(layout,for:pair)}
    status(TCText("Connection maintained: screen layout applied (")+edge.rawValue+TCText("). New coordinates take effect at the next edge crossing."))
    return true
  }
  private lazy var mouseInjectionSource: CGEventSource? = {
    let source = CGEventSource(stateID: .privateState)
    source?.localEventsSuppressionInterval = 0
    return source
  }()
  private let bridgeMonitor = DispatchQueue(label: "ThunderControl.bridge-monitor", qos: .utility)
  private var bridgeCheckInFlight = false
  private var lastEdgeGateReason = ""
  private let cursorResources: CursorRecoveryController
  init(cursorResources: CursorRecoveryController = CursorRecoveryController(),receiverCursor:CursorVisibilityController = CursorVisibilityController(),layoutStore:SavedScreenLayoutStore=SavedScreenLayoutStore(),desktopPlacementStore:SavedDesktopPlacementStore=SavedDesktopPlacementStore()) {
    self.savedScreenLayouts=layoutStore
    self.savedDesktopPlacements=desktopPlacementStore
    self.cursorResources = cursorResources;self.receiverCursor=receiverCursor
  }
  /// Sender-only accepted source attachment. Validates against the current
  /// receiver desktop, snaps so the proposed source rectangle attaches to a
  /// receiver display edge without overlap, and persists only user-driven
  /// drags to the per-pair placement store. Must not fire during an active
  /// display topology barrier or when unrelated inputs are held. The source
  /// view may authorize its own local left-button layout drag, never remote input; the
  /// transition protocol can finish before the sender publishes a new origin.
  @discardableResult func setSourceOrigin(_ proposed:CGPoint,fromLocalLayoutDrag:Bool=false)->Bool {
    guard sender,authenticated,multiDisplayDesktopCompatible,canEditScreenLayout,displayBarrier==nil,
      handoff.phase == .local,
      !hasUnresolvedLocalRecovery,
      localKeys.isEmpty,localFlags.isEmpty,
      (localButtons.isEmpty || (fromLocalLayoutDrag && localButtons==Set([Int64(0)]))),
      let desktop=receiverDesktop,desktop.valid,
      ReceiverDesktop.finite(proposed) else{return false}
    let size=topology?.bounds.size ?? CGDisplayBounds(CGMainDisplayID()).size
    guard ReceiverDesktop.sane(CGRect(origin:.zero,size:size)) else{return false}
    guard let accepted=desktop.snappedSourceOrigin(proposed:proposed,size:size) else{return false}
    guard accepted != sourceOrigin else{return false}
    sourceOrigin=accepted
    if let pair=layoutDevicePair,!pendingInitialSourceOriginRestore {
      _ = savedDesktopPlacements.save(origin:accepted,sourceSize:size,desktop:desktop,for:pair)
    }
    onReceiverDesktopChanged?()
    return true
  }
  /// Receiver-side: capture current OS desktop and decide whether a new
  /// revision must be issued. Fingerprinting runs against the untagged current
  /// read; the revision counter only increments when the fingerprint actually
  /// changed. Returns the final encoded payload with the correct revision
  /// stamped on the receiver desktop structure, so the sender never sees a
  /// counter bump without an underlying map change.
  private func encodeReceiverDesktopForPublication()->(Data,ReceiverDesktop)? {
    guard !sender else{return nil}
    let currentRevision=receiverDesktopPublishRevision
    // Use the current counter for the first read; it is replaced below if the
    // fingerprint confirms a new map must be published.
    guard displayBarrier == nil || receiverMapPublicationCandidate != nil else{return nil}
    guard let probe=receiverMapPublicationCandidate ?? freshReceiverDesktop(max(currentRevision,1)),probe.valid else{return nil}
    if currentRevision>0,receiverMapPublicationCandidate==nil,
      desktopFingerprintForPublication(probe) != receiverDesktopPublishedFingerprint {return nil}
    let fingerprint=desktopFingerprintForPublication(probe)
    let revisionToPublish:UInt64
    if receiverDesktopPublishedFingerprint == fingerprint,currentRevision>0 {
      // Unchanged map: re-publish the identical revision, never a bump.
      revisionToPublish=currentRevision
    } else {
      revisionToPublish=currentRevision &+ 1
    }
    let published=ReceiverDesktop(revision:revisionToPublish,mainID:probe.mainID,displays:probe.displays,virtualDisplayID:probe.virtualDisplayID)
    guard published.valid,let encoded=try? JSONEncoder().encode(published),encoded.count<=8192 else{return nil}
    return (encoded,published)
  }
  /// Sender-only. Called from `handle` for mouseMoved events when the new
  /// desktop handoff is armed. Returns true if the new-mode consumed the
  /// gating decision (so legacy auto edge gating must sit out). The method
  /// scans the receiver desktop portals of the current source rectangle,
  /// gates on an armed outward 1pt edge event, and triggers
  /// `prepareSourceForeground` once the receiver can accept the handoff.
  @discardableResult
  private func detectAndProposeDesktopHandoff(sourceLocal:CGPoint,delta:CGVector,held:Bool,now:Double)->Bool {
    guard sender,auto,multiDisplayDesktopCompatible,handoff.phase == .local,
      let desktop=receiverDesktop,desktop.valid,
      let origin=sourceOrigin,
      let bounds=topology?.bounds,bounds.width>=64,bounds.height>=64 else { return false }
    let sourceRect=CGRect(origin:origin,size:bounds.size)
    guard ReceiverDesktop.sane(sourceRect) else { return false }
    let portals=desktop.portals(sourceRect:sourceRect)
    guard !portals.isEmpty else { return false }
    guard let portal=desktopEntryPolicy.candidate(sourceLocal:sourceLocal,delta:delta,sourceRect:sourceRect,portals:portals,held:held) else{return true}
    if desktopPhysicalInputsForTests?() ?? physicalInputsHeld() { return true }
    let localX=sourceLocal.x,localY=sourceLocal.y
    // Compose entry point: edge touch point on the source rect maps to the
    // portal's target edge via DesktopPortal.targetPoint.
    let sourceEdgePoint:CGPoint
    switch portal.sourceSide {
    case .left: sourceEdgePoint=CGPoint(x:sourceRect.minX,y:origin.y+localY)
    case .right: sourceEdgePoint=CGPoint(x:sourceRect.maxX,y:origin.y+localY)
    case .top: sourceEdgePoint=CGPoint(x:origin.x+localX,y:sourceRect.minY)
    case .bottom: sourceEdgePoint=CGPoint(x:origin.x+localX,y:sourceRect.maxY)
    }
    let entryGlobal=portal.targetPoint(fromSourceEdge:sourceEdgePoint)
    desktopPortal=portal
    desktopGlobalPointer=entryGlobal
    desktopHandoffRevision=receiverDesktopAdoptedRevision
    desktopEntryPolicy.latch(portal.sourceSide)
    handoff.arrangement=nil;handoff.latched=true;desktopReturnPoint=nil
    handoff.phase = .pending
    handoff.token=UUID().uuidString
    handoff.deadline=now+1.5
    handoff.startedAt=now
    if let token=handoff.token { entryMotion.begin(token:token) }
    status("Desktop handoff: edge reached; acquiring source foreground")
    if let begin=desktopFocusBeginForTests,let token=handoff.token {begin(token)} else{prepareSourceForeground()}
    return true
  }
  private func sendDesktopBeginControl(token:String)->Bool {
    guard let portal=desktopPortal,let entry=desktopGlobalPointer,let revision=desktopHandoffRevision,
      let desktop=receiverDesktop,revision==desktop.revision,revision==receiverDesktopAdoptedRevision else{forceLocal();return false}
    let frame=DesktopHandoffRouting.beginFrame(session:session,token:token,portal:portal,entry:entry,revision:revision)
    guard DesktopHandoffRouting.portal(frame,desktop:desktop,publishedRevision:revision)==portal,enqueue(frame) else{forceLocal();return false}
    return true
  }
  // Fresh OS map must still be exactly the map the receiver published. B can
  // cancel the token before publishing/adopting any changed map revision.
  @discardableResult private func pauseReceiverTopologyFailure()->Bool {
    guard !sender,authenticated,multiDisplayDesktopCompatible else{return false}
    if displayBarrier==nil {startReceiverDisplayPause(ownedByMap:true,completion:nil)}
    return true
  }
  private func currentRoutingDesktop()->ReceiverDesktop? {
    if desktopEpochForTests==nil,!desktopObserverActive {
      guard DesktopInjectionEpoch.shared.acquire() else{safetyStop("Display observer registration failed");return nil}
      desktopObserverActive=true
    }
    let epoch=desktopEpoch
    // One fresh full map is sufficient here; the guard below performs the
    // same mismatch pause and retains the before/after/final epoch checks.
    guard !sender,receiverDesktopPublishRevision>0,
      displayBarrier == nil,let fresh=freshReceiverDesktop(receiverDesktopPublishRevision),
      fresh.valid,desktopFingerprintForPublication(fresh)==receiverDesktopPublishedFingerprint else{_ = pauseReceiverTopologyFailure();return nil}
    guard epoch==desktopEpoch else{_ = pauseReceiverTopologyFailure();return nil}
    desktopValidatedEpoch=epoch
    return fresh
  }
  private func desktopFingerprintForPublication(_ desktop:ReceiverDesktop)->Data {
    var fingerprint=Data()
    for d in desktop.displays {
      withUnsafeBytes(of: d.id.bigEndian) { fingerprint.append(contentsOf: $0) }
      for coord in [d.bounds.minX,d.bounds.minY,d.bounds.width,d.bounds.height] {
        withUnsafeBytes(of: coord.bitPattern.bigEndian) { fingerprint.append(contentsOf: $0) }
      }
      if let identity = d.stableIdentity, let utf8 = identity.data(using: .utf8) { fingerprint.append(utf8) }
      fingerprint.append(0)
    }
    withUnsafeBytes(of: desktop.mainID.bigEndian) { fingerprint.append(contentsOf: $0) }
    withUnsafeBytes(of: (desktop.virtualDisplayID ?? 0).bigEndian) { fingerprint.append(contentsOf: $0) }
    return fingerprint
  }
  /// Sender-side map adoption. Rejects decode errors, invalid maps, stale
  /// revisions, or oversized payloads. On the first authenticated map, tries
  /// to restore a saved per-pair placement; otherwise attaches left of the virtual display
  /// (or physical main before the virtual exists), vertically centered. Mapped geometry changes anchor the current
  /// origin without automatically persisting a new placement.
  private func adoptReceiverDesktopFromPeer(_ data:Data) {
    guard sender,authenticated,multiDisplayDesktopCompatible,!data.isEmpty,data.count<=8192 else{return}
    guard let decoded=try? JSONDecoder().decode(ReceiverDesktop.self,from:data),decoded.valid else{return}
    // Strictly monotonic revisions. A matching revision must carry an
    // identical fingerprint; divergent content at the same counter would be
    // a protocol violation and gets dropped before any pointer use.
    if decoded.revision < receiverDesktopAdoptedRevision { return }
    let decodedFingerprint=desktopFingerprintForPublication(decoded)
    if decoded.revision == receiverDesktopAdoptedRevision {
      if let last=receiverDesktopAdoptedFingerprint, last != decodedFingerprint { return }
      if receiverDesktop != nil { return }
    }
    if desktopHandoffRevision != nil,desktopHandoffRevision != decoded.revision {
      if let token=handoff.token {_ = control("cancel",token:token)}
      forceLocal()
    }
    let geometryChanged = receiverDesktopAdoptedFingerprint != decodedFingerprint
    let previous=receiverDesktop
    receiverDesktop=decoded
    receiverDesktopAdoptedRevision=decoded.revision
    receiverDesktopAdoptedFingerprint=decodedFingerprint
    let size=topology?.bounds.size ?? CGDisplayBounds(CGMainDisplayID()).size
    if pendingInitialSourceOriginRestore {
      pendingInitialSourceOriginRestore=false
      let restored:CGPoint?
      if let pair=layoutDevicePair,let saved=savedDesktopPlacements.restored(for:pair,sourceSize:size,desktop:decoded) {
        restored=saved
      } else {
        restored=decoded.defaultSourceOrigin(size:size)
      }
      if let p=restored,let accepted=decoded.snappedSourceOrigin(proposed:p,size:size) {
        sourceOrigin=accepted
      } else {
        sourceOrigin=nil
      }
    } else if geometryChanged {
      // Actual receiver geometry change. Prefer the per-pair saved anchor+
      // tangent-offset restore (the store relativises against stable identity
      // so an OS main or origin change does not silently switch the user's
      // chosen attachment side). The adopted anchor must not be auto-persisted;
      // the user still owns the record. If no saved record exists and the old
      // absolute origin still has a portal, keep it; otherwise snap defensively.
      if let pair=layoutDevicePair,let saved=savedDesktopPlacements.restored(for:pair,sourceSize:size,desktop:decoded) {
        sourceOrigin=saved
      } else if sourceOrigin == nil {
        // Physical-only maps may have no valid left attachment yet. Once the
        // virtual appears, retry only the defined collision-free default.
        sourceOrigin=decoded.defaultSourceOrigin(size:size)
      } else if let origin=sourceOrigin,previous?.virtualDisplayID == nil,decoded.virtualDisplayID != nil,
        previous?.defaultSourceOrigin(size:size) == origin {
        // The initial physical-only default must move left of the newly-owned
        // virtual display. Saved/manual anchors above always take precedence.
        sourceOrigin=decoded.defaultSourceOrigin(size:size)
      } else if let origin=sourceOrigin,decoded.portals(sourceRect:CGRect(origin:origin,size:size)).isEmpty {
        sourceOrigin=decoded.snappedSourceOrigin(proposed:origin,size:size) ?? decoded.defaultSourceOrigin(size:size)
      }
    }
    if previous != receiverDesktop || sourceOrigin != nil {onReceiverDesktopChanged?()}
  }
  private var recoveryNonce = UUID()
  private var recoveryNotice = ""
  private var topology: DisplayTopologySnapshot?
  private var localKeys = Set<CGKeyCode>()
  private var localButtons = Set<Int64>()
  private var localFlags: CGEventFlags = []
  private var gestureUntil = 0.0
  private var lastBridgeCheck = 0.0
  private var displayBounds = CGRect.zero
  private var lastInput = ProcessInfo.processInfo.systemUptime
  private var context: SessionContext?
  private var connection: OwnedSocket?
  private(set) var generation = UUID()
  private var timer: Timer?
  private var tap: CFMachPort?
  private var source: CFRunLoopSource?
  private var key: SymmetricKey?
  private var session = ""
  private var seq: UInt64 = 1
  private var keys = Set<CGKeyCode>()
  private var buttons = Set<UInt32>()
  private var sender = false
  private var gestureCompatible = false
  private var receiverGestureAvailable=false
  private var dockSource=DockTransferState()
  private var dockReceiver=DockTransferState()
  private var dockSourceDesktopTarget:DesktopSystemGestureTarget?
  private var dockReceiverDesktopTarget:DesktopSystemGestureTarget?
  private struct PostedDockStream {
    let descriptor:DockGestureDescriptor
    let point:CGPoint
    let target:DesktopSystemGestureTarget
    let token:String
    let stream:String
    let session:String
    let generation:UUID
  }
  private var postedDockStream:PostedDockStream?
  // Terminate only an already-posted canonical stream on its still-valid
  // display. Never copy/replay opaque HID or manufacture a new begin.
  private func cancelPostedDockStream() {
    guard let posted=postedDockStream else{return}
    postedDockStream=nil // consume before any gate can synchronously restore
    guard !sender,authenticated,!lockedTransportOnly,inject,experimental,gestureCompatible,
      multiDisplayDesktopCompatible,desktopSystemGestureCompatible,
      posted.generation==generation,posted.session==session,
      handoff.token==posted.token,acceptsToken(handoff,posted.token),dockReceiver.id==posted.stream,
      dockReceiverDesktopTarget==posted.target,
      (desktopSystemGesturePermissionForTests?() ?? AXIsProcessTrusted()),
      currentSessionBlockReason(forceRefresh:true)==nil,displayBarrier==nil,
      !receiverCursorLocalOverride,receiverActivationPendingToken==nil,
      desktopReceiverPreviousPointer==posted.point,
      let desktop=currentRoutingDesktop(),desktop.revision==posted.target.revision,
      desktopHandoffRevision==posted.target.revision,
      desktop.displays.contains(where:{$0.id==posted.target.displayID && ReceiverDesktop.has($0.bounds,posted.point)}) else {
      status("System gesture cleanup skipped: active session, consent or exact display proof unavailable")
      return
    }
    let terminal=DockGestureDescriptor(motion:posted.descriptor.motion,phase:8,progress:posted.descriptor.progress,velocityX:0,velocityY:0)
    let projected=receiverDockProjection(terminal,invertVertical:invertVerticalSystemGestures,invertHorizontal:invertHorizontalSystemGestures)
    guard let event=desktopSystemGestureBuildForTests?(projected) ?? makeDock(projected) else {
      status("System gesture cleanup skipped: canonical cancellation builder unavailable");return
    }
    event.location=posted.point
    guard finalDesktopInjectionGate(),dockReceiver.accept(terminal,id:posted.stream,now:ProcessInfo.processInfo.systemUptime) else {
      status("System gesture cleanup skipped: final epoch or stream proof changed");return
    }
    event.timestamp=DispatchTime.now().uptimeNanoseconds
    event.setIntegerValueField(.eventSourceUserData,value:marker)
    if let post=desktopSystemGesturePostForTests {post(event)} else {event.post(tap:.cgSessionEventTap)}
    gestureTrace.recordDock(stage:.rxPosted,descriptor:projected,stream:posted.stream,inverted:terminal.motion==1 ? invertHorizontalSystemGestures:invertVerticalSystemGestures)
    status("System gesture canonical cancellation queued before local restore; native completion unverified")
  }

  // Memory-only seams: never selected from network data or UI.
  var desktopSystemGesturePermissionForTests:(()->Bool)?
  var desktopSystemGestureBuildForTests:((DockGestureDescriptor)->CGEvent?)?
  var desktopSystemGesturePostForTests:((CGEvent)->Void)?
  func prepareDesktopSystemGestureForTests(map:ReceiverDesktop,point:CGPoint,token:String,negotiated:Bool=true) {
    sender=false;multiDisplayDesktopCompatible=true;desktopSystemGestureCompatible=negotiated;gestureCompatible=true;experimental=true;inject=true
    handoff.phase = .targetActive;handoff.token=token
    receiverDesktopPublishRevision=map.revision;receiverDesktopPublishedFingerprint=desktopFingerprintForPublication(map)
    desktopHandoffRevision=map.revision;desktopGlobalPointer=point;desktopReceiverPreviousPointer=point
    desktopPortal=map.portals(sourceRect:CGRect(x:-1200,y:0,width:1200,height:800)).first
    dockReceiver.reset();dockReceiverDesktopTarget=nil;receiverCursorLocalOverride=false
  }
  private var dockLocalActive=false
  private var dockOrphanMotion:Int?
  private var callbackReplacement:CGEvent?
  private let pending = DispatchSemaphore(value: 128)
  private let inbound = DispatchSemaphore(value: 32)
  private var modifiers = Set<CGKeyCode>()
  private let out = DispatchQueue(label: "ThunderControl.send")
  var diagnosticLines: [String] = []
  var diagnosticChanged: ((String) -> Void)?
  func status(_ s: String) {
    let publish = {
      self.diagnosticLines.append("\(ISO8601DateFormatter().string(from: Date())) \(s)")
      if self.diagnosticLines.count > 200 {
        self.diagnosticLines.removeFirst(self.diagnosticLines.count - 200)
      }
      connectionLog("\(s)")
      self.diagnosticChanged?(self.diagnosticLines.joined(separator: "\n"))
      self.changed?(s)
    }
    if Thread.isMainThread { publish() } else { DispatchQueue.main.async(execute: publish) }
  }
  // MARK: - Internal test seams.
  // These never mutate real OS state; they let out-of-class pure-model tests
  // drive the sender adoption path without opening sockets, keychain state,
  // input capture, or screen capture.
  var concurrentDisplayCompatibleForTests:Bool {
    get { concurrentDisplayCompatible }
    set { concurrentDisplayCompatible = newValue }
  }
  var multiDisplayDesktopCompatibleForTests:Bool {
    get { multiDisplayDesktopCompatible }
    set { multiDisplayDesktopCompatible = newValue }
  }
  var layoutDevicePairForTests:LayoutDevicePair? {
    get { layoutDevicePair }
    set { layoutDevicePair = newValue }
  }
  var pendingInitialSourceOriginRestoreForTests:Bool {
    get { pendingInitialSourceOriginRestore }
    set { pendingInitialSourceOriginRestore = newValue }
  }
  var topologyForTests:DisplayTopologySnapshot? {
    get { topology }
    set { topology = newValue; displayBounds = newValue?.bounds ?? .zero }
  }
  var sessionForTests:String { session }
  var senderForTests:Bool {
    get { sender }
    set { sender = newValue }
  }
  var connectionForTests:OwnedSocket? {
    get { connection }
    set { connection = newValue }
  }
  var contextForTests:SessionContext? {
    get { context }
    set { context = newValue }
  }
  var keyForTests:SymmetricKey? {
    get { key }
    set { key = newValue }
  }
  // Drives the actual entry detector, with foreground/physical-input hooks
  // supplied by the isolated test. No CGEvent construction or OS input.
  func desktopPrepareEntryForTests(map:ReceiverDesktop,origin:CGPoint) {
    receiverDesktop=map;receiverDesktopAdoptedRevision=map.revision;sourceOrigin=origin
    handoff.phase = .local;desktopEntryPolicy.reset();auto=true
  }
  @discardableResult func desktopEntryForTests(_ p:CGPoint,delta:CGVector,held:Bool=false,now:Double)->Bool {
    detectAndProposeDesktopHandoff(sourceLocal:p,delta:delta,held:held,now:now)
  }
  var desktopEntryStartedForTests:Double {handoff.startedAt}
  var desktopEntryLatchedSideForTests:DesktopSide? {desktopEntryPolicy.latchedSide}
  func receiveControlForTests(_ w:Wire) { receiveControl(w) }
  func detectDesktopMapForTests()->Bool {detectReceiverMapTransition()}
  func tickDesktopMapForTests() {tickDisplayTopologyTransition()}
  var desktopBarrierForTests:ConcurrentDisplayBarrier? {displayBarrier}
  var desktopPublishedRevisionForTests:UInt64 {receiverDesktopPublishRevision}
  var desktopRoutingAllowedForTests:Bool {currentRoutingDesktop() != nil}
  func desktopPrepareStopProjectionForTests(portal:DesktopPortal,point:CGPoint) {
    desktopPortal=portal;desktopGlobalPointer=point;desktopHandoffRevision=1
    handoff.phase = .remote
    _ = cursorResources.acquire(display:1)
  }
  func desktopGateEffectsForTests(post:()->Void,warp:()->Void,bookkeeping:()->Void) {
    guard currentRoutingDesktop() != nil,finalDesktopInjectionGate() else{return}
    post();warp();bookkeeping()
  }
  var desktopLocalKeysForTests:Set<CGKeyCode> {get{localKeys} set{localKeys=newValue}}
  var desktopLocalButtonsForTests:Set<Int64> {get{localButtons} set{localButtons=newValue}}
  func receiveDesktopBarrierForTests(_ w:Wire) {receiveDisplayBarrier(w)}
  /// Pure adoption seam that skips the "available" side effects (auto arming,
  /// consent broadcast, cursor sync) so a pure-model regression can observe
  /// only the map protocol state transitions.
  func adoptReceiverDesktopPayloadForTests(_ data:Data) { adoptReceiverDesktopFromPeer(data) }
  static func verifyConcurrentDisplayIdentityForTests(_ lease:ConcurrentDisplayLease)->Bool {
    let r=Relay(),socket=OwnedSocket(-1),ctx=SessionContext(OwnedSocket(-1))
    r.connection=socket;r.context=ctx;r.key=SymmetricKey(size:.bits256);r.sender=true
    let generation=r.generation,key=r.key!.withUnsafeBytes{Data($0)}
    var rejected=false
    r.beginDisplayTopologyTransition {if case .failure=$0 {rejected=true}}
    guard rejected,r.connection === socket,r.context === ctx,r.generation==generation,r.key!.withUnsafeBytes({Data($0)})==key else{return false}
    r.sender=false;r.displayBarrier=ConcurrentDisplayBarrier(phase:.paused,now:0)
    r.adoptDisplayLease(lease)
    return r.connection === socket && r.context === ctx && !ctx.cancelled && r.generation==generation && r.key!.withUnsafeBytes({Data($0)})==key && r.topology?.mainID==lease.accepted.main && r.topology?.bounds==lease.accepted.bounds && !r.topologyUnchanged()
  }
  func beginDisplayTopologyTransition(completion:@escaping(Result<Void,Error>)->Void) {
    guard authenticated,!sender,!lockedTransportOnly,concurrentDisplayCompatible else {completion(.failure(Failure("Authenticated receiver required")));return}
    if let barrier=displayBarrier {
      guard receiverOwnsMapTransition,displayBarrierCompletion==nil,
        barrier.phase == .awaitingAck || barrier.phase == .paused else {completion(.failure(Failure("Display transition already owned")));return}
      // Helper takes ownership without restarting the deadline or nonce.
      receiverOwnsMapTransition=false
      if barrier.phase == .paused {completion(.success(()))} else{displayBarrierCompletion=completion}
      return
    }
    guard multiDisplayDesktopCompatible || topologyUnchanged() else {completion(.failure(Failure("Stable display topology required")));return}
    startReceiverDisplayPause(ownedByMap:false,completion:completion)
  }
  func commitDisplayTopology(original:DisplayBaseline,ownedID:CGDirectDisplayID)throws {
    guard !sender,(!authenticated || displayBarrier?.phase == .paused),displayLease==nil,
      let first=freshDisplayBaseline(),let second=freshDisplayBaseline(),first==second else{throw Failure("Display adoption barrier not ready")}
    let lease=try ConcurrentDisplayLease(original:original,current:second,ownedID:ownedID)
    guard lease.matches(first),lease.matches(second) else{throw Failure("Owned display identity changed")}
    displayLease=lease
    guard let map=stableReceiverDesktop() else{displayLease=nil;throw Failure("Unstable owned desktop")}
    try adoptReceiverMain(map)
    if authenticated {try resumeDisplayReceiver(map:map)}
  }
  private func adoptDisplayLease(_ lease:ConcurrentDisplayLease) {
    displayLease=lease
    if let map=lease.accepted.desktop(revision:max(1,receiverDesktopPublishRevision),virtualID:lease.ownedID) {try? adoptReceiverMain(map)}
  }
  func finishDisplayTopologyRemoval(original:DisplayBaseline)throws {
    guard !sender,(!authenticated || displayBarrier?.phase == .paused),
      let first=freshDisplayBaseline(),let second=freshDisplayBaseline(),first==second,second.supported else{throw Failure("Display removal map unstable")}
    if let owned=displayLease?.ownedID,first.ids.contains(owned) || second.ids.contains(owned) {throw Failure("Owned display still present")}
    let prior=displayLease;displayLease=nil
    guard let map=stableReceiverDesktop() else{displayLease=prior;throw Failure("Display removal map unstable")}
    try adoptReceiverMain(map)
    if authenticated {try resumeDisplayReceiver(map:map)}
  }
  func abortDisplayTopologyTransition() {
    if displayBarrier != nil {safetyStop("Display topology transition aborted safely")}
  }
  static func verifyDevelopmentReconnectTimeoutForTests()->Bool {
    final class Mock:CursorRecoveryAPI {
      var failShow=false
      func associate(_ associated:Bool)->CGError{.success};func hide(display:CGDirectDisplayID)->CGError{.success}
      func show(display:CGDirectDisplayID)->CGError{failShow ? .failure:.success};func warp(to point:CGPoint)->CGError{.success}
    }
    for independentlySuspended in [false,true] {
      let mock=Mock(),r=Relay(cursorResources:CursorRecoveryController(api:mock),receiverCursor:CursorVisibilityController(api:mock))
      r.automaticReconnectSuspended=independentlySuspended
      let ctx=SessionContext(OwnedSocket(-1));r.context=ctx;r.connection=OwnedSocket(-1);r.key=SymmetricKey(size:.bits256)
      r.displayBarrier=ConcurrentDisplayBarrier(phase:.awaitingAck,now:0)
      var completionAfterCancellation=false
      r.displayBarrierCompletion={_ in completionAfterCancellation=ctx.cancelled && r.displayBarrier==nil}
      r.expireDisplayTopologyTransition()
      guard ctx.cancelled,r.context==nil,r.displayBarrier==nil,completionAfterCancellation,r.automaticReconnectSuspended==independentlySuspended,!r.hasUnresolvedLocalRecovery else{return false}
      guard automaticConnectionMayStart(configured:true,paused:false,suspended:r.automaticReconnectSuspended,permissions:true,sessionSafe:true,recovery:r.hasUnresolvedLocalRecovery,hasSession:r.hasSession) == !independentlySuspended else{return false}
    }
    let mock=Mock(),visible=CursorVisibilityController(api:mock)
    guard visible.hide(display:1) else{return false};mock.failShow=true
    let r=Relay(cursorResources:CursorRecoveryController(api:mock),receiverCursor:visible)
    r.context=SessionContext(OwnedSocket(-1));r.connection=OwnedSocket(-1);r.key=SymmetricKey(size:.bits256)
    r.displayBarrier=ConcurrentDisplayBarrier(phase:.awaitingAck,now:0)
    r.expireDisplayTopologyTransition()
    guard r.hasUnresolvedLocalRecovery,!r.automaticReconnectSuspended,
      !automaticConnectionMayStart(configured:true,paused:false,suspended:false,permissions:true,sessionSafe:true,recovery:r.hasUnresolvedLocalRecovery,hasSession:r.hasSession) else{return false}
    mock.failShow=false;r.forceLocal()
    return !r.hasUnresolvedLocalRecovery && !r.automaticReconnectSuspended
  }
  private func expireDisplayTopologyTransition() {
    guard displayBarrier != nil else{return}
    // Timeout proves neither malicious peer nor new user intent. Retire the old
    // session and recover owned inputs; never clear an existing safety latch.
    // automaticConnectionMayStart still forbids retry while local recovery remains.
    DevelopmentDiagnostics.shared.record(stage:"input_transition_timeout")
    stop(reason:"Display transition timed out; retry after safe local cleanup")
  }
  private func resumeDisplayReceiver(map:ReceiverDesktop)throws {
    guard let barrier=displayBarrier,barrier.phase == .paused else{throw Failure("Missing display pause acknowledgment")}
    guard desktopNow<barrier.deadline else{expireDisplayTopologyTransition();throw Failure("Display transition expired")}
    receiverMapPublicationCandidate=map
    defer{receiverMapPublicationCandidate=nil}
    guard control("available",width:0),control("displayResume",token:barrier.token,width:displayLease != nil ? 1:0) else{throw Failure("Display resume queue failed")}
    displayBarrier=nil;receiverOwnsMapTransition=false
    consent(barrier.savedConsent && automaticSharingInputAllowed(false))
  }
  private func receiveDisplayBarrier(_ w:Wire) {
    guard authenticated,concurrentDisplayCompatible,let token=w.token else{abortDisplayTopologyTransition();return}
    switch w.kind {
    case "displayPause":
      guard sender,(displayBarrier==nil || displayBarrier?.phase == .resuming),!displayBarrierTokens.contains(token) else{safetyStop("Unexpected display pause");return}
      let savedAuto=displayBarrier?.savedAuto ?? auto,savedForward=displayBarrier?.savedForward ?? forward
      if displayBarrier == nil,desktopFocusIntent == nil,handoff.phase == .remote,auto,
        let map=receiverDesktop,let point=desktopGlobalPointer {desktopFocusIntent=DesktopMapFocusIntent(desktop:map,point:point,now:desktopNow)}
      sourceBarrierRevision=receiverDesktopAdoptedRevision
      sourceBarrierMapReady=false
      displayBarrierTokens.insert(token)
      displayBarrier=ConcurrentDisplayBarrier(token:token,phase:.draining,now:desktopNow,auto:savedAuto,forward:savedForward)
      auto=false;forward=false
      ownership.force();sourceGesture.forceLocal();_ = restoreLocal(deferActivation:desktopFocusIntent != nil)
      status(TCText("Input connection maintained: waiting for the other Mac's display transition."))
      tickDisplayTopologyTransition()
    case "displayPaused":
      guard !sender,displayBarrier?.token==token,displayBarrier?.phase == .awaitingAck else{safetyStop("Unexpected display acknowledgment");return}
      displayBarrier?.phase = .paused
      connectionLog("Display transition: receiver confirmed peer input drain")
      let completion=displayBarrierCompletion;displayBarrierCompletion=nil;completion?(.success(()))
      if receiverOwnsMapTransition {tickDisplayTopologyTransition()}
    case "displayResume":
      guard sender,displayBarrier?.token==token,displayBarrier?.phase == .paused,(!multiDisplayDesktopCompatible || sourceBarrierMapReady),(w.width==0 || w.width==1) else{safetyStop("Unexpected display resume");return}
      applyDisplayRemoteTarget(w.width==1)
      displayBarrier?.phase = .resuming;tickDisplayTopologyTransition()
    default: break
    }
  }
  private func applyDisplayRemoteTarget(_ temporary:Bool) {
    guard !multiDisplayDesktopCompatible else{return}
    if temporary && !displayRemoteGeometryTemporary {
      displayRemoteOriginalLayout=(selectedEdge,layoutOffsetY)
      if let bounds=topology?.bounds,let remote=remoteDisplaySize {
        let arrangement=ScreenArrangement(sourceSize:bounds.size,remoteSize:remote,remoteOnRight:selectedEdge == .right,offsetY:layoutOffsetY)
        if !arrangement.isValid {layoutOffsetY=0}
      }
    }
    if !temporary,let original=displayRemoteOriginalLayout {
      selectedEdge=original.0;layoutOffsetY=original.1;displayRemoteOriginalLayout=nil
    }
    displayRemoteGeometryTemporary=temporary
  }
  static func verifyConcurrentTemporaryLayoutForTests()->Bool {
    let r=Relay();r.selectedEdge = .left;r.layoutOffsetY=37
    // Same-resolution physical and virtual targets still require explicit isolation.
    r.remoteDisplaySize=CGSize(width:1920,height:1080)
    r.applyDisplayRemoteTarget(true)
    guard r.displayRemoteGeometryTemporary else{return false}
    r.selectedEdge = .right;r.layoutOffsetY = -52
    r.applyDisplayRemoteTarget(true) // no overwrite of the original snapshot
    r.applyDisplayRemoteTarget(false)
    guard !r.displayRemoteGeometryTemporary && r.selectedEdge == .left && r.layoutOffsetY==37 && r.displayRemoteOriginalLayout==nil else{return false}
    let tall=Relay();tall.topology=DisplayTopologySnapshot(mainID:1,activeIDs:[1],bounds:CGRect(x:0,y:0,width:1440,height:900));tall.remoteDisplaySize=CGSize(width:1920,height:1080);tall.layoutOffsetY = -1200
    tall.applyDisplayRemoteTarget(true);guard tall.layoutOffsetY==0 else{return false};tall.applyDisplayRemoteTarget(false)
    return tall.layoutOffsetY == -1200
  }
  private func tickDisplayTopologyTransition() {
    guard let barrier=displayBarrier else{return}
    guard desktopNow<barrier.deadline else{expireDisplayTopologyTransition();return}
    guard sender else{
      guard receiverOwnsMapTransition,barrier.phase == .paused,let map=stableReceiverDesktop() else{return}
      // A missing owned identity must be reconciled by helper cleanup, never relabelled here.
      if let lease=displayLease {guard let actual=freshDisplayBaseline(),lease.matches(actual) else{return}}
      do {try adoptReceiverMain(map);try resumeDisplayReceiver(map:map)} catch {abortDisplayTopologyTransition()}
      return
    }
    // Only the receiver's topology may change. Source never gets a bypass.
    guard let expected=topology,let actual=desktopSourceReadForTests?() ?? (try? captureSingleDisplayTopology()),actual==expected else{safetyStop("Source topology changed during display transition");return}
    guard localKeys.isEmpty,localButtons.isEmpty,localFlags.isEmpty,!ownership.blocked,ownership.owned.isEmpty,
      !hasUnresolvedLocalRecovery,!sourceGesture.blockAuto,!sourceGesture.hasOrphans,!dockLocalActive,dockOrphanMotion==nil,
      !(desktopPhysicalInputsForTests?() ?? physicalInputsHeld()),handoff.phase == .local else{return}
    if barrier.phase == .draining {
      guard control("displayPaused",token:barrier.token) else{return}
      displayBarrier?.phase = .paused
    } else if barrier.phase == .resuming {
      if (barrier.savedForward || desktopFocusIntent != nil) && !receiverAvailable {return}
      displayBarrier=nil
      if let intent=desktopFocusIntent {
        guard automaticSharingInputAllowed(true) else{forceLocal();return}
        desktopFocusIntent=nil
        guard desktopNow<intent.deadline,!automaticReconnectSuspended,!lockedTransportOnly,desktopFocusSafety,
          let map=receiverDesktop,map.revision==receiverDesktopAdoptedRevision,map.revision>sourceBarrierRevision,
          let target=intent.target(in:map),let origin=sourceOrigin,let bounds=topology?.bounds,
          let route=DesktopMapFocusRoute.make(desktop:map,source:CGRect(origin:origin,size:bounds.size),target:target) else{
          forceLocal();status(TCText("Returned to local control because a safe crossing point could not be confirmed after the display transition."));return
        }
        // Re-enter through the same strict begin/ready/commit/active protocol.
        let portal=route.portal,entry=route.entry
        desktopPortal=portal;desktopGlobalPointer=entry;desktopHandoffRevision=map.revision
        auto=true;forward=false;handoff.arrangement=nil;handoff.latched=true
        handoff.phase = .pending;handoff.token=UUID().uuidString;handoff.deadline=ProcessInfo.processInfo.systemUptime+1.5;handoff.startedAt=ProcessInfo.processInfo.systemUptime
        let token=handoff.token!;entryMotion.begin(token:token)
        // Buffered motion is validated again against the new map after active.
        var previous=entry
        for point in route.waypoints {
          guard entryMotion.append(token:token,dx:point.x-previous.x,dy:point.y-previous.y) else{forceLocal();return}
          previous=point
        }
        if !route.preserved {status(TCText("No route to the previous screen remains. Resuming control at a safe edge of the remote screen."))}
        desktopFocusIntent=intent
        activationRestorePending=false
        if let begin=desktopFocusBeginForTests {begin(token)} else{prepareSourceForeground()}
        status(TCText("Rechecking the existing remote control state after the display transition."));return
      }
      connectionLog("Display transition: source resumes existing input session")
      if barrier.savedAuto,automaticSharingInputAllowed(true) {configureAuto(true,edge:selectedEdge)}
      else if barrier.savedForward,receiverAvailable,inputPermissionsReady(),NSApp.isActive {forward=true}
      status(TCText("Input connection maintained: input mode restored after the display transition."))
    }
  }
  func topologyUnchanged() -> Bool {
    guard displayBarrier == nil else{return false}
    guard let expected=topology else{return false}
    if sender {return (desktopSourceReadForTests?() ?? (try? captureSingleDisplayTopology())) == expected}
    if multiDisplayDesktopCompatible,receiverDesktopPublishedFingerprint != nil {
      guard let fresh=freshReceiverDesktop(max(1,receiverDesktopPublishRevision)),fresh.valid else{return false}
      return desktopFingerprintForPublication(fresh)==receiverDesktopPublishedFingerprint
    }
    if let lease=displayLease {guard let first=freshDisplayBaseline(),let second=freshDisplayBaseline(),first==second else{return false};return lease.matches(second)}
    guard let map=stableReceiverDesktop(),let main=map.displays.first(where:{$0.id==map.mainID}) else{return false}
    return main.id==expected.mainID && main.bounds==expected.bounds
  }
  func noteRecovery(_ result: RecoveryOutcome) {
    if !result.recovered {
      recoveryNotice =
        "Cursor recovery unresolved: "
        + result.errors.map { $0.description }.joined(separator: "; ")
        + ". New connections and auto activation are blocked. Stop retries recovery."
      status(recoveryNotice)
    } else if !result.warnings.isEmpty {
      recoveryNotice =
        result.warnings.map { $0.description }.joined(separator: "; ")
        + " Local input is restored, but the pointer position could not be restored."
      status(recoveryNotice)
    } else {
      recoveryNotice = ""
    }
  }
  func retryRecovery(_ nonce: UUID, _ lease: UUID, after delay: Double) {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self, self.recoveryNonce == nonce, self.cursorResources.leaseID == lease,
        self.cursorResources.needsRecovery
      else { return }
      let result = self.cursorResources.restore(point: nil, expectedLeaseID: lease)
      self.noteRecovery(result)
      if result.shouldRetry {
        self.retryRecovery(nonce, lease, after: 0.25)
      } else if result.recovered {
        if self.context == nil { self.removeCaptureIfClean() }
        self.restoreSourceActivation?()
        if self.recoveryNotice.isEmpty {
          self.status("Cursor resources recovered. Input options remain OFF.")
        }
      }
    }
  }
  @discardableResult
  func restoreLocal(deferActivation:Bool=false,useReturnCarry:Bool=false) -> Bool {
    let wasTransferred = handoff.phase != .local
    recoveryNonce = UUID()
    let nonce = recoveryNonce
    let lease = cursorResources.leaseID
    let b = topology?.bounds ?? CGDisplayBounds(CGMainDisplayID())
    let point:CGPoint?
    if cursorResources.needsRecovery,let portal=desktopPortal,let global=desktopReturnPoint ?? desktopGlobalPointer {
      point=DesktopHandoffRouting.localReturn(portal:portal,point:global,bounds:b)
    } else {
      point=cursorResources.needsRecovery ? sourceCursorReturnPoint(bounds:b,edge:selectedEdge,handoff:handoff,xCarry:useReturnCarry ? returnMotion.take(now:ProcessInfo.processInfo.systemUptime) : 0):nil
    }
    desktopEntryPolicy.reset(returningThrough:desktopPortal?.sourceSide)
    desktopPortal=nil;desktopGlobalPointer=nil;desktopHandoffRevision=nil;desktopReceiverPreviousPointer=nil;desktopReturnPoint=nil
    entryMotion.reset();returnMotion.reset();returnStartedAt=nil;receiverActivationPendingToken=nil;receiverActivationDeadline=nil
    pendingForegroundToken = nil
    sourceActivationCheckScheduled=false
    let result = cursorResources.restore(point: point, expectedLeaseID: lease)
    noteRecovery(result)
    if dockSource.active {dockOrphanMotion=dockSource.motion}
    dockSource.reset();dockReceiver.reset();dockSourceDesktopTarget=nil;dockReceiverDesktopTarget=nil;postedDockStream=nil
    sourceGesture.forceLocal();receiverAppGesture.reset()
    _ = handoff.reset()
    releaseInputs()
    if sender && (wasTransferred || activationRestorePending) && result.recovered {
      if deferActivation {activationRestorePending=true}
      else {activationRestorePending=false;restoreSourceActivation?()}
    }
    if result.shouldRetry, let lease { retryRecovery(nonce, lease, after: 0.25) }
    if wasTransferred && result.recovered && recoveryNotice.isEmpty && !deferActivation {
      status(
        sender
          ? "Local input active. Move inward before another edge crossing."
          : "Source has local control. Receiver waiting for another handoff.")
    }
    let visibilityRecovered=syncReceiverCursor()
    return result.recovered && visibilityRecovered
  }
  func forceLocal() {
    cancelDesktopFocusRestore()
    ownership.force()
    sourceGesture.forceLocal()
    restoreLocal()
  }
  func removeCaptureIfClean() {
    guard context == nil,!sourceGesture.hasOrphans,!ownership.blocked, !cursorResources.needsRecovery,!receiverCursor.needsRecovery,dockOrphanMotion==nil else { return }
    if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
    if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
    source = nil
    tap = nil
  }
  func finishReturnIfDrained() {
    guard
      ownership.ready(
        handoff.token, held: !localKeys.isEmpty || !localButtons.isEmpty || !localFlags.isEmpty || dockSource.active || sourceGesture.remoteActive),
      let token = ownership.pendingReturn
    else { return }
    // Restore source ownership first. ACK still follows all earlier input frames
    // in the same serial TX queue. If restoration fails, close instead of ACKing.
    let started=returnStartedAt
    guard restoreLocal(deferActivation:true,useReturnCarry:true) else {
      stop()
      status("Return cancelled; connection closed. " + recoveryNotice)
      return
    }
    sourceReturnRestoredAt=ProcessInfo.processInfo.systemUptime
    ownership.pendingReturn = nil
    guard control("returnAck", token: token) else { return }
    let g=generation
    if let started {status(String(format:"Return cursor restored; ACK queued %.1f ms",(ProcessInfo.processInfo.systemUptime-started)*1000))}
    DispatchQueue.main.async { [weak self] in
      guard let self,self.generation==g,self.handoff.phase == .local,self.activationRestorePending,!self.cursorResources.needsRecovery else{return}
      self.activationRestorePending=false;self.restoreSourceActivation?()
    }
  }
  func configureAuto(_ enabled: Bool, edge: Edge) {
    guard displayBarrier == nil else{if !enabled {cancelDesktopFocusRestore();_ = restoreLocal()};auto=false;forward=false;return}
    guard !lockedTransportOnly else{auto=false;forward=false;return}
    defer {sendCursorMode()}
    if let token = handoff.token { _ = control("cancel", token: token) }
    forceLocal()
    auto =
      enabled && sender && connection != nil && key != nil && !ownership.blocked && dockOrphanMotion==nil && !sourceGesture.blockAuto
      && cursorResources.canAcquire && topologyUnchanged()
      && inputPermissionsReady()
    selectedEdge = edge
    handoff.edge = edge
    if enabled && multiDisplayDesktopCompatible {
      if let desktop=receiverDesktop,desktop.valid,let origin=sourceOrigin,let bounds=topology?.bounds,!desktop.portals(sourceRect:CGRect(origin:origin,size:bounds.size)).isEmpty {}
      else {auto=false;status("Auto not armed: waiting for a valid desktop portal.")}
    } else if enabled {
      if let size = remoteDisplaySize, let bounds = topology?.bounds {
        let layout = ScreenArrangement(
          sourceSize: bounds.size, remoteSize: size, remoteOnRight: edge == .right,
          offsetY: layoutOffsetY)
        if !layout.isValid {
          auto = false
          status("Auto not armed: screens do not overlap vertically. Adjust Screen layout.")
        }
      } else {
        auto = false
        status("Auto not armed: waiting for peer screen geometry.")
      }
    }
    if auto {
      forward = false
      status("Local input active. Automatic edge handoff armed (" + selectedEdge.rawValue + ").")
    } else if enabled {
      status(
        "Auto not armed. Connect first, grant Accessibility and release held inputs. "
          + recoveryNotice)
    }
  }
  func sendCursorMode() {
    guard sender,authenticated,cursorVisibilityCompatible else{return}
    guard enqueue(Wire(kind:"cursorMode",session:session,sequence:0,cursorMode:auto)) else{stop(reason:lastEnqueueFailure);return}
  }
  @discardableResult func restoreReceiverCursor()->Bool {
    let lease=receiverCursor.leaseID
    let ok=receiverCursor.restore()
    if ok {releaseReceiverCursorFocus?()}
    if !ok,let lease {retryReceiverCursor(lease,remaining:3)}
    return ok
  }
  func retryReceiverCursor(_ lease:UUID,remaining:Int) {
    guard remaining>0 else{return}
    DispatchQueue.main.asyncAfter(deadline:.now()+0.25) { [weak self] in
      guard let self,self.receiverCursor.leaseID==lease else{return}
      if self.receiverCursor.restore(expectedLeaseID:lease) {self.releaseReceiverCursorFocus?();if self.context==nil {self.removeCaptureIfClean()}}
      else {self.retryReceiverCursor(lease,remaining:remaining-1)}
    }
  }
  var receiverWantsCursorHidden:Bool {
    // Disabled by user: do not hide or acquire foreground solely for receiver visibility.
    false
  }
  func cursorDiagnostic(_ reason:String) {
    let summary="reason="+reason+" auth=\(authenticated) cap=\(cursorVisibilityCompatible) input=\(inject) mode=\(sourceAutoCursorMode) phase=\(handoff.phase) foreground=\(NSApp?.isActive ?? false) listen=\(CGPreflightListenEventAccess()) hideOwned=\(receiverCursor.isHidden) override=\(receiverCursorLocalOverride) focusAttempts=\(receiverFocusRetry.attempts)"
    if summary != lastCursorDiagnostic {lastCursorDiagnostic=summary;connectionLog("Cursor ownership \(summary)")}
  }
  func receiverLocalCursorOverride(reason:String="local-input-or-app-change") {
    guard !sender else{return}
    if displayBarrier != nil {displayBarrier?.savedConsent=false}
    receiverCursorLocalOverride=true
    if let pending=receiverActivationPendingToken {
      receiverActivationPendingToken=nil;receiverActivationDeadline=nil
      _ = control("cancel",token:pending);_ = handoff.reset();releaseInputs()
    }
    receiverLocalUserIntent?()
    _ = restoreReceiverCursor();cursorDiagnostic("local-override-"+reason)
  }
  @discardableResult func syncReceiverCursor()->Bool {
    guard !sender else{return true}
    let hide=receiverWantsCursorHidden
    if hide {
      guard NSApp.isActive,receiverCursorFocusOwned?() == true else{requestReceiverCursorFocus?();cursorDiagnostic("foreground-wait-or-request");return true}
      guard let display=topology?.mainID,receiverCursor.hide(display:display) else{automaticReconnectSuspended=true;stop(reason:"Receiver cursor hide failed; input stopped safely");return false}
      cursorDiagnostic("hide-owned-foreground");return true
    }
    receiverFocusRetry.reset()
    let ok=restoreReceiverCursor();cursorDiagnostic("shown-or-not-needed");return ok
  }
  func consent(_ enabled: Bool) {
    guard displayBarrier == nil else{if !enabled {displayBarrier?.savedConsent=false};inject=false;return}
    guard !lockedTransportOnly else{inject=false;return}
    inject = enabled && !sender && inputPermissionsReady()
    if !inject {
      if let t = handoff.token { _ = control("cancel", token: t) }
      forceLocal()
    }
    if !sender {
      _ = control("available", width: inject ? 1 : 0)
      _ = syncReceiverCursor()
      status(
        inject
          ? "Receiver enabled. Waiting for a handoff or manual mirror." : "Receiver input disabled."
      )
    }
  }
  static func verifyReceiverWindowPresentationForTests(_ present:(Relay)->Void)->Bool {
    let socket=OwnedSocket(-1),ctx=SessionContext(OwnedSocket(-1)),r=Relay()
    r.sender=false;r.context=ctx;r.connection=socket;r.key=SymmetricKey(size:.bits256)
    r.inject=true;r.auto=false;r.handoff.phase = .targetActive;r.handoff.token=UUID().uuidString
    r.receiverCursorLocalOverride=false;r.streamFlags = .maskShift
    let token=r.handoff.token,g=r.generation,sequence=r.seq
    present(r)
    return r.context === ctx && !ctx.cancelled && r.connection === socket && r.authenticated && r.inject
      && r.handoff.phase == .targetActive && r.handoff.token==token && r.generation==g && r.seq==sequence
      && !r.receiverCursorLocalOverride && r.streamFlags == .maskShift
  }
  static func verifyDeviceLayoutPersistenceForTests()->Bool {
    final class Mock:CursorRecoveryAPI {
      func associate(_ a:Bool)->CGError {.success}
      func hide(display:CGDirectDisplayID)->CGError {.success}
      func show(display:CGDirectDisplayID)->CGError {.success}
      func warp(to:CGPoint)->CGError {.success}
    }
    let suite="ThunderControl.LayoutRoutingTests."+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
    defer{defaults.removePersistentDomain(forName:suite)}
    let store=SavedScreenLayoutStore(defaults:defaults),local=UUID().uuidString
    let a=LayoutDevicePair(localID:local,peerID:UUID().uuidString)!,b=LayoutDevicePair(localID:local,peerID:UUID().uuidString)!
    let source=CGDisplayBounds(CGMainDisplayID()).size,remote=CGSize(width:1920,height:1080)
    let layout=ScreenArrangement(sourceSize:source,remoteSize:remote,remoteOnRight:false,offsetY:10)
    guard store.save(layout,for:a) else{return false}
    func ready(_ pair:LayoutDevicePair)->Relay {
      let r=Relay(cursorResources:CursorRecoveryController(api:Mock()),receiverCursor:CursorVisibilityController(api:Mock()),layoutStore:store)
      r.sender=true;r.layoutDevicePair=pair;r.pendingInitialLayoutRestore=true
      r.receiveControl(Wire(kind:"available",session:UUID().uuidString,sequence:1,width:0,screenWidth:remote.width,screenHeight:remote.height))
      return r
    }
    let first=ready(a)
    guard first.selectedEdge == .left,first.layoutOffsetY==10,first.editScreenLayout(edge:.left,offset:20) else{return false}
    let other=ready(b)
    guard other.selectedEdge == .right,other.layoutOffsetY==0 else{return false}
    let again=ready(a)
    guard again.selectedEdge == .left,again.layoutOffsetY==20 else{return false}
    guard again.editScreenLayout(edge:.right,offset:30) else{return false}
    again.receiveControl(Wire(kind:"available",session:UUID().uuidString,sequence:2,width:0,screenWidth:remote.width,screenHeight:remote.height))
    let ok=again.selectedEdge == .right && again.layoutOffsetY==30 && !again.pendingInitialLayoutRestore
    if ok {print("PASS actual layout edit/save/first-geometry restore routing; peer isolation and repeated metadata do not overwrite edits; mocked cursor only")}
    return ok
  }
  static func verifyStaleActiveForTests()->Bool {
    var fds:[Int32]=[0,0]
    guard socketpair(AF_UNIX,SOCK_STREAM,0,&fds)==0 else{return false}
    defer{close(fds[1])}
    let socket=OwnedSocket(fds[0]),ctx=SessionContext(OwnedSocket(dup(fds[0])))
    defer{ctx.cancel(reason:"Stale-active memory fixture finished")}
    let subject=Relay();subject.context=ctx;subject.connection=socket;subject.key=SymmetricKey(size:.bits256);subject.sender=true
    let g=subject.generation
    subject.receiveControl(Wire(kind:"active",session:UUID().uuidString,sequence:1,token:UUID().uuidString))
    return subject.context === ctx && !ctx.cancelled && subject.generation==g && subject.handoff.phase == .local
  }
  // Actual Dock routing + focus-loss + active-ack transitions; all outputs,
  // cursor resources and platform observations are inert fixture replacements.
  static func verifyReceiverSingleMapReadForTests()->Bool {
    final class Mock:CursorRecoveryAPI {
      func associate(_ associated:Bool)->CGError{.success}
      func hide(display:CGDirectDisplayID)->CGError{.success}
      func show(display:CGDirectDisplayID)->CGError{.success}
      func warp(to point:CGPoint)->CGError{.success}
    }
    let map=ReceiverDesktop(revision:7,mainID:11,displays:[ReceiverDisplay(id:11,bounds:CGRect(x:0,y:0,width:1920,height:1080)),ReceiverDisplay(id:99,bounds:CGRect(x:-1512,y:-945,width:1512,height:945))],virtualDisplayID:99)
    for origin in [CGPoint(x:500,y:200),CGPoint(x:-800,y:-300)] {
      let r=Relay(cursorResources:CursorRecoveryController(api:Mock()))
      let ctx=SessionContext(OwnedSocket(-1));defer{ctx.cancel(reason:"single-map fixture end")}
      r.connection=OwnedSocket(-1);r.context=ctx;r.key=SymmetricKey(size:.bits256)
      r.safetyObserversInstalled=true;r.gestureTrace.setEnabled(false)
      var reads=0,posts=0,epoch:UInt64=0
      r.desktopMapReadForTests={_,_ in reads+=1;return map}
      r.desktopEpochForTests={epoch};r.desktopInputPermissionForTests={true}
      r.desktopInputPostForTests={_ in posts+=1}
      let token=UUID().uuidString
      r.prepareDesktopSystemGestureForTests(map:map,point:origin,token:token)
      func packet(_ point:CGPoint,token:String)->Wire? {
        guard let event=CGEvent(mouseEventSource:nil,mouseType:.mouseMoved,mouseCursorPosition:point,mouseButton:.left) else{return nil}
        event.flags=[];event.setDoubleValueField(.mouseEventDeltaX,value:1);event.setDoubleValueField(.mouseEventDeltaY,value:0)
        guard let bytes=event.data else{return nil}
        return Wire(kind:"event",session:r.session,sequence:1,raw:5,data:bytes as Data,token:token,desktopMapRevision:7,desktopGlobalX:point.x,desktopGlobalY:point.y)
      }
      func freshSession(){r.sessionSnapshot=SessionSafetySnapshot(onConsole:true,loginDone:true,screenLocked:false);r.lastSessionPoll=ProcessInfo.processInfo.systemUptime}
      for n in 1...100 {
        freshSession()
        guard let w=packet(CGPoint(x:origin.x+CGFloat(n),y:origin.y),token:token) else{return false}
        r.receive(w)
        guard reads==n,posts==n else{fputs("Receiver single-map fixture: read/post count mismatch\n",stderr);return false}
      }
      let next=CGPoint(x:origin.x+101,y:origin.y)
      guard let stale=packet(next,token:UUID().uuidString),let valid=packet(next,token:token) else{return false}
      freshSession();r.receive(stale)
      guard reads==100,posts==100 else{return false}
      r.desktopInputPermissionForTests={false};freshSession();r.receive(valid)
      guard reads==100,posts==100 else{return false}
      r.desktopInputPermissionForTests={true}
      r.desktopBeforeGateForTests={epoch+=1};freshSession();r.receive(valid)
      guard reads==101,posts==100,r.displayTopologyTransitionActive else{return false}
    }
    print("PASS receiver mouse: exactly one fresh map per event on physical/virtual targets; stale token, permission loss and epoch race reject; no OS posting")
    return true
  }
  static func verifyDockFocusReturnForTests()->Bool {
    final class Mock:CursorRecoveryAPI {
      func associate(_ associated:Bool)->CGError{.success}
      func hide(display:CGDirectDisplayID)->CGError{.success}
      func show(display:CGDirectDisplayID)->CGError{.success}
      func warp(to point:CGPoint)->CGError{.success}
    }
    let r=Relay(cursorResources:CursorRecoveryController(api:Mock()))
    let socket=OwnedSocket(-1),ctx=SessionContext(OwnedSocket(-1))
    defer{ctx.cancel(reason:"Dock focus return fixture end")}
    r.context=ctx;r.connection=socket;r.key=SymmetricKey(size:.bits256)
    r.sender=true;r.auto=true;r.experimental=true;r.gestureCompatible=true
    r.receiverGestureAvailable=true;r.multiDisplayDesktopCompatible=true;r.desktopSystemGestureCompatible=true
    r.safetyObserversInstalled=true;r.gestureTrace.setEnabled(false)
    let topology=DisplayTopologySnapshot(mainID:1,activeIDs:[1],bounds:CGRect(x:0,y:0,width:1200,height:800))
    r.topology=topology;r.desktopSourceReadForTests={topology}
    var owned=true,frames=[Wire]()
    r.desktopFocusSafetyForTests={owned};r.desktopPhysicalInputsForTests={false}
    r.desktopEnqueueForTests={frames.append($0);return true}
    let map=ReceiverDesktop(revision:7,mainID:11,displays:[ReceiverDisplay(id:11,bounds:CGRect(x:0,y:0,width:1920,height:1080)),ReceiverDisplay(id:99,bounds:CGRect(x:-1512,y:-945,width:1512,height:945))],virtualDisplayID:99)
    let p=CGPoint(x:-400,y:-300),generation=r.generation
    let begin=DockGestureDescriptor(motion:2,phase:1,progress:0,velocityX:0,velocityY:0)
    let change=DockGestureDescriptor(motion:2,phase:2,progress:0.2,velocityX:0,velocityY:1)
    let end=DockGestureDescriptor(motion:2,phase:4,progress:0.3,velocityX:0,velocityY:0)
    func arm()->String {
      let token=UUID().uuidString
      r.desktopPrepareFocusForTests(map:map,origin:CGPoint(x:-2712,y:-945),point:p)
      r.desktopPortal=map.portals(sourceRect:CGRect(x:-2712,y:-945,width:1200,height:800)).first
      r.handoff.token=token
      return token
    }
    let old=arm()
    guard r.routeDockGesture(begin)==true,r.routeDockGesture(change)==true else{return false}
    owned=false
    // Reproduce viewer focus loss before the asynchronous callback, while
    // app activation alone could still report true. Old stream is quarantined.
    guard r.routeDockGesture(change)==true,r.handoff.phase == .local,r.auto,
      r.dockOrphanMotion==2,r.context === ctx,!ctx.cancelled else{return false}
    let count=frames.filter{$0.kind=="dock"}.count
    _ = r.routeDockGesture(end)
    guard r.dockOrphanMotion==nil else{return false}
    // A local begin arriving during ownership negotiation must cancel the
    // active acknowledgement, not turn its terminal into remote no-begin.
    owned=true
    let pending=arm();r.handoff.phase = .committed
    _ = r.routeDockGesture(begin)
    r.receiveControl(Wire(kind:"active",session:r.session,sequence:1,token:pending))
    guard r.handoff.phase == .local,r.dockLocalActive,r.auto,!ctx.cancelled else{return false}
    _ = r.routeDockGesture(end)
    guard !r.dockLocalActive else{return false}
    let fresh=arm()
    // Delayed callbacks/packets from the previous ownership token cannot
    // revoke the fresh stream; production token guards must sit them out.
    r.receiveControl(Wire(kind:"cancel",session:r.session,sequence:2,token:old))
    r.receiveControl(Wire(kind:"active",session:r.session,sequence:3,token:pending))
    for descriptor in [begin,change,end] {guard r.routeDockGesture(descriptor)==true else{return false}}
    let dock=frames.filter{$0.kind=="dock"}
    guard dock.count==count+3,dock.suffix(3).allSatisfy({$0.token==fresh && $0.desktopGestureTargetID==99 && $0.desktopMapRevision==7}),
      dock.suffix(3).compactMap({$0.dock?.phase}) == [1,2,4],!r.dockSource.active,
      r.generation==generation,r.context === ctx,!ctx.cancelled else{return false}
    r.experimental=false
    let before=frames.count
    guard r.routeDockGesture(begin)==true,frames.count==before else{return false}
    print("PASS Relay Dock focus return: local-stream negotiation race, focus-loss orphan drain, fresh target/token rearm, stale controls and consent; no OS posting")
    return true
  }
  static func verifyForegroundPausePreservesConnectionForTests() -> Bool {
    final class Mock: CursorRecoveryAPI {
      func associate(_ associated: Bool) -> CGError { .success }
      func hide(display: CGDirectDisplayID) -> CGError { .success }
      func show(display: CGDirectDisplayID) -> CGError { .success }
      func warp(to point: CGPoint) -> CGError { .success }
    }
    var fds:[Int32]=[0,0]
    guard socketpair(AF_UNIX,SOCK_STREAM,0,&fds)==0 else{return false}
    defer{close(fds[1])}
    let socket=OwnedSocket(fds[0]),context=SessionContext(socket)
    defer{context.cancel(reason:"Foreground pause fixture finished")}
    let subject=Relay(cursorResources:CursorRecoveryController(api:Mock()))
    subject.sender=true;subject.context=context;subject.connection=socket
    subject.key=SymmetricKey(size:.bits256);subject.auto=true;subject.forward=true
    subject.handoff.phase = .remote
    let generation=subject.generation,epoch=subject.automaticSuspensionEpoch
    subject.pauseSourceForForegroundLoss()
    return subject.context === context && subject.connection === socket && !context.cancelled
      && subject.key != nil && subject.generation==generation && subject.automaticSuspensionEpoch==epoch
      && !subject.automaticReconnectSuspended && subject.auto && !subject.forward && subject.handoff.phase == .local
  }
  static func verifyUnsafeStopOrderingForTests() -> Bool {
    final class Mock: CursorRecoveryAPI {
      func associate(_ associated: Bool) -> CGError { .success }
      func hide(display: CGDirectDisplayID) -> CGError { .success }
      func show(display: CGDirectDisplayID) -> CGError { .success }
      func warp(to point: CGPoint) -> CGError { .success }
    }
    var fds: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { return false }
    defer { close(fds[1]) }
    let owned = OwnedSocket(fds[0])
    let context = SessionContext(owned)
    let recovery = CursorRecoveryController(api: Mock())
    guard case .success = recovery.acquire(display: 1) else { return false }
    let subject = Relay(cursorResources: recovery)
    subject.context = context
    subject.connection = owned
    subject.key = SymmetricKey(size: .bits256)
    subject.sender = true
    subject.auto = true
    subject.forward = true
    subject.inject = true
    subject.handoff.phase = .remote
    subject.topology = DisplayTopologySnapshot(
      mainID: 1, activeIDs: [1], bounds: CGRect(x: 0, y: 0, width: 1000, height: 800))
    let generation = subject.generation
    var sawCancellationBeforeCallback = false
    subject.restoreSourceActivation = {
      sawCancellationBeforeCallback =
        context.cancelled && subject.context == nil && subject.connection == nil
        && subject.key == nil && subject.generation != generation && !subject.auto
        && !subject.forward && !subject.inject
    }
    subject.sessionBecameUnsafe("test unsafe session")
    subject.restoreSourceActivation = nil
    return sawCancellationBeforeCallback && !recovery.needsRecovery && context.cancelled
  }
  func stop(reason:String="Local Stop") {
    if desktopObserverActive {DesktopInjectionEpoch.shared.release();desktopObserverActive=false}
    desktopValidatedEpoch=nil
    let barrierCompletion=displayBarrierCompletion;displayBarrierCompletion=nil;displayBarrier=nil
    receiverOwnsMapTransition=false;receiverMapPublicationCandidate=nil
    authenticatedDevicePair=nil;authenticatedSharingPeerHost=nil;displayPreferenceCompatible=false;peerDisplayPreference=nil;concurrentDisplayCompatible=false;multiDisplayDesktopCompatible=false;desktopSystemGestureCompatible=false;displayBarrierTokens.removeAll();displayRemoteGeometryTemporary=false;displayRemoteOriginalLayout=nil
    receiverDesktop=nil;sourceOrigin=nil;receiverDesktopAdoptedRevision=0;receiverDesktopAdoptedFingerprint=nil;receiverDesktopPublishRevision=0;receiverDesktopPublishedFingerprint=nil;pendingInitialSourceOriginRestore=false
    // Preserve portal projection until forceLocal consumes it.
    onReceiverDesktopChanged?()
    defer {barrierCompletion?(.failure(Failure("Display transition interrupted")))}
    if let ctx=context {lastStopReason=ctx.terminalReason ?? reason}
    sourceAutoCursorMode=false;cursorVisibilityCompatible=false;receiverCursorLocalOverride=false;receiverFocusRetry.reset();sourceReturnRestoredAt=nil
    // Cut off both queues BEFORE cursor APIs, input releases or UI activation.
    auto = false
    forward = false
    inject = false
    lockedTransportOnly=false
    generation = UUID()
    context?.cancel(reason:lastStopReason.isEmpty ? reason : lastStopReason)
    context = nil
    connection = nil
    key = nil
    authenticatedPeerDisplayName=nil
    layoutDevicePair=nil;pendingInitialLayoutRestore=false
    timer?.invalidate()
    timer = nil
    forceLocal()
    cancelReceiverCursorFocus?()
    receiverAvailable = false
    receiverGestureAvailable=false
    receiverAppGestureAvailable=false
    appGestureCompatible=false
    sourceGesture.reset();receiverAppGesture.reset()
    remoteDisplaySize = nil
    displayGeometryChanged?(nil)
    bridgeCheckInFlight = false
    gestureCompatible = false
    localKeys.removeAll()
    localButtons.removeAll()
    localFlags = []
    gestureUntil = 0
    dockLocalActive=false
    removeCaptureIfClean()
    releaseInputs()
    if receiverCursor.needsRecovery {status(TCText("Waiting to restore the Receiver cursor's visibility. Click Stop to retry."));return}
    if cursorResources.needsRecovery {
      status(recoveryNotice)
      return
    }
    status(
      ownership.blocked
        ? "Stopped. Release remote-owned inputs; cleanup filtering active only while app and permission remain available. Hard quit or permission loss cannot guarantee orphan filtering."
        : "Stopped. Input forwarding and receiving disabled. Reason: " + lastStopReason)
  }
  func releaseInputs() {
    streamFlags = []
    keys.formUnion(modifiers)
    modifiers.removeAll()
    for k in keys {
      let e = CGEvent(keyboardEventSource: nil, virtualKey: k, keyDown: false)
      e?.setIntegerValueField(.eventSourceUserData, value: marker)
      e?.post(tap: .cghidEventTap)
    }
    keys.removeAll()
    for b in buttons {
      let t: CGEventType = b == 0 ? .leftMouseUp : b == 1 ? .rightMouseUp : .otherMouseUp
      if let e = CGEvent(
        mouseEventSource: nil, mouseType: t,
        mouseCursorPosition: CGEvent(source: nil)?.location ?? .zero,
        mouseButton: CGMouseButton(rawValue: b) ?? .left)
      {
        e.setIntegerValueField(.eventSourceUserData, value: marker)
        e.post(tap: .cghidEventTap)
      }
    }
    buttons.removeAll()
  }
  static func verifyReceiverPhysicalInputCancelsActivationForTests()->Bool {
    let relay=Relay();let token=UUID().uuidString
    relay.cursorVisibilityCompatible=true;relay.sourceAutoCursorMode=true
    relay.handoff.phase = .targetActive;relay.handoff.token=token
    relay.receiverActivationPendingToken=token;relay.receiverActivationDeadline=ProcessInfo.processInfo.systemUptime+0.4
    var canceledFocus=false;relay.receiverLocalUserIntent={canceledFocus=true}
    guard let event=CGEvent(mouseEventSource:nil,mouseType:.mouseMoved,mouseCursorPosition:.zero,mouseButton:.left) else{return false}
    event.setIntegerValueField(.eventSourceUnixProcessID,value:0);event.setIntegerValueField(.eventSourceUserData,value:0)
    _ = relay.handle(.mouseMoved,event)
    relay.finishReceiverActivation(token:token,generation:relay.generation,ready:true)
    return canceledFocus && relay.receiverCursorLocalOverride && relay.receiverActivationPendingToken==nil && relay.handoff.phase == .local && !relay.hasSession
  }
  static func verifyReceiverRecoveryBlocksStartForTests()->Bool {
    final class FailingShow:CursorRecoveryAPI {
      var touchesRealCursor=false
      func associate(_ associated:Bool)->CGError {touchesRealCursor=true;return .failure}
      func hide(display:CGDirectDisplayID)->CGError {.success}
      func show(display:CGDirectDisplayID)->CGError {.failure}
      func warp(to point:CGPoint)->CGError {touchesRealCursor=true;return .failure}
    }
    let mock=FailingShow(),visible=CursorVisibilityController(api:FailingShow())
    guard visible.hide(display:1) else{return false}
    let relay=Relay(cursorResources:CursorRecoveryController(api:mock),receiverCursor:visible)
    do {try relay.start(name:"not-a-real-interface",peer:"",pass:"0000",port:49177,sendMode:true);return false}
    catch {return String(describing:error).contains("Cursor recovery must finish") && !relay.hasSession && !relay.sender && visible.needsRecovery && !mock.touchesRealCursor}
  }
  @discardableResult func start(name: String, peer: String, pass: String, port: UInt16, sendMode: Bool,automaticStart:Bool=false,lockedTransport:Bool=false,lockedPermitEpoch:UInt64?=nil,expectedRoutePair:LayoutDevicePair?=nil,fastRouteAttempt:Bool=false) throws -> Bridge {
    let attemptStartedAt=ProcessInfo.processInfo.systemUptime
    guard displayLease == nil,displayBarrier == nil else{throw Failure("Stop the owned display before reconnecting input")}
    stop()
    guard expectedRoutePair==nil || automaticStart else{throw Failure("Remembered peer binding is restricted to automatic reconnect")}
    guard !fastRouteAttempt || (automaticStart && sendMode && expectedRoutePair != nil) else{throw Failure("Fast route is restricted to a bound automatic sender reconnect")}
    guard cursorResources.canAcquire,!receiverCursor.needsRecovery,receiverFocusRecoveryPending?() != true else{throw Failure("Cursor recovery must finish before starting either role; use Stop to retry recovery")}
    if lockedTransport {
      guard automaticStart,lockedTransportEligible,(!automaticReconnectSuspended || lockedPermitEpoch==automaticSuspensionEpoch) else{throw Failure("Locked transport requires a verified logged-in locked session")}
    } else if automaticStart {
      guard !automaticReconnectSuspended,!sessionLockedSignal,currentSessionBlockReason(forceRefresh:true)==nil else{throw Failure(TCText("Automatic reconnection paused for safety. Click Connect or Resume Listening."))}
    } else {try prepareSessionForExplicitStart();automaticReconnectSuspended=false}
    guard lockedTransport || inputPermissionsReady() else{throw Failure("Allow Accessibility and Input Monitoring before connecting")}
    guard !ownership.blocked,dockOrphanMotion==nil,!sourceGesture.blockAuto else {
      throw Failure("Release all held inputs/fingers before reconnecting; if gesture cleanup missed, quit and reopen after lifting fingers")
    }
    guard cursorResources.canAcquire else {
      throw Failure(
        recoveryNotice.isEmpty ? "Cursor recovery must finish before reconnecting" : recoveryNotice)
    }
    guard automaticStart || !sendMode || (pass.utf8.count==4 && pass.utf8.allSatisfy({(48...57).contains($0)})) else {throw Failure("Set a fresh 4-digit pairing code")}
    lockedTransportOnly=lockedTransport
    do {
      if lockedTransport {
        topology = nil
      } else if sendMode {
        // Source still runs on exactly one display; multi-display source
        // changes identity/capture guarantees and is out of scope for 0.8.20.
        topology = try captureSingleDisplayTopology()
      } else {
        // Receiver may already be multi-display at connect time. Anchor the
        // input coordinate space on the main display identity+bounds, and
        // use the ReceiverDesktop map protocol for anything else.
        let desktop = try readReceiverDesktop(revision:1,virtualDisplayID:nil)
        guard desktop.valid, let main = desktop.displays.first(where: { $0.id == desktop.mainID }) else {
          throw Failure("receiver desktop enumeration unstable")
        }
        topology = DisplayTopologySnapshot(mainID: desktop.mainID,
          activeIDs: desktop.displays.map { $0.id }.sorted(),
          bounds: main.bounds)
      }
    } catch {
      throw Failure(
        "Display identity/topology could not be verified. On the source Mac use exactly one display: \(error)"
      )
    }
    let b = try bridge(name)
    let remote = sendMode ? try address(peer, port) : nil
    let initial = OwnedSocket(try boundSocket(b, sendMode ? 0 : port))
    if !sendMode {guard listen(initial.fd,1)==0 else{throw Failure("Cannot listen on Thunderbolt socket")}}
    let sessionContext = SessionContext(initial,fastRoute:fastRouteAttempt)
    self.context = sessionContext
    let localSession = UUID().uuidString
    sender = sendMode
    key = nil
    session = localSession
    seq = 1
    let g = generation
    displayBounds = topology?.bounds ?? .zero
    lastInput = ProcessInfo.processInfo.systemUptime

    timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      guard let self, self.generation == g else { return }
      if self.lockedTransportOnly {self.tickLockedTransport(context:sessionContext,generation:g,bridge:b);return}
      self.publishLayoutEligibility()
      if !self.sender,self.authenticated,!self.syncReceiverCursor() {self.safetyStop("Receiver cursor visibility could not be restored");return}
      if let reason = self.currentSessionBlockReason() {
        self.sessionBecameUnsafe(reason,origin:self.polledSessionSuspensionOrigin)
        return
      }
      if self.sender && (self.forward || self.handoff.phase == .remote) && !NSApp.isActive {
        self.pauseSourceForForegroundLoss()
        return
      }
      _ = self.detectReceiverMapTransition()
      self.tickDisplayTopologyTransition()
      guard self.generation==g else{return}
      guard self.displayBarrier != nil || self.topologyUnchanged() else {
        if self.pauseReceiverTopologyFailure() {return}
        self.stop()
        self.status("Display identity or topology changed. Session stopped. " + self.recoveryNotice)
        return
      }
      if self.authenticated && !inputPermissionsReady() {
        self.safetyStop("Accessibility or Input Monitoring permission lost")
        return
      }
      let now = ProcessInfo.processInfo.systemUptime
      if self.receiverActivationPendingToken != nil,let deadline=self.receiverActivationDeadline,now>=deadline {self.safetyStop("Receiver foreground restore deadline exceeded");return}
      if self.connection==nil,sessionContext.authenticationExpired(now:now) {sessionContext.cancel(reason:sessionContext.authenticationTimeoutReason);self.stop(reason:sessionContext.authenticationTimeoutReason);return}
      if self.sourceGesture.expired(now:now) || self.receiverAppGesture.expired(now:now) {self.stop(reason:"App gesture stream expired; lift fingers, then explicitly reconnect");return}
      if self.dockSource.expired(now:now) || self.dockReceiver.expired(now:now) {self.stop(reason:"System gesture stream timed out; lift all fingers");return}
      let oldPhase = self.handoff.phase
      let oldToken = self.handoff.token
      if self.handoff.tick(now, preserveState: true) == .restore {
        if returnTimeoutMustCancel(oldPhase) {
          self.stop()
          self.status("Return drain timed out. Connection closed; local restored.")
          return
        }
        if let t = oldToken { _ = self.control("cancel", token: t) }
        self.forceLocal()
        self.status("Handoff timed out. Local input restored.")
      }
      if heartbeatExpired(authenticated: self.connection != nil, idle: now - self.lastInput) {
        self.stop()
        self.status("Peer heartbeat lost. Local restored.")
        return
      }
      guard now - self.lastBridgeCheck >= 1 else { return }
      self.lastBridgeCheck = now
      if self.sender && self.connection != nil { _ = self.control("ping") }
      if !self.sender && self.connection != nil {
        _ = self.control("available", width: self.inject ? 1 : 0)
      }
      self.checkBridgeContinuity(b,generation:g)
    }
    status(
      sendMode
        ? "Connecting through \(b.name) \(b.ip)…" : "Listening ONLY on \(b.name) \(b.ip):\(port)")
    var pendingPIN:String?=sendMode ? pass : nil
    DispatchQueue.global().async { [self] in
      defer {pendingPIN=nil}
      var stage = sendMode ? "TCP connect" : "TCP accept"
      do {
        let connected: OwnedSocket
        if let remoteAddress = remote {
          try connectBound(initial, remoteAddress, sessionContext,timeout:fastRouteAttempt ? 0.75:5)
          connected = initial
        } else {
          connected = try acceptBound(initial, sessionContext)
        }
        let c = connected.fd
        try setBlocking(c)
        let transportReadyAt=ProcessInfo.processInfo.systemUptime
        var noDelay: Int32 = 1
        guard
          setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))
            == 0
        else { throw Failure("Cannot enable TCP_NODELAY") }
        stage = "Encrypted handshake"
        var acceptedIndex = b.index
        guard
          setsockopt(
            c, IPPROTO_IP, IP_BOUND_IF, &acceptedIndex,
            socklen_t(MemoryLayout.size(ofValue: acceptedIndex))) == 0
        else { throw Failure("Connected bridge binding failed") }
        guard !sessionContext.cancelled else { return }
        var sendTimeout = timeval(tv_sec: 5, tv_usec: 0)
        var noSignal: Int32 = 1
        guard setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, 4) == 0 else {
          throw Failure("Cannot disable socket SIGPIPE")
        }
        var keepalive: Int32 = 1
        var idle: Int32 = 5
        var interval: Int32 = 2
        var retries: Int32 = 3
        guard
          setsockopt(
            c, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
          setsockopt(c, SOL_SOCKET, SO_KEEPALIVE, &keepalive, 4) == 0,
          setsockopt(c, IPPROTO_TCP, TCP_KEEPALIVE, &idle, 4) == 0,
          setsockopt(c, IPPROTO_TCP, TCP_KEEPINTVL, &interval, 4) == 0,
          setsockopt(c, IPPROTO_TCP, TCP_KEEPCNT, &retries, 4) == 0
        else { throw Failure("Socket liveness configuration failed") }
        var timeout = timeval(tv_sec: 90, tv_usec: 0)
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        sessionContext.beginAuthentication()
        guard PairingAttemptLimiter.shared.consume() else{throw Failure("Too many pairing attempts; wait one minute and generate a fresh code")}
        stage="Trusted pairing"
        let pairingScope=try agreePairingScope(sendMode:sendMode,localSession:localSession,send:{try sendFrame(c,$0)},receive:{try readFrame(c,maximum:256)})
        let io=PINPairingTransport(send:{data in guard !sessionContext.cancelled else{throw Failure("Pairing cancelled")};do {try sendFrame(c,data)} catch {if isTransientTransportFailure(error) {sessionContext.cancel(reason:"Pairing transport interrupted")};throw error}},receive:{guard !sessionContext.cancelled else{throw Failure("Pairing cancelled")};do {return try readFrame(c,maximum:4096)} catch {if isTransientTransportFailure(error) {sessionContext.cancel(reason:"Pairing transport interrupted")};throw error}},cancelled:{sessionContext.cancelled})
        let proofStartedAt=ProcessInfo.processInfo.systemUptime
        let k:SymmetricKey
        var verifiedPairingIDs:(String,String)?
        do {defer{pendingPIN=nil}
        k=try performTrustedPairing(isSender:sendMode,senderPIN:pendingPIN,sessionID:pairingScope,localName:BridgeDiscoveryValidation.displayName(Host.current().localizedName ?? "ThunderControl Mac"),transport:io,allowNewTrust:expectedRoutePair == nil && !lockedTransport && (!automaticStart || !sendMode),allowKeychainInteraction:!automaticStart,authenticatedIdentity:{local,peer in verifiedPairingIDs=(local,peer)},receiverApproval:{request in
          guard let approval=self.approvePIN else{throw Failure("Receiver approval unavailable")}
          return try approval(request,{sessionContext.cancelled})
        })
        }
        let proofFinishedAt=ProcessInfo.processInfo.systemUptime
        stage="Encrypted role confirmation"
        try sendFrame(
          c,
          seal(
            Wire(
              concurrentDisplayCodec:1,kind: sendMode ? "sender-hello-v5" : "receiver-hello-v5", session: localSession,
              sequence: 0, os: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,osBuild:systemBuildIdentifier(),gestureCodec:DockGestureCodec.supported ? 1 : 0,appGestureCodec:AppGestureCodec.supported ? 1 : 0,cursorVisibilityCodec:1,peerDisplayName:ConnectionNotificationTracker.displayName(Host.current().localizedName ?? "ThunderControl Mac"),multiDisplayDesktopCodec:1,desktopGestureCodec:DockGestureCodec.supported ? 1:0,displayPreferenceCodec:1), k))
        var remoteHello = try unseal(readFrame(c), k)
        guard (sendMode || remoteHello.session==pairingScope),remoteHello.kind == (sendMode ? "receiver-hello-v5" : "sender-hello-v5") else {
          throw Failure("Handshake role mismatch")
        }
        let compatible =
          remoteHello.os == ProcessInfo.processInfo.operatingSystemVersion.majorVersion && remoteHello.gestureCodec==1 && remoteHello.osBuild != nil && remoteHello.osBuild==systemBuildIdentifier() && DockGestureCodec.supported
        let displayCompatible=remoteHello.concurrentDisplayCodec==1 || remoteHello.multiDisplayDesktopCodec==1
        let multiDisplayDesktopCompatibleNegotiated=remoteHello.multiDisplayDesktopCodec==1
        let desktopSystemGestureNegotiated=multiDisplayDesktopCompatibleNegotiated && compatible && remoteHello.desktopGestureCodec==1
        let displayPreferenceNegotiated=multiDisplayDesktopCompatibleNegotiated && remoteHello.displayPreferenceCodec==1
        let visibilityCompatible=remoteHello.cursorVisibilityCodec==1
        let appCompatible=AppGestureCodec.compatible(build:remoteHello.osBuild,codec:remoteHello.appGestureCodec)
        remoteHello.kind = "hello"
        var v = Validator()
        try v.accept(remoteHello)
        guard let ids=verifiedPairingIDs,let confirmedLayoutPair=LayoutDevicePair(localID:ids.0,peerID:ids.1) else{throw Failure("Authenticated device identity unavailable")}
        guard routeIdentityMatches(confirmedLayoutPair,expected:expectedRoutePair) else{throw TrustedPairingError.failed}
        let senderNonce = sendMode ? localSession : remoteHello.session
        let receiverNonce = sendMode ? remoteHello.session : localSession
        let sessionKey = connectionKey(
          k, sender: senderNonce, receiver: receiverNonce, reverse: !sendMode)
        let incomingKey = connectionKey(
          k, sender: senderNonce, receiver: receiverNonce, reverse: sendMode)
        var peerValidator = PeerValidator(senderPeer: !sendMode, session: remoteHello.session,cursorVisibilitySupported:visibilityCompatible,concurrentDisplaySupported:displayCompatible,multiDisplayDesktopSupported:multiDisplayDesktopCompatibleNegotiated,desktopGesturesSupported:desktopSystemGestureNegotiated,displayPreferenceSupported:displayPreferenceNegotiated)
        timeout.tv_sec = 0
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        DispatchQueue.main.async {
          guard self.generation == g, !sessionContext.cancelled else { return }
          guard sessionContext.finishAuthentication(now:ProcessInfo.processInfo.systemUptime) else{sessionContext.cancel(reason:sessionContext.authenticationTimeoutReason);self.stop(reason:sessionContext.authenticationTimeoutReason);return}
          self.lastInput = ProcessInfo.processInfo.systemUptime
          connectionLog(String(format:"Connection timing route=%@ transportWaitMs=%.1f trustMs=%.1f roleAndQueueMs=%.1f totalMs=%.1f",fastRouteAttempt ? "cached":(expectedRoutePair == nil ? "normal":"discovered-bound"),(transportReadyAt-attemptStartedAt)*1000,(proofFinishedAt-proofStartedAt)*1000,(self.lastInput-proofFinishedAt)*1000,(self.lastInput-attemptStartedAt)*1000))
          if sendMode,let hint=AuthenticatedRouteHint(pair:confirmedLayoutPair,ipv4:peer,port:port) {_ = AuthenticatedRouteHintStore().save(hint)}
          DisplayPeerRoute.rememberAuthenticatedSocket(c)
          self.authenticatedDevicePair=confirmedLayoutPair;self.authenticatedSharingPeerHost=DisplayPeerRoute.authenticatedSocketHost(c);self.concurrentDisplayCompatible=displayCompatible
          self.multiDisplayDesktopCompatible=multiDisplayDesktopCompatibleNegotiated;self.desktopSystemGestureCompatible=desktopSystemGestureNegotiated
          self.displayPreferenceCompatible=displayPreferenceNegotiated;self.peerDisplayPreference=nil
          self.layoutDevicePair=sendMode ? confirmedLayoutPair:nil
          self.pendingInitialLayoutRestore=sendMode
          self.pendingInitialSourceOriginRestore=sendMode
          self.receiverDesktop=nil;self.sourceOrigin=nil
          self.receiverDesktopAdoptedRevision=0
          self.receiverDesktopAdoptedFingerprint=nil
          self.receiverDesktopPublishRevision=0
          self.receiverDesktopPublishedFingerprint=nil
          if sendMode {self.selectedEdge = .right;self.layoutOffsetY=0}
          self.authenticatedPeerDisplayName=ConnectionNotificationTracker.displayName(remoteHello.peerDisplayName ?? TCText("Bridge peer"))
          self.key = sessionKey
          self.connection = connected
          self.gestureCompatible = compatible
          self.appGestureCompatible=appCompatible
          self.cursorVisibilityCompatible=visibilityCompatible
          let peerBuild=remoteHello.osBuild.flatMap {v in v.utf8.count<32 && v.utf8.allSatisfy({(48...57).contains($0)||(65...90).contains($0)||(97...122).contains($0)}) ? v : nil}
          self.status("Gesture build metadata: local="+(systemBuildIdentifier() ?? "unavailable")+", peer="+(peerBuild ?? "unavailable"))
          self.experimental=compatible;self.appGestureExperimental=appCompatible
          if self.lockedTransportOnly {
            self.auto=false;self.forward=false;self.inject=false
            if !self.sender {_ = self.control("available",width:0)}
            self.status(TCText("Authenticated connection established: input is blocked while locked. After unlocking, input starts with fresh authentication."))
            return
          }
          do {
            self.forward = false
            self.inject = false
            guard inputPermissionsReady() else{self.safetyStop("Input permissions missing after authentication");return}
            try self.capture()
            if !self.sender,self.automaticSharingInputAllowed(false) {self.consent(true)}
            self.status(visibilityCompatible ? TCText("Two-way cursor visibility switching available: enable automatic switching and Receiver input to show the cursor only on the active Mac.") : TCText("Two-way cursor visibility requires 0.6.6 or later on both Macs. Existing input forwarding continues."))
            self.status(appCompatible ? TCText("App zoom/rotate/swipe enabled by default") : TCText("App gestures unavailable because OS builds differ."))
            self.status(compatible ? TCText("Authentication complete. Input and screen crossing are enabled automatically.") : TCText("Authentication complete. Basic input enabled automatically; system gestures disabled because OS builds differ."))
          } catch {
            self.safetyStop("Input capture unavailable; restart after permission approval")
            self.status(safeConnectionError(error))
          }
        }
        stage = "Authenticated stream"
        while !sessionContext.cancelled {
          let w = try unseal(readFrame(c), incomingKey)
          try peerValidator.accept(w)
          guard self.inbound.wait(timeout: .now()) == .success else {
            throw Failure("Inbound queue overload")
          }
          let inputQueuedAt=ProcessInfo.processInfo.systemUptime
          DispatchQueue.main.async {
            defer { self.inbound.signal() }
            guard self.generation == g, !sessionContext.cancelled else { return }
            self.noteInputQueue(w,queuedAt:inputQueuedAt)
            self.receive(w)
          }
        }
        sessionContext.cancel(reason:"Session loop ended")
      } catch {
        let failureStage = stage
        let reason = safeConnectionError(error)
        let terminal="\(failureStage): \(reason)"
        sessionContext.cancel(reason:terminal)
        DispatchQueue.main.async {
          guard self.generation == g else { return }
          if shouldSuspendAutomaticReconnect(stage:failureStage,error:error,terminalReason:sessionContext.terminalReason) {self.automaticReconnectSuspended=true}
          self.stop(reason:sessionContext.terminalReason ?? terminal)
          self.status(sessionContext.terminalReason ?? terminal)
        }
      }
    }
    return b
  }
  func checkBridgeContinuity(_ expected:Bridge,generation g:UUID) {
    guard !bridgeCheckInFlight else{return}
    bridgeCheckInFlight=true
    bridgeMonitor.async {[weak self] in
      let verified=try? bridge(expected.name)
      DispatchQueue.main.async {
        guard let self,self.generation==g else{return}
        self.bridgeCheckInFlight=false
        if verified != expected {self.bridgeBecameUnavailable?();self.stop(reason:"Bridge changed or lost")}
      }
    }
  }
  func tickLockedTransport(context expected:SessionContext,generation g:UUID,bridge b:Bridge) {
    guard lockedTransportEligible else{stop(reason:"Locked standby session ended");return}
    let now=ProcessInfo.processInfo.systemUptime
    if connection==nil,expected.authenticationExpired(now:now) {expected.cancel(reason:expected.authenticationTimeoutReason);stop(reason:expected.authenticationTimeoutReason);return}
    if heartbeatExpired(authenticated:authenticated,idle:now-lastInput){stop(reason:"Standby heartbeat lost");return}
    guard now-lastBridgeCheck>=1 else{return}
    lastBridgeCheck=now
    if authenticated {_ = sender ? control("ping"):control("available",width:0)}
    checkBridgeContinuity(b,generation:g)
  }
  static func verifyLockedTransportInputBarrierForTests()->Bool {
    var fds:[Int32]=[0,0]
    guard socketpair(AF_UNIX,SOCK_STREAM,0,&fds)==0 else{return false}
    defer{close(fds[1])}
    let r=Relay();r.lockedTransportOnly=true
    let owned=OwnedSocket(fds[0]);r.context=SessionContext(owned);r.connection=owned;r.key=SymmetricKey(size:.bits256)
    r.configureAuto(true,edge:.right);r.consent(true)
    r.receive(Wire(kind:"event",session:"test",sequence:1,raw:10,data:Data([0])))
    r.receiveControl(Wire(kind:"begin",session:"test",sequence:2))
    do {try r.capture();return false}catch{}
    let ok = !r.auto && !r.forward && !r.inject && r.tap==nil && r.handoff.phase == .local && r.authenticated && r.hasSession
    r.stop();return ok
  }
  func capture() throws {
    guard !lockedTransportOnly else{throw Failure("Input capture forbidden in locked transport")}
    guard tap == nil else { return }
    let mask: CGEventMask = UInt64.max
    guard
      let t = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
        eventsOfInterest: mask,
        callback: { _, type, event, ctx in
          let r = Unmanaged<Relay>.fromOpaque(ctx!).takeUnretainedValue()
          r.callbackReplacement=nil
          let suppressed=r.handle(type,event)
          if let replacement=r.callbackReplacement {r.callbackReplacement=nil;return Unmanaged.passRetained(replacement)}
          return suppressed ? nil : Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
    else {
      throw Failure("Input Monitoring permission needed for local emergency key and sender capture")
    }
    tap = t
    source = CFMachPortCreateRunLoopSource(nil, t, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: t, enable: true)
  }
  @discardableResult
  func enqueue(_ input: Wire) -> Bool {
    if displayBarrier != nil,["event","dock","appGesture","begin","ready","commit","active","return","returnAck"].contains(input.kind) {return false}
    if lockedTransportOnly {
      guard lockedTransportEligible,lockedTransportOutgoingAllowed(input) else{return false}
    } else if let reason = currentSessionBlockReason() {
      sessionBecameUnsafe(reason,origin:polledSessionSuspensionOrigin)
      return false
    }
    guard let k=key,let socket=connection,let ctx=context else {lastEnqueueFailure="No authenticated transport";return false}
    guard !ctx.cancelled else {lastEnqueueFailure=ctx.terminalReason ?? "Transport already cancelled";connectionLog("TX rejected: \(self.lastEnqueueFailure)");return false}
    guard pending.wait(timeout:.now()) == .success else {lastEnqueueFailure="Output queue full";connectionLog("TX rejected: output queue full");return false}
    var w = input
    w.sequence = seq
    seq += 1
    traceGesture(stage:.txQueued,packet:w)
    let g = generation
    out.async {
      defer { self.pending.signal() }
      guard !ctx.cancelled else { return }
      do { try sendFrame(socket.fd, seal(w, k));self.traceGesture(stage:.txWritten,packet:w) } catch {
        let reason = safeConnectionError(error)
        ctx.cancel(reason:"Send stream: "+reason)
        DispatchQueue.main.async {
          if self.generation == g {
            self.stop()
            self.status("Send stream: \(reason)")
          }
        }
      }
    }
    return true
  }
  @discardableResult
  func control(
    _ kind: String, token: String? = nil, edge: Edge? = nil,
    y: Double? = nil, width: Double? = nil, height: Double? = nil
  ) -> Bool {
    if kind == "available",receiverMapPublicationCandidate==nil,detectReceiverMapTransition() {return true}
    let bounds = topology?.bounds
    let carriesGeometry = kind == "available" || kind == "begin"
    // Receiver-only: attach a bounded ReceiverDesktop snapshot to each
    // "available" packet. Gated on the 0.8.20 explicit desktop-codec
    // capability so 0.8.19 peers (which advertise concurrentDisplayCodec=1
    // but do not understand the map) never see one.
    var publishedMap:Data? = nil
    if kind == "available", !sender, multiDisplayDesktopCompatible, let encoded = encodeReceiverDesktopForPublication() {
      let (data,desktop) = encoded
      let fingerprint = desktopFingerprintForPublication(desktop)
      receiverDesktopPublishRevision = desktop.revision
      receiverDesktopPublishedFingerprint = fingerprint
      publishedMap = data
    }
    let ok = (desktopEnqueueForTests ?? enqueue)(
      Wire(
        kind: kind, session: session, sequence: 0, y: y,
        token: token, edge: edge, width: width, height: height,
        screenWidth: carriesGeometry ? bounds.map { Double($0.width) } : nil,
        screenHeight: carriesGeometry ? bounds.map { Double($0.height) } : nil,
        layoutY: kind == "begin" ? layoutOffsetY : nil,gestureCodec:kind == "available" && experimental && gestureCompatible ? 1 : 0,
        appGestureCodec:kind == "available" && inject && appGestureExperimental && appGestureCompatible ? 1 : 0,
        receiverDesktopMap: publishedMap))
    if !ok && connection != nil { stop(reason:lastEnqueueFailure) }
    return ok
  }
  func handle(_ reported: CGEventType, _ e: CGEvent) -> Bool {
    if lockedTransportOnly {return false}
    if reported == .tapDisabledByTimeout || reported == .tapDisabledByUserInput {
      automaticReconnectSuspended=true
      stop(reason:reported == .tapDisabledByTimeout ? "Event tap disabled by timeout":"Event tap disabled by user input")
      if reported == .tapDisabledByTimeout, (ownership.blocked || sourceGesture.hasOrphans), AXIsProcessTrusted(), let tap {
        CGEvent.tapEnable(tap: tap, enable: true)
        status(
          "Forwarding stopped. Cleanup tap re-enabled; release remote-owned inputs. Hard quit or permission loss cannot guarantee filtering."
        )
      } else {
        status(
          "Event tap disabled. Local restored; orphan filtering is not guaranteed while the tap or permission is unavailable."
        )
      }
      return false
    }
    if context != nil, let reason = currentSessionBlockReason() { sessionBecameUnsafe(reason,origin:polledSessionSuspensionOrigin) }
    if sender && (forward || handoff.phase == .remote) && !NSApp.isActive {
      pauseSourceForForegroundLoss()
    }
    let raw55 = UInt32(truncatingIfNeeded: e.getIntegerValueField(CGEventField(rawValue: 55)!))
    let type = ([29, 30].contains(raw55) ? CGEventType(rawValue: raw55) : reported) ?? reported
    if [29, 30].contains(type.rawValue),
      e.getIntegerValueField(.eventSourceUserData) != marker,
      e.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid()),
      explicitGestureMotion(e)
    {
      gestureUntil = ProcessInfo.processInfo.systemUptime + 2
      // Classified native app gestures are handled after the marker filter below.
    }
    if type == .keyDown, e.getIntegerValueField(.keyboardEventKeycode) == 53,
      e.flags.contains([.maskControl, .maskAlternate])
    {
      sharingEmergencyStopped?()
      safetyStop("Emergency hotkey stop; explicit resume required")
      return false
    }
    guard e.getIntegerValueField(.eventSourceUserData) != marker,
      e.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid())
    else { return false }
    if drainDesktopPauseInput(type:type,code:CGKeyCode(truncatingIfNeeded:e.getIntegerValueField(.keyboardEventKeycode)),button:e.getIntegerValueField(.mouseEventButtonNumber),flags:e.flags) {return true}
    if sender,handoff.phase == .local,type == .mouseMoved,let started=sourceReturnRestoredAt {
      sourceReturnRestoredAt=nil
      let elapsed=ProcessInfo.processInfo.systemUptime-started
      if elapsed>=0 && elapsed<2 {connectionLog("Source return first unmarked move ms=\(elapsed*1000)")}
    }
    if !sender,cursorVisibilityCompatible,sourceAutoCursorMode,standard.contains(type.rawValue) {
      let wasHidden=receiverCursor.isHidden
      receiverLocalCursorOverride(reason:"physical-input")
      guard !receiverCursor.needsRecovery else{safetyStop("Receiver local input cursor recovery failed");return false}
      if wasHidden {status(TCText("Local input on the Receiver Mac made the cursor visible again."))}
    }
    if sender,context != nil,[UInt32(29),30].contains(type.rawValue),gestureTrace.enabled,currentSessionBlockReason()==nil {gestureTrace.recordNative(stage:.txCapture,event:e)}
    if [UInt32(29),30].contains(type.rawValue) {
      let gestureOrphanCodes=Set(ownership.orphans.compactMap {input -> CGKeyCode? in if case .modifier(let key)=input{return key};return nil})
      e.flags=filteredModifierFlags(e.flags,orphanCodes:gestureOrphanCodes,ambiguous:ownership.ambiguousModifiers)
    }
    if let handled=handleSourceGesture(e) {return handled}
    if let handled=handleDockGesture(e) {return handled}
    if sender,context != nil,[UInt32(29),30].contains(type.rawValue) {gestureTrace.recordNative(stage:.txRejected,event:e)}
    let code = CGKeyCode(truncatingIfNeeded: e.getIntegerValueField(.keyboardEventKeycode))
    if sender, type == .flagsChanged, modifierDescriptors[code] != nil,
      modifierDown(code, flags: e.flags) == nil
    {
      if (auto && handoff.phase != .local) || !ownership.owned.isEmpty || ownership.blocked {
        ownership.quarantineModifierGroup(code)
        if let token = handoff.token { _ = control("cancel", token: token) }
        forceLocal()
        auto = false
        automaticReconnectSuspended=true
        sendCursorMode()
        status(
          "Modifier side flags unavailable. Relay returned local; release both paired modifier keys before rearming. "
            + recoveryNotice)
        return true
      }
      if forward {
        stop()
        status("Modifier side flags unavailable; manual mirror stopped")
        return false
      }
    }
    let groupConsumed = ownership.reconcileModifierGroups(
      type == .flagsChanged ? code : nil, flags: e.flags)
    if groupConsumed {
      localFlags = filteredModifierFlags(
        e.flags, orphanCodes: [], ambiguous: ownership.ambiguousModifiers
      ).intersection(heldModifierMask)
      if !ownership.blocked && context == nil { removeCaptureIfClean() }
      return true
    }
    let input: RemoteInputOwnership.Input?
    let down: Bool
    if type == .keyDown || type == .keyUp {
      input = .key(code)
      down = type == .keyDown
    } else if [1, 2, 3, 4, 25, 26].contains(type.rawValue) {
      input = .button(e.getIntegerValueField(.mouseEventButtonNumber))
      down = [1, 3, 25].contains(type.rawValue)
    } else if type == .flagsChanged, modifierDescriptors[code] != nil {
      input = .modifier(code)
      down = modifierDown(code, flags: e.flags) ?? false
    } else {
      input = nil
      down = false
    }
    if [6, 7, 27].contains(type.rawValue),
      ownership.orphans.contains(.button(e.getIntegerValueField(.mouseEventButtonNumber)))
    {
      return true
    }
    let quarantined = ownership.filter(
      input, down: down,
      repeatKey: type == .keyDown && e.getIntegerValueField(.keyboardEventAutorepeat) != 0)
    // Missing release events can be reconciled from current physical stream flags.
    for orphan in Array(ownership.orphans) {
      if case .modifier(let key) = orphan, let flag = modifierFlags[key], !e.flags.contains(flag) {
        ownership.orphans.remove(orphan)
      }
    }
    let orphanCodes = Set(
      ownership.orphans.compactMap { input -> CGKeyCode? in
        if case .modifier(let key) = input { return key }
        return nil
      })
    if quarantined {
      if type == .keyUp { localKeys.remove(code) }
      if !down, case .button(let button) = input { localButtons.remove(button) }
      if !ownership.blocked && context == nil { removeCaptureIfClean() }
      return true
    }
    e.flags = filteredModifierFlags(
      e.flags, orphanCodes: orphanCodes, ambiguous: ownership.ambiguousModifiers)
    if !ownership.blocked && context == nil { removeCaptureIfClean() }
    if type == .keyDown { localKeys.insert(code) }
    if type == .keyUp { localKeys.remove(code) }
    if [1, 3, 25].contains(type.rawValue) {
      localButtons.insert(e.getIntegerValueField(.mouseEventButtonNumber))
    }
    if [2, 4, 26].contains(type.rawValue) {
      localButtons.remove(e.getIntegerValueField(.mouseEventButtonNumber))
    }
    localFlags = e.flags.intersection([
      .maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn,
    ])

    guard sender,displayBarrier == nil else { return false }
    if auto,type == .mouseMoved,[EdgeHandoff.Phase.pending,.committed].contains(handoff.phase),let token=handoff.token {
      let dx=e.getDoubleValueField(.mouseEventDeltaX),dy=e.getDoubleValueField(.mouseEventDeltaY)
      let retracts:Bool
      if multiDisplayDesktopCompatible,let portal=desktopPortal {
        let b=boundsForEntry(),p=CGPoint(x:e.location.x-b.minX,y:e.location.y-b.minY)
        switch portal.sourceSide {
        case .left:retracts=dx>0 && p.x>=2
        case .right:retracts=dx<0 && p.x<=b.width-3
        case .top:retracts=dy>0 && p.y>=2
        case .bottom:retracts=dy<0 && p.y<=b.height-3
        }
      } else {retracts=dx != 0 && !selectedEdge.outward(dx) && selectedEdge.distance(e.location.x-boundsForEntry().minX,displayBounds.width)>=2}
      if retracts {
        _=control("cancel",token:token);forceLocal();status("Handoff cancelled: pointer retracted during ownership negotiation");return false
      }
      guard entryMotion.append(token:token,dx:dx,dy:dy) else{stop(reason:"Invalid or excessive transition motion");return false}
    }
    let heldReason = edgeHeldReason(
      keys: !localKeys.isEmpty, buttons: !localButtons.isEmpty, modifiers: !localFlags.isEmpty,
      gesture: ProcessInfo.processInfo.systemUptime < gestureUntil || dockLocalActive || sourceGesture.blockAuto)
    let held = heldReason != nil
    let b = topology?.bounds ?? CGDisplayBounds(CGMainDisplayID())
    if auto && !multiDisplayDesktopCompatible && type == .mouseMoved && handoff.phase == .local {
      let distance = selectedEdge.distance(e.location.x - b.minX, b.width)
      if distance >= 20 { lastEdgeGateReason = "" }
      if distance <= 3 {
        let reason =
          ownership.blocked
          ? "cleanup pending"
          : !receiverAvailable
            ? "receiver input not enabled"
            : held
              ? (heldReason ?? "input state unavailable")
              : handoff.latched ? "move inward before rearming" : ""
        if !reason.isEmpty && reason != lastEdgeGateReason {
          lastEdgeGateReason = reason
          status("Edge gate: " + reason)
        } else if reason.isEmpty && lastEdgeGateReason.isEmpty {
          lastEdgeGateReason = "waiting outward dwell"
          status("Edge sensor: selected boundary reached; waiting for outward dwell")
        }
      }
    }
    if auto && !ownership.blocked && !sourceGesture.blockAuto && receiverAvailable && handoff.phase == .local
      && type == .mouseMoved
    {
      if multiDisplayDesktopCompatible {
        guard topologyUnchanged() else{stop(reason:"Source topology changed before desktop handoff");return false}
        _ = detectAndProposeDesktopHandoff(sourceLocal:CGPoint(x:e.location.x-b.minX,y:e.location.y-b.minY),delta:CGVector(dx:e.getDoubleValueField(.mouseEventDeltaX),dy:e.getDoubleValueField(.mouseEventDeltaY)),held:held,now:ProcessInfo.processInfo.systemUptime)
      } else {
      guard let peerSize = remoteDisplaySize else { return false }
      let layout = ScreenArrangement(
        sourceSize: b.size, remoteSize: peerSize, remoteOnRight: selectedEdge == .right,
        offsetY: layoutOffsetY)
      guard layout.isValid else { return false }
      handoff.arrangement = layout
      handoff.activationDelay = 0
      handoff.activationDistance = 1
      handoff.rearmDistance = 2
      let action = handoff.motion(
        x: e.location.x - b.minX, y: e.location.y - b.minY,
        dx: e.getDoubleValueField(.mouseEventDeltaX), now: ProcessInfo.processInfo.systemUptime,
        held: held, w: b.width, h: b.height)
      if action == .begin {
        // Reconcile physical input exactly when arming, not at pointer sample rate.
        let physicalHeld = physicalInputsHeld()
        if physicalHeld {
          _ = handoff.reset()
          status("Edge gate: physical input held at transition")
          return false
        }
        guard topologyUnchanged() else {
          stop()
          status("Single-display topology changed before handoff")
          return false
        }
        if let token=handoff.token {entryMotion.begin(token:token)}
        status("Handoff: boundary reached; acquiring source foreground")
        prepareSourceForeground()
      }
    }
      }
    let remote = auto && handoff.phase == .remote
    // New-mode peers never interpret manual normalized coordinates as a desktop.
    if multiDisplayDesktopCompatible && !remote {return false}
    guard remote || (!auto && forward),
      allowed(type.rawValue, !auto && experimental && gestureCompatible),
      validFields(e, type.rawValue), let d = e.data as Data?
    else { return false }
    if remote && multiDisplayDesktopCompatible {
      guard let desktop=receiverDesktop,let revision=desktopHandoffRevision,revision==desktop.revision,let previous=desktopGlobalPointer,let portal=desktopPortal else{forceLocal();return ownership.filter(input,down:down,repeatKey:e.getIntegerValueField(.keyboardEventAutorepeat) != 0)}
      if [5,6,7,27].contains(type.rawValue) {
        let delta=CGVector(dx:e.getDoubleValueField(.mouseEventDeltaX),dy:e.getDoubleValueField(.mouseEventDeltaY))
        _ = portal // Return point and portal are supplied only by authenticated receiver return.
        desktopGlobalPointer=DesktopHandoffRouting.moved(previous,delta:delta,desktop:desktop)
      }
    } else if remote && [5, 6, 7, 27].contains(type.rawValue) {
      returnMotion.observe(edge:selectedEdge,x:handoff.x,width:handoff.width,dx:e.getDoubleValueField(.mouseEventDeltaX),now:ProcessInfo.processInfo.systemUptime,held:held || type != .mouseMoved)
      handoff.relative(
        e.getDoubleValueField(.mouseEventDeltaX), e.getDoubleValueField(.mouseEventDeltaY))
    }
    var w = Wire(
      kind: "event", session: session, sequence: 0, raw: type.rawValue, data: d,
      x: remote ? handoff.x / (handoff.width - 1) : (e.location.x - b.minX) / b.width,
      y: remote ? handoff.y / (handoff.height - 1) : (e.location.y - b.minY) / b.height,
      token: remote ? handoff.token : nil)
    if multiDisplayDesktopCompatible {w.x=nil;w.y=nil;w.desktopGlobalX=desktopGlobalPointer.map{Double($0.x)};w.desktopGlobalY=desktopGlobalPointer.map{Double($0.y)};w.desktopMapRevision=desktopHandoffRevision}
    guard enqueue(w) else {
      stop()
      status("Output backpressure: local restored")
      // The failed frame was not accepted. A previously owned release still must not leak locally.
      return ownership.filter(
        input, down: down, repeatKey: e.getIntegerValueField(.keyboardEventAutorepeat) != 0)
    }
    ownership.accepted(input, down: down, suppressed: remote)
    if remote { finishReturnIfDrained() }
    return remote
  }
  private func boundsForEntry()->CGRect {topology?.bounds ?? CGDisplayBounds(CGMainDisplayID())}
  private func flushEntryMotion(token:String)->Bool {
    guard let moves=entryMotion.takeMoves(token:token) else{return true}
    guard let lastMove=moves.last(where:{$0.dx != 0 || $0.dy != 0}) else{return true}
    guard handoff.phase == .remote,handoff.token==token,desktopFocusSafety else{stop(reason:"Transition motion ownership invalid");return false}
    if multiDisplayDesktopCompatible {
      guard let desktop=receiverDesktop,desktop.revision==desktopHandoffRevision,var p=desktopGlobalPointer else{stop(reason:"Desktop transition map unavailable");return false}
      for move in moves where move.dx != 0 || move.dy != 0 {
        let delta=CGVector(dx:move.dx,dy:move.dy)
        // Do not cache speculative crossings: receiver-local held input can block them.
        p=DesktopHandoffRouting.moved(p,delta:delta,desktop:desktop)
        if let flush=desktopFocusFlushForTests {guard flush() else{return false};continue}
        guard let event=CGEvent(mouseEventSource:nil,mouseType:.mouseMoved,mouseCursorPosition:p,mouseButton:.left) else{stop(reason:"Cannot construct desktop transition motion");return false}
        event.flags=CGEventSource.flagsState(.hidSystemState).subtracting(heldModifierMask)
        event.setDoubleValueField(.mouseEventDeltaX,value:move.dx);event.setDoubleValueField(.mouseEventDeltaY,value:move.dy)
        guard let data=event.data,enqueue(Wire(kind:"event",session:session,sequence:0,raw:5,data:data as Data,token:token,desktopMapRevision:desktopHandoffRevision,desktopGlobalX:p.x,desktopGlobalY:p.y)) else{stop(reason:"Desktop transition flush failed");return false}
      }
      desktopGlobalPointer=p;return true
    }
    for move in moves {handoff.relative(move.dx,move.dy)}
    guard let event=CGEvent(mouseEventSource:nil,mouseType:.mouseMoved,mouseCursorPosition:.zero,mouseButton:.left) else{stop(reason:"Cannot construct transition motion frame");return false}
    event.flags=CGEventSource.flagsState(.hidSystemState).subtracting(heldModifierMask)
    event.setDoubleValueField(.mouseEventDeltaX,value:lastMove.dx);event.setDoubleValueField(.mouseEventDeltaY,value:lastMove.dy)
    guard let data=event.data else{stop(reason:"Cannot encode transition motion frame");return false}
    let frame=Wire(kind:"event",session:session,sequence:0,raw:5,data:data as Data,x:handoff.x/(handoff.width-1),y:handoff.y/(handoff.height-1),token:token)
    guard enqueue(frame) else{stop(reason:"Transition motion flush failed");return false}
    return true
  }
  private func handleSourceGesture(_ event:CGEvent)->Bool? {
    guard sender,let descriptor=NativeGestureDescriptor.decode(event),
      context != nil || sourceGesture.hasOrphans else{return nil}
    let remote=auto && handoff.phase == .remote
    let route=sourceGesture.route(descriptor,remote:remote,now:ProcessInfo.processInfo.systemUptime)
    if context == nil {removeCaptureIfClean();return route.suppress}
    guard route.forward else{return route.suppress}
    // Off or unsupported still owns/suppresses the whole stream, never leaks locally.
    guard !multiDisplayDesktopCompatible,appGestureExperimental,appGestureCompatible,receiverAppGestureAvailable else {
      if descriptor.terminal {finishReturnIfDrained()}
      return true
    }
    guard let outgoing=event.copy() else{stop(reason:"Cannot copy app gesture frame");return true}
    let orphanCodes=Set(ownership.orphans.compactMap{input -> CGKeyCode? in if case .modifier(let key)=input{return key};return nil})
    outgoing.flags=filteredModifierFlags(event.flags,orphanCodes:orphanCodes,ambiguous:ownership.ambiguousModifiers)
    guard NSApp.isActive,sourceOwnershipConfirmed?()==true,currentSessionBlockReason()==nil,
      AXIsProcessTrusted(),topologyUnchanged(),
      let token=handoff.token,let id=route.id,
      let data=outgoing.data as Data?,!data.isEmpty,data.count<=AppGestureCodec.maximumDataSize,
      handoff.width>1,handoff.height>1 else {
      stop(reason:"App gesture source ownership or serialization unavailable");return true
    }
    let packet=Wire(kind:"appGesture",session:session,sequence:0,raw:event.type.rawValue,data:data,
      x:handoff.x/(handoff.width-1),y:handoff.y/(handoff.height-1),token:token,
      appGesture:descriptor,appGestureID:id,appGestureCodec:1)
    guard AppGestureCodec.decode(packet) != nil,enqueue(packet) else {
      // A failed begin/terminal must not release an unfinished physical gesture locally.
      if !descriptor.atomic && !descriptor.terminal {
        sourceGesture.forceLocal()
      }
      stop(reason:"App gesture frame rejected; lift fingers before reconnecting");return true
    }
    if descriptor.terminal {finishReturnIfDrained()}
    return true
  }
  private func receiveAppGesture(_ packet:Wire) {
    guard !multiDisplayDesktopCompatible else{return}
    guard receiverActivationPendingToken == nil,!sender,inject,appGestureExperimental,appGestureCompatible,
      AXIsProcessTrusted(),currentSessionBlockReason()==nil,topologyUnchanged(),
      let token=packet.token,acceptsToken(handoff,token),
      let descriptor=packet.appGesture,let id=packet.appGestureID,
      let event=AppGestureCodec.decode(packet),let x=packet.x,let y=packet.y,
      let bounds=topology?.bounds else{traceGesture(stage:.rxRejected,packet:packet);return}
    guard receiverAppGesture.accept(descriptor,id:id) else {
      stop(reason:"Invalid app gesture stream ordering");return
    }
    // Only public routing metadata is changed; preserve opaque event payload.
    event.location=CGPoint(x:bounds.minX+x*(bounds.width-1),y:bounds.minY+y*(bounds.height-1))
    event.timestamp=DispatchTime.now().uptimeNanoseconds
    event.setIntegerValueField(.eventSourceUserData,value:marker)
    gestureTrace.recordApp(stage:.rxBuilt,descriptor:descriptor,event:event,sequence:packet.sequence,stream:id)
    event.post(tap:.cgSessionEventTap)
    gestureTrace.recordApp(stage:.rxPosted,descriptor:descriptor,event:event,sequence:packet.sequence,stream:id)
  }

  private func inspectDock(_ event:CGEvent)->DockGestureDescriptor? {
    DockGestureCodec.inspect(event) ?? DockGestureCodec.inspectExperimentalVertical(event)
  }
  private func makeDock(_ d:DockGestureDescriptor)->CGEvent? {
    d.motion==1 ? DockGestureCodec.makeEvent(d) : DockGestureCodec.makeExperimentalVerticalEvent(d)
  }
  private func handleDockGesture(_ event:CGEvent)->Bool? {
    guard sender,let d=inspectDock(event) else{return nil}
    return routeDockGesture(d)
  }
  // Shared by the native classifier and memory-only transition fixtures.
  // No opaque payload replay and no test-specific routing decisions.
  private func routeDockGesture(_ d:DockGestureDescriptor)->Bool? {
    if let orphan=dockOrphanMotion,orphan==d.motion {
      if d.phase==4 || d.phase==8 {dockOrphanMotion=nil;if context==nil {removeCaptureIfClean()}}
      return true
    }
    guard context != nil else{return nil}
    let remote=auto && handoff.phase == .remote
    // A gesture that began while local stays local even if an asynchronous
    // active acknowledgement races its terminal. Never reinterpret its tail
    // as a fresh remote stream or stop the authenticated session for no begin.
    if dockLocalActive || !remote {
      if dockLocalActive && remote {pauseSourceForForegroundLoss()}
      dockLocalActive=d.phase==1 || d.phase==2
      if d.phase==1 {status("Native DockSwipe recognized locally (no remote injection)")}
      return nil
    }
    // Window ownership can disappear while this app remains active (viewer
    // resignation). Do not wait for the deferred ownership callback or timer.
    guard desktopFocusSafety else {pauseSourceForForegroundLoss();return true}
    if multiDisplayDesktopCompatible && !desktopSystemGestureCompatible {
      if d.phase==1 {status(TCText("Multi-display system gestures require updated apps on both Macs and matching OS builds."))}
      guard dockSource.beginSource(d,now:ProcessInfo.processInfo.systemUptime) != nil else{return true}
      if d.phase==4 || d.phase==8 {finishReturnIfDrained()};return true
    }
    guard experimental,gestureCompatible,receiverGestureAvailable else{return true}
    guard let token=handoff.token else{return true}
    var packet=Wire(kind:"dock",session:session,sequence:0,token:token,dock:d)
    var target:DesktopSystemGestureTarget?
    if multiDisplayDesktopCompatible {
      guard let desktop=receiverDesktop,let revision=desktopHandoffRevision,let point=desktopGlobalPointer,
        let bound=DesktopSystemGestureTarget.attach(packet,desktop:desktop,revision:revision,point:point),
        let resolved=DesktopSystemGestureTarget.resolve(bound,desktop:desktop,revision:revision,previous:point),
        DesktopSystemGestureTarget.continues(phase:d.phase,requested:resolved,current:dockSourceDesktopTarget) else{
          stop(reason:"System gesture desktop target changed; lift all fingers");return true
        }
      packet=bound;target=resolved
    }
    guard let id=dockSource.beginSource(d,now:ProcessInfo.processInfo.systemUptime) else {
      stop(reason:"System gesture lacks a valid begin; lift all fingers before retrying");return true
    }
    packet.dockID=id
    guard (desktopEnqueueForTests ?? enqueue)(packet) else{stop(reason:lastEnqueueFailure);return true}
    if d.phase==1 {dockSourceDesktopTarget=target}
    if d.phase==4 || d.phase==8 {dockSourceDesktopTarget=nil}
    if d.phase==1 {status("System gesture begin queued")}
    if d.phase==4 || d.phase==8 {status("System gesture terminal queued");finishReturnIfDrained()}
    // Suppress source CG event only. This does not prove earlier native HID/Dock suppression.
    return true
  }
  private func traceGesture(stage:GestureTraceStage,packet:Wire) {
    guard gestureTrace.enabled else{return}
    if packet.kind=="dock",let d=packet.dock {gestureTrace.recordDock(stage:stage,descriptor:d,sequence:packet.sequence,stream:packet.dockID)}
    else if packet.kind=="appGesture",let d=packet.appGesture {gestureTrace.recordApp(stage:stage,descriptor:d,event:packet.data.flatMap{CGEvent(withDataAllocator:nil,data:$0 as CFData)},sequence:packet.sequence,stream:packet.appGestureID)}
  }
  private func receiveDockGesture(_ w:Wire) {
    guard !multiDisplayDesktopCompatible || desktopSystemGestureCompatible else{return}
    guard receiverActivationPendingToken == nil,inject,experimental,gestureCompatible,(desktopSystemGesturePermissionForTests?() ?? AXIsProcessTrusted()),let token=w.token,acceptsToken(handoff,token),let id=w.dockID,let d=w.dock else{traceGesture(stage:.rxRejected,packet:w);return}
    var target:DesktopSystemGestureTarget?
    var destination:CGPoint?
    if multiDisplayDesktopCompatible {
      guard !receiverCursorLocalOverride,let desktop=currentRoutingDesktop(),let revision=desktopHandoffRevision,
        let previous=desktopReceiverPreviousPointer,desktopPortal != nil,
        let resolved=DesktopSystemGestureTarget.resolve(w,desktop:desktop,revision:revision,previous:previous),
        DesktopSystemGestureTarget.continues(phase:d.phase,requested:resolved,current:dockReceiverDesktopTarget) else {traceGesture(stage:.rxRejected,packet:w);return}
      target=resolved;destination=previous
    }
    let projected=receiverDockProjection(d,invertVertical:invertVerticalSystemGestures,invertHorizontal:invertHorizontalSystemGestures)
    gestureTrace.recordDock(stage:.rxProjected,descriptor:projected,sequence:w.sequence,stream:id,inverted:d.motion==1 ? invertHorizontalSystemGestures:invertVerticalSystemGestures)
    guard let event=desktopSystemGestureBuildForTests?(projected) ?? makeDock(projected) else{stop(reason:"Unsupported native system gesture stream");return}
    if let destination {event.location=destination}
    guard finalDesktopInjectionGate() else{return}
    guard dockReceiver.accept(d,id:id,now:ProcessInfo.processInfo.systemUptime) else{stop(reason:"Invalid native system gesture stream");return}
    if d.phase==1 {dockReceiverDesktopTarget=target}
    if d.phase==4 || d.phase==8 {dockReceiverDesktopTarget=nil}
    event.timestamp=DispatchTime.now().uptimeNanoseconds
    event.setIntegerValueField(.eventSourceUserData,value:marker)
    gestureTrace.recordNative(stage:.rxBuilt,event:event,sequence:w.sequence,stream:id)
    if let post=desktopSystemGesturePostForTests {post(event)} else {event.post(tap:.cgSessionEventTap)}
    gestureTrace.recordDock(stage:.rxPosted,descriptor:projected,sequence:w.sequence,stream:id,inverted:d.motion==1 ? invertHorizontalSystemGestures:invertVerticalSystemGestures)
    if let target,let destination,dockReceiver.active {
      postedDockStream=PostedDockStream(descriptor:d,point:destination,target:target,token:token,stream:id,session:session,generation:generation)
    } else {postedDockStream=nil}

    if d.phase==1 || d.phase==4 || d.phase==8 {status("System gesture phase delivered to session queue")}
  }
  func receiveControl(_ w: Wire) {
    guard !lockedTransportOnly else{return}
    if w.kind == "displayPreference" {
      guard authenticated,!sender,displayPreferenceCompatible,let enabled=w.displayPreference else{return}
      peerDisplayPreference=enabled;displayPreferenceChanged?(enabled);return
    }
    let now = ProcessInfo.processInfo.systemUptime
    let b = topology?.bounds ?? CGDisplayBounds(CGMainDisplayID())
    if ["displayPause","displayPaused","displayResume"].contains(w.kind) {receiveDisplayBarrier(w);return}
    if displayBarrier != nil && !["ping","available"].contains(w.kind) {return}
    if w.kind == "ping" { return }
    if !sender,detectReceiverMapTransition() {return}
    if w.kind == "cursorMode" {
      guard !sender,cursorVisibilityCompatible,let enabled=w.cursorMode else{return}
      sourceAutoCursorMode=enabled
      if !enabled {receiverCursorLocalOverride=false}
      cursorDiagnostic("mode-received");_ = syncReceiverCursor();return
    }
    if w.kind == "available" {
      receiverAvailable = w.width == 1
      receiverGestureAvailable=w.gestureCodec==1 && gestureCompatible
      receiverAppGestureAvailable=w.width==1 && w.appGestureCodec==1 && appGestureCompatible
      if sender, let map = w.receiverDesktopMap,displayBarrier?.phase != .draining {
        adoptReceiverDesktopFromPeer(map)
        if displayBarrier?.phase == .paused,let decoded=try? JSONDecoder().decode(ReceiverDesktop.self,from:map),
          let adopted=receiverDesktop,decoded.valid,decoded.revision==adopted.revision,decoded.revision>sourceBarrierRevision,
          desktopFingerprintForPublication(decoded)==desktopFingerprintForPublication(adopted) {sourceBarrierMapReady=true}
      }
      if sourceGesture.remoteActive && !receiverAppGestureAvailable {stop(reason:"Receiver app gesture consent lost; lift fingers");return}
      if let width = w.screenWidth, let height = w.screenHeight {
        let size = CGSize(width: width, height: height)
        if size != remoteDisplaySize {
          remoteDisplaySize = size
          if sender,pendingInitialLayoutRestore {
            pendingInitialLayoutRestore=false
            if let pair=layoutDevicePair,let saved=savedScreenLayouts.restored(for:pair,sourceSize:b.size,remoteSize:size) {
              selectedEdge=saved.remoteOnRight ? .right:.left;layoutOffsetY=saved.offsetY
              status(TCText("Saved per-device screen layout restored."))
            }
          }
          displayGeometryChanged?(size)
        }
      }
      if !receiverAvailable,displayBarrier == nil { forceLocal() }
      else if sender,displayBarrier == nil,!auto,!automaticReconnectSuspended,remoteDisplaySize != nil,hasUnresolvedLocalRecovery == false,automaticSharingInputAllowed(true) {configureAuto(true,edge:selectedEdge)}
      return
    }
    guard let token = w.token else { return }
    switch w.kind {
    case "begin":
      status("Handoff: begin received")
      guard topologyUnchanged() else {
        if pauseReceiverTopologyFailure() {return}
        stop()
        status("Single-display topology changed before begin")
        return
      }
      if multiDisplayDesktopCompatible {
        guard !sender,inject,AXIsProcessTrusted(),handoff.phase == .local,
          UUID(uuidString:token)?.uuidString==token,let desktop=currentRoutingDesktop(),
          let portal=DesktopHandoffRouting.portal(w,desktop:desktop,publishedRevision:receiverDesktopPublishRevision),
          let entry=DesktopHandoffRouting.point(w,desktop:desktop,revision:receiverDesktopPublishRevision) else{_ = control("cancel",token:token);return}
        desktopPortal=portal;desktopGlobalPointer=entry;desktopReceiverPreviousPointer=entry;desktopHandoffRevision=desktop.revision
        handoff.arrangement=nil;handoff.token=token;handoff.phase = .targetReady;handoff.deadline=now+1.5
        _ = control("ready",token:token,width:portal.targetRect.width,height:portal.targetRect.height)
        return
      }
      if handoff.begin(
        token, edge: w.edge!, offset: w.y!, enabled: inject && AXIsProcessTrusted(),
        w: b.width, h: b.height, now: now,
        sourceSize: CGSize(width: w.screenWidth!, height: w.screenHeight!), layoutY: w.layoutY!)
        == .activate
      {
        status("Handoff: receiver ready")
        _ = control("ready", token: token, width: b.width, height: b.height)
      } else {
        _ = control("cancel", token: token)
      }
    case "ready":
      status("Handoff: ready received")
      guard topologyUnchanged() else {
        stop()
        status("Display topology changed before commit")
        return
      }
      guard auto, !sourceGesture.blockAuto, !dockLocalActive, dockOrphanMotion==nil, localKeys.isEmpty, localButtons.isEmpty, localFlags.isEmpty, !(desktopPhysicalInputsForTests?() ?? physicalInputsHeld())
      else {
        if handoff.token == token {
          _ = control("cancel", token: token)
          forceLocal()
        }
        return
      }
      if multiDisplayDesktopCompatible {
        guard handoff.phase == .pending,handoff.token==token,now<handoff.deadline,
          let desktop=receiverDesktop,desktop.revision==desktopHandoffRevision,
          let portal=desktopPortal,w.width==portal.targetRect.width,w.height==portal.targetRect.height else{_ = control("cancel",token:token);forceLocal();return}
        handoff.phase = .committed
        _ = control("commit",token:token);return
      }
      if handoff.ready(token, w: w.width!, h: w.height!, now: now) == .commit {
        status("Handoff: commit sent")
        _ = control("commit", token: token)
      }
    case "commit":
      status("Handoff: commit received")
      guard handoff.token == token else { return }
      guard topologyUnchanged() else {
        if pauseReceiverTopologyFailure() {return}
        stop()
        status("Display topology changed before target activation")
        return
      }
      guard inject && AXIsProcessTrusted() else {
        _ = control("cancel", token: token)
        forceLocal()
        return
      }
      guard localKeys.isEmpty,localButtons.isEmpty,localFlags.isEmpty else{_ = control("cancel",token:token);forceLocal();return}
      if multiDisplayDesktopCompatible {
        guard let desktop=currentRoutingDesktop(),desktop.revision==desktopHandoffRevision,desktopPortal != nil else{_ = control("cancel",token:token);forceLocal();return}
      }
      let activation:EdgeAction
      if multiDisplayDesktopCompatible {
        if handoff.phase == .targetReady,now<handoff.deadline {handoff.phase = .targetActive;activation = .activate} else{activation = .none}
      } else {activation=handoff.commit(token,now:now)}
      if activation == .activate {
        receiverCursorLocalOverride=false
        receiverActivationPendingToken=token;receiverActivationDeadline=ProcessInfo.processInfo.systemUptime+0.4
        guard restoreReceiverCursor() else{safetyStop("Receiver cursor could not be shown before handoff");return}
        let g=generation
        guard let prepare=prepareReceiverInputTarget else{safetyStop("Receiver foreground coordinator unavailable");return}
        prepare({[weak self] in guard let self else{return false};return self.generation==g && self.receiverActivationPendingToken==token && self.handoff.token==token && self.handoff.phase == .targetActive && !self.receiverCursorLocalOverride && self.currentSessionBlockReason()==nil},{[weak self] ready in self?.finishReceiverActivation(token:token,generation:g,ready:ready)})
      }
    case "active":
      guard handoff.phase == .committed,handoff.token==token else{return}
      guard topologyUnchanged(), cursorResources.canAcquire, desktopFocusSafety
      else {
        stop()
        status(
          "Cannot activate: cursor resources, permission or display topology invalid. "
            + recoveryNotice)
        return
      }
      guard auto, !sourceGesture.blockAuto, !dockLocalActive, dockOrphanMotion==nil, localKeys.isEmpty, localButtons.isEmpty, localFlags.isEmpty, !(desktopPhysicalInputsForTests?() ?? physicalInputsHeld())
      else {
        if handoff.token == token {
          _ = control("cancel", token: token)
          forceLocal()
        }
        return
      }
      if handoff.active(token, now: now) == .remote {
        desktopFocusIntent=nil
        guard let targetTopology = topology else {
          stop()
          return
        }
        switch cursorResources.acquire(display: targetTopology.mainID) {
        case .success: break
        case .failure(let error):
          stop()
          status("Cursor acquisition failed: \(error). " + recoveryNotice)
          return
        }
        guard flushEntryMotion(token:token) else{return}
        status(
          String(
            format:
              "Remote active. Handoff %.1f ms. Control + Option + Escape restores local input.",
            (now - handoff.startedAt) * 1000))
      }
    case "return":
      if multiDisplayDesktopCompatible {
        guard sender,handoff.phase == .remote,handoff.token==token,let original=desktopPortal,let map=receiverDesktop,let revision=desktopHandoffRevision,revision==receiverDesktopAdoptedRevision,let portal=DesktopHandoffRouting.returnPortal(w,desktop:map,revision:revision,sourceRect:original.sourceRect),let point=DesktopHandoffRouting.point(w,desktop:map,revision:revision) else{return}
        desktopPortal=portal;desktopReturnPoint=point
      }
      if handoff.phase == .remote && handoff.token==token {returnStartedAt=now}
      ownership.request(token, current: handoff.token, remote: handoff.phase == .remote)
      finishReturnIfDrained()
    case "returnAck":
      if handoff.phase == .returning && handoff.token == token {let started=receiverReturnRequestAt;receiverReturnRequestAt=nil;restoreLocal();if let started {connectionLog("Return request-to-ACK ms=\((ProcessInfo.processInfo.systemUptime-started)*1000)")}}
    case "cancel":
      status("Handoff: cancel received")
      if handoff.token == token { cancelPostedDockStream();forceLocal() }
    default: break
    }
  }
  func finishReceiverActivation(token:String,generation expected:UUID,ready:Bool) {
    guard generation==expected,receiverActivationPendingToken==token,handoff.token==token,handoff.phase == .targetActive,authenticated else{return}
    if detectReceiverMapTransition() {return}
    guard ready,!receiverCursorLocalOverride,localKeys.isEmpty,localButtons.isEmpty,localFlags.isEmpty,inject,inputPermissionsReady(),currentSessionBlockReason(forceRefresh:true)==nil,let deadline=receiverActivationDeadline,ProcessInfo.processInfo.systemUptime<deadline,let bounds=topology?.bounds else{safetyStop("Receiver target foreground not ready; handoff canceled safely");return}
    guard topologyUnchanged() else{if !pauseReceiverTopologyFailure(){safetyStop("Receiver topology changed")};return}
    let entry:CGPoint
    if multiDisplayDesktopCompatible {
      guard let desktop=currentRoutingDesktop(),desktop.revision==desktopHandoffRevision,let p=desktopGlobalPointer,desktop.contains(p),desktopPortal != nil else{_ = pauseReceiverTopologyFailure();return}
      entry=p
    } else {entry=CGPoint(x:bounds.minX+handoff.x,y:bounds.minY+handoff.y)}
    guard finalDesktopInjectionGate() else{return}
    guard CGWarpMouseCursorPosition(entry) == .success else{safetyStop("Target entry warp failed");return}
    receiverActivationPendingToken=nil;receiverActivationDeadline=nil
    status("Handoff: receiver target foreground confirmed; active acknowledgement sent")
    _ = control("active",token:token)
  }
  func receive(_ w: Wire) {
    let inputStartedAt=ProcessInfo.processInfo.systemUptime
    if lockedTransportOnly {lastInput=ProcessInfo.processInfo.systemUptime;return}
    if let reason = currentSessionBlockReason() {
      sessionBecameUnsafe(reason,origin:polledSessionSuspensionOrigin)
      return
    }
    lastInput = ProcessInfo.processInfo.systemUptime
    // Ordinary input validates the fresh map once in currentRoutingDesktop,
    // after decoding and before any modifier reconciliation or OS posting.
    let mapPaused = w.kind == "event" ? displayBarrier != nil : detectReceiverMapTransition()
    if mapPaused,["event","dock","appGesture","begin","commit"].contains(w.kind) {return}
    if displayBarrier != nil,["event","dock","appGesture"].contains(w.kind) {return}
    if !multiDisplayDesktopCompatible && displayLease != nil && displayBarrier == nil && !topologyUnchanged() {safetyStop("Owned display topology changed before input");return}
    if w.kind == "dock" || w.kind == "appGesture" {traceGesture(stage:.rxDecoded,packet:w)}
    if multiDisplayDesktopCompatible,w.kind=="appGesture" {return}
    if w.kind == "appGesture" {receiveAppGesture(w);return}
    if w.kind == "dock" {receiveDockGesture(w);return}
    if w.kind != "event" {
      receiveControl(w)
      return
    }
    if multiDisplayDesktopCompatible && (w.token == nil || desktopPortal == nil) {return}
    if let token = w.token {
      guard acceptsToken(handoff, token) else { return }
    } else {
      guard handoff.phase == .local else { return }
    }
    guard receiverActivationPendingToken == nil,inject, (desktopInputPermissionForTests?() ?? AXIsProcessTrusted()), let t = w.raw,
      allowed(t, experimental && gestureCompatible), let d = w.data,
      let decoded = CGEvent(withDataAllocator: nil, data: d as CFData),
      decoded.type.rawValue == t
        || ([29, 30].contains(t)
          && UInt32(truncatingIfNeeded: decoded.getIntegerValueField(CGEventField(rawValue: 55)!))
            == t)
    else { return }
    var e = decoded
    let eventDesktop:ReceiverDesktop?
    if multiDisplayDesktopCompatible {
      prepareInputTiming()
      let queryStartedAt=ProcessInfo.processInfo.systemUptime
      let fresh=currentRoutingDesktop()
      inputMapTiming.record((ProcessInfo.processInfo.systemUptime-queryStartedAt)*1000)
      guard let fresh,finalDesktopInjectionGate() else{return}
      eventDesktop=fresh
    } else {eventDesktop=nil}
    guard validMouseCoordinates(w), validFields(e, t) else {
      stop()
      status("Invalid authenticated input fields")
      return
    }
    if e.type == .keyDown, e.getIntegerValueField(.keyboardEventKeycode) == 53,
      e.flags.contains([.maskControl, .maskAlternate])
    {
      return
    }
    if t == 12 {
      let code = CGKeyCode(e.getIntegerValueField(.keyboardEventKeycode))
      if modifierDescriptors[code] != nil && modifierDown(code, flags: e.flags) == nil {
        stop()
        status("Ambiguous modifier-side event rejected before injection")
        return
      }
    }
    var desktopDestination:CGPoint?=nil
    var desktopReverse:(DesktopPortal,CGPoint)?=nil
    if multiDisplayDesktopCompatible {
      // Drop before modifier reconciliation or any other OS event posting.
      guard let desktop=eventDesktop,let revision=desktopHandoffRevision,
        let previous=desktopReceiverPreviousPointer,let portal=desktopPortal,
        let p=DesktopHandoffRouting.eventPoint(w,desktop:desktop,revision:revision,previous:previous,
          delta:CGVector(dx:e.getDoubleValueField(.mouseEventDeltaX),dy:e.getDoubleValueField(.mouseEventDeltaY)),moving:[5,6,7,27].contains(t)),
        ![UInt32(29),30].contains(t) else{return}
      desktopDestination=p
      if handoff.phase == .targetActive,t==5 {
        desktopReverse=DesktopHandoffRouting.reverse(desktop:desktop,sourceRect:portal.sourceRect,previous:previous,
          delta:CGVector(dx:e.getDoubleValueField(.mouseEventDeltaX),dy:e.getDoubleValueField(.mouseEventDeltaY)),
          held:!keys.isEmpty || !buttons.isEmpty || !modifiers.isEmpty || !localKeys.isEmpty || !localButtons.isEmpty || !localFlags.isEmpty || !e.flags.intersection(heldModifierMask).isEmpty || dockReceiver.active || receiverAppGesture.active)
      }
    }
    guard finalDesktopInjectionGate() else{return}
    streamFlags = e.flags.intersection(heldModifierMask)
    // Only reconcile modifiers previously injected; never synthesize hardware releases.
    for code in Array(modifiers) {
      if !(t == 12 && CGKeyCode(e.getIntegerValueField(.keyboardEventKeycode)) == code),
        modifierDown(code, flags: e.flags) == false
      {
        let release = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
        release?.flags = streamFlags
        release?.setIntegerValueField(.eventSourceUserData, value: marker)
        guard finalDesktopInjectionGate() else{return}
        release?.post(tap: .cghidEventTap)
        modifiers.remove(code)
      }
    }
    e.timestamp = DispatchTime.now().uptimeNanoseconds
    if [29, 30].contains(t) {  // Experimental injection extension point: raw CGEvent replay only, not private HID dispatch.
      guard experimental else { return }
    }
    if !multiDisplayDesktopCompatible,t == 22, let x = w.x, let y = w.y {
      let bounds = topology?.bounds ?? CGDisplayBounds(CGMainDisplayID())
      e.location = CGPoint(
        x: bounds.minX + x * (bounds.width - 1), y: bounds.minY + y * (bounds.height - 1))
    }
    if !multiDisplayDesktopCompatible,[1, 2, 3, 4, 5, 6, 7, 25, 26, 27].contains(t), let x = w.x, let y = w.y, x.isFinite,
      y.isFinite
    {
      let b = topology?.bounds ?? CGDisplayBounds(CGMainDisplayID())
      let destination = CGPoint(
        x: b.minX + min(1, max(0, x)) * (b.width - 1),
        y: b.minY + min(1, max(0, y)) * (b.height - 1))
      guard let source = mouseInjectionSource,
        let fresh = destinationMouseEvent(decoded, type: t, point: destination, source: source)
      else {
        stop()
        status("Destination mouse event creation failed")
        return
      }
      e = fresh
    }
    if let destination=desktopDestination {
      if positionalMouseTypes.contains(t) {
        guard let source=mouseInjectionSource,let fresh=destinationMouseEvent(decoded,type:t,point:destination,source:source) else{stop(reason:"Desktop mouse event creation failed");return}
        e=fresh
      } else {e.location=destination}
      // Commit pointer bookkeeping only after the final epoch gate below.
    }
    e.setIntegerValueField(.eventSourceUserData, value: marker)
    guard finalDesktopInjectionGate() else{return}
    if let destination=desktopDestination {desktopReceiverPreviousPointer=destination;desktopGlobalPointer=destination}
    if t == 12 {
      let code = CGKeyCode(e.getIntegerValueField(.keyboardEventKeycode))
      if let down = modifierDown(code, flags: e.flags) {
        if down { modifiers.insert(code) } else { modifiers.remove(code) }
      }
    }
    if t == 10 { keys.insert(CGKeyCode(e.getIntegerValueField(.keyboardEventKeycode))) }
    if t == 11 { keys.remove(CGKeyCode(e.getIntegerValueField(.keyboardEventKeycode))) }
    if [1, 3, 25].contains(t) {
      buttons.insert(UInt32(e.getIntegerValueField(.mouseEventButtonNumber)))
    }
    if [2, 4, 26].contains(t) {
      buttons.remove(UInt32(e.getIntegerValueField(.mouseEventButtonNumber)))
    }
    // The final gate above precedes bookkeeping and post, but WindowServer
    // asynchronous dispatch still has an unavoidable OS-level residual race.
    if let post=desktopInputPostForTests {post(e)} else {e.post(tap: replayTapLocation(for: t))}
    noteMousePost(t,startedAt:inputStartedAt)
    if multiDisplayDesktopCompatible {
      if let back=desktopReverse,let token=handoff.token,let revision=desktopHandoffRevision,handoff.phase == .targetActive {
        handoff.phase = .returning;handoff.deadline=ProcessInfo.processInfo.systemUptime+1.5
        receiverReturnRequestAt=ProcessInfo.processInfo.systemUptime
        _ = enqueue(DesktopHandoffRouting.returnFrame(session:session,token:token,portal:back.0,point:back.1,revision:revision))
      }
      return
    }
    if handoff.phase == .targetActive, t == 5 {
      let b = topology?.bounds ?? CGDisplayBounds(CGMainDisplayID())
      let action = handoff.motion(
        x: e.location.x - b.minX, y: e.location.y - b.minY,
        dx: decoded.getDoubleValueField(.mouseEventDeltaX),
        now: ProcessInfo.processInfo.systemUptime,
        held: !keys.isEmpty || !buttons.isEmpty || !modifiers.isEmpty || !streamFlags.isEmpty || dockReceiver.active || receiverAppGesture.active,
        w: b.width, h: b.height)
      if action == .requestReturn {receiverReturnRequestAt=ProcessInfo.processInfo.systemUptime;connectionLog("Return boundary reached; request queued");_ = control("return", token: handoff.token)}
    }
  }
}
final class PasteCommandProbe: NSResponder {
  var calls = 0
  override var acceptsFirstResponder: Bool { true }
  @objc func paste(_ sender: Any?) { calls += 1 }
}
@MainActor final class App: NSObject, NSApplicationDelegate, NSTabViewDelegate {
  lazy var appearance=AppAppearanceController(nativeEffectsEnabled:!isAutomationTest)
  let appUpdateCheck=AppUpdateCheck()
  var pendingDockVisibility:Bool?
  var appearanceTimer:Timer?
  var appearanceInstalled=false
  var applicationIsQuitting=false
  /// One quit request completes after video cleanup; avoids a second quit racing a resume.
  var quitAfterDisplayCleanupTimer:Timer?
  let sharingStore:SavedSharingStateStore
  var sharingNewPairVideoPreference:()->Bool? = {UserDefaults.standard.object(forKey:"ThunderControl.virtualDisplayPreferred") as? Bool}
  var sharingExplicitResumePending:(generation:UUID,sender:Bool)?
  var sharingLastGateDiagnostic=""
  var sharingBlockedReason:String?
  var sharingResume=AutomaticSharingResume()
  var sharingAutomaticVideoStart=false
  var sharingRestoreInProgress=false
  var sharingInputRestoreBlocked=false
  var connectedWindowVisibility=ConnectedWindowVisibility()
  let connectionNotifications=ConnectionNotifications()
  let relay:Relay
  let displayMode=DisplayModeController()
  let displayPreferenceToggle=NSButton(checkboxWithTitle:TCText("Use this Mac as a virtual display"),target:nil,action:nil)
  var displayPreferencePending:Bool?
  var displayPreferencePendingPair:LayoutDevicePair?
  var displayPreferenceLastSent:(UUID,Bool)?
  let screenPermissionButton=NSButton(title:TCText("Allow Screen Recording"),target:nil,action:nil)
  let displayPeer=NSTextField(string:"")
  let displayStatus=NSTextField(wrappingLabelWithString:TCText("Screen mode is stopped."))
  override convenience init() {self.init(relay:Relay())}
  init(relay:Relay,sharingStore:SavedSharingStateStore=SavedSharingStateStore()) {self.relay=relay;self.sharingStore=sharingStore;super.init()}
  lazy var ownershipHUD = SourceOwnershipHUD()
  lazy var sourceWindowOwnership = SourceWindowOwnershipCoordinator(hud:ownershipHUD)
  lazy var receiverCursorFocus=ReceiverCursorFocusController(window:window)
  let discovery = BridgeDiscovery()
  var discoveredPeers: [BridgePeer] = []
  var peerSelectionConfirmed=false
  let peerPicker = NSPopUpButton(frame: .zero, pullsDown: false)
  let pinField = NSTextField(string: "")
  let pinRow=NSStackView()
  let sendSection = NSStackView()
  let receiveSection = NSStackView()
  let manualPeerRow = NSStackView()
  let manualPeerToggle = NSButton(checkboxWithTitle:TCText("Enter IPv4 Directly (if discovery fails)"),target:nil,action:nil)
  let connectButton = NSButton(title:TCText("Request Connection"),target:nil,action:nil)
  let generatePINButton = NSButton(title:TCText("New Code"),target:nil,action:nil)
  let layoutTabItem = NSTabViewItem(identifier:"layout")
  var pairingAlert: NSAlert?
  var pairingAlertToken:UUID?
  var manualPairingAttempt=false
  var trustedSenderHint=false
  var trustHintPending=false
  var lastTrustHintTime=0.0
  var lockedTransportUnlockObserved=false
  var fastRouteTried=false,fastRouteInProgress=false
  let fastRoutes=AuthenticatedRouteHintStore()
  var reconnectBackoff=AutomaticReconnectBackoff()
  let bridgeRecoveryObserver=BridgeRecoveryObserver()
  var verifiedBridgeRecovery=VerifiedBridgeRecoveryState()
  var bridgeRecoveryProbeWork:DispatchWorkItem?
  var bridgeRecoveryProbeInFlight=false,bridgeRecoveryProbeAgain=false,automaticTickQueued=false
  var automaticRetryTimer:Timer?
  var scheduledAutomaticRetryDeadline:Double?
  var automaticSessionVerified=false
  var sessionAutoResume=SessionAutoResumePermit()
  var automaticConnectionPaused=false
  var automaticConnectionTimer:Timer?
  var nextAutomaticAttempt=0.0
  var nextDiscoveryAttempt=0.0
  var discoveryIsBrowsing=false
  var peerSearchStartedAt=0.0
  var receiverAdvertisementBridge:Bridge?
  var receiverAdvertisementPort:UInt16=49177
  var receiverAdvertisementLease=UUID()
  var nextAdvertisementRepair=0.0
  var advertisementRepairInFlight=false
  var hadSession=false
  var dockOutputTestGeneration=UUID()
  let settingsTabs = NSTabView()
  var latestConnectionMessage=""
  let screenLayout = ScreenArrangementView()
  let layoutOffsetField = NSTextField(string: "0")
  let layoutSummary = NSTextField(
    wrappingLabelWithString: TCText("Connect to receive the other screen size."))
  let localAddress = NSTextField(labelWithString: TCText("Checking address"))
  let copyAddress = NSButton(title: TCText("Copy Address"), target: nil, action: nil)
  var verifiedLocalIP: String?
  let notificationPermissionButton=NSButton(title:TCText("Allow Connection Notifications"),target:nil,action:nil)
  let loginApprovalButton=NSButton(title:TCText("Login Item Settings"),target:nil,action:nil)
  let permissionSummary = NSTextField(wrappingLabelWithString: "")
  let accessibilityStatus = NSTextField(labelWithString: "")
  let monitoringStatus = NSTextField(labelWithString: "")
  var didChooseInitialTab = false
  var safetyObserverTokens: [NSObjectProtocol] = []
  var previousForeground: NSRunningApplication?
  var sourceWindowWasVisible = false
  var sourceReturnFocusStarted:Double?
  var sourceReturnFocusTarget:Int32?
  var window: NSWindow!
  let mode = NSSegmentedControl(
    labels: [TCText("Sender"), TCText("Receiver")], trackingMode: .selectOne, target: nil, action: nil)
  let iface = NSTextField(string: "bridge0")
  let peer = NSTextField(string: "")
  let pass = NSSecureTextField(string: "")
  let port = NSTextField(string: "49177")
  let forward = NSButton(checkboxWithTitle: TCText("Forward input (sender)"), target: nil, action: nil)
  let automatic = NSButton(
    checkboxWithTitle: TCText("Automatic edge handoff (experimental)"), target: nil,
    action: nil)
  let enable = NSButton(checkboxWithTitle: TCText("Enable input (receiver)"), target: nil, action: nil)
  let gesture = NSButton(
    checkboxWithTitle: TCText("Experimental native gesture relay (unverified)"), target: nil, action: nil)
  let appGestureToggle=NSButton(checkboxWithTitle:TCText("Experimental: App Zoom/Rotate/Swipe (behavior unverified, consent on both Macs)"),target:nil,action:nil)
  let state = NSTextField(wrappingLabelWithString: TCText("Listen for Connections"))
  func applicationDidFinishLaunching(_ n: Notification) {
    installApplicationIcon()
    installMenus()
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 740, height: 820),
      styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    window.title = "ThunderControl"
    window.isReleasedWhenClosed = false
    settingsTabs.translatesAutoresizingMaskIntoConstraints = false
    window.contentView!.addSubview(settingsTabs)
    NSLayoutConstraint.activate([
      settingsTabs.leadingAnchor.constraint(
        equalTo: window.contentView!.leadingAnchor, constant: 10),
      settingsTabs.trailingAnchor.constraint(
        equalTo: window.contentView!.trailingAnchor, constant: -10),
      settingsTabs.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 10),
      settingsTabs.bottomAnchor.constraint(
        equalTo: window.contentView!.bottomAnchor, constant: -10),
    ])
    let connectionView = NSView()
    let connectionTab = NSTabViewItem(identifier: "connection")
    connectionTab.label = TCText("Connect")
    connectionTab.view = connectionView
    settingsTabs.addTabViewItem(connectionTab)
    let permissionView = NSView()
    let permissionTab = NSTabViewItem(identifier: "permissions")
    permissionTab.label = TCText("Permissions")
    permissionTab.view = permissionView
    settingsTabs.addTabViewItem(permissionTab)
    let layoutTab = layoutTabItem
    layoutTab.label = TCText("Screen Layout")
    let layoutContainer = NSView()
    let layoutStack = NSStackView()
    layoutStack.orientation = .vertical
    layoutStack.alignment = .leading
    layoutStack.spacing = 12
    layoutStack.translatesAutoresizingMaskIntoConstraints = false
    layoutContainer.addSubview(layoutStack)
    NSLayoutConstraint.activate([
      layoutStack.leadingAnchor.constraint(equalTo: layoutContainer.leadingAnchor, constant: 20),
      layoutStack.trailingAnchor.constraint(equalTo: layoutContainer.trailingAnchor, constant: -20),
      layoutStack.topAnchor.constraint(equalTo: layoutContainer.topAnchor, constant: 20),
    ])
    layoutStack.addArrangedSubview(
      NSTextField(
        wrappingLabelWithString:
          TCText("Drag the screens to align their positions.")
      ))
    screenLayout.widthAnchor.constraint(equalToConstant: 640).isActive = true
    screenLayout.heightAnchor.constraint(equalToConstant: 350).isActive = true
    layoutStack.addArrangedSubview(screenLayout)
    layoutOffsetField.widthAnchor.constraint(equalToConstant: 100).isActive = true
    layoutTab.view = layoutContainer
    settingsTabs.addTabViewItem(layoutTab)
    let appearanceTab=NSTabViewItem(identifier:"appearance");appearanceTab.label=TCText("Settings")
    appearanceTab.view=appearance.makePreferencesView();settingsTabs.addTabViewItem(appearanceTab)
    installDisplaySharing()
    screenLayout.onArrangementChanged = { [weak self] right,value in self?.setScreenArrangement(remoteOnRight:right,offset:value) }
    screenLayout.onSourceOriginChanged = { [weak self] origin in guard let self else{return}; _ = self.relay.setSourceOrigin(origin,fromLocalLayoutDrag:self.screenLayout.isSourceDragActive); self.refreshLayout() }
    relay.displayGeometryChanged = { [weak self] _ in self?.refreshLayout() }
    relay.layoutEligibilityChanged = { [weak self] in self?.refreshLayout() }
    relay.onReceiverDesktopChanged = { [weak self] in self?.refreshLayout() }
    // Diagnostic details are recorded to bounded files, never rendered in the UI.
    let permissionStack = NSStackView()
    permissionStack.orientation = .vertical
    permissionStack.alignment = .leading
    permissionStack.spacing = 18
    permissionStack.translatesAutoresizingMaskIntoConstraints = false
    permissionView.addSubview(permissionStack)
    NSLayoutConstraint.activate([
      permissionStack.leadingAnchor.constraint(equalTo: permissionView.leadingAnchor, constant: 20),
      permissionStack.trailingAnchor.constraint(
        equalTo: permissionView.trailingAnchor, constant: -20),
      permissionStack.topAnchor.constraint(equalTo: permissionView.topAnchor, constant: 20),
    ])
    permissionStack.addArrangedSubview(permissionSummary)
    permissionStack.addArrangedSubview(accessibilityStatus)
    permissionStack.addArrangedSubview(
      NSButton(title: TCText("Open Accessibility Settings"), target: self, action: #selector(openAccessibility)))
    permissionStack.addArrangedSubview(monitoringStatus)
    permissionStack.addArrangedSubview(
      NSButton(title: TCText("Open Input Monitoring Settings"), target: self, action: #selector(openMonitoring)))
    permissionStack.addArrangedSubview(
      NSButton(title: TCText("Recheck Permissions"), target: self, action: #selector(refreshPermissions)))
    permissionStack.addArrangedSubview(
      NSTextField(
        wrappingLabelWithString:
          TCText("In Settings, use the + button to add ThunderControl.app from Applications, then turn on its switch. The app does not grant permissions automatically. You may need to relaunch the app after changing permissions.")
      ))
    loginApprovalButton.target=self;loginApprovalButton.action=#selector(openLoginItemsSettings);loginApprovalButton.isHidden=true
    permissionStack.addArrangedSubview(loginApprovalButton)
    notificationPermissionButton.target=self;notificationPermissionButton.action=#selector(allowConnectionNotifications);notificationPermissionButton.isHidden=true
    connectionNotifications.permissionStateChanged = {[weak self] needed in self?.notificationPermissionButton.isHidden = !needed}
    permissionStack.addArrangedSubview(notificationPermissionButton)
    permissionStack.addArrangedSubview(NSButton(title:TCText("Export Diagnostics..."),target:self,action:#selector(exportDiagnostics)))
    permissionStack.addArrangedSubview(NSTextField(wrappingLabelWithString:TCText("Development video diagnostics start with the authenticated screen connection. Numeric frame stages are saved locally and copied to iCloud when available. No video pixels, typed text, or credentials are recorded.")))
    permissionStack.addArrangedSubview(NSButton(title:TCText("Open Development Diagnostics"),target:self,action:#selector(openDevelopmentDiagnostics)))
    permissionStack.addArrangedSubview(NSButton(title:TCText("Open iCloud Diagnostics"),target:self,action:#selector(openCloudDevelopmentDiagnostics)))
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    connectionView.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: connectionView.leadingAnchor, constant: 20),
      stack.trailingAnchor.constraint(equalTo: connectionView.trailingAnchor, constant: -20),
      stack.topAnchor.constraint(equalTo: connectionView.topAnchor, constant: 20),
    ])
    mode.selectedSegment = !isAutomationTest && UserDefaults.standard.string(forKey:"preferredRole")=="receive" ? 1:0
    mode.target = self
    mode.action = #selector(modeChanged)
    state.font = .systemFont(ofSize:20,weight:.semibold)
    state.setAccessibilityLabel(TCText("Connection Status"))
    stack.addArrangedSubview(state)
    mode.controlSize = .large
    stack.addArrangedSubview(mode)
    for section in [sendSection,receiveSection] { section.orientation = .vertical; section.alignment = .leading; section.spacing = 10; stack.addArrangedSubview(section) }
    stack.addArrangedSubview(displayStatus)
    peerPicker.widthAnchor.constraint(equalToConstant:350).isActive = true
    peerPicker.addItem(withTitle:TCText("Discovering Thunderbolt peers..."))
    peerPicker.target=self; peerPicker.action=#selector(peerSelected)
    sendSection.addArrangedSubview(NSStackView(views:[peerPicker,NSButton(title:TCText("Search Again"),target:self,action:#selector(searchPeersExplicit))]))
    manualPeerToggle.target=self; manualPeerToggle.action=#selector(showManualPeer)
    // Manual address fallback is retained internally but not shown in the simple UI.
    manualPeerRow.orientation = .horizontal
    manualPeerRow.addArrangedSubview(NSTextField(labelWithString:TCText("Direct IPv4")));manualPeerRow.addArrangedSubview(peer)
    peer.widthAnchor.constraint(equalToConstant:210).isActive=true
    manualPeerRow.isHidden=true
    pinField.font = .monospacedDigitSystemFont(ofSize:18,weight:.medium);pinField.alignment = .center
    pinField.placeholderString=TCText("4-Digit Code");pinField.widthAnchor.constraint(equalToConstant:125).isActive=true
    generatePINButton.target=self;generatePINButton.action=#selector(generatePIN)
    pinRow.addArrangedSubview(NSTextField(labelWithString:TCText("Pairing Code")));pinRow.addArrangedSubview(pinField);pinRow.addArrangedSubview(generatePINButton)
    sendSection.addArrangedSubview(pinRow)
    displayPreferenceToggle.target=self;displayPreferenceToggle.action=#selector(toggleVirtualDisplay)
    displayPreferenceToggle.setAccessibilityIdentifier("virtualDisplayPreference")
    sendSection.addArrangedSubview(displayPreferenceToggle)
    for button in [automatic,forward,gesture] {button.target=self;button.action=#selector(toggle)}
    // Handoff is armed automatically only after authentication and receiver readiness.
    forward.title=TCText("Manual Forward Test (do not use with automatic switching)")
    copyAddress.target=self;copyAddress.action=#selector(copyLocalAddress)
    receiveSection.addArrangedSubview(NSTextField(wrappingLabelWithString:TCText("When a connection request arrives, enter the code from the Sender Mac.")))
    enable.target=self;enable.action=#selector(toggle)
    // Standalone experimental output test removed from normal UI.
    iface.widthAnchor.constraint(equalToConstant:100).isActive=true;port.widthAnchor.constraint(equalToConstant:80).isActive=true
    gesture.title=TCText("Experimental: Mission Control / Space Gesture Forwarding (consent required on both Macs)")
    gesture.state=relay.experimental ? .on:.off
    // System gestures are enabled by negotiated capability.
    appGestureToggle.target=self;appGestureToggle.action=#selector(toggleAppGestures)
    // App gestures are enabled by negotiated capability.
    connectButton.target=self;connectButton.action=#selector(start)
    connectButton.bezelStyle = .rounded
    connectButton.bezelColor = .controlAccentColor
    stack.addArrangedSubview(NSStackView(views:[connectButton,NSButton(title:TCText("Stop"),target:self,action:#selector(stop))]))
    relay.sessionTransitionSuspended = { [weak self] epoch in
      guard let self else{return}
      if !self.relay.sessionLockedSignal {self.invalidateUnlockEvidenceForNewTransition()}
      guard !self.automaticConnectionPaused else{return}
      self.sessionAutoResume.adoptTransition(epoch:epoch)
      self.automaticSessionVerified=false;self.relay.sessionLockedSignal=true
      self.requestAutomaticConnectionTick()
    }
    relay.bridgeBecameUnavailable = { [weak self] in
      guard let self else{return}
      _ = self.verifiedBridgeRecovery.observe(nil)
    }
    relay.automaticInputSharingPermitted = {[weak self] pair,sender in self?.sharingInputPermitted(pair:pair,sender:sender) ?? false}
    relay.sharingEmergencyStopped = {[weak self] in self?.sharingUserStoppedAll()}
    relay.changed = { [weak self] s in
      self?.sharingObserveAuthenticatedBinding()
      if let self {if self.relay.authenticated {self.connectionNotifications.connected(peerName:self.relay.authenticatedPeerDisplayName ?? TCText("Bridge peer"),localIsSender:self.relay.authenticatedLocalIsSender)}else{self.connectionNotifications.disconnected()}}
      if let self,!self.isAutomationTest,self.appearanceInstalled {self.updateAutomaticWindowVisibility(connected:self.relay.authenticated);self.appearance.setConnected(self.relay.authenticated);self.flushDockVisibilityIfSafe()}
      self?.updateConnectionState(s)
      DispatchQueue.main.async { [weak self] in self?.sharingRestoreTick() }
      if let self {let active=self.relay.hasSession;if self.hadSession && !active {self.handleFastRouteDisconnect();self.requestBridgeRecoveryProbe();self.requestAutomaticConnectionTick()};if (self.hadSession && !active) || self.relay.authenticated {self.pinField.stringValue=""};if self.relay.authenticated {if self.fastRouteInProgress {self.discovery.stop();self.discoveryIsBrowsing=false};self.fastRouteInProgress=false;self.fastRouteTried=false;self.reconnectBackoff.reset();self.nextAutomaticAttempt=0;self.nextDiscoveryAttempt=0};if !active || self.relay.authenticated {self.manualPairingAttempt=false};self.hadSession=active;self.pinField.isEnabled = !active;self.generatePINButton.isEnabled = !active;self.iface.isEnabled = !active;self.port.isEnabled = !active}
      if let self,!self.relay.displayTopologyTransitionActive {
        if self.displayMode.active || self.displayMode.cleaning {
          self.forward.state=self.relay.forward ? .on:.off;self.automatic.state=self.relay.auto ? .on:.off;self.enable.state=self.relay.inject ? .on:.off
        } else {
          if !self.relay.forward {self.forward.state = .off};if !self.relay.auto {self.automatic.state = .off};if !self.relay.inject {self.enable.state = .off}
        }
      }
      if let self {self.gesture.state=self.relay.experimental ? .on:.off}
      self?.refreshModeUI()
    }
    installSessionSafety()
    installPINApproval()
    discovery.onError = { [weak self] hint in
      guard let self else{return}
      self.discoveryIsBrowsing=false;self.discoveredPeers=[];self.peerSelectionConfirmed=false
      if self.mode.selectedSegment==0 {self.peerSelectionConfirmed=false;self.peerPicker.removeAllItems();self.peerPicker.addItem(withTitle:TCText("Discovery unavailable: check Local Network permission and cable")) }
      self.relay.status(hint)
    }
    refreshPermissions()
    refreshLocalAddress()
    refreshLayout()
    refreshModeUI()
    generatePIN()
    if !CommandLine.arguments.contains("--ui-smoke-test") && !CommandLine.arguments.contains("--ui-ownership-test") { searchPeers() }
    connectionLog("App UI initialized; input remains off until authentication, gestures default enabled.")
    settingsTabs.delegate=self
    window.center();updateConnectionState();resizeForCurrentTab()
    if isOffscreenLocalizationPreview {
      DispatchQueue.main.async {
        do {try self.renderLocalizedOffscreenPreview(); NSApp.terminate(nil)}
        catch {fputs("Offscreen localization preview failed: \(error)\n",stderr);exit(1)}
      }
      return
    }
    window.makeKeyAndOrderFront(nil)
    NSRunningApplication.current.activate(options:[.activateIgnoringOtherApps,.activateAllWindows])
    NSApp.activate(ignoringOtherApps: true)
    connectionNotifications.requestAuthorizationIfNeeded()
    installAppearancePreferences()
    installLoginLaunch()
    installAutomaticConnections()
    if !isAutomationTest {appUpdateCheck.startAutomatically()}
    if CommandLine.arguments.contains("--ui-smoke-test"),CommandLine.arguments.contains("--appearance-preview"),let i=CommandLine.arguments.firstIndex(of:"--ui-smoke-test"),i+1<CommandLine.arguments.count {
      DispatchQueue.main.asyncAfter(deadline:.now()+0.5) {
        do {try self.renderAppearancePreferencesForTests(to:CommandLine.arguments[i+1]);NSApp.terminate(nil)}catch{fputs("Preferences render failed\n",stderr);exit(1)}
      };return
    }
    if CommandLine.arguments.contains("--ui-smoke-test"),CommandLine.arguments.contains("--display-preview"),let i=CommandLine.arguments.firstIndex(of:"--ui-smoke-test"),i+1<CommandLine.arguments.count {
      settingsTabs.selectTabViewItem(withIdentifier:"displayStream");resizeForCurrentTab()
      DispatchQueue.main.asyncAfter(deadline:.now()+0.5) {
        do {let shot=Process();shot.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture");shot.arguments=["-x","-o","-l",String(self.window.windowNumber),CommandLine.arguments[i+1]];shot.terminationHandler={child in DispatchQueue.main.async {guard child.terminationStatus==0 else{fputs("Display UI screenshot failed\n",stderr);exit(1)};print("PASS display controls captured from actual native window; no network or input");NSApp.terminate(nil)}};try shot.run();DispatchQueue.global().asyncAfter(deadline:.now()+8){if shot.isRunning{shot.terminate()}}}catch{fputs("Display UI render failed\n",stderr);exit(1)}
      };return
    }
    if CommandLine.arguments.contains("--ui-ownership-test") {
      DispatchQueue.main.asyncAfter(deadline:.now()+0.5) {
        if CommandLine.arguments.contains("--accessory-ownership-test") {check(NSApp.setActivationPolicy(.accessory))}
        self.ownershipHUD.present {}
        self.window.orderOut(nil)
        DispatchQueue.main.asyncAfter(deadline:.now()+0.15) {
          self.finishOwnershipUITestWhenStable(deadline:ProcessInfo.processInfo.systemUptime+1.0)
        }
      }
    }
    // In-process view render only: never starts networking, taps or injection.
    if let flag = CommandLine.arguments.firstIndex(of: "--ui-smoke-test"),
      flag + 1 < CommandLine.arguments.count
    {
      verifyUnlockStatusUIForTests()
      check(settingsTabs.numberOfTabViewItems == 4)
      check(displayPreferenceToggle.superview === sendSection)
      check(displayStatus.superview === sendSection.superview)
      check(!settingsTabs.tabViewItems.contains{($0.identifier as? String)=="displayStream"})
      check(
        NSApp.mainMenu?.items.last?.submenu?.items.contains(where: {
          $0.action == #selector(NSText.paste(_:)) && $0.keyEquivalent == "v"
            && $0.keyEquivalentModifierMask == .command
        }) == true)
      print("PASS standard Edit menu contains command-V paste mapping; clipboard untouched")
      check(
        !permissionSummary.stringValue.isEmpty && !accessibilityStatus.stringValue.isEmpty
          && !monitoringStatus.stringValue.isEmpty)
      let expectedPermissionTab = AXIsProcessTrusted() && CGPreflightListenEventAccess() ? 0 : 1
      check(
        settingsTabs.selectedTabViewItem === settingsTabs.tabViewItem(at: expectedPermissionTab))
      print(
        "PASS permission status populated and initial tab matches missing permissions; no permission requests or settings changes"
      )
      settingsTabs.selectTabViewItem(at: 0)
      let destination = CommandLine.arguments[flag + 1]
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        do {
          guard let view = self.window.contentView,
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
          else { throw Failure("UI render unavailable") }
          view.layoutSubtreeIfNeeded()
          if !CommandLine.arguments.contains("--layout-only") {
            let probe = PasteCommandProbe()
            probe.nextResponder = self.window
            print("UI focus state: active=\(NSApp.isActive) key=\(self.window.isKeyWindow) keyMatches=\(NSApp.keyWindow === self.window)")
            check(self.window.makeFirstResponder(probe))
            check(NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil))
            check(probe.calls == 1)
            let shortcut = NSEvent.keyEvent(
              with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
              windowNumber: self.window.windowNumber, context: nil, characters: "v",
              charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9)!
            check(NSApp.mainMenu?.performKeyEquivalent(with: shortcut) == true)
            check(probe.calls == 2)
            self.window.makeFirstResponder(nil)
            print(
              "PASS native responder-chain paste command delivery without reading or changing clipboard"
            )
          } else {
            print(
              "SKIP native keyboard focus dispatch; layout-only test, no capture or clipboard access"
            )
          }
          self.verifyReceiverWindowPresentationUIPathsForTests()
          self.verifyPreferencesTabRoutingForTests()
          self.verifyAutomaticMainWindowVisibilityUIForTests()
          let controls: [NSView] = [
            self.mode,self.peerPicker,self.pinField,
            self.state,self.connectButton,
          ]
          for control in controls {
            let rect = control.convert(control.bounds, to: view)
            guard rect.width > 0, rect.height > 0,
              view.bounds.insetBy(dx: -1, dy: -1).contains(rect)
            else { throw Failure("A required UI control lies outside the window") }
          }
          self.mode.selectedSegment=1;self.refreshModeUI()
          check(self.sendSection.isHidden && !self.receiveSection.isHidden && self.settingsTabs.numberOfTabViewItems==3)
          self.mode.selectedSegment=0;self.refreshModeUI()
          check(!self.sendSection.isHidden && self.receiveSection.isHidden && self.settingsTabs.numberOfTabViewItems==4)
          self.relay.remoteDisplaySize=CGSize(width:1920,height:1080);self.relay.auto=true;self.refreshLayout()
          check(self.screenLayout.isInteractionEnabled && self.layoutOffsetField.isEnabled)
          self.setLayoutOffset(40);check(self.relay.auto && self.relay.layoutOffsetY==40)
          self.setScreenArrangement(remoteOnRight:false,offset:40)
          check(self.relay.auto && self.relay.selectedEdge == .left)
          self.setLayoutOffset(-1081);check(self.relay.layoutOffsetY==40)
          self.relay.auto=false;self.relay.remoteDisplaySize=nil;self.relay.layoutOffsetY=0;self.relay.selectedEdge = .right;self.refreshLayout()
          print("PASS auto-armed layout editor supports side/height changes and rejects non-overlap; no session/network/input started")
          check(!self.settingsTabs.tabViewItems.contains{($0.identifier as? String)=="gestureTrace" || ($0.identifier as? String)=="diagnostics"})
          print("PASS diagnostic tabs absent; background recording only; clipboard untouched")
          self.settingsTabs.selectTabViewItem(at:0)
          guard !self.relay.auto, !self.relay.forward, !self.relay.inject else {
            throw Failure("UI launch did not keep input OFF")
          }
          self.pinField.stringValue="" // Never include even a test PIN in visual proof.
          view.needsDisplay=true;self.window.displayIfNeeded()
          let context=NSGraphicsContext(bitmapImageRep:bitmap)!
          NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=context
          NSColor.windowBackgroundColor.setFill();view.bounds.fill()
          view.displayIgnoringOpacity(view.bounds,in:context)
          NSGraphicsContext.restoreGraphicsState()
          let image = NSImage(size: view.bounds.size)
          image.lockFocus()
          NSColor(calibratedWhite: 0.94, alpha: 1).setFill()
          view.bounds.fill()
          bitmap.draw(in: view.bounds)
          image.unlockFocus()
          guard let tiff = image.tiffRepresentation, let composed = NSBitmapImageRep(data: tiff),
            let png = composed.representation(using: .png, properties: [:])
          else {
            throw Failure("UI PNG unavailable")
          }
          try png.write(to: URL(fileURLWithPath: destination))
          print(
            "PASS UI controls are visible within the window; input options OFF; no network, capture or injection started"
          )
          NSApp.terminate(nil)
        } catch {
          fputs("UI smoke test: \(error)\n", stderr)
          exit(1)
        }
      }
    }
  }
  func applicationDidBecomeActive(_ notification: Notification) {
    if relay.currentSessionBlockReason(forceRefresh:true)==nil {automaticSessionVerified=true}
    receiverCursorFocus.didBecomeActive()
    relay.sourceBecameActive()
    refreshPermissions()
    if window != nil && !relay.hasSession { refreshLocalAddress() }
  }
  func applicationDidResignActive(_ notification: Notification) {
    if !relay.awaitingSourceActivation { previousForeground = nil }
    relay.sourceResignedActive()
    if receiverCursorFocus.isOwned {relay.receiverLocalCursorOverride(reason:"app-deactivated")}
  }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    prepareAppWindowPresentation()
    window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    return true
  }
  func installSessionSafety() {
    let workspace = NSWorkspace.shared.notificationCenter
    safetyObserverTokens.append(workspace.addObserver(forName:NSWorkspace.didActivateApplicationNotification,object:nil,queue:.main) {[weak self] notification in
      MainActor.assumeIsolated {
        guard let self else{return}
        self.receiverCursorFocus.didBecomeActive()
        guard let started=self.sourceReturnFocusStarted,let expected=self.sourceReturnFocusTarget,let app=notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else{return}
        if app.processIdentifier==expected {connectionLog("Source return foreground-confirmed ms=\((ProcessInfo.processInfo.systemUptime-started)*1000)");self.sourceReturnFocusStarted=nil;self.sourceReturnFocusTarget=nil}
        else if app.processIdentifier != ProcessInfo.processInfo.processIdentifier {self.sourceReturnFocusStarted=nil;self.sourceReturnFocusTarget=nil;connectionLog("Source return foreground measurement interrupted by app switch")}
      }
    })
    let distributed = DistributedNotificationCenter.default()
    safetyObserverTokens.append(
      workspace.addObserver(
        forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.suspendForSessionTransition("login session resigned active")
        }
      })
    safetyObserverTokens.append(
      workspace.addObserver(
        forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.relay.screenSleeping = true
          self?.suspendForSessionTransition("screen asleep")
        }
      })
    safetyObserverTokens.append(
      workspace.addObserver(
        forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
      ) { [weak self] _ in MainActor.assumeIsolated { self?.relay.screenSleeping = false } })
    safetyObserverTokens.append(
      distributed.addObserver(
        forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.suspendForSessionTransition("screen locked",actualScreenLock:true)
        }
      })
    safetyObserverTokens.append(
      workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated {
          self?.relay.systemSleeping = true
          self?.suspendForSessionTransition("system sleeping")
        }
      })
    safetyObserverTokens.append(
      workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated { self?.relay.systemSleeping = false }
      })
    // Unlock may permit ONLY a fresh authenticated session, never resume old input.
    safetyObserverTokens.append(distributed.addObserver(forName:Notification.Name("com.apple.screenIsUnlocked"),object:nil,queue:.main) {[weak self] _ in MainActor.assumeIsolated {self?.observedSessionUnlock()}})
    safetyObserverTokens.append(workspace.addObserver(forName:NSWorkspace.sessionDidBecomeActiveNotification,object:nil,queue:.main) {[weak self] _ in MainActor.assumeIsolated {self?.observedSessionUnlock()}})
    relay.safetyObserversInstalled = true
    relay.requestReceiverCursorFocus = { [weak self] in
      guard let self else{return}
      guard self.relay.receiverWantsCursorHidden,self.relay.receiverFocusRetry.begin(now:ProcessInfo.processInfo.systemUptime,unsettled:self.receiverCursorFocus.hasUnsettledActivation) else{return}
      self.receiverCursorFocus.requestTyped(stillNeeded:{[weak self] in self?.relay.receiverWantsCursorHidden == true},ready:{[weak self] in _ = self?.relay.syncReceiverCursor()},failed:{[weak self] failure in
        guard let self,self.relay.receiverWantsCursorHidden else{return}
        switch failure {
        case .timeout,.missingForeground,.unsettledActivation:
          self.relay.receiverFocusRetry.failed(now:ProcessInfo.processInfo.systemUptime)
          _ = self.relay.restoreReceiverCursor()
          self.relay.cursorDiagnostic("focus-transient-"+failure.rawValue)
        default:
          self.relay.receiverLocalCursorOverride(reason:"focus-"+failure.rawValue)
        }
      })
    }
    relay.receiverCursorFocusOwned = {[weak self] in self?.receiverCursorFocus.isOwned == true}
    relay.receiverFocusRecoveryPending = {[weak self] in self?.receiverCursorFocus.hasUnsettledActivation == true}
    relay.releaseReceiverCursorFocus = { [weak self] in if self?.receiverCursorFocus.isOwned == true {self?.receiverCursorFocus.release()} }
    relay.cancelReceiverCursorFocus = {[weak self] in self?.receiverCursorFocus.release()}
    relay.receiverLocalUserIntent = {[weak self] in self?.receiverCursorFocus.localUserOverride()}
    relay.prepareReceiverInputTarget = {[weak self] stillNeeded,completion in guard let self else{completion(false);return};self.receiverCursorFocus.prepareInputTarget(stillNeeded:stillNeeded,completion:completion)}
    sourceWindowOwnership.eligibleViewer = {[weak self] in self?.displayMode.sourceOwnershipViewer}
    displayMode.viewerOwnershipLost = {[weak self] in guard let self,self.relay.inputIsSender,self.relay.isTransferring || self.relay.forward else{return};self.relay.pauseSourceForForegroundLoss()}
    relay.sourceOwnershipConfirmed = { [weak self] in self?.sourceWindowOwnership.hasStableOwnership == true }
    relay.requestSourceActivation = { [weak self] in
      guard let self, self.relay.sessionAllowed else { return }
      let front = NSWorkspace.shared.frontmostApplication
      if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
        self.previousForeground = front
      }
      self.sourceWindowWasVisible = self.sourceWindowWasVisible || self.window.isVisible
      self.window.endEditing(for:nil);self.window.makeFirstResponder(nil)
      self.sourceWindowOwnership.request { [weak self] in self?.stop() }
      self.window.orderOut(nil)
    }
    relay.restoreSourceActivation = { [weak self] in
      guard let self else { return }
      let old = self.previousForeground
      let mayRestorePreviousApp=NSApp.isActive
      self.previousForeground = nil
      let keepsViewer=self.sourceWindowOwnership.restore()
      if self.sourceWindowWasVisible && self.connectedWindowVisibility.mayRestoreMainWindow { self.window.orderBack(nil) }
      self.sourceWindowWasVisible = false
      if !keepsViewer && mayRestorePreviousApp && self.relay.sessionAllowed,let old,!old.isTerminated {
        self.sourceReturnFocusStarted=ProcessInfo.processInfo.systemUptime;self.sourceReturnFocusTarget=old.processIdentifier
        old.activate(options:[.activateIgnoringOtherApps])
      }
    }
  }
  @objc func refreshPermissions() {
    guard settingsTabs.tabViewItems.contains(where:{($0.identifier as? String)=="permissions"}) else { return }
    let accessibility = AXIsProcessTrusted()
    let monitoring = CGPreflightListenEventAccess()
    accessibilityStatus.stringValue = TCText("Accessibility: ") + (accessibility ? TCText("Allowed") : TCText("Permission Required"))
    monitoringStatus.stringValue = TCText("Input Monitoring: ") + (monitoring ? TCText("Allowed") : TCText("Permission Required"))
    permissionSummary.stringValue =
      accessibility && monitoring
      ? TCText("Both required permissions are confirmed. Continue in the Connection tab. Permissions alone do not enable input.")
      : TCText("Required permissions are missing. Use the buttons below to open the relevant Privacy & Security settings.")
    if !didChooseInitialTab {
      settingsTabs.selectTabViewItem(at: accessibility && monitoring ? 0 : 1)
      didChooseInitialTab = true
    }
  }
  func openPermissionSettings(_ pane: String) {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane),
      NSWorkspace.shared.open(url)
    else {
      permissionSummary.stringValue = TCText("Could not open settings. Check permissions manually in System Settings → Privacy & Security.")
      return
    }
    permissionSummary.stringValue =
      TCText("Add and allow ThunderControl in System Settings, then return here. If a different page opens, select the relevant permission manually in Privacy & Security.")
  }
  @objc func openAccessibility() { openPermissionSettings("Privacy_Accessibility") }
  @objc func openMonitoring() { openPermissionSettings("Privacy_ListenEvent") }
  func installMenus() {
    let root = NSMenu()
    let appItem = NSMenuItem(title: "ThunderControl", action: nil, keyEquivalent: "")
    root.addItem(appItem)
    let appMenu = NSMenu(title: "ThunderControl")
    appMenu.addItem(withTitle:TCText("About ThunderControl"),action:#selector(NSApplication.orderFrontStandardAboutPanel(_:)),keyEquivalent:"")
    appMenu.addItem(appUpdateCheck.checkItem)
    appMenu.addItem(appUpdateCheck.availableItem)
    appMenu.addItem(.separator())
    let preferencesItem=appMenu.addItem(withTitle:TCText("Settings..."),action:#selector(showAppPreferences),keyEquivalent:",");preferencesItem.target=self
    appMenu.addItem(.separator())
    appMenu.addItem(
      withTitle: TCText("Quit ThunderControl"), action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q")
    appItem.submenu = appMenu
    let editItem = NSMenuItem(title: TCText("Edit"), action: nil, keyEquivalent: "")
    root.addItem(editItem)
    let edit = NSMenu(title: TCText("Edit"))
    edit.addItem(withTitle: TCText("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
    let redo = edit.addItem(withTitle: TCText("Redo"), action: Selector(("redo:")), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    edit.addItem(.separator())
    edit.addItem(withTitle: TCText("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: TCText("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: TCText("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: TCText("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = edit
    NSApp.mainMenu = root
  }
  func tabView(_ tabView:NSTabView,didSelect tabViewItem:NSTabViewItem?) {resizeForCurrentTab()}
  func resizeForCurrentTab() {
    guard let window,let id=settingsTabs.selectedTabViewItem?.identifier as? String else{return}
    let height:CGFloat = id=="displayStream" ? 570 : id=="layout" ? 520 : id=="permissions" ? 560 : id=="appearance" ? 260 : mode.selectedSegment==0 ? 350:260
    let width:CGFloat = id=="displayStream" ? 660 : id=="layout" ? 740 : id=="permissions" ? 640:560
    let target=window.frameRect(forContentRect:NSRect(x:0,y:0,width:width,height:height))
    guard abs(window.frame.height-target.height)>1 || abs(window.frame.width-target.width)>1 else{return}
    var frame=window.frame;frame.origin.y+=frame.height-target.height;frame.size=target.size;window.setFrame(frame,display:true,animate:false)
  }
  func refreshLayout() {
    screenLayout.sourceSize = CGDisplayBounds(CGMainDisplayID()).size
    screenLayout.remoteSize = relay.remoteDisplaySize
    screenLayout.remoteOnRight = relay.selectedEdge == .right
    screenLayout.offsetY = relay.layoutOffsetY
    // Multi-display receiver preview: the authenticated map is read-only; only
    // the source rectangle is user-draggable, mirroring the exact UI contract.
    screenLayout.receiverDesktop = relay.receiverDesktop
    screenLayout.sourceOrigin = relay.sourceOrigin
    if layoutOffsetField.currentEditor()==nil {layoutOffsetField.stringValue=String(format:"%.1f",relay.layoutOffsetY)}
    screenLayout.isInteractionEnabled =
      mode.selectedSegment == 0 && relay.remoteDisplaySize != nil && relay.canEditScreenLayout
    layoutOffsetField.isEnabled = screenLayout.isInteractionEnabled
    if let remote = relay.remoteDisplaySize {
      let layout = ScreenArrangement(
        sourceSize: screenLayout.sourceSize, remoteSize: remote,
        remoteOnRight: screenLayout.remoteOnRight, offsetY: relay.layoutOffsetY)
      layoutSummary.stringValue =
        layout.isValid
        ? TCText("Layout changes are saved automatically per device and restored on the next connection. Automatic switching stays enabled.") : TCText("Screen heights do not overlap. Adjust the layout.")
    } else {
      layoutSummary.stringValue = TCText("The other Mac's screen dimensions appear when connected. Set the layout on the Sender Mac.")
    }
  }
  func setLayoutOffset(_ value: Double) {
    guard mode.selectedSegment == 0, relay.canEditScreenLayout,
      value.isFinite, abs(value) <= 32768
    else {
      relay.status(TCText("Return to local control and finish the gesture before changing the layout. The connection stays active."))
      return
    }
    guard relay.editScreenLayout(edge:relay.selectedEdge,offset:value) else{refreshLayout();return}
    layoutOffsetField.stringValue = String(format: "%.1f", value)
    refreshLayout()
  }
  func setScreenArrangement(remoteOnRight:Bool,offset:Double) {
    guard mode.selectedSegment==0,relay.canEditScreenLayout else{refreshLayout();return}
    guard relay.editScreenLayout(edge:remoteOnRight ? .right:.left,offset:offset) else{refreshLayout();return}
    layoutOffsetField.stringValue=String(format:"%.1f",offset);refreshLayout()
  }
  @objc func applyLayoutOffset() {
    guard let value = Double(layoutOffsetField.stringValue) else {
      relay.status("Enter a finite layout offset in logical points")
      return
    }
    setLayoutOffset(value)
  }
  @objc func alignLayoutTop() { setLayoutOffset(0) }
  @objc func alignLayoutCenter() {
    guard let remote = relay.remoteDisplaySize else { return }
    setLayoutOffset((CGDisplayBounds(CGMainDisplayID()).height - remote.height) / 2)
  }
  @objc func generatePassphrase() {
    guard !relay.hasSession else {
      state.stringValue = TCText("Click Stop before generating a new passphrase.")
      return
    }
    let key = SymmetricKey(size: .bits256)
    pass.stringValue = key.withUnsafeBytes { Data($0.prefix(24)).base64EncodedString() }
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
    state.stringValue = TCText("Generated a random 32-character passphrase. Copy it and enter the same value on the other Mac. The passphrase is not saved.")
  }
  @objc func copyPassphrase() {
    guard pass.stringValue.count >= 16 else {
      state.stringValue = TCText("First enter a passphrase of at least 16 characters or click Generate Random.")
      return
    }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(pass.stringValue, forType: .string)
    state.stringValue = TCText("Passphrase copied to the clipboard. Enter the same value on the other Mac.")
  }
  @objc func refreshLocalAddress() {
    verifiedLocalIP = nil
    copyAddress.isEnabled = false
    do {
      let verified = try bridge(iface.stringValue)
      verifiedLocalIP = verified.ip
      localAddress.stringValue = TCText("This Mac's Thunderbolt IPv4: ") + verified.ip
      copyAddress.isEnabled = true
    } catch {
      localAddress.stringValue = TCText("Thunderbolt address unavailable: check the cable and bridge0 connection.")
    }
  }
  @objc func copyLocalAddress() {
    refreshLocalAddress()
    guard let ip = verifiedLocalIP else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(ip, forType: .string)
  }
  @objc func modeChanged() {
    displayPreferencePending=nil;displayPreferencePendingPair=nil
    let keepPaused=automaticConnectionPaused || sharingInputRestoreBlocked || relay.automaticReconnectSuspended
    sharingPrepareRoleChange()
    tearDownConnection(userStop:false)
    UserDefaults.standard.set(mode.selectedSegment==0 ? "send":"receive",forKey:"preferredRole")
    automaticConnectionPaused=keepPaused;nextAutomaticAttempt=0;nextDiscoveryAttempt=0;reconnectBackoff.reset();sessionAutoResume.revoke()
    refreshModeUI()
    refreshLocalAddress()
    if mode.selectedSegment == 0 { generatePIN(); searchPeers() }
  }
  @objc func toggle() {
    guard !relay.displayTopologyTransitionActive else{refreshModeUI();return}
    sharingUserChangedInput()
    relay.experimental = gesture.state == .on
    relay.configureAuto(
      mode.selectedSegment == 0 && automatic.state == .on,
      edge:relay.selectedEdge)
    relay.forward =
      mode.selectedSegment == 0 && !relay.displayTopologyTransitionActive && !relay.hasLocalInputsForAppearance && !relay.auto && !relay.hasUnresolvedLocalRecovery
      && forward.state == .on
    relay.consent(mode.selectedSegment == 1 && enable.state == .on)
    automatic.state = relay.auto ? .on : .off
    relay.experimental = gesture.state == .on
    if !relay.inject { relay.releaseInputs() }
    forward.state = relay.forward ? .on : .off
    enable.state = relay.inject ? .on : .off
    refreshLayout()
  }
  func refreshModeUI() {
    automatic.isEnabled = !relay.displayTopologyTransitionActive;forward.isEnabled = !relay.displayTopologyTransitionActive;enable.isEnabled = !relay.displayTopologyTransitionActive
    refreshDisplayPreferenceUI()
    let sending=mode.selectedSegment==0
    sendSection.isHidden = !sending; receiveSection.isHidden = sending
    connectButton.title = sending ? TCText("Connect") : TCText("Resume Listening")
    connectButton.isHidden = !sending && !automaticConnectionPaused && !relay.automaticReconnectSuspended
    connectButton.isEnabled = !relay.hasSession && !displayMode.cleaning && !relay.displayTopologyTransitionActive
    mode.isEnabled = !displayMode.active && !displayMode.cleaning
    pinRow.isHidden = relay.authenticated || (trustedSenderHint && !manualPairingAttempt)
    if sending && !settingsTabs.tabViewItems.contains(where:{$0 === layoutTabItem}) {settingsTabs.insertTabViewItem(layoutTabItem,at:2)}
    if !sending && settingsTabs.tabViewItems.contains(where:{$0 === layoutTabItem}) {settingsTabs.removeTabViewItem(layoutTabItem)}
    refreshLayout();updateConnectionState();resizeForCurrentTab()
  }
  @objc func toggleAppGestures() {
    relay.configureAppGestures(appGestureToggle.state == .on)
    appGestureToggle.state=relay.appGestureExperimental ? .on : .off
  }
  @objc func showManualPeer() {manualPeerRow.isHidden = manualPeerToggle.state != .on}
  @objc func peerSelected() {
    let i=peerPicker.indexOfSelectedItem
    if discoveredPeers.indices.contains(i),peer.stringValue != discoveredPeers[i].ipv4 {displayPreferencePending=nil;displayPreferencePendingPair=nil}
    syncSelectedPeerAddress()
  }
  func syncSelectedPeerAddress() {
    let i=peerPicker.indexOfSelectedItem
    guard discoveredPeers.indices.contains(i) else{return}
    peerSelectionConfirmed=true
    peer.stringValue=discoveredPeers[i].ipv4;port.stringValue=String(discoveredPeers[i].port)
  }
  @objc func searchPeersExplicit(){reconnectBackoff.reset();nextAutomaticAttempt=0;nextDiscoveryAttempt=0;searchPeers()}
  @objc func searchPeers() {
    guard mode.selectedSegment==0,!relay.hasSession else{return}
    discovery.stop();discoveryIsBrowsing=false
    discoveredPeers=[];peerSelectionConfirmed=false
    do {let b=try bridge(iface.stringValue);startPeerBrowsing(verified:b)}
    catch {discoveryIsBrowsing=false;relay.status(TCText("Thunderbolt peer discovery unavailable: check the cable and interface."))}
  }
  func startPeerBrowsing(verified b:Bridge) {
      peerSearchStartedAt=ProcessInfo.processInfo.systemUptime
      _ = verifiedBridgeRecovery.observe("\(b.name)/\(b.index)/\(b.ip)")
      discovery.startBrowsing(interfaceIndex:b.index,localIPv4:b.ip) { [weak self] peers in
        guard let self,self.mode.selectedSegment==0 else{return}
        let selected=self.peer.stringValue
        let previouslyConfirmed=self.peerSelectionConfirmed
        self.discoveredPeers=peers;self.peerPicker.removeAllItems()
        if peers.isEmpty {self.peerSelectionConfirmed=false;self.peerPicker.addItem(withTitle:TCText("No peer found: check that the Receiver Mac is listening and the cable is connected"))}
        else { for p in peers {self.peerPicker.addItem(withTitle:p.name)}
          if peers.count==1 {self.peerPicker.selectItem(at:0);if self.manualPeerToggle.state != .on {self.peerSelected()}}
          else if previouslyConfirmed,let i=peers.firstIndex(where:{$0.ipv4==selected}) {self.peerPicker.selectItem(at:i);if self.manualPeerToggle.state != .on {self.peerSelected()}}
          else {self.peerPicker.selectItem(at:-1);self.peerSelectionConfirmed=false}
        }
        self.requestAutomaticConnectionTick()
      }
      discoveryIsBrowsing=discovery.isBrowsing
  }
  @objc func generatePIN() {
    guard !relay.hasSession else{return}
    pinField.stringValue=String(format:"%04d",Int.random(in:0..<10000))
  }
  @objc func start() {
    guard !displayMode.cleaning,!relay.displayTopologyTransitionActive else{displayStatus.stringValue=TCText("Wait for the display configuration transition to finish.");return}
    automaticConnectionPaused=false;nextAutomaticAttempt=ProcessInfo.processInfo.systemUptime+5;nextDiscoveryAttempt=0;reconnectBackoff.reset();sessionAutoResume.revoke()
    UserDefaults.standard.set(mode.selectedSegment==0 ? "send":"receive",forKey:"preferredRole")
    dockOutputTestGeneration=UUID()
    window.endEditing(for:nil);window.makeFirstResponder(nil)
    do {
      let sending=mode.selectedSegment==0
      let p:UInt16=49177
      if sending && manualPeerToggle.state != .on {guard peerSelectionConfirmed else{throw Failure(TCText("Select a discovered Receiver Mac or choose to enter an address directly"))};syncSelectedPeerAddress()}
      if sending,pinField.stringValue.isEmpty {generatePIN()}
      if sending {guard pinField.stringValue.utf8.count==4,pinField.stringValue.utf8.allSatisfy({(48...57).contains($0)}) else{throw Failure(TCText("Set a 4-digit numeric code for this request"))}}
      discovery.stop();discoveryIsBrowsing=false
      let verified=try relay.start(name:"bridge0",peer:peer.stringValue,pass:sending ? pinField.stringValue : "",port:p,sendMode:sending)
      sharingDidStartExplicitConnection(sending:sending)
      automaticSessionVerified=true;manualPairingAttempt=sending;refreshModeUI()
      if !sending {advertiseVerifiedReceiver(verified,port:p)}
    } catch {relay.status(safeConnectionError(error));if !relay.hasSession {discovery.stop()}}
  }
  @objc func stop() {tearDownConnection(userStop:true)}
  func tearDownConnection(userStop:Bool,updateUI:Bool=true) {
    if userStop {sharingUserStoppedAll()}
    displayMode.stop()
    dockOutputTestGeneration=UUID()
    if let alert=pairingAlert {window.endSheet(alert.window,returnCode:.abort);pairingAlert=nil;pairingAlertToken=nil}
    automaticConnectionPaused=true;discoveryIsBrowsing=false;sessionAutoResume.revoke()
    discovery.stop();relay.stop();forward.state = .off;enable.state = .off;automatic.state = .off;if updateUI {refreshModeUI()}
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    applicationIsQuitting=true // Preserve sharing intent, but never restart video while quitting.
    if displayMode.active || displayMode.cleaning {
      if displayMode.active {displayMode.stop()}
      finishQuitAfterDisplayCleanup()
      return .terminateCancel
    }
    applicationIsQuitting=true
    relay.stop()
    if relay.hasUnresolvedLocalRecovery {
      applicationIsQuitting=false
      window?.makeKeyAndOrderFront(nil)
      relay.status(
        "Normal quit blocked until held inputs and cursor recovery are cleared. Release keys/buttons, then press Stop to retry. Force quit cannot guarantee cleanup."
      )
      return .terminateCancel
    }
    return .terminateNow
  }
  func applicationWillTerminate(_ n: Notification) {
    if !DevelopmentDiagnostics.shared.shutdown(timeout:2){fputs("Development diagnostics final local flush incomplete; inspect manifest counters.\n",stderr)}
    appUpdateCheck.stop();stopBridgeRecoveryScheduling();appearanceInstalled=false;appearanceTimer?.invalidate();automaticConnectionTimer?.invalidate();discovery.stop(); relay.stop();if !isAutomationTest {appearance.teardown()} }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  /// Display cleanup (input drain, helper exit, display restoration) is async. Poll
  /// it, then complete the user's single quit. Give up after 20s and stay running
  /// with a clear status rather than force-quitting through an unconfirmed cleanup.
  func finishQuitAfterDisplayCleanup() {
    guard quitAfterDisplayCleanupTimer == nil else{return}
    let deadline=ProcessInfo.processInfo.systemUptime+20
    quitAfterDisplayCleanupTimer=Timer.scheduledTimer(withTimeInterval:0.1,repeats:true){[weak self] timer in MainActor.assumeIsolated{
      guard let self,self.applicationIsQuitting else{timer.invalidate();self?.quitAfterDisplayCleanupTimer=nil;return}
      if !self.displayMode.active && !self.displayMode.cleaning {
        timer.invalidate();self.quitAfterDisplayCleanupTimer=nil;NSApp.terminate(nil);return
      }
      if ProcessInfo.processInfo.systemUptime>deadline {
        timer.invalidate();self.quitAfterDisplayCleanupTimer=nil;self.applicationIsQuitting=false
        self.displayStatus.stringValue=TCText("Quit paused: screen sharing cleanup did not finish. Choose Quit again after it finishes.")
      }
    }}
  }
}
func check(_ condition: Bool, file: String = #fileID, line: Int = #line) {
  if !condition {
    fputs("FAIL assertion \(file):\(line)\n", stderr)
    exit(1)
  }
}
func mustReject(_ body: () throws -> Void) throws {
  var rejected = false
  do { try body() } catch { rejected = true }
  guard rejected else { throw Failure("Expected rejection") }
}
func validKeyCode(_ n: Int64) -> Bool { (0...255).contains(n) }
func validButton(_ n: Int64) -> Bool { (0...31).contains(n) }
func matchingButton(_ type: UInt32, _ number: Int64) -> Bool {
  if [1, 2, 6].contains(type) { return number == 0 }
  if [3, 4, 7].contains(type) { return number == 1 }
  if [25, 26, 27].contains(type) { return (2...31).contains(number) }
  return true
}
// Memory-only construction: source relative deltas never compete with destination location.
func destinationMouseEvent(
  _ decoded: CGEvent, type: UInt32, point: CGPoint, source: CGEventSource? = nil
) -> CGEvent? {
  guard [1, 2, 3, 4, 5, 6, 7, 25, 26, 27].contains(type), point.x.isFinite, point.y.isFinite,
    let mouseType = CGEventType(rawValue: type)
  else { return nil }
  let number = decoded.getIntegerValueField(.mouseEventButtonNumber)
  guard validButton(number), matchingButton(type, number),
    let fresh = CGEvent(
      mouseEventSource: source, mouseType: mouseType, mouseCursorPosition: point,
      mouseButton: CGMouseButton(rawValue: UInt32(number)) ?? .center)
  else { return nil }
  fresh.flags = decoded.flags
  fresh.timestamp = DispatchTime.now().uptimeNanoseconds
  fresh.setIntegerValueField(
    .mouseEventClickState, value: decoded.getIntegerValueField(.mouseEventClickState))
  fresh.setIntegerValueField(.mouseEventButtonNumber, value: number)
  fresh.setDoubleValueField(
    .mouseEventPressure, value: decoded.getDoubleValueField(.mouseEventPressure))
  fresh.setDoubleValueField(.mouseEventDeltaX, value: 0)
  fresh.setDoubleValueField(.mouseEventDeltaY, value: 0)
  return fresh
}
func validFields(_ e: CGEvent, _ t: UInt32) -> Bool {
  if [10, 11, 12].contains(t) {
    guard (0...255).contains(e.getIntegerValueField(.keyboardEventKeycode)) else { return false }
  }
  if [1, 2, 3, 4, 5, 6, 7, 25, 26, 27].contains(t) {
    guard validButton(e.getIntegerValueField(.mouseEventButtonNumber)),
      matchingButton(t, e.getIntegerValueField(.mouseEventButtonNumber)), e.location.x.isFinite,
      e.location.y.isFinite
    else { return false }
  }
  return true
}
func appGesturePacketTests() throws {
  let event=CGEvent(source:nil)!
  event.type=CGEventType(rawValue:29)!
  event.setIntegerValueField(CGEventField(rawValue:110)!,value:8)
  event.setIntegerValueField(CGEventField(rawValue:132)!,value:1)
  event.setDoubleValueField(CGEventField(rawValue:113)!,value:0.25)
  guard let descriptor=NativeGestureDescriptor.decode(event),let data=event.data else{throw Failure("Memory gesture fixture unavailable")}
  let session=UUID().uuidString
  let w=Wire(kind:"appGesture",session:session,sequence:1,raw:29,data:data as Data,x:0.5,y:0.5,token:UUID().uuidString,appGesture:descriptor,appGestureID:UUID().uuidString,appGestureCodec:1)
  var v=PeerValidator(senderPeer:true,session:session);try v.accept(w)
  try mustReject{var p=PeerValidator(senderPeer:false,session:session);try p.accept(w)}
  try mustReject{var p=PeerValidator(senderPeer:true,session:session);var bad=w;bad.x=nil;try p.accept(bad)}
  try mustReject{var p=PeerValidator(senderPeer:true,session:session);var bad=w;bad.appGestureCodec=0;try p.accept(bad)}
  try mustReject{var p=PeerValidator(senderPeer:true,session:session);var bad=w;bad.appGesture = .init(kind:.rotate,phase:.began);try p.accept(bad)}
  let key=SymmetricKey(size:.bits256)
  check(AppGestureCodec.decode(try unseal(seal(w,key),key)) != nil)
  print("PASS typed app gesture memory packet, coordinates, role, codec, descriptor and authentication; no posting")
}
func dockProtocolTests() throws {
  let session=UUID().uuidString,token=UUID().uuidString,id=UUID().uuidString
  let d=DockGestureDescriptor(motion:2,phase:1,progress:0,velocityX:0,velocityY:0)
  let frame=Wire(kind:"dock",session:session,sequence:1,token:token,dock:d,dockID:id)
  var v=PeerValidator(senderPeer:true,session:session)
  try v.accept(frame)
  try mustReject {var receiver=PeerValidator(senderPeer:false,session:session);try receiver.accept(frame)}
  try mustReject {var bad=frame;bad.dockID="not-a-uuid";var fresh=PeerValidator(senderPeer:true,session:session);try fresh.accept(bad)}
  try mustReject {var bad=frame;bad.dock = .init(motion:2,phase:1,progress:99,velocityX:0,velocityY:0);var fresh=PeerValidator(senderPeer:true,session:session);try fresh.accept(bad)}
  try mustReject {var bad=frame;bad.token=nil;var fresh=PeerValidator(senderPeer:true,session:session);try fresh.accept(bad)}
  let key=SymmetricKey(size:.bits256)
  let decoded=try unseal(seal(frame,key),key)
  check(decoded.dock==d && decoded.dockID==id)
  print("PASS authenticated Dock descriptor roles, token, bounds and serialization; no posting")
}
func ownershipTests() {
  check(runModifierStateTests() == 0)
  for pair: [CGKeyCode] in [[56, 60], [59, 62], [58, 61], [55, 54]] {
    let d = modifierDescriptors[pair[0]]!
    let both = CGEventFlags(rawValue: d.aggregate.rawValue | d.pairBits)
    for first in [0, 1] {
      var normal = RemoteInputOwnership()
      for code in pair {
        normal.accepted(.modifier(code), down: modifierDown(code, flags: both)!, suppressed: true)
      }
      var forced = normal
      forced.force()
      let second = 1 - first
      let remaining = modifierDescriptors[pair[second]]!
      let one = CGEventFlags(rawValue: remaining.aggregate.rawValue | remaining.sideBit)
      normal.accepted(
        .modifier(pair[first]), down: modifierDown(pair[first], flags: one)!, suppressed: true)
      check(normal.owned == [.modifier(pair[second])])
      normal.accepted(
        .modifier(pair[second]), down: modifierDown(pair[second], flags: [])!, suppressed: true)
      check(normal.owned.isEmpty)
      check(
        forced.filter(
          .modifier(pair[first]), down: modifierDown(pair[first], flags: one)!, repeatKey: false))
      check(forced.blocked)
      check(
        forced.filter(
          .modifier(pair[second]), down: modifierDown(pair[second], flags: [])!, repeatKey: false))
      check(!forced.blocked)
    }
    var ambiguous = RemoteInputOwnership()
    ambiguous.quarantineModifierGroup(pair[0])
    check(ambiguous.blocked)
    check(ambiguous.reconcileModifierGroups(pair[1], flags: d.aggregate))
    check(ambiguous.blocked)
    check(ambiguous.reconcileModifierGroups(pair[0], flags: []))
    check(!ambiguous.blocked)
  }

  let old = UUID().uuidString
  let next = UUID().uuidString
  var source = RemoteInputOwnership()
  source.request(old, current: old, remote: true)
  // A down arriving after return request is still remote, never locally dropped.
  source.accepted(.key(0), down: true, suppressed: true)
  check(!source.ready(old, held: true))
  source.accepted(.button(0), down: true, suppressed: true)
  source.accepted(.key(0), down: false, suppressed: true)
  check(!source.ready(old, held: true))
  source.accepted(.button(0), down: false, suppressed: true)
  check(source.ready(old, held: false))
  check(!source.ready(next, held: false))
  source.pendingReturn = nil
  source.request(old, current: next, remote: true)
  check(source.pendingReturn == nil)
  source.accepted(.key(1), down: true, suppressed: true)
  source.accepted(.modifier(56), down: true, suppressed: true)
  source.force()
  check(source.blocked && source.owned.isEmpty)
  check(source.filter(.key(1), down: true, repeatKey: true))
  check(!source.filter(.key(2), down: true, repeatKey: false))
  check(source.filter(.key(1), down: false, repeatKey: false))
  check(source.filter(.modifier(56), down: false, repeatKey: false))
  check(!source.blocked)
  source.accepted(.key(3), down: true, suppressed: false)
  source.force()
  check(!source.blocked)  // manual mirror also delivered its down locally
  source.accepted(.key(4), down: true, suppressed: true)
  source.force()
  check(!source.filter(.key(4), down: true, repeatKey: false))
  check(!source.blocked)  // fresh press after missed release
  var target = EdgeHandoff()
  target.token = old
  target.phase = .targetActive
  check(acceptsToken(target, old))
  target.phase = .returning
  check(acceptsToken(target, old) && !acceptsToken(target, next))
  check(returnTimeoutMustCancel(target.phase))
  // Stale ACK cannot close a newer transfer.
  if target.token == next && target.phase == .returning { _ = target.reset() }
  check(target.phase == .returning)
  _ = target.reset()
  check(!acceptsToken(target, old))
  check(!returnTimeoutMustCancel(.remote))
  let motionFlags: CGEventFlags = [.maskShift, .maskAlphaShift, .maskNumericPad, .maskNonCoalesced]
  check(motionFlags.intersection(heldModifierMask) == .maskShift)
  check(
    CGEventFlags([.maskAlphaShift, .maskNumericPad, .maskNonCoalesced]).intersection(
      heldModifierMask
    ).isEmpty)
  var gate = EdgeHandoff(edge: .left)
  gate.phase = .targetActive
  gate.token = old
  gate.latched = false
  let held = !motionFlags.intersection(heldModifierMask).isEmpty
  _ = gate.motion(x: 0, y: 100, dx: -2, now: 0, held: held, w: 1000, h: 800)
  check(gate.motion(x: 0, y: 100, dx: -2, now: 1, held: held, w: 1000, h: 800) == .none)
  check(gate.phase == .targetActive)
  _ = gate.motion(x: 0, y: 100, dx: -2, now: 2, held: false, w: 1000, h: 800)
  check(gate.motion(x: 0, y: 100, dx: -2, now: 2.2, held: false, w: 1000, h: 800) == .requestReturn)
  print(
    "PASS pure ownership drain, quarantine, fresh press, manual mirror, stale tokens, returning input, timeout cancellation policy and side-specific paired modifier release orders, ambiguity recovery and modifier motion gate"
  )
}
func edgeTests() throws {
  final class WarpProbe: CursorRecoveryAPI {
    var point: CGPoint?
    func associate(_ associated: Bool) -> CGError { .success }
    func hide(display: CGDirectDisplayID) -> CGError { .success }
    func show(display: CGDirectDisplayID) -> CGError { .success }
    func warp(to point: CGPoint) -> CGError {
      self.point = point
      return .success
    }
  }
  var saved = EdgeHandoff(edge: .right)
  saved.arrangement = ScreenArrangement(
    sourceSize: CGSize(width: 1512, height: 982), remoteSize: CGSize(width: 2560, height: 1440),
    remoteOnRight: true, offsetY: -200)
  saved.y = 800
  saved.phase = .committed
  saved.deadline = 1
  check(saved.tick(2, preserveState: true) == .restore && saved.arrangement != nil)
  let probe = WarpProbe()
  let recovery = CursorRecoveryController(api: probe)
  if case .failure = recovery.acquire(display: 1) { check(false) }
  let result = recovery.restore(
    point: sourceCursorReturnPoint(
      bounds: CGRect(x: 0, y: 0, width: 1512, height: 982), edge: .right, handoff: saved))
  check(result.recovered && probe.point == CGPoint(x: 1510, y: 600))
  print("PASS timeout preserves geometry until actual mock recovery warp uses latest mapped Y")
  var direct = EdgeHandoff(edge: .right)
  direct.activationDelay = 0
  direct.activationDistance = 1
  direct.rearmDistance = 2
  _ = direct.motion(x: 900, y: 400, dx: 1, now: 0, held: false, w: 1000, h: 800)
  check(direct.motion(x: 999, y: 400, dx: 1, now: 0.001, held: false, w: 1000, h: 800) == .begin)
  var heldDirect = EdgeHandoff(edge: .right)
  heldDirect.activationDelay = 0
  _ = heldDirect.motion(x: 900, y: 400, dx: 1, now: 0, held: false, w: 1000, h: 800)
  check(heldDirect.motion(x: 999, y: 400, dx: 1, now: 1, held: true, w: 1000, h: 800) == .none)
  print("PASS direct transition removes fixed dwell but preserves held-input gate")
  let arrangement = ScreenArrangement(
    sourceSize: CGSize(width: 1512, height: 982), remoteSize: CGSize(width: 2560, height: 1440),
    remoteOnRight: true, offsetY: -200)
  var alignedSource = EdgeHandoff(edge: .right)
  alignedSource.arrangement = arrangement
  _ = alignedSource.motion(x: 1400, y: 500, dx: 1, now: 0, held: false, w: 1512, h: 982)
  _ = alignedSource.motion(x: 1511.5, y: 500, dx: 1, now: 1, held: false, w: 1512, h: 982)
  check(
    alignedSource.motion(x: 1511.5, y: 500, dx: 1, now: 1.3, held: false, w: 1512, h: 982) == .begin
  )
  let alignedToken = alignedSource.token!
  check(alignedSource.ready(alignedToken, w: 2560, h: 1440, now: 1.4) == .commit)
  check(abs(alignedSource.y - 700) < 0.000001)
  var alignedTarget = EdgeHandoff()
  check(
    alignedTarget.begin(
      alignedToken, edge: .right, offset: 500.0 / 982.0, enabled: true, w: 2560, h: 1440, now: 1.35,
      sourceSize: CGSize(width: 1512, height: 982), layoutY: -200) == .activate)
  check(alignedTarget.commit(alignedToken, now: 1.5) == .activate)
  check(abs(alignedTarget.y - 700) < 0.000001)
  check(alignedSource.active(alignedToken, now: 1.6) == .remote)
  alignedSource.relative(0, 100)
  check(abs((alignedSource.y + arrangement.offsetY) - 600) < 0.000001)
  // The target must not return at heights where the source screen does not exist.
  _ = alignedTarget.motion(x: 100, y: 100, dx: -1, now: 2, held: false, w: 2560, h: 1440)
  check(alignedTarget.motion(x: 0, y: 100, dx: -1, now: 3, held: false, w: 2560, h: 1440) == .none)
  check(alignedTarget.phase == .targetActive)
  check(!alignedTarget.latched)
  check(
    alignedTarget.motion(x: 0, y: 700, dx: -1, now: 3.1, held: false, w: 2560, h: 1440)
      == .requestReturn)
  print(
    "PASS aligned entry preserves global Y and return uses current remote Y; non-overlap does not handoff"
  )
  for type: NSEvent.EventType? in [
    nil, .gesture, .beginGesture, .endGesture, .mouseMoved, .scrollWheel,
  ] {
    check(!blocksPointerHandoff(type))
  }
  for type: NSEvent.EventType in [.magnify, .rotate, .swipe] {
    check(blocksPointerHandoff(type))
    check(!blocksPointerHandoff(type, changed: false))
  }
  check(edgeHeldReason(keys: false, buttons: false, modifiers: false, gesture: false) == nil)
  check(
    edgeHeldReason(keys: true, buttons: false, modifiers: false, gesture: false)
      == "keyboard input still held")
  check(
    edgeHeldReason(keys: false, buttons: true, modifiers: false, gesture: false)
      == "mouse button still held")
  check(
    edgeHeldReason(keys: false, buttons: false, modifiers: true, gesture: false)
      == "modifier still held")
  check(
    edgeHeldReason(keys: false, buttons: false, modifiers: false, gesture: true)
      == "explicit gesture cooldown")
  print(
    "PASS generic touch/begin/end cannot refresh gesture gate; explicit gestures still block; held-input reasons separated"
  )
  for edge in [Edge.left, .right] {
    var retina = EdgeHandoff(edge: edge)
    _ = retina.motion(
      x: 756, y: 981.5, dx: edge == .right ? 1 : -1, now: 0, held: false, w: 1512, h: 982)
    let edgeX = edge == .right ? 1511.5 : 0.0
    let dx = edge == .right ? 1.0 : -1.0
    _ = retina.motion(x: edgeX, y: 981.5, dx: dx, now: 1, held: false, w: 1512, h: 982)
    check(
      retina.motion(x: edgeX, y: 981.5, dx: dx, now: 1.3, held: false, w: 1512, h: 982) == .begin)
    var outside = EdgeHandoff(edge: edge)
    _ = outside.motion(x: 756, y: 400, dx: dx, now: 0, held: false, w: 1512, h: 982)
    check(outside.motion(x: 1512, y: 400, dx: dx, now: 1, held: false, w: 1512, h: 982) == .none)
    check(outside.motion(x: edgeX, y: 982, dx: dx, now: 1, held: false, w: 1512, h: 982) == .none)
  }
  print(
    "PASS Retina fractional right/bottom coordinates accepted; exact outside display coordinates rejected"
  )
  let id = UUID().uuidString
  let stale = UUID().uuidString
  var source = EdgeHandoff(edge: .right)
  check(source.phase == .local)
  var outside = EdgeHandoff(edge: .right)
  outside.latched = false
  check(outside.motion(x: 2000, y: 10, dx: 3, now: 0, held: false, w: 1000, h: 800) == .none)
  check(outside.motion(x: 2000, y: 10, dx: 3, now: 1, held: false, w: 1000, h: 800) == .none)
  check(outside.phase == .local)
  check(source.motion(x: 999, y: 100, dx: 3, now: 0, held: false, w: 1000, h: 800) == .none)
  _ = source.motion(x: 500, y: 100, dx: 1, now: 0, held: false, w: 1000, h: 800)
  _ = source.motion(x: 999, y: 400, dx: 2, now: 1, held: true, w: 1000, h: 800)
  check(source.phase == .local)
  _ = source.motion(x: 999, y: 400, dx: 2, now: 2, held: false, w: 1000, h: 800)
  check(source.motion(x: 999, y: 400, dx: 2, now: 2.2, held: false, w: 1000, h: 800) == .begin)
  let t = source.token!
  check(source.active(t, now: 2.3) == .none)
  check(source.ready(stale, w: 2000, h: 1000, now: 2.3) == .none)
  check(source.ready(t, w: 2000, h: 1000, now: 2.3) == .commit)
  check(source.phase == .committed)
  check(source.active(stale, now: 2.4) == .none)
  check(source.active(t, now: 2.4) == .remote)
  let x = source.x
  let y = source.y
  source.relative(40, 80)
  check(source.x == x + 40 && source.y == y + 80)
  source.relative(.infinity, 0)
  check(source.x == x + 40)
  check(source.reset() == .restore && source.phase == .local)
  var target = EdgeHandoff()
  check(
    target.begin(id, edge: .right, offset: 0.5, enabled: false, w: 2000, h: 1000, now: 0) == .none)
  check(
    target.begin(id, edge: .right, offset: 0.5, enabled: true, w: 2000, h: 1000, now: 0)
      == .activate)
  check(target.commit(stale, now: 0.1) == .none)
  check(target.commit(id, now: 0.1) == .activate && target.edge == .left)
  check(target.motion(x: 0, y: 500, dx: -2, now: 0.2, held: false, w: 2000, h: 1000) == .none)
  _ = target.motion(x: 40, y: 500, dx: 2, now: 0.3, held: false, w: 2000, h: 1000)
  _ = target.motion(x: 0, y: 500, dx: -2, now: 0.5, held: false, w: 2000, h: 1000)
  check(
    target.motion(x: 0, y: 500, dx: -2, now: 0.7, held: false, w: 2000, h: 1000) == .requestReturn)
  check(target.tick(3) == .restore && target.phase == .local)
  var left = EdgeHandoff(edge: .left)
  _ = left.motion(x: 50, y: 100, dx: 1, now: 0, held: false, w: 1000, h: 800)
  _ = left.motion(x: 0, y: 200, dx: -2, now: 1, held: false, w: 1000, h: 800)
  check(left.motion(x: 0, y: 200, dx: -2, now: 1.2, held: false, w: 1000, h: 800) == .begin)
  check(left.offset == 0.25)
  check(left.tick(3) == .restore)
  var timeout = EdgeHandoff()
  _ = timeout.begin(id, edge: .left, offset: 1, enabled: true, w: 800, h: 600, now: 0)
  check(timeout.tick(2) == .restore && timeout.commit(id, now: 2) == .none)
  let root = derive("edge-testing-passphrase")
  let a = UUID().uuidString
  let b = UUID().uuidString
  let forwardKey = connectionKey(root, sender: a, receiver: b)
  let reverseKey = connectionKey(root, sender: a, receiver: b, reverse: true)
  let frame = Wire(
    kind: "begin", session: a, sequence: 1, y: 0.5, token: id, edge: .left, screenWidth: 1920,
    screenHeight: 1080, layoutY: 0)
  let sealed = try seal(frame, forwardKey)
  try mustReject { _ = try unseal(sealed, reverseKey) }
  try mustReject {
    _ = try unseal(sealed, connectionKey(root, sender: a, receiver: UUID().uuidString))
  }
  var receiver = PeerValidator(senderPeer: true, session: a)
  try receiver.accept(frame)
  try mustReject { try receiver.accept(frame) }
  var wrongRole = PeerValidator(senderPeer: false, session: a)
  try mustReject { try wrongRole.accept(frame) }
  var malformed = frame
  malformed.y = .infinity
  var fresh = PeerValidator(senderPeer: true, session: a)
  try mustReject { try fresh.accept(malformed) }
  var reply = PeerValidator(senderPeer: false, session: b)
  try reply.accept(
    Wire(kind: "ready", session: b, sequence: 1, token: id, width: 1920, height: 1080))
  print(
    "PASS pure edge geometry, handshake gates, stale tokens, relative cursor, held-input gate, entry latch, timeout/disconnect reset, v5 direction keys and role counters"
  )
}
func tests() throws {
  check(runScreenLayoutTests() == 0)
  check(runSessionSafetyTests() == 0)
  #if TC_FRESH_RECEIVER_SAFETY
  check(Relay.verifyFreshDisplaySafetyForTests())
  check(DisplayTransport.verifyFreshSafetyWorkerForTests())
  check(MainActor.assumeIsolated{DisplayModeController.verifyPeriodicSafetyForTests()})
  #endif
  try displayViewerStartupLifecycleTests()
  check(Relay.verifyUnsafeStopOrderingForTests())
  check(Relay.verifyForegroundPausePreservesConnectionForTests())
  print(
    "PASS unsafe session cancels transport and invalidates queues before mock cursor recovery/activation callback"
  )
  for type in positionalMouseTypes {
    let button: Int64 = [3, 4, 7].contains(type) ? 1 : [25, 26, 27].contains(type) ? 2 : 0
    let original = CGEvent(
      mouseEventSource: nil, mouseType: CGEventType(rawValue: type)!,
      mouseCursorPosition: CGPoint(x: 900, y: 700),
      mouseButton: CGMouseButton(rawValue: UInt32(button))!)!
    original.setIntegerValueField(.mouseEventButtonNumber, value: button)
    original.setIntegerValueField(.mouseEventClickState, value: 2)
    original.setDoubleValueField(.mouseEventPressure, value: 0.5)
    original.setDoubleValueField(.mouseEventDeltaX, value: 99)
    original.flags = [.maskShift]
    var frame = Wire(
      kind: "event", session: UUID().uuidString, sequence: 1, raw: type,
      data: original.data as Data?, x: 0.5, y: 0.25)
    check(validMouseCoordinates(frame))
    let event = destinationMouseEvent(original, type: type, point: CGPoint(x: 10.5, y: 20.5))!
    check(event.location == CGPoint(x: 10.5, y: 20.5) && event.flags == .maskShift)
    check(event.getIntegerValueField(.mouseEventButtonNumber) == button)
    check(event.getIntegerValueField(.mouseEventClickState) == 2)
    check(
      abs(
        event.getDoubleValueField(.mouseEventPressure)
          - original.getDoubleValueField(.mouseEventPressure)) < 0.004)
    check(
      event.getDoubleValueField(.mouseEventDeltaX) == 0
        && event.getDoubleValueField(.mouseEventDeltaY) == 0)
    frame.x = nil
    check(!validMouseCoordinates(frame))
    var checker = PeerValidator(senderPeer: true, session: frame.session)
    try mustReject { try checker.accept(frame) }
    frame.x = 0.5
    frame.y = nil
    check(!validMouseCoordinates(frame))
    frame.y = .nan
    check(!validMouseCoordinates(frame))
  }
  var wheelFrame = Wire(
    kind: "event", session: UUID().uuidString, sequence: 1, raw: 22, data: Data([1]), x: 0.5, y: 0.5
  )
  check(validMouseCoordinates(wheelFrame))
  wheelFrame.x = nil
  check(!validMouseCoordinates(wheelFrame))
  print(
    "PASS all10 destination mouse types: required coordinates, button/click/pressure/flags and zero-delta consistency; no injection"
  )
  let oldMouse = CGEvent(
    mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: 900, y: 700),
    mouseButton: .left)!
  oldMouse.flags = [.maskShift]
  oldMouse.setDoubleValueField(.mouseEventDeltaX, value: 120)
  oldMouse.setDoubleValueField(.mouseEventDeltaY, value: -40)
  let absolute = destinationMouseEvent(oldMouse, type: 5, point: CGPoint(x: 1, y: 321.5))!
  check(absolute.location == CGPoint(x: 1, y: 321.5))
  check(
    absolute.getDoubleValueField(.mouseEventDeltaX) == 0
      && absolute.getDoubleValueField(.mouseEventDeltaY) == 0)
  check(oldMouse.getDoubleValueField(.mouseEventDeltaX) == 120)
  check(absolute.flags == .maskShift)
  print(
    "PASS fresh absolute mouse event matches destination and has no source-relative deltas; memory only"
  )
  check(Relay.verifyStaleActiveForTests())
  var ordered=EntryMotionBuffer();let orderedToken=UUID().uuidString;ordered.begin(token:orderedToken)
  check(ordered.append(token:orderedToken,dx:2,dy:-30));check(ordered.append(token:orderedToken,dx:2,dy:30))
  var clampedModel=EdgeHandoff();clampedModel.phase = .remote;clampedModel.width=100;clampedModel.height=100;clampedModel.x=1;clampedModel.y=10
  for move in ordered.takeMoves(token:orderedToken)! {clampedModel.relative(move.dx,move.dy)}
  check(clampedModel.x==5 && clampedModel.y==30)
  print("PASS stale active ignored without focus checks; ordered pending motion preserves per-sample boundary clamping")
  let unsafe = DecodingError.dataCorrupted(
    .init(codingPath: [], debugDescription: "PAYLOAD_SENTINEL_DO_NOT_LOG"))
  check(!safeConnectionError(unsafe).contains("PAYLOAD_SENTINEL_DO_NOT_LOG"))
  check(safeConnectionError(CryptoKitError.authenticationFailure).contains("Session authentication failed"))
  var testSocketPair: [Int32] = [0, 0]
  check(!heartbeatExpired(authenticated: false, idle: 3600))
  check(!heartbeatExpired(authenticated: true, idle: 6))
  check(heartbeatExpired(authenticated: true, idle: 6.1))
  let pairResult = socketpair(AF_UNIX, SOCK_STREAM, 0, &testSocketPair)
  check(pairResult == 0)
  let originalFlags = fcntl(testSocketPair[0], F_GETFL)
  check(fcntl(testSocketPair[0], F_SETFL, originalFlags | O_NONBLOCK) == 0)
  try setBlocking(testSocketPair[0])
  check(fcntl(testSocketPair[0], F_GETFL) & O_NONBLOCK == 0)
  close(testSocketPair[0])
  close(testSocketPair[1])
  print("PASS pre-auth wait has no heartbeat expiry and connected socket blocking mode is explicit")
  check(runModifierStateTests() == 0)
  for pair: [CGKeyCode] in [[56, 60], [59, 62], [58, 61], [55, 54]] {
    let descriptor = modifierDescriptors[pair[0]]!
    let fixture = CGEvent(source: nil)!
    fixture.flags = CGEventFlags(rawValue: descriptor.aggregate.rawValue | descriptor.pairBits)
    let data = fixture.data!
    let decoded = CGEvent(withDataAllocator: nil, data: data)!
    check(decoded.flags.rawValue == fixture.flags.rawValue)
    check(
      modifierDown(pair[0], flags: decoded.flags) == true
        && modifierDown(pair[1], flags: decoded.flags) == true)
  }
  check(runCursorRecoveryTests() == 0)
  check(runDisplayTopologyTests() == 0)
  ownershipTests()
  try edgeTests()
  check(matchingButton(1, 0) && !matchingButton(1, 1))
  check(matchingButton(3, 1) && !matchingButton(3, 0))
  check(matchingButton(25, 2) && !matchingButton(25, 0))
  try validateThunderboltMembers(["en2", "en3"], ["en2", "en3", "en4"], active: true)
  try mustReject { try validateThunderboltMembers(["en2", "en1"], ["en2"], active: true) }
  try mustReject { try validateThunderboltMembers([], ["en2"], active: true) }
  try mustReject { try validateThunderboltMembers(["en2"], ["en2"], active: false) }
  try mustReject { try validateThunderboltMembers(["en2"], [], active: true) }
  let k = derive("a-high-entropy-test-passphrase")
  let hello = Wire(kind: "hello", session: UUID().uuidString, sequence: 0)
  let enc = try seal(hello, k)
  let freshKey = HKDF<SHA256>.deriveKey(
    inputKeyMaterial: k, salt: Data(UUID().uuidString.utf8),
    info: Data("fresh-receiver-challenge".utf8), outputByteCount: 32)
  try mustReject { _ = try unseal(enc, freshKey) }
  let recordedSender = UUID().uuidString
  let oldReceiver = UUID().uuidString
  let freshReceiver = UUID().uuidString
  let recordedHello = try seal(
    Wire(kind: "sender-hello-v5", session: recordedSender, sequence: 0), k)
  var replayedHello = try unseal(recordedHello, k)
  replayedHello.kind = "hello"
  var newSessionValidator = Validator()
  try newSessionValidator.accept(replayedHello)
  let recordedEvent = try seal(
    Wire(kind: "event", session: recordedSender, sequence: 1, raw: 22),
    connectionKey(k, sender: recordedSender, receiver: oldReceiver))
  try mustReject {
    _ = try unseal(recordedEvent, connectionKey(k, sender: recordedSender, receiver: freshReceiver))
  }
  var pair: [Int32] = [0, 0]
  guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
    throw Failure("Socket lifetime test setup failed")
  }
  let heldSocket = OwnedSocket(pair[0])
  let otherSocket = OwnedSocket(pair[1])
  let life = SessionContext(heldSocket)
  life.cancel()
  check(life.cancelled)
  withExtendedLifetime((life, heldSocket, otherSocket)) {
    check(fcntl(heldSocket.fd, F_GETFD) >= 0)
    check(fcntl(otherSocket.fd, F_GETFD) >= 0)
  }
  let opened = try unseal(enc, k)
  check(opened.session == hello.session)
  var bad = enc
  bad[bad.count - 1] ^= 1
  do {
    _ = try unseal(bad, k)
    throw Failure("tamper accepted")
  } catch is CryptoKitError {}
  var v = Validator()
  try v.accept(hello)
  let event = Wire(kind: "event", session: hello.session, sequence: 1, raw: 10)
  try v.accept(event)
  try mustReject { try v.accept(event) }
  check(v.next == 2)
  try mustReject { _ = try unseal(Data(count: cap + 1), k) }
  check(!allowed(29,false) && !allowed(29,true) && !allowed(30,true) && !allowed(31,true))
  check(!Relay().forward && !Relay().inject && Relay().experimental && Relay().appGestureExperimental)
  try mustReject { _ = try bridge("en0") }
  try mustReject { _ = try bridge("bridge99999") }
  let malformed = CGEvent(source: nil)!
  malformed.setIntegerValueField(.keyboardEventKeycode, value: 999999)
  check(!validKeyCode(999999))
  malformed.setIntegerValueField(.mouseEventButtonNumber, value: -1)
  check(!validButton(-1))
  let e = CGEvent(source: nil)!
  for (f, n) in [(55, 30), (110, 23), (123, 1), (132, 1)] {
    e.setIntegerValueField(CGEventField(rawValue: UInt32(f))!, value: Int64(n))
  }
  e.setDoubleValueField(CGEventField(rawValue: 124)!, value: 0.5)
  guard let raw = e.data, let decoded = CGEvent(withDataAllocator: nil, data: raw) else {
    throw Failure("event serialization failed")
  }
  for (f, n) in [(55, 30), (110, 23), (123, 1), (132, 1)] {
    print(
      "field", f, "expected", n, "actual",
      decoded.getIntegerValueField(CGEventField(rawValue: UInt32(f))!))
    check(decoded.getIntegerValueField(CGEventField(rawValue: UInt32(f))!) == Int64(n))
  }
  check(decoded.getDoubleValueField(CGEventField(rawValue: 124)!) == 0.5)
  print(
    "PASS encryption, recorded-session replay rejection, tamper, socket lifetime, frame cap, counters, mouse consistency, unauthenticated input OFF, Thunderbolt members, bridge fail closed, private field serialization (no capture/injection)"
  )
}
@main
struct ThunderControlMain {
  @MainActor static func main() {
    if CommandLine.arguments.contains("--reset-local-state") {
      guard !NSRunningApplication.runningApplications(withBundleIdentifier:"local.experimental.ThunderControl").contains(where:{$0.processIdentifier != ProcessInfo.processInfo.processIdentifier}) else{fputs("Quit ThunderControl before resetting its local state.\n",stderr);exit(2)}
      do {try TrustedPairingStore.resetForFirstSetup();print("ThunderControl-only trust and preferences reset. Other apps untouched.")}catch{fputs("ThunderControl local reset failed; no permission reset performed.\n",stderr);exit(1)}
    } else if let i=CommandLine.arguments.firstIndex(of:"--display-viewer-ui-test") ?? CommandLine.arguments.firstIndex(of:"--display-viewer-fullscreen-test"),i+2<CommandLine.arguments.count {
      let application=NSApplication.shared;application.setActivationPolicy(CommandLine.arguments.contains("--accessory-viewer") ? .accessory:.regular)
      Task { @MainActor in
        do {let format=try displayTestFormat(arguments:CommandLine.arguments,after:i+3);try await runDisplayViewerUITests(path:CommandLine.arguments[i+1],output:CommandLine.arguments[i+2],format:format,startsFullScreen:CommandLine.arguments[i]=="--display-viewer-fullscreen-test");exit(0)}
        catch {fputs("Display native viewer test failed: \(error)\n",stderr);exit(1)}
      }
      application.run()
    } else if let i=CommandLine.arguments.firstIndex(of:"--display-pipeline-self-test"),i+1<CommandLine.arguments.count {
      do{
        let format=try displayTestFormat(arguments:CommandLine.arguments,after:i+2)
        try runDisplayPipelineTests(path:CommandLine.arguments[i+1],format:format)
      }catch{fputs("Display offline pipeline failed\n",stderr);exit(1)}
    } else if CommandLine.arguments.contains("--pairing-integration-test") {
      do {try runPINRelayIntegrationTests()}catch{fputs("FAIL paired protocol integration: \(error)\n",stderr);exit(1)}
    } else if CommandLine.arguments.contains("--localization-self-test") {
      exit(runLocalizationTests()==0 ? 0:1)
    } else if CommandLine.arguments.contains("--ownership-self-test") {
      ownershipTests()
    } else if CommandLine.arguments.contains("--desktop-map-self-test") {
      exit(runDesktopMapTransitionTests()==0 ? 0:1)
    } else if CommandLine.arguments.contains("--self-test") {
      do { try tests();check(runLocalizationTests()==0);check(runConcurrentDisplayTests()==0);check(runReceiverDesktopRelayTests()==0);check(runReceiverDesktopTests()==0);check(runSavedDesktopPlacementTests()==0);check(runReceiverDesktopUITests()==0);check(runDesktopMapTransitionTests()==0);check(runDesktopHandoffRoutingTests()==0);check(runDesktopEntryPolicyTests()==0);check(runDisplayHeartbeatTests()==0);check(runDisplayTrustTests()==0);check(runDisplayRemoteInputTests()==0);check(runDisplayTransportTests()==0);check(runDisplayCadenceTests()==0);check(runDisplayFramePacingTests()==0);check(runDisplayVideoFormatTests()==0);check(runSavedSharingStateTests()==0);check(runAutomaticSharingResumeTests()==0);check(runSharingLifecycleIntegrationTests()==0);check(runDisplayPreferenceTests()==0);check(runUpdateReleaseTests()==0);check(runSavedVirtualDisplayPlacementTests()==0);check(runVirtualDisplayPlacementSessionTests()==0);check(runDisplayVideoDecoderTests()==0);check(runDisplayDecodeWorkerTests()==0);check(runScrollReplayTests()==0);check(runDiscoveryRecoveryPolicyTests()==0);check(runNativeGestureTests()==0);check((runDockTransferStateTests()+runDesktopSystemGestureTests())==0);check(runTransitionMotionTests()==0);check(runGestureTraceTests()==0);check(runCursorVisibilityTests()==0);check(runConnectedLayoutTests()==0);check(runCursorModeProtocolTests()==0);ReceiverCursorFocusTests.run();check(runAutomaticConnectionPolicyTests()==0);check(runCableReconnectPolicyTests()==0);check(runReceiverFocusRetryTests()==0);check(runReturnWarpResumeTests()==0);check(runDiagnosticStoreTests()==0);check(runDevelopmentDiagnosticsTests()==0);check(runDevelopmentFrameTraceTests()==0);check(runDisplayDiagnosticLinesTests()==0);check(runTrustedPairingTests()==0);check(runConnectionNotificationTests()==0);check(runSingleConnectionNotificationTests()==0);check(runAppAppearancePreferencesTests()==0);check(runAppWindowPresentationPolicyTests()==0);check(runConnectedWindowVisibilityTests()==0);check(runSavedScreenLayoutTests()==0);check(Relay.verifyDeviceLayoutPersistenceForTests());check(runSessionAutoResumeTests()==0);check(runSessionSuspensionOriginTests()==0);check(Relay.verifySessionSuspensionOriginsForTests());check(runAutomaticReconnectBackoffTests()==0);check(runBridgeRecoverySchedulingTests()==0);check(runLockedTransportPolicyTests()==0);check(runAuthenticatedRouteHintTests()==0);check(runFastReconnectPolicyTests()==0);check(Relay.verifyLockedTransportInputBarrierForTests());check(!Relay().receiverWantsCursorHidden);ScreenArrangementDragTests.run();check(Relay.verifyReceiverRecoveryBlocksStartForTests());check(Relay.verifyReceiverPhysicalInputCancelsActivationForTests());try dockProtocolTests();try appGesturePacketTests();print("PASS gesture memory classification and system stream ordering; no posting") } catch {
        fputs("FAIL \(error)\n", stderr)
        exit(1)
      }
    } else if CommandLine.arguments.contains("--recovery-self-test") {
      check(runCursorRecoveryTests() == 0 && runDisplayTopologyTests() == 0)
      print("PASS mock cursor recovery and pure topology checks; no real input or cursor effects")
    } else if CommandLine.arguments.contains("--check-display") {
      do {
        let snapshot = try captureSingleDisplayTopology()
        print(
          "Verified single display: mainID=\(snapshot.mainID), active=\(snapshot.activeIDs.count), size=\(snapshot.bounds.width)x\(snapshot.bounds.height)"
        )
      } catch {
        fputs("Single-display check: \(error)\n", stderr)
        exit(2)
      }
    } else if CommandLine.arguments.contains("--check-bridge") {
      do {
        let b = try bridge("bridge0")
        print("Verified Thunderbolt bridge: \(b.name) \(b.ip)")
      } catch {
        fputs("Bridge check: \(error)\n", stderr)
        exit(2)
      }
    } else {
      let app = NSApplication.shared
      let offscreen = CommandLine.arguments.contains("--ui-smoke-test") && CommandLine.arguments.contains("--layout-only") && CommandLine.arguments.contains("--offscreen-localization")
      app.setActivationPolicy(offscreen ? .prohibited : .regular)
      let delegate = App()
      app.delegate = delegate
      withExtendedLifetime(delegate) { app.run() }
    }

  }
}
