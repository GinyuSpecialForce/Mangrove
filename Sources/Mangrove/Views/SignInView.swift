import SwiftUI
import WebKit

/// Sign-in screen. Overleaf has no OAuth flow for third-party clients, and a
/// native password form would mean handling credentials (and Overleaf's
/// CAPTCHA), so sign-in happens in a real web view and the app takes over the
/// resulting session cookie.
struct SignInView: View {
    @EnvironmentObject private var state: AppState
    @State private var showCookieImport = false
    @State private var cookieHeader = ""
    @State private var importError: String?

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            VStack(spacing: 20) {
                AppMark(size: 84)

                VStack(spacing: 6) {
                    Text("Mangrove")
                        .font(Theme.Typeface.display(29))
                    Text("Write LaTeX and compile without leaving your desktop.")
                        .font(Theme.Typeface.ui(12))
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 9) {
                    Button {
                        state.showSignInSheet = true
                    } label: {
                        Text("Sign in to Overleaf")
                            .frame(width: 180, height: 18)
                    }
                    .buttonStyle(PrimaryButtonStyle())

                    Text("Opens overleaf.com inside the app. Your password is never seen or stored here.")
                        .font(Theme.Typeface.ui(9.5))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 260)
                }

                if showCookieImport {
                    cookieImport
                } else {
                    Button("Use a session cookie instead") {
                        showCookieImport = true
                    }
                    .buttonStyle(.plain)
                    .font(Theme.Typeface.ui(10.5))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(40)
        }
        .sheet(isPresented: $state.showSignInSheet) {
            WebSignInSheet()
                .environmentObject(state)
        }
    }

    private var cookieImport: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Paste the value of the Cookie request header")
                .font(Theme.Typeface.ui(11, .semibold))
            Text("In your browser, open overleaf.com while signed in, then look in Developer Tools → Network → any request → Request Headers → Cookie.")
                .font(Theme.Typeface.ui(9.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $cookieHeader)
                .font(Theme.Typeface.mono(10))
                .frame(width: 400, height: 62)
                .padding(5)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Metric.corner, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Metric.corner, style: .continuous)
                        .stroke(Theme.rule, lineWidth: 1)
                )

            if let importError {
                Text(importError)
                    .font(Theme.Typeface.ui(9.5))
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Cancel") {
                    showCookieImport = false
                    cookieHeader = ""
                    importError = nil
                }
                .buttonStyle(.plain)
                .font(Theme.Typeface.ui(10.5))
                .foregroundStyle(.secondary)

                Spacer()

                Button("Import Cookie") { importCookie() }
                    .buttonStyle(PrimaryButtonStyle(compact: true))
                    .disabled(cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 432)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.rule, lineWidth: 1)
        )
    }

    private func importCookie() {
        importError = nil
        do {
            let stored = try StoredSession.fromRawCookieHeader(
                cookieHeader,
                baseURL: state.instanceURL.absoluteString
            )
            Task { await state.completeSignIn(with: stored) }
        } catch {
            importError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// A real browser pointed at overleaf.com. When a session cookie appears we hand
/// it to the app, so password, SSO and two-factor all work as they do on the web.
struct WebSignInSheet: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                AppMark(size: 18)
                Text("Sign in to Overleaf")
                    .font(Theme.Typeface.ui(12, .semibold))
                Spacer()
                Button("Cancel") { state.showSignInSheet = false }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Rule()

            WebSignInView(startURL: state.signInURL) { records in
                guard !records.isEmpty else { return }
                let stored = StoredSession(
                    baseURL: state.instanceURL.absoluteString,
                    cookies: records,
                    savedAt: Date()
                )
                Task { await state.completeSignIn(with: stored) }
            }

            Rule()

            Text("This window closes on its own once Overleaf accepts the session.")
                .font(Theme.Typeface.ui(9.5))
                .foregroundStyle(.tertiary)
                .padding(8)
        }
        .frame(width: 900, height: 664)
    }
}

struct WebSignInView: NSViewRepresentable {
    let startURL: URL
    let onSessionCookies: ([CookieRecord]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSessionCookies: onSessionCookies)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.customUserAgent = OverleafClient.browserUserAgent
        webView.load(URLRequest(url: startURL))
        context.coordinator.attach(webView)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) { }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let onSessionCookies: ([CookieRecord]) -> Void
        private weak var webView: WKWebView?
        private var timer: Timer?
        private var lastSignature = ""

        init(onSessionCookies: @escaping ([CookieRecord]) -> Void) {
            self.onSessionCookies = onSessionCookies
        }

        func attach(_ webView: WKWebView) {
            self.webView = webView
            let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
                self?.poll()
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            poll()
        }

        /// OAuth and SSO flows often try to open a popup; run it in this view
        /// instead so the session lands in the same cookie store.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        private func poll() {
            guard let webView else { return }
            let host = webView.url?.host ?? "www.overleaf.com"
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self else { return }
                let records = cookies
                    .filter { cookie in
                        let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
                        return host == domain || host.hasSuffix("." + domain) || domain.hasSuffix("overleaf.com")
                    }
                    .compactMap(CookieRecord.init(cookie:))
                    .filter { !$0.isExpired && !$0.value.isEmpty }

                let hasSession = records.contains { record in
                    let name = record.name.lowercased()
                    return name.contains("session") || name.contains("sid")
                }
                guard hasSession else { return }

                let signature = records
                    .map { "\($0.name)=\($0.value)" }
                    .sorted()
                    .joined(separator: "|")
                guard signature != self.lastSignature else { return }
                self.lastSignature = signature

                DispatchQueue.main.async {
                    self.onSessionCookies(records)
                }
            }
        }
    }
}
