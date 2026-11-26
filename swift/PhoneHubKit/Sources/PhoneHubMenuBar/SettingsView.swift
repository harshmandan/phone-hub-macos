import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var engine: PhoneHubEngine

    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            OnboardingView().tabItem { Label("Set up", systemImage: "antenna.radiowaves.left.and.right") }
        }
        .padding(20)
        .onChange(of: engine.config) { _, c in ConfigStore.save(c) }
        .onAppear { WindowActivation.enter() }
        .onDisappear { WindowActivation.leave() }
    }
}

// MARK: General

private struct GeneralSettings: View {
    @EnvironmentObject var engine: PhoneHubEngine
    @Environment(\.openWindow) private var openWindow
    @State private var msg = ""
    @State private var msgOK = true

    private var isSetUp: Bool { !engine.config.phoneBtMac.isEmpty && !engine.config.identityPath.isEmpty }

    var body: some View {
        Form {
            Section("Account") {
                if engine.config.account.isEmpty {
                    Button { openWindow(id: "signin") } label: {
                        Label("Sign in with Google…", systemImage: "person.badge.key")
                    }
                    Text("Opens a Google sign-in window. We read the sign-in token Google returns — never your password.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    LabeledContent("Connected account") {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(Palette.good)
                            Text(engine.config.account)
                        }
                    }
                    Button("Sign in with a different account") { openWindow(id: "signin") }
                        .font(.caption)
                }
            }

            Section("Phone") {
                if isSetUp {
                    LabeledContent("Name", value: engine.config.phoneName)
                    LabeledContent("Bluetooth MAC") { Text(engine.config.phoneBtMac).font(.body.monospaced()) }
                } else {
                    Text("No phone set up yet. Import a setup below, or use the Set up tab.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Setup") {
                Text("Move a working setup to another Mac as one file.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button { importBundle() } label: { Label("Import setup…", systemImage: "square.and.arrow.down") }
                    Button { exportBundle() } label: { Label("Export setup…", systemImage: "square.and.arrow.up") }
                        .disabled(!isSetUp)
                    if FileManager.default.fileExists(atPath: ConfigStore.probeIdentityPath) {
                        Button("Use repo probe") { runImportFiles(URL(fileURLWithPath: ConfigStore.probeIdentityPath)) }
                    }
                }
                if !msg.isEmpty { Text(msg).font(.caption).foregroundStyle(msgOK ? Palette.good : .red) }
            }

            Section("Behavior") {
                Toggle("Connect automatically on launch", isOn: $engine.config.autoConnect)
                Text("To stop sharing photos or notifications, turn them off in your phone's Chromebook settings.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private func importBundle() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.message = "Pick a PhoneHub setup .zip (exported by the app or the CLI)."
        if panel.runModal() == .OK, let url = panel.url {
            do { engine.config = try ConfigStore.importBundle(from: url); ok("Imported \(engine.config.phoneName). Ready to connect.") }
            catch { fail(error) }
        }
    }

    private func exportBundle() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "phonehub-setup.zip"
        panel.allowedContentTypes = [.zip]
        if panel.runModal() == .OK, let url = panel.url {
            do { try ConfigStore.exportBundle(to: url); ok("Exported to \(url.lastPathComponent).") }
            catch { fail(error) }
        }
    }

    private func runImportFiles(_ url: URL) {
        do { engine.config = try ConfigStore.importSetup(from: url); ok("Imported \(engine.config.phoneName). Ready to connect.") }
        catch { fail(error) }
    }

    private func ok(_ s: String) { msgOK = true; msg = s }
    private func fail(_ e: Error) { msgOK = false; msg = e.localizedDescription }
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
