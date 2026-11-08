import AppKit

@MainActor final class FileTransferView: NSView {
  let coordinator: FileTransferCoordinator
  private let status = NSTextField(wrappingLabelWithString: TCText("Connect both Macs with file transfer support."))
  private let progress = NSProgressIndicator()
  private let choose = NSButton(title: TCText("Choose File or Folder…"), target: nil, action: nil)
  private let accept = NSButton(title: TCText("Accept and Save…"), target: nil, action: nil)
  private let decline = NSButton(title: TCText("Decline"), target: nil, action: nil)
  private let cancelButton = NSButton(title: TCText("Cancel Transfer"), target: nil, action: nil)
  private let current = NSTextField(labelWithString: "")
  private var incoming: TransferItem?
  init(coordinator: FileTransferCoordinator) {
    self.coordinator = coordinator
    super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 320))
    registerForDraggedTypes([.fileURL])
    let heading = NSTextField(labelWithString: TCText("Send a file or folder to the paired Mac"))
    heading.font = .boldSystemFont(ofSize: 15)
    let detail = NSTextField(wrappingLabelWithString: TCText("Drop one file or folder here, or choose one. The receiving Mac chooses where to save it. Links and special files are not sent. Each file can be up to 64 GiB. Folders need 0.9.10 or later on both Macs."))
    current.lineBreakMode = .byTruncatingMiddle; current.textColor = .secondaryLabelColor
    let buttons = NSStackView(views: [choose, accept, decline, cancelButton]); buttons.spacing = 8
    let stack = NSStackView(views: [heading, detail, status, current, progress, buttons]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16; stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: topAnchor, constant: 24), status.widthAnchor.constraint(equalTo: stack.widthAnchor), detail.widthAnchor.constraint(equalTo: stack.widthAnchor), progress.widthAnchor.constraint(equalTo: stack.widthAnchor), current.widthAnchor.constraint(equalTo: stack.widthAnchor)])
    progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 1
    choose.target = self; choose.action = #selector(pick)
    accept.target = self; accept.action = #selector(save)
    decline.target = self; decline.action = #selector(reject)
    cancelButton.target = self; cancelButton.action = #selector(cancelTransfer)
    coordinator.onChange = { [weak self] state in self?.render(state) }; render(coordinator.state)
  }
  required init?(coder: NSCoder) { nil }
  private func render(_ state: FileTransferState) {
    incoming = nil; accept.isHidden = true; decline.isHidden = true; choose.isEnabled = false; cancelButton.isEnabled = true; progress.doubleValue = 0; current.stringValue = ""
    cancelButton.title = TCText("Cancel Transfer")
    func size(_ bytes: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file) }
    switch state {
    case .unavailable(let text): status.stringValue = TCText(text); cancelButton.isEnabled = false
    case .idle: status.stringValue = TCText("Ready. Drop a file or folder here."); choose.isEnabled = true; cancelButton.isEnabled = false
    case .preparing: status.stringValue = TCText("Preparing…")
    case .awaitingPeer(let item): status.stringValue = TCText("Waiting for approval: {0}", item.name)
    case .incomingOffer(let item):
      incoming = item; accept.isHidden = false; decline.isHidden = false
      if case .folder(let offer) = item { status.stringValue = TCText("Incoming folder: {0} ({1} files, {2})", offer.name, String(offer.fileCount), size(offer.totalBytes)) }
      else { status.stringValue = TCText("Incoming: {0} ({1})", item.name, size(item.byteCount)) }
    case .folderProgress(let offer, let p):
      cancelButton.title = TCText("Stop Transfer")
      status.stringValue = p.verifying ? TCText("Verifying folder…") : TCText("Transferring folder {0}: {1} of {2} files, {3} of {4}", offer.name, String(p.doneFiles), String(p.totalFiles), size(p.doneBytes), size(p.totalBytes))
      if p.skippedFiles > 0 { current.stringValue = TCText("{0} completed files reused", String(p.skippedFiles)) }
      if let path = p.currentPath { current.stringValue = path }
      progress.doubleValue = p.totalBytes == 0 ? (p.totalFiles == 0 ? 1 : Double(p.doneFiles) / Double(p.totalFiles)) : Double(p.doneBytes) / Double(p.totalBytes)
    case .transferring(let offer, let count): status.stringValue = TCText("Transferring: {0}", offer.name); progress.doubleValue = offer.byteCount == 0 ? 1 : Double(count) / Double(offer.byteCount)
    case .verifying: status.stringValue = TCText("Verifying file…"); progress.doubleValue = 1
    case .completed(let item): status.stringValue = TCText("Completed: {0}", item.name); progress.doubleValue = 1; choose.isEnabled = true; cancelButton.isEnabled = false
    case .failed(let text): status.stringValue = text; choose.isEnabled = true; cancelButton.isEnabled = false
    case .cancelled: status.stringValue = TCText("Transfer cancelled."); choose.isEnabled = true; cancelButton.isEnabled = false
    }
  }
  @objc private func pick() {
    let token = coordinator.sessionToken
    let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
    panel.begin { [weak self] response in guard response == .OK, let url = panel.url, let self, self.coordinator.sessionToken == token else { return }; self.coordinator.sendURL(url) }
  }
  @objc private func save() {
    guard let offer = incoming else { return }
    let token = coordinator.sessionToken
    let panel = NSSavePanel(); panel.nameFieldStringValue = offer.name; panel.canCreateDirectories = true
    if case .folder = offer { panel.message = TCText("A new folder is created. Existing folders are never merged or replaced. To resume a stopped folder, choose the same location and name.") }
    else { panel.message = TCText("Existing files are not replaced. Choose a different name if it already exists.") }
    panel.begin { [weak self] response in guard response == .OK, let url = panel.url, let self, self.coordinator.sessionToken == token else { return }; self.coordinator.acceptURL(url, for: offer.id) }
  }
  @objc private func reject() { coordinator.reject() }
  @objc private func cancelTransfer() { coordinator.cancel() }
  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { choose.isEnabled ? .copy : [] }
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    guard choose.isEnabled else { return false }
    let token = coordinator.sessionToken
    let boardName = sender.draggingPasteboard.name
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let board = NSPasteboard(name: boardName)
      guard let items = board.pasteboardItems, items.count == 1, let text = items[0].string(forType: .fileURL), let url = URL(string: text), url.isFileURL else { return }
      DispatchQueue.main.async { guard let self, self.coordinator.sessionToken == token else { return }; self.coordinator.sendURL(url) }
    }
    return true
  }
}
