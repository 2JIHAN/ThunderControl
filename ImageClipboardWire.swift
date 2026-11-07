import Foundation

enum ImageClipboardWirePolicy {
  static func validEnvelope(_ w:Wire)->Bool {
    guard w.kind=="imageClipboard",let packet=w.imageClipboard,packet.valid,
      let data=try? JSONEncoder().encode(w),data.count<=96*1024,
      let json=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else{return false}
    return Set(json.keys)==Set(["kind","session","sequence","imageClipboard"])
  }
}
