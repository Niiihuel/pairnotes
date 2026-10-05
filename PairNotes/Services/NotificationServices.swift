import Foundation
import UIKit
import UserNotifications
import PairNotesCore

extension AppServices: UNUserNotificationCenterDelegate {
    var deviceID: String {
        let key = "PairNotes.installationID"
        if let value = UserDefaults.standard.string(forKey: key), UUID(uuidString: value) != nil { return value }
        let value = UUID().uuidString.lowercased()
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    func configureNotifications() { UNUserNotificationCenter.current().delegate = self }

    /// This is called only by the explicit notifications control in Nosotros.
    func enableNotifications() async throws -> Bool {
        let uid = try requireUID()
        let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        try checkUID(uid)
        UserDefaults.standard.set(granted, forKey: notificationPreferenceKey(uid))
        notificationsEnabled = granted
        if granted { UIApplication.shared.registerForRemoteNotifications() }
        return granted
    }

    func disableNotifications() async throws {
        let uid = try requireUID()
        UserDefaults.standard.set(false, forKey: notificationPreferenceKey(uid))
        notificationsEnabled = false
        UIApplication.shared.unregisterForRemoteNotifications()
        // Does not revoke the independent widget push registration or credential.
        _ = try await call("registerDevice", ["deviceId": deviceID, "apnsToken": NSNull()])
    }

    func restoreNotificationPreference() async {
        guard let uid = try? requireUID(), UserDefaults.standard.bool(forKey: notificationPreferenceKey(uid)) else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard (try? requireUID()) == uid else { return }
        notificationsEnabled = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        if notificationsEnabled {
            UIApplication.shared.registerForRemoteNotifications()
            if let pendingAPNsToken { try? await registerAPNsToken(pendingAPNsToken) }
        } else {
            _ = try? await call("registerDevice", ["deviceId": deviceID, "apnsToken": NSNull()])
        }
    }

    func didRegisterAPNsToken(_ token: Data) {
        pendingAPNsToken = token
        Task {
            do { try await registerAPNsToken(token) } catch { recordError(error) }
        }
    }

    private func registerAPNsToken(_ token: Data) async throws {
        guard notificationsEnabled, let uid = try? requireUID(),
              UserDefaults.standard.bool(forKey: notificationPreferenceKey(uid)) else { return }
        let hex = token.map { String(format: "%02x", $0) }.joined()
        let environment = try requireClient().configuration.apnsEnvironment
        _ = try await call("registerDevice", ["deviceId": deviceID, "apnsToken": hex, "apnsEnvironment": environment])
        try checkUID(uid)
    }

    func registerWidgetPushToken(_ token: Data) async throws {
        guard !token.isEmpty else { throw ServiceError.invalidResponse }
        let hex = token.map { String(format: "%02x", $0) }.joined()
        let environment = try requireClient().configuration.apnsEnvironment
        _ = try await call("registerDevice", ["deviceId": deviceID, "widgetPushToken": hex,
                                              "apnsEnvironment": environment, "widgetPushEnvironment": environment])
    }

    func issueWidgetSession() async throws -> WidgetAuthorization {
        let uid = try requireUID()
        guard let pair = membership, let base = widgetBaseURL else { throw ServiceError.noPair }
        _ = try await call("registerDevice", ["deviceId": deviceID])
        try checkSpaceContext(uid: uid, pair: pair)
        let response = try await call("issueWidgetSession", ["deviceId": deviceID])
        try checkUID(uid)
        guard membership?.id == pair.id, membership?.pairEpoch == pair.pairEpoch,
              let token = response["token"] as? String, let expiresAt = response["expiresAt"] as? NSNumber else {
            throw ServiceError.sessionChanged
        }
        return WidgetAuthorization(token: token, expiresAt: Date(timeIntervalSince1970: expiresAt.doubleValue / 1_000),
                                   baseURL: base, uid: uid, pairID: pair.id, pairEpoch: pair.pairEpoch, deviceID: deviceID,
                                   apnsEnvironment: try requireClient().configuration.apnsEnvironment)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                             willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        await MainActor.run { onReceivedNote?() }
        return [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if response.notification.request.content.userInfo["type"] as? String == "monthlyAnniversary" {
            await MainActor.run { onOpenCouple?() }
            return
        }
        let info = response.notification.request.content.userInfo
        if let type = info["type"] as? String, ["letter", "gesture", "reaction"].contains(type) {
            let pairID = info["pairId"] as? String
            let epoch = (info["pairEpoch"] as? NSNumber)?.uint64Value
            let letterID = info["letterId"] as? String
            let noteID = info["noteId"] as? String
            await MainActor.run {
                guard let pairID, let epoch else { return }
                pendingAffectionRoute = PendingAffectionRoute(type: type, pairID: pairID, epoch: epoch,
                    letterID: letterID, noteID: noteID)
                deliverPendingAffectionRoute()
            }
            return
        }
        if response.notification.request.content.userInfo["type"] as? String == "message" {
            await MainActor.run { onOpenMessages?(); onReceivedNote?() }
            return
        }
        guard let noteID = response.notification.request.content.userInfo["noteId"] as? String,
              UUID(uuidString: noteID) != nil else { return }
        await MainActor.run { onOpenNote?(noteID) }
    }

    /// A notification can launch the process before RootView and membership are ready.
    func deliverPendingAffectionRoute() {
        guard membershipResolved, let route = pendingAffectionRoute,
              onOpenLetters != nil, onOpenHome != nil, onOpenNote != nil else { return }
        pendingAffectionRoute = nil
        guard route.pairID == membership?.id, route.epoch == membership?.pairEpoch else { return }
        if route.type == "letter" { onOpenLetters?(route.letterID) }
        else if route.type == "gesture" { onOpenHome?() }
        else if let id = route.noteID { onOpenNote?(id) }
        onReceivedNote?()
    }

    private func notificationPreferenceKey(_ uid: String) -> String { "PairNotes.notifications.\(uid)" }
}

@MainActor
final class PairNotesApplicationDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = AppServices.shared
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        AppServices.shared.didRegisterAPNsToken(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        AppServices.shared.recordError(error)
    }

}
