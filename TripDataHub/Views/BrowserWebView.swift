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

#if DEBUG
private let browserProbeLogger = Logger(
    subsystem: "com.sfune.TripDataHub",
    category: "AutoPrintProbe"
)

/// Phase 0 evidence gathering for `docs/INVESTIGATION_CREWACCESS_AUTO_PRINT.md`.
///
/// **Observational only.** Nothing in this type — or on the path that calls it — clicks, focuses,
/// submits a form, invokes a site function, or dispatches a synthetic event. It reads a page that
/// has already finished loading and logs a redacted description of it.
///
/// It exists to answer one question on a real device instead of inferring it from comments and RCA
/// documents: **is the CrewAccess Print control a same-origin DOM element reachable from this
/// WebView's JavaScript context, or a Zscaler-injected / cross-origin surface?**
///
/// Privacy: the probe never reads cookies, storage, credentials, or auth tokens, and never returns
/// a URL query value. Every string it returns is whitespace-collapsed, truncated, and has digit
/// runs of four or more masked, so trip identifiers, crew IDs, and seniority numbers do not reach
/// the log. Element labels are page chrome; they are logged so the Print control can be identified.
enum CrewAccessPageProbe {

    enum PageKind: String {
        /// `crewaccess.inside.ups.com/access/rs/reports/<uuid>/content/Trip_Information…`
        case tripInformationReport = "trip-information-report"
        /// Some other generated report under the same `/access/rs/reports/` tree.
        case crewAccessReport = "crewaccess-report"
        case crewAccessOther = "crewaccess-other"
        case fltopsPortal = "fltops-portal"
        case zscaler = "zscaler"
        case upsOther = "ups-other"
        case other = "other"
        case unknown = "unknown"
    }

    /// Intervals *between* samples, in seconds — cumulatively 1s / 3s / 6s / 10s after `didFinish`.
    ///
    /// One sample cannot answer *when* a Print control appears, because the report DOM keeps
    /// changing after `didFinish` (that is why the popup performance sampler debounces mutations).
    /// The schedule is bounded and is abandoned as soon as the navigation is superseded.
    static let resampleIntervals: [TimeInterval] = [1, 2, 3, 4]

    static func pageKind(for url: URL?) -> PageKind {
        guard let url, let host = url.host?.lowercased() else { return .unknown }
        if host.contains("zscaler") || host.contains("zscloud") {
            return .zscaler
        }
        if host == "crewaccess.inside.ups.com" {
            let path = url.path
            let tripInformationPattern =
                #"^/access/rs/reports/[0-9a-fA-F-]{36}/content/Trip_Information"#
            if path.range(of: tripInformationPattern, options: .regularExpression) != nil {
                return .tripInformationReport
            }
            if path.hasPrefix("/access/rs/reports/") {
                return .crewAccessReport
            }
            return .crewAccessOther
        }
        if host == "fltops-portal.ups.com" { return .fltopsPortal }
        if host == "ups.com" || host.hasSuffix(".ups.com") { return .upsOther }
        return .other
    }

    /// Whether a page of this kind is worth re-reading on the bounded schedule.
    ///
    /// Phase 0 is discovery, so every UPS or Zscaler surface qualifies: the Trip Details document
    /// has not yet been proven to live on the host the printed PDFs point at.
    static func warrantsResampling(_ kind: PageKind) -> Bool {
        switch kind {
        case .tripInformationReport, .crewAccessReport, .crewAccessOther,
             .fltopsPortal, .zscaler, .upsOther:
            return true
        case .other, .unknown:
            return false
        }
    }

    /// A loggable form of a URL: scheme, host, and path with report UUIDs and long digit runs
    /// masked. Query **values** are never included — only the parameter names, because a query can
    /// carry a session or auth token.
    static func urlShape(for url: URL?) -> String {
        guard let url else { return "<nil>" }
        let scheme = url.scheme ?? "?"
        let host = url.host ?? "?"
        let uuidPattern =
            #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
        let path = url.path
            .replacingOccurrences(of: uuidPattern, with: "<uuid>", options: .regularExpression)
            .replacingOccurrences(of: #"\d{4,}"#, with: "<n>", options: .regularExpression)
        let names = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .map(\.name)
            .sorted() ?? []
        let query = names.isEmpty
            ? ""
            : "?<\(names.count) params: \(names.prefix(6).joined(separator: ","))>"
        return "\(scheme)://\(host)\(path)\(query)"
    }

    /// The JavaScript expression merged into the existing page-inspection script as `probe`.
    ///
    /// Read-only by construction: it queries, measures, and reads attributes. There is no
    /// assignment to the page, no event dispatch, and no invocation of any page function.
    static let probeExpression: String = #"""
            (() => {
                try {
                    const MAXIMUM_LOGGED_ELEMENTS = 12;
                    const MAXIMUM_SCANNED_ELEMENTS = 4000;
                    const redact = value => String(value === null || value === undefined ? '' : value)
                        .replace(/\s+/g, ' ')
                        .replace(/\d{4,}/g, '<n>')
                        .trim()
                        .slice(0, 60);
                    const originOf = value => {
                        try { return new URL(String(value), location.href).origin; } catch (error) { return '<unparsable>'; }
                    };
                    const pathShapeOf = value => {
                        try {
                            const parsed = new URL(String(value), location.href);
                            const path = parsed.pathname
                                .replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi, '<uuid>')
                                .replace(/\d{4,}/g, '<n>');
                            return (parsed.origin + path).slice(0, 120);
                        } catch (error) { return '<unparsable>'; }
                    };
                    const attributeOf = (element, name) => (
                        element && element.getAttribute ? element.getAttribute(name) : null
                    );
                    const labelOf = element => [
                        element.innerText,
                        element.value,
                        attributeOf(element, 'aria-label'),
                        attributeOf(element, 'title'),
                        attributeOf(element, 'alt')
                    ].filter(Boolean).join(' ');
                    const identityOf = element => [
                        element.id,
                        typeof element.className === 'string' ? element.className : '',
                        attributeOf(element, 'name')
                    ].filter(Boolean).join(' ');
                    const isVisible = element => {
                        const rects = element.getClientRects ? element.getClientRects() : [];
                        if (!rects || rects.length === 0) return false;
                        const style = window.getComputedStyle(element);
                        if (!style) return true;
                        return style.visibility !== 'hidden'
                            && style.display !== 'none'
                            && Number(style.opacity || '1') > 0.01;
                    };
                    const printMatch = element => {
                        const ownText = Array.from(element.childNodes || [])
                            .filter(node => node.nodeType === 3)
                            .map(node => node.textContent)
                            .join(' ');
                        const label = ownText + ' ' + (element.value || '') + ' '
                            + (attributeOf(element, 'aria-label') || '') + ' '
                            + (attributeOf(element, 'title') || '') + ' '
                            + (attributeOf(element, 'alt') || '');
                        const identity = identityOf(element);
                        if (/^\s*print(\s+trip)?\s*$/i.test(label)) return 'exact';
                        if (/print/i.test(label)) return 'label-substring';
                        if (/print/i.test(identity)) return 'identity-substring';
                        return '';
                    };
                    const describe = (element, rootName) => {
                        const rect = element.getBoundingClientRect
                            ? element.getBoundingClientRect()
                            : { x: 0, y: 0, width: 0, height: 0 };
                        const form = element.form || (element.closest ? element.closest('form') : null);
                        return {
                            root: rootName,
                            tagName: (element.tagName || '?').toLowerCase(),
                            type: redact(attributeOf(element, 'type')),
                            id: redact(element.id),
                            className: redact(typeof element.className === 'string' ? element.className : ''),
                            role: redact(attributeOf(element, 'role')),
                            label: redact(labelOf(element)),
                            value: redact(element.value),
                            ariaLabel: redact(attributeOf(element, 'aria-label')),
                            title: redact(attributeOf(element, 'title')),
                            href: element.href ? pathShapeOf(element.href) : '',
                            target: redact(attributeOf(element, 'target')),
                            hasOnclickAttribute: attributeOf(element, 'onclick') !== null,
                            onclickAttribute: redact(attributeOf(element, 'onclick')),
                            hasOnclickProperty: typeof element.onclick === 'function',
                            formAction: form ? pathShapeOf(form.action || location.href) : '',
                            formMethod: form ? redact(form.method) : '',
                            isDisabled: element.disabled === true || attributeOf(element, 'aria-disabled') === 'true',
                            tabIndex: typeof element.tabIndex === 'number' ? element.tabIndex : -1,
                            isVisible: isVisible(element),
                            rect: [
                                Math.round(rect.x || 0),
                                Math.round(rect.y || 0),
                                Math.round(rect.width || 0),
                                Math.round(rect.height || 0)
                            ],
                            printMatch: printMatch(element)
                        };
                    };

                    const controlSelector = 'a, button, input[type="button"], input[type="submit"], '
                        + 'input[type="image"], [role="button"], [onclick]';
                    const roots = [{ name: 'document', node: document }];
                    const shadowHosts = Array.from(document.querySelectorAll('*'))
                        .slice(0, MAXIMUM_SCANNED_ELEMENTS)
                        .filter(element => element.shadowRoot)
                        .slice(0, 8);
                    shadowHosts.forEach((host, index) => roots.push({
                        name: 'shadow[' + index + ']:' + (host.tagName || '?').toLowerCase(),
                        node: host.shadowRoot
                    }));

                    let printElements = [];
                    let interactiveElements = [];
                    let scannedElementCount = 0;
                    let vendorMarkerCount = 0;
                    const vendorMarkerSamples = [];
                    roots.forEach(root => {
                        const scanned = Array.from(
                            root.node.querySelectorAll ? root.node.querySelectorAll('*') : []
                        ).slice(0, MAXIMUM_SCANNED_ELEMENTS);
                        scannedElementCount += scanned.length;
                        scanned.forEach(element => {
                            if (printMatch(element)) {
                                printElements.push({ element: element, root: root.name });
                            }
                            if (element.matches && element.matches(controlSelector)) {
                                interactiveElements.push({ element: element, root: root.name });
                            }
                            const vendorSource = identityOf(element) + ' '
                                + (attributeOf(element, 'src') || '') + ' '
                                + (attributeOf(element, 'href') || '');
                            if (/zscaler|zpa\b|zia\b|zsc-/i.test(vendorSource)) {
                                vendorMarkerCount += 1;
                                if (vendorMarkerSamples.length < 4) {
                                    vendorMarkerSamples.push(redact(vendorSource));
                                }
                            }
                        });
                    });

                    const frames = Array.from(document.querySelectorAll('iframe, frame'))
                        .slice(0, 8)
                        .map(frame => {
                            let isSameOriginAccessible = false;
                            let innerPrintElementCount = -1;
                            let innerReadyState = '';
                            try {
                                const frameDocument = frame.contentDocument;
                                isSameOriginAccessible = Boolean(frameDocument && frameDocument.body);
                                if (isSameOriginAccessible) {
                                    innerReadyState = frameDocument.readyState;
                                    innerPrintElementCount = Array.from(
                                        frameDocument.querySelectorAll(controlSelector)
                                    ).slice(0, 500).filter(element => printMatch(element)).length;
                                }
                            } catch (error) {
                                isSameOriginAccessible = false;
                            }
                            return {
                                srcOrigin: originOf(attributeOf(frame, 'src') || ''),
                                srcShape: pathShapeOf(attributeOf(frame, 'src') || ''),
                                id: redact(frame.id),
                                className: redact(typeof frame.className === 'string' ? frame.className : ''),
                                isSameOriginAccessible: isSameOriginAccessible,
                                innerReadyState: innerReadyState,
                                innerPrintElementCount: innerPrintElementCount
                            };
                        });

                    const distinctOrigins = selector => Array.from(new Set(
                        Array.from(document.querySelectorAll(selector))
                            .slice(0, 200)
                            .map(element => originOf(
                                attributeOf(element, 'src') || attributeOf(element, 'href') || ''
                            ))
                    )).slice(0, 8);

                    const bodyText = document.body ? document.body.innerText : '';
                    const rows = Array.from(document.querySelectorAll('tr')).slice(0, 2000);
                    let isTopSameOrigin = false;
                    try {
                        isTopSameOrigin = window.top.location.origin === location.origin;
                    } catch (error) {
                        isTopSameOrigin = false;
                    }

                    return {
                        readyState: document.readyState,
                        title: redact(document.title),
                        documentOrigin: location.origin,
                        isInFrame: window.top !== window.self,
                        isTopSameOrigin: isTopSameOrigin,
                        frameCount: window.frames.length,
                        frames: frames,
                        scriptOrigins: distinctOrigins('script[src]'),
                        styleOrigins: distinctOrigins('link[rel="stylesheet"]'),
                        shadowRootCount: shadowHosts.length,
                        scannedElementCount: scannedElementCount,
                        vendorMarkerCount: vendorMarkerCount,
                        vendorMarkerSamples: vendorMarkerSamples,
                        bodyCharacterCount: bodyText.length,
                        tableCount: document.querySelectorAll('table').length,
                        nonEmptyRowCount: rows.filter(row => (row.innerText || '').trim().length > 0).length,
                        legAnchorRowCount: rows.filter(row => {
                            const text = row.innerText || '';
                            return /[A-Z]{3}\s*[-–—]\s*[A-Z]{3}/.test(text) && /\d{2}:\d{2}/.test(text);
                        }).length,
                        hasTripIdLine: /\bTrip\s*Id\s*:\s*[A-Z0-9]{4,8}\s+\d{2}[A-Za-z]{3}\d{4}\b/.test(bodyText),
                        hasTripInformationHeading: /\btrip\s+information\b/i.test(
                            (document.title || '') + ' ' + bodyText.slice(0, 2000)
                        ),
                        hasRosterMarker: /\broster\b/i.test((document.title || '') + ' ' + bodyText.slice(0, 2000)),
                        unableToLoadReport: bodyText.toLowerCase().includes('unable to load report'),
                        busyIndicatorCount: document.querySelectorAll(
                            '[aria-busy="true"], .loading, .spinner, [role="progressbar"]'
                        ).length,
                        printElementCount: printElements.length,
                        interactiveElementCount: interactiveElements.length,
                        printElements: printElements
                            .slice(0, MAXIMUM_LOGGED_ELEMENTS)
                            .map(entry => describe(entry.element, entry.root)),
                        interactiveElements: interactiveElements
                            .slice(0, MAXIMUM_LOGGED_ELEMENTS)
                            .map(entry => describe(entry.element, entry.root))
                    };
                } catch (error) {
                    return { error: String(error).slice(0, 200) };
                }
            })()
    """#
}
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
        /// Phase 0 probe bookkeeping. `didFinish` counts are keyed by redacted URL shape so a page
        /// that completes navigation more than once is visible as such in the log.
        private var crewAccessProbeDidFinishCounts: [String: Int] = [:]
        private var crewAccessProbeSequences: [ObjectIdentifier: UInt] = [:]
        private var nextCrewAccessProbeSequence: UInt = 0
        /// Pending delayed probe work, keyed by `ObjectIdentifier` so the registry itself never
        /// retains a WebView. The Coordinator owns these tasks; every task body captures the
        /// Coordinator and the WebView weakly, so the ownership only ever points this way.
        private var crewAccessProbeTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
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

        /// The single per-navigation DOM read. Both the main WebView and every popup reach it from
        /// `didFinish`.
        ///
        /// In Release it returns exactly the two fields the status classifier consumes. In DEBUG it
        /// additionally carries the Phase 0 `probe` object, so evidence gathering rides on this one
        /// script instead of introducing a second, independent DOM inspection pipeline.
        static func pageInspectionScript() -> String {
            #if DEBUG
            return """
            (() => ({
                pageText: document.body ? document.body.innerText : '',
                hasPasswordField: document.querySelector('input[type="password"]') !== null,
                probe: \(CrewAccessPageProbe.probeExpression)
            }))()
            """
            #else
            return """
            (() => ({
                pageText: document.body ? document.body.innerText : '',
                hasPasswordField: document.querySelector('input[type="password"]') !== null
            }))()
            """
            #endif
        }

        private func inspectCompletedPage(_ webView: WKWebView, completedURL: URL?) {
            let script = Self.pageInspectionScript()
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
                #if DEBUG
                let probeValues = values?["probe"] as? [String: Any]
                // Weak: a queued diagnostic hop must never hold the Coordinator or a popup
                // WebView alive past the point the normal lifecycle would release them.
                DispatchQueue.main.async { [weak self, weak webView] in
                    guard let self, let webView else { return }
                    self.beginCrewAccessProbe(
                        probeValues,
                        webView: webView,
                        completedURL: completedURL
                    )
                }
                #endif
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

        // MARK: - Phase 0 auto-print evidence (DEBUG only, observational)

        #if DEBUG
        /// Logs one `didFinish` sample and, for UPS/Zscaler surfaces, schedules bounded re-reads.
        ///
        /// Observational only. This path never clicks, focuses, submits, invokes a site function,
        /// or dispatches a synthetic event, and it changes no production state.
        @MainActor
        func beginCrewAccessProbe(
            _ probe: [String: Any]?,
            webView: WKWebView,
            completedURL: URL?
        ) {
            // A newer navigation on this WebView supersedes any schedule still in flight.
            cancelCrewAccessProbe(for: webView)

            nextCrewAccessProbeSequence &+= 1
            let sequence = nextCrewAccessProbeSequence
            crewAccessProbeSequences[ObjectIdentifier(webView)] = sequence

            let shape = CrewAccessPageProbe.urlShape(for: completedURL)
            crewAccessProbeDidFinishCounts[shape, default: 0] += 1

            logCrewAccessProbeSample(
                probe,
                webView: webView,
                completedURL: completedURL,
                attempt: 0,
                sequence: sequence
            )

            // Nothing is scheduled against a WebView the Coordinator no longer owns, or while a
            // popup teardown is running. Diagnostics never outlive the surface they describe.
            let kind = CrewAccessPageProbe.pageKind(for: completedURL)
            guard CrewAccessPageProbe.warrantsResampling(kind),
                  activePopupTeardownGeneration == nil,
                  ownsCrewAccessProbeTarget(webView) else {
                crewAccessProbeSequences.removeValue(forKey: ObjectIdentifier(webView))
                return
            }
            scheduleCrewAccessProbeResample(
                webView: webView,
                completedURL: completedURL,
                nextAttempt: 1,
                sequence: sequence
            )
        }

        /// Whether this WebView is still one the Coordinator drives: the browser's main WebView, or
        /// a currently tracked popup. A popup removed by teardown fails this immediately.
        @MainActor
        private func ownsCrewAccessProbeTarget(_ webView: WKWebView) -> Bool {
            popupWebViews.contains(where: { $0 === webView }) || viewModel.webView === webView
        }

        /// Cancels and forgets any pending probe work for this WebView. Cancellation resumes a
        /// sleeping task immediately, so pending diagnostics become inert at once rather than at
        /// the end of the sampling schedule.
        @MainActor
        func cancelCrewAccessProbe(for webView: WKWebView) {
            let key = ObjectIdentifier(webView)
            crewAccessProbeTasks.removeValue(forKey: key)?.cancel()
            crewAccessProbeSequences.removeValue(forKey: key)
        }

        /// Ends a probe chain that reached its bound or found itself stale, without disturbing a
        /// newer chain that a later navigation may already have registered for the same WebView.
        @MainActor
        private func endCrewAccessProbe(for webView: WKWebView, sequence: UInt) {
            let key = ObjectIdentifier(webView)
            guard crewAccessProbeSequences[key] == sequence else { return }
            crewAccessProbeTasks.removeValue(forKey: key)?.cancel()
            crewAccessProbeSequences.removeValue(forKey: key)
        }

        /// Test introspection: whether any delayed probe work is still registered.
        @MainActor
        var hasPendingCrewAccessProbeWork: Bool {
            !crewAccessProbeTasks.isEmpty
        }

        @MainActor
        private func scheduleCrewAccessProbeResample(
            webView: WKWebView,
            completedURL: URL?,
            nextAttempt: Int,
            sequence: UInt
        ) {
            let intervalIndex = nextAttempt - 1
            guard intervalIndex >= 0,
                  intervalIndex < CrewAccessPageProbe.resampleIntervals.count else {
                endCrewAccessProbe(for: webView, sequence: sequence)
                return
            }
            let interval = CrewAccessPageProbe.resampleIntervals[intervalIndex]

            // Registered so teardown can cancel it. The task captures nothing strongly: it holds a
            // weak Coordinator and a weak WebView, and exits the moment either has gone.
            let key = ObjectIdentifier(webView)
            crewAccessProbeTasks.removeValue(forKey: key)?.cancel()
            crewAccessProbeTasks[key] = Task { @MainActor [weak self, weak webView] in
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, let self, let webView else { return }
                guard self.crewAccessProbeSequences[ObjectIdentifier(webView)] == sequence,
                      self.activePopupTeardownGeneration == nil,
                      self.ownsCrewAccessProbeTarget(webView),
                      webView.url == completedURL else {
                    self.endCrewAccessProbe(for: webView, sequence: sequence)
                    return
                }

                webView.evaluateJavaScript(Self.pageInspectionScript()) { [weak self, weak webView] result, _ in
                    let probe = (result as? [String: Any])?["probe"] as? [String: Any]
                    DispatchQueue.main.async { [weak self, weak webView] in
                        guard let self, let webView else { return }
                        guard self.crewAccessProbeSequences[ObjectIdentifier(webView)] == sequence,
                              self.activePopupTeardownGeneration == nil,
                              self.ownsCrewAccessProbeTarget(webView) else {
                            self.endCrewAccessProbe(for: webView, sequence: sequence)
                            return
                        }
                        self.logCrewAccessProbeSample(
                            probe,
                            webView: webView,
                            completedURL: completedURL,
                            attempt: nextAttempt,
                            sequence: sequence
                        )
                        self.scheduleCrewAccessProbeResample(
                            webView: webView,
                            completedURL: completedURL,
                            nextAttempt: nextAttempt + 1,
                            sequence: sequence
                        )
                    }
                }
            }
        }

        /// Every value logged here was redacted inside `CrewAccessPageProbe.probeExpression`
        /// before it crossed the JavaScript boundary, so `.public` is safe and the log is readable
        /// on device without an OS logging profile.
        @MainActor
        private func logCrewAccessProbeSample(
            _ probe: [String: Any]?,
            webView: WKWebView,
            completedURL: URL?,
            attempt: Int,
            sequence: UInt
        ) {
            let isPopup = popupWebViews.contains(where: { $0 === webView })
            let surface = isPopup ? "popup" : "main"
            let isVisibleSurface = isPopup
                ? viewModel.popupWebView === webView
                : viewModel.popupWebView == nil
            let kind = CrewAccessPageProbe.pageKind(for: completedURL)
            let shape = CrewAccessPageProbe.urlShape(for: completedURL)
            let didFinishCount = crewAccessProbeDidFinishCounts[shape] ?? 0
            let header = "[AutoPrintProbe] seq=\(sequence) attempt=\(attempt) surface=\(surface)"

            guard let probe else {
                browserProbeLogger.info(
                    "\(header, privacy: .public) kind=\(kind.rawValue, privacy: .public) url=\(shape, privacy: .public) result=no-probe-payload"
                )
                return
            }
            if let message = probe["error"] as? String {
                browserProbeLogger.error(
                    "\(header, privacy: .public) kind=\(kind.rawValue, privacy: .public) url=\(shape, privacy: .public) result=probe-error error=\(message, privacy: .public)"
                )
                return
            }

            let summary = [
                "kind=\(kind.rawValue)",
                "visible=\(isVisibleSurface)",
                "didFinishCount=\(didFinishCount)",
                "url=\(shape)",
                "readyState=\(probeString(probe, "readyState"))",
                "title=\(probeString(probe, "title"))",
                "docOrigin=\(probeString(probe, "documentOrigin"))",
                "inFrame=\(probeBool(probe, "isInFrame"))",
                "topSameOrigin=\(probeBool(probe, "isTopSameOrigin"))",
                "frameCount=\(probeInt(probe, "frameCount"))",
                "shadowRoots=\(probeInt(probe, "shadowRootCount"))",
                "scanned=\(probeInt(probe, "scannedElementCount"))",
                "bodyChars=\(probeInt(probe, "bodyCharacterCount"))",
                "tables=\(probeInt(probe, "tableCount"))",
                "rows=\(probeInt(probe, "nonEmptyRowCount"))",
                "legRows=\(probeInt(probe, "legAnchorRowCount"))",
                "tripIdLine=\(probeBool(probe, "hasTripIdLine"))",
                "tripInformation=\(probeBool(probe, "hasTripInformationHeading"))",
                "roster=\(probeBool(probe, "hasRosterMarker"))",
                "unableToLoadReport=\(probeBool(probe, "unableToLoadReport"))",
                "busy=\(probeInt(probe, "busyIndicatorCount"))",
                "printElements=\(probeInt(probe, "printElementCount"))",
                "interactiveElements=\(probeInt(probe, "interactiveElementCount"))",
                "vendorMarkers=\(probeInt(probe, "vendorMarkerCount"))",
                "vendorSamples=\((probe["vendorMarkerSamples"] as? [String] ?? []).joined(separator: " | "))",
                "scriptOrigins=\((probe["scriptOrigins"] as? [String] ?? []).joined(separator: ","))",
                "styleOrigins=\((probe["styleOrigins"] as? [String] ?? []).joined(separator: ","))"
            ].joined(separator: " ")
            browserProbeLogger.info("\(header, privacy: .public) \(summary, privacy: .public)")

            for (index, frame) in (probe["frames"] as? [[String: Any]] ?? []).enumerated() {
                browserProbeLogger.info(
                    "\(header, privacy: .public) frame[\(index, privacy: .public)] origin=\(self.probeString(frame, "srcOrigin"), privacy: .public) src=\(self.probeString(frame, "srcShape"), privacy: .public) id=\(self.probeString(frame, "id"), privacy: .public) class=\(self.probeString(frame, "className"), privacy: .public) sameOriginAccessible=\(self.probeBool(frame, "isSameOriginAccessible"), privacy: .public) innerReadyState=\(self.probeString(frame, "innerReadyState"), privacy: .public) innerPrintElements=\(self.probeInt(frame, "innerPrintElementCount"), privacy: .public)"
                )
            }

            for (index, element) in (probe["printElements"] as? [[String: Any]] ?? []).enumerated() {
                browserProbeLogger.info(
                    "\(header, privacy: .public) printElement[\(index, privacy: .public)] \(self.describeProbeElement(element), privacy: .public)"
                )
            }

            for (index, element) in (probe["interactiveElements"] as? [[String: Any]] ?? []).enumerated() {
                browserProbeLogger.info(
                    "\(header, privacy: .public) interactiveElement[\(index, privacy: .public)] \(self.describeProbeElement(element), privacy: .public)"
                )
            }
        }

        private func describeProbeElement(_ element: [String: Any]) -> String {
            let rect = (element["rect"] as? [Any] ?? [])
                .map { String((($0 as? NSNumber)?.intValue ?? 0)) }
                .joined(separator: ",")
            return [
                "root=\(probeString(element, "root"))",
                "tag=\(probeString(element, "tagName"))",
                "type=\(probeString(element, "type"))",
                "id=\(probeString(element, "id"))",
                "class=\(probeString(element, "className"))",
                "role=\(probeString(element, "role"))",
                "label=\(probeString(element, "label"))",
                "value=\(probeString(element, "value"))",
                "ariaLabel=\(probeString(element, "ariaLabel"))",
                "title=\(probeString(element, "title"))",
                "href=\(probeString(element, "href"))",
                "target=\(probeString(element, "target"))",
                "hasOnclickAttribute=\(probeBool(element, "hasOnclickAttribute"))",
                "onclickAttribute=\(probeString(element, "onclickAttribute"))",
                "hasOnclickProperty=\(probeBool(element, "hasOnclickProperty"))",
                "formAction=\(probeString(element, "formAction"))",
                "formMethod=\(probeString(element, "formMethod"))",
                "disabled=\(probeBool(element, "isDisabled"))",
                "tabIndex=\(probeInt(element, "tabIndex"))",
                "visible=\(probeBool(element, "isVisible"))",
                "rect=[\(rect)]",
                "printMatch=\(probeString(element, "printMatch"))"
            ].joined(separator: " ")
        }

        private func probeString(_ values: [String: Any], _ key: String) -> String {
            values[key] as? String ?? ""
        }

        private func probeBool(_ values: [String: Any], _ key: String) -> Bool {
            values[key] as? Bool ?? false
        }

        private func probeInt(_ values: [String: Any], _ key: String) -> Int {
            (values[key] as? NSNumber)?.intValue ?? -1
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
            #if DEBUG
            // Teardown has begun: pending diagnostics for these popups are made inert immediately,
            // before any of the native cleanup below runs.
            for popup in popups {
                cancelCrewAccessProbe(for: popup)
            }
            #endif
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
                cancelCrewAccessProbe(for: popup)
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
