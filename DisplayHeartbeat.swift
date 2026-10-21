import Foundation

struct DisplayHeartbeatState {
  private var sequence:UInt64=0
  private(set) var pending:(token:UInt64,sent:Double)?
  mutating func next(now:Double)->(token:UInt64?,expired:Bool) {
    if let pending,now-pending.sent<6{return(nil,false)}
    let expired=pending != nil
    sequence &+= 1;if sequence==0{sequence=1}
    pending=(sequence,now);return(sequence,expired)
  }
  mutating func accept(token:UInt64,now:Double)->Double? {
    guard let item=pending,item.token==token,now.isFinite,now>=item.sent else{return nil}
    pending=nil;return(now-item.sent)*1000
  }
  static func packet(token:UInt64,reply:Bool)->Data {
    var value=token.bigEndian
    return Data([0,reply ? 2:1])+withUnsafeBytes(of:&value){Data($0)}
  }
  static func parse(_ bytes:Data)throws->(token:UInt64,reply:Bool) {
    let data=Array(bytes)
    guard data.count==10,data[0]==0,data[1]==1 || data[1]==2 else{throw DisplayTransportError.invalid}
    let token=data.suffix(8).reduce(UInt64(0)){($0<<8)|UInt64($1)}
    guard token != 0 else{throw DisplayTransportError.invalid}
    return(token,data[1]==2)
  }
}
