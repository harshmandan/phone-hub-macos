import SwiftUI

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
                .frame(width: 520, height: 460)
        }
    }

    private var menuIcon: String {
        switch engine.status {
        case .connected: return "iphone.gen3"
        case .arming, .connecting: return "iphone.gen3.radiowaves.left.and.right"
        default: return "iphone.slash"
        }
    }
}
