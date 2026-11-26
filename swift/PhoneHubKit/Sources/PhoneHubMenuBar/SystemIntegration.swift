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

    /// Ask the OS for permission; if it can't be granted in-app (already decided,
    /// or an unsigned build gets no prompt), open System Settings so the user can
    /// flip it there. Either way, something happens.
    func toggleNotifications(_ on: Bool) {
        guard on else { openNotificationSettings(); return }   // can't revoke from here
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in
                self.refresh()
                if !granted { self.openNotificationSettings() }
            }
        }
    }

    func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }
}
