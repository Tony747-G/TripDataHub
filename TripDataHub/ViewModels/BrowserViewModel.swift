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
        let success = appViewModel.importCrewAccessPDFData(data, sourceFileName: sourceFileName)
        if success {
            statusMessage = "✅ PDF imported — please review the content"
        } else {
            statusMessage = "⚠️ Import skipped (already processing)"
        }
        popupWebView = nil
    }
}
