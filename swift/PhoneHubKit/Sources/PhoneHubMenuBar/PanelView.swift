import SwiftUI

/// The menu-bar dropdown — a Phone Hub-style panel: phone status header, quick
/// actions, notifications (with inline reply), and recent photos.
struct PanelView: View {
    @EnvironmentObject var engine: PhoneHubEngine
    @Environment(\.openSettings) private var openSettings

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
        default: return engine.step.isEmpty ? engine.status.label : engine.step
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if engine.status == .connected {
                quickActions
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
                    PulseDot(color: statusColor, active: engine.status.isBusy)
                }
                if engine.status == .connected {
                    SyncLabel(lastUpdated: engine.phone.lastUpdated) { engine.refreshPhotos() }
                } else {
                    Text(headerSubtitle).font(.caption).foregroundStyle(.secondary)
                }
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
                Text("Click Allow on the macOS prompt. If you dismissed it, open Settings.")
                    .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                Button { openBluetoothSettings() } label: {
                    Label("Open Bluetooth Settings", systemImage: "gearshape").frame(maxWidth: .infinity)
                }
                .controlSize(.large).buttonStyle(.bordered)
            } else if engine.config.phoneBtMac.isEmpty {
                Text("Set up your phone in Settings").font(.subheadline).foregroundStyle(.secondary)
                Button { openSettings() } label: {
                    Label("Open Settings", systemImage: "gearshape").frame(maxWidth: .infinity)
                }
                .controlSize(.large).buttonStyle(.borderedProminent).tint(Palette.accent)
            } else if engine.status.isBusy {
                // Connecting: no button, just the live step + a spinner.
                Text(engine.step.isEmpty ? engine.status.label : engine.step)
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
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
            hotspotAction
        }
    }

    // MARK: hotspot (Instant Tethering) — third quick action

    private var hotspotAction: some View {
        Button {
            switch engine.hotspot {
            case .off, .available, .failed: engine.enableHotspot()
            default: break
            }
        } label: {
            VStack(spacing: 5) {
                if isHotspotBusy {
                    ProgressView().controlSize(.small).frame(height: 20)
                } else {
                    Image(systemName: hotspotIcon).font(.title3).foregroundStyle(hotspotTint)
                }
                Text(hotspotTitle).font(.caption2).lineLimit(1)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 10)
            .glassCard(cornerRadius: 12)
        }
        .buttonStyle(.plain)
        .disabled(isHotspotBusy)
    }

    private var hotspotTitle: String {
        switch engine.hotspot {
        case .off, .available: return "Hotspot"
        case .turningOn: return "Turning on"
        case .joining: return "Joining"
        case .joined: return "On hotspot"
        case .failed: return "Retry"
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

/// Status dot. While busy it pulses opacity, driven purely by a TimelineView
/// clock (no implicit .animation), so it never animates layout — the dot and the
/// rows around it stay put instead of sliding.
private struct PulseDot: View {
    let color: Color
    let active: Bool
    var body: some View {
        Group {
            if active {
                TimelineView(.animation) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    let o = 0.4 + 0.6 * (0.5 + 0.5 * sin(t * 2.6))   // smooth 0.4–1.0
                    Circle().fill(color).opacity(o)
                }
            } else {
                Circle().fill(color)
            }
        }
        .frame(width: 8, height: 8)
    }
}

/// The header "Last synced …" label. Shows a small refresh glyph; the time ticks
/// live (5s buckets). Hovering turns it into a "Refresh now" text link.
private struct SyncLabel: View {
    let lastUpdated: Date?
    let refresh: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: refresh) {
            TimelineView(.periodic(from: .now, by: 5)) { ctx in
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise").font(.caption2)
                    if hover {
                        Text("Refresh now")
                    } else if let d = lastUpdated {
                        Text("Last synced \(relativeTime(since: d, now: ctx.date))")
                    } else {
                        Text("Syncing…")
                    }
                }
                .font(.caption)
                .foregroundStyle(hover ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(.secondary))
            }
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Refresh now")
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
