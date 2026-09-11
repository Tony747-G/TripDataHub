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

struct CrewAccessIncompleteImportFailure: Identifiable, Equatable {
    let id = UUID()
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
    private(set) var isImportingCrewAccessTrip = false
    private(set) var incompleteImportFailure: CrewAccessIncompleteImportFailure?
    private(set) var isPDFImportInProgress = false
    private(set) var isAutoPrintRetryInProgress = false

    var statusIsError: Bool {
        statusMessage == BrowserStatusText.networkError
            || statusMessage == BrowserStatusText.unableToLoadReport
    }

    /// Coordinator-owned popup teardown. Views may request cleanup, but only the
    /// BrowserWebView coordinator owns and mutates the popup lifecycle collections.
    @ObservationIgnored var requestPopupTeardown: (@MainActor () -> Void)?
    @ObservationIgnored var requestAutoPrintRetry: (@MainActor () -> Bool)?
    /// Cancelling the failure alert has to reach the Coordinator as well as this view model: the
    /// bounded sampling schedules are Coordinator-owned, and a cancelled import must not leave one
    /// of them running behind a dismissed alert.
    @ObservationIgnored var requestAutoPrintCancel: (@MainActor () -> Void)?

    // MARK: - AppViewModel への参照

    weak var appViewModel: AppViewModel?

    // MARK: - PDF取り込み（WebView.Coordinator から呼び出す）

    func handlePDFData(
        _ data: Data,
        sourceFileName: String?,
        completion: @escaping @MainActor (CrewAccessPDFImportResult) -> Void
    ) {
        guard !isPDFImportInProgress else {
            completion(.rejected)
            return
        }
        beginCrewAccessImportingPresentation()
        guard let appViewModel else {
            errorMessage = "AppViewModel not found"
            completion(.rejected)
            return
        }
        isPDFImportInProgress = true
        Task { [weak self] in
            let result = await appViewModel.importCrewAccessPDFDataWithResult(
                data,
                sourceFileName: sourceFileName
            )
            guard let self else {
                completion(result)
                return
            }
            self.isPDFImportInProgress = false
            self.isAutoPrintRetryInProgress = false
            switch result {
            case .previewReady:
                self.incompleteImportFailure = nil
                self.statusMessage = "✅ PDF imported — please review the content"
            case .incompleteTrip:
                self.presentIncompleteImportFailure()
            case .rejected:
                self.statusMessage = "⚠️ Import skipped (already processing)"
            }
            completion(result)
        }
    }

    @discardableResult
    func tryAgainIncompleteImport() -> Bool {
        guard incompleteImportFailure != nil,
              !isPDFImportInProgress,
              !isAutoPrintRetryInProgress
        else { return false }

        // The retry's presentation state is established BEFORE the coordinator is asked, because
        // the coordinator's retry can conclude synchronously — a refused dialog census, an
        // immediately terminal re-entry — and anything set after it returns would overwrite the
        // failure it just presented.
        incompleteImportFailure = nil
        isAutoPrintRetryInProgress = true
        beginCrewAccessImportingPresentation()

        // A popup that can no longer be retried must not leave the user tapping `Try Again` at an
        // alert that re-presents itself. Failing safely here means falling back to cancellation.
        guard let requestAutoPrintRetry, requestAutoPrintRetry() else {
            isAutoPrintRetryInProgress = false
            cancelIncompleteImport()
            return false
        }
        return true
    }

    func cancelIncompleteImport() {
        incompleteImportFailure = nil
        isAutoPrintRetryInProgress = false
        endCrewAccessImportingPresentation()
        requestAutoPrintCancel?()
        statusMessage = "CrewAccess import canceled."
    }

    func presentIncompleteImportFailure() {
        // A retry that itself failed hands the decision back to the user, so the in-progress mark
        // has to be released here as well as on the PDF import path — otherwise the second
        // `Try Again` would be refused by its own concurrency guard.
        isAutoPrintRetryInProgress = false
        incompleteImportFailure = CrewAccessIncompleteImportFailure()
        statusMessage = "⚠️ Unable to import trip"
    }

    func beginCrewAccessImportingPresentation() {
        isImportingCrewAccessTrip = true
        statusMessage = "Importing Trip…"
    }

    func endCrewAccessImportingPresentation() {
        isImportingCrewAccessTrip = false
    }

    func teardownPopups() {
        requestPopupTeardown?()
    }

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
