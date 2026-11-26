import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The app's only settings window: a list of set-up phones + system options.
/// Setting up a phone happens in the wizard (a separate window), not here.
struct SettingsView: View {
    @EnvironmentObject var engine: PhoneHubEngine
    @Environment(\.openWindow) private var openWindow
    @StateObject private var system = SystemIntegration()
    @State private var comingSoon = false
    @State private var msg = ""
    @State private var msgOK = true

    var body: some View {
        Form {
            Section("Phones") {
                if engine.config.phones.isEmpty {
                    Text("No phone set up yet. Add one to get started.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(engine.config.phones) { phone in
                        PhoneRow(phone: phone, onExport: exportPhone, onRemove: removePhone)
                    }
                }
                Menu {
                    Button { openWindow(id: "wizard") } label: { Label("Set up a new phone…", systemImage: "wand.and.stars") }
                    Button { importExisting() } label: { Label("Import a setup…", systemImage: "square.and.arrow.down") }
                    if FileManager.default.fileExists(atPath: ConfigStore.probeIdentityPath) {
                        Divider()
                        Button { useRepoProbe() } label: { Label("Use repo probe (dev)", systemImage: "hammer") }
                    }
                } label: {
                    Label("Add device…", systemImage: "plus")
                } primaryAction: { addDevice() }
            }

            Section("System") {
                Toggle(isOn: Binding(get: { system.startAtLogin }, set: { system.setStartAtLogin($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Start at login")
                        Text(system.startAtLogin ? "PhoneHub opens automatically when you log in."
                                                  : "PhoneHub won't open until you launch it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: Binding(get: { system.notificationsAuthorized }, set: { system.toggleNotifications($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("System notifications")
                        Text(system.notificationsAuthorized ? "Allowed — your phone's notifications show on the Mac."
                             : "Not allowed. Turn on to grant it (or open System Settings).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if !msg.isEmpty {
                Section { Text(msg).font(.caption).foregroundStyle(msgOK ? Palette.good : .red) }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, minHeight: 420)
        .onAppear { WindowActivation.enter(); system.refresh() }
        .onDisappear { WindowActivation.leave() }
        .alert("Multiple phones — coming soon", isPresented: $comingSoon) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("PhoneHub pairs with one phone for now. Managing several at once is on the way.")
        }
    }

    // MARK: actions

    private func addDevice() {
        if engine.config.phones.isEmpty { openWindow(id: "wizard") } else { comingSoon = true }
    }

    private func importExisting() {
        if !engine.config.phones.isEmpty { comingSoon = true; return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.message = "Pick a PhoneHub setup .zip (exported by the app or the CLI)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { addPhone(try ConfigStore.importBundle(from: url)) } catch { fail(error) }
    }

    private func useRepoProbe() {
        if !engine.config.phones.isEmpty { comingSoon = true; return }
        do { addPhone(try ConfigStore.importPhone(fromIdentity: URL(fileURLWithPath: ConfigStore.probeIdentityPath),
                                                  account: "you@example.com")) }
        catch { fail(error) }
    }

    private func addPhone(_ p: PhoneSetup) {
        engine.config.phones.append(p)
        engine.config.activePhoneId = p.id
        ConfigStore.save(engine.config)
        ok("Added \(p.name).")
        engine.reconnect()
    }

    private func exportPhone(_ p: PhoneSetup) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(p.name.replacingOccurrences(of: " ", with: "-")).phonehub.zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try ConfigStore.exportBundle(p, to: url); ok("Exported \(p.name).") } catch { fail(error) }
    }

    private func removePhone(_ p: PhoneSetup) {
        engine.config.phones.removeAll { $0.id == p.id }
        if engine.config.activePhoneId == p.id { engine.config.activePhoneId = engine.config.phones.first?.id }
        ConfigStore.save(engine.config)
        ConfigStore.removePhoneFiles(p.id)
        engine.reconnect()
        ok("Removed \(p.name).")
    }

    private func ok(_ s: String) { msgOK = true; msg = s }
    private func fail(_ e: Error) { msgOK = false; msg = e.localizedDescription }
}

/// One phone in the list: name, linked account, live status, and a … menu.
private struct PhoneRow: View {
    @EnvironmentObject var engine: PhoneHubEngine
    let phone: PhoneSetup
    let onExport: (PhoneSetup) -> Void
    let onRemove: (PhoneSetup) -> Void

    private var isActive: Bool {
        engine.config.activePhoneId == phone.id ||
        (engine.config.activePhoneId == nil && engine.config.phones.first?.id == phone.id)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "iphone.gen3").font(.title3).foregroundStyle(Palette.accent).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(phone.name).font(.body.weight(.medium))
                    if isActive {
                        HStack(spacing: 4) {
                            Circle().fill(statusColor).frame(width: 6, height: 6)
                            Text(engine.status.label).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                if !phone.account.isEmpty {
                    Label(phone.account, systemImage: "checkmark.seal.fill")
                        .font(.caption).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                }
                if !phone.btMac.isEmpty {
                    Text(phone.btMac).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Menu {
                Button { onExport(phone) } label: { Label("Export setup…", systemImage: "square.and.arrow.up") }
                Button(role: .destructive) { onRemove(phone) } label: { Label("Remove", systemImage: "trash") }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.vertical, 3)
    }

    private var statusColor: Color {
        switch engine.status {
        case .connected: return Palette.good
        case .arming, .connecting: return Palette.warn
        case .error: return .red
        case .disconnected: return .secondary
        }
    }
}
