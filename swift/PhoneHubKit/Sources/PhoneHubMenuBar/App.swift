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
            MenuBarLabel(engine: engine)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environmentObject(engine)
                .frame(width: 520, height: 480)
        }

        Window("Set up a phone", id: "wizard") {
            SetupWizardView().environmentObject(engine)
        }
        .windowResizability(.contentSize)
    }
}

/// The menu-bar item: the phone's live carrier, signal, and battery when
/// connected; otherwise a status icon.
private struct MenuBarLabel: View {
    @ObservedObject var engine: PhoneHubEngine

    var body: some View {
        if engine.status == .connected {
            HStack(spacing: 3) {
                if let bars = engine.phone.signalBars {
                    Image(systemName: "cellularbars", variableValue: max(0.15, Double(bars) / 4.0))
                }
                if !engine.phone.carrier.isEmpty { Text(engine.phone.carrier) }
                if let b = engine.phone.battery {
                    Image(systemName: engine.phone.charging ? "battery.100.bolt" : batteryIcon(b))
                    Text("\(b)%")
                }
            }
        } else {
            Image(systemName: statusIcon)
        }
    }

    private var statusIcon: String {
        switch engine.status {
        case .connected: return "iphone.gen3"
        case .arming, .connecting: return "iphone.gen3.radiowaves.left.and.right"
        default: return "iphone.slash"
        }
    }

    private func batteryIcon(_ b: Int) -> String {
        switch b { case ..<13: return "battery.0"; case ..<38: return "battery.25"
        case ..<63: return "battery.50"; case ..<88: return "battery.75"; default: return "battery.100" }
    }
}
