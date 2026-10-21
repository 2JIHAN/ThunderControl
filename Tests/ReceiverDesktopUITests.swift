import AppKit

/// Events are sent directly to this local view, never posted to the OS.
@MainActor @discardableResult func runReceiverDesktopUITests()->Int {
    var failures=0,checks=0
    func check(_ ok:Bool,_ name:String){checks+=1;if !ok {failures+=1;print("FAIL desktop UI: "+name)}}
    let map=ReceiverDesktop(revision:1,mainID:1,displays:[
        ReceiverDisplay(id:1,bounds:CGRect(x:0,y:0,width:1000,height:800)),
        ReceiverDisplay(id:2,bounds:CGRect(x:1000,y:200,width:1000,height:800))],virtualDisplayID:2)
    let view=ScreenArrangementView(frame:CGRect(x:0,y:0,width:800,height:400))
    view.receiverDesktop=map;view.sourceSize=CGSize(width:1000,height:800);view.sourceOrigin=CGPoint(x:-1000,y:0)
    func event(_ type:NSEvent.EventType,_ point:CGPoint)->NSEvent {
        NSEvent.mouseEvent(with:type,location:view.convert(point,to:nil),modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:0)!
    }
    func center(_ rect:CGRect)->CGPoint{CGPoint(x:rect.midX,y:rect.midY)}
    var calls=0
    view.onSourceOriginChanged={point in calls+=1;view.sourceOrigin=point}
    for display in map.displays {
        guard let frame=view.desktopReceiverFrame(id:display.id) else{check(false,"receiver frame missing");continue}
        view.mouseDown(with:event(.leftMouseDown,center(frame)))
        view.mouseDragged(with:event(.leftMouseDragged,CGPoint(x:frame.midX+150,y:frame.midY+80)))
        view.mouseUp(with:event(.leftMouseUp,center(frame)))
    }
    check(calls==0,"receiver screens are not draggable")
    check(view.receiverDesktop==map,"receiver map remains unchanged")
    let initial=view.sourceOrigin!
    if let frame=view.desktopSourceFrame() {
        let scale=frame.width/view.sourceSize.width,start=center(frame)
        view.mouseDown(with:event(.leftMouseDown,start))
        view.mouseDragged(with:event(.leftMouseDragged,CGPoint(x:start.x+3000*scale,y:start.y+200*scale)))
        check(calls==1,"source drag proposes one placement")
        check(view.sourceOrigin != initial,"owner can accept source-only drag")
        check(!map.portals(sourceRect:CGRect(origin:view.sourceOrigin!,size:view.sourceSize)).isEmpty,"accepted position has a real portal")
        check(view.receiverDesktop==map,"source drag never rewrites receiver map")
        view.mouseUp(with:event(.leftMouseUp,start))
    } else {check(false,"source frame missing")}
    let accepted=view.sourceOrigin!
    view.onSourceOriginChanged={_ in calls+=1}
    if let frame=view.desktopSourceFrame() {
        let start=center(frame)
        view.mouseDown(with:event(.leftMouseDown,start))
        view.mouseDragged(with:event(.leftMouseDragged,CGPoint(x:start.x,y:start.y-150)))
        check(view.sourceOrigin==accepted,"rejected placement leaves accepted view intact")
        let prior=calls
        var revised=map;revised.revision=2;view.receiverDesktop=revised
        view.mouseDragged(with:event(.leftMouseDragged,CGPoint(x:start.x-100,y:start.y)))
        check(calls==prior,"map revision cancels an in-progress drag")
        view.mouseUp(with:event(.leftMouseUp,start))
    }
    if let frame=view.desktopSourceFrame() {
        let start=center(frame),prior=calls
        view.mouseDown(with:event(.leftMouseDown,start));view.isInteractionEnabled=false
        view.mouseDragged(with:event(.leftMouseDragged,CGPoint(x:start.x-150,y:start.y)))
        check(calls==prior,"disabled edit cancels drag")
        view.isInteractionEnabled=true
        view.mouseDown(with:event(.leftMouseDown,start));view.sourceSize=CGSize(width:900,height:800)
        view.mouseDragged(with:event(.leftMouseDragged,CGPoint(x:start.x-150,y:start.y)))
        check(calls==prior,"source geometry change cancels drag")
    }
    check(view.receiverDesktop?.displays==map.displays,"all tests preserve native receiver geometry")
    print("Receiver desktop source-only UI: \(checks) checks failures=\(failures); local synthetic view events only, no posting/network/settings")
    return failures
}
