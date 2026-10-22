import AppKit

@MainActor extension App {
    var isOffscreenLocalizationPreview: Bool {
        CommandLine.arguments.contains("--ui-smoke-test") &&
        CommandLine.arguments.contains("--layout-only") &&
        CommandLine.arguments.contains("--offscreen-localization")
    }

    /// Actual controls, rendered without ordering a window, activating the app, reading the
    /// clipboard, capturing a display, searching peers, registering login items or enabling input.
    func renderLocalizedOffscreenPreview() throws {
        guard isOffscreenLocalizationPreview,
              let index = CommandLine.arguments.firstIndex(of: "--ui-smoke-test"),
              index + 1 < CommandLine.arguments.count,
              !NSApp.isActive, !window.isVisible, !relay.hasSession, !discoveryIsBrowsing,
              !relay.forward, !relay.inject, !relay.auto else {
            throw Failure("Offscreen preview admission failed")
        }
        guard displayPreferenceToggle.superview === sendSection,
              displayStatus.superview === sendSection.superview,
              !settingsTabs.tabViewItems.contains(where:{($0.identifier as? String)=="displayStream"}),
              displayPeer.superview==nil else{throw Failure("Simplified display UI hierarchy invalid")}
        print("PASS actual UI hierarchy: sender checkbox, shared status, no display tab or address field")
        guard let menu=NSApp.mainMenu?.items.first?.submenu,menu.items.contains(where:{$0 === appUpdateCheck.checkItem}),menu.items.contains(where:{$0 === appUpdateCheck.availableItem}),appUpdateCheck.availableItem.isHidden else{throw Failure("Update menu hierarchy invalid")}
        print("PASS actual update menu: manual check and hidden passive availability item; offline")
        let destination = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        pinField.stringValue = ""
        peer.stringValue = ""
        displayPeer.stringValue = ""
        localAddress.stringValue = ""
        verifiedLocalIP = nil
        peerPicker.removeAllItems()
        peerPicker.addItem(withTitle: TCText("No devices in offline preview"))
        screenLayout.sourceSize = CGSize(width: 1512, height: 950)
        window.appearance = NSAppearance(named: .aqua)
        var report: [[String: Any]] = []
        for tab in settingsTabs.tabViewItems {
            guard let identifier = tab.identifier as? String else { throw Failure("Missing preview tab identifier") }
            settingsTabs.selectTabViewItem(tab)
            resizeForCurrentTab()
            guard let view = window.contentView else { throw Failure("Missing preview content") }
            view.layoutSubtreeIfNeeded()
            var controlCount = 0
            var visibleText: [String] = []
            func inspect(_ item: NSView) throws {
                guard !item.isHiddenOrHasHiddenAncestor else { return }
                if let button = item as? NSButton, !button.title.isEmpty {
                    let rect = button.convert(button.bounds, to: view)
                    guard rect.width > 0, rect.height > 0,
                          view.bounds.insetBy(dx: -1, dy: -1).contains(rect) else {
                        throw Failure("Localized button outside \(identifier)")
                    }
                    guard button.intrinsicContentSize.width <= button.bounds.width + 4 else {
                        throw Failure("Localized button title clipped in \(identifier)")
                    }
                    controlCount += 1
                    visibleText.append(button.title)
                }
                if let field = item as? NSTextField, !field.isEditable, !field.stringValue.isEmpty {
                    visibleText.append(field.stringValue)
                }
                for child in item.subviews { try inspect(child) }
            }
            try inspect(view)
            // Hidden WindowServer layers do not fully rasterize via cacheDisplay.
            // The view's print-render path draws native controls into an in-memory PDF,
            // then an image, without printing, ordering a window or capturing a display.
            let pdf = view.dataWithPDF(inside: view.bounds)
            guard let representation = NSPDFImageRep(data: pdf) else {
                throw Failure("Offscreen print representation unavailable")
            }
            let image = NSImage(size: view.bounds.size)
            image.lockFocus()
            NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
            view.bounds.fill()
            representation.draw(in: view.bounds)
            image.unlockFocus()
            guard let tiff = image.tiffRepresentation,
                  let composed = NSBitmapImageRep(data: tiff),
                  let png = composed.representation(using: .png, properties: [:]) else {
                throw Failure("Offscreen PNG unavailable")
            }
            try png.write(to: destination.appendingPathComponent(identifier + ".png"))
            report.append(["tab": identifier, "label": tab.label, "visibleButtons": controlCount,
                           "width": view.bounds.width, "height": view.bounds.height, "text": visibleText])
        }
        guard !window.isVisible, !NSApp.isActive, !relay.hasSession, !discoveryIsBrowsing,
              !relay.forward, !relay.inject, !relay.auto, pinField.stringValue.isEmpty,
              displayPeer.stringValue.isEmpty else { throw Failure("Offscreen preview safety changed") }
        let data = try JSONSerialization.data(withJSONObject: ["language": TCLocalization.preferredLanguage,
            "tabs": report, "windowVisible": window.isVisible, "appActive": NSApp.isActive,
            "relaySessionPresent": relay.hasSession, "discoveryBrowsing": discoveryIsBrowsing,
            "inputForwarding": relay.forward, "inputInjection": relay.inject,
            "pinFieldEmpty": pinField.stringValue.isEmpty,
            "scope": "Offscreen controls and guarded app state; not network packet instrumentation or a live-session test"], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: destination.appendingPathComponent("report.json"))
        print("PASS offscreen localized native controls: language=\(TCLocalization.preferredLanguage) tabs=\(report.count); inactive, hidden, sessionless, input off, PIN field empty")
    }
}
