import GrimmoryAPI
import SwiftUI
import WebKit

/// Remote (proxy) auth: shows the server in a web view so the user signs in to the proxy in front of Grimmory
/// (Authelia, Authentik, …). Each time a page from the server's own host finishes loading, the proxy's cookies are
/// copied into the app's URL session and Bow tries `/api/v1/auth/remote`. It succeeds once the proxy lets requests
/// through with the user's headers.
struct ProxySignInView: View {
    let serverURL: URL
    let client: GrimmoryClient
    let onSignedIn: (GrimmoryUser) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var status = "Sign in on the page below."

    var body: some View {
        NavigationStack {
            ProxyWebView(serverURL: serverURL) { await tryRemoteSignIn() }
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(serverURL.host() ?? "Sign In")
                .navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .top) {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(8)
                        .background(.bar)
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
        }
    }

    private func tryRemoteSignIn() async {
        do {
            onSignedIn(try await client.signInWithRemoteAuth())
        } catch GrimmoryError.webPageInsteadOfAPI {
            status = "Still at the sign-in page. Finish signing in below."
        } catch GrimmoryError.forbidden {
            status = "This server has remote sign-in turned off."
        } catch {
            status = "Not signed in yet: \(AddServerView.message(for: error))"
        }
    }
}

private struct ProxyWebView: UIViewRepresentable {
    let serverURL: URL
    let onServerPageLoaded: @MainActor () async -> Void

    func makeCoordinator() -> Coordinator { Coordinator(serverURL: serverURL, onServerPageLoaded: onServerPageLoaded) }

    func makeUIView(context: Context) -> WKWebView {
        // The default (persistent) store, so the proxy session survives and later sign-ins can be quick.
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: serverURL))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let serverURL: URL
        let onServerPageLoaded: @MainActor () async -> Void

        init(serverURL: URL, onServerPageLoaded: @escaping @MainActor () async -> Void) {
            self.serverURL = serverURL
            self.onServerPageLoaded = onServerPageLoaded
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Pages on the proxy's own login host don't count; only the server's host means we're through.
            guard webView.url?.host() == serverURL.host() else { return }
            Task { @MainActor in
                await Self.shareCookies(from: webView, for: serverURL)
                await onServerPageLoaded()
            }
        }

        /// Copies the cookies that apply to the server's host (including parent-domain cookies like
        /// `.example.com`, which proxies often use) into the shared cookie storage `URLSession.shared` sends from.
        @MainActor
        static func shareCookies(from webView: WKWebView, for serverURL: URL) async {
            guard let host = serverURL.host()?.lowercased() else { return }
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            for cookie in cookies {
                let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                if host == domain || host.hasSuffix("." + domain) {
                    HTTPCookieStorage.shared.setCookie(cookie)
                }
            }
        }
    }
}
