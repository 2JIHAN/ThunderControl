import Foundation
import CryptoKit

func runImageClipboardWireTests()->Int {
  var failures=0,checks=0
  func check(_ value:Bool,_ label:String){checks+=1;if !value{failures+=1;print("FAIL image clipboard wire: \(label)")}}
  check(ImageClipboardWirePolicy.isolatedSharingSupported(codec:1,isolation:1),"fixed peers enable image sharing")
  check(!ImageClipboardWirePolicy.isolatedSharingSupported(codec:1,isolation:nil),"0.9.6 images remain disabled without breaking wire acceptance")
  check(!ImageClipboardWirePolicy.isolatedSharingSupported(codec:nil,isolation:nil),"older peers remain disabled")
  let session=UUID().uuidString,epoch=UUID().uuidString
  let consent=ImageClipboardPacket(op:.consent,epoch:epoch,enabled:true)
  let wire=Wire(kind:"imageClipboard",session:session,sequence:1,imageClipboard:consent)
  check(ImageClipboardWirePolicy.validEnvelope(wire),"minimal consent envelope")
  for sender in [true,false] {
    var accepted=PeerValidator(senderPeer:sender,session:session,imageClipboardSupported:true)
    do{try accepted.accept(wire);check(accepted.next==2,"both directions consume exact sequence")}catch{check(false,"both roles accept negotiated image control")}
    var old=PeerValidator(senderPeer:sender,session:session)
    do{try old.accept(wire);check(false,"old peer denied")}catch{check(old.next==1,"old peer rejects without sequence advance")}
  }
  var extra=wire;extra.token=UUID().uuidString
  check(!ImageClipboardWirePolicy.validEnvelope(extra),"no input ownership token piggyback")
  extra=wire;extra.data=Data([1]);check(!ImageClipboardWirePolicy.validEnvelope(extra),"no opaque input piggyback")
  extra=wire;extra.imageClipboardCodec=1;check(!ImageClipboardWirePolicy.validEnvelope(extra),"hello capability not on image data")
  extra=wire;extra.folderTransferCodec=1;check(!ImageClipboardWirePolicy.validEnvelope(extra),"folder hello capability not on image data")
  // folderTransferCodec is a hello-only capability, separate from fileTransferCodec.
  var hello=Wire(kind:"hello",session:session,sequence:0);hello.fileTransferCodec=1;hello.folderTransferCodec=1
  do{var v=Validator();try v.accept(hello);check(true,"folder hello codec 1 accepted")}catch{check(false,"folder hello codec 1 accepted")}
  var unknown=hello;unknown.folderTransferCodec=2
  do{var v=Validator();try v.accept(unknown);check(false,"unknown folder codec rejected")}catch{check(true,"unknown folder codec rejected")}
  var event=Wire(kind:"event",session:session,sequence:1);event.folderTransferCodec=1
  do{var v=Validator();try v.accept(hello);try v.accept(event);check(false,"folder codec on event rejected")}catch{check(true,"folder codec on event rejected")}
  var peerEvent=Wire(kind:"ping",session:session,sequence:1);peerEvent.folderTransferCodec=1
  var peerValidator=PeerValidator(senderPeer:true,session:session)
  do{try peerValidator.accept(peerEvent);check(false,"folder codec on peer event rejected")}catch{check(peerValidator.next==1,"folder codec on peer event rejected")}
  extra=wire;extra.kind="ping"
  do{var v=PeerValidator(senderPeer:true,session:session,imageClipboardSupported:true);try v.accept(extra);check(false,"image on other kind denied")}catch{check(true,"image on other kind denied")}
  let chunk=ImageClipboardPacket(op:.chunk,epoch:epoch,peerEpoch:UUID().uuidString,id:UUID().uuidString,offset:0,totalBytes:32768,bytes:Data(repeating:0,count:32768))
  let payload=Wire(kind:"imageClipboard",session:session,sequence:1,imageClipboard:chunk)
  let key=SymmetricKey(size:.bits256)
  do{let encrypted=try seal(payload,key);check(encrypted.count<128*1024,"maximum chunk below unchanged frame cap");let decoded=try unseal(encrypted,key);check(decoded.imageClipboard==chunk,"encrypted packet roundtrip")}
  catch{check(false,"encrypted image frame roundtrip")}
  print("Image clipboard wire: \(checks) checks, \(failures) failures; encrypted memory only")
  return failures
}
