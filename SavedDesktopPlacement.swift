import Foundation
import CoreGraphics

/// Stores only the source attachment to an authenticated receiver display.
/// Receiver geometry is never written or restored into macOS settings.
final class SavedDesktopPlacementStore {
    static let key="ThunderControl.sourceDesktopPlacements.v1"
    static let maximumRecords=128,maximumBytes=256*1024
    private struct Record:Codable {
        let pair:LayoutDevicePair
        let anchorIdentity:String?
        let anchorID:UInt32
        let anchorVirtual:Bool?
        let side:DesktopSide
        let tangentOffset:Double
        var valid:Bool {
            pair.localID != pair.peerID && anchorID != 0 && tangentOffset.isFinite && abs(tangentOffset)<=2_000_000 &&
            (anchorIdentity == nil || UUID(uuidString:anchorIdentity!)?.uuidString == anchorIdentity)
        }
    }
    private struct Envelope:Codable {let version:Int;var records:[Record]}
    private let defaults:UserDefaults
    init(defaults:UserDefaults = .standard){self.defaults=defaults}
    private func records()->[Record] {
        guard let data=defaults.data(forKey:Self.key),data.count<=Self.maximumBytes,
              let envelope=try? JSONDecoder().decode(Envelope.self,from:data),envelope.version==1,envelope.records.count<=Self.maximumRecords else{return []}
        var seen=Set<LayoutDevicePair>()
        return envelope.records.filter{$0.valid && seen.insert($0.pair).inserted}
    }
    @discardableResult func save(origin:CGPoint,sourceSize:CGSize,desktop:ReceiverDesktop,for pair:LayoutDevicePair)->Bool {
        guard desktop.valid,ReceiverDesktop.finite(origin),ReceiverDesktop.sane(CGRect(origin:.zero,size:sourceSize)),pair.localID != pair.peerID else{return false}
        let portals=desktop.portals(sourceRect:CGRect(origin:origin,size:sourceSize))
        guard let portal=portals.first(where:{$0.displayID==desktop.mainID}) ?? portals.first,
              let anchor=desktop.displays.first(where:{$0.id==portal.displayID}) else{return false}
        let offset=(portal.sourceSide == .left || portal.sourceSide == .right) ? origin.y-anchor.bounds.minY : origin.x-anchor.bounds.minX
        let record=Record(pair:pair,anchorIdentity:anchor.stableIdentity,anchorID:anchor.id,anchorVirtual:anchor.id==desktop.virtualDisplayID,side:portal.sourceSide,tangentOffset:Double(offset))
        guard record.valid else{return false}
        var list=records().filter{$0.pair != pair};list.append(record)
        if list.count>Self.maximumRecords {list.removeFirst(list.count-Self.maximumRecords)}
        guard let data=try? JSONEncoder().encode(Envelope(version:1,records:list)),data.count<=Self.maximumBytes else{return false}
        defaults.set(data,forKey:Self.key);return true
    }
    func restored(for pair:LayoutDevicePair,sourceSize:CGSize,desktop:ReceiverDesktop)->CGPoint? {
        guard desktop.valid,ReceiverDesktop.sane(CGRect(origin:.zero,size:sourceSize)) else{return nil}
        guard let saved=records().first(where:{$0.pair==pair}) else {
            // Read-only migration of the old two-screen placement. The old store
            // is preserved and no automatic adjustment is written as user intent.
            guard let main=desktop.displays.first(where:{$0.id==desktop.mainID}),
                  let legacy=SavedScreenLayoutStore(defaults:defaults).restored(for:pair,sourceSize:sourceSize,remoteSize:main.bounds.size) else{return nil}
            let origin=CGPoint(x:legacy.remoteOnRight ? main.bounds.minX-sourceSize.width : main.bounds.maxX,y:main.bounds.minY-legacy.offsetY)
            return desktop.snappedSourceOrigin(proposed:origin,size:sourceSize)
        }
        let exact:ReceiverDisplay?
        if saved.anchorVirtual==true {exact=desktop.displays.first{$0.id==desktop.virtualDisplayID}}
        else if let identity=saved.anchorIdentity {exact=desktop.displays.first{$0.stableIdentity==identity}}
        else {exact=desktop.displays.first{$0.id==saved.anchorID}}
        guard let anchor=exact ?? desktop.displays.first(where:{$0.id==desktop.mainID}) else{return nil}
        let offset=CGFloat(saved.tangentOffset),rect=anchor.bounds
        let origin:CGPoint
        switch saved.side {
        case .left:origin=CGPoint(x:rect.maxX,y:rect.minY+offset)
        case .right:origin=CGPoint(x:rect.minX-sourceSize.width,y:rect.minY+offset)
        case .top:origin=CGPoint(x:rect.minX+offset,y:rect.maxY)
        case .bottom:origin=CGPoint(x:rect.minX+offset,y:rect.minY-sourceSize.height)
        }
        if !desktop.portals(sourceRect:CGRect(origin:origin,size:sourceSize)).isEmpty {return origin}
        // A changed receiver layout can obstruct the old attachment. Adjust only
        // the current source position, without overwriting the user's saved intent.
        return desktop.snappedSourceOrigin(proposed:origin,size:sourceSize)
    }
}
