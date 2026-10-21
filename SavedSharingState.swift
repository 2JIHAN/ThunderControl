import Foundation

/// User intent, never a snapshot of transient topology cleanup or disconnect.
struct SavedSharingState:Codable,Equatable {
  let pair:LayoutDevicePair
  let inputIsSender:Bool
  var inputAuto:Bool
  var inputForward:Bool
  var receiverConsent:Bool
  var videoEnabled:Bool
  var videoSending:Bool
  var valid:Bool {pair.localID != pair.peerID && videoSending == !inputIsSender && (!inputIsSender ? !inputAuto && !inputForward : !receiverConsent) && !(inputAuto && inputForward)}
  /// No record means no explicit per-pair OFF was saved. Preserve the existing
  /// authenticated sender's default auto-input intent even if peer geometry
  /// has not arrived when the first video button is pressed.
  static func firstVideo(pair:LayoutDevicePair,inputIsSender:Bool,auto:Bool,forward:Bool,consent:Bool)->Self {
    var state=Self.off(pair:pair,inputIsSender:inputIsSender)
    state.inputAuto=inputIsSender && (auto || !forward)
    state.inputForward=inputIsSender && !state.inputAuto && forward
    state.receiverConsent = !inputIsSender && consent
    state.videoEnabled=true
    return state
  }
  static func off(pair:LayoutDevicePair,inputIsSender:Bool)->Self {
    .init(pair:pair,inputIsSender:inputIsSender,inputAuto:false,inputForward:false,receiverConsent:false,videoEnabled:false,videoSending:!inputIsSender)
  }
}
final class SavedSharingStateStore {
  static let key="ThunderControl.savedSharingState.v1"
  static let maximumRecords=128,maximumBytes=128*1024
  private struct Envelope:Codable {let version:Int;var records:[SavedSharingState]}
  private let defaults:UserDefaults
  init(defaults:UserDefaults = .standard){self.defaults=defaults}
  var isReadable:Bool {records() != nil}
  private func records()->[SavedSharingState]? {
    guard let raw=defaults.object(forKey:Self.key) else{return []}
    guard let data=raw as? Data,data.count<=Self.maximumBytes,
      let value=try? JSONDecoder().decode(Envelope.self,from:data),value.version==1,value.records.count<=Self.maximumRecords else{return nil}
    var seen=Set<String>()
    guard value.records.allSatisfy({$0.valid && seen.insert("\($0.pair.localID)/\($0.pair.peerID)/\($0.inputIsSender)").inserted}) else{return nil}
    return value.records
  }
  func load(pair:LayoutDevicePair,inputIsSender:Bool)->SavedSharingState? {
    records()?.first{$0.pair==pair && $0.inputIsSender==inputIsSender}
  }
  @discardableResult func save(_ state:SavedSharingState)->Bool {
    guard state.valid,let existing=records() else{return false}
    var list=existing.filter{!($0.pair==state.pair && $0.inputIsSender==state.inputIsSender)}
    list.append(state);if list.count>Self.maximumRecords {list.removeFirst(list.count-Self.maximumRecords)}
    guard let data=try? JSONEncoder().encode(Envelope(version:1,records:list)),data.count<=Self.maximumBytes else{return false}
    defaults.set(data,forKey:Self.key);return true
  }
}
