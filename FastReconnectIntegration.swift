import AppKit
func routeIdentityMatches(_ actual:LayoutDevicePair,expected:LayoutDevicePair?)->Bool {expected==nil || actual==expected}
@MainActor extension App {
  func tryFastAuthenticatedRoute(locked:Bool)->Bool {
    guard !isAutomationTest,!fastRouteTried,discoveredPeers.count<=1,
      let stored=UserDefaults.standard.string(forKey:"ThunderControl.autoTrust.deviceID.v1"),let local=UUID(uuidString:stored),
      let hint=fastRoutes.load(localID:local),discoveredPeers.isEmpty || discoveredPeers.first?.ipv4==hint.ipv4 else{return false}
    fastRouteTried=true;fastRouteInProgress=true
    nextAutomaticAttempt=ProcessInfo.processInfo.systemUptime+5
    do {
      // Exactly one TCP attempt. Bonjour is metadata-only and cannot authorize input.
      let verified=try relay.start(name:"bridge0",peer:hint.ipv4,pass:"",port:hint.port,sendMode:true,automaticStart:true,lockedTransport:locked,lockedPermitEpoch:sessionAutoResume.epoch,expectedRoutePair:hint.pair)
      startPeerBrowsing(verified:verified)
    } catch {
      fastRouteInProgress=false
      if !relay.automaticReconnectSuspended && !automaticConnectionPaused {nextAutomaticAttempt=0;nextDiscoveryAttempt=0;requestAutomaticConnectionTick()}
      relay.status(TCText("Saved route unreachable: switching to peer discovery on the verified bridge."))
    }
    return true
  }
  func handleFastRouteDisconnect() {
    let fast=fastRouteInProgress;fastRouteInProgress=false
    if !fast || relay.automaticReconnectSuspended || automaticConnectionPaused {discovery.stop();discoveryIsBrowsing=false}
    if fast && !relay.automaticReconnectSuspended && !automaticConnectionPaused {nextAutomaticAttempt=0;nextDiscoveryAttempt=0}
  }
}
func runFastReconnectPolicyTests()->Int {
  var n=0,f=0;func check(_ ok:Bool){n+=1;if !ok{f+=1}}
  let local=UUID().uuidString,a=UUID().uuidString,b=UUID().uuidString
  let pair=LayoutDevicePair(localID:local,peerID:a)!,other=LayoutDevicePair(localID:local,peerID:b)!,otherLocal=LayoutDevicePair(localID:b,peerID:a)!
  check(routeIdentityMatches(pair,expected:pair));check(routeIdentityMatches(pair,expected:nil));check(!routeIdentityMatches(other,expected:pair));check(!routeIdentityMatches(otherLocal,expected:pair))
  check(!shouldSuspendAutomaticReconnect(stage:"Trusted pairing",error:Failure("x"),terminalReason:"Fast route budget expired"))
  check(shouldSuspendAutomaticReconnect(stage:"Trusted pairing",error:TrustedPairingError.failed,terminalReason:"MAC rejected"))
  var fds:[Int32]=[0,0]
  if socketpair(AF_UNIX,SOCK_STREAM,0,&fds)==0 {
    let owned=OwnedSocket(fds[0]),fast=SessionContext(owned,fastRoute:true),normal=SessionContext(owned)
    defer{close(fds[1])}
    fast.beginAuthentication();normal.beginAuthentication();let now=ProcessInfo.processInfo.systemUptime
    check(!fast.authenticationExpired(now:now+2.8));check(fast.authenticationExpired(now:now+3.2));check(!normal.authenticationExpired(now:now+3.2));check(normal.authenticationExpired(now:now+91))
    check(fast.authenticationTimeoutReason=="Fast route budget expired");check(normal.authenticationTimeoutReason=="Pairing timeout")
    check(!fast.finishAuthentication(now:now+3.2))
    check(normal.finishAuthentication(now:now+3.2));check(!normal.authenticationExpired(now:now+200))
    normal.cancel(reason:"must not cancel committed authentication",onlyIfAuthenticationExpired:true);check(!normal.cancelled)
    check(!normal.finishAuthentication(now:now+3.3))
    fast.cancel();check(!fast.finishAuthentication(now:now))
    let background=SessionContext(owned,fastRoute:true);background.beginAuthentication()
    Thread.sleep(forTimeInterval:3.2) // Prove cancellation even while the main test thread is blocked.
    check(background.cancelled && background.terminalReason=="Fast route budget expired")
  } else {check(false)}
  print("Fast route identity/budget policy: \(n) checks, \(f) failures; one transport only, no event posting")
  return f
}
