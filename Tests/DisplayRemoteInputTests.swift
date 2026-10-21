import Foundation
import CoreGraphics

func runDisplayRemoteInputTests()->Int {
  var failures=0,checks=0
  func check(_ value:Bool){checks+=1;if !value{failures+=1}}
  func reject(_ work:()throws->Void){do{try work();check(false)}catch{check(true)}}
  let packets:[DisplayInputPacket]=[
    .init(kind:.move,x:0,y:65535),.init(kind:.buttonDown,code:2,detail:3),.init(kind:.buttonUp,code:0,detail:1),
    .init(kind:.keyDown,code:0),.init(kind:.keyDown,code:127,detail:1),.init(kind:.keyUp,code:127),
    .init(kind:.modifier,code:56,detail:1),.init(kind:.scroll,sx:-4096,sy:4096)]
  for p in packets{do{let d=try p.encoded();check(d.count==36);check(try DisplayInputPacket(data:d)==p)}catch{check(false)}}
  do{let d=try packets[0].encoded();for n in 0..<36{reject{_ = try DisplayInputPacket(data:Data(d.prefix(n)))}}
    reject{_ = try DisplayInputPacket(data:d+Data([0]))}
    for index in [0,1,2,3,6,7]{var bad=d;bad[index]=255;reject{_ = try DisplayInputPacket(data:bad)}}
  }catch{check(false)}
  for p in [DisplayInputPacket(kind:.move,x:65536),.init(kind:.move,y:65536),.init(kind:.move,flags:UInt64.max),.init(kind:.keyDown,code:128),.init(kind:.keyDown,code:55),.init(kind:.keyDown,detail:2),.init(kind:.keyUp,detail:1),.init(kind:.buttonDown,code:3,detail:1),.init(kind:.buttonUp,detail:0),.init(kind:.modifier,code:1),.init(kind:.modifier,code:55,detail:2),.init(kind:.scroll,sx:Int32.min),.init(kind:.scroll,sy:4097)]{reject{_ = try p.encoded()}}
  var own=DisplayInputOwnership()
  reject{try own.accept(.init(kind:.keyUp,code:0))}
  reject{try own.accept(.init(kind:.keyDown,code:0,detail:1))}
  do{
    try own.accept(.init(kind:.keyDown,code:0));check(own.keys==[0]);reject{try own.accept(.init(kind:.keyDown,code:0))}
    try own.accept(.init(kind:.keyDown,code:0,detail:1));check(own.keys==[0]);try own.accept(.init(kind:.keyUp,code:0));check(own.keys.isEmpty)
    try own.accept(.init(kind:.modifier,code:55,detail:1));check(own.keys==[55]);reject{try own.accept(.init(kind:.modifier,code:55,detail:1))};try own.accept(.init(kind:.modifier,code:55));check(own.keys.isEmpty)
    try own.accept(.init(kind:.buttonDown,code:0,detail:1));reject{try own.accept(.init(kind:.buttonDown,code:0,detail:1))};try own.accept(.init(kind:.buttonUp,code:0,detail:1));check(own.buttons.isEmpty)
  }catch{check(false)}
  reject{try own.accept(.init(kind:.buttonUp,code:0,detail:1))}
  // Flags on movement, scrolling and buttons cannot assert unowned modifiers.
  var flagOwner=DisplayInputOwnership()
  for kind in [DisplayInputPacket.Kind.move,.scroll,.buttonDown] {
    do{let detail:UInt32=kind == .buttonDown ? 1:0;try flagOwner.accept(.init(kind:kind,flags:DisplayInputPacket.flagMask,detail:detail));check(flagOwner.heldFlags.isEmpty)}catch{check(false)}
  }
  do {
    try flagOwner.accept(.init(kind:.modifier,code:55,detail:1))
    check(flagOwner.heldFlags.contains(.maskCommand));check(!flagOwner.heldFlags.contains(.maskShift))
    try flagOwner.accept(.init(kind:.modifier,code:54,detail:1))
    check(flagOwner.heldFlags.rawValue & 0x18 == 0x18)
    try flagOwner.accept(.init(kind:.modifier,code:55))
    check(flagOwner.heldFlags.contains(.maskCommand));check(flagOwner.heldFlags.rawValue & 0x18 == 0x10)
    try flagOwner.accept(.init(kind:.modifier,code:54))
    check(flagOwner.heldFlags.isEmpty)
  }catch{check(false)}
  for code:UInt16 in [48,49,12,53] {check(!displayInputKeyPermitted(code,flags:.maskCommand))}
  for code:UInt16 in [49,120,99,123,124,125,126] {check(!displayInputKeyPermitted(code,flags:.maskControl))}
  check(!displayInputKeyPermitted(12,flags:[.maskCommand,.maskControl]))
  check(!displayInputKeyPermitted(12,flags:[.maskCommand,.maskShift]))
  for code:UInt16 in [0,1,3,6,7,8,9,13,17,45] {check(displayInputKeyPermitted(code,flags:.maskCommand))}
  check(displayInputKeyPermitted(0,flags:[]));check(displayInputKeyPermitted(123,flags:[]))
  for code:UInt16 in [72,73,74,127]{check(!displayInputKeyPermitted(code,flags:[]))}
  do {
    let release=DisplayInputPacket(kind:.releaseAll)
    check(try DisplayInputPacket(data:release.encoded()) == release)
    check(try displayInputSafeBeforeTarget(release.encoded()))
    check(try !displayInputSafeBeforeTarget(DisplayInputPacket(kind:.keyDown,code:0).encoded()))
    reject{_ = try displayInputSafeBeforeTarget(Data([4,1,8]))}
    var owned=DisplayInputOwnership();try owned.accept(.init(kind:.keyDown,code:0));try owned.accept(.init(kind:.buttonDown,code:0,detail:1));try owned.accept(release);check(owned.keys.isEmpty && owned.buttons.isEmpty)
    var invalid=release;invalid.flags=CGEventFlags.maskCommand.rawValue;reject{try invalid.validate()}
    var queue=DisplayInputPendingBuffer()
    for n in 0..<1000 {check(queue.push(try DisplayInputPacket(kind:.move,x:UInt32(n)).encoded(),now:Double(n)))}
    check(queue.items.count==1);check(try DisplayInputPacket(data:queue.items[0].data).x==999)
    check(queue.push(try DisplayInputPacket(kind:.buttonDown,detail:1).encoded(),now:1001))
    check(queue.push(try DisplayInputPacket(kind:.move,x:123).encoded(),now:1002));check(queue.items.count==3)
    check(queue.push(try release.encoded(),now:1003,reset:true));check(queue.items.count==1);check(try DisplayInputPacket(data:queue.pop()!.data).kind == .releaseAll)
    for n in 0..<32 {check(queue.push(try DisplayInputPacket(kind:.keyDown,code:UInt16(n)).encoded(),now:0))}
    check(!queue.push(try DisplayInputPacket(kind:.keyUp,code:0).encoded(),now:0))
  }catch{check(false)}
  print("Display remote input protocol/ownership checks=\(checks) failures=\(failures); no capture or posting")
  return failures
}
