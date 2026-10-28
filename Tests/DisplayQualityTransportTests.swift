import Foundation
#if TC_QUALITY_TIERS
func runDisplayQualityTransportTests()->Int {
  var failures=0
  func check(_ yes:Bool,_ name:String){if !yes{failures+=1};print("\(yes ? "PASS":"FAIL") quality-transport \(name)")}
  enum FixtureError:Error {case failure}
  do {
    let all=try DisplayQualityCapabilities(mask:15,ceiling:3)
    var sent:[Data]=[],received=0
    let legacy=try displayNegotiateQualityCapabilities(enabled:false,local:all,send:{sent.append($0)},receive:{received+=1;throw FixtureError.failure})
    check(legacy.mask==1 && legacy.ceiling==0 && sent.isEmpty && received==0,"legacy sends zero extension bytes")
    let peer=try DisplayQualityCapabilities(mask:5,ceiling:2),echo=Data([12,1,5,2])
    let agreed=try displayNegotiateQualityCapabilities(enabled:true,local:all,send:{sent.append($0)},receive:{defer{received+=1};return received==0 ? peer.packet:echo})
    check(agreed==peer && sent==[all.packet,echo] && received==2,"exact authenticated transcript")
    for bad in [Data(),Data([0]),Data([13,1,2]),Data([11,1,0,3]),Data([11,1,255,3]),Data([11,1,15,4]),Data([11,1,8,0]),Data([11,1,15,3,0])] {
      sent=[]
      do {_=try displayNegotiateQualityCapabilities(enabled:true,local:all,send:{sent.append($0)},receive:{bad});check(false,"invalid proposal")}
      catch {check(sent==[all.packet],"reject proposal before echo")}
    }
    for bad in [Data([12,1,15,2]),Data([12,1,5,3]),Data([12,2,5,2]),Data([12,1,5,2,0]),Data([0])] {
      received=0
      do {_=try displayNegotiateQualityCapabilities(enabled:true,local:all,send:{_ in},receive:{defer{received+=1};return received==0 ? peer.packet:bad});check(false,"invalid echo")}
      catch {check(received==2,"reject altered echo")}
    }
    do {_=try displayNegotiateQualityCapabilities(enabled:true,local:all,send:{_ in throw FixtureError.failure},receive:{throw FixtureError.failure});check(false,"failed sender")}
    catch FixtureError.failure {check(true,"send error preserved")}
    catch {check(false,"unexpected send error")}
  } catch {check(false,"unexpected fixture error")}
  return failures
}
#endif
