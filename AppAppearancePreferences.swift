import AppKit
import CoreFoundation

/// Strict booleans with connected-background defaults; no application policy or window effects.
public struct AppearancePreferences: Equatable {
    public static let menuBarDefaultsKey = "ThunderControl.appearance.showMenuBarIcon"
    public static let dockDefaultsKey = "ThunderControl.appearance.hideDockIconWhileConnected"
    public static let legacyDockDefaultsKey = "ThunderControl.appearance.showDockIconWhileConnected"

    public static let connectedBackgroundDefaultsKey = "ThunderControl.appearance.connectedBackgroundDefaults.v1"

    public var showMenuBarIcon: Bool
    public var hideDockIconWhileConnected: Bool

    public init(showMenuBarIcon: Bool = true, hideDockIconWhileConnected: Bool = true) {
        self.showMenuBarIcon = showMenuBarIcon
        self.hideDockIconWhileConnected = hideDockIconWhileConnected
    }

    public static func load(from defaults: UserDefaults) -> AppearancePreferences {
        func boolean(for key: String) -> Bool? {
            guard let value = defaults.object(forKey: key) as? NSNumber,
                  CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
            return value.boolValue
        }
        let hideDock: Bool
        if defaults.object(forKey: dockDefaultsKey) != nil {
            // An invalid new value must not fall through to the legacy preference.
            hideDock = boolean(for: dockDefaultsKey) ?? true
        } else {
            hideDock = boolean(for: legacyDockDefaultsKey).map { !$0 } ?? true
        }
        return AppearancePreferences(showMenuBarIcon: boolean(for: menuBarDefaultsKey) ?? true,
                                     hideDockIconWhileConnected: hideDock)
    }

    /// Adopt this release's requested behavior once, retaining later explicit user choices.
    public static func adoptConnectedBackgroundDefaultsIfNeeded(in defaults: UserDefaults) {
        if let marker = defaults.object(forKey: connectedBackgroundDefaultsKey) as? NSNumber,
           CFGetTypeID(marker) == CFBooleanGetTypeID(), marker.boolValue { return }
        defaults.set(true, forKey: menuBarDefaultsKey)
        defaults.set(true, forKey: dockDefaultsKey)
        defaults.set(true, forKey: connectedBackgroundDefaultsKey)
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(showMenuBarIcon, forKey: Self.menuBarDefaultsKey)
        defaults.set(hideDockIconWhileConnected, forKey: Self.dockDefaultsKey)
    }
}

/// Reports desired Dock visibility; the parent alone owns activation policy and safe input focus.
@MainActor
public final class AppAppearanceController: NSObject {
    public var onShowConnection: (() -> Void)?
    public var onStop: (() -> Void)?
    public var onQuit: (() -> Void)?
    public var onDockVisibilityRequested: ((Bool) -> Void)?
    public var onShowPreferences: (() -> Void)?

    public private(set) var preferences: AppearancePreferences
    public private(set) var isConnected = false
    public private(set) var preferencesView: NSView?
    public var desiredDockVisibility: Bool {
        !isConnected || !preferences.hideDockIconWhileConnected
    }
    public var isMenuBarIconRequested: Bool { preferences.showMenuBarIcon }

    private let defaults: UserDefaults
    private let nativeEffectsEnabled: Bool
    private var statusItem: NSStatusItem?
    private var lastRequestedDockVisibility: Bool?
    private var menuBarCheckbox: NSButton?
    private var dockCheckbox: NSButton?

    public init(defaults: UserDefaults = .standard, nativeEffectsEnabled: Bool = true) {
        self.defaults = defaults
        self.nativeEffectsEnabled = nativeEffectsEnabled
        self.preferences = AppearancePreferences.load(from: defaults)
        super.init()
    }

    public func install() {
        if nativeEffectsEnabled {
            AppearancePreferences.adoptConnectedBackgroundDefaultsIfNeeded(in: defaults)
        }
        preferences = AppearancePreferences.load(from: defaults)
        refreshAppearance()
    }

    /// Call with authenticated connection state, not transport-discovery state.
    public func setConnected(_ connected: Bool) {
        guard connected != isConnected else { return }
        isConnected = connected
        refreshAppearance()
    }

    public func updatePreferences(_ value: AppearancePreferences) {
        preferences = value
        value.save(to: defaults)
        refreshAppearance()
    }

    public func showPreferences() {
        guard nativeEffectsEnabled else { return }
        onShowPreferences?()
    }

    /// Reusable embedded tab content. No second window is created.
    public func makePreferencesView() -> NSView {
        if let view=preferencesView {return view}
        let view=NSView(frame:NSRect(x:0,y:0,width:520,height:160))
        let menu = NSButton(checkboxWithTitle: TCText("Show menu bar icon"), target: self,
                            action: #selector(preferencesChanged(_:)))
        let dock = NSButton(checkboxWithTitle: TCText("Hide Dock icon while connected"), target: self,
                            action: #selector(preferencesChanged(_:)))
        let help = NSTextField(wrappingLabelWithString: TCText("The app window also hides automatically when connected. The Dock icon and window reappear when disconnected."))
        help.font = .systemFont(ofSize: 12)
        help.textColor = .secondaryLabelColor
        help.translatesAutoresizingMaskIntoConstraints = false
        help.widthAnchor.constraint(equalToConstant: 380).isActive = true
        let stack = NSStackView(views: [menu, dock, help])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        do {
            let content=view
            content.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -28),
                stack.centerYAnchor.constraint(equalTo: content.centerYAnchor)
            ])
        }
        menuBarCheckbox = menu
        dockCheckbox = dock
        preferencesView = view
        refreshCheckboxes()
        return view
    }

    public func teardown() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func refreshAppearance() {
        refreshCheckboxes()
        if nativeEffectsEnabled { refreshStatusItem() }
        let visible = desiredDockVisibility
        guard visible != lastRequestedDockVisibility else { return }
        lastRequestedDockVisibility = visible
        onDockVisibilityRequested?(visible)
    }

    private func refreshCheckboxes() {
        menuBarCheckbox?.state = preferences.showMenuBarIcon ? .on : .off
        dockCheckbox?.state = preferences.hideDockIconWhileConnected ? .on : .off
    }

    private func refreshStatusItem() {
        guard preferences.showMenuBarIcon else {
            if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
            statusItem = nil
            return
        }
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let image = Bundle.main.url(forResource:"ThunderControlMenuBarTemplate",withExtension:"png").flatMap {NSImage(contentsOf:$0)}
                ?? NSImage(systemSymbolName:"display.2",accessibilityDescription:"ThunderControl")
            image?.size = NSSize(width: 20, height: 20)
            image?.isTemplate = true
            item.button?.image = image
            let menu = NSMenu()
            menu.addItem(menuItem(TCText("Open Connection Window"), action: #selector(showConnectionAction)))
            menu.addItem(menuItem(TCText("Settings..."), action: #selector(showPreferencesAction)))
            menu.addItem(.separator())
            menu.addItem(menuItem(TCText("Stop Sharing"), action: #selector(stopAction)))
            menu.addItem(menuItem(TCText("Quit ThunderControl"), action: #selector(quitAction)))
            item.menu = menu
            statusItem = item
        }
        statusItem?.button?.toolTip = isConnected ? TCText("ThunderControl: Connected") : TCText("ThunderControl: Not Connected")
    }

    private func menuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func preferencesChanged(_ sender: NSButton) {
        updatePreferences(AppearancePreferences(showMenuBarIcon: menuBarCheckbox?.state == .on,
                                               hideDockIconWhileConnected: dockCheckbox?.state == .on))
    }
    @objc private func showConnectionAction() { onShowConnection?() }
    @objc private func showPreferencesAction() { showPreferences() }
    @objc private func stopAction() { onStop?() }
    @objc private func quitAction() { onQuit?() }
}
