import SwiftUI
import AppKit

/// A menu-bar (accessory) app doesn't activate its windows by default, so Settings
/// and the sign-in window open unfocused, with no dock icon and a stale menu bar.
/// Switch to a regular policy (dock icon + menu + focus) while such a window is
/// open, and back to accessory once the last one closes.
@MainActor enum WindowActivation {
    private static var count = 0
    static func enter() {
        count += 1
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    static func leave() {
        count = max(0, count - 1)
        if count == 0 { NSApp.setActivationPolicy(.accessory) }
    }
}

@main
struct PhoneHubApp: App {
    @StateObject private var engine = PhoneHubEngine(config: ConfigStore.load())

    var body: some Scene {
        MenuBarExtra {
            PanelView().environmentObject(engine)
        } label: {
            Image(systemName: menuIcon)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environmentObject(engine)
                .frame(width: 520, height: 480)
        }

        Window("Sign in to Google", id: "signin") {
            SignInView().environmentObject(engine)
        }
        .windowResizability(.contentSize)
    }

    private var menuIcon: String {
        switch engine.status {
        case .connected: return "iphone.gen3"
        case .arming, .connecting: return "iphone.gen3.radiowaves.left.and.right"
        default: return "iphone.slash"
        }
    }
}
