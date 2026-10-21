import AppKit
@MainActor extension App {
  var automaticSchedulingAllowed:Bool {
    guard !isAutomationTest,!applicationIsQuitting,!automaticConnectionPaused else{return false}
    if automaticSessionVerified && !relay.automaticReconnectSuspended {return true}
    return lockedStandbyAutomaticEligible
  }
  func requestAutomaticConnectionTick() {
    guard !isAutomationTest,!applicationIsQuitting,!automaticTickQueued else{return}
    automaticTickQueued=true
    DispatchQueue.main.async {[weak self] in
      guard let self else{return}
      self.automaticTickQueued=false
      guard !self.applicationIsQuitting else{return}
      self.automaticConnectionTick()
    }
  }
  func scheduleAutomaticRetryWake() {
    guard !relay.hasSession,automaticSchedulingAllowed else {
      automaticRetryTimer?.invalidate();automaticRetryTimer=nil;scheduledAutomaticRetryDeadline=nil;return
    }
    let now=ProcessInfo.processInfo.systemUptime
    guard let deadline=automaticRetryDeadline(sending:mode.selectedSegment==0,attempt:nextAutomaticAttempt,discovery:nextDiscoveryAttempt,now:now) else {
      automaticRetryTimer?.invalidate();automaticRetryTimer=nil;scheduledAutomaticRetryDeadline=nil;return
    }
    if automaticRetryTimer?.isValid==true,scheduledAutomaticRetryDeadline==deadline {return}
    automaticRetryTimer?.invalidate();scheduledAutomaticRetryDeadline=deadline
    let timer=Timer(timeInterval:max(0.001,deadline-now),repeats:false) {[weak self] _ in
      MainActor.assumeIsolated {self?.automaticConnectionTick()}
    }
    automaticRetryTimer=timer;RunLoop.main.add(timer,forMode:.common)
  }
  func requestBridgeRecoveryProbe() {
    guard !relay.hasSession,automaticSchedulingAllowed else{return}
    if bridgeRecoveryProbeInFlight {bridgeRecoveryProbeAgain=true;return}
    guard bridgeRecoveryProbeWork==nil else{return}
    let work=DispatchWorkItem {[weak self] in
      guard let self else{return}
      self.bridgeRecoveryProbeWork=nil
      guard !self.relay.hasSession,self.automaticSchedulingAllowed else{return}
      self.bridgeRecoveryProbeInFlight=true
      let observationRevision=self.verifiedBridgeRecovery.revision
      DispatchQueue.global(qos:.utility).async {[weak self] in
        // OS events are hints only. No deadline is reset unless full Thunderbolt validation succeeds.
        let verified=try? bridge("bridge0")
        DispatchQueue.main.async {[weak self] in
          guard let self else{return}
          self.bridgeRecoveryProbeInFlight=false
          let again=self.bridgeRecoveryProbeAgain;self.bridgeRecoveryProbeAgain=false
          guard !self.applicationIsQuitting else{return}
          if !self.relay.hasSession {
            let signature=verified.map{"\($0.name)/\($0.index)/\($0.ip)"}
            let recovered=self.verifiedBridgeRecovery.observe(signature,after:observationRevision)
            if recovered,self.automaticSchedulingAllowed {
              self.fastRouteTried=false
              self.nextAutomaticAttempt=0;self.nextDiscoveryAttempt=0;self.reconnectBackoff.reset()
              if self.mode.selectedSegment==0,self.iface.stringValue=="bridge0",self.manualPeerToggle.state != .on {self.discovery.stop();self.discoveryIsBrowsing=false}
              self.requestAutomaticConnectionTick()
            }
          }
          if again {self.requestBridgeRecoveryProbe()}
        }
      }
    }
    bridgeRecoveryProbeWork=work
    DispatchQueue.main.asyncAfter(deadline:.now()+0.1,execute:work)
  }
  func stopBridgeRecoveryScheduling() {
    bridgeRecoveryObserver.stop();bridgeRecoveryProbeWork?.cancel();bridgeRecoveryProbeWork=nil
    automaticRetryTimer?.invalidate();automaticRetryTimer=nil
    automaticConnectionTimer?.invalidate();automaticConnectionTimer=nil
  }
}
