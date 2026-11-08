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
  // Legacy image frames stay byte-for-byte: new optional Wire fields are omitted when nil.
  let fixed=ImageClipboardPacket(op:.consent,epoch:"00000000-0000-0000-0000-000000000001",enabled:true)
  var legacyWire=Wire(kind:"imageClipboard",session:"00000000-0000-0000-0000-000000000002",sequence:7,imageClipboard:fixed)
  let legacyJSON=(try? JSONSerialization.jsonObject(with:JSONEncoder().encode(legacyWire))) as? [String:Any]
  check(Set(legacyJSON?.keys.map{$0} ?? [])==Set(["kind","session","sequence","imageClipboard"]),"legacy image envelope keys unchanged")
  check(Set((legacyJSON?["imageClipboard"] as? [String:Any])?.keys.map{$0} ?? [])==Set(["op","epoch","enabled"]),"legacy image consent has no format field")
  legacyWire.textClipboardCodec=1;check(!ImageClipboardWirePolicy.validEnvelope(legacyWire),"text hello codec not on image data")
  // Text envelope.
  let textConsent=TextClipboardPacket(ImageClipboardPacket(op:.consent,epoch:epoch,enabled:true))
  var textWire=Wire(kind:"textClipboard",session:session,sequence:1);textWire.textClipboard=textConsent
  check(TextClipboardWirePolicy.validEnvelope(textWire),"text consent envelope")
  check(!ImageClipboardWirePolicy.validEnvelope(textWire),"text envelope is not an image envelope")
  for sender in [true,false] {
    var v=PeerValidator(senderPeer:sender,session:session,imageClipboardSupported:true,textClipboardSupported:true)
    do{try v.accept(textWire);check(v.next==2,"text consumes exact sequence")}catch{check(false,"negotiated text accepted")}
    var old=PeerValidator(senderPeer:sender,session:session,imageClipboardSupported:true)
    do{try old.accept(textWire);check(false,"image-only peer rejects text")}catch{check(old.next==1,"image-only peer rejects text without sequence advance")}
  }
  var mixed=textWire;mixed.imageClipboard=consent
  check(!TextClipboardWirePolicy.validEnvelope(mixed),"mixed image+text envelope rejected")
  mixed=wire;mixed.textClipboard=textConsent
  check(!ImageClipboardWirePolicy.validEnvelope(mixed),"image envelope with text field rejected")
  mixed=textWire;mixed.kind="imageClipboard"
  do{var v=PeerValidator(senderPeer:true,session:session,imageClipboardSupported:true,textClipboardSupported:true);try v.accept(mixed);check(false,"text payload under image kind rejected")}catch{check(true,"text payload under image kind rejected")}
  mixed=wire;mixed.kind="textClipboard"
  check(!TextClipboardWirePolicy.validEnvelope(mixed),"image payload under text kind rejected")
  mixed=textWire;mixed.textClipboardCodec=1;check(!TextClipboardWirePolicy.validEnvelope(mixed),"hello codec not on text data")
  mixed=textWire;mixed.token=UUID().uuidString;check(!TextClipboardWirePolicy.validEnvelope(mixed),"no token piggyback on text")
  var ping=Wire(kind:"ping",session:session,sequence:1);ping.textClipboardCodec=1
  do{var v=PeerValidator(senderPeer:true,session:session,imageClipboardSupported:true,textClipboardSupported:true);try v.accept(ping);check(false,"text codec on non-hello rejected")}catch{check(true,"text codec on non-hello rejected")}
  ping.textClipboardCodec=nil;ping.textClipboard=textConsent
  do{var v=PeerValidator(senderPeer:true,session:session,imageClipboardSupported:true,textClipboardSupported:true);try v.accept(ping);check(false,"text field on other kind rejected")}catch{check(true,"text field on other kind rejected")}
  var textHello=Wire(kind:"hello",session:session,sequence:0);textHello.textClipboardCodec=1
  do{var v=Validator();try v.accept(textHello);check(true,"text hello codec 1")}catch{check(false,"text hello codec 1")}
  textHello.textClipboardCodec=2
  do{var v=Validator();try v.accept(textHello);check(false,"unknown text codec rejected")}catch{check(true,"unknown text codec rejected")}
  check(TextClipboardWirePolicy.supported(textCodec:1,imageCodec:1,isolation:1),"text negotiated with isolation")
  check(!TextClipboardWirePolicy.supported(textCodec:1,imageCodec:1,isolation:nil),"text requires isolation")
  check(!TextClipboardWirePolicy.supported(textCodec:nil,imageCodec:1,isolation:1),"0.9.10 peer has no text")
  // Format is decoded, never defaulted: missing or wrong format rejects every op.
  let ops:[[String:Any]]=[["op":"consent","epoch":epoch,"enabled":true],
    ["op":"chunk","epoch":epoch,"peerEpoch":epoch,"id":epoch,"offset":0,"totalBytes":1,"bytes":"QQ=="],
    ["op":"ack","epoch":epoch,"peerEpoch":epoch,"id":epoch,"offset":1],["op":"cancel","epoch":epoch,"peerEpoch":epoch,"id":epoch]]
  for body in ops {
    func decode(_ format:Any?)->TextClipboardPacket? {
      var b=body;if let format {b["format"]=format}
      return (try? JSONSerialization.data(withJSONObject:b)).flatMap{try? JSONDecoder().decode(TextClipboardPacket.self,from:$0)}
    }
    let op=body["op"] as! String
    check(decode("utf8")?.valid==true,"utf8 \(op) accepted")
    check(decode(nil)==nil,"missing format \(op) rejected")
    check(decode("utf16")?.valid != true,"wrong format \(op) rejected")
  }
  let textChunk=TextClipboardPacket(ImageClipboardPacket(op:.chunk,epoch:epoch,peerEpoch:UUID().uuidString,id:UUID().uuidString,offset:0,totalBytes:32768,bytes:Data(repeating:0x41,count:32768)))
  var textPayload=Wire(kind:"textClipboard",session:session,sequence:1);textPayload.textClipboard=textChunk
  check(TextClipboardWirePolicy.validEnvelope(textPayload),"max text chunk within 96 KiB envelope")
  do{let decoded=try unseal(try seal(textPayload,key),key);check(decoded.textClipboard==textChunk && decoded.imageClipboard==nil,"encrypted text roundtrip")}
  catch{check(false,"encrypted text frame roundtrip")}
  print("Image clipboard wire: \(checks) checks, \(failures) failures; encrypted memory only")
  return failures
}
