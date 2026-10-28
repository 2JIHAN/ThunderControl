import Foundation
#if TC_QUALITY_TIERS
func runDisplayQualityNegotiationTests()->Int {
  var failures=0
  func check(_ pass:Bool,_ name:String){if !pass{failures+=1};print("\(pass ? "PASS":"FAIL") quality-negotiation \(name)")}
  do {
    let all=try DisplayQualityCapabilities(mask:15,ceiling:3),old=try DisplayQualityCapabilities(mask:1,ceiling:0)
    check(try DisplayQualityCapabilities(packet:all.packet)==all,"bounded capability roundtrip")
    check(try all.agreement(with:old)==old,"intersection chooses H264")
    let capped=try DisplayQualityCapabilities(mask:15,ceiling:1)
    check(try all.agreement(with:capped).selected==1,"both ceilings respected")
    check(all.codecNames==["lt","proxy","hevc","h264"],"descending helper allowlist")
    for bad:Data in [Data(),Data([11,1,0,3]),Data([11,1,255,3]),Data([11,1,15,4]),Data([11,2,15,3]),Data([11,1,8,0]),Data([11,1,15,3,0])] {
      check((try? DisplayQualityCapabilities(packet:bad))==nil,"malformed capability rejected")
    }
    var governor=DisplayQualityCongestion(),changes:[Int]=[]
    for n in 0..<500 {if let tier=governor.observe(now:Double(n)/60,writeSeconds:n==60 ? 0.1:0.001,current:3,mask:15){changes.append(tier)}}
    check(changes.isEmpty,"isolated spike never downgrades")
    governor=DisplayQualityCongestion()
    for n in 0..<150 {if let tier=governor.observe(now:Double(n)/60,writeSeconds:0.025,current:3,mask:15){changes.append(tier)}}
    check(changes==[2],"sustained write congestion lowers one tier")
    for n in 150..<300 {if let tier=governor.observe(now:Double(n)/60,writeSeconds:0.025,current:2,mask:15){changes.append(tier)}}
    check(changes==[2],"cooldown prevents rapid oscillation")
    check(DisplayQualityCapabilities.tier(in:Data([10,0x61,0x70,0x63,0x73,0]))==3,"actual LT packet")
    check(DisplayQualityCapabilities.tier(in:Data([10,0x61,0x70,0x63,0x6f,0]))==2,"actual Proxy packet")
  } catch {check(false,"unexpected error")}
  return failures
}
#endif
