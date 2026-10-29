import Foundation
import Darwin

/// Only a classified inactive link may wait. Unknown membership, identity or
/// address errors still throw, so grace can never turn into route fallback.
enum BridgeLinkStatus {
  case active(Bridge), inactive(Bridge)
  var bridge:Bridge {switch self {case .active(let b),.inactive(let b):return b}}
}

struct BridgeLinkGrace {
  private(set) var inactiveSince:Double?
  mutating func observe(active:Bool,now:Double)->Bool {
    guard now.isFinite,now>=0 else{return false}
    if let start=inactiveSince,now<start || now-start>=2 {return false}
    if active {inactiveSince=nil;return true}
    if inactiveSince==nil {inactiveSince=now}
    return true
  }
}

func verifiedBridgeLinkStatus(_ name:String,text:String)throws->BridgeLinkStatus {
  guard name=="bridge0" else{throw Failure("Only bridge0 is supported")}
  var members=Set<String>(),active:Bool?
  for line in text.components(separatedBy:.newlines) {
    let words=line.split(whereSeparator:{$0.isWhitespace})
    if words.count>=2,words[0]=="member:" {members.insert(String(words[1]))}
    if words.count==2,words[0]=="status:" {
      guard active==nil,words[1]=="active" || words[1]=="inactive" else{throw Failure("Unknown bridge link status")}
      active=words[1]=="active"
    }
  }
  guard let active else{throw Failure("Missing bridge link status")}
  // Prove the hardware even when the cable is temporarily inactive.
  try validateThunderboltMembers(members,thunderboltHardwareNames(),active:true)
  var list:UnsafeMutablePointer<ifaddrs>?
  guard getifaddrs(&list)==0 else{throw Failure("getifaddrs failed")}
  defer{freeifaddrs(list)}
  var cursor=list
  while let item=cursor {
    cursor=item.pointee.ifa_next
    let value=item.pointee
    guard String(cString:value.ifa_name)==name,let sockAddress=value.ifa_addr,
      Int32(sockAddress.pointee.sa_family)==AF_INET,(value.ifa_flags & UInt32(IFF_UP)) != 0 else{continue}
    if active && (value.ifa_flags & UInt32(IFF_RUNNING))==0 {throw Failure("Active bridge is not running")}
    var host=[CChar](repeating:0,count:Int(INET_ADDRSTRLEN))
    var ipv4=UnsafeRawPointer(sockAddress).assumingMemoryBound(to:sockaddr_in.self).pointee
    guard inet_ntop(AF_INET,&ipv4.sin_addr,&host,socklen_t(host.count)) != nil else{throw Failure("Bridge address unavailable")}
    let ip=String(cString:host),index=if_nametoindex(name)
    _ = try address(ip,49177)
    guard index>0 else{throw Failure("Bridge interface unavailable")}
    let bridge=Bridge(name:name,index:index,ip:ip)
    return active ? .active(bridge):.inactive(bridge)
  }
  throw Failure("Bridge IPv4 unavailable; no fallback")
}

func bridgeLinkStatus(_ name:String)throws->BridgeLinkStatus {
  let process=Process(),pipe=Pipe()
  process.executableURL=URL(fileURLWithPath:"/sbin/ifconfig");process.arguments=[name]
  process.standardOutput=pipe;process.standardError=FileHandle.nullDevice
  try process.run()
  let data=pipe.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
  guard process.terminationStatus==0,data.count<65536,let text=String(data:data,encoding:.utf8) else{throw Failure("Cannot verify bridge membership")}
  return try verifiedBridgeLinkStatus(name,text:text)
}

/// A reset/ready exchange runs in the existing ordered, authenticated stream.
/// Old bytes are consumed but never injected until a fresh matching ready is
/// received. No encrypted frame or sequence number is skipped or replayed.
struct BridgeInputRecovery {
  private(set) var deadline:Double?
  private(set) var request:String?
  private(set) var peerRequest:String?
  private(set) var needsRequest=false
  private(set) var proofReady=false
  var suspended:Bool {deadline != nil}
  func valid(now:Double)->Bool {now.isFinite && now>=0 && (deadline.map{now >= $0-4 && now<$0} ?? true)}
  mutating func begin(local:Bool,now:Double) {
    if deadline==nil {deadline=now+4}
    proofReady=false
    if local {needsRequest=true}
  }
  mutating func receiveRequest(_ token:String,now:Double) {begin(local:false,now:now);peerRequest=token}
  mutating func proveActive() {proofReady=true}
  mutating func makeRequest()->String? {
    guard proofReady,needsRequest,request==nil else{return nil}
    let token=UUID().uuidString;request=token;return token
  }
  mutating func takeReply()->String? {
    guard proofReady,let token=peerRequest else{return nil}
    peerRequest=nil;return token
  }
  mutating func acceptReply(_ token:String,now:Double)->Bool {
    guard suspended,valid(now:now),request==token else{return false}
    request=nil;needsRequest=false;return true
  }
  mutating func finishIfReady()->Bool {
    guard suspended,proofReady,!needsRequest,request==nil,peerRequest==nil else{return false}
    deadline=nil;proofReady=false;return true
  }
  static func validEnvelope(_ wire:Wire)->Bool {
    guard ["linkReset","linkReady","inputLease"].contains(wire.kind),let token=wire.token,UUID(uuidString:token)?.uuidString==token,
      let data=try? JSONEncoder().encode(wire),data.count<=256,
      let json=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else{return false}
    return Set(json.keys)==Set(["kind","session","sequence","token"])
  }
}

/// Receiver-issued freshness uses only the receiver's monotonic clock. It
/// bounds queued input even when only the source observed the cable flap.
struct BridgeInputLease {
  static let inputKinds:Set<String>=["event","dock","appGesture","begin","commit"]
  private var issued:[(token:String,time:Double)]=[]
  private(set) var latest:String?
  private(set) var receivedAt:Double?
  mutating func issue(now:Double)->String {
    let token=UUID().uuidString
    issued.removeAll{now-$0.time>0.35}
    issued.append((token,now));if issued.count>8 {issued.removeFirst(issued.count-8)}
    return token
  }
  mutating func receive(_ token:String,now:Double) {latest=token;receivedAt=now}
  func sourceFresh(now:Double)->Bool {
    guard let time=receivedAt else{return false}
    return now.isFinite && now>=time && now-time<=0.35
  }
  func accepts(_ token:String?,now:Double)->Bool {
    guard let token,now.isFinite,let issued=issued.first(where:{$0.token==token}) else{return false}
    return now>=issued.time && now-issued.time<=0.35
  }
}
