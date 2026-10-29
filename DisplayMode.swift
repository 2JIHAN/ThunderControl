import AppKit
import CoreGraphics

struct DisplayBaseline: Equatable {
  let ids:[CGDirectDisplayID]
  let active:[CGDirectDisplayID]
  let main:CGDirectDisplayID
  let bounds:CGRect
  let rectangles:[CGRect]
  let mirrors:[CGDirectDisplayID]
  static func read()->DisplayBaseline? {
    var ids=[CGDirectDisplayID](repeating:0,count:32),active=[CGDirectDisplayID](repeating:0,count:32);var count:UInt32=0,activeCount:UInt32=0
    guard CGGetOnlineDisplayList(32,&ids,&count) == .success,count>0,count<=32,CGGetActiveDisplayList(32,&active,&activeCount) == .success,activeCount>0,activeCount<=32 else{return nil}
    let main=CGMainDisplayID(),online=Array(ids.prefix(Int(count))).sorted()
    return DisplayBaseline(ids:online,active:Array(active.prefix(Int(activeCount))).sorted(),main:main,bounds:CGDisplayBounds(main),rectangles:online.map{CGDisplayBounds($0)},mirrors:online.map{CGDisplayMirrorsDisplay($0)})
  }
  /// Mirrors are aliases of their active root, never extra input rectangles.
  /// Physical identities, main selection and layout may change on the receiver.
  var supported:Bool {desktop(revision:1) != nil}
  func desktop(revision:UInt64,virtualID:UInt32?=nil)->ReceiverDesktop? {
    guard (1...8).contains(ids.count),ids.count==rectangles.count,ids.count==mirrors.count,
      Set(ids).count==ids.count,!ids.contains(0),Set(active).count==active.count,
      Set(active).isSubset(of:Set(ids)),active.contains(main),let mainIndex=ids.firstIndex(of:main),
      mirrors[mainIndex]==0,bounds==rectangles[mainIndex] else{return nil}
    for i in ids.indices {
      var cursor=ids[i],seen=Set<UInt32>()
      while let index=ids.firstIndex(of:cursor),mirrors[index] != 0 {
        guard seen.insert(cursor).inserted,ids.contains(mirrors[index]) else{return nil}
        cursor=mirrors[index]
      }
      if mirrors[i] != 0 && !active.contains(cursor){return nil}
    }
    if let virtualID,mirrors.contains(virtualID){return nil}
    let screens=ids.enumerated().compactMap { i,id -> ReceiverDisplay? in
      active.contains(id) && mirrors[i]==0 ? ReceiverDisplay(id:id,bounds:rectangles[i]):nil
    }
    let result=ReceiverDesktop(revision:revision,mainID:main,displays:screens,virtualDisplayID:virtualID)
    return result.valid ? result:nil
  }
  /// Startup proves the owned ID is new and all pre-existing displays remain.
  /// Ongoing changes are checked against the current OS map, not this baseline.
  func preserves(_ original:DisplayBaseline,adding id:CGDirectDisplayID)->Bool {
    guard original.supported,supported,!original.ids.contains(id),id != 0,
      Set(original.ids).isSubset(of:Set(ids)),active.contains(id),
      let index=ids.firstIndex(of:id),mirrors[index]==0 else{return false}
    return true
  }

}

/// Ongoing ownership check, not a replay of the startup physical baseline.
/// The helper independently suspends capture while its own proof is invalid.
struct OwnedDisplayMonitor {
  enum State {case ready,waiting,expired}
  private(set) var invalidSince:Double?
  mutating func observe(_ current:DisplayBaseline?,ownedID:UInt32,now:Double)->State {
    guard now.isFinite else{return .expired}
    if current?.desktop(revision:1,virtualID:ownedID) != nil {invalidSince=nil;return .ready}
    if invalidSince==nil {invalidSince=now}
    return now-invalidSince!>=5 ? .expired:.waiting
  }
}

@MainActor final class DisplayModeController:NSObject {
  typealias PauseCompletion=(Result<Void,Error>)->Void
#if TC_VIDEO_OFFMAIN
  private(set) var active=false {didSet{publishDelivery()}}
  private(set) var cleaning=false
  // The video reader thread checks "still delivering for this epoch?" once per frame. It used to
  // ask the main thread synchronously, so any main-thread work stalled the frame (measured as the
  // remaining 5ms p99 send-side tail). A lock-protected copy of (active, epoch) answers the same
  // question; stop() still flips it before returning, so no frame is accepted after a stop.
  private let deliveryLock=NSLock()
  private var deliverySnapshot:(active:Bool,epoch:UUID?)=(false,nil)
  private func publishDelivery(){deliveryLock.lock();deliverySnapshot=(active,epoch);deliveryLock.unlock()}
  fileprivate func deliveryAllowed(_ token:UUID)->Bool{deliveryLock.lock();defer{deliveryLock.unlock()};return deliverySnapshot.active && deliverySnapshot.epoch==token}
#else
  private(set) var active=false,cleaning=false
#endif
  var status:((String)->Void)?
  var userStopped:(()->Void)?
  var viewerOwnershipLost:(()->Void)?
  var sourceOwnershipViewer:DisplayViewer? {
    guard active,!sending,authenticatedAt != nil,inputBindingValid?()==true,let viewer,viewer.isOpenForSourceOwnership else{return nil}
    return viewer
  }
  var sharingSending:Bool? {active ? sending:nil}
  var sessionPermitted:(()->Bool)?
  #if TC_FRESH_RECEIVER_SAFETY
  var makeSafetyTicket:((UUID)->DisplaySafetyTicket?)?
  var currentSafetyTicket:((DisplaySafetyTicket)->Bool)?
  var sampledSessionPermitted:((FreshSessionSafetySample,DisplaySafetyTicket,Double)->Bool)?
  private var safetyTicket:DisplaySafetyTicket?
  private let periodicSafetyQueue=DispatchQueue(label:"ThunderControl.display.periodic-safety")
  private var periodicSafetyPending=DisplaySafetyPending()
  var periodicSafetySampler=FreshSessionSafetySampler()
  #endif
  var inputBindingValid:(()->Bool)?
  var inputBindingConflicts:(()->Bool)?
  var prepareInputTransition:((@escaping PauseCompletion)->Void)?
  var commitInputDisplay:((DisplayBaseline,CGDirectDisplayID)throws->Void)?
  var finishInputDisplay:((DisplayBaseline)throws->Void)?
  var abortInputTransition:(()->Void)?
  private var transport:DisplayTransport?,viewer:DisplayViewer?,helper:Process?,heartbeat:FileHandle?,timer:Timer?
  private var baseline:DisplayBaseline?,virtualID:CGDirectDisplayID?,expectedPair:LayoutDevicePair?
  private var observers:[(NotificationCenter,NSObjectProtocol)]=[]
#if TC_VIDEO_OFFMAIN
  private var epoch=UUID() {didSet{publishDelivery()}}
  private var sending=false,sourceReady=false,transitionEngaged=false,pausing=false,cleanupRunning=false,transitionFailed=false
#else
  private var epoch=UUID(),sending=false,sourceReady=false,transitionEngaged=false,pausing=false,cleanupRunning=false,transitionFailed=false
#endif
  private var receivedFirstFrame=false,authenticatedAt:Double?,networkRTT:Double?,lastStatsAt=0.0,started=0.0
  private var receivedVideo=0,lastReceivedVideo=0
  private var ownedMonitor=OwnedDisplayMonitor()
  private var videoFormat=DisplayVideoFormat.standard
  private let virtualPlacementStore=SavedVirtualDisplayPlacementStore()
  private var placementSession:VirtualDisplayPlacementSession?
  private var finalMessage=TCText("Screen connection ended. The existing input connection remains active.")
  var connected:Bool {active && authenticatedAt != nil && (sending ? sourceReady:receivedFirstFrame)}
  private var safe:Bool {sessionPermitted?() == true && sessionBlockReason(snapshot:readSystemSessionSnapshot(),lockedSignal:false,sleeping:false,secureInput:isSystemSecureInputEnabled()) == nil}
#if TC_QUALITY_TIERS
  var qualityExtensionEnabled=false
  private(set) var currentDisplayCodecName:String?
  private var qualityCommandPending=false,qualityCommandDirty=false
  private var lastRequestedCeiling:Int?
  private let helperQualityQueue=DispatchQueue(label:"ThunderControl.helper.quality")
  func requestQualitySettingsUpdate() {
    viewer?.setPresentationMode(DisplayQualityPreferences.presentation)
    let ceiling=DisplayQualityPreferences.maximumTier.rawValue
    if lastRequestedCeiling != ceiling {lastRequestedCeiling=ceiling;transport?.updateQualityCeiling(ceiling)}
    if active && !qualityExtensionEnabled {report("표시 방식은 적용했습니다. 품질 등급 변경은 양쪽 Mac에 새 버전이 필요합니다.")}
  }
  private func sendQualityCommand(_ ceiling:Int,token:UUID) {
    guard active,sending,epoch==token,(0...3).contains(ceiling),let pipe=heartbeat else{return}
    // Commands are rare, serialized and never make the frame reader wait for main.
    if qualityCommandPending {qualityCommandDirty=true;return}
    qualityCommandPending=true;qualityCommandDirty=false
    let heldTransport=transport
    helperQualityQueue.async {[weak self] in
      defer {DispatchQueue.main.async {
        guard let self,self.epoch==token else{return}
        self.qualityCommandPending=false
        if self.qualityCommandDirty {self.sendQualityCommand(ceiling,token:token)}
      }}
      guard self?.deliveryAllowed(token)==true,let latest=heldTransport?.agreedQuality else{return}
      do{try pipe.write(contentsOf:Data([UInt8(0x20+latest.ceiling)]))}
      catch{DispatchQueue.main.async {guard let self,self.active,self.epoch==token else{return};self.report("영상 품질 변경을 적용하지 못했습니다.")}}
    }
  }
  private func observeQuality(_ data:Data) {
    guard let tier=DisplayQualityCapabilities.tier(in:data),let value=DisplayQualityTier(rawValue:tier),currentDisplayCodecName != value.wireCodecName else{return}
    currentDisplayCodecName=value.wireCodecName
    report("현재 영상: \(value.codecDisplayName)")
  }
#endif
  private func report(_ text:String){status?(text);connectionLog("Display: "+text)}
  func start(sending:Bool,peer:String,expectedPair:LayoutDevicePair)throws {
    guard #available(macOS 14.0,*) else{throw Failure(TCText("Extended display requires macOS 14 or later."))}
    guard !active,!cleaning,safe,inputBindingValid?()==true else{throw Failure(TCText("First complete the input connection between the same two Macs and wait for display restoration. Both Macs require 0.8.22 or later."))}
    if sending {guard DisplayPeerRoute.valid(peer) else{throw Failure(TCText("Check the MacBook's Thunderbolt IPv4 address."))}}
    guard let original=DisplayBaseline.read(),original.supported else{throw Failure(TCText("Verify a valid receiving display configuration, then restart."))}
    if sending {guard CGPreflightScreenCaptureAccess() else{throw Failure(TCText("Allow Screen Recording on the Mac mini."))}}
    self.sending=sending;self.expectedPair=expectedPair;baseline=original;active=true;epoch=UUID();ownedMonitor=OwnedDisplayMonitor();placementSession=nil
    let token=epoch;sourceReady=false;transitionEngaged=false;transitionFailed=false;receivedFirstFrame=false;authenticatedAt=nil;networkRTT=nil;receivedVideo=0;lastReceivedVideo=0;started=ProcessInfo.processInfo.systemUptime;lastStatsAt=started
    let viewerTarget = sending ? nil : DisplayViewerTarget.read()
    let t=DisplayTransport();transport=t
#if TC_QUALITY_TIERS
    currentDisplayCodecName=nil;qualityCommandPending=false;qualityCommandDirty=false;lastRequestedCeiling=DisplayQualityPreferences.maximumTier.rawValue;t.qualityExtensionEnabled=qualityExtensionEnabled
    t.onQualityLimitChange={[weak self] ceiling in self?.sendQualityCommand(ceiling,token:token)}
#endif
    #if TC_FRESH_RECEIVER_SAFETY
    // Fixed immutable ticket is captured before transport start, not per packet.
    guard let fixedSafetyTicket=makeSafetyTicket?(token),fixedSafetyTicket.displayEpoch==token else {
      stop(message:TCText("Screen transmission stopped because the session's safety state changed."));throw Failure("Display safety ticket unavailable")
    }
    safetyTicket=fixedSafetyTicket
    #endif
    t.onAuthenticated = {[weak self] format in
      guard let self,self.active,self.epoch==token else{return}
      guard self.inputBindingValid?()==true else{self.stop(message:TCText("Screen startup canceled because the authenticated input peer changed."));return}
      guard format.valid else {self.stop(message:TCText("Could not agree on a video resolution."));return}
      self.videoFormat=format
      self.authenticatedAt=ProcessInfo.processInfo.systemUptime
      if sending {
        self.report(TCText("Preparing to add a screen while keeping the input connection. Release all keys and buttons, and lift your fingers off the trackpad."))
        self.requestInputPause {[weak self] in
          guard let self else{return}
          guard self.active,self.epoch==token else{if self.cleaning{self.cleanUpHelper()};return}
          guard !self.transitionFailed else{self.stop(message:TCText("Screen startup canceled because input release could not be confirmed. Check the input connection."));return}
          do {try self.launchHelper(token:token)}catch{self.stop(message:TCText("Could not start the extended display helper."))}
        }
      } else {
        let v=DisplayViewer(format:format,targetScreen:viewerTarget?.screen,diagnosticStream:self.transport?.diagnosticStreamID);v.acceptsViewerInput=false
#if TC_DEADLINE_PRESENTATION
        v.maySubmitPresentation = { [weak owner = self, weak transport = t] in
          guard let owner, let transport else { return false }
          return owner.active && owner.epoch == token && owner.transport === transport &&
            owner.safetyTicket == fixedSafetyTicket && owner.currentSafetyTicket?(fixedSafetyTicket) == true
        }
#endif
        v.onUserClose={[weak self] in self?.userStopped?()}
        v.onClose={[weak self] in guard let self,self.epoch==token else{return};self.stop()}
        v.onWillClose={[weak self] in self?.viewerOwnershipLost?()}
        v.onFocusLost={[weak self] in self?.viewerOwnershipLost?()}
        self.viewer=v;v.show();self.report(TCText("Screen authentication complete. Using the existing MacBook → Mac mini input connection."))
      }
    }
    #if TC_FRESH_RECEIVER_SAFETY
    t.onPayload = {[weak self,weak t] data,sample in
      guard let self,let t,self.active,self.epoch==token,self.transport === t,
        self.safetyTicket==fixedSafetyTicket else{return}
      let guardStartedAt=ProcessInfo.processInfo.systemUptime
      let payloadSafe=self.sampledSessionPermitted?(sample,fixedSafetyTicket,guardStartedAt)==true
      let guardFinishedAt=ProcessInfo.processInfo.systemUptime
      let guardMs=(guardFinishedAt-guardStartedAt)*1000
      // elapsedMs retains main guard duration meaning, not worker/query time.
      // sampleToAcceptMs starts before the snapshot read and ends at acceptance gate.
      if guardMs>=2 || sample.sampleWorkerMs>=2,let stream=t.diagnosticStreamID {
        let sequence=data.first==6 ? (try? DisplayStreamFrameHeader(data))?.sequence:nil
        DevelopmentDiagnostics.shared.record(stage:"receiver_guard_slow",sequence:sequence,fields:["kind":Double(data.first ?? 255),"elapsedMs":guardMs,"startedAt":guardStartedAt,"time":guardFinishedAt,"allowed":payloadSafe ? 1:0,"sampleWorkerMs":sample.sampleWorkerMs,"snapshotMs":sample.snapshotMs,"secureMs":sample.secureMs,"mainEvalMs":guardMs,"sampleToAcceptMs":(guardFinishedAt-sample.startedAt)*1000],stream:stream)
      }
      // Recheck epoch, transport and current latches immediately before both
      // acceptance and an unsafe stop, so old completions cannot stop a new run.
      guard self.active,self.epoch==token,self.transport === t,self.safetyTicket==fixedSafetyTicket else{return}
      guard payloadSafe,self.currentSafetyTicket?(fixedSafetyTicket)==true,sample.valid(at:guardFinishedAt),guardFinishedAt>=guardStartedAt else {
        self.stop(message:TCText("Screen transmission stopped because the session's safety state changed."));return
      }
      guard !sending else{self.stop(message:TCText("Received data not allowed on the video-only channel."));return}
      if data.first==7 {
        do {try self.viewer?.acceptCursor(data)} catch {self.stop(message:TCText("Invalid screen video frame."))};return
      }
#if TC_QUALITY_TIERS
      self.observeQuality(data)
#endif
      if data.first==2 || data.first==6 {
        do {guard let viewer=self.viewer else{throw DisplayVideoError.decoderFailed};try viewer.accept(data,guardMilliseconds:guardMs);self.receivedFirstFrame=true;self.receivedVideo+=1}
        catch{self.stop(message:TCText("Could not decode incoming video. This video error is separate from the input connection."))}
      }
    }
    #else
    t.onPayload = {[weak self] data in
      guard let self,self.active,self.epoch==token else{return}
      // Keep the safety query and gate in their original order, once per payload.
      let guardStartedAt=ProcessInfo.processInfo.systemUptime
      let payloadSafe=self.safe
      let guardFinishedAt=ProcessInfo.processInfo.systemUptime
      let guardMs=(guardFinishedAt-guardStartedAt)*1000
      if guardMs>=2,let stream=self.transport?.diagnosticStreamID {
        let sequence=data.first==6 ? (try? DisplayStreamFrameHeader(data))?.sequence:nil
        DevelopmentDiagnostics.shared.record(stage:"receiver_guard_slow",sequence:sequence,fields:["kind":Double(data.first ?? 255),"elapsedMs":guardMs,"startedAt":guardStartedAt,"time":guardFinishedAt,"allowed":payloadSafe ? 1:0],stream:stream)
      }
      guard payloadSafe else{self.stop(message:TCText("Screen transmission stopped because the session's safety state changed."));return}
      guard !sending else{self.stop(message:TCText("Received data not allowed on the video-only channel."));return}
      if data.first==7 {
        do {try self.viewer?.acceptCursor(data)} catch {self.stop(message:TCText("Invalid screen video frame."))};return
      }
#if TC_QUALITY_TIERS
      self.observeQuality(data)
#endif
      if data.first==2 || data.first==6 {
        do {guard let viewer=self.viewer else{throw DisplayVideoError.decoderFailed};try viewer.accept(data,guardMilliseconds:guardMs);self.receivedFirstFrame=true;self.receivedVideo+=1}
        catch{self.stop(message:TCText("Could not decode incoming video. This video error is separate from the input connection."))}
      }
    }
    #endif
    t.onLatency = {[weak self] value in guard let self,self.active,self.epoch==token else{return};self.networkRTT=value.flatMap{$0.isFinite ? $0:nil}}
    t.onFailure = {[weak self] text in guard let self,self.epoch==token else{return};self.stop(message:text)}
    for name in [NSWorkspace.willSleepNotification,NSWorkspace.sessionDidResignActiveNotification,NSWorkspace.screensDidSleepNotification] {
      let center=NSWorkspace.shared.notificationCenter
      let observer=center.addObserver(forName:name,object:nil,queue:.main){[weak self] _ in MainActor.assumeIsolated{guard let self,self.epoch==token else{return};self.stop(message:TCText("Screen transmission stopped due to sleep or a session change."))}}
      observers.append((center,observer))
    }
    let center=DistributedNotificationCenter.default()
    let observer=center.addObserver(forName:NSNotification.Name("com.apple.screenIsLocked"),object:nil,queue:.main){[weak self] _ in MainActor.assumeIsolated{guard let self,self.epoch==token else{return};self.stop(message:TCText("Screen transmission stopped because the screen locked."))}}
    observers.append((center,observer))
    timer=Timer.scheduledTimer(withTimeInterval:0.5,repeats:true){[weak self] _ in MainActor.assumeIsolated{guard let self,self.epoch==token else{return};self.tick()}}
    if let timer {RunLoop.main.add(timer,forMode:.common)}
    do {try t.start(sending:sending,peer:peer,expectedPair:expectedPair,viewerFormat:viewerTarget?.format ?? .standard)}catch{stop(message:safeConnectionError(error));throw error}
    report(sending ? TCText("Authenticating the same MacBook as the existing input connection on the screen channel."):TCText("Waiting for a screen connection. The existing input connection remains active."))
  }
  private func requestInputPause(_ completion:@escaping()->Void) {
    guard let prepareInputTransition else{transitionFailed=true;completion();return}
    pausing=true;transitionEngaged=true
    prepareInputTransition {[weak self] result in
      guard let self else{return};self.pausing=false
      if case .failure(let error)=result {connectionLog("Display input barrier failed: "+safeConnectionError(error));self.transitionFailed=true;self.abortInputTransition?()}
      completion()
    }
  }
  #if TC_FRESH_RECEIVER_SAFETY
  // Receiver safety queries alone move off main. Raw Relay input timers,
  // topology/permission queries, startup and sending/helper checks remain unchanged.
  // This does NOT promise a stall-free main thread or atomic OS/session state.
  private func periodicSafetyContextCurrent(ticket:DisplaySafetyTicket,token:UUID,expectedTransport:DisplayTransport?)->Bool {
    active && epoch==token && ticket.displayEpoch==token && transport === expectedTransport && safetyTicket==ticket
  }
  private func completePeriodicSafety(_ sample:FreshSessionSafetySample,ticket:DisplaySafetyTicket,token:UUID,expectedTransport:DisplayTransport?,pending:UUID) {
    guard periodicSafetyPending.finish(pending),periodicSafetyContextCurrent(ticket:ticket,token:token,expectedTransport:expectedTransport) else{return}
    let now=ProcessInfo.processInfo.systemUptime
    guard sampledSessionPermitted?(sample,ticket,now)==true else {
      // Shared production completion fence: retired unsafe samples cannot stop
      // replacement sessions, even if an injected evaluator reenters/restarts.
      guard periodicSafetyContextCurrent(ticket:ticket,token:token,expectedTransport:expectedTransport) else{return}
      stop(message:TCText("Screen transmission stopped due to locking or a safety state change."));return
    }
    // Success is discarded, never cached or used to authorize payloads.
  }
  static func verifyPeriodicSafetyForTests()->Bool {
    let controller=DisplayModeController()
    let entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0)
    let countLock=NSLock();var queries=0,evaluations=0
    controller.periodicSafetySampler=FreshSessionSafetySampler(snapshot:{
      countLock.lock();queries+=1;countLock.unlock()
      entered.signal();_ = release.wait(timeout:.now()+10)
      return .init(onConsole:nil,loginDone:nil,screenLocked:nil)
    },secure:{false})
    func arm()->DisplaySafetyTicket {
      controller.active=true;controller.epoch=UUID();controller.transport=DisplayTransport()
      let ticket=DisplaySafetyTicket(relayGeneration:UUID(),safetyRevision:UUID(),displayEpoch:controller.epoch)
      controller.safetyTicket=ticket;return ticket
    }
    controller.sampledSessionPermitted={_,_,_ in evaluations+=1;return false}
    let old=arm();controller.schedulePeriodicSafety(ticket:old)
    guard entered.wait(timeout:.now()+2) == .success else{release.signal();return false}
    defer{release.signal();controller.stop()}
    controller.stop() // Actual receiver stop, no GUI/helper/native OS hooks.
    let replacement=arm(),replacementEpoch=controller.epoch
    for _ in 0..<8 {controller.schedulePeriodicSafety(ticket:replacement)}
    countLock.lock();let onePending=queries==1;countLock.unlock()
    var pumped=false;DispatchQueue.main.async{pumped=true}
    release.signal()
    let deadline=Date(timeIntervalSinceNow:2)
    while (!pumped || controller.periodicSafetyPending.token != nil) && Date()<deadline {
      _ = RunLoop.current.run(mode:.default,before:Date(timeIntervalSinceNow:0.005))
    }
    guard onePending,pumped,controller.periodicSafetyPending.token==nil,controller.active,
      controller.epoch==replacementEpoch,evaluations==0 else{return false}
    // A new healthy schedule may proceed after the retired query really returns.
    controller.periodicSafetySampler=FreshSessionSafetySampler(snapshot:{
      countLock.lock();queries+=1;countLock.unlock()
      return .init(onConsole:true,loginDone:true,screenLocked:false)
    },secure:{false})
    controller.sampledSessionPermitted={_,_,_ in evaluations+=1;return true}
    controller.schedulePeriodicSafety(ticket:replacement)
    let healthyDeadline=Date(timeIntervalSinceNow:2)
    while controller.periodicSafetyPending.token != nil && Date()<healthyDeadline {
      _ = RunLoop.current.run(mode:.default,before:Date(timeIntervalSinceNow:0.005))
    }
    countLock.lock();let twoQueries=queries==2;countLock.unlock()
    guard controller.active,controller.epoch==replacementEpoch,evaluations==1,twoQueries,controller.periodicSafetyPending.token==nil else{return false}
    // Exercise the SAME production completion after an evaluator reenters and
    // replaces the controller epoch before returning an unsafe result.
    let pending=controller.periodicSafetyPending.begin()!,oldTransport=controller.transport
    let now=ProcessInfo.processInfo.systemUptime
    let unsafe=FreshSessionSafetySample(snapshot:.init(onConsole:nil,loginDone:nil,screenLocked:nil),secureInput:false,startedAt:now,snapshotFinishedAt:now,finishedAt:now)
    var reentrantEpoch:UUID?
    controller.sampledSessionPermitted={_,_,_ in reentrantEpoch=arm().displayEpoch;return false}
    controller.completePeriodicSafety(unsafe,ticket:replacement,token:replacementEpoch,expectedTransport:oldTransport,pending:pending)
    return controller.active && controller.epoch==reentrantEpoch && controller.epoch != replacementEpoch
  }
  private func schedulePeriodicSafety(ticket:DisplaySafetyTicket) {
    guard let pending=periodicSafetyPending.begin() else{return}
    let token=epoch,sampler=periodicSafetySampler
    let expectedTransport=transport
    periodicSafetyQueue.async {[weak self] in
      let sample=sampler.sample()
      DispatchQueue.main.async {
        self?.completePeriodicSafety(sample,ticket:ticket,token:token,expectedTransport:expectedTransport,pending:pending)
      }
    }
  }
  #endif
  private func tick() {
    guard active else{return}
    #if TC_FRESH_RECEIVER_SAFETY
    if sending {
      guard safe else{stop(message:TCText("Screen transmission stopped due to locking or a safety state change."));return}
    } else {
      guard let ticket=safetyTicket,currentSafetyTicket?(ticket)==true else {
        stop(message:TCText("Screen transmission stopped due to locking or a safety state change."));return
      }
      schedulePeriodicSafety(ticket:ticket)
    }
    #else
    guard safe else{stop(message:TCText("Screen transmission stopped due to locking or a safety state change."));return}
    #endif
    if inputBindingConflicts?()==true {stop(message:TCText("The input peer changed. Closing the previous peer's video connection."));return}
    let now=ProcessInfo.processInfo.systemUptime
    if connected,now-lastStatsAt>=2 {
      let rate=Double(receivedVideo-lastReceivedVideo)/(now-lastStatsAt);lastReceivedVideo=receivedVideo;lastStatsAt=now
      let latency=networkRTT.map{String(format:TCText("Video channel round trip %.1fms"),$0)} ?? TCText("Measuring video latency")
      status?(sending ? TCText("Sending Mac mini → MacBook screen / ")+latency : String(format:TCText("Receiving Mac mini screen / %@ / recent %.0f fps"),latency,rate))
    }
    if !sending,let authenticatedAt,!receivedFirstFrame,now-authenticatedAt>30 {stop(message:TCText("Video connection stopped because the first video frame did not arrive."));return}
    if sending,helper != nil {
      guard CGPreflightScreenCaptureAccess() else{stop(message:TCText("Video transmission stopped because Screen Recording permission is missing."));return}
      if let id=virtualID {
        if ownedMonitor.observe(DisplayBaseline.read(),ownedID:id,now:now) == .expired {
          stop(message:TCText("Video transmission stopped because a valid configuration for the app-owned extended display could not be confirmed."));return
        }
        captureVirtualPlacement(now:now)
        // While native enumeration settles, keep heartbeat alive. Capture is
        // independently paused by the helper, never redirected to a physical screen.
      } else if now-started>25 {stop(message:TCText("Extended display creation timed out."));return}
      do{try heartbeat?.write(contentsOf:Data([1]))}catch{stop(message:TCText("The extended display helper exited."))}
    }
  }
  private func launchHelper(token:UUID)throws {
    guard active,safe,inputBindingValid?()==true,let url=Bundle.main.url(forAuxiliaryExecutable:"ThunderDisplaySender") else{throw Failure(TCText("Could not verify the display helper or input connection."))}
    var arguments=["--stream","--size",String(videoFormat.width),String(videoFormat.height),"--scale",String(videoFormat.pixelScale)]
    if let pair=expectedPair {
      let physical=try? readReceiverDesktop(revision:1)
      let origin=physical.flatMap{virtualPlacementStore.restored(for:pair,size:videoFormat.size,physicalDesktop:$0)}
      placementSession=VirtualDisplayPlacementSession(pair:pair,requestedOrigin:origin,hadSaved:virtualPlacementStore.hasSaved(for:pair))
      // Keep requestedOrigin as the actual saved restore, so an obstructed old
      // record is not overwritten merely because the default was used this run.
      let requested=origin ?? physical?.defaultOwnedVirtualOrigin(size:videoFormat.size)
      if let requested {arguments += ["--origin",String(Int(requested.x)),String(Int(requested.y))]}
    }
#if TC_VIDEO_SOCKETPAIR
    // Video leaves the helper through a socket pair with multi-MB buffers instead of a 64KB pipe:
    // a ~1MB ProRes frame then goes over in one write rather than ~16 writer/reader handoffs,
    // which measured as a 6-8ms p99 tail between encode completion and the network send.
    // Cursor messages (23 bytes) stay whole: Darwin stream sockets refuse rather than split a
    // write when less than the 2KB low-water mark is free.
    var videoFDs:[Int32]=[-1,-1]
    guard socketpair(AF_UNIX,SOCK_STREAM,0,&videoFDs)==0 else{throw Failure("Video channel setup failed")}
    var channelBuffer:Int32=4*1024*1024
    for fd in videoFDs {
      _=setsockopt(fd,SOL_SOCKET,SO_SNDBUF,&channelBuffer,socklen_t(MemoryLayout<Int32>.size))
      _=setsockopt(fd,SOL_SOCKET,SO_RCVBUF,&channelBuffer,socklen_t(MemoryLayout<Int32>.size))
    }
    let process=Process(),input=Pipe(),output=FileHandle(fileDescriptor:videoFDs[0],closeOnDealloc:true),errors=Pipe();process.executableURL=url;process.arguments=arguments;process.standardInput=input;process.standardOutput=FileHandle(fileDescriptor:videoFDs[1],closeOnDealloc:false);process.standardError=errors

#if TC_QUALITY_TIERS
    var environment=ProcessInfo.processInfo.environment
    let quality=transport?.agreedQuality
    environment["TC_VIDEO_CODECS"]=quality?.codecNames.joined(separator:",") ?? "h264"
    environment["TC_VIDEO_INITIAL_TIER"]=String(quality?.ceiling ?? 0)
    process.environment=environment
#endif
    do {try process.run()} catch {close(videoFDs[1]);throw error}
    close(videoFDs[1]) // The helper holds its own copy; EOF must follow the helper's exit.
    helper=process;
#else
    let process=Process(),input=Pipe(),output=Pipe(),errors=Pipe();process.executableURL=url;process.arguments=arguments;process.standardInput=input;process.standardOutput=output;process.standardError=errors
    try process.run();helper=process;
#endif
heartbeat=input.fileHandleForWriting;try heartbeat?.write(contentsOf:Data([1]))
#if TC_QUALITY_TIERS
    // Session-start ceiling was passed via environment before process.run().
#endif
    let diagnosticStream=transport?.diagnosticStreamID
    DispatchQueue.global(qos:.utility).async {
      let handle=errors.fileHandleForReading;defer{try? handle.close()};var lines=DisplayDiagnosticLines()
      let raw:(String)->Void = {DevelopmentDiagnostics.shared.recordHelperLine($0,stream:diagnosticStream)}
      // Only diagnostic work gets new pool boundaries; video pipeline is unchanged.
      while (try? autoreleasepool { () throws -> Bool in
        guard let chunk=try handle.read(upToCount:1024),!chunk.isEmpty else{return false}
        lines.append(chunk,now:ProcessInfo.processInfo.systemUptime,emit:connectionLog,raw:raw);return true
      }) == true {}
      lines.finish(now:ProcessInfo.processInfo.systemUptime,emit:connectionLog,raw:raw)
    }
    let t=transport
    DispatchQueue.global(qos:.userInitiated).async {[weak self] in
#if TC_VIDEO_SOCKETPAIR
      let handle=output;defer{try? handle.close()}
      // One reusable buffer and large reads: a frame costs one copy into Data, not repeated appends.
      let fd=handle.fileDescriptor;var buffer=[UInt8](repeating:0,count:4194304)
      func exact(_ size:Int)throws->Data {
        var got=0
        while got<size {
          let n=buffer.withUnsafeMutableBytes{Darwin.read(fd,$0.baseAddress!+got,size-got)}
          if n>0 {got+=n} else if n<0 && errno==EINTR {continue} else {throw Failure("Video pipe ended")}
        }
        return Data(buffer[0..<size])
      }
#else
      let handle=output.fileHandleForReading;defer{try? handle.close()}
      func exact(_ size:Int)throws->Data {var data=Data();while data.count<size {guard let part=try handle.read(upToCount:size-data.count),!part.isEmpty else{throw Failure("Video pipe ended")};data.append(part)};return data}
#endif
      var deliveryFailed=false
#if TC_QUALITY_TIERS
      var lastTier:Int?
#endif
      do {while true {
        let header=try exact(4),size=header.reduce(UInt32(0)){($0<<8)|UInt32($1)}
        guard size>0,size<=4194304 else{throw Failure("Invalid video framing")}
        let payload=try exact(Int(size))
        if payload.first==6,let frame=try? DisplayStreamFrameHeader(payload),let diagnosticStream{
          DevelopmentDiagnostics.shared.record(stage:"helper_read",sequence:frame.sequence,fields:["bytes":Double(payload.count),"sourceCaptureUS":Double(frame.capture),"sourceEncodeStartUS":Double(frame.encodeStart),"sourceEncodeEndUS":Double(frame.encodeEnd)],stream:diagnosticStream)
        }
        // Keep draining the helper even after its independent video socket closes.
        // Removing the owned display must wait for the raw-input pause barrier.
#if TC_VIDEO_OFFMAIN
        let deliver=self?.deliveryAllowed(token)==true
#else
        let deliver=DispatchQueue.main.sync {self?.active==true && self?.epoch==token}
#endif
        if !deliver || deliveryFailed {continue}
#if TC_QUALITY_TIERS
        if let tier=DisplayQualityCapabilities.tier(in:payload),tier != lastTier {
          lastTier=tier
          DispatchQueue.main.async {guard let self,self.active,self.epoch==token else{return};self.observeQuality(payload)}
        }
#endif
        if payload.first==1 {
          guard payload.count==5 else{throw Failure("Invalid owned display identity")}
          let id=payload.dropFirst().reduce(UInt32(0)){($0<<8)|UInt32($1)}
          try DispatchQueue.main.sync {
            guard let self else{return}
            guard self.active,self.epoch==token else{return}
            guard let original=self.baseline,let commit=self.commitInputDisplay else{throw Failure("Missing display input coordinator")}
            guard let current=DisplayBaseline.read(),let index=current.ids.firstIndex(of:id),
              current.rectangles[index].size==self.videoFormat.size,let mode=CGDisplayCopyDisplayMode(id),
              mode.width==self.videoFormat.width,mode.height==self.videoFormat.height,
              mode.pixelWidth==self.videoFormat.pixelWidth,mode.pixelHeight==self.videoFormat.pixelHeight else {throw Failure("Owned display format mismatch")}
            try commit(original,id);self.virtualID=id;self.sourceReady=true
            self.captureVirtualPlacement(now:ProcessInfo.processInfo.systemUptime)
            self.report(TCText("Both connections active: MacBook → Mac mini input maintained / Mac mini → MacBook screen transmission"))
          }
        } else {guard payload.first==6 || payload.first==7 else{throw Failure("Unexpected helper packet")}}
        do {guard let t else{throw Failure("Video transport retired")};try t.send(payload)}
        catch {deliveryFailed=true;DispatchQueue.main.async{guard let self,self.active,self.epoch==token else{return};self.stop(message:TCText("Video connection ended. Cleaning up the display while keeping the input connection."))}}
      }}catch{DispatchQueue.main.async{guard let self,self.active,self.epoch==token else{return};self.stop(message:TCText("Screen transmission stopped because the video helper or extended display setup failed."))}}
    }
  }
  private func captureVirtualPlacement(now:Double,force:Bool=false) {
    guard sending,active,sourceReady,let id=virtualID,placementSession != nil,
      let map=try? readReceiverDesktop(revision:1,virtualDisplayID:id),
      let sample=VirtualDisplayPlacementSample(desktop:map,ownedID:id,format:videoFormat) else{return}
    _ = placementSession?.observe(sample,now:now,store:virtualPlacementStore,force:force)
  }
  func stop(message:String=TCText("Screen connection ended. The existing input connection remains active.")) {
    guard active || cleaning else{return}
    if cleaning {if !pausing && !cleanupRunning{cleanUpHelper()};return}
    captureVirtualPlacement(now:ProcessInfo.processInfo.systemUptime,force:true)
#if TC_QUALITY_TIERS
    currentDisplayCodecName=nil
#endif
    finalMessage=message;active=false;cleaning=true;epoch=UUID();timer?.invalidate();timer=nil
    for (center,observer) in observers{center.removeObserver(observer)};observers=[]
    #if TC_FRESH_RECEIVER_SAFETY
    safetyTicket=nil // Do not clear outstanding periodic work until it completes.
    #endif
    transport?.stop();transport=nil;viewer?.onClose=nil;viewer?.close();viewer=nil
    report(TCText("Preparing to end the screen connection. Release all keys and buttons. Cleaning up the existing input connection."))
    if sending,helper != nil {
      timer=Timer.scheduledTimer(withTimeInterval:0.5,repeats:true){[weak self] _ in MainActor.assumeIsolated{
        guard let self,self.cleaning,!self.cleanupRunning else{return}
        do {try self.heartbeat?.write(contentsOf:Data([1]))}
        catch {self.transitionFailed=true;self.abortInputTransition?();if !self.pausing{self.cleanUpHelper()}}
      }}
      if let timer {RunLoop.main.add(timer,forMode:.common)}
    }
    guard sending else{baseline=nil;cleaning=false;report(message);return}
    if pausing{return}
    if sourceReady {requestInputPause{[weak self] in self?.cleanUpHelper()}}
    else {cleanUpHelper()}
  }
  private func cleanUpHelper() {
    guard cleaning,!pausing,!cleanupRunning else{return};cleanupRunning=true;timer?.invalidate();timer=nil
    try? heartbeat?.close();heartbeat=nil
    let process=helper;helper=nil;let original=baseline,retiredDisplayID=virtualID;virtualID=nil;sourceReady=false;placementSession=nil
    if let process,process.isRunning{process.terminate()}
    DispatchQueue.global(qos:.utility).async {[weak self] in
      if let process {for _ in 0..<20{if !process.isRunning{break};Thread.sleep(forTimeInterval:0.1)};if process.isRunning{kill(process.processIdentifier,SIGKILL)};process.waitUntilExit()}
      var restored=false
      // Check only retirement of the owned display and a valid current OS map.
      // Never restore an old physical layout over the user's later OS edits.
      for _ in 0..<40 {
        if let current=DisplayBaseline.read(),current.supported {
          if let id=retiredDisplayID {restored = !current.ids.contains(id)}
          else if let original {restored = Set(current.ids).isSubset(of:Set(original.ids))}
          if restored {break}
        }
        Thread.sleep(forTimeInterval:0.25)
      }
      DispatchQueue.main.async {
        guard let self else{return};self.cleanupRunning=false
        guard restored,let original else{self.abortInputTransition?();self.report(TCText("Input stopped for safety because restoration of the original display configuration could not be confirmed. Click Stop Screen Sharing again to check."));return}
        if self.transitionEngaged {
          do {guard let finish=self.finishInputDisplay else{throw Failure("Missing input restoration")};try finish(original)}
          catch {self.transitionFailed=true;self.abortInputTransition?();try? self.finishInputDisplay?(original)}
        }
        self.baseline=nil;self.cleaning=false;self.transitionEngaged=false
        self.report(self.transitionFailed ? TCText("The display was restored, but the input transition could not be confirmed. Check the input connection again."):self.finalMessage)
      }
    }
  }
}

@MainActor extension App {
  func installDisplaySharing() {
    screenPermissionButton.target=self;screenPermissionButton.action=#selector(displayPermission)
    receiveSection.addArrangedSubview(screenPermissionButton)
    relay.displayPreferenceChanged={[weak self] enabled in self?.sharingReceivedDisplayPreference(enabled)}
    #if TC_FRESH_RECEIVER_SAFETY
    displayMode.makeSafetyTicket={[weak self] epoch in self?.relay.displaySafetyTicket(epoch:epoch)}
    displayMode.currentSafetyTicket={[weak self] ticket in self?.relay.displaySafetyTicketCurrent(ticket)==true}
    displayMode.sampledSessionPermitted={[weak self] sample,ticket,now in self?.relay.sampledDisplaySessionPermitted(sample,ticket:ticket,now:now)==true}
    #endif
    displayMode.sessionPermitted={[weak self] in guard let self else{return false};return self.relay.sessionAllowed && !self.relay.screenSleeping && !self.relay.systemSleeping && self.relay.multiDisplayDesktopReady}
    displayMode.prepareInputTransition={[weak self] completion in guard let self else{completion(.failure(Failure("Input owner unavailable")));return};self.relay.beginDisplayTopologyTransition(completion:completion)}
    displayMode.commitInputDisplay={[weak self] original,id in guard let self else{throw Failure("Input owner unavailable")};try self.relay.commitDisplayTopology(original:original,ownedID:id)}
    displayMode.finishInputDisplay={[weak self] original in guard let self else{throw Failure("Input owner unavailable")};try self.relay.finishDisplayTopologyRemoval(original:original)}
    displayMode.abortInputTransition={[weak self] in self?.relay.abortDisplayTopologyTransition()}
    displayMode.userStopped={[weak self] in self?.sharingUserStoppedVideo()}
    displayMode.status={[weak self] text in guard let self else{return};self.displayStatus.stringValue=text;self.updateConnectionState();self.connectButton.isEnabled = !self.relay.hasSession && !self.displayMode.cleaning;self.mode.isEnabled = !self.displayMode.active && !self.displayMode.cleaning;self.sharingDisplayStatusDidChange()
#if TC_QUALITY_TIERS
      self.refreshDisplayQualityUI()
#endif
    }
  }
  func beginDisplay(sending:Bool) {
    // Automatic resume must not reopen video while the user is quitting.
    guard !applicationIsQuitting else{return}
    guard !displayMode.active,!displayMode.cleaning else{return}
    guard relay.displayPreferenceCompatible else{displayStatus.stringValue=TCText("Automatic virtual display requires 0.8.28 or later on both Macs.");return}
    guard let pair=relay.authenticatedDevicePair,relay.authenticated,relay.inputIsSender == !sending else{displayStatus.stringValue=TCText("First complete the input connection: Sender on the MacBook → Receiver on the Mac mini. The existing connection has not been changed.");return}
    guard relay.multiDisplayDesktopReady else{displayStatus.stringValue=TCText("Integrated screen mapping requires 0.8.22 or later on both Macs. The existing input connection remains active.");return}
    guard let destination=relay.authenticatedSharingPeerHost,DisplayPeerRoute.valid(destination) else{displayStatus.stringValue=TCText("Waiting for the authenticated peer route.");return}
    displayMode.inputBindingConflicts={[weak self] in guard let self,let current=self.relay.authenticatedDevicePair else{return false};return current != pair || self.relay.inputIsSender != !sending}
    displayMode.inputBindingValid={[weak self] in guard let self else{return false};return self.relay.authenticated && self.relay.authenticatedDevicePair==pair && self.relay.inputIsSender == !sending}
#if TC_QUALITY_TIERS
    displayMode.qualityExtensionEnabled=relay.peerVideoQualityCompatible
#endif
    do{try displayMode.start(sending:sending,peer:destination,expectedPair:pair)}catch{displayStatus.stringValue=safeConnectionError(error)}
  }
  @objc func sendDisplay(){sharingUserRequestedVideo(sending:true);beginDisplay(sending:true)}
  @objc func receiveDisplay(){sharingUserRequestedVideo(sending:false);beginDisplay(sending:false)}
  @objc func stopDisplay(){sharingUserStoppedVideo();displayMode.stop()}
  @objc func displayPermission(){if !CGPreflightScreenCaptureAccess(){_ = CGRequestScreenCaptureAccess()};openPermissionSettings("Privacy_ScreenCapture")}
}
