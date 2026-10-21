import Foundation

/// No NSApplication, status items, windows, input, or activation-policy calls.
@MainActor
func runAppAppearancePreferencesTests() -> Int {
    var failures = 0
    var checks = 0
    func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        checks += 1
        if !condition() {
            failures += 1
            print("FAIL AppAppearancePreferences: \(name)")
        }
    }
    let suiteName = "ThunderControl.AppAppearancePreferencesTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        print("FAIL AppAppearancePreferences: isolated UserDefaults suite")
        return 1
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let initial = AppearancePreferences.load(from: defaults)
    check(initial == AppearancePreferences(showMenuBarIcon: true, hideDockIconWhileConnected: true),
          "missing values default to menu shown and connected Dock hiding checked")
    let controller = AppAppearanceController(defaults: defaults, nativeEffectsEnabled: false)
    var requests: [Bool] = []
    controller.onDockVisibilityRequested = { requests.append($0) }
    controller.install()
    check(controller.preferences == initial, "install loads preferences")
    check(controller.desiredDockVisibility, "disconnected Dock always visible")
    check(controller.isMenuBarIconRequested, "menu enabled by default")
    check(requests == [true], "install reports initial desired visibility")
    controller.install()
    controller.setConnected(false)
    controller.updatePreferences(initial)
    check(requests == [true], "duplicate installation and refresh are deduplicated")

    controller.setConnected(true)
    check(controller.isConnected && !controller.desiredDockVisibility, "connected default Dock hidden")
    check(requests == [true, false], "authenticated connection requests hiding")
    let hidden = AppearancePreferences(showMenuBarIcon: false, hideDockIconWhileConnected: true)
    controller.updatePreferences(hidden)
    check(controller.preferences == hidden, "public update stores both values")
    check(!controller.isMenuBarIconRequested, "menu can be hidden while connected")
    check(!controller.desiredDockVisibility, "connected Dock hides when hide preference is checked")
    check(requests == [true, false], "Dock hide requested once")
    controller.updatePreferences(hidden)
    controller.setConnected(true)
    check(requests == [true, false], "duplicate hidden state does not request again")

    controller.updatePreferences(AppearancePreferences(showMenuBarIcon: true, hideDockIconWhileConnected: true))
    check(controller.isMenuBarIconRequested && !controller.desiredDockVisibility,
          "menu visibility independent of hidden connected Dock")
    check(requests == [true, false], "menu-only changes do not request Dock visibility")
    controller.updatePreferences(hidden)
    controller.setConnected(false)
    check(controller.desiredDockVisibility && !controller.isMenuBarIconRequested,
          "disconnect restores Dock but not menu")
    check(requests == [true, false, true], "disconnect requests Dock restoration once")
    controller.setConnected(false)
    check(requests == [true, false, true], "duplicate disconnect deduplicated")
    check(controller.preferences.hideDockIconWhileConnected,
          "disconnect does not overwrite stored Dock preference")

    let restarted = AppAppearanceController(defaults: defaults, nativeEffectsEnabled: false)
    var restartedRequests: [Bool] = []
    restarted.onDockVisibilityRequested = { restartedRequests.append($0) }
    restarted.install()
    check(restarted.preferences == hidden, "menu hidden and Dock hiding checked survive controller restart")
    check(restarted.desiredDockVisibility, "restart begins disconnected and visible")
    restarted.setConnected(true)
    check(!restarted.desiredDockVisibility && !restarted.isMenuBarIconRequested,
          "reconnect honors persisted menu hidden and Dock hiding checked")
    restarted.setConnected(false)
    restarted.updatePreferences(AppearancePreferences(showMenuBarIcon: false, hideDockIconWhileConnected: false))
    restarted.setConnected(true)
    check(restarted.desiredDockVisibility && !restarted.isMenuBarIconRequested,
          "hidden menu does not hide connected Dock with hiding unchecked")
    check(restartedRequests == [true, false, true], "Dock requests track actual desired changes only")
    var willShowCount = 0
    restarted.onShowPreferences = { willShowCount += 1 }
    restarted.showPreferences()
    check(restarted.preferencesView == nil && willShowCount == 0,
          "native-disabled showPreferences does not create a view or invoke focus callback")
    controller.teardown()
    restarted.teardown()
    check(controller.preferencesView == nil, "pure tests never construct a native view")

    // Strings and numeric values must not be coerced to booleans.
    let malformed: [Any] = ["false", "true", "0", 0, 1, 2, 0.5, ["value": false], [false], Data([0])]
    for value in malformed {
        defaults.set(value, forKey: AppearancePreferences.menuBarDefaultsKey)
        defaults.set(value, forKey: AppearancePreferences.dockDefaultsKey)
        check(AppearancePreferences.load(from: defaults) == AppearancePreferences(),
              "malformed value defaults safely: \(type(of: value)) \(value)")
    }
    defaults.set(false, forKey: AppearancePreferences.menuBarDefaultsKey)
    defaults.set("invalid", forKey: AppearancePreferences.dockDefaultsKey)
    check(AppearancePreferences.load(from: defaults) == AppearancePreferences(showMenuBarIcon: false),
          "malformed Dock does not discard valid menu preference")
    defaults.removeObject(forKey: AppearancePreferences.menuBarDefaultsKey)
    defaults.set(true, forKey: AppearancePreferences.dockDefaultsKey)
    check(AppearancePreferences.load(from: defaults) == AppearancePreferences(hideDockIconWhileConnected: true),
          "missing menu does not discard valid Dock preference")
    let reloaded = AppAppearanceController(defaults: defaults, nativeEffectsEnabled: false)
    defaults.set(false, forKey: AppearancePreferences.menuBarDefaultsKey)
    reloaded.install()
    check(reloaded.preferences == hidden, "install reloads defaults changed after initialization")
    reloaded.teardown()
    // Legacy values migrate only when the new key is absent; loading never mutates storage.
    defaults.removeObject(forKey: AppearancePreferences.dockDefaultsKey)
    defaults.set(true, forKey: AppearancePreferences.legacyDockDefaultsKey)
    check(!AppearancePreferences.load(from: defaults).hideDockIconWhileConnected,
          "legacy show true migrates to hide false")
    check(defaults.object(forKey: AppearancePreferences.dockDefaultsKey) == nil,
          "loading legacy preferences does not rewrite storage")
    defaults.set(false, forKey: AppearancePreferences.legacyDockDefaultsKey)
    check(AppearancePreferences.load(from: defaults).hideDockIconWhileConnected,
          "legacy show false migrates to hide true")
    let migrated = AppearancePreferences.load(from: defaults)
    migrated.save(to: defaults)
    check(defaults.object(forKey: AppearancePreferences.dockDefaultsKey) as? Bool == true,
          "saving migration stores the actual hide flag under the new key")
    check(defaults.object(forKey: AppearancePreferences.legacyDockDefaultsKey) as? Bool == false,
          "saving preserves legacy key")
    defaults.set("owned sentinel", forKey: "unrelated.preference")
    AppearancePreferences(hideDockIconWhileConnected: false).save(to: defaults)
    check(defaults.string(forKey: "unrelated.preference") == "owned sentinel",
          "saving preserves unrelated preferences")
    check(!AppearancePreferences.load(from: defaults).hideDockIconWhileConnected,
          "new false overrides legacy show false")
    defaults.set(true, forKey: AppearancePreferences.legacyDockDefaultsKey)
    defaults.set(true, forKey: AppearancePreferences.dockDefaultsKey)
    check(AppearancePreferences.load(from: defaults).hideDockIconWhileConnected,
          "new true overrides legacy show true")
    defaults.set(true, forKey: AppearancePreferences.legacyDockDefaultsKey)
    for value in malformed {
        defaults.set(value, forKey: AppearancePreferences.dockDefaultsKey)
        check(AppearancePreferences.load(from: defaults).hideDockIconWhileConnected,
              "invalid present new hide flag falls back to true, never legacy: \(value)")
    }
    defaults.removeObject(forKey: AppearancePreferences.dockDefaultsKey)
    for value in malformed {
        defaults.set(value, forKey: AppearancePreferences.legacyDockDefaultsKey)
        check(AppearancePreferences.load(from: defaults).hideDockIconWhileConnected,
              "invalid legacy show flag falls back to hide true: \(value)")
    }
    defaults.removeObject(forKey: AppearancePreferences.legacyDockDefaultsKey)
    check(AppearancePreferences.load(from: defaults).hideDockIconWhileConnected,
          "both Dock keys missing keep connected Dock hiding checked")

    // Exercise the production upgrade using only this test-owned defaults suite.
    defaults.set(false, forKey: AppearancePreferences.menuBarDefaultsKey)
    defaults.set(false, forKey: AppearancePreferences.dockDefaultsKey)
    defaults.set(true, forKey: AppearancePreferences.legacyDockDefaultsKey)
    defaults.removeObject(forKey: AppearancePreferences.connectedBackgroundDefaultsKey)
    let untouched = AppAppearanceController(defaults: defaults, nativeEffectsEnabled: false)
    untouched.install()
    check(untouched.preferences == AppearancePreferences(showMenuBarIcon: false, hideDockIconWhileConnected: false),
          "native-disabled install preserves old explicit choices")
    check(defaults.object(forKey: AppearancePreferences.connectedBackgroundDefaultsKey) == nil,
          "native-disabled install never adopts production defaults")
    untouched.teardown()
    AppearancePreferences.adoptConnectedBackgroundDefaultsIfNeeded(in: defaults)
    check(AppearancePreferences.load(from: defaults) == AppearancePreferences(),
          "one-time adoption overrides old false menu and Dock hiding values")
    check(defaults.object(forKey: AppearancePreferences.connectedBackgroundDefaultsKey) as? Bool == true,
          "adoption records a strict true marker")
    check(defaults.object(forKey: AppearancePreferences.legacyDockDefaultsKey) as? Bool == true,
          "adoption preserves legacy preference")
    check(defaults.string(forKey: "unrelated.preference") == "owned sentinel",
          "adoption preserves unrelated preference")
    AppearancePreferences(showMenuBarIcon: false, hideDockIconWhileConnected: false).save(to: defaults)
    AppearancePreferences.adoptConnectedBackgroundDefaultsIfNeeded(in: defaults)
    let afterAdoption = AppAppearanceController(defaults: defaults, nativeEffectsEnabled: false)
    afterAdoption.install()
    check(!afterAdoption.preferences.showMenuBarIcon && !afterAdoption.preferences.hideDockIconWhileConnected,
          "next adoption and installation preserve later unchecked choices with true marker")
    afterAdoption.setConnected(true)
    check(afterAdoption.desiredDockVisibility,
          "explicit unchecked choice after adoption keeps connected Dock visible")
    afterAdoption.teardown()
    for marker in malformed + [false] {
        AppearancePreferences(showMenuBarIcon: false, hideDockIconWhileConnected: false).save(to: defaults)
        // Remove first: UserDefaults can coalesce numerically equal true and integer 1 writes.
        defaults.removeObject(forKey: AppearancePreferences.connectedBackgroundDefaultsKey)
        defaults.set(marker, forKey: AppearancePreferences.connectedBackgroundDefaultsKey)
        AppearancePreferences.adoptConnectedBackgroundDefaultsIfNeeded(in: defaults)
        check(AppearancePreferences.load(from: defaults) == AppearancePreferences(),
              "non-true or malformed marker reapplies adoption: \(marker)")
        check(defaults.object(forKey: AppearancePreferences.connectedBackgroundDefaultsKey) as? Bool == true,
              "adoption replaces malformed marker with true")
    }
    print("AppAppearancePreferences: \(checks) checks, \(failures) failures")
    return failures
}
