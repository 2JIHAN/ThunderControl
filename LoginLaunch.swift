import AppKit
import ServiceManagement

@MainActor extension App {
  /// Reset only as part of an explicit user-requested fresh installation.
  /// This records the request, not the current Login Items preference.
  static let loginLaunchRequestDefaultsKey = "loginLaunchRegistrationRequested"

  func installLoginLaunch() {
    guard !isAutomationTest,
          !CommandLine.arguments.contains("--self-test"),
          !CommandLine.arguments.contains("--pairing-integration-test"),
          Bundle.main.bundleURL == URL(fileURLWithPath: "/Applications/ThunderControl.app", isDirectory: true)
    else { return }

    let defaults = UserDefaults.standard
    let service = SMAppService.mainApp
    switch service.status {
    case .enabled:
      // Also remember an existing registration, so a later user disable is respected.
      defaults.set(true, forKey: Self.loginLaunchRequestDefaultsKey)
      return
    case .requiresApproval:
      defaults.set(true, forKey: Self.loginLaunchRequestDefaultsKey)
      loginApprovalButton.isHidden=false
      connectionLog("Login launch requires user approval in System Settings > General > Login Items.")
      return
    case .notRegistered, .notFound:
      break
    @unknown default:
      connectionLog("Login launch: unknown ServiceManagement status; no registration attempted.")
      return
    }

    guard !defaults.bool(forKey: Self.loginLaunchRequestDefaultsKey) else { return }
    // Persist before requesting, including on failure: never repeatedly override
    // the user's later Login Items choice or retry a failed request at startup.
    defaults.set(true, forKey: Self.loginLaunchRequestDefaultsKey)
    do {
      try service.register()
      if service.status == .requiresApproval {
        connectionLog("Login launch requires user approval in System Settings > General > Login Items.")
      }
    } catch {
      // Avoid localized descriptions/userInfo, which may contain private data.
      let failure = error as NSError
      connectionLog("Login launch registration failed (domain=\(failure.domain), code=\(failure.code)).")
    }
  }

  /// An explicit UI action only; startup never opens System Settings.
  @objc func openLoginItemsSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }
}
