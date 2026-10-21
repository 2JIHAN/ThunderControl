var assertions=0
func expect(_ condition: @autoclosure () -> Bool, _ name:String) { assertions += 1; if !condition() { fputs("FAIL: \(name)\n",stderr); exit(1) } }
func rejects(_ name:String,_ block:()throws->Void){ var failed=false;do{try block()}catch{failed=true};expect(failed,name) }
func move(_ m:inout EdgeHandoff,_ x:Double,_ y:Double,_ dx:Double,_ t:Double,_ held:Bool=false)->EdgeAction {m.motion(x:x,y:y,dx:dx,now:t,held:held,w:1920,h:1080)}
var source=EdgeHandoff();source.edge = .right
expect(move(&source,1919,270,1,0) == .none,"initial latch blocks immediate crossing")
expect(move(&source,1000,270,1,0.1) == .none,"inward rearms")
expect(move(&source,1919,270,1,1) == .none,"edge dwell starts without suppression")
expect(move(&source,1919,270,1,1.2) == .begin,"qualified right edge begins")
expect(source.phase == .pending,"request is not remote")
let token=source.token!
expect(source.ready(UUID().uuidString,w:1280,h:800,now:1.21) == .none,"stale ready ignored")
expect(source.active(token,now:1.22) == .none,"active before commit ignored")
expect(source.ready(token,w:1280,h:800,now:1.23) == .commit,"matching ready commits")
expect(source.phase == .committed,"ready is not remote")
var target=EdgeHandoff()
expect(target.begin(token,edge:.right,offset:0.25,enabled:false,w:1280,h:800,now:1.2) == .none,"target refuses without consent")
expect(target.begin(token,edge:.right,offset:0.25,enabled:true,w:1280,h:800,now:1.2) == .activate,"target ready with consent")
expect(target.phase == .targetReady && target.edge == .left,"opposite entry edge")
expect(target.commit(UUID().uuidString,now:1.25) == .none,"wrong commit ignored")
expect(target.commit(token,now:1.25) == .activate,"matching commit activates target")
expect(source.active(token,now:1.26) == .remote,"only active ack makes source remote")
source.relative(120,40)
expect(abs(source.x-121)<0.0001 && abs(source.y-239.75)<0.0001,"relative virtual cursor and display scaling")
expect(target.motion(x:1,y:200,dx:-2,now:1.3,held:false,w:1280,h:800) == .none,"entry latch prevents immediate return")
expect(target.motion(x:40,y:200,dx:2,now:1.4,held:false,w:1280,h:800) == .none,"move inward to rearm")
expect(target.motion(x:1,y:200,dx:-2,now:1.5,held:false,w:1280,h:800) == .none,"return dwell starts")
expect(target.motion(x:1,y:200,dx:-2,now:1.7,held:false,w:1280,h:800) == .requestReturn,"return request after rearm and dwell")
expect(target.phase == .returning,"bounded return phase")
expect(target.tick(3.3) == .restore && target.phase == .local,"missing return ack times out local")
expect(source.reset() == .restore && source.phase == .local,"disconnect reset local")
expect(source.active(token,now:3.4) == .none,"late ack after cancel cannot revive")
var held=EdgeHandoff();_ = move(&held,1000,500,1,0)
expect(move(&held,1919,500,1,1,true) == .none && move(&held,1919,500,1,2,true) == .none,"held input prevents handoff")
expect(move(&held,1919,500,1,2.1) == .none,"released input needs new dwell")
expect(move(&held,1919,500,1,2.3) == .begin,"new dwell allowed after release")
let old=held.token!;expect(held.tick(4) == .restore,"pending timeout local")
expect(held.ready(old,w:1280,h:800,now:4.1) == .none,"late ready rejected")
var left=EdgeHandoff();left.edge = .left;_ = move(&left,1000,500,-1,0)
expect(move(&left,0,500,1,1) == .none,"inward direction at left edge does not cross")
_ = move(&left,0,500,-1,2)
expect(move(&left,0,500,-1,2.2) == .begin,"left outward handoff")
var outside=EdgeHandoff();_ = move(&outside,1000,500,1,0)
expect(move(&outside,9999,500,1,1) == .none && move(&outside,9999,500,1,1.2) == .none,"off-main-screen cannot trigger")
expect(!EdgeHandoff.dimensions(.infinity,800) && !EdgeHandoff.dimensions(63,800),"invalid dimensions rejected")
let session=UUID().uuidString
var fromSource=PeerValidator(senderPeer:true,session:session)
try fromSource.accept(Wire(kind:"begin",session:session,sequence:1,y:0.25,token:UUID().uuidString,edge:.right,screenWidth:1920,screenHeight:1080,layoutY:0))
rejects("opposite role rejected") {try fromSource.accept(Wire(kind:"active",session:session,sequence:2,token:UUID().uuidString))}
expect(fromSource.next == 2,"rejection does not advance counter")
rejects("missing control token rejected") {try fromSource.accept(Wire(kind:"commit",session:session,sequence:2))}
rejects("sequence replay rejected") {try fromSource.accept(Wire(kind:"begin",session:session,sequence:1,y:0.25,token:UUID().uuidString,edge:.right,screenWidth:1920,screenHeight:1080,layoutY:0))}
var fromTarget=PeerValidator(senderPeer:false,session:session)
try fromTarget.accept(Wire(kind:"available",session:session,sequence:1,width:1,screenWidth:1280,screenHeight:800))
rejects("reflected input event rejected") {try fromTarget.accept(Wire(kind:"event",session:session,sequence:2,raw:10,data:Data([1])))}
let key=derive("independent-random-fixture-not-a-real-secret")
let sNonce=UUID().uuidString,rNonce=UUID().uuidString
let forward=connectionKey(key,sender:sNonce,receiver:rNonce),reverse=connectionKey(key,sender:sNonce,receiver:rNonce,reverse:true)
let packet=try seal(Wire(kind:"begin",session:sNonce,sequence:1,y:0.2,token:UUID().uuidString,edge:.right),forward)
rejects("direction reflection cannot decrypt") {_ = try unseal(packet,reverse)}
rejects("fresh receiver rejects recorded packet") {_ = try unseal(packet,connectionKey(key,sender:sNonce,receiver:UUID().uuidString))}
print("PASS independent edge and duplex protocol assertions: \(assertions), no taps/input posting/network")
