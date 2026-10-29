import AppKit
import IOKit

func runHIDMouseMotionTests() -> Int {
  var failures=0
  func check(_ ok:Bool,_ name:String) { if !ok { failures+=1;print("FAIL HID motion: \(name)") } }
  func prepare(_ type:UInt32=5,_ x:Double=10.25,_ y:Double = -20.5,
               _ dx:Double=120,_ dy:Double = -40) -> MotionPreparation {
    MotionPlan.make(type:type,location:CGPoint(x:x,y:y),dx:dx,dy:dy,
                    flags:CGEventFlags.maskShift.rawValue,budget:4_000_000)
  }
  for type:UInt32 in [5,6,7] {
    guard case .motion(let p)=prepare(type) else { check(false,"motion type \(type)");continue }
    check(p.type==type && p.location==CGPoint(x:10.25,y:-20.5),"authoritative position")
    check(p.point.x==10 && p.point.y == -21 && p.subx==64 && p.suby==128,"floor fractional position")
    let data=p.payload
    check(data.mouseMove.dx==120 && data.mouseMove.dy == -40 && data.mouseMove.subx==64 && data.mouseMove.suby==128,"payload")
    check(p.flags==UInt32(CGEventFlags.maskShift.rawValue)|0x100,"flags preserved")
  }
  for type:UInt32 in [1,2,3,4,10,11,12,22,25,26,27] {
    if case .useCG=prepare(type) {} else { check(false,"nonmotion uses CG") }
  }
  for position in [32768.0,-32768.5] {
    if case .useCG=prepare(5,position) {} else { check(false,"Int16 fallback") }
  }
  if case .useCG=prepare(5,10,20,0.5) {} else {check(false,"fractional delta retains CG path")}
  for invalid in [Double.nan,Double.infinity,4_000_001,Double(Int32.max)+1] {
    if case .failed=prepare(5,10,20,invalid) {} else { check(false,"invalid delta rejected") }
  }
  if case .failed=prepare(5,Double.nan) {} else { check(false,"invalid position rejected") }
  if case .motion(let p)=prepare(5,-0.25,0.75,-9,8) {
    check(p.point.x == -1 && p.point.y==0 && p.subx==192 && p.suby==192,"signed fraction")
    check(p.dx == -9 && p.dy==8,"signed deltas")
  } else {check(false,"signed plan")}
  var allowed=true,opens=0,posts=0,closes=0,gates=0
  var openResult:Int32=0,postResult:Int32=0
  var afterOpen:()->Void = {}
  let api=HIDMotionAPI(permissionCheck:{allowed},open:{
    opens+=1;afterOpen();return (openResult,openResult==0 ? 42:0)
  },post:{_,_ in posts+=1;return postResult},close:{_ in closes+=1})
  let poster=HIDMouseMotionPoster(api:api)
  allowed=false
  check(poster.post(prepare(),canPost:{true}) == .failed(Int32(kIOReturnNotPermitted)),"denied")
  check(opens==0 && posts==0,"denied does not open or post")
  allowed=true;openResult = -7
  check(poster.post(prepare(),canPost:{true}) == .failed(-7),"open failure")
  check(posts==0,"open failure no post")
  openResult=0;var fresh=true;afterOpen={fresh=false}
  check(poster.post(prepare(),canPost:{gates+=1;return fresh}) == .cancelled,"fresh gate after open")
  check(posts==0 && gates==1,"cancelled no post")
  postResult = -8
  check(poster.post(prepare(),canPost:{true}) == .failed(-8),"post failure")
  check(posts==1,"failed post never duplicated")
  postResult=0
  check(poster.post(prepare(),canPost:{true}) == .posted,"success")
  check(posts==2 && opens==2,"one post, reused connection")
  check(poster.post(prepare(1),canPost:{preconditionFailure("CG gate belongs to caller")}) == .useCG,"click fallback")
  check(posts==2,"fallback never posts HID")
  allowed=false
  check(poster.post(prepare(),canPost:{true}) == .failed(Int32(kIOReturnNotPermitted)),"recheck access")
  check(posts==2,"revoked no post")
  poster.close();poster.close();check(closes==1,"idempotent close")
  print("HID motion: \(failures) failures; fake API only, no real input posting")
  return failures
}
