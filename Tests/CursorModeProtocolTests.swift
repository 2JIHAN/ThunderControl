import Foundation
import CryptoKit
func runCursorModeProtocolTests()->Int {
  var failed=0
  func check(_ b:Bool){if !b {failed+=1}}
  let session=UUID().uuidString
  let first=Wire(kind:"cursorMode",session:session,sequence:1,cursorMode:true)
  do {let key=SymmetricKey(size:.bits256);let decoded=try unseal(seal(first,key),key);check(decoded.kind=="cursorMode" && decoded.cursorMode==true && decoded.session==session && decoded.sequence==1)}catch{failed+=1}
  var peer=PeerValidator(senderPeer:true,session:session,cursorVisibilitySupported:true)
  do {try peer.accept(first);check(peer.next==2);try peer.accept(Wire(kind:"cursorMode",session:session,sequence:2,cursorMode:false));check(peer.next==3)}catch{failed+=1}
  do {try peer.accept(first);failed+=1}catch{check(peer.next==3)}
  func rejected(_ packet:Wire,sender:Bool=true,supported:Bool=true)->Bool {
    var p=PeerValidator(senderPeer:sender,session:session,cursorVisibilitySupported:supported)
    do {try p.accept(packet);return false}catch{return p.next==1}
  }
  check(rejected(first,sender:false));check(rejected(first,supported:false))
  var bad=first;bad.cursorMode=nil;check(rejected(bad))
  bad=first;bad.token=UUID().uuidString;check(rejected(bad))
  bad=first;bad.raw=5;check(rejected(bad))
  bad=first;bad.data=Data([1]);check(rejected(bad))
  bad=first;bad.layoutY=1;check(rejected(bad))
  bad=first;bad.screenWidth=100;check(rejected(bad))
  bad=first;bad.cursorVisibilityCodec=1;check(rejected(bad))
  bad=first;bad.kind="ping";check(rejected(bad))
  bad=first;bad.session=UUID().uuidString;check(rejected(bad))
  bad=first;bad.sequence=2;check(rejected(bad))
  print("CursorMode protocol authentication envelope/role/capability/replay/malformed rejection failures=\(failed); no OS calls")
  return failed
}
