const fs=require('fs');const source=fs.readFileSync('ThunderControl.swift','utf8');let base=fs.readFileSync('Tests/TransitionMotionOverloadRegression.swift.inc','utf8');
let pre=base.slice(0,base.indexOf('final class TransitionReplayFixture'));
pre='import Darwin\n'+pre;
pre=pre.replace('struct Point {','typealias SessionContext = Context\ntypealias CGEventFlags = Flags\ntypealias CGPoint = Point\nstruct Point: Equatable {').replace('struct Flags {','struct Flags { static let maskShift=Flags();').replace('struct CGVector { var dx: Double; var dy: Double }','struct CGVector { var dx: Double; var dy: Double;static let zero=CGVector(dx:0,dy:0) }').replace('var raw: Int?','var raw: UInt32?');
const a=source.indexOf('  private final class ReplayWake'),b=source.indexOf('  private var returnMotion=',a);
const c=source.indexOf('  private enum NativeAdmission'),d=source.indexOf('  @discardableResult\n  func control(',c);
const e=source.indexOf('  private func flushEntryMotion'),f=source.indexOf('  private func handleSourceGesture',e);
let defs=base.slice(base.indexOf('final class TransitionReplayFixture'),base.indexOf('  func runReplay('));
defs=defs.replace('  var desktopFocusSafety = true','  var focusChecks=0;var focusAllowed=true;var focusHook:(()->Void)?\n  var desktopFocusSafety:Bool {focusChecks+=1;focusHook?();return focusAllowed}');
defs=defs.replace('    stopReasons.append(reason)','    abortDesktopReplay()\n    stopReasons.append(reason)');
defs+=`  let standard:Set<UInt32>=[1,2,3,4,5,6,7,10,11,12,22,25,26,27]
  var localKeys=Set<Int>(),localButtons=Set<Int>(),localFlags=Set<Int>()
  var dockSource=Dock(),sourceGesture=Gesture(),ownership=Ownership()
  struct Dock {var active=false};struct Gesture {var remoteActive=false}
  struct Ownership {var returning=false;func ready(_ token:String?,held:Bool)->Bool {returning && !held}}
  func finishReturnIfDrained() {}
`;
let blocks=source.slice(a,b)+source.slice(c,d)+source.slice(e,f);
blocks=blocks.replaceAll('private ','');
let test=`
  func focusCounter() {
    let r=TransitionReplayFixture();r.replayRecordWriterForTests={r.queued.append($0)}
    r.entryMotion.begin(token:"replay");for _ in 0..<129 {precondition(r.entryMotion.append(token:"replay",dx:1,dy:0))}
    precondition(r.flushEntryMotion(token:"replay") && r.queued.count==128 && r.focusChecks==1)
    r.focusAllowed=false;r.pending.signal();r.pumpDesktopReplay()
    precondition(r.focusChecks==2 && r.queued.count==128 && r.context!.cancelled && r.desktopReplay==nil)
    let reentrant=TransitionReplayFixture();reentrant.replayRecordWriterForTests={_ in preconditionFailure("invalid post-focus anchor admission")}
    reentrant.entryMotion.begin(token:"replay");precondition(reentrant.entryMotion.append(token:"replay",dx:1,dy:0))
    reentrant.focusHook={reentrant.generation=UUID()}
    precondition(!reentrant.flushEntryMotion(token:"replay") && reentrant.focusChecks==1 && reentrant.seq==0)
    let step=TransitionReplayFixture();step.replayRecordWriterForTests={step.queued.append($0);step.desktopHandoffRevision=2}
    step.entryMotion.begin(token:"replay");for _ in 0..<2 {precondition(step.entryMotion.append(token:"replay",dx:1,dy:0))}
    precondition(!step.flushEntryMotion(token:"replay") && step.queued.count==1 && step.focusChecks==1)
    print("PASS exact-source safety counters: full focus once per resume, fresh foreground rejection, post-focus anchor recheck, per-step revision rejection")
  }
  func matrix() {
    var cases=0
    for count in [0,1,127,128,129,2048] {
      for credit in [0,1,127,128] {
        for batch in [1,2,31,127,128] {
          let r=TransitionReplayFixture();r.replayRecordWriterForTests={r.queued.append($0)}
          for _ in credit..<128 {precondition(r.pending.wait(timeout:.now()) == .success)}
          r.entryMotion.begin(token:"replay")
          for i in 0..<count {precondition(r.entryMotion.append(token:"replay",dx:1,dy:i.isMultiple(of:2) ? -30:30))}
          precondition(r.flushEntryMotion(token:"replay"));precondition(r.queued.count==min(count,credit))
          for _ in 0..<2100 {if r.desktopReplay==nil {break};for _ in 0..<batch {r.pending.signal()};r.pumpDesktopReplay()}
          precondition(r.desktopReplay==nil && r.queued.count==count && r.stopReasons.isEmpty)
          precondition(r.queued.enumerated().allSatisfy{$0.element.sequence==UInt64($0.offset)})
          cases+=1
        }
      }
    }
    let zero=TransitionReplayFixture();zero.replayRecordWriterForTests={_ in preconditionFailure("zero sample admission")}
    zero.entryMotion.begin(token:"replay");for _ in 0..<2048 {precondition(zero.entryMotion.append(token:"replay",dx:0,dy:0))}
    precondition(zero.flushEntryMotion(token:"replay") && zero.desktopReplay!.next==128)
    for _ in 0..<16 {zero.pumpDesktopReplay()}
    precondition(zero.desktopReplay==nil && zero.seq==0)
    let terminal=TransitionReplayFixture();terminal.ownership.returning=true;terminal.replayRecordWriterForTests={terminal.queued.append($0)}
    for _ in 0..<127 {precondition(terminal.pending.wait(timeout:.now()) == .success)}
    terminal.entryMotion.begin(token:"replay");precondition(terminal.entryMotion.append(token:"replay",dx:1,dy:0))
    precondition(terminal.flushEntryMotion(token:"replay") && terminal.desktopReplay!.empty)
    terminal.pending.signal();terminal.pumpDesktopReplay();precondition(terminal.desktopReplay==nil)
    let held=TransitionReplayFixture();held.localKeys.insert(12);held.replayRecordWriterForTests={held.queued.append($0)}
    held.entryMotion.begin(token:"replay");for _ in 0..<128 {precondition(held.entryMotion.append(token:"replay",dx:1,dy:0))}
    precondition(held.flushEntryMotion(token:"replay") && held.desktopReplay==nil && !held.context!.cancelled)
    print("PASS exact-source C matrix: " + String(cases) + " count/partial-credit/drain cases; zeros 128/turn; pre-restore terminal credit gate; held-key immediate retirement")
  }
  func test() {
    entryMotion.begin(token:"replay")
    for i in 0..<2048 {precondition(entryMotion.append(token:"replay",dx:1,dy:i.isMultiple(of:2) ? -30:30))}
    replayRecordWriterForTests={self.queued.append($0)}
    precondition(flushEntryMotion(token:"replay"))
    precondition(queued.count==128 && desktopReplay!.next==128 && !context!.cancelled)
    let point=desktopGlobalPointer
    let live=Wire(kind:"event",session:session,sequence:0,raw:5,data:Data([1]),token:"replay",desktopMapRevision:1)
    precondition(acceptCapturedDesktopInput(live,delta:CGVector(dx:-50,dy:2)))
    precondition(point==desktopGlobalPointer)
    for _ in 0..<32 {for _ in 0..<128 {pending.signal()};pumpDesktopReplay();if desktopReplay==nil {break}}
    precondition(queued.count==2049 && desktopReplay==nil && stopReasons.isEmpty)
    var expected=Point()
    for i in 0..<2048 {expected=DesktopHandoffRouting.moved(expected,delta:CGVector(dx:1,dy:i.isMultiple(of:2) ? -30:30),desktop:receiverDesktop!);precondition(queued[i].desktopGlobalX==expected.x && queued[i].desktopGlobalY==expected.y)}
    expected=DesktopHandoffRouting.moved(expected,delta:CGVector(dx:-50,dy:2),desktop:receiverDesktop!)
    precondition(desktopGlobalPointer==expected && queued.last!.desktopGlobalX==expected.x)
    precondition(queued.enumerated().allSatisfy{$0.element.sequence==UInt64($0.offset)})
    bridgeInputSuspended=true;let sequence=seq
    precondition(enqueue(live) && seq==sequence)
    let latch=ReplayWake();latch.setActive(true);precondition(latch.request())
    for _ in 0..<1000 {latch.setActive(false);latch.setActive(true);precondition(!latch.request())}
    latch.consume();precondition(latch.request())
    let bounded=TransitionReplayFixture();let ctx=bounded.context!
    bounded.desktopReplay=DesktopReplay(token:"replay",generation:bounded.generation,context:ctx,revision:1,flags:Flags(),moves:[(dx:1,dy:0)])
    for _ in 0..<64 {precondition(bounded.acceptCapturedDesktopInput(live,delta:.zero))}
    precondition(!bounded.acceptCapturedDesktopInput(live,delta:.zero))
    bounded.abortDesktopReplay();precondition(ctx.cancelled && bounded.desktopReplay==nil)
    let stopped=TransitionReplayFixture();let stoppedContext=stopped.context!
    stopped.entryMotion.begin(token:"replay");precondition(stopped.entryMotion.append(token:"replay",dx:1,dy:0))
    stopped.replayRecordWriterForTests={_ in stopped.abortDesktopReplay()}
    precondition(!stopped.flushEntryMotion(token:"replay"))
    precondition(stopped.desktopReplay==nil && stoppedContext.cancelled && stopped.desktopGlobalPointer==Point())
    print("PASS exact-source C pump/native adapter/capture: 2048 + live, 128-credit stall/resume, full point trace, contiguous sequence, suspended Bool true")
  }
}
@main struct Run {static func main(){precondition(runTransitionMotionTests()==0);TransitionReplayFixture().test();TransitionReplayFixture().matrix();TransitionReplayFixture().focusCounter()}}
`;
const output=process.argv[2];if(!output)throw Error('Usage: node Tests/TransitionReplayExtractedFixture.cjs /absolute/output/main.swift');fs.mkdirSync(require('path').dirname(output),{recursive:true});fs.writeFileSync(output,pre+defs+blocks+test);
