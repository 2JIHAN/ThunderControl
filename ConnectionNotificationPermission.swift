import AppKit
@MainActor extension App {
  @objc func allowConnectionNotifications() {
    connectionNotifications.permissionActionRequired = {[weak self] in
      guard let self else{return}
      let alert=NSAlert();alert.messageText=TCText("Please Allow Connection Notifications")
      alert.informativeText=TCText("In System Settings > Notifications, allow notifications for ThunderControl and select Banners. macOS may hide notifications while a Focus is active.")
      alert.addButton(withTitle:TCText("Open System Settings"));alert.addButton(withTitle:TCText("Close"))
      alert.beginSheetModal(for:self.window) {response in
        if response == .alertFirstButtonReturn {NSWorkspace.shared.open(URL(fileURLWithPath:"/System/Applications/System Settings.app"))}
      }
    }
    connectionNotifications.requestAuthorizationIfNeeded(forceRetry:true)
  }
}
