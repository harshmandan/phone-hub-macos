import Foundation
import ServiceManagement
import UserNotifications
import AppKit

/// macOS system hooks the Settings view shows status for: start-at-login (a login
/// item) and notification permission. We can set the login item directly; the
/// notification permission is the OS's, so we can only request it or deep-link to
/// System Settings.
@MainActor final class SystemIntegration: ObservableObject {
    @Published var startAtLogin = false
    @Published var notificationsAuthorized = false
    @Published var notificationsDetermined = false   // false = never asked yet

    init() { refresh() }

    func refresh() {
        startAtLogin = SMAppService.mainApp.status == .enabled
        UNUserNotificationCenter.current().getNotificationSettings { s in
            Task { @MainActor in
                self.notificationsAuthorized = s.authorizationStatus == .authorized
                self.notificationsDetermined = s.authorizationStatus != .notDetermined
            }
        }
    }

    func setStartAtLogin(_ on: Bool) {
        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
        catch { NSLog("start-at-login \(on ? "register" : "unregister") failed: \(error)") }
        refresh()
    }

    /// First time: ask the OS. After that the choice is locked, so send the user to
    /// System Settings to change it.
    func enableNotifications() {
        if notificationsDetermined {
            openNotificationSettings()
        } else {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
                Task { @MainActor in self.refresh() }
            }
        }
    }

    func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }
}
