import SwiftUI

/// The menu-bar dropdown — a Phone Hub-style panel: phone status header, quick
/// actions, notifications (with inline reply), and recent photos.
struct PanelView: View {
    @EnvironmentObject var engine: PhoneHubEngine
    @Environment(\.openSettings) private var openSettings
    @State private var pulse = 0.0   // slow flash for the status dot while connecting

    private var headerSubtitle: String {
        if engine.btGate.isDenied { return "Needs Bluetooth permission" }
        if engine.btGate.isUnknown { return "Waiting for Bluetooth…" }
        switch engine.status {
        case .connected:
            if let d = engine.phone.lastUpdated {
                return "Last synced \(d.formatted(date: .omitted, time: .shortened))"
            }
            return "Connected"
        case .error(let m): return m
        default: return engine.status.label   // Waking phone… / Connecting… / Not connected
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if engine.status == .connected {
                quickActions
                hotspotBar
                Divider().opacity(0.4)
                notificationsSection
                if !engine.photos.isEmpty { photosSection }
            } else {
                connectCard
            }
            footer
        }
        .padding(14)
        .frame(width: 360)
        .focusEffectDisabled()
        .onAppear { pulse = 1 }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Palette.accent.opacity(0.15)).frame(width: 44, height: 44)
                Image(systemName: "iphone.gen3").font(.title2).foregroundStyle(Palette.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(engine.config.phoneName).font(.headline)
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                        .opacity(engine.status.isBusy ? (0.3 + 0.7 * pulse) : 1)
                        .animation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true), value: pulse)
                }
                Text(headerSubtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if engine.status == .connected {
                VStack(alignment: .trailing, spacing: 4) {
                    if let b = engine.phone.battery {
                        StatPill(systemImage: engine.phone.charging ? "battery.100.bolt" : batteryIcon(b),
                                 text: "\(b)%", tint: b <= 15 ? Palette.warn : .secondary)
                    }
                    if let bars = engine.phone.signalBars {
                        StatPill(systemImage: "cellularbars", text: engine.phone.carrier.isEmpty ? "\(bars)/4" : engine.phone.carrier)
                    }
                }
            }
        }
    }

    private var statusColor: Color {
        switch engine.status {
        case .connected: return Palette.good
        case .arming, .connecting: return Palette.warn
        case .error: return .red
        case .disconnected: return .secondary
        }
    }

    /// Open Settings and close the menu-bar popover so it doesn't linger behind it.
    private func openSettingsDismissingPanel() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
        DispatchQueue.main.async {
            for w in NSApp.windows {
                let cls = String(describing: type(of: w))
                if cls.contains("MenuBarExtra") { w.close() }                 // dismiss the popover
                else if w.isVisible && !w.title.isEmpty { w.makeKeyAndOrderFront(nil) }  // front Settings if already open
            }
        }
    }

    private func openBluetoothSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
            NSWorkspace.shared.open(url)
        }
    }

    private func batteryIcon(_ b: Int) -> String {
        switch b { case ..<13: return "battery.0"; case ..<38: return "battery.25"
        case ..<63: return "battery.50"; case ..<88: return "battery.75"; default: return "battery.100" }
    }

    // MARK: connect card (disconnected)

    private var connectCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.system(size: 34)).foregroundStyle(.secondary)
            if engine.btGate.isDenied {
                Text("PhoneHub needs Bluetooth").font(.subheadline).foregroundStyle(.red)
                Button { openBluetoothSettings() } label: {
                    Label("Open Bluetooth Settings", systemImage: "gearshape").frame(maxWidth: .infinity)
                }
                .controlSize(.large).buttonStyle(.borderedProminent).tint(Palette.accent)
            } else if engine.btGate.isUnknown {
                Text("Allow Bluetooth to connect").font(.subheadline).foregroundStyle(.secondary)
                Text("Click Allow on the macOS prompt.").font(.caption).foregroundStyle(.tertiary)
            } else if engine.config.phoneBtMac.isEmpty {
                Text("Set up your phone in Settings").font(.subheadline).foregroundStyle(.secondary)
                Button { openSettings() } label: {
                    Label("Open Settings", systemImage: "gearshape").frame(maxWidth: .infinity)
                }
                .controlSize(.large).buttonStyle(.borderedProminent).tint(Palette.accent)
            } else if engine.status.isBusy {
                // Connecting: no button, just the status + a spinner.
                Text(engine.status.label).font(.subheadline).foregroundStyle(.secondary)
                ProgressView().controlSize(.small)
            } else {
                if case .error(let m) = engine.status {
                    Text(m).font(.subheadline).foregroundStyle(.red).multilineTextAlignment(.center)
                } else {
                    Text("Not connected").font(.subheadline).foregroundStyle(.secondary)
                }
                Button { engine.connect() } label: {
                    Label("Connect", systemImage: "antenna.radiowaves.left.and.right").frame(maxWidth: .infinity)
                }
                .controlSize(.large).buttonStyle(.borderedProminent).tint(Palette.accent)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 16)
    }

    // MARK: quick actions

    private var quickActions: some View {
        HStack(spacing: 10) {
            QuickAction(icon: "bell.and.waves.left.and.right", title: "Ring") { engine.ring() }
            QuickAction(icon: "photo.on.rectangle", title: "Photos") { engine.refreshPhotos() }
            QuickAction(icon: "arrow.clockwise", title: "Refresh") { engine.refreshPhotos() }
        }
    }

    // MARK: hotspot (Instant Tethering)

    @ViewBuilder private var hotspotBar: some View {
        if engine.hotspot != .off {
            Button {
                switch engine.hotspot {
                case .available, .failed: engine.enableHotspot()
                default: break
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: hotspotIcon).foregroundStyle(hotspotTint)
                    Text(engine.hotspot.label).font(.caption).lineLimit(1)
                    Spacer()
                    if isHotspotBusy { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .frame(maxWidth: .infinity)
                .glassCard(cornerRadius: 12)
            }
            .buttonStyle(.plain)
            .disabled(isHotspotBusy)
        }
    }

    private var isHotspotBusy: Bool {
        if case .turningOn = engine.hotspot { return true }
        if case .joining = engine.hotspot { return true }
        return false
    }

    private var hotspotIcon: String {
        switch engine.hotspot {
        case .joined: return "wifi"
        case .failed: return "wifi.exclamationmark"
        default: return "personalhotspot"
        }
    }

    private var hotspotTint: Color {
        switch engine.hotspot {
        case .joined: return Palette.good
        case .failed: return .red
        default: return Palette.accent
        }
    }

    // MARK: notifications

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notifications").sectionLabelStyle()
            if engine.notifications.isEmpty {
                Text("No notifications").font(.caption).foregroundStyle(.secondary).padding(.vertical, 6)
            } else {
                ForEach(engine.notifications) { note in
                    NotificationRow(note: note)
                }
            }
        }
    }

    // MARK: photos

    private var photosSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent Photos").sectionLabelStyle()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(engine.photos) { photo in PhotoThumb(photo: photo) }
                }
            }
        }
    }

    // MARK: footer

    private var footer: some View {
        VStack(spacing: 1) {
            Divider().padding(.horizontal, -14).padding(.bottom, 3)
            MenuRow(title: "Settings…", shortcut: "⌘,") { openSettingsDismissingPanel() }
            MenuRow(title: "Quit PhoneHub", shortcut: "⌘Q") { NSApplication.shared.terminate(nil) }
        }
        .padding(.horizontal, -8)
    }
}

/// A full-width row styled like a native menu item: accent-fill highlight on
/// hover, optional keyboard-shortcut hint on the right.
private struct MenuRow: View {
    let title: String
    var shortcut: String? = nil
    var destructive = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let s = shortcut {
                    Text(s).foregroundStyle(hover ? .white.opacity(0.85) : .secondary)
                }
            }
            .foregroundStyle(hover ? .white : (destructive ? .red : .primary))
            .padding(.vertical, 3).padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .background(hover ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).font(.callout)
        .onHover { hover = $0 }
    }
}

private struct QuickAction: View {
    let icon: String, title: String, action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 10)
            .glassCard(cornerRadius: 12)
        }
        .buttonStyle(.plain)
    }
}
