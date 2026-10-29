import AppKit

func runMouseMotionPreservationTests() -> Int {
  var failures=0
  func check(_ ok:Bool,_ name:String){if !ok{failures+=1;print("FAIL mouse motion: \(name)")}}
  for raw:UInt32 in [5,6,7,27] {
    let button:UInt32 = raw==7 ? 1 : raw==27 ? 2 : 0
    let original=CGEvent(mouseEventSource:nil,mouseType:CGEventType(rawValue:raw)!,mouseCursorPosition:CGPoint(x:900,y:700),mouseButton:CGMouseButton(rawValue:button)!)!
    original.setDoubleValueField(.mouseEventDeltaX,value:120)
    original.setDoubleValueField(.mouseEventDeltaY,value:-40)
    original.flags=[.maskShift]
    guard let output=destinationMouseEvent(original,type:raw,point:CGPoint(x:10.5,y:20.5)) else{check(false,"type \(raw) construction");continue}
    check(output.location==CGPoint(x:10.5,y:20.5),"type \(raw) destination")
    check(output.getDoubleValueField(.mouseEventDeltaX)==120 && output.getDoubleValueField(.mouseEventDeltaY)==(-40),"type \(raw) original relative movement survives")
    check(output.flags==original.flags,"type \(raw) flags")
    check(original.location==CGPoint(x:900,y:700) && original.getDoubleValueField(.mouseEventDeltaX)==120,"type \(raw) original unchanged")
    original.setDoubleValueField(.mouseEventDeltaX,value:4_000_001)
    check(destinationMouseEvent(original,type:raw,point:CGPoint(x:10,y:20))==nil,"type \(raw) excessive movement rejected")
  }
  for raw:UInt32 in [1,2,3,4,25,26] {
    let button:UInt32 = [3,4].contains(raw) ? 1 : [25,26].contains(raw) ? 2 : 0
    let original=CGEvent(mouseEventSource:nil,mouseType:CGEventType(rawValue:raw)!,mouseCursorPosition:CGPoint(x:90,y:70),mouseButton:CGMouseButton(rawValue:button)!)!
    original.setDoubleValueField(.mouseEventDeltaX,value:99)
    let output=destinationMouseEvent(original,type:raw,point:CGPoint(x:10,y:20))!
    check(output.getDoubleValueField(.mouseEventDeltaX)==0 && output.getDoubleValueField(.mouseEventDeltaY)==0,"button type \(raw) has no phantom movement")
  }
  print("Mouse motion preservation: \(failures) failures; memory only, no event posting")
  return failures
}
