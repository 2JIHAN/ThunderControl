import AppKit
@MainActor extension App {
  func installGestureTraceTab() {
    let tab=NSTabViewItem(identifier:"gestureTrace");tab.label=TCText("Gesture Log")
    let container=NSView(),stack=NSStackView();stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=10;stack.translatesAutoresizingMaskIntoConstraints=false
    container.addSubview(stack)
    NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:container.leadingAnchor,constant:16),stack.trailingAnchor.constraint(equalTo:container.trailingAnchor,constant:-16),stack.topAnchor.constraint(equalTo:container.topAnchor,constant:16),stack.bottomAnchor.constraint(equalTo:container.bottomAnchor,constant:-16)])
    gestureTraceToggle.state=relay.gestureTrace.enabled ? .on : .off;gestureTraceToggle.target=self;gestureTraceToggle.action=#selector(toggleGestureTrace)
    stack.addArrangedSubview(gestureTraceToggle)
    stack.addArrangedSubview(NSTextField(wrappingLabelWithString:TCText("Enable logging → perform one action → disable logging → Copy All. Keystrokes, PINs, secret keys, raw events, and finger coordinates are not logged. This tab holds up to 2048 rows. Numeric logs also remain in system diagnostics. Clear only clears this tab.")))
    stack.addArrangedSubview(NSStackView(views:[NSButton(title:TCText("Copy All"),target:self,action:#selector(copyGestureTrace)),NSButton(title:TCText("Clear"),target:self,action:#selector(clearGestureTrace)),NSButton(title:TCText("Refresh"),target:self,action:#selector(refreshGestureTrace))]))
    let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.hasHorizontalScroller=true
    gestureTraceText.isEditable=false;gestureTraceText.isSelectable=true;gestureTraceText.font = .monospacedSystemFont(ofSize:10,weight:.regular);gestureTraceText.isVerticallyResizable=true;gestureTraceText.isHorizontallyResizable=true;gestureTraceText.textContainer?.widthTracksTextView=false;gestureTraceText.textContainer?.containerSize=NSSize(width:100000,height:CGFloat.greatestFiniteMagnitude)
    gestureTraceText.frame=NSRect(x:0,y:0,width:640,height:500);gestureTraceText.minSize=NSSize(width:640,height:300);gestureTraceText.maxSize=NSSize(width:100000,height:CGFloat.greatestFiniteMagnitude)
    scroll.documentView=gestureTraceText;scroll.translatesAutoresizingMaskIntoConstraints=false
    stack.addArrangedSubview(scroll);scroll.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true
    scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:300).isActive=true
    tab.view=container;settingsTabs.addTabViewItem(tab)
    gestureTraceTimer=Timer.scheduledTimer(withTimeInterval:0.25,repeats:true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self,self.window.isVisible,!self.window.isMiniaturized,NSApp.isActive,!self.relay.isTransferring,(self.settingsTabs.selectedTabViewItem?.identifier as? String)=="gestureTrace" else{return}
        self.refreshGestureTrace()
      }
    }
  }
  @objc func toggleGestureTrace() {relay.gestureTrace.setEnabled(gestureTraceToggle.state == .on);refreshGestureTrace()}
  @objc func clearGestureTrace() {relay.gestureTrace.clear();refreshGestureTrace()}
  @objc func refreshGestureTrace() {gestureTraceToggle.state=relay.gestureTrace.enabled ? .on : .off;gestureTraceText.string=gestureTraceHeader()+relay.gestureTrace.snapshot();gestureTraceText.sizeToFit()}
  private func gestureTraceHeader()->String {"ThunderControl "+(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "debug")+" mode="+(mode.selectedSegment==0 ? "Send":"Receive")+" OSbuild="+(systemBuildIdentifier() ?? "unknown")+"\nconfig="+relay.gestureDebugConfiguration+"\nTX_CAPTURE=source native scalars; TX_QUEUED=encrypted queue; TX_WRITTEN=socket write success\nRX_DECODED=received parameters; RX_PROJECTED=direction transformed; RX_BUILT=OS event fields; RX_POSTED=post API invoked, not proof of recognition\n"}
  @objc func copyGestureTrace() {let text=gestureTraceHeader()+relay.gestureTrace.snapshot();NSPasteboard.general.clearContents();NSPasteboard.general.setString(text,forType:.string)}
}
