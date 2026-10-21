import AppKit

// A browse can remain allocated after a resolve/address timeout without another
// service-add callback. Start a fresh round after allowing its 10s resolve budget.
func shouldRenewEmptyPeerSearch(browsing:Bool,peerCount:Int,started:Double,now:Double)->Bool {
  browsing && peerCount==0 && started.isFinite && now.isFinite && now>=started && now-started>=12
}
func receiverAdvertisementRepairAllowed(configured:Bool,paused:Bool,suspended:Bool,sessionSafe:Bool,
  permissions:Bool,recovery:Bool,listening:Bool,advertising:Bool)->Bool {
  configured && !paused && !suspended && sessionSafe && permissions && !recovery && listening && !advertising
}
@MainActor extension App {
  func advertiseVerifiedReceiver(_ verified:Bridge,port:UInt16=49177) {
    receiverAdvertisementPort=port
    receiverAdvertisementBridge=verified;receiverAdvertisementLease=UUID()
    nextAdvertisementRepair=ProcessInfo.processInfo.systemUptime+5
    discovery.advertise(interfaceIndex:verified.index,name:Host.current().localizedName ?? "ThunderControl Mac",port:port)
  }
  var mayRepairReceiverAdvertisement:Bool {
    let standby=lockedStandbyAutomaticEligible
    return !isAutomationTest && !applicationIsQuitting && receiverAdvertisementRepairAllowed(
      configured:automaticSessionVerified || standby,paused:automaticConnectionPaused,
      suspended:relay.automaticReconnectSuspended && !standby,
      sessionSafe:relay.sessionAllowed || standby,permissions:inputPermissionsReady() || standby,
      recovery:relay.hasUnresolvedLocalRecovery,listening:relay.hasSession && !relay.authenticated && !relay.authenticatedLocalIsSender,
      advertising:discovery.isAdvertising)
  }
  func repairReceiverAdvertisementIfNeeded() {
    let now=ProcessInfo.processInfo.systemUptime
    guard mayRepairReceiverAdvertisement,!advertisementRepairInFlight,now>=nextAdvertisementRepair,
      let expected=receiverAdvertisementBridge else{return}
    advertisementRepairInFlight=true;nextAdvertisementRepair=now+5
    let lease=receiverAdvertisementLease
    DispatchQueue.global(qos:.utility).async {[weak self] in
      let verified=try? bridge("bridge0")
      DispatchQueue.main.async {[weak self] in
        guard let self else{return}
        self.advertisementRepairInFlight=false
        // Only the same waiting listener may re-advertise, on the same fully
        // validated bridge. Never bind/start another TCP connection here.
        guard self.receiverAdvertisementLease==lease,self.receiverAdvertisementBridge==expected,
          verified==expected,self.mayRepairReceiverAdvertisement else{return}
        self.discovery.advertise(interfaceIndex:expected.index,name:Host.current().localizedName ?? "ThunderControl Mac",port:self.receiverAdvertisementPort)
        connectionLog("Receiver discovery advertisement retry requested; existing verified listener retained")
      }
    }
  }
}
func runDiscoveryRecoveryPolicyTests()->Int {
  var n=0,f=0
  func check(_ ok:Bool){n+=1;if !ok{f+=1}}
  check(!shouldRenewEmptyPeerSearch(browsing:false,peerCount:0,started:1,now:20))
  check(!shouldRenewEmptyPeerSearch(browsing:true,peerCount:1,started:1,now:20))
  check(!shouldRenewEmptyPeerSearch(browsing:true,peerCount:0,started:1,now:12.99))
  check(shouldRenewEmptyPeerSearch(browsing:true,peerCount:0,started:1,now:13))
  for invalid in [Double.nan,.infinity,-.infinity] {
    check(!shouldRenewEmptyPeerSearch(browsing:true,peerCount:0,started:invalid,now:20))
    check(!shouldRenewEmptyPeerSearch(browsing:true,peerCount:0,started:1,now:invalid))
  }
  check(!shouldRenewEmptyPeerSearch(browsing:true,peerCount:0,started:20,now:1))
  for mask in 0..<256 {
    let result=receiverAdvertisementRepairAllowed(configured:mask&1 != 0,paused:mask&2 != 0,
      suspended:mask&4 != 0,sessionSafe:mask&8 != 0,permissions:mask&16 != 0,
      recovery:mask&32 != 0,listening:mask&64 != 0,advertising:mask&128 != 0)
    check(result == (mask==89))
  }
  print("Discovery recovery: \(n) policy assertions, \(f) failures; empty-search renewal and advertisement safety gates, no network/input")
  return f
}
