import AppKit

@MainActor extension App {
  func setupImageClipboardUI(_ view:NSView)->NSView {
    guard let stack=view.subviews.first(where:{$0 is NSStackView}) as? NSStackView else{return view}
    let enabled = !isAutomationTest && (UserDefaults.standard.object(forKey:"ThunderControl.imageClipboard.enabled") as? Bool ?? false)
    imageClipboardToggle.state=enabled ? .on:.off
    imageClipboardToggle.target=self;imageClipboardToggle.action=#selector(toggleImageClipboard)
    imageClipboardToggle.setAccessibilityIdentifier("imageClipboardSharing")
    imageClipboardToggle.toolTip=TCText("Both Macs need 0.9.7 or later and image sharing enabled. Only newly copied images are shared. PNG and TIFF are sent as PNG, up to 8 MiB. Files are not shared.")
    stack.addArrangedSubview(imageClipboardToggle)
    imageClipboardStatus.font = .systemFont(ofSize:12)
    imageClipboardStatus.textColor = .secondaryLabelColor
    stack.addArrangedSubview(imageClipboardStatus)
    imageClipboardStatus.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true
    relay.imageClipboardStatusChanged={[weak self] text in self?.imageClipboardStatus.stringValue=TCText(text)}
    relay.setImageClipboardEnabled(enabled)
    // Text is a separate, default-off consent; the image preference never enables it.
    let textEnabled = !isAutomationTest && (UserDefaults.standard.object(forKey:"ThunderControl.textClipboard.enabled") as? Bool ?? false)
    textClipboardToggle.state=textEnabled ? .on:.off
    textClipboardToggle.target=self;textClipboardToggle.action=#selector(toggleTextClipboard)
    textClipboardToggle.setAccessibilityIdentifier("textClipboardSharing")
    textClipboardToggle.toolTip=TCText("Both Macs need 0.9.11 or later and text sharing enabled. Only newly copied plain text is shared, up to 1 MiB. Formatting, file paths and files are not shared.")
    stack.addArrangedSubview(textClipboardToggle)
    textClipboardStatus.setAccessibilityIdentifier("textClipboardStatus")
    textClipboardStatus.font = .systemFont(ofSize:12)
    textClipboardStatus.textColor = .secondaryLabelColor
    stack.addArrangedSubview(textClipboardStatus)
    textClipboardStatus.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true
    relay.textClipboardStatusChanged={[weak self] text in self?.textClipboardStatus.stringValue=TCText(text)}
    relay.setTextClipboardEnabled(textEnabled)
    return view
  }
  @objc func toggleTextClipboard() {
    let enabled=textClipboardToggle.state == .on
    if !isAutomationTest {UserDefaults.standard.set(enabled,forKey:"ThunderControl.textClipboard.enabled")}
    relay.setTextClipboardEnabled(enabled)
  }
  @objc func toggleImageClipboard() {
    let enabled=imageClipboardToggle.state == .on
    if !isAutomationTest {UserDefaults.standard.set(enabled,forKey:"ThunderControl.imageClipboard.enabled")}
    relay.setImageClipboardEnabled(enabled)
  }
}
