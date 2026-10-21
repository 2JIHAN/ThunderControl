import Foundation
import Darwin
func systemBuildIdentifier() -> String? {
  var size=0
  guard sysctlbyname("kern.osversion",nil,&size,nil,0)==0,size>1,size<64 else{return nil}
  var bytes=[CChar](repeating:0,count:size)
  guard sysctlbyname("kern.osversion",&bytes,&size,nil,0)==0 else{return nil}
  let value=String(cString:bytes)
  guard !value.isEmpty,value.utf8.count<32,value.utf8.allSatisfy({(48...57).contains($0)||(65...90).contains($0)||(97...122).contains($0)}) else{return nil}
  return value
}
struct DockTransferState {
  private(set) var id:String?
  private(set) var motion:Int?
  private(set) var started:Double=0
  var active:Bool {id != nil}
  static func valid(_ d:DockGestureDescriptor)->Bool {
    [1,2].contains(d.motion) && [1,2,4,8].contains(d.phase) && d.progress.isFinite && abs(d.progress)<=1 && d.velocityX.isFinite && abs(d.velocityX)<=10000 && d.velocityY.isFinite && abs(d.velocityY)<=10000
  }
  mutating func beginSource(_ d:DockGestureDescriptor,now:Double)->String? {
    guard Self.valid(d),now.isFinite else{return nil}
    if active && (now<started || expired(now:now)) {return nil}
    if d.phase==1 {
      guard !active else{return nil}
      id=UUID().uuidString;motion=d.motion;started=now;return id
    }
    guard let token=id,motion==d.motion else{return nil}
    if d.phase==4 || d.phase==8 {reset()}
    return token
  }
  mutating func accept(_ d:DockGestureDescriptor,id token:String,now:Double)->Bool {
    guard Self.valid(d),UUID(uuidString:token)?.uuidString==token,now.isFinite else{return false}
    if active && (now<started || expired(now:now)) {return false}
    if d.phase==1 {guard !active else{return false};id=token;motion=d.motion;started=now;return true}
    guard id==token,motion==d.motion else{return false}
    if d.phase==4 || d.phase==8 {reset()}
    return true
  }
  func expired(now:Double)->Bool {active && now-started>15}
  mutating func reset(){id=nil;motion=nil;started=0}
}
func runDockTransferStateTests()->Int {
 var failures=0
 func expect(_ b:Bool){if !b{failures+=1}}
 let begin=DockGestureDescriptor(motion:2,phase:1,progress:0,velocityX:0,velocityY:0)
 let change=DockGestureDescriptor(motion:2,phase:2,progress:0.5,velocityX:0,velocityY:1)
 let end=DockGestureDescriptor(motion:2,phase:4,progress:1,velocityX:0,velocityY:0)
 var source=DockTransferState(),target=DockTransferState()
 expect(source.beginSource(change,now:0)==nil)
 guard let token=source.beginSource(begin,now:0) else{return 1}
 expect(target.accept(begin,id:token,now:0));expect(!target.accept(begin,id:token,now:0))
 expect(!target.accept(change,id:UUID().uuidString,now:1))
 expect(source.beginSource(change,now:1)==token);expect(target.accept(change,id:token,now:1))
 expect(source.expired(now:16));expect(source.beginSource(end,now:16)==nil);expect(!target.accept(end,id:token,now:16));expect(source.beginSource(end,now:2)==token)
 expect(target.accept(end,id:token,now:2));expect(!source.active && !target.active)
 expect(!target.accept(change,id:token,now:3))
 expect(!DockTransferState.valid(.init(motion:2,phase:2,progress:.nan,velocityX:0,velocityY:0)))
 expect(!DockTransferState.valid(.init(motion:3,phase:1,progress:0,velocityX:0,velocityY:0)))
 let sample=DockGestureDescriptor(motion:2,phase:2,progress:0.4,velocityX:0.2,velocityY:1.5)
 let flipped=receiverDockProjection(sample,invertVertical:true)
 expect(flipped.progress == -0.4 && flipped.velocityY == -1.5 && flipped.velocityX==0.2 && flipped.phase==sample.phase)
 expect(receiverDockProjection(sample,invertVertical:false)==sample)
 let horizontal=DockGestureDescriptor(motion:1,phase:2,progress:0.4,velocityX:0.2,velocityY:1.5)
 expect(receiverDockProjection(horizontal,invertVertical:true)==horizontal)
 expect(receiverDockProjection(flipped,invertVertical:true)==sample)
 for phase in [1,2,4,8] {
  let h=DockGestureDescriptor(motion:1,phase:phase,progress:0.4,velocityX:1.5,velocityY:0.2)
  let r=receiverDockProjection(h,invertVertical:true,invertHorizontal:true)
  expect(r.progress == -0.4 && r.velocityX == -1.5 && r.velocityY == 0.2 && r.phase==phase && r.motion==1)
  expect(receiverDockProjection(r,invertVertical:false,invertHorizontal:true)==h)
  expect(receiverDockProjection(h,invertVertical:true,invertHorizontal:false)==h)
 }
 expect(receiverDockProjection(sample,invertVertical:true,invertHorizontal:true)==flipped)
 expect(receiverDockProjection(sample,invertVertical:false,invertHorizontal:true)==sample)
 return failures
}

func receiverDockProjection(_ input:DockGestureDescriptor,invertVertical:Bool,invertHorizontal:Bool=false)->DockGestureDescriptor {
 if input.motion==1,invertHorizontal {return .init(motion:input.motion,phase:input.phase,progress:-input.progress,velocityX:-input.velocityX,velocityY:input.velocityY)}
 guard input.motion==2,invertVertical else{return input}
 return .init(motion:input.motion,phase:input.phase,progress:-input.progress,velocityX:input.velocityX,velocityY:-input.velocityY)
}
