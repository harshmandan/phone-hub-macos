import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var engine: PhoneHubEngine

    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            OnboardingView().tabItem { Label("Set up", systemImage: "antenna.radiowaves.left.and.right") }
            ConfigSettings().tabItem { Label("Config", systemImage: "doc.badge.gearshape") }
        }
        .padding(20)
        .onChange(of: engine.config) { _, c in ConfigStore.save(c) }
    }
}

// MARK: General

private struct GeneralSettings: View {
    @EnvironmentObject var engine: PhoneHubEngine

    var body: some View {
        Form {
            Section("Phone") {
                TextField("Name", text: $engine.config.phoneName)
                TextField("Bluetooth MAC", text: $engine.config.phoneBtMac)
                    .font(.body.monospaced())
                HStack {
                    TextField("Identity file", text: $engine.config.identityPath)
                        .font(.caption.monospaced())
                    Button("Choose…") { pickIdentity() }
                }
            }
            Section("Behavior") {
                Toggle("Connect automatically on launch", isOn: $engine.config.autoConnect)
                Toggle("Show notifications", isOn: $engine.config.showNotifications)
            }
            Section("Account") {
                TextField("Google account", text: $engine.config.account)
                Text("Used only to label this setup; enrollment is done by the probe tools.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func pickIdentity() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url { engine.config.identityPath = url.path }
    }
}

// MARK: Onboarding (ESP32 flashing)

private struct OnboardingView: View {
    @EnvironmentObject var engine: PhoneHubEngine
    @StateObject private var flasher = Esp32Flasher()
    @State private var selected: Esp32Flasher.Board?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set up a phone")
                .font(.title3.weight(.semibold))
            Text("Phone Hub needs the phone to first \"Set up this Chromebook\". A small ESP32 board broadcasts the trigger beacon next to your Mac — the one signal macOS can't send itself. Flash it here, then bring your phone close.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack {
                Button { flasher.detectBoards() } label: { Label("Detect board", systemImage: "cable.connector") }
                    .disabled(flasher.busy)
                if flasher.busy { ProgressView().controlSize(.small) }
                Spacer()
            }

            if !flasher.boards.isEmpty {
                Picker("Board", selection: $selected) {
                    ForEach(flasher.boards) { b in Text("\(b.name) — \(b.port)").tag(Optional(b)) }
                }
                Button {
                    if let b = selected ?? flasher.boards.first { flasher.flash(b, appConfig: engine.config) }
                } label: { Label("Flash trigger beacon", systemImage: "bolt.fill") }
                    .buttonStyle(.borderedProminent).tint(Palette.accent)
                    .disabled(flasher.busy)
            }

            ScrollView {
                Text(flasher.log.isEmpty ? "Logs will appear here." : flasher.log)
                    .font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(.secondary)
            }
            .frame(maxHeight: .infinity)
            .glassCard()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: Config export/import

private struct ConfigSettings: View {
    @EnvironmentObject var engine: PhoneHubEngine
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Configuration").font(.title3.weight(.semibold))
            Text("Export your setup to move it to another Mac, or import one you saved.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button { export() } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                Button { importConfig() } label: { Label("Import…", systemImage: "square.and.arrow.down") }
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Text("Stored at \(ConfigStore.url.path)").font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "phonehub-config.json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            do { try ConfigStore.export(engine.config, to: url); message = "Exported to \(url.lastPathComponent)" }
            catch { message = "Export failed: \(error.localizedDescription)" }
        }
    }

    private func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            do { engine.config = try ConfigStore.load(from: url); ConfigStore.save(engine.config); message = "Imported." }
            catch { message = "Import failed: \(error.localizedDescription)" }
        }
    }
}
