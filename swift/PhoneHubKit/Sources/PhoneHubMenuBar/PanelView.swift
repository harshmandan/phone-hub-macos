import SwiftUI

/// The menu-bar dropdown — a Phone Hub-style panel: phone status header, quick
/// actions, notifications (with inline reply), and recent photos.
struct PanelView: View {
    @EnvironmentObject var engine: PhoneHubEngine
    @Environment(\.openSettings) private var openSettings

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
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Palette.accent.opacity(0.15)).frame(width: 44, height: 44)
                Image(systemName: "iphone.gen3").font(.title2).foregroundStyle(Palette.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.phone.phoneName).font(.headline)
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(engine.status.label).font(.caption).foregroundStyle(.secondary)
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

    private func batteryIcon(_ b: Int) -> String {
        switch b { case ..<13: return "battery.0"; case ..<38: return "battery.25"
        case ..<63: return "battery.50"; case ..<88: return "battery.75"; default: return "battery.100" }
    }

    // MARK: connect card (disconnected)

    private var connectCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.system(size: 34)).foregroundStyle(.secondary)
            Text(engine.config.phoneBtMac.isEmpty ? "Set up your phone in Settings" : "Not connected")
                .font(.subheadline).foregroundStyle(.secondary)
            if case .error(let m) = engine.status {
                Text(m).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            Button {
                engine.config.phoneBtMac.isEmpty ? openSettings() : engine.connect()
            } label: {
                Label(engine.config.phoneBtMac.isEmpty ? "Open Settings" : "Connect",
                      systemImage: "antenna.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large).buttonStyle(.borderedProminent).tint(Palette.accent)
            .disabled(engine.status.isBusy)
            if engine.status.isBusy { ProgressView().controlSize(.small) }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 18)
        .glassCard()
    }

    // MARK: quick actions

    private var quickActions: some View {
        HStack(spacing: 10) {
            QuickAction(icon: "bell.and.waves.left.and.right", title: "Ring") { engine.ring() }
            QuickAction(icon: "photo.on.rectangle", title: "Photos") { engine.refreshPhotos() }
            QuickAction(icon: "arrow.clockwise", title: "Refresh") { engine.refreshPhotos() }
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
        HStack {
            Button { openSettings() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            Spacer()
            if engine.status == .connected || engine.status.isBusy {
                Button("Disconnect") { engine.disconnect() }.buttonStyle(.plain).foregroundStyle(.red)
            }
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .font(.callout)
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
