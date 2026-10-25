import AppKit
@MainActor extension App {
  var isAutomationTest:Bool {CommandLine.arguments.contains("--ui-smoke-test") || CommandLine.arguments.contains("--ui-ownership-test")}

  // This noninteractive metadata lookup is only a scheduling/UI hint. The wire
  // handshake must prove the peer's saved key, identity and opposite role.
  func refreshTrustedSenderHint(force:Bool=false) {
    guard !isAutomationTest,!trustHintPending else{return}
    let now=ProcessInfo.processInfo.systemUptime
    guard force || lastTrustHintTime==0 || now-lastTrustHintTime>=5 else{return}
    lastTrustHintTime=now
    trustHintPending=true
    DispatchQueue.global(qos:.utility).async { [weak self] in
      let trusted=TrustedPairingStore.hasAnyTrustedPeer(isSender:true)
      DispatchQueue.main.async { [weak self] in
        guard let self else{return}
        self.trustHintPending=false
        // Age the cache from completion, not from a potentially delayed query.
        self.lastTrustHintTime=ProcessInfo.processInfo.systemUptime
        if self.trustedSenderHint != trusted {
          self.trustedSenderHint=trusted
          self.refreshModeUI()
        }
        self.requestAutomaticConnectionTick()
      }
    }
  }

  func installAutomaticConnections() {
    guard !isAutomationTest else{return}
    _ = bridgeRecoveryObserver.start {[weak self] in self?.requestBridgeRecoveryProbe()}
    automaticConnectionTimer=Timer.scheduledTimer(withTimeInterval:2,repeats:true) {[weak self] _ in
      MainActor.assumeIsolated {self?.automaticConnectionTick()}
    }
    automaticConnectionTick()
  }

  // Hidden developer preference, default OFF. No extra UI.
  var adaptiveReconnectEnabled:Bool {UserDefaults.standard.bool(forKey:"adaptiveReconnectBackoffEnabled")}

  func automaticConnectionTick() {
    sharingRestoreTick()
    guard !displayMode.cleaning else{return}
    if displayMode.active && !relay.hasSession {return}
    // Unlock recovery owns its own safety checks and must run before the gates.
    tryResumeAfterVerifiedUnlock()
    guard !isAutomationTest,!applicationIsQuitting else{return}
    if relay.hasSession {repairReceiverAdvertisementIfNeeded();scheduleAutomaticRetryWake();return}
    defer{scheduleAutomaticRetryWake()}
    requestBridgeRecoveryProbe()
    let lockedStandby=lockedStandbyAutomaticEligible
    guard automaticSessionVerified || lockedStandby else{return}
    let sending=mode.selectedSegment==0
    guard sending || mode.selectedSegment==1 else{return}
    // Discovery can aid first enrollment before a role is persisted, but every
    // network action still obeys pause, emergency-stop and session safety gates.
    guard automaticConnectionMayStart(configured:true,paused:automaticConnectionPaused,
      suspended:relay.automaticReconnectSuspended && !lockedStandby,permissions:inputPermissionsReady() || lockedStandby,
      sessionSafe:relay.sessionAllowed || lockedStandby,recovery:relay.hasUnresolvedLocalRecovery,
      hasSession:relay.hasSession) else{return}
    if lockedStandby,!relay.automaticReconnectSuspended {sessionAutoResume.armLockedStandby(epoch:relay.automaticSuspensionEpoch)}
    let now=ProcessInfo.processInfo.systemUptime
    let configured=UserDefaults.standard.string(forKey:"preferredRole")==((sending) ? "send":"receive")
    if sending {
      // Never turn a manually typed address or ambiguous discovery into an
      // automatic attempt. Addresses and names are routing hints, not trust.
      guard iface.stringValue=="bridge0",manualPeerToggle.state != .on else{return}
      if configured,now>=nextAutomaticAttempt,tryFastAuthenticatedRoute(locked:lockedStandby) {return}
      // Browsing is independent of connection retry pacing, so a cable/peer
      // change can still be discovered during a long retry cooldown.
      if !discovery.isBrowsing || shouldRenewEmptyPeerSearch(browsing:discovery.isBrowsing,peerCount:discoveredPeers.count,started:peerSearchStartedAt,now:now) {
        guard now>=nextDiscoveryAttempt else{return}
        searchPeers()
        nextDiscoveryAttempt=discovery.isBrowsing ? 0:now+reconnectBackoff.nextDelay(enabled:adaptiveReconnectEnabled)
        return
      }
      if !discoveredPeers.isEmpty {refreshTrustedSenderHint()}
      guard configured,trustedSenderHint,
        discoveredPeers.count==1,peerSelectionConfirmed,
        peerPicker.indexOfSelectedItem==0,
        let candidate=discoveredPeers.first,candidate.port==49177,
        peer.stringValue==candidate.ipv4,port.stringValue=="49177",
        now>=nextAutomaticAttempt else{return}
      // The remembered identity survives route/address changes. Discovery is only
      // a route hint; never silently reconnect to another already-trusted Mac.
      guard let expectedPair=rememberedAutomaticReconnectPair else{return}
      nextAutomaticAttempt=now+5
      do {
        discovery.stop();discoveryIsBrowsing=false
        // Empty pass is deliberate: unknown automatic senders must never fall
        // back to PIN enrollment. Relay enforces allowNewTrust:false here.
        try relay.start(name:"bridge0",peer:candidate.ipv4,pass:"",port:49177,
          sendMode:true,automaticStart:true,lockedTransport:lockedStandby,lockedPermitEpoch:sessionAutoResume.epoch,expectedRoutePair:expectedPair)
      } catch {
        if !relay.hasSession {discovery.stop();discoveryIsBrowsing=false}
        relay.status(TCText("Automatic Sender connection failed: ") + safeConnectionError(error))
      }
      return
    }
    guard configured,now>=nextAutomaticAttempt else{return}
    // Exact 5s fallback; verified bridge recovery can bring this deadline forward. A successful
    // listener is not an authenticated connection and must not reset the delay.
    // App resets this state only on authentication or explicit manual restart.
    nextAutomaticAttempt=now+5
    do {
      discovery.stop();discoveryIsBrowsing=false
      // Listening is not trust. Receiver enrollment still requires a human PIN
      // approval; the Relay permits it even for automatic receiver listening.
      let verified=try relay.start(name:"bridge0",peer:"",pass:"",port:49177,sendMode:false,automaticStart:true,lockedTransport:lockedStandby,lockedPermitEpoch:sessionAutoResume.epoch,expectedRoutePair:sharingResume.lastBinding.flatMap{$0.inputIsSender ? nil:$0.pair})
      _ = verifiedBridgeRecovery.observe("\(verified.name)/\(verified.index)/\(verified.ip)")
      advertiseVerifiedReceiver(verified)
    } catch {
      if !relay.hasSession {discovery.stop();discoveryIsBrowsing=false}
      relay.status(TCText("Automatic Receiver listening failed: ") + safeConnectionError(error))
    }
  }
}
