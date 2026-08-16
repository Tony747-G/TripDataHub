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
    @State private var browserResetID = UUID()
    @State private var isResettingBrowser = false
    @State private var showingResetConfirmation = false

    /// When true, this view presents ImportPreviewView itself when pendingImport
    /// is set. Both the iPhone and iPad browser flows present BrowserTabView as a
    /// sheet, so both callers pass true to avoid competing root-level sheets.
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
                    .id(browserResetID)

                // ステータスバー
                BrowserStatusBar(viewModel: browserViewModel)
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
                set: { if !$0 { browserViewModel.teardownPopups() } }
            )) {
                if let popupWV = browserViewModel.popupWebView {
                    BrowserPopupSheet(webView: popupWV, viewModel: browserViewModel) {
                        browserViewModel.teardownPopups()
                    }
                }
            }
        }
        .onAppear {
            // AppViewModel への参照を注入
            browserViewModel.appViewModel = appViewModel
        }
        .onChange(of: appViewModel.pendingImport?.id) { _, newValue in
            showingImportPreview = ImportPreviewPresentationPolicy.browserPreviewIsPresented(
                pendingImportID: newValue,
                presentsImportPreview: presentsImportPreview
            )
        }
            .sheet(isPresented: $showingImportPreview) {
            NavigationStack { ImportPreviewView() }
                .environmentObject(appViewModel)
        }
        .alert("Reset Browser?", isPresented: $showingResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                resetBrowser()
            }
        } message: {
            Text("This will clear the in-app browser session and require you to sign in again.")
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
            if browserViewModel.isLoading || isResettingBrowser {
                ProgressView().scaleEffect(0.75)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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
        ToolbarItem(placement: .navigationBarTrailing) {
            Button(role: .destructive) {
                showingResetConfirmation = true
            } label: {
                Image(systemName: "eraser.fill")
                    .foregroundStyle(.primary)
            }
            .disabled(isResettingBrowser)
            .accessibilityLabel("Reset Browser")
        }
    }

    private func resetBrowser() {
        isResettingBrowser = true
        browserViewModel.prepareForBrowserReset()

        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().removeData(ofTypes: dataTypes, modifiedSince: .distantPast) {
            DispatchQueue.main.async {
                browserResetID = UUID()
                isResettingBrowser = false
                browserViewModel.isLoading = false
                browserViewModel.statusMessage = "Browser reset. Sign in to CrewAccess again."
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

struct BrowserStatusBar: View {
    @Environment(\.colorScheme) private var colorScheme

    let viewModel: BrowserViewModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: viewModel.statusIsError ? "exclamationmark.circle.fill" : "circle.fill")
                .font(.system(size: 8, weight: .semibold))
            Text(viewModel.statusMessage)
                .font(.footnote)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .foregroundStyle(statusColor)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .leading)
        .background(.bar)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Browser status: \(viewModel.statusMessage)")
    }

    private var statusColor: Color {
        if viewModel.statusIsError {
            return .red
        }
        return colorScheme == .dark ? .white : .secondary
    }
}

// MARK: - Zscaler Print ポップアップシート

struct BrowserPopupSheet: View {
    let webView: WKWebView
    let viewModel: BrowserViewModel
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ExistingWebViewWrapper(webView: webView)
                BrowserStatusBar(viewModel: viewModel)
            }
            .navigationTitle("Print Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { onDismiss() }
                }
                #if DEBUG
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        viewModel.sendDiagnosticFocusPulse()
                    } label: {
                        Image(systemName: "scope")
                    }
                    .accessibilityLabel("Diagnostic Focus Pulse")
                    .help("Send one diagnostic WebView focus pulse")
                }
                #endif
            }
        }
    }
}

#Preview {
    BrowserTabView()
        .environmentObject(AppViewModel())
}
