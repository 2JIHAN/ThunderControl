import AppKit
import ApplicationServices
@MainActor extension App {
  func updateConnectionState(_ message:String="") {
    if !message.isEmpty {latestConnectionMessage=message}
    if relay.lockedTransportOnly || relay.sessionLockedSignal || relay.screenSleeping || relay.systemSleeping {
      state.stringValue=TCText("Locked, input sharing stopped")
      state.textColor = .secondaryLabelColor
    } else if displayMode.active {
      state.stringValue=(relay.authenticated ? TCText("Input connection maintained / "):TCText("No input connection / "))+(displayMode.connected ? TCText("Screen connected"):TCText("Connecting screen..."))
      state.textColor = .labelColor
    } else if displayMode.cleaning {
      state.stringValue=TCText("Verifying sharing has stopped and inputs are released")
      state.textColor = .secondaryLabelColor
    } else if relay.authenticated {
      state.stringValue=relay.isTransferring ? TCText("Controlling remote Mac"):(sharingBlockedReason ?? (relay.inputIsSender && !relay.auto ? TCText("Connected. Waiting for input sharing readiness."):TCText("Connected")))
      state.textColor = .labelColor
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
    print("PASS unlocked UI drops stale lock label without unpausing independent Stop; new transition discards both unlock proofs even while paused; no input/network")
  }
  @objc func openDevelopmentDiagnostics() {
    let url=DevelopmentDiagnostics.shared.localDirectoryURL
    if FileManager.default.fileExists(atPath:url.path){NSWorkspace.shared.open(url)}else{
      let alert=NSAlert();alert.messageText=TCText("Development diagnostics start after the screen connection is authenticated.");alert.beginSheetModal(for:window)
    }
  }
  @objc func openCloudDevelopmentDiagnostics() {
    if let url=DevelopmentDiagnostics.shared.cloudDirectoryURL{NSWorkspace.shared.open(url)}else{
      let alert=NSAlert();alert.messageText=TCText("iCloud diagnostics are not available yet. Local diagnostics remain available; cloud copying retries automatically.");alert.beginSheetModal(for:window)
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
          try DiagnosticStore.shared.export(to:directory)
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
