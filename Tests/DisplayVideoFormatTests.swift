import Foundation
import CoreGraphics
import CryptoKit

func runDisplayVideoFormatTests() -> Int {
    var checks=0,failures=0
    func check(_ value:Bool,_ label:String){checks+=1;if !value{failures+=1;fputs("DisplayVideoFormat failed: \(label)\n",stderr)}}
    func rejects(_ body:()throws->Void,_ label:String){do{try body();check(false,label)}catch{check(true,label)}}
    check(DisplayVideoFormat.standard.valid,"legacy1080 valid")
    for size in [CGSize(width:2560,height:1600),CGSize(width:3024,height:1964),CGSize(width:3456,height:2234),CGSize(width:1512,height:945),CGSize(width:1920,height:1080),CGSize(width:3840,height:2160),CGSize(width:1920,height:1440),CGSize(width:2560,height:1080)] {
        let format=DisplayVideoFormat.fitting(size)
        check(format.valid,"bounded fitted format")
        check(abs(Double(format.width)/Double(format.height)-Double(size.width/size.height))<0.005,"no stretch/crop, bounded even rounding")
        check(format.width*format.height<=1920*1080,"unchanged pixel budget")
        check(((format.width+15)/16)*((format.height+15)/16)<=8704,"60fps level4.2 macroblocks")
        do{check(try DisplayVideoFormat.decode(format.encoded())==format,"wire round trip")}catch{check(false,"wire encode")}
    }
    for size in [CGSize.zero,CGSize(width:-1,height:900),CGSize(width:CGFloat.nan,height:900),CGSize(width:CGFloat.infinity,height:900),CGSize(width:900,height:1600),CGSize(width:10000,height:1)] {
        check(DisplayVideoFormat.fitting(size) == .standard,"invalid target defaults safely")
    }
    for format in [DisplayVideoFormat(width:1920,height:1200),DisplayVideoFormat(width:1920,height:1440),DisplayVideoFormat(width:1921,height:1080),DisplayVideoFormat(width:1801,height:1124),DisplayVideoFormat(width:0,height:0),DisplayVideoFormat(width:640,height:1440),DisplayVideoFormat(width:Int.max,height:Int.max),DisplayVideoFormat(width:-1,height:1080)] {
        check(!format.valid,"invalid or over-budget rejected")
        rejects({_ = try format.encoded()},"invalid format encode")
    }
    for size in [CGSize(width:1512,height:945),CGSize(width:1728,height:1080),CGSize(width:1808,height:1130),CGSize(width:1920,height:1200)] {
        let retina=DisplayVideoFormat.hiDPI(for:size)
        check(retina.valid && retina.pixelScale==2,"real HiDPI format")
        check(retina.pixelWidth==retina.width*2 && retina.pixelHeight==retina.height*2,"exact2x pixels")
        check(abs(retina.size.width/retina.size.height-size.width/size.height)<0.003,"HiDPI aspect preserved")
        check(retina.pixelWidth*retina.pixelHeight<=DisplayVideoFormat.maximumEncodedPixels,"HiDPI pixel budget")
        do{check(try DisplayVideoFormat.decode(retina.encoded())==retina,"HiDPI wire roundtrip")}catch{check(false,"HiDPI wire")}
    }
    let native=DisplayVideoFormat.hiDPI(for:CGSize(width:1512,height:945))
    check(native.width==1512 && native.height==945 && native.pixelWidth==3024 && native.pixelHeight==1890,"native logical safe area no inflation")
    check(DisplayVideoFormat(width:1512,height:945,pixelScale:2).valid,"odd logical even backing")
    check(!DisplayVideoFormat(width:1512,height:945).valid,"SDR odd pixel rejected")
    for scale in [-1,0,3,Int.max] {check(!DisplayVideoFormat(width:1440,height:900,pixelScale:scale).valid,"invalid scale")}
    rejects({_ = try DisplayVideoFormat.decode(Data([5,2,5,160,3,132,3]))},"wire scale rejected")
    let example=DisplayVideoFormat.fitting(CGSize(width:2560,height:1600))
    let proposal=try! example.encoded()
    for n in 0..<proposal.count {rejects({_ = try DisplayVideoFormat.decode(Data(proposal.prefix(n)))},"truncation")}
    rejects({_ = try DisplayVideoFormat.decode(proposal+Data([0]))},"trailing bytes")
    for index in [0,1] {var wrong=proposal;wrong[index]^=255;rejects({_ = try DisplayVideoFormat.decode(wrong)},"wrong type/version")}
    rejects({_ = try DisplayVideoFormat.decode(Data([5,2,255,255,255,255,2]))},"oversized wire dimensions")
    for role in [false,true] {check(!DisplayChannelCipher.allowedPayload(proposal,fromSender:role),"no streaming renegotiation")}
    check(!DisplayChannelCipher.validInputPayload(proposal),"not an input packet")
    // Actual shared negotiation helper through real direction-bound AEAD channels.
    let root=SymmetricKey(size:.bits256),s=UUID().uuidString,r=UUID().uuidString
    var viewerTX=DisplayChannelCipher(root:root,senderNonce:s,receiverNonce:r,senderToReceiver:false)
    var sourceRX=DisplayChannelCipher(root:root,senderNonce:s,receiverNonce:r,senderToReceiver:false)
    var sourceTX=DisplayChannelCipher(root:root,senderNonce:s,receiverNonce:r,senderToReceiver:true)
    var viewerRX=DisplayChannelCipher(root:root,senderNonce:s,receiverNonce:r,senderToReceiver:true)
    var request:Data?,response:Data?,adopted:DisplayVideoFormat?
    do {
        let viewer = try displayNegotiateVideoFormat(sending:false,viewerFormat:example,send:{request=try viewerTX.seal($0)},receive:{
            adopted = try displayNegotiateVideoFormat(sending:true,viewerFormat:.standard,send:{response=try sourceTX.seal($0)},receive:{try sourceRX.open(request!)})
            return try viewerRX.open(response!)
        })
        check(adopted==example && viewer==example,"both endpoints agree before helper/viewer creation")
        if let request {rejects({_ = try sourceRX.open(request)},"encrypted proposal replay denied")}
        if let response {rejects({_ = try viewerRX.open(response)},"encrypted echo replay denied")}
    } catch {check(false,"encrypted format exchange")}
    rejects({_ = try displayNegotiateVideoFormat(sending:false,viewerFormat:example,send:{_ in},receive:{try DisplayVideoFormat.standard.encoded()})},"echo substitution")
    rejects({_ = try displayNegotiateVideoFormat(sending:true,viewerFormat:.standard,send:{_ in},receive:{Data([1,0,0,0,1])})},"identity before config")
    rejects({_ = try displayNegotiateVideoFormat(sending:true,viewerFormat:.standard,send:{_ in},receive:{Data([4,1,0,0])})},"legacy input denied during negotiation")
    enum Timeout:Error{case expired}
    rejects({_ = try displayNegotiateVideoFormat(sending:true,viewerFormat:.standard,send:{_ in},receive:{throw Timeout.expired})},"negotiation read timeout")
    rejects({_ = try DisplayChannelCipher.parseHello(Data("TDSP3".utf8)+Data([1])+Data(s.utf8),expectSender:true)},"v3 downgrade denied")
    // Screen selection is pure: external main cannot displace an active built-in.
    func candidate(_ builtIn:Bool,_ active:Bool=true,_ top:CGFloat=0)->DisplayViewerScreenCandidate {
        DisplayViewerScreenCandidate(builtIn:builtIn,active:active,frame:CGRect(x:0,y:0,width:1512,height:982),safeTop:top,safeBottom:0,safeLeft:0,safeRight:0)
    }
    let screens=[candidate(false),candidate(true,true,37)]
    check(DisplayViewerScreenCandidate.preferredIndex(screens,mainIndex:0)==1,"built-in preferred over external main")
    check(screens[1].fullScreenSize==CGSize(width:1512,height:945),"notch-safe fullscreen prediction, no Dock deduction")
    check(DisplayViewerScreenCandidate.preferredIndex([candidate(false),candidate(true,false)],mainIndex:0)==0,"closed built-in falls back to active main")
    check(DisplayViewerScreenCandidate.preferredIndex([],mainIndex:nil)==nil,"no screen fallback")
    check(candidate(true,true,-1).fullScreenSize==nil,"negative safe inset rejected")
    check(candidate(true,true,2000).fullScreenSize==nil,"empty safe area rejected")
    check(candidate(true,true,.nan).fullScreenSize==nil,"invalid safe inset rejected")
    let retina=DisplayVideoFormat.fitting(CGSize(width:3024,height:1890)),scaled=DisplayVideoFormat.fitting(CGSize(width:1512,height:945))
    check(retina==scaled,"scaled points preserve physical aspect")
    print("Display video format negotiation and target selection: \(checks) checks, \(failures) failures; memory-only crypto, no screen settings/network/input")
    return failures
}
