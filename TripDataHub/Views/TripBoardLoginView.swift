import SwiftUI
import WebKit

struct TripBoardLoginView: View {
    let onAuthenticated: ([HTTPCookie], URL?) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                #if os(iOS)
                if let loginURL = URL(string: "https://tripboard.bidproplus.com/") {
                    TripBoardWebView(
                        url: loginURL,
                        onAuthenticated: onAuthenticated
                    )
                } else {
                    Text("Failed to build TripBoard login URL.")
                        .foregroundStyle(.red)
                }
                #else
                Text("TripBoard login is supported on iOS only.")
                    .foregroundStyle(.secondary)
                #endif
            }
            .navigationTitle("TripBoard Login")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { onCancel() }
                }
            }
        }
    }
}

#if os(iOS)
private struct TripBoardWebView: UIViewRepresentable {
    let url: URL
    let onAuthenticated: ([HTTPCookie], URL?) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onAuthenticated: onAuthenticated)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var webView: WKWebView?
        private let authService: TripBoardAuthServiceProtocol
        private let onAuthenticated: ([HTTPCookie], URL?) -> Void
        private var didNotifyAuth = false

        init(
            authService: TripBoardAuthServiceProtocol = TripBoardAuthService(),
            onAuthenticated: @escaping ([HTTPCookie], URL?) -> Void
        ) {
            self.authService = authService
            self.onAuthenticated = onAuthenticated
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("document.querySelector('input[type=password]') !== null") { [weak self, weak webView] result, error in
                guard let self else { return }
                guard error == nil, let hasPasswordField = result as? Bool else { return }
                if hasPasswordField { return }

                webView?.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self, weak webView] cookies in
                    guard let self else { return }
                    let currentURL = webView?.url
                    if self.didNotifyAuth { return }
                    if self.authService.isAuthenticated(url: currentURL, cookies: cookies) {
                        self.didNotifyAuth = true
                        DispatchQueue.main.async {
                            self.onAuthenticated(cookies, currentURL)
                        }
                    }
                }
            }
        }
    }
}
#endif

#Preview {
    TripBoardLoginView(
        onAuthenticated: { _, _ in },
        onCancel: {}
    )
}
