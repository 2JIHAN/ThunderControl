import AppKit

@MainActor extension App {
  func installApplicationIcon() {
    guard let url=Bundle.main.url(forResource:"ThunderControl",withExtension:"icns"),
      let icon=NSImage(contentsOf:url),icon.isValid else{return}
    NSApp.applicationIconImage=icon
  }
  func installAppearancePreferences() {
    guard !isAutomationTest else{return}
    appearance.onShowConnection = {[weak self] in self?.showConnectionWindow()}
    appearance.onStop = {[weak self] in self?.stop()}
    appearance.onQuit = {NSApp.terminate(nil)}
    appearance.onShowPreferences = {[weak self] in self?.showAppPreferences()}
    appearance.onDockVisibilityRequested = {[weak self] visible in
      self?.pendingDockVisibility=visible;self?.flushDockVisibilityIfSafe()
    }
    appearance.install()
    appearanceInstalled=true
    updateAutomaticWindowVisibility(connected:relay.authenticated)
    appearance.setConnected(relay.authenticated)
    appearanceTimer=Timer.scheduledTimer(withTimeInterval:0.5,repeats:true) {[weak self] _ in
      MainActor.assumeIsolated {self?.flushDockVisibilityIfSafe()}
    }
  }
  // Never change activation policy while this app owns remote inputs/cursor recovery.
  func flushDockVisibilityIfSafe() {
    guard !isAutomationTest,!applicationIsQuitting,let visible=pendingDockVisibility,
      !relay.isTransferring,!relay.isReceivingActiveInput,!relay.hasLocalInputsForAppearance,!relay.forward,!relay.hasUnresolvedLocalRecovery else{return}
    let wanted:NSApplication.ActivationPolicy=visible ? .regular:.accessory
    guard NSApp.activationPolicy() != wanted else {pendingDockVisibility=nil;return}
    let wasActive=NSApp.isActive,key=NSApp.keyWindow
    if NSApp.setActivationPolicy(wanted) {
      pendingDockVisibility=nil
      if wasActive,let key,key.isVisible {
        key.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
      }
    }
  }
  func prepareAppWindowPresentation() {
    connectedWindowVisibility.userOpenedWindow(connected:relay.authenticated)
    relay.appWindowPresentationPolicy.perform(stopSource:{self.stop()},resetLocalIntent:{
      self.relay.receiverLocalCursorOverride(reason:"local-window-opened")
      self.receiverCursorFocus.userReopened()
    })
  }
  func updateAutomaticWindowVisibility(connected:Bool) {
    guard appearanceInstalled,!isAutomationTest,let action=connectedWindowVisibility.setConnected(connected),!applicationIsQuitting else{return}
    applyMainWindowVisibility(action)
  }
  func applyMainWindowVisibility(_ action:ConnectedWindowVisibility.Action) {
    guard let window else{return}
    switch action {
    case .hideMainWindow:
      sourceWindowWasVisible=false
      window.orderOut(nil) // Never NSApp.hide: the invisible source ownership window must survive.
    case .showMainWindow:
      window.orderFront(nil) // Show without stealing another app's keyboard focus.
    }
  }
  func verifyAutomaticMainWindowVisibilityUIForTests() {
    ownershipHUD.present {}
    applyMainWindowVisibility(.hideMainWindow)
    // Cocoa activation is asynchronous; wait only in the native UI test harness.
    let deadline=Date().addingTimeInterval(1.5)
    while !ownershipHUD.hasStableOwnership && Date()<deadline {
      _ = RunLoop.main.run(mode:.default,before:Date().addingTimeInterval(0.01))
    }
    check(!window.isVisible && ownershipHUD.hasStableOwnership)
    applyMainWindowVisibility(.showMainWindow)
    check(window.isVisible)
    ownershipHUD.dismiss();window.makeKeyAndOrderFront(nil)
    print("PASS only main window auto-hides/restores; invisible source key ownership preserved; no input/network")
  }
  func prepareToShowPreferences() {prepareAppWindowPresentation()}
  func verifyReceiverWindowPresentationUIPathsForTests() {
    for entry in 0..<3 {
      check(Relay.verifyReceiverWindowPresentationForTests {receiver in
        let fixture=App(relay:receiver);fixture.window=self.window
        switch entry {
        case 0:check(fixture.applicationShouldHandleReopen(NSApp,hasVisibleWindows:true))
        case 1:fixture.showConnectionWindow()
        default:fixture.showAppPreferences()
        }
      })
    }
    print("PASS actual receiver Dock/menu/preferences UI entrypoints preserve authenticated context, input, token, generation and sequence; no input posted")
  }
  func finishOwnershipUITestWhenStable(deadline:Double) {
    if !ownershipHUD.hasStableOwnership {
      guard ProcessInfo.processInfo.systemUptime<deadline else {
        print("Ownership not ready: active=\(NSApp.isActive) policy=\(NSApp.activationPolicy().rawValue) keyExists=\(NSApp.keyWindow != nil)")
        check(false);return
      }
      DispatchQueue.main.asyncAfter(deadline:.now()+0.05) {[weak self] in self?.finishOwnershipUITestWhenStable(deadline:deadline)}
      return
    }
    DispatchQueue.main.async {[weak self] in
      guard let self else{return}
      check(self.ownershipHUD.hasStableOwnership)
      check(!self.relay.hasSession && !self.relay.forward && !self.relay.inject)
      self.ownershipHUD.dismiss();self.window.makeKeyAndOrderFront(nil)
      print("PASS invisible key ownership stable across run-loop turns; policy=\(NSApp.activationPolicy().rawValue); no network/capture/input")
      if let flag=CommandLine.arguments.firstIndex(of:"--ui-ownership-test"),flag+1<CommandLine.arguments.count {
        do {try Data("PASS native key ownership; no input/network\n".utf8).write(to:URL(fileURLWithPath:CommandLine.arguments[flag+1]))}catch{exit(1)}
      }
      NSApp.terminate(nil)
    }
  }
  func verifyPreferencesTabRoutingForTests() {
    let old=settingsTabs.selectedTabViewItem,count=NSApp.windows.count
    showAppPreferences()
    check((settingsTabs.selectedTabViewItem?.identifier as? String)=="appearance")
    check(NSApp.windows.count==count)
    check(appearance.preferencesView?.window === window)
    if let old {settingsTabs.selectTabViewItem(old)}
    resizeForCurrentTab();window.contentView?.layoutSubtreeIfNeeded()
    print("PASS preferences opens embedded tab without new window; tab persists in both roles")
  }
  func renderAppearancePreferencesForTests(to path:String)throws {
    showAppPreferences()
    let w=window!,v=w.contentView!
    let content=appearance.makePreferencesView()
    w.makeKeyAndOrderFront(nil);v.layoutSubtreeIfNeeded();w.displayIfNeeded()
    let boxes=content.subviews.compactMap{$0 as? NSStackView}.flatMap{$0.arrangedSubviews}.compactMap{$0 as? NSButton}
    check(boxes.count==2)
    check(boxes[1].title == TCText("Hide Dock icon while connected"))
    check(boxes[0].state == (appearance.preferences.showMenuBarIcon ? .on:.off))
    check(boxes[1].state == (appearance.preferences.hideDockIconWhileConnected ? .on:.off))
    for box in boxes {check(v.bounds.contains(box.convert(box.bounds,to:v)))}
    guard let bitmap=v.bitmapImageRepForCachingDisplay(in:v.bounds) else{return}
    let context=NSGraphicsContext(bitmapImageRep:bitmap)!
    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=context
    NSColor.windowBackgroundColor.setFill();v.bounds.fill()
    v.displayIgnoringOpacity(v.bounds,in:context)
    NSGraphicsContext.restoreGraphicsState()
    guard let png=bitmap.representation(using:.png,properties:[:]) else{return}
    try png.write(to:URL(fileURLWithPath:path))
    print("PASS embedded preferences tab: two visible persisted controls; native status/policy effects disabled")
  }
  @objc func showAppPreferences() {
    prepareToShowPreferences()
    if settingsTabs.tabViewItems.contains(where:{($0.identifier as? String)=="appearance"}) {settingsTabs.selectTabViewItem(withIdentifier:"appearance")}
    resizeForCurrentTab()
    window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
  }
  @objc func showConnectionWindow() {
    prepareAppWindowPresentation()
    if settingsTabs.tabViewItems.contains(where:{($0.identifier as? String)=="connection"}) {settingsTabs.selectTabViewItem(withIdentifier:"connection")}
    window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
  }
}
