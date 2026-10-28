import Foundation
import VideoToolbox

#if TC_QUALITY_TIERS
// Negotiated only after the authenticated Relay announces this extension on both ends.
// No new bytes are sent to legacy video peers. These messages remain inside v6 AEAD.
struct DisplayQualityCapabilities: Equatable {
    let mask: UInt8
    let ceiling: Int
    init(mask: UInt8, ceiling: Int) throws {
        guard mask > 0, mask & 0xf0 == 0, (0...3).contains(ceiling),
              mask & UInt8((1 << (ceiling + 1)) - 1) != 0 else { throw DisplayTransportError.invalid }
        self.mask=mask;self.ceiling=ceiling
    }
    var packet: Data { Data([11,1,mask,UInt8(ceiling)]) }
    init(packet: Data) throws {
        guard packet.count==4,packet[0]==11,packet[1]==1 else { throw DisplayTransportError.invalid }
        try self.init(mask:packet[2],ceiling:Int(packet[3]))
    }
    static func local(ceiling: Int) throws -> Self {
        let codecs: [CMVideoCodecType] = [kCMVideoCodecType_H264,kCMVideoCodecType_HEVC,kCMVideoCodecType_AppleProRes422Proxy,kCMVideoCodecType_AppleProRes422LT]
        var mask:UInt8=0
        for (i,codec) in codecs.enumerated() where VTIsHardwareDecodeSupported(codec) { mask |= UInt8(1 << i) }
        // Sender creation is independently hardware-required in the helper; decode support
        // here is a conservative shared floor, not a promise that encoding will succeed.
        return try .init(mask:mask,ceiling:ceiling)
    }
    func agreement(with peer: Self) throws -> Self { try .init(mask:mask & peer.mask,ceiling:min(ceiling,peer.ceiling)) }
    var codecNames: [String] { (0...3).reversed().compactMap { mask & UInt8(1 << $0) != 0 ? DisplayQualityTier(rawValue:$0)?.wireCodecName : nil } }
    var selected: Int? { (0...ceiling).reversed().first { mask & UInt8(1 << $0) != 0 } }
    static func tier(in data: Data) -> Int? {
        let offset = data.first == 6 ? DisplayStreamFrameHeader.videoOffset : 0
        guard data.count>offset else{return nil}
        switch data[data.startIndex+offset] {
        case 2:return 0
        case 9:return 1
        case 10:
            guard data.count>offset+4 else{return nil}
            let fourcc=DisplayStreamFrame.number(data,offset+1,4)
            if fourcc==UInt64(kCMVideoCodecType_AppleProRes422Proxy){return 2}
            if fourcc==UInt64(kCMVideoCodecType_AppleProRes422LT){return 3}
            return nil
        default:return nil
        }
    }
}

// A single slow frame never lowers quality. Require a sustained window, and never
// oscillate upward automatically. User changes/new sessions reset this governor.
struct DisplayQualityCongestion {
    private var start:Double?
    private var total=0,slow=0
    private var nextAllowed=0.0
    mutating func observe(now:Double,writeSeconds:Double,current:Int,mask:UInt8)->Int? {
        guard now.isFinite,writeSeconds.isFinite,writeSeconds>=0 else{return nil}
        guard current>0,now>=nextAllowed else{return nil}
        if start==nil {start=now}
        total+=1;if writeSeconds>0.018 {slow+=1}
        guard let since=start,now-since>=2 else{return nil}
        let congested=total>=30 && Double(slow)/Double(total)>=0.25
        start=now;total=0;slow=0
        guard congested,let lower=(0..<current).reversed().first(where:{mask & UInt8(1 << $0) != 0}) else{return nil}
        nextAllowed=now+5
        return lower
    }
}
#endif

#if TC_QUALITY_TIERS
func displayNegotiateQualityCapabilities(enabled:Bool,local:DisplayQualityCapabilities,
    send:(Data)throws->Void,receive:()throws->Data)throws->DisplayQualityCapabilities {
    guard enabled else{return try .init(mask:1,ceiling:0)}
    try send(local.packet)
    let peer=try DisplayQualityCapabilities(packet:receive())
    let agreement=try local.agreement(with:peer)
    let echo=Data([12,1,agreement.mask,UInt8(agreement.ceiling)])
    try send(echo)
    guard try receive()==echo else{throw DisplayTransportError.invalid}
    return agreement
}
#endif
