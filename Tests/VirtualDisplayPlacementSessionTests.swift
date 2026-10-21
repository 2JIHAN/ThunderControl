import Foundation
import CoreGraphics

func runVirtualDisplayPlacementSessionTests() -> Int {
    let suite="ThunderControl.VirtualPlacementSession."+UUID().uuidString,defaults:UserDefaults
    defaults=UserDefaults(suiteName:suite)!
    defer{defaults.removePersistentDomain(forName:suite)}
    let store=SavedVirtualDisplayPlacementStore(defaults:defaults)
    let pair=LayoutDevicePair(localID:UUID().uuidString,peerID:UUID().uuidString)!
    let identity=UUID().uuidString
    let physical=ReceiverDisplay(id:1,bounds:CGRect(x:0,y:0,width:1200,height:900),stableIdentity:identity)
    let format=DisplayVideoFormat(width:1600,height:1000)
    func sample(_ origin:CGPoint,_ physical:ReceiverDisplay=physical)->VirtualDisplayPlacementSample {
        let owned=ReceiverDisplay(id:99,bounds:CGRect(origin:origin,size:format.size),stableIdentity:UUID().uuidString)
        return VirtualDisplayPlacementSample(desktop:ReceiverDesktop(revision:1,mainID:physical.id,displays:[physical,owned],virtualDisplayID:99),ownedID:99,format:format)!
    }
    let right=sample(CGPoint(x:1200,y:0)),left=sample(CGPoint(x:-1600,y:0)),above=sample(CGPoint(x:0,y:-1000))
    var checks=0,failures=0
    func check(_ value:Bool,_ label:String){checks+=1;if !value{failures+=1;fputs("Virtual placement session: \(label)\n",stderr)}}
    var first=VirtualDisplayPlacementSession(pair:pair,requestedOrigin:nil,hadSaved:false)
    check(!first.observe(right,now:0,store:store),"initial sample waits")
    check(!first.observe(right,now:0.5,store:store),"debounce")
    check(first.observe(right,now:1,store:store),"stable initial save")
    let saved=defaults.data(forKey:SavedVirtualDisplayPlacementStore.key)
    check(!first.observe(right,now:5,store:store),"unchanged no repeat write")
    check(defaults.data(forKey:SavedVirtualDisplayPlacementStore.key)==saved,"unchanged bytes")
    check(!first.observe(left,now:6,store:store),"user rearrange waits")
    check(first.observe(left,now:6.8,store:store),"new stable layout saved")
    check(store.restored(for:pair,size:format.size,physicalDesktop:left.physicalDesktop)==left.ownedBounds.origin,"reconnect uses new left placement")
    var missing=VirtualDisplayPlacementSession(pair:pair,requestedOrigin:nil,hadSaved:true)
    check(!missing.observe(right,now:10,store:store),"missing anchor startup ignored")
    check(!missing.observe(right,now:20,store:store,force:true),"stop cannot overwrite missing anchor intent")
    check(store.restored(for:pair,size:format.size,physicalDesktop:left.physicalDesktop)==left.ownedBounds.origin,"missing anchor prior record retained")
    check(!missing.observe(above,now:21,store:store),"new user change after fallback waits")
    check(missing.observe(above,now:22,store:store),"explicit later change updates prior record")
    var fallback=VirtualDisplayPlacementSession(pair:pair,requestedOrigin:above.ownedBounds.origin,hadSaved:true)
    check(!fallback.observe(right,now:30,store:store,force:true),"helper fallback cannot overwrite requested origin")
    var restored=VirtualDisplayPlacementSession(pair:pair,requestedOrigin:above.ownedBounds.origin,hadSaved:true)
    check(restored.observe(above,now:40,store:store,force:true),"verified requested restore can save on stop")
    check(!restored.observe(left,now:.nan,store:store,force:true),"invalid clock denied")
    let wrong=ReceiverDesktop(revision:1,mainID:1,displays:[physical,ReceiverDisplay(id:99,bounds:CGRect(x:1200,y:0,width:1920,height:1080))],virtualDisplayID:99)
    check(VirtualDisplayPlacementSample(desktop:wrong,ownedID:99,format:format)==nil,"mismatched video dimensions never saved")
    check(VirtualDisplayPlacementSample(desktop:ReceiverDesktop(revision:1,mainID:1,displays:[physical]),ownedID:99,format:format)==nil,"missing owned identity never saved")
    print("Virtual display placement lifecycle: \(checks) checks, \(failures) failures; isolated preferences, no native settings")
    return failures
}
