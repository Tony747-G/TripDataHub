// BrowserViewModel.swift
// TripDataHub
//
// ブラウザタブの状態管理
// PDF検出時に AppViewModel.importCrewAccessPDFData() を呼び出し
// 既存の ImportPreviewView シートフローに繋げる

import Foundation
import WebKit

enum BrowserStatusText {
    static let loading = "Loading…"
    static let pageLoaded = "Page loaded"
    static let networkError = "Network error"
    static let loginRequired = "Login required"
    static let unableToLoadReport = "Unable to load report. Please reset the browser using the eraser icon in the top-right corner."
}

enum BrowserPageStatusClassifier {
    static func status(
        url: URL?,
        pageText: String,
        hasPasswordField: Bool
    ) -> String {
        let normalizedText = pageText.lowercased()
        if normalizedText.contains("unable to load report") {
            return BrowserStatusText.unableToLoadReport
        }

        let normalizedURL = url?.absoluteString.lowercased() ?? ""
        let loginURLMarkers = ["/login", "/signin", "/sign-in", "/authenticate"]
        let hasLoginURL = loginURLMarkers.contains { normalizedURL.contains($0) }
        let hasExplicitLoginCopy = [
            "login required",
            "sign in to crewaccess",
            "sign in to ups"
        ].contains { normalizedText.contains($0) }
        if hasPasswordField || hasLoginURL || hasExplicitLoginCopy {
            return BrowserStatusText.loginRequired
        }

        return BrowserStatusText.pageLoaded
    }
}

@MainActor
@Observable
final class BrowserViewModel {

    // MARK: - 公開状態

    var webView: WKWebView?
    var popupWebView: WKWebView?
    var currentURL: String = ""
    var isLoading: Bool = false
    var statusMessage: String = "Open CrewAccess and import a trip"
    var errorMessage: String? = nil

    var statusIsError: Bool {
        statusMessage == BrowserStatusText.networkError
            || statusMessage == BrowserStatusText.unableToLoadReport
    }

    /// Coordinator-owned popup teardown. Views may request cleanup, but only the
    /// BrowserWebView coordinator owns and mutates the popup lifecycle collections.
    @ObservationIgnored var requestPopupTeardown: (@MainActor () -> Void)?

    #if DEBUG
    /// Diagnostic-only bridge. The coordinator owns the popup and decides which
    /// tracked WebView may receive the focus pulse.
    @ObservationIgnored var requestDiagnosticFocusPulse: (@MainActor () -> Void)?
    #endif

    // MARK: - AppViewModel への参照

    weak var appViewModel: AppViewModel?

    // MARK: - PDF取り込み（WebView.Coordinator から呼び出す）

    func handlePDFData(_ data: Data, sourceFileName: String?) {
        statusMessage = "✈️ Importing PDF..."
        guard let appViewModel else {
            errorMessage = "AppViewModel not found"
            return
        }
        Task { [weak self] in
            let success = await appViewModel.importCrewAccessPDFData(data, sourceFileName: sourceFileName)
            guard let self else { return }
            if success {
                self.statusMessage = "✅ PDF imported — please review the content"
            } else {
                self.statusMessage = "⚠️ Import skipped (already processing)"
            }
        }
    }

    func teardownPopups() {
        requestPopupTeardown?()
    }

    #if DEBUG
    func sendDiagnosticFocusPulse() {
        requestDiagnosticFocusPulse?()
    }
    #endif

    func prepareForBrowserReset() {
        webView?.stopLoading()
        teardownPopups()
        webView = nil
        currentURL = ""
        isLoading = true
        errorMessage = nil
        statusMessage = "Resetting browser..."
    }
}
