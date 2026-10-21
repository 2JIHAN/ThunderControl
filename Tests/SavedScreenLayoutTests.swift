import Foundation
import CoreGraphics
func runSavedScreenLayoutTests()->Int {
  var failures=0,checks=0
  func check(_ v:Bool){checks+=1;if !v{failures+=1;print("FAIL saved screen layout check \(checks)")}}
  let suite="ThunderControl.SavedScreenLayoutTests."+UUID().uuidString
  let defaults=UserDefaults(suiteName:suite)!
  defer{defaults.removePersistentDomain(forName:suite)}
  let local=UUID().uuidString,a=UUID().uuidString,b=UUID().uuidString
  let pairA=LayoutDevicePair(localID:local,peerID:a)!,pairB=LayoutDevicePair(localID:local,peerID:b)!
  let otherLocal=LayoutDevicePair(localID:b,peerID:a)!,store=SavedScreenLayoutStore(defaults:defaults)
  let source=CGSize(width:2560,height:1600),remote=CGSize(width:1920,height:1080)
  let layout=ScreenArrangement(sourceSize:source,remoteSize:remote,remoteOnRight:false,offsetY:250)
  check(LayoutDevicePair(localID:local,peerID:local)==nil)
  check(LayoutDevicePair(localID:"not-an-identity",peerID:a)==nil)
  check(store.restored(for:pairA,sourceSize:source,remoteSize:remote)==nil)
  check(store.save(layout,for:pairA))
  check(SavedScreenLayoutStore(defaults:defaults).restored(for:pairA,sourceSize:source,remoteSize:remote)==layout)
  check(store.restored(for:pairB,sourceSize:source,remoteSize:remote)==nil)
  check(store.restored(for:otherLocal,sourceSize:source,remoteSize:remote)==nil)
  let layoutB=ScreenArrangement(sourceSize:source,remoteSize:remote,remoteOnRight:true,offsetY:-500)
  check(store.save(layoutB,for:pairB))
  check(store.restored(for:pairA,sourceSize:source,remoteSize:remote)==layout)
  check(store.restored(for:pairB,sourceSize:source,remoteSize:remote)==layoutB)
  var thin=layout;thin.offsetY=1599
  check(store.save(thin,for:pairA))
  check(store.restored(for:pairA,sourceSize:source,remoteSize:remote)==thin)
  check(store.save(layout,for:pairA))
  var invalid=layout;invalid.offsetY=2000;check(!store.save(invalid,for:pairA))
  invalid.offsetY = .nan;check(!store.save(invalid,for:pairA))
  check(store.restored(for:pairA,sourceSize:source,remoteSize:remote)==layout)
  let tall=ScreenArrangement(sourceSize:CGSize(width:2000,height:5000),remoteSize:remote,remoteOnRight:false,offsetY:4000)
  check(store.save(tall,for:pairA))
  let shrunk=store.restored(for:pairA,sourceSize:CGSize(width:1440,height:900),remoteSize:remote)
  check(shrunk?.remoteOnRight==false && shrunk?.offsetY==836 && shrunk?.isValid==true)
  check(store.restored(for:pairA,sourceSize:tall.sourceSize,remoteSize:remote)==tall)
  check(store.restored(for:pairA,sourceSize:CGSize(width:1,height:1),remoteSize:remote)==nil)
  for n in 0..<SavedScreenLayoutStore.maximumRecords+1 {
    let p=LayoutDevicePair(localID:local,peerID:UUID().uuidString)!
    check(store.save(layout,for:p));_ = n
  }
  check(store.restored(for:pairA,sourceSize:source,remoteSize:remote)==nil)
  defaults.set(Data("not json".utf8),forKey:SavedScreenLayoutStore.key)
  check(store.restored(for:pairA,sourceSize:source,remoteSize:remote)==nil)
  defaults.set(Data(repeating:0,count:SavedScreenLayoutStore.maximumBytes+1),forKey:SavedScreenLayoutStore.key)
  check(store.restored(for:pairA,sourceSize:source,remoteSize:remote)==nil)
  defaults.set(Data("{\"version\":2,\"records\":[]}".utf8),forKey:SavedScreenLayoutStore.key)
  check(store.restored(for:pairA,sourceSize:source,remoteSize:remote)==nil)
  check(store.save(layout,for:pairA))
  check(store.restored(for:pairA,sourceSize:source,remoteSize:remote)==layout)
  print("Saved device-pair screen layouts: \(checks) checks, \(failures) failures; no secrets or input data stored")
  return failures
}
