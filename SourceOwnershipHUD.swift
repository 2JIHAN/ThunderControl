import AppKit
// A key window is still required for safe source ownership, but has no visible UI.
@MainActor private final class SourceOwnershipWindow:NSWindow {
  override var canBecomeKey:Bool {true}
  override var canBecomeMain:Bool {false}
}
@MainActor final class SourceOwnershipHUD:NSObject {
  private let panel:NSWindow
  override init() {
    panel=SourceOwnershipWindow(contentRect:NSRect(x:0,y:0,width:1,height:1),styleMask:.borderless,backing:.buffered,defer:false)
    super.init()
    panel.isReleasedWhenClosed=false
    panel.title=""
    panel.isOpaque=false;panel.backgroundColor = .clear;panel.alphaValue=0
    panel.hasShadow=false;panel.ignoresMouseEvents=true
    panel.collectionBehavior=[.transient,.ignoresCycle,.fullScreenAuxiliary]
  }
  func present(stop:@escaping()->Void) {
    panel.makeFirstResponder(nil);panel.makeKeyAndOrderFront(nil)
    NSRunningApplication.current.activate(options:[.activateIgnoringOtherApps]);NSApp.activate(ignoringOtherApps:true)
  }
  var hasStableOwnership:Bool {panel.isVisible && panel.isKeyWindow && NSApp.isActive && panel.alphaValue==0 && panel.ignoresMouseEvents}
  func dismiss(){panel.orderOut(nil)}
}
