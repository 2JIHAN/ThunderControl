import Foundation
import Darwin

// Routing hint only. A fresh stored-key proof is mandatory before capture/input.
enum DisplayPeerRoute {
  static let key="ThunderControl.displayPeerRoute.v2"
  static func valid(_ value:String)->Bool {(try? address(value,49178)) != nil}
  static func load()->String? {guard let value=UserDefaults.standard.string(forKey:key),valid(value) else{return nil};return value}
  static func authenticatedSocketHost(_ fd:Int32)->String? {
    var a=sockaddr_in();var n=socklen_t(MemoryLayout<sockaddr_in>.size)
    let r=withUnsafeMutablePointer(to:&a){$0.withMemoryRebound(to:sockaddr.self,capacity:1){getpeername(fd,$0,&n)}}
    guard r==0,a.sin_family==AF_INET else{return nil}
    var text=[CChar](repeating:0,count:Int(INET_ADDRSTRLEN))
    guard inet_ntop(AF_INET,&a.sin_addr,&text,socklen_t(text.count)) != nil else{return nil}
    let value=String(cString:text);guard valid(value) else{return nil}
    return value
  }
  static func rememberAuthenticatedSocket(_ fd:Int32) {
    guard let value=authenticatedSocketHost(fd) else{return}
    UserDefaults.standard.set(value,forKey:key)
  }
}
