import SwiftUI
import WebKit
import PhoneHubKit

/// Google sign-in by web view: the user logs in to Google's Android EmbeddedSetup
/// flow, we read the `oauth_token` cookie it sets and exchange it for a master
/// token — so we never ask for a token or handle a password ourselves.
@MainActor
final class SignInController: ObservableObject {
    enum Phase: Equatable {
        case loading, login, exchanging, done(email: String), failed(String)
        var isBusy: Bool { self == .loading || self == .exchanging }
    }
    @Published var phase: Phase = .loading
    /// Called once with the account email after a master token is captured + saved.
    var onSignedIn: ((String) -> Void)?
}

struct SignInView: View {
    @EnvironmentObject var engine: PhoneHubEngine
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller = SignInController()

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            SignInWebView(controller: controller)
                .frame(minWidth: 420, minHeight: 520)
        }
        .frame(width: 460, height: 600)
        .onAppear { WindowActivation.enter() }   // focus so the Google login can take keyboard input
        .onDisappear { WindowActivation.leave() }
    }

    @ViewBuilder private var statusBar: some View {
        HStack(spacing: 8) {
            switch controller.phase {
            case .loading:    ProgressView().controlSize(.small); Text("Loading Google sign-in…")
            case .login:      Image(systemName: "person.crop.circle"); Text("Sign in to your Google account")
            case .exchanging: ProgressView().controlSize(.small); Text("Finishing sign-in…")
            case .done(let e): Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.good)
                               Text("Signed in as \(e)").font(.callout.weight(.medium))
            case .failed(let m): Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                                 Text(m).font(.caption).lineLimit(2)
            }
            Spacer()
            if case .done = controller.phase { Button("Done") { dismiss() } }
        }
        .font(.callout)
        .padding(10)
        .background(.ultraThinMaterial)
    }
}

/// WKWebView wrapper that loads EmbeddedSetup and watches for the oauth_token cookie.
struct SignInWebView: NSViewRepresentable {
    @ObservedObject var controller: SignInController

    func makeCoordinator() -> Coordinator { Coordinator(controller) }

    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        web.navigationDelegate = context.coordinator
        // Android-ish UA so Google serves the embedded setup flow and allows login.
        web.customUserAgent = "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
        context.coordinator.web = web
        let url = URL(string: "https://accounts.google.com/embedded/setup/v2/android?source=com.google.android.gms&xoauth_display_name=Chromebook&flowName=EmbeddedSetupAndroid&canFrp=1")!
        web.load(URLRequest(url: url))
        return web
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let controller: SignInController
        weak var web: WKWebView?
        private var done = false
        init(_ c: SignInController) { controller = c }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if case .loading = controller.phase { controller.phase = .login }
            captureToken(webView)
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if !done { controller.phase = .failed(error.localizedDescription) }
        }

        /// Google sets `oauth_token` (oauth2_4/…) once login completes; poll for it.
        private func captureToken(_ webView: WKWebView) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self, !self.done else { return }
                guard let tok = cookies.first(where: { $0.name == "oauth_token" })?.value,
                      tok.hasPrefix("oauth2_") else { return }
                self.done = true
                self.controller.phase = .exchanging
                Task { @MainActor in
                    do {
                        let r = try await GoogleAuth.exchangeOAuthToken(tok)
                        ConfigStore.saveMasterToken(r.masterToken)
                        self.controller.phase = .done(email: r.email)
                        self.controller.onSignedIn?(r.email)
                    } catch {
                        self.controller.phase = .failed(error.localizedDescription)
                    }
                }
            }
        }
    }
}
