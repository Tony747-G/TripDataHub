// BrowserViewModel.swift
// TripDataHub
//
// ブラウザタブの状態管理
// PDF検出時に AppViewModel.importCrewAccessPDFData() を呼び出し
// 既存の ImportPreviewView シートフローに繋げる

import Foundation
import WebKit

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
            self.popupWebView = nil
        }
    }
}
