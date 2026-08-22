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
import os

private let browserPopupLogger = Logger(
    subsystem: "com.sfune.TripDataHub",
    category: "BrowserPopup"
)

#if DEBUG
private let browserPerformanceLogger = Logger(
    subsystem: "com.sfune.TripDataHub",
    category: "BrowserPerf"
)
#endif

private final class BrowserPopupWebView: WKWebView {
    var didAttachToWindow: (@MainActor () -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        didAttachToWindow?()
    }
}

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
        // Intentionally empty: the WebView drives its own navigation after makeUIView.
        // Reloading here would interrupt in-progress auth flows (e.g. Zscaler MFA redirects).
    }
}

// MARK: - Coordinator

extension BrowserWebView {
    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        typealias PDFDataHandler = @MainActor (Data, String?) -> Void
        typealias JavaScriptEvaluator = @MainActor (
            WKWebView,
            String,
            @escaping @MainActor (Error?) -> Void
        ) -> Void
        typealias PopupFocusAcquirer = @MainActor (WKWebView) -> Bool
        typealias PopupAttachmentChecker = @MainActor (WKWebView) -> Bool

        var viewModel: BrowserViewModel
        var popupWebViews: [WKWebView] = []
        /// ポップアップの親WebViewを追跡（blob: URL抽出時にblob作成元コンテキストで実行するため）
        var popupParents: [ObjectIdentifier: WKWebView] = [:]
        private let pdfDataHandler: PDFDataHandler
        private let javaScriptEvaluator: JavaScriptEvaluator
        private let popupFocusAcquirer: PopupFocusAcquirer
        private let popupAttachmentChecker: PopupAttachmentChecker
        private var popupTeardownGeneration: UInt = 0
        private var activePopupTeardownGeneration: UInt?
        private var activePopupTeardownTargets: [WKWebView] = []
        private var pendingWindowCloseCallbacks = 0
        private var popupFocusAcquisitionStates: [ObjectIdentifier: PopupFocusAcquisitionState] = [:]

        #if DEBUG
        private var nextPopupPerformanceTraceID: UInt = 0
        private var popupPerformanceTraces: [ObjectIdentifier: PopupPerformanceTrace] = [:]
        #endif

        private struct PopupFocusAcquisitionState {
            var hasCompletedNavigation = false
            var isResolved = false
        }

        #if DEBUG
        private struct PopupPerformanceTrace {
            let id: UInt
            let startedAt: TimeInterval
            let startedAtWallClock: TimeInterval
            var lastDOMSignature: String?
            var isSamplingDOM = false
        }
        #endif

        @MainActor
        init(
            viewModel: BrowserViewModel,
            pdfDataHandler: PDFDataHandler? = nil,
            javaScriptEvaluator: JavaScriptEvaluator? = nil,
            popupFocusAcquirer: PopupFocusAcquirer? = nil,
            popupAttachmentChecker: PopupAttachmentChecker? = nil
        ) {
            self.viewModel = viewModel
            self.pdfDataHandler = pdfDataHandler ?? { [weak viewModel] data, sourceFileName in
                viewModel?.handlePDFData(data, sourceFileName: sourceFileName)
            }
            self.javaScriptEvaluator = javaScriptEvaluator ?? { webView, script, completion in
                webView.evaluateJavaScript(script) { _, error in
                    DispatchQueue.main.async {
                        completion(error)
                    }
                }
            }
            self.popupFocusAcquirer = popupFocusAcquirer ?? { webView in
                webView.becomeFirstResponder()
            }
            self.popupAttachmentChecker = popupAttachmentChecker ?? { webView in
                webView.window != nil
            }
            super.init()
            viewModel.requestPopupTeardown = { [weak self] in
                self?.closePopups()
            }
            #if DEBUG
            viewModel.requestDiagnosticFocusPulse = { [weak self] in
                self?.performDiagnosticFocusPulse()
            }
            #endif
        }

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
                        self.viewModel.statusMessage = BrowserStatusText.loading
                    }
                }
                return nil
            }

            // JS起点のwindow.open()（Zscaler Print等）→ シートで表示
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
            let popup = BrowserPopupWebView(
                frame: CGRect(x: 0, y: 0, width: 375, height: 812),
                configuration: configuration
            )
            popup.didAttachToWindow = { [weak self, weak popup] in
                guard let self, let popup else { return }
                self.popupDidAttach(popup)
            }
            popup.navigationDelegate = self
            popup.uiDelegate = self
            popupWebViews.append(popup)
            popupParents[ObjectIdentifier(popup)] = webView   // blob取得のために親を記録
            popupFocusAcquisitionStates[ObjectIdentifier(popup)] = PopupFocusAcquisitionState()
            #if DEBUG
            startPopupPerformanceTrace(for: popup)
            #endif

            DispatchQueue.main.async {
                self.viewModel.popupWebView = popup
                self.viewModel.statusMessage = "📄 Processing popup..."
            }
            return popup
        }

        func webViewDidClose(_ webView: WKWebView) {
            closePopups()
        }

        // MARK: Navigation events

        func webView(_ webView: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
            let isPopup = popupWebViews.contains(webView)
            #if DEBUG
            if isPopup {
                logPopupPerformanceEvent("navigation started", for: webView)
            }
            #endif
            DispatchQueue.main.async {
                if !isPopup {
                    self.viewModel.isLoading = true
                }
                self.viewModel.statusMessage = BrowserStatusText.loading
            }
        }

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            let isPopup = popupWebViews.contains(webView)
            let completedURL = webView.url
            if isPopup {
                #if DEBUG
                logPopupPerformanceEvent("navigation didFinish", for: webView)
                #endif
                recordPopupNavigationCompleted(webView)
                #if DEBUG
                beginPopupDOMSamplingIfNeeded(webView)
                #endif
            }
            DispatchQueue.main.async {
                if !isPopup {
                    self.viewModel.isLoading = false
                    self.viewModel.currentURL = completedURL?.absoluteString ?? ""
                }
            }
            inspectCompletedPage(webView, completedURL: completedURL)
        }

        func webView(_ webView: WKWebView, didFail _: WKNavigation!, withError error: Error) {
            let isPopup = popupWebViews.contains(webView)
            #if DEBUG
            if isPopup {
                logPopupPerformanceEvent("navigation failed", for: webView)
            }
            #endif
            DispatchQueue.main.async {
                if !isPopup {
                    self.viewModel.isLoading = false
                }
                self.viewModel.statusMessage = BrowserStatusText.networkError
            }
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation _: WKNavigation!,
                     withError error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            let isPopup = popupWebViews.contains(webView)
            #if DEBUG
            if isPopup {
                logPopupPerformanceEvent("provisional navigation failed", for: webView)
            }
            #endif
            DispatchQueue.main.async {
                if !isPopup {
                    self.viewModel.isLoading = false
                }
                self.viewModel.statusMessage = BrowserStatusText.networkError
            }
        }

        private func inspectCompletedPage(_ webView: WKWebView, completedURL: URL?) {
            let script = """
            (() => ({
                pageText: document.body ? document.body.innerText : '',
                hasPasswordField: document.querySelector('input[type="password"]') !== null
            }))()
            """
            webView.evaluateJavaScript(script) { [weak self, weak webView] result, _ in
                guard let self, let webView else { return }
                let values = result as? [String: Any]
                let pageText = values?["pageText"] as? String ?? ""
                let hasPasswordField = values?["hasPasswordField"] as? Bool ?? false
                let status = BrowserPageStatusClassifier.status(
                    url: completedURL,
                    pageText: pageText,
                    hasPasswordField: hasPasswordField
                )
                DispatchQueue.main.async {
                    guard webView.url == completedURL else { return }
                    self.viewModel.statusMessage = status
                }
            }
        }

        #if DEBUG
        private func startPopupPerformanceTrace(for webView: WKWebView) {
            nextPopupPerformanceTraceID &+= 1
            popupPerformanceTraces[ObjectIdentifier(webView)] = PopupPerformanceTrace(
                id: nextPopupPerformanceTraceID,
                startedAt: ProcessInfo.processInfo.systemUptime,
                startedAtWallClock: Date().timeIntervalSince1970
            )
            logPopupPerformanceEvent("popup created", for: webView)
        }

        private func logPopupPerformanceEvent(_ event: String, for webView: WKWebView) {
            guard let trace = popupPerformanceTraces[ObjectIdentifier(webView)] else { return }
            let elapsed = ProcessInfo.processInfo.systemUptime - trace.startedAt
            browserPerformanceLogger.info(
                "[BrowserPerf] trace=\(trace.id, privacy: .public) \(event, privacy: .public) +\(elapsed, format: .fixed(precision: 3))s"
            )
        }
        #endif

        @MainActor
        func recordPopupNavigationCompleted(_ popup: WKWebView) {
            guard popupWebViews.contains(where: { $0 === popup }) else { return }
            let key = ObjectIdentifier(popup)
            var state = popupFocusAcquisitionStates[key] ?? PopupFocusAcquisitionState()
            state.hasCompletedNavigation = true
            popupFocusAcquisitionStates[key] = state
            attemptProductionPopupFocusAcquisition(for: popup)
        }

        @MainActor
        func popupDidAttach(_ popup: WKWebView) {
            guard popupWebViews.contains(where: { $0 === popup }) else { return }
            attemptProductionPopupFocusAcquisition(for: popup)
        }

        @MainActor
        private func attemptProductionPopupFocusAcquisition(for popup: WKWebView) {
            let key = ObjectIdentifier(popup)
            guard var state = popupFocusAcquisitionStates[key],
                  state.hasCompletedNavigation,
                  !state.isResolved,
                  popupAttachmentChecker(popup),
                  viewModel.popupWebView === popup else { return }

            // Reaching this eligible point resolves focus for this popup identity.
            // A later navigation must never trigger another acquisition attempt.
            state.isResolved = true
            popupFocusAcquisitionStates[key] = state

            guard !popup.isFirstResponder else {
                #if DEBUG
                logPopupPerformanceEvent(
                    "production focus acquisition completed accepted=not-needed alreadyFirstResponder=true",
                    for: popup
                )
                #endif
                return
            }

            #if DEBUG
            logPopupPerformanceEvent(
                "production focus acquisition requested method=becomeFirstResponder",
                for: popup
            )
            #endif
            let accepted = popupFocusAcquirer(popup)
            #if DEBUG
            logPopupPerformanceEvent(
                "production focus acquisition completed method=becomeFirstResponder accepted=\(accepted) isFirstResponder=\(popup.isFirstResponder)",
                for: popup
            )
            #else
            _ = accepted
            #endif
        }

        #if DEBUG
        @MainActor
        private func performDiagnosticFocusPulse() {
            guard let popup = viewModel.popupWebView,
                  popupWebViews.contains(where: { $0 === popup }) else {
                browserPerformanceLogger.info(
                    "[BrowserPerf] diagnostic focus pulse ignored reason=no-visible-tracked-popup"
                )
                return
            }

            logPopupPerformanceEvent(
                "diagnostic focus pulse requested method=becomeFirstResponder",
                for: popup
            )
            let wasFirstResponder = popup.isFirstResponder
            let accepted = popup.becomeFirstResponder()
            DispatchQueue.main.async { [weak self, weak popup] in
                guard let self, let popup else { return }
                self.logPopupPerformanceEvent(
                    "diagnostic focus pulse completed method=becomeFirstResponder accepted=\(accepted) wasFirstResponder=\(wasFirstResponder) isFirstResponder=\(popup.isFirstResponder) windowAttached=\(popup.window != nil)",
                    for: popup
                )
            }
        }
        #endif

        #if DEBUG
        private func beginPopupDOMSamplingIfNeeded(_ webView: WKWebView) {
            let key = ObjectIdentifier(webView)
            guard var trace = popupPerformanceTraces[key] else { return }
            let shouldStartSampling = !trace.isSamplingDOM
            if shouldStartSampling {
                trace.isSamplingDOM = true
            }
            popupPerformanceTraces[key] = trace
            installPopupPerformanceHooks(webView, shouldStartSampling: shouldStartSampling)
        }

        private func installPopupPerformanceHooks(
            _ webView: WKWebView,
            shouldStartSampling: Bool
        ) {
            let script = #"""
            (() => {
                if (window.__tdhBrowserPerf) {
                    return { installed: false, reason: 'already-installed' };
                }

                const events = [];
                const maximumQueuedEvents = 100;
                const structuralPattern = /trip_information|report|schedule|roster|loading|spinner|busy|print/i;
                const structuralTokens = value => {
                    const source = String(value || '').toLowerCase();
                    const tokens = [];
                    if (source.includes('trip_information')) tokens.push('trip_information_<redacted>.html');
                    if (source.includes('report')) tokens.push('report');
                    if (source.includes('schedule')) tokens.push('schedule');
                    if (source.includes('roster')) tokens.push('roster');
                    if (source.includes('loading')) tokens.push('loading');
                    if (source.includes('spinner')) tokens.push('spinner');
                    if (source.includes('busy')) tokens.push('busy');
                    if (source.includes('print')) tokens.push('print');
                    return Array.from(new Set(tokens));
                };
                const dimensions = () => ({
                    innerWidth: Math.round(window.innerWidth || 0),
                    innerHeight: Math.round(window.innerHeight || 0),
                    viewportWidth: Math.round(window.visualViewport ? window.visualViewport.width : 0),
                    viewportHeight: Math.round(window.visualViewport ? window.visualViewport.height : 0),
                    viewportScale: window.visualViewport ? Number(window.visualViewport.scale.toFixed(3)) : 0,
                    visibilityState: document.visibilityState || 'unknown',
                    hasFocus: document.hasFocus()
                });
                const enqueue = (type, details = {}) => {
                    events.push({ type, epochMilliseconds: Date.now(), ...dimensions(), ...details });
                    if (events.length > maximumQueuedEvents) {
                        events.splice(0, events.length - maximumQueuedEvents);
                    }
                };
                const elementNames = element => [
                    element && element.id,
                    element && typeof element.className === 'string' ? element.className : '',
                    element && element.getAttribute ? element.getAttribute('name') : '',
                    element && element.getAttribute ? element.getAttribute('src') : '',
                    element && element.getAttribute ? element.getAttribute('href') : ''
                ].filter(Boolean).join(' ');
                const describeTarget = target => {
                    const element = target && target.nodeType === Node.ELEMENT_NODE
                        ? target
                        : target && target.parentElement;
                    if (!element) return 'unknown';
                    const tokens = structuralTokens(elementNames(element));
                    const hasUnloggedIdentity = Boolean(element.id || (
                        typeof element.className === 'string' && element.className.trim()
                    ));
                    return `${(element.tagName || 'unknown').toLowerCase()}`
                        + `${tokens.length ? ':' + tokens.join(',') : (hasUnloggedIdentity ? ':<redacted>' : '')}`;
                };
                const snapshot = () => {
                    const bodyText = document.body ? document.body.innerText : '';
                    const rows = Array.from(document.querySelectorAll('tr'));
                    const namedElements = Array.from(document.querySelectorAll(
                        '[id], [class], [name], [src], [href]'
                    ));
                    const controls = Array.from(document.querySelectorAll(
                        'button, input[type="button"], input[type="submit"], a'
                    ));
                    const label = element => (
                        element.innerText || element.value || element.getAttribute('aria-label') || ''
                    ).trim().toLowerCase();
                    const candidateTokens = Array.from(new Set(namedElements.flatMap(element =>
                        structuralTokens(elementNames(element))
                    ))).slice(0, 8);
                    return {
                        readyState: document.readyState,
                        bodyCharacterCount: bodyText.length,
                        tableCount: document.querySelectorAll('table').length,
                        nonEmptyRowCount: rows.filter(row => (row.innerText || '').trim().length > 0).length,
                        reportNamedContainerCount: namedElements.filter(element =>
                            structuralPattern.test(elementNames(element))
                        ).length,
                        reportCandidateTokens: candidateTokens,
                        printControlCount: controls.filter(element => label(element).includes('print')).length,
                        busyIndicatorCount: document.querySelectorAll(
                            '[aria-busy="true"], .loading, .spinner, [role="progressbar"]'
                        ).length,
                        unableToLoadReport: bodyText.toLowerCase().includes('unable to load report')
                    };
                };
                const meaningfulSignature = value => JSON.stringify([
                    value.tableCount,
                    value.nonEmptyRowCount,
                    value.reportNamedContainerCount,
                    value.reportCandidateTokens,
                    value.printControlCount,
                    value.busyIndicatorCount,
                    value.unableToLoadReport
                ]);

                window.addEventListener('resize', () => enqueue('window resize'), { passive: true });
                if (window.visualViewport) {
                    window.visualViewport.addEventListener(
                        'resize',
                        () => enqueue('visualViewport resize'),
                        { passive: true }
                    );
                }
                window.addEventListener('focus', () => enqueue('focus'), { passive: true });
                window.addEventListener('blur', () => enqueue('blur'), { passive: true });
                document.addEventListener('visibilitychange', () => enqueue('visibilitychange'), { passive: true });
                if ('PointerEvent' in window) {
                    document.addEventListener('pointerdown', event => enqueue(
                        'pointer/touch interaction',
                        { pointerType: event.pointerType || 'pointer' }
                    ), { passive: true, capture: true });
                } else {
                    document.addEventListener('touchstart', () => enqueue(
                        'pointer/touch interaction',
                        { pointerType: 'touch' }
                    ), { passive: true, capture: true });
                }

                let pendingMutationCount = 0;
                let pendingMutationTargets = new Set();
                let mutationDebounce;
                let lastMutationSignature = meaningfulSignature(snapshot());
                const observer = new MutationObserver(mutations => {
                    pendingMutationCount += mutations.length;
                    mutations.forEach(mutation => pendingMutationTargets.add(describeTarget(mutation.target)));
                    clearTimeout(mutationDebounce);
                    mutationDebounce = setTimeout(() => {
                        const currentSnapshot = snapshot();
                        const currentSignature = meaningfulSignature(currentSnapshot);
                        if (currentSignature !== lastMutationSignature) {
                            enqueue('DOM mutation', {
                                mutationCount: pendingMutationCount,
                                mutationTargets: Array.from(pendingMutationTargets).slice(0, 8),
                                snapshot: currentSnapshot
                            });
                            lastMutationSignature = currentSignature;
                        }
                        pendingMutationCount = 0;
                        pendingMutationTargets.clear();
                    }, 250);
                });
                if (document.documentElement) {
                    observer.observe(document.documentElement, {
                        subtree: true,
                        childList: true,
                        attributes: true,
                        characterData: true
                    });
                }

                window.__tdhBrowserPerf = { events, snapshot, observer };
                return { installed: true };
            })()
            """#
            webView.evaluateJavaScript(script) { [weak self, weak webView] _, error in
                DispatchQueue.main.async {
                    guard let self, let webView,
                          self.popupPerformanceTraces[ObjectIdentifier(webView)] != nil else { return }
                    self.logPopupPerformanceEvent(
                        error == nil ? "event hooks installed" : "event hooks install failed",
                        for: webView
                    )
                    if shouldStartSampling {
                        self.samplePopupDOM(webView)
                    }
                }
            }
        }

        private func samplePopupDOM(_ webView: WKWebView) {
            let script = #"""
            (() => {
                const instrumentation = window.__tdhBrowserPerf;
                if (!instrumentation) return null;
                const value = instrumentation.snapshot();
                value.events = instrumentation.events.splice(0, instrumentation.events.length);
                return value;
            })()
            """#
            webView.evaluateJavaScript(script) { [weak self, weak webView] result, error in
                DispatchQueue.main.async {
                    guard let self, let webView else { return }
                    let key = ObjectIdentifier(webView)
                    guard var trace = self.popupPerformanceTraces[key],
                          self.popupWebViews.contains(where: { $0 === webView }) else { return }

                    let values = result as? [String: Any]
                    let readyState = values?["readyState"] as? String ?? "unknown"
                    let bodyCharacters = (values?["bodyCharacterCount"] as? NSNumber)?.intValue ?? -1
                    let tables = (values?["tableCount"] as? NSNumber)?.intValue ?? -1
                    let nonEmptyRows = (values?["nonEmptyRowCount"] as? NSNumber)?.intValue ?? -1
                    let namedContainers = (values?["reportNamedContainerCount"] as? NSNumber)?.intValue ?? -1
                    let candidateTokens = values?["reportCandidateTokens"] as? [String] ?? []
                    let printControls = (values?["printControlCount"] as? NSNumber)?.intValue ?? -1
                    let busyIndicators = (values?["busyIndicatorCount"] as? NSNumber)?.intValue ?? -1
                    let unable = values?["unableToLoadReport"] as? Bool ?? false
                    let events = values?["events"] as? [[String: Any]] ?? []
                    self.logPopupPerformanceEvents(events, trace: trace)
                    let signature = [
                        readyState,
                        String(bodyCharacters),
                        String(tables),
                        String(nonEmptyRows),
                        String(namedContainers),
                        candidateTokens.joined(separator: ","),
                        String(printControls),
                        String(busyIndicators),
                        String(unable),
                        error == nil ? "ok" : "js-error"
                    ].joined(separator: "|")

                    if trace.lastDOMSignature != signature {
                        trace.lastDOMSignature = signature
                        self.popupPerformanceTraces[key] = trace
                        let elapsed = ProcessInfo.processInfo.systemUptime - trace.startedAt
                        browserPerformanceLogger.info(
                            "[BrowserPerf] trace=\(trace.id, privacy: .public) DOM snapshot +\(elapsed, format: .fixed(precision: 3))s readyState=\(readyState, privacy: .public) bodyChars=\(bodyCharacters, privacy: .public) tables=\(tables, privacy: .public) nonEmptyRows=\(nonEmptyRows, privacy: .public) namedContainers=\(namedContainers, privacy: .public) candidateTokens=\(candidateTokens.joined(separator: ","), privacy: .public) printControls=\(printControls, privacy: .public) busy=\(busyIndicators, privacy: .public) unable=\(unable, privacy: .public) jsError=\(error != nil, privacy: .public)"
                        )
                    }

                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak webView] in
                        guard let self, let webView,
                              self.popupPerformanceTraces[key] != nil else { return }
                        self.samplePopupDOM(webView)
                    }
                }
            }
        }

        private func logPopupPerformanceEvents(
            _ events: [[String: Any]],
            trace: PopupPerformanceTrace
        ) {
            for event in events {
                let type = event["type"] as? String ?? "unknown event"
                let epochMilliseconds = (event["epochMilliseconds"] as? NSNumber)?.doubleValue ?? 0
                let elapsed = max(0, (epochMilliseconds / 1_000) - trace.startedAtWallClock)
                let innerWidth = (event["innerWidth"] as? NSNumber)?.intValue ?? -1
                let innerHeight = (event["innerHeight"] as? NSNumber)?.intValue ?? -1
                let viewportWidth = (event["viewportWidth"] as? NSNumber)?.intValue ?? -1
                let viewportHeight = (event["viewportHeight"] as? NSNumber)?.intValue ?? -1
                let viewportScale = (event["viewportScale"] as? NSNumber)?.doubleValue ?? -1
                let visibility = event["visibilityState"] as? String ?? "unknown"
                let hasFocus = event["hasFocus"] as? Bool ?? false
                let pointerType = event["pointerType"] as? String ?? "none"
                let mutationCount = (event["mutationCount"] as? NSNumber)?.intValue ?? 0
                let mutationTargets = event["mutationTargets"] as? [String] ?? []
                let snapshot = event["snapshot"] as? [String: Any]
                let bodyCharacters = (snapshot?["bodyCharacterCount"] as? NSNumber)?.intValue ?? -1
                let namedContainers = (snapshot?["reportNamedContainerCount"] as? NSNumber)?.intValue ?? -1
                let candidateTokens = snapshot?["reportCandidateTokens"] as? [String] ?? []
                let printControls = (snapshot?["printControlCount"] as? NSNumber)?.intValue ?? -1
                let busyIndicators = (snapshot?["busyIndicatorCount"] as? NSNumber)?.intValue ?? -1
                let unable = snapshot?["unableToLoadReport"] as? Bool ?? false
                browserPerformanceLogger.info(
                    "[BrowserPerf] trace=\(trace.id, privacy: .public) \(type, privacy: .public) +\(elapsed, format: .fixed(precision: 3))s inner=\(innerWidth, privacy: .public)x\(innerHeight, privacy: .public) viewport=\(viewportWidth, privacy: .public)x\(viewportHeight, privacy: .public)@\(viewportScale, format: .fixed(precision: 3)) visibility=\(visibility, privacy: .public) focus=\(hasFocus, privacy: .public) pointer=\(pointerType, privacy: .public) mutations=\(mutationCount, privacy: .public) targets=\(mutationTargets.joined(separator: ","), privacy: .public) bodyChars=\(bodyCharacters, privacy: .public) printControls=\(printControls, privacy: .public) namedContainers=\(namedContainers, privacy: .public) candidateTokens=\(candidateTokens.joined(separator: ","), privacy: .public) busy=\(busyIndicators, privacy: .public) unable=\(unable, privacy: .public)"
                )
            }
        }
        #endif

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
                guard let url = responseURL else {
                    DispatchQueue.main.async {
                        self.failPDFProcessing("PDF response URL is missing")
                    }
                    return
                }
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                    self?.downloadPDF(from: url, cookies: cookies)
                }

            case "blob":
                decisionHandler(.cancel)
                guard let urlStr = responseURL?.absoluteString else {
                    DispatchQueue.main.async {
                        self.failPDFProcessing("Blob PDF URL is missing")
                    }
                    return
                }
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
                DispatchQueue.main.async {
                    self.handleDownloadedPDFResult(
                        data: data,
                        response: response,
                        error: error,
                        sourceFileName: url.lastPathComponent
                    )
                }
            }.resume()
        }

        @MainActor
        func handleDownloadedPDFResult(
            data: Data?,
            response: URLResponse?,
            error: Error?,
            sourceFileName: String
        ) {
            if let error {
                failPDFProcessing("PDF fetch failed: \(error.localizedDescription)")
                return
            }
            guard let data, !data.isEmpty else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                failPDFProcessing("Empty response (HTTP \(status))")
                return
            }
            finishPDFProcessing(data, sourceFileName: sourceFileName)
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
                DispatchQueue.main.async {
                    self.handleBlobExtractionResult(result)
                }
            }
        }

        @MainActor
        func handleBlobExtractionResult(_ result: Result<Any, Error>) {
            switch result {
            case .success(let value):
                guard let str = value as? String else {
                    failPDFProcessing("Invalid JS return value: \(String(describing: value))")
                    return
                }
                guard str.hasPrefix("OK:") else {
                    failPDFProcessing("JS blob fetch error: \(str)")
                    return
                }
                let base64 = String(str.dropFirst(3))
                guard let data = Data(base64Encoded: base64) else {
                    failPDFProcessing("Base64 decode failed (length: \(base64.count))")
                    return
                }
                finishPDFProcessing(data, sourceFileName: "crewaccess_trip.pdf")

            case .failure(let error):
                failPDFProcessing("JS execution failed: \(error.localizedDescription)")
            }
        }

        @MainActor
        private func finishPDFProcessing(_ data: Data, sourceFileName: String?) {
            // Blob extraction no longer needs popupParents once Data has been materialized.
            // Hand the value to the importer first, then tear down every live popup.
            pdfDataHandler(data, sourceFileName)
            closePopups()
        }

        @MainActor
        private func failPDFProcessing(_ message: String) {
            viewModel.errorMessage = message
            closePopups()
        }

        // MARK: - ポップアップ閉じる

        @MainActor
        func closePopups() {
            guard activePopupTeardownGeneration == nil else {
                browserPopupLogger.info("[BrowserPopup] teardown request coalesced")
                return
            }

            var popups = popupWebViews
            if let visiblePopup = viewModel.popupWebView,
               !popups.contains(where: { $0 === visiblePopup }) {
                popups.append(visiblePopup)
            }

            popupTeardownGeneration &+= 1
            let generation = popupTeardownGeneration
            activePopupTeardownGeneration = generation
            activePopupTeardownTargets = popups
            pendingWindowCloseCallbacks = popups.count
            browserPopupLogger.info(
                "[BrowserPopup] teardown begin tracked=\(self.popupWebViews.count, privacy: .public) parents=\(self.popupParents.count, privacy: .public) targets=\(popups.count, privacy: .public)"
            )

            guard !popups.isEmpty else {
                finalizePopupTeardown(generation: generation, reason: "no targets")
                return
            }

            for popup in popups {
                javaScriptEvaluator(popup, "window.close()") { [weak self] error in
                    self?.windowCloseCompleted(
                        generation: generation,
                        error: error
                    )
                }
            }

            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 750_000_000)
                guard let self,
                      self.activePopupTeardownGeneration == generation else { return }
                browserPopupLogger.error(
                    "[BrowserPopup] window.close timeout remaining=\(self.pendingWindowCloseCallbacks, privacy: .public)"
                )
                self.finalizePopupTeardown(
                    generation: generation,
                    reason: "window.close timeout"
                )
            }
        }

        @MainActor
        private func windowCloseCompleted(
            generation: UInt,
            error: Error?
        ) {
            guard activePopupTeardownGeneration == generation else { return }
            if let error {
                browserPopupLogger.error(
                    "[BrowserPopup] window.close failed error=\(error.localizedDescription, privacy: .public)"
                )
            } else {
                browserPopupLogger.info("[BrowserPopup] window.close completed")
            }
            pendingWindowCloseCallbacks = max(0, pendingWindowCloseCallbacks - 1)
            guard pendingWindowCloseCallbacks == 0 else { return }
            finalizePopupTeardown(
                generation: generation,
                reason: error == nil ? "window.close completed" : "window.close failed"
            )
        }

        @MainActor
        private func finalizePopupTeardown(
            generation: UInt,
            reason: String
        ) {
            guard activePopupTeardownGeneration == generation else { return }
            let popups = activePopupTeardownTargets
            for popup in popups {
                #if DEBUG
                logPopupPerformanceEvent("popup teardown", for: popup)
                popupPerformanceTraces.removeValue(forKey: ObjectIdentifier(popup))
                #endif
                popupFocusAcquisitionStates.removeValue(forKey: ObjectIdentifier(popup))
                (popup as? BrowserPopupWebView)?.didAttachToWindow = nil
                popup.stopLoading()
                popup.navigationDelegate = nil
                popup.uiDelegate = nil
                popup.loadHTMLString("", baseURL: nil)
            }

            popupWebViews.removeAll { trackedPopup in
                popups.contains(where: { $0 === trackedPopup })
            }
            for popup in popups {
                popupParents.removeValue(forKey: ObjectIdentifier(popup))
            }
            if let visiblePopup = viewModel.popupWebView,
               popups.contains(where: { $0 === visiblePopup }) {
                viewModel.popupWebView = nil
            }
            pendingWindowCloseCallbacks = 0
            activePopupTeardownTargets.removeAll()
            activePopupTeardownGeneration = nil
            browserPopupLogger.info(
                "[BrowserPopup] teardown complete reason=\(reason, privacy: .public) tracked=\(self.popupWebViews.count, privacy: .public) parents=\(self.popupParents.count, privacy: .public) visible=\(self.viewModel.popupWebView == nil, privacy: .public)"
            )
        }
    }
}
