// BrowserTabView.swift
// TripDataHub
//
// CrewAccess PDFを取り込むためのブラウザタブ
// WebView内でPDFが検出されると自動的に ImportPreviewView シートが開く

import SwiftUI
import WebKit

struct BrowserTabView: View {

    @EnvironmentObject private var appViewModel: AppViewModel
    @State private var browserViewModel = BrowserViewModel()
    @State private var showingImportPreview = false

    /// When true, this view presents ImportPreviewView itself when pendingImport
    /// is set. iPad workspace uses this because BrowserTabView is presented as a
    /// sheet there — a separate sheet on the workspace would conflict. iPhone
    /// uses the tab-based RootTabView which presents the preview at the root.
    let presentsImportPreview: Bool

    init(presentsImportPreview: Bool = false) {
        self.presentsImportPreview = presentsImportPreview
    }

    private let portalURL = URL(string: "https://fltops-portal.ups.com/")!

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // URL バー
                urlBar

                // WebView 本体
                BrowserWebView(url: portalURL, viewModel: browserViewModel)
                    .ignoresSafeArea(edges: .bottom)

                // ステータスバー
                statusBar
            }
            .navigationTitle("Browser")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            // エラーアラート
            .alert("Error", isPresented: Binding(
                get: { browserViewModel.errorMessage != nil },
                set: { if !$0 { browserViewModel.errorMessage = nil } }
            )) {
                Button("OK") { browserViewModel.errorMessage = nil }
            } message: {
                Text(browserViewModel.errorMessage ?? "")
            }
            // Zscaler Print ポップアップシート
            .sheet(isPresented: Binding(
                get: { browserViewModel.popupWebView != nil },
                set: { if !$0 { browserViewModel.popupWebView = nil } }
            )) {
                if let popupWV = browserViewModel.popupWebView {
                    BrowserPopupSheet(webView: popupWV) {
                        browserViewModel.popupWebView = nil
                    }
                }
            }
        }
        .onAppear {
            // AppViewModel への参照を注入
            browserViewModel.appViewModel = appViewModel
        }
        .onChange(of: appViewModel.pendingImport?.id) { _, newValue in
            if presentsImportPreview, newValue != nil {
                showingImportPreview = true
            }
        }
        .sheet(isPresented: $showingImportPreview) {
            NavigationStack { ImportPreviewView() }
                .environmentObject(appViewModel)
        }
    }

    // MARK: - URL バー

    private var urlBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.green)
                .font(.caption)
            Text(browserViewModel.currentURL.isEmpty
                 ? portalURL.absoluteString
                 : browserViewModel.currentURL)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if browserViewModel.isLoading {
                ProgressView().scaleEffect(0.75)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(.systemGray6))
    }

    // MARK: - ステータスバー

    private var statusBar: some View {
        Text(browserViewModel.statusMessage)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color(.systemGray6))
    }

    // MARK: - ツールバー

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button {
                browserViewModel.webView?.goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
        }
        ToolbarItem(placement: .navigationBarLeading) {
            Button {
                browserViewModel.webView?.goForward()
            } label: {
                Image(systemName: "chevron.right")
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                browserViewModel.webView?.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
        }
    }
}

// MARK: - 既存 WKWebView を SwiftUI にラップ

private struct ExistingWebViewWrapper: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ webView: WKWebView, context: Context) {}
}

// MARK: - Zscaler Print ポップアップシート

struct BrowserPopupSheet: View {
    let webView: WKWebView
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            ExistingWebViewWrapper(webView: webView)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Print Preview")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { onDismiss() }
                    }
                }
        }
    }
}

#Preview {
    BrowserTabView()
        .environmentObject(AppViewModel())
}
