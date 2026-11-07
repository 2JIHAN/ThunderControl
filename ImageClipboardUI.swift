import AppKit

@MainActor extension App {
  func setupImageClipboardUI(_ view:NSView)->NSView {
    guard let stack=view.subviews.first(where:{$0 is NSStackView}) as? NSStackView else{return view}
    let enabled = !isAutomationTest && (UserDefaults.standard.object(forKey:"ThunderControl.imageClipboard.enabled") as? Bool ?? false)
    imageClipboardToggle.state=enabled ? .on:.off
    imageClipboardToggle.target=self;imageClipboardToggle.action=#selector(toggleImageClipboard)
    imageClipboardToggle.setAccessibilityIdentifier("imageClipboardSharing")
    imageClipboardToggle.toolTip=TCText("Both Macs need 0.9.6 or later and image sharing enabled. Only newly copied images are shared. PNG and TIFF are sent as PNG, up to 8 MiB. Text and files are not shared.")
    stack.addArrangedSubview(imageClipboardToggle)
    imageClipboardStatus.font = .systemFont(ofSize:12)
    imageClipboardStatus.textColor = .secondaryLabelColor
    stack.addArrangedSubview(imageClipboardStatus)
    imageClipboardStatus.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true
    relay.imageClipboardStatusChanged={[weak self] text in self?.imageClipboardStatus.stringValue=TCText(text)}
    relay.setImageClipboardEnabled(enabled)
    return view
  }
  @objc func toggleImageClipboard() {
    let enabled=imageClipboardToggle.state == .on
    if !isAutomationTest {UserDefaults.standard.set(enabled,forKey:"ThunderControl.imageClipboard.enabled")}
    relay.setImageClipboardEnabled(enabled)
  }
}
