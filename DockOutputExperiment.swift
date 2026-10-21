import AppKit
@MainActor extension App {
  @objc func testMissionControlOutput() {
    guard mode.selectedSegment==1,!relay.hasSession,NSApp.isActive,relay.sessionAllowed,AXIsProcessTrusted(),DockGestureCodec.supported else {
      relay.status(TCText("Output test requires Receiver mode, a stopped connection, the app active, Accessibility permission, and macOS 27."));return
    }
    guard !NSRunningApplication.runningApplications(withBundleIdentifier:"local.experimental.ThunderControl").contains(where:{$0.processIdentifier != ProcessInfo.processInfo.processIdentifier}) else{relay.status(TCText("Click Stop in any other ThunderControl instance, then quit it first."));return}
    let alert=NSAlert()
    alert.messageText=TCText("Unverified Mission Control Output Test")
    alert.informativeText=TCText("Sends a brief native vertical gesture only to this Mac. No actual finger input is captured or sent over the network. Mission Control may open, or screen switching may stall. After testing, press Escape or click the desktop on this Mac to close it.")
    alert.addButton(withTitle:TCText("Run Test"));alert.addButton(withTitle:TCText("Cancel"))
    guard alert.runModal() == .alertFirstButtonReturn else{return}
    let generation=UUID();dockOutputTestGeneration=generation
    let frames:[DockGestureDescriptor]=[
      .init(motion:2,phase:1,progress:0,velocityX:0,velocityY:0),
      .init(motion:2,phase:2,progress:0.15,velocityX:0,velocityY:1),
      .init(motion:2,phase:2,progress:0.45,velocityX:0,velocityY:1),
      .init(motion:2,phase:2,progress:0.8,velocityX:0,velocityY:1),
      .init(motion:2,phase:4,progress:1,velocityX:0,velocityY:0)]
    for (i,frame) in frames.enumerated() {
      DispatchQueue.main.asyncAfter(deadline:.now()+Double(i)*0.06) { [weak self] in
        guard let self,self.dockOutputTestGeneration==generation,!self.relay.hasSession,self.relay.sessionAllowed,let event=DockGestureCodec.makeExperimentalVerticalEvent(frame) else{return}
        event.timestamp=DispatchTime.now().uptimeNanoseconds
        event.setIntegerValueField(.eventSourceUserData,value:marker)
        event.post(tap:.cgSessionEventTap)
        if i==frames.count-1 {self.relay.status(TCText("Experimental frames delivered. Check the screen yourself to see whether Mission Control opened."))}
      }
    }
  }
}
