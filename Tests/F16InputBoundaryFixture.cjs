const fs=require('fs'),path=require('path');
const root=path.resolve(__dirname,'..'),out=process.argv[2];
const source=fs.readFileSync(path.join(root,'ThunderControl.swift'),'utf8');
function method(start,end){let a=source.indexOf(start),b=source.indexOf(end,a);if(a<0||b<0)throw Error(start);return source.slice(a,b);}
fs.mkdirSync(out,{recursive:true});
const gate=method('  func currentSessionBlockReason(forceRefresh:', '  func safetyStop(');
const post=method('  private func postReceiverInput(', '  func releaseInputs()');
const test=method('  static func verifyReceiverNativeOpenSessionForTests()', '  static func verifyReceiverInputCleanupBlocksLifecycleForTests()');
const fixture=`import AppKit\nimport IOKit\nimport IOKit.hidsystem\nstruct Bounds {let bounds:CGRect}\nstruct Desktop {let displays:[Bounds]}\nfunc replayTapLocation(for:UInt32)->CGEventTapLocation{.cghidEventTap}\nfinal class Relay {\nlet hidInputPoster:HIDInputPoster\ninit(inputAPI:RelayInputAPI){hidInputPoster=HIDInputPoster(api:inputAPI.native)}\nvar desktopInputPostForTests:((CGEvent)->Void)?\nvar desktopPhysicalInputsForTests:(()->Bool)?\nvar receiverPhysicalModifiers=Set<CGKeyCode>()\nvar receiverDesktop:Desktop?=Desktop(displays:[Bounds(bounds:CGRect(x:0,y:0,width:100,height:100))])\nvar topology:Bounds?\nvar sessionSnapshotReadForTests:(()->SessionSafetySnapshot)?\nvar sessionSnapshot=SessionSafetySnapshot(onConsole:true,loginDone:true,screenLocked:false)\nvar lastSessionPoll=ProcessInfo.processInfo.systemUptime\nvar safetyObserversInstalled=true,sessionLockedSignal=false,screenSleeping=false,systemSleeping=false\nfunc physicalInputsHeld()->Bool{fatalError("unexpected physical read")}\nfunc receiverModifierFlags(_ codes:Set<CGKeyCode>)->CGEventFlags{[]}\nfunc postCGEvent(_ event:CGEvent,_ tap:CGEventTapLocation){fatalError("unexpected CG post")}\n${gate}${post}${test}}\n`;
fs.writeFileSync(path.join(out,'RelayBoundary.swift'),fixture);
fs.writeFileSync(path.join(out,'main.swift'),'import Darwin\nlet ok=Relay.verifyReceiverNativeOpenSessionForTests()\nlet failures=runHIDMouseMotionTests()\nexit(ok && failures==0 ? 0:1)\n');
console.log('Exact production currentSessionBlockReason/postReceiverInput and actual Relay self-test extracted; only unrelated state dependencies stubbed.');
