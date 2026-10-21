import Foundation
func runDisplayHeartbeatTests()->Int {
  var failures=0,checks=0
  func check(_ b:Bool){checks+=1;if !b{failures+=1}}
  func reject(_ f:()throws->Void){do{try f();check(false)}catch{check(true)}}
  var state=DisplayHeartbeatState()
  let first=state.next(now:10);check(first.token==1 && !first.expired)
  check(state.next(now:11).token==nil)
  check(state.accept(token:99,now:11.1)==nil)
  check(state.accept(token:1,now:11.2).map{abs($0-1200)<0.001} ?? false)
  check(state.accept(token:1,now:11.3)==nil)
  let second=state.next(now:12);check(second.token==2 && !second.expired)
  check(state.next(now:17.99).token==nil)
  let third=state.next(now:18);check(third.token==3 && third.expired)
  check(state.accept(token:2,now:18.1)==nil)
  check(state.accept(token:3,now:17.9)==nil)
  check(state.accept(token:3,now:Double.nan)==nil)
  check(state.accept(token:3,now:18.01).map{abs($0-10)<0.001} ?? false)
  for token:UInt64 in [1,0x12345678,UInt64.max] {for reply in [false,true]{do{let packet=DisplayHeartbeatState.packet(token:token,reply:reply);let parsed=try DisplayHeartbeatState.parse(packet);check(parsed.token==token && parsed.reply==reply);for n in 0..<10{reject{_ = try DisplayHeartbeatState.parse(Data(packet.prefix(n)))}};reject{_ = try DisplayHeartbeatState.parse(packet+Data([0]))}}catch{check(false)}}}
  reject{_ = try DisplayHeartbeatState.parse(Data([0,3])+Data(repeating:1,count:8))}
  reject{_ = try DisplayHeartbeatState.parse(DisplayHeartbeatState.packet(token:0,reply:false))}
  print("Display heartbeat: \(checks) checks failures=\(failures); delayed replies, expiry and strict framing, no sockets")
  return failures
}
