import Foundation
import CoreGraphics

@discardableResult func runSavedDesktopPlacementTests()->Int {
    var failures=0,checks=0
    func check(_ ok:Bool){checks+=1;if !ok{failures+=1}}
    let suite="ThunderControl.tests.source-placement."+UUID().uuidString
    let defaults=UserDefaults(suiteName:suite)!
    defer{defaults.removePersistentDomain(forName:suite)}
    let store=SavedDesktopPlacementStore(defaults:defaults)
    let pair=LayoutDevicePair(localID:UUID().uuidString,peerID:UUID().uuidString)!
    let other=LayoutDevicePair(localID:UUID().uuidString,peerID:UUID().uuidString)!
    let stable=UUID().uuidString
    let size=CGSize(width:800,height:600)
    let main=ReceiverDisplay(id:1,bounds:CGRect(x:0,y:0,width:1000,height:900),stableIdentity:stable)
    let map=ReceiverDesktop(revision:1,mainID:1,displays:[main])
    let migratedPair=LayoutDevicePair(localID:UUID().uuidString,peerID:UUID().uuidString)!
    let legacyStore=SavedScreenLayoutStore(defaults:defaults)
    check(legacyStore.save(ScreenArrangement(sourceSize:size,remoteSize:main.bounds.size,remoteOnRight:true,offsetY:200),for:migratedPair))
    let oldData=defaults.data(forKey:SavedScreenLayoutStore.key)
    check(store.restored(for:migratedPair,sourceSize:size,desktop:map)==CGPoint(x:-800,y:-200))
    check(defaults.data(forKey:SavedScreenLayoutStore.key)==oldData)
    check(defaults.data(forKey:SavedDesktopPlacementStore.key)==nil)
    for origin in [CGPoint(x:-800,y:100),CGPoint(x:1000,y:100),CGPoint(x:100,y:-600),CGPoint(x:100,y:900)] {
        check(store.save(origin:origin,sourceSize:size,desktop:map,for:pair))
        check(store.restored(for:pair,sourceSize:size,desktop:map)==origin)
        check(store.restored(for:other,sourceSize:size,desktop:map)==nil)
        let shifted=ReceiverDesktop(revision:2,mainID:9,displays:[ReceiverDisplay(id:9,bounds:CGRect(x:-1200,y:500,width:1000,height:900),stableIdentity:stable)])
        check(store.restored(for:pair,sourceSize:size,desktop:shifted)==CGPoint(x:origin.x-1200,y:origin.y+500))
    }
    check(!store.save(origin:.zero,sourceSize:size,desktop:map,for:pair))
    check(!store.save(origin:CGPoint(x:CGFloat.nan,y:0),sourceSize:size,desktop:map,for:pair))
    check(!store.save(origin:CGPoint(x:2000,y:0),sourceSize:size,desktop:map,for:pair))
    check(store.save(origin:CGPoint(x:1000,y:100),sourceSize:size,desktop:map,for:pair))
    let obstructed=ReceiverDesktop(revision:3,mainID:1,displays:[main,ReceiverDisplay(id:2,bounds:CGRect(x:1000,y:0,width:1000,height:900))])
    let before=defaults.data(forKey:SavedDesktopPlacementStore.key)
    if let restored=store.restored(for:pair,sourceSize:size,desktop:obstructed) {
        check(!obstructed.portals(sourceRect:CGRect(origin:restored,size:size)).isEmpty)
    }else{check(false)}
    check(defaults.data(forKey:SavedDesktopPlacementStore.key)==before)
    check(store.restored(for:pair,sourceSize:size,desktop:map)==CGPoint(x:1000,y:100))
    let newPhysical=ReceiverDesktop(revision:4,mainID:1,displays:[ReceiverDisplay(id:1,bounds:CGRect(x:0,y:0,width:1200,height:900),stableIdentity:UUID().uuidString)])
    check(store.restored(for:pair,sourceSize:size,desktop:newPhysical)==CGPoint(x:1200,y:100))
    let virtualMap=ReceiverDesktop(revision:5,mainID:1,displays:[main,ReceiverDisplay(id:2,bounds:CGRect(x:1000,y:0,width:1000,height:900),stableIdentity:UUID().uuidString)],virtualDisplayID:2)
    check(store.save(origin:CGPoint(x:2000,y:100),sourceSize:size,desktop:virtualMap,for:pair))
    let recreated=ReceiverDesktop(revision:6,mainID:1,displays:[main,ReceiverDisplay(id:7,bounds:CGRect(x:1500,y:0,width:1000,height:900),stableIdentity:UUID().uuidString)],virtualDisplayID:7)
    check(store.restored(for:pair,sourceSize:size,desktop:recreated)==CGPoint(x:2500,y:100))
    defaults.set(Data("invalid".utf8),forKey:SavedDesktopPlacementStore.key)
    check(store.restored(for:pair,sourceSize:size,desktop:map)==nil)
    defaults.set(Data(repeating:0,count:SavedDesktopPlacementStore.maximumBytes+1),forKey:SavedDesktopPlacementStore.key)
    check(store.restored(for:pair,sourceSize:size,desktop:map)==nil)
    print("Saved source placement: \(checks) checks failures=\(failures); isolated test preferences, no receiver setting changes")
    return failures
}
