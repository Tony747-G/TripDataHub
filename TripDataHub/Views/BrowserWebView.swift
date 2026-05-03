// BrowserWebView.swift
// TripDataHub
//
// WKWebView の UIViewRepresentable ラッパー
// PDF検出方式:
//   http/https URL → URLSession（WebViewのcookie引き継ぎ）
//   blob: URL     → decidePolicyForでキャンセル後、親WebView（blob作成元）の
//                   callAsyncJavaScriptでバイナリ取得
//                   （ZscalerはPDFをblob URLとして開く。PDF表示モードのWKWebViewは
//                    JSコンテキストが失われるため親から取得する）

import SwiftUI
import WebKit
import PDFKit

struct BrowserWebView: UIViewRepresentable {
    let url: URL
    var viewModel: BrowserViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate         = context.coordinator
        webView.scrollView.isScrollEnabled = true

        DispatchQueue.main.async {
            context.coordinator.viewModel.webView = webView
        }

        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if let current = webView.url, current != url {
            webView.load(URLRequest(url: url))
        }
    }
}

// MARK: - Coordinator

extension BrowserWebView {
    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var viewModel: BrowserViewModel
        var popupWebViews: [WKWebView] = []
        /// ポップアップの親WebViewを追跡（blob: URL抽出時にblob作成元コンテキストで実行するため）
        var popupParents: [ObjectIdentifier: WKWebView] = [:]

        init(viewModel: BrowserViewModel) { self.viewModel = viewModel }

        // MARK: WKUIDelegate — ポップアップ

        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {

            // ユーザータップのリンク（target="_blank"）→ メインWebViewで開く
            if navigationAction.navigationType == .linkActivated {
                if let url = navigationAction.request.url {
                    DispatchQueue.main.async {
                        self.viewModel.webView?.load(URLRequest(url: url))
                        self.viewModel.statusMessage = "Loading page..."
                    }
                }
                return nil
            }

            // JS起点のwindow.open()（Zscaler Print等）→ シートで表示
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
            let popup = WKWebView(frame: CGRect(x: 0, y: 0, width: 375, height: 812),
                                  configuration: configuration)
            popup.navigationDelegate = self
            popup.uiDelegate = self
            popupWebViews.append(popup)
            popupParents[ObjectIdentifier(popup)] = webView   // blob取得のために親を記録

            DispatchQueue.main.async {
                self.viewModel.popupWebView = popup
                self.viewModel.statusMessage = "📄 Processing popup..."
            }
            return popup
        }

        func webViewDidClose(_ webView: WKWebView) {
            popupParents.removeValue(forKey: ObjectIdentifier(webView))
            popupWebViews.removeAll { $0 === webView }
            DispatchQueue.main.async {
                if self.viewModel.popupWebView === webView {
                    self.viewModel.popupWebView = nil
                }
            }
        }

        // MARK: Navigation events

        func webView(_ webView: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
            guard !popupWebViews.contains(webView) else { return }
            DispatchQueue.main.async {
                self.viewModel.isLoading = true
                self.viewModel.statusMessage = "Loading page..."
            }
        }

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            guard !popupWebViews.contains(webView) else { return }
            DispatchQueue.main.async {
                self.viewModel.isLoading = false
                self.viewModel.currentURL = webView.url?.absoluteString ?? ""
                self.viewModel.statusMessage = "Page loaded"
            }
        }

        func webView(_ webView: WKWebView, didFail _: WKNavigation!, withError error: Error) {
            guard !popupWebViews.contains(webView) else { return }
            DispatchQueue.main.async {
                self.viewModel.isLoading = false
                self.viewModel.statusMessage = "Error: \(error.localizedDescription)"
            }
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation _: WKNavigation!,
                     withError error: Error) {
            guard !popupWebViews.contains(webView) else { return }
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            DispatchQueue.main.async {
                self.viewModel.isLoading = false
                self.viewModel.statusMessage = "Navigation error: \(error.localizedDescription)"
            }
        }

        // MARK: PDF検出 — スキームに応じて処理を分岐

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            let mimeType = navigationResponse.response.mimeType ?? ""
            guard mimeType == "application/pdf" else {
                decisionHandler(.allow)
                return
            }

            let responseURL = navigationResponse.response.url
            let scheme = responseURL?.scheme ?? "(nil)"

            DispatchQueue.main.async {
                self.viewModel.statusMessage = "✈️ PDF detected (scheme: \(scheme))"
            }

            switch scheme {
            case "https", "http":
                decisionHandler(.cancel)
                guard let url = responseURL else { return }
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                    self?.downloadPDF(from: url, cookies: cookies)
                }

            case "blob":
                decisionHandler(.cancel)
                guard let urlStr = responseURL?.absoluteString else { return }
                let parentWV = popupParents[ObjectIdentifier(webView)] ?? webView
                DispatchQueue.main.async {
                    self.viewModel.statusMessage = "📄 Fetching blob PDF..."
                }
                extractBlobFromURL(urlStr, from: parentWV)

            default:
                decisionHandler(.allow)
                DispatchQueue.main.async {
                    self.viewModel.statusMessage = "⚠️ Unknown scheme [\(scheme)] → allowed"
                }
            }
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(.allow)
        }

        // MARK: - URLSession ダウンロード（http/https用）

        private func downloadPDF(from url: URL, cookies: [HTTPCookie]) {
            DispatchQueue.main.async {
                self.viewModel.statusMessage = "📥 Fetching PDF..."
            }
            let cookieHeader = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            var request = URLRequest(url: url,
                                     cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                     timeoutInterval: 60)
            if !cookieHeader.isEmpty { request.setValue(cookieHeader, forHTTPHeaderField: "Cookie") }
            request.setValue(
                "Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148 Safari/604.1",
                forHTTPHeaderField: "User-Agent"
            )
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest  = 60
            config.timeoutIntervalForResource = 120
            URLSession(configuration: config).dataTask(with: request) { [weak self] data, response, error in
                guard let self else { return }
                if let error = error {
                    DispatchQueue.main.async {
                        self.viewModel.errorMessage = "PDF fetch failed: \(error.localizedDescription)"
                        self.closePopups()
                    }
                    return
                }
                guard let data, !data.isEmpty else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    DispatchQueue.main.async {
                        self.viewModel.errorMessage = "Empty response (HTTP \(status))"
                        self.closePopups()
                    }
                    return
                }
                DispatchQueue.main.async {
                    self.viewModel.handlePDFData(data, sourceFileName: url.lastPathComponent)
                }
            }.resume()
        }

        // MARK: - JavaScript blob抽出（blob: URL用）

        private func extractBlobFromURL(_ urlString: String, from sourceWebView: WKWebView) {
            let js = """
            try {
                const resp = await fetch(blobURL);
                const buf  = await resp.arrayBuffer();
                const bytes = new Uint8Array(buf);
                let bin = '';
                const chunk = 8192;
                for (let i = 0; i < bytes.length; i += chunk) {
                    bin += String.fromCharCode(...Array.from(bytes.subarray(i, Math.min(i + chunk, bytes.length))));
                }
                return 'OK:' + btoa(bin);
            } catch(e) {
                return 'ERR:' + e.toString();
            }
            """

            sourceWebView.callAsyncJavaScript(js,
                                              arguments: ["blobURL": urlString],
                                              in: nil, in: .page) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let value):
                    guard let str = value as? String else {
                        DispatchQueue.main.async {
                            self.viewModel.errorMessage = "Invalid JS return value: \(String(describing: value))"
                            self.closePopups()
                        }
                        return
                    }
                    if str.hasPrefix("OK:") {
                        let b64 = String(str.dropFirst(3))
                        if let data = Data(base64Encoded: b64) {
                            DispatchQueue.main.async {
                                self.viewModel.handlePDFData(data, sourceFileName: "crewaccess_trip.pdf")
                            }
                        } else {
                            DispatchQueue.main.async {
                                self.viewModel.errorMessage = "Base64 decode failed (length: \(b64.count))"
                                self.closePopups()
                            }
                        }
                    } else {
                        DispatchQueue.main.async {
                            self.viewModel.errorMessage = "JS blob fetch error: \(str)"
                            self.closePopups()
                        }
                    }
                case .failure(let error):
                    DispatchQueue.main.async {
                        self.viewModel.errorMessage = "JS execution failed: \(error.localizedDescription)"
                        self.closePopups()
                    }
                }
            }
        }

        // MARK: - ポップアップ閉じる

        @MainActor
        private func closePopups() {
            viewModel.popupWebView = nil
            popupWebViews.removeAll()
            popupParents.removeAll()
        }
    }
}
