import SwiftUI
import AppKit
import PhoneHubKit

/// The interactive "set up a new phone" flow, in its own window. Steps:
/// sign in → flash the beacon → pair on the phone → done. Each step has a
/// collapsible debug log so a stuck user can copy it into an issue.
@MainActor final class WizardModel: ObservableObject {
    enum Step: Int, CaseIterable {
        case signIn, flash, pair, done
        var title: String {
            switch self {
            case .signIn: return "Sign in"
            case .flash:  return "Flash beacon"
            case .pair:   return "Pair phone"
            case .done:   return "Done"
            }
        }
    }
    @Published var step: Step = .signIn
    @Published var email = ""
    @Published var logs: [Step: String] = [:]

    func log(_ s: Step, _ line: String) { logs[s, default: ""] += line + "\n" }
    func advance() { if let n = Step(rawValue: step.rawValue + 1) { step = n } }
    func back() { if let p = Step(rawValue: step.rawValue - 1) { step = p } }
}

struct SetupWizardView: View {
    @EnvironmentObject var engine: PhoneHubEngine
    @Environment(\.dismiss) private var dismiss
    @StateObject private var wiz = WizardModel()
    @StateObject private var signIn = SignInController()
    @StateObject private var flasher = Esp32Flasher()

    var body: some View {
        VStack(spacing: 0) {
            stepBar
            Divider()
            ScrollView { content.padding(18) }.frame(maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 540, height: 620)
        .onAppear { WindowActivation.enter() }
        .onDisappear { WindowActivation.leave() }
    }

    // MARK: step bar

    private var stepBar: some View {
        HStack(spacing: 0) {
            ForEach(WizardModel.Step.allCases, id: \.rawValue) { s in
                let done = s.rawValue < wiz.step.rawValue
                let active = s == wiz.step
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(active ? Palette.accent : (done ? Palette.good : Color.secondary.opacity(0.25)))
                            .frame(width: 22, height: 22)
                        if done { Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(.white) }
                        else { Text("\(s.rawValue + 1)").font(.caption2.bold()).foregroundStyle(active ? .white : .secondary) }
                    }
                    Text(s.title).font(.caption).foregroundStyle(active ? .primary : .secondary)
                }
                if s != .done { Rectangle().fill(.secondary.opacity(0.2)).frame(height: 1).frame(maxWidth: .infinity) }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: content

    @ViewBuilder private var content: some View {
        switch wiz.step {
        case .signIn: signInStep
        case .flash:  flashStep
        case .pair:   pairStep
        case .done:   doneStep
        }
    }

    private var signInStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            StepTitle("Sign in to Google", subtitle: "Log in so this Mac can pair with your phone. We read the sign-in token Google returns — never your password.")
            SignInWebView(controller: signIn)
                .frame(height: 340)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
            if case .done(let e) = signIn.phase {
                Label("Signed in as \(e)", systemImage: "checkmark.seal.fill").foregroundStyle(Palette.good).font(.callout)
            }
            DebugLog(text: signInDebug)
        }
        .onChange(of: signInPhaseText) { _, _ in
            if case .done(let e) = signIn.phase { wiz.email = e; wiz.log(.signIn, "signed in as \(e)") }
        }
    }

    private var flashStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepTitle("Flash the trigger beacon", subtitle: "A small ESP32 board broadcasts the \"Set up this Chromebook\" signal next to your Mac — the one thing macOS can't send itself.")
            HStack {
                Button { flasher.detectBoards() } label: { Label("Detect board", systemImage: "cable.connector") }
                    .disabled(flasher.busy)
                if flasher.busy { ProgressView().controlSize(.small) }
            }
            if !flasher.boards.isEmpty {
                ForEach(flasher.boards) { b in
                    Button { flasher.flash(b, appConfig: engine.config) } label: {
                        Label("Flash \(b.name) on \(b.port)", systemImage: "bolt.fill")
                    }
                    .buttonStyle(.borderedProminent).tint(Palette.accent).disabled(flasher.busy)
                }
            }
            DisclosureGroup("My board isn't an ESP32 / isn't listed") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("PhoneHub flashes ESP32-family boards over USB. For anything else, copy this prompt into an AI assistant — it has your Mac's details and will produce firmware you can flash yourself.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ScrollView { Text(escapePrompt).font(.caption2.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(height: 120).glassCard(cornerRadius: 8)
                    Button { copy(escapePrompt) } label: { Label("Copy prompt", systemImage: "doc.on.doc") }
                }
                .padding(.top, 4)
            }
            .font(.callout)
            DebugLog(text: flasher.log)
        }
    }

    private var pairStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepTitle("Finish on your phone", subtitle: "Bring your phone within ~30 cm of the Mac. It shows \"Set up this Chromebook\" — tap it and follow the prompts. Or scan this QR.")
            if let img = qrImage {
                Image(nsImage: img).resizable().interpolation(.none)
                    .frame(width: 180, height: 180).frame(maxWidth: .infinity)
            }
            Text("When your phone appears as a device, you're paired. Keep the beacon powered.")
                .font(.caption).foregroundStyle(.secondary)
            DebugLog(text: wiz.logs[.pair] ?? "Waiting for the phone…")
        }
    }

    private var doneStep: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 54)).foregroundStyle(Palette.good)
            Text("All set").font(.title2.weight(.semibold))
            Text(wiz.email.isEmpty ? "Your phone is ready." : "Paired with \(wiz.email).")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 30)
    }

    // MARK: footer

    private var footer: some View {
        HStack {
            if wiz.step != .signIn && wiz.step != .done {
                Button("Back") { wiz.back() }
            }
            Spacer()
            switch wiz.step {
            case .done:
                Button("Finish") { dismiss() }.buttonStyle(.borderedProminent).tint(Palette.accent)
            default:
                Button(wiz.step == .pair ? "I've paired my phone" : "Continue") { wiz.advance() }
                    .buttonStyle(.borderedProminent).tint(Palette.accent)
                    .disabled(wiz.step == .signIn && !signedIn)
            }
        }
        .padding(14)
    }

    // MARK: helpers

    private var signedIn: Bool { if case .done = signIn.phase { return true }; return false }
    private var signInPhaseText: String { String(describing: signIn.phase) }
    private var signInDebug: String {
        switch signIn.phase {
        case .loading: return "loading Google sign-in…"
        case .login: return "waiting for login…"
        case .exchanging: return "exchanging token…"
        case .done(let e): return "signed in as \(e)"
        case .failed(let m): return "failed: \(m)"
        }
    }

    private var qrImage: NSImage? {
        let b = QuickStart.newBootstrap()
        let url = QuickStart.qrURL(b)
        let path = NSTemporaryDirectory() + "phonehub-qr.png"
        guard QrImage.writePNG(url, to: path) else { return nil }
        return NSImage(contentsOfFile: path)
    }

    private var escapePrompt: String {
        let mac = flasher.macBtAddress
        return """
        I want to build BLE beacon firmware for my dev board (tell me which board I have and adapt).
        It must make a nearby Android phone show Google's "Set up this Chromebook" prompt by emitting a
        Nearby Connections BLE advertisement:
          • service-data under UUID 0000FEF3 (the NC advertisement header), and
          • a GATT characteristic 00000000-0000-3000-8000-000000000000 serving the medium advertisement,
            whose PCP advertisement carries this Mac's Bluetooth Classic MAC: \(mac).
        Use NimBLE if possible. Reference implementation (ESP32 Arduino):
        github.com/harshmandan/phone-hub-macos firmware/chromebook_beacon (chromebook_beacon.ino + gen_nc_advert.py).
        Give me a complete sketch for my board and the exact flashing commands.
        """
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
    }
}

// MARK: small pieces

private struct StepTitle: View {
    let title: String, subtitle: String
    init(_ t: String, subtitle: String) { title = t; self.subtitle = subtitle }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title3.weight(.semibold))
            Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct DebugLog: View {
    let text: String
    var body: some View {
        DisclosureGroup("Debug log") {
            ScrollView {
                Text(text.isEmpty ? "No output yet." : text)
                    .font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 100).glassCard(cornerRadius: 8)
        }
        .font(.caption)
    }
}
