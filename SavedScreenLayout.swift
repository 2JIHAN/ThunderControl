import Foundation
import CoreGraphics

/// Display metadata only. Construct production bindings only from completed authenticated pairing.
struct LayoutDevicePair:Codable,Hashable {
  let localID:UUID
  let peerID:UUID
  init?(localID:String,peerID:String) {
    guard let local=UUID(uuidString:localID),let peer=UUID(uuidString:peerID),local != peer,
      local.uuidString==localID,peer.uuidString==peerID else{return nil}
    self.localID=local;self.peerID=peer
  }
}
struct SavedLayoutRecord:Codable {
  let pair:LayoutDevicePair
  let sourceWidth:Double,sourceHeight:Double,remoteWidth:Double,remoteHeight:Double
  let remoteOnRight:Bool,offsetY:Double
  var arrangement:ScreenArrangement {
    .init(sourceSize:CGSize(width:sourceWidth,height:sourceHeight),remoteSize:CGSize(width:remoteWidth,height:remoteHeight),remoteOnRight:remoteOnRight,offsetY:offsetY)
  }
}
final class SavedScreenLayoutStore {
  static let key="ThunderControl.savedScreenLayouts.v1"
  static let maximumRecords=128,maximumBytes=256*1024
  private struct Envelope:Codable {var version:Int;var records:[SavedLayoutRecord]}
  private let defaults:UserDefaults
  init(defaults:UserDefaults = .standard){self.defaults=defaults}
  private func records()->[SavedLayoutRecord] {
    guard let data=defaults.data(forKey:Self.key),data.count<=Self.maximumBytes,
      let envelope=try? JSONDecoder().decode(Envelope.self,from:data),envelope.version==1,
      envelope.records.count<=Self.maximumRecords else{return []}
    var seen=Set<LayoutDevicePair>()
    return envelope.records.filter {record in
      record.pair.localID != record.pair.peerID && record.arrangement.isValid && seen.insert(record.pair).inserted
    }
  }
  @discardableResult func save(_ layout:ScreenArrangement,for pair:LayoutDevicePair)->Bool {
    guard layout.isValid,pair.localID != pair.peerID else{return false}
    var list=records().filter{$0.pair != pair}
    list.append(.init(pair:pair,sourceWidth:layout.sourceSize.width,sourceHeight:layout.sourceSize.height,remoteWidth:layout.remoteSize.width,remoteHeight:layout.remoteSize.height,remoteOnRight:layout.remoteOnRight,offsetY:layout.offsetY))
    if list.count>Self.maximumRecords {list.removeFirst(list.count-Self.maximumRecords)}
    guard let data=try? JSONEncoder().encode(Envelope(version:1,records:list)),data.count<=Self.maximumBytes else{return false}
    defaults.set(data,forKey:Self.key);return true
  }
  func restored(for pair:LayoutDevicePair,sourceSize:CGSize,remoteSize:CGSize)->ScreenArrangement? {
    guard let saved=records().first(where:{$0.pair==pair}),
      ScreenArrangement(sourceSize:sourceSize,remoteSize:remoteSize,remoteOnRight:saved.remoteOnRight,offsetY:0).hasValidDimensions else{return nil}
    let exact=ScreenArrangement(sourceSize:sourceSize,remoteSize:remoteSize,remoteOnRight:saved.remoteOnRight,offsetY:saved.offsetY)
    if exact.isValid {return exact}
    // Only adjust a now-invalid saved arrangement after geometry changes.
    let overlap=min(64,min(sourceSize.height,remoteSize.height))
    let offset=max(-remoteSize.height+overlap,min(sourceSize.height-overlap,saved.offsetY))
    let result=ScreenArrangement(sourceSize:sourceSize,remoteSize:remoteSize,remoteOnRight:saved.remoteOnRight,offsetY:offset)
    return result.isValid ? result:nil
  }
}
