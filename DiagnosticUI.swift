import AppKit
import ApplicationServices
@MainActor extension App {
  func updateConnectionState(_ message:String="") {
    if !message.isEmpty {latestConnectionMessage=message}
    resumeInputButton.isHidden = !relay.authenticated || (relay.inputIsSender ? relay.auto:relay.inject)
    resumeInputButton.isEnabled = relay.boundaryBlockedReason != .receiverUnavailable && !applicationIsQuitting && !automaticConnectionPaused && !relay.automaticReconnectSuspended && !relay.displayTopologyTransitionActive && !relay.hasUnresolvedLocalRecovery && !relay.bridgeInputSuspended && relay.sessionAllowed && !displayMode.cleaning && !relay.lockedTransportOnly && !relay.sessionLockedSignal && !relay.screenSleeping && !relay.systemSleeping && inputPermissionsReady()
    screenLayout.boundaryBlockedReason=relay.boundaryBlockedReason?.localized
    if relay.lockedTransportOnly || relay.sessionLockedSignal || relay.screenSleeping || relay.systemSleeping {
      state.stringValue=TCText("Locked, input sharing stopped")
      state.textColor = .secondaryLabelColor
    } else if displayMode.active {
      state.stringValue=(relay.authenticated ? ((relay.boundaryBlockedReason?.localized ?? TCText("Input connection maintained"))+" / "):TCText("No input connection / "))+(displayMode.connected ? TCText("Screen connected"):TCText("Connecting screen..."))
      state.textColor = .labelColor
    } else if displayMode.cleaning {
      state.stringValue=TCText("Verifying sharing has stopped and inputs are released")
      state.textColor = .secondaryLabelColor
    } else if relay.authenticated {
      state.stringValue=relay.isTransferring ? TCText("Controlling remote Mac"):(relay.boundaryBlockedReason?.localized ?? sharingBlockedReason ?? (relay.inputIsSender && !relay.auto ? TCText("Connected. Waiting for input sharing readiness."):TCText("Connected")))
      state.textColor = .labelColor
    } else if relay.hasUnresolvedLocalRecovery {
      state.stringValue=TCText("Input recovery is pending. Release held inputs and click Stop to retry.")
      state.textColor = .secondaryLabelColor
    } else if inputPermissionsReady(),!automaticConnectionPaused,!relay.automaticReconnectSuspended,
      !sharingInputRestoreBlocked,relay.sessionAllowed,
      let recovery=connectionRecoveryWait.phase(now:ProcessInfo.processInfo.systemUptime) {
      state.stringValue=TCText(recovery == .waiting
        ? "Connection interrupted. Input is local. Reconnecting..."
        : "Still waiting for a Thunderbolt connection. Check both Macs.")
      state.textColor = .secondaryLabelColor
    } else if relay.hasSession {
      state.stringValue=mode.selectedSegment==1 ? TCText("Waiting for connection requests"):TCText("Connecting...")
      state.textColor = .labelColor
    } else if !AXIsProcessTrusted() || !CGPreflightListenEventAccess() {
      state.stringValue=TCText("Allow the required permissions")
      state.textColor = .secondaryLabelColor
    } else if relay.automaticReconnectSuspended {
      state.stringValue=TCText("Stopped for safety. Reconnect to continue")
      state.textColor = .secondaryLabelColor
    } else if latestConnectionMessage.contains("PIN pairing") {
      state.stringValue=TCText("Check the code and reconnect")
      state.textColor = .secondaryLabelColor
    } else if automaticConnectionPaused {
      state.stringValue=TCText("Connection stopped")
      state.textColor = .secondaryLabelColor
    } else {
      state.stringValue=mode.selectedSegment==1 ? TCText("Preparing to listen"):trustedSenderHint ? TCText("Waiting to connect"):TCText("Select a Mac to connect to")
      state.textColor = .labelColor
    }
    connectButton.keyEquivalent=mode.selectedSegment==0 && !relay.hasSession ? "\r":""
  }
  func verifyUnlockStatusUIForTests() {
    let fixture=App(relay:Relay())
    fixture.relay.sessionLockedSignal=true;fixture.updateConnectionState()
    check(fixture.state.stringValue==TCText("Locked, input sharing stopped"))
    fixture.relay.automaticReconnectSuspended=true
    fixture.sessionAutoResume.adoptTransition(epoch:fixture.relay.automaticSuspensionEpoch)
    fixture.sessionAutoResume.observedUnlock();fixture.lockedTransportUnlockObserved=true
    fixture.automaticConnectionPaused=true
    fixture.invalidateUnlockEvidenceForNewTransition()
    check(!fixture.lockedTransportUnlockObserved && !fixture.sessionAutoResume.unlockObserved)
    // Display cleanup is not permission to restart an independently stopped relay.
    let unlocked=SessionSafetySnapshot(onConsole:true,loginDone:true,screenLocked:false)
    check(mayClearSessionLockAfterUnlock(snapshot:unlocked,unlockObserved:true,screenSleeping:false,systemSleeping:false,observersInstalled:true))
    fixture.relay.sessionLockedSignal=false;fixture.updateConnectionState()
    check(fixture.state.stringValue != TCText("Locked, input sharing stopped"))
    check(fixture.relay.automaticReconnectSuspended && fixture.automaticConnectionPaused)
    let recovering=App(relay:Relay())
    recovering.connectionRecoveryWait.begin(now:ProcessInfo.processInfo.systemUptime)
    recovering.relay.receiverFocusRecoveryPending={true}
    recovering.updateConnectionState()
    check(recovering.state.stringValue==TCText("Input recovery is pending. Release held inputs and click Stop to retry."))
    print("PASS unresolved input recovery overrides reconnect notice; no input/network")
    print("PASS unlocked UI drops stale lock label without unpausing independent Stop; new transition discards both unlock proofs even while paused; no input/network")
  }
  @objc func openDevelopmentDiagnostics() {
    let url=DevelopmentDiagnostics.shared.localDirectoryURL
    if FileManager.default.fileExists(atPath:url.path){NSWorkspace.shared.open(url)}else{
      let alert=NSAlert();alert.messageText=TCText("Development diagnostics start after the screen connection is authenticated.");alert.beginSheetModal(for:window)
    }
  }
  @objc func exportDiagnostics() {
    let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false
    panel.allowsMultipleSelection=false;panel.canCreateDirectories=true
    panel.message=TCText("Choose a folder to save the diagnostic files.");panel.prompt=TCText("Export")
    panel.beginSheetModal(for:window) {[weak self] result in
      guard result == .OK,let directory=panel.url else{return}
      DispatchQueue.global(qos:.utility).async {
        do {
          try DiagnosticStore.shared.export(to:directory, additionalFiles:DevelopmentDiagnostics.shared.exportSnapshot())
          DispatchQueue.main.async {NSWorkspace.shared.open(directory)}
        } catch {
          DispatchQueue.main.async {
            guard let self else{return}
            let alert=NSAlert();alert.messageText=TCText("Could not save the diagnostic files.")
            alert.informativeText=TCText("Choose another folder you can write to.")
            alert.beginSheetModal(for:self.window)
          }
        }
      }
    }
  }
}
