import Foundation
import UserNotifications

/// Display-only state. Call connected only after the relay authenticates its peer.
struct ConnectionNotificationTracker {
    struct Event: Equatable {
        let title: String
        let body: String
    }
    private var active: (name: String, sender: Bool)?

    mutating func connected(peerName: String, localIsSender: Bool) -> Event? {
        // Repeated relay callbacks are not new connections, even if display metadata changes.
        guard active == nil else { return nil }
        let name = Self.displayName(peerName)
        active = (name, localIsSender)
        return Event(title: TCText("Connection Established"), body: "\(localIsSender ? TCText("Receiving Mac") : TCText("Sending Mac")): \(name)")
    }

    mutating func disconnected() -> Event? {
        guard let peer = active else { return nil }
        active = nil
        return Event(title: TCText("Disconnected"), body: "\(peer.sender ? TCText("Receiving Mac") : TCText("Sending Mac")): \(peer.name)")
    }

    static func displayName(_ name: String) -> String {
        let clean = name.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) &&
            !CharacterSet.illegalCharacters.contains($0) &&
            $0.properties.generalCategory != .format &&
            $0.value != 0x2028 && $0.value != 0x2029
        }
        var result = ""
        var bytes = 0
        for scalar in clean {
            let size = String(scalar).utf8.count
            guard bytes + size <= 128 else { break }
            result.unicodeScalars.append(scalar)
            bytes += size
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? TCText("Bridge peer") : result
    }

    static func disablesNativeWork(arguments: [String]) -> Bool {
        let flags: Set<String> = ["--self-test", "--pairing-integration-test", "--ui-smoke-test", "--ui-ownership-test"]
        return arguments.contains { flags.contains($0) }
    }
}

@MainActor
final class ConnectionNotifications: NSObject, UNUserNotificationCenterDelegate {
    private static let identifier = "ThunderControl.connection-status"
    private var tracker = ConnectionNotificationTracker()
    private let nativeDisabled: Bool
    private let testDelivery: ((ConnectionNotificationTracker.Event) -> Void)?
    private let testAuthorization: (() -> Void)?
    var permissionActionRequired:(()->Void)?
    var permissionStateChanged:((Bool)->Void)?
    private var authorizationRequested = false
    private var deliveryTask: Task<Void, Never>?
    // In particular, initialization during CLI tests never touches the native center.
    private lazy var center: UNUserNotificationCenter = {
        let value = UNUserNotificationCenter.current()
        value.delegate = self
        return value
    }()

    override init() {
        nativeDisabled = ConnectionNotificationTracker.disablesNativeWork(arguments: CommandLine.arguments)
        testDelivery = nil
        testAuthorization = nil
        super.init()
    }

    /// Injection is always native-free, including settings queries and delegate registration.
    init(deliver: @escaping (ConnectionNotificationTracker.Event) -> Void,
         requestAuthorization: @escaping () -> Void = {}) {
        nativeDisabled = true
        testDelivery = deliver
        testAuthorization = requestAuthorization
        super.init()
    }

    func requestAuthorizationIfNeeded(forceRetry:Bool=false) {
        guard !authorizationRequested || forceRetry else { return }
        authorizationRequested = true
        if let request = testAuthorization { request(); return }
        guard !nativeDisabled else { return }
        let center = self.center
        Task {
            let settings = await center.notificationSettings()
            connectionLog("Connection notifications authorization status=\(settings.authorizationStatus.rawValue)")
            let needsPermission=settings.authorizationStatus != .authorized && settings.authorizationStatus != .provisional
            permissionStateChanged?(needsPermission)
            guard settings.authorizationStatus == .notDetermined else {if forceRetry && needsPermission {permissionActionRequired?()};return}
            do {
                let allowed = try await center.requestAuthorization(options: [.alert])
                permissionStateChanged?(!allowed)
                if !allowed {connectionLog("Connection notifications permission not granted");if forceRetry {permissionActionRequired?()}}
            } catch {
                let detail=error as NSError
                connectionLog("Connection notifications permission request failed domain=\(detail.domain) code=\(detail.code)")
                permissionStateChanged?(true);if forceRetry {permissionActionRequired?()}
            }
        }
    }

    func connected(peerName: String, localIsSender: Bool) {
        if let event = tracker.connected(peerName: peerName, localIsSender: localIsSender) { deliver(event) }
    }

    func disconnected() {
        if let event = tracker.disconnected() { deliver(event) }
    }

    private func deliver(_ event: ConnectionNotificationTracker.Event) {
        if let injected = testDelivery { injected(event); return }
        guard !nativeDisabled else { return }
        let center = self.center
        let previous = deliveryTask
        // Serialize replacement so delayed authorization/settings callbacks cannot reorder events.
        deliveryTask = Task {
            await previous?.value
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {connectionLog("Connection banner skipped; authorization status=\(settings.authorizationStatus.rawValue)");return}
            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = event.body
            content.sound = nil
            center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
            center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
            do {
                try await center.add(UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil))
            } catch {
                connectionLog("Connection notification delivery failed")
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(ConnectionNotificationTracker.disablesNativeWork(arguments: CommandLine.arguments) ? [] : [.banner])
    }
}
