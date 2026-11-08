import Foundation

enum ImageClipboardWirePolicy {
  static func isolatedSharingSupported(codec:Int?,isolation:Int?)->Bool {codec==1 && isolation==1}
  static func validEnvelope(_ w:Wire)->Bool {
    guard w.kind=="imageClipboard",let packet=w.imageClipboard,packet.valid,
      let data=try? JSONEncoder().encode(w),data.count<=96*1024,
      let json=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else{return false}
    return Set(json.keys)==Set(["kind","session","sequence","imageClipboard"])
  }
}

enum TextClipboardWirePolicy {
  /// Text needs its own hello codec and the same isolation fix as images; image consent never implies text.
  static func supported(textCodec:Int?,imageCodec:Int?,isolation:Int?)->Bool {textCodec==1 && ImageClipboardWirePolicy.isolatedSharingSupported(codec:imageCodec,isolation:isolation)}
  static func validEnvelope(_ w:Wire)->Bool {
    guard w.kind=="textClipboard",let packet=w.textClipboard,packet.valid,
      let data=try? JSONEncoder().encode(w),data.count<=96*1024,
      let json=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else{return false}
    return Set(json.keys)==Set(["kind","session","sequence","textClipboard"])
  }
}
