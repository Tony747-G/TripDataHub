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

/// Ships in Release. CrewAccess auto-print is a product feature, and when it fails on a real
/// device the only evidence available is this log, so it stays concise and diagnosis-oriented:
/// which gate rejected, which one-shot was spent, and what the two DOM invocations returned.
private let browserAutoPrintLogger = Logger(
    subsystem: "com.sfune.TripDataHub",
    category: "AutoPrint"
)

/// Read-only page snapshot used to determine whether a tracked Zscaler popup is eligible for
/// CrewAccess auto-print.
///
/// **Observational only.** This probe never clicks, focuses, submits a form, invokes a site
/// function, or dispatches a synthetic event. It reads a page that has already finished loading
/// and returns a redacted description to the guarded auto-print coordinator.
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
    /// The broader classification remains useful to page-inspection tests, while the production
    /// auto-print scheduler further restricts execution to an exact Zscaler session URL.
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
                            tagNameIsExactButton: element.tagName === 'BUTTON',
                            type: redact(attributeOf(element, 'type')),
                            typeIsExactButton: attributeOf(element, 'type') === 'button',
                            id: redact(element.id),
                            className: redact(typeof element.className === 'string' ? element.className : ''),
                            role: redact(attributeOf(element, 'role')),
                            label: redact(labelOf(element)),
                            value: redact(element.value),
                            ariaLabel: redact(attributeOf(element, 'aria-label')),
                            ariaLabelIsExactPrint: attributeOf(element, 'aria-label') === 'Print',
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
                        bodyHTMLCharacterCount: document.body ? document.body.innerHTML.length : 0,
                        scriptElementCount: document.scripts ? document.scripts.length : 0,
                        visibilityState: document.visibilityState || 'unknown',
                        hasDocumentFocus: document.hasFocus(),
                        windowNamePresent: Boolean(window.name),
                        canvasElementCount: document.querySelectorAll('canvas').length,
                        visibleCanvasElementCount: Array.from(document.querySelectorAll('canvas'))
                            .filter(canvas => isVisible(canvas)).length,
                        canvasCSSPixelArea: Array.from(document.querySelectorAll('canvas'))
                            .reduce((total, canvas) => {
                                const rect = canvas.getBoundingClientRect();
                                return total + Math.max(0, Math.round(rect.width || 0))
                                    * Math.max(0, Math.round(rect.height || 0));
                            }, 0),
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

/// Production, fail-closed execution path for the Zscaler Print control observed by
/// `CrewAccessPageProbe`.
enum CrewAccessAutoPrint {
    /// Same isolation session, allowing only an in-place query change.
    ///
    /// Full-URL equality was the wrong identity for Stage 2's staleness guard: the Zscaler
    /// isolation client evolves its own URL in place while the same Print dialog stays open, and a
    /// benign query mutation cancelled the whole observational schedule.
    ///
    /// Both sides must independently satisfy `isExactZscalerSessionURL` — which already pins
    /// https, no port/user/password, **no fragment**, an `*.isolation.zscaler.com` host and the
    /// exact `/profile/<UUID>/zpa-session` path — and must then agree on scheme, host and path.
    /// That is strictly narrower than the `url-mismatch` guard that follows it, so the only thing
    /// newly tolerated is a query difference within one identical session endpoint.
    static func isSameZscalerSession(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs,
              isExactZscalerSessionURL(lhs),
              isExactZscalerSessionURL(rhs)
        else { return false }

        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && lhs.path == rhs.path
    }

    /// Bounded settle time taken BEFORE Stage 1. Taking it before the toolbar Print button is
    /// invoked means the user watches Trip Details for the whole wait instead of the Print dialog.
    ///
    /// Five seconds is the accepted physical-device settle period. It remains fail closed: a
    /// document that does not present exactly one qualifying Print button is rejected with the
    /// Stage 1 one-shot unconsumed.
    static let stageOneSettleDelayNanoseconds: UInt64 = 5_000_000_000

    /// Stage 2 no longer waits a fixed six seconds. Once Stage 1 has physically opened the Print
    /// dialog, the only thing left to wait for is that dialog's DOM becoming structurally ready,
    /// so Stage 2 samples a small finite schedule of offsets measured from the confirmed Stage 1
    /// invocation. Bounded and finite: after the last offset the schedule is exhausted and the
    /// Stage 2 one-shot is left unconsumed.
    static let stageTwoReadinessOffsetsNanoseconds: [UInt64] = [
        100_000_000,
        250_000_000,
        500_000_000
    ]

    static func isExactZscalerSessionURL(_ url: URL?) -> Bool {
        guard let url,
              url.scheme?.lowercased() == "https",
              url.port == nil,
              url.user == nil,
              url.password == nil,
              url.fragment == nil,
              let host = url.host?.lowercased(),
              host == "isolation.zscaler.com" || host.hasSuffix(".isolation.zscaler.com")
        else { return false }

        let pathComponents = url.pathComponents.filter { $0 != "/" }
        guard pathComponents.count == 3,
              pathComponents[0] == "profile",
              UUID(uuidString: pathComponents[1]) != nil,
              pathComponents[2] == "zpa-session"
        else { return false }

        return true
    }

    static func qualifyingPrintButtonCount(in elements: [[String: Any]]) -> Int {
        elements.filter(isQualifyingPrintButton).count
    }

    static func rejectionReason(
        isTrackedPopup: Bool,
        isVisiblePopup: Bool,
        livePopupCount: Int,
        teardownInProgress: Bool,
        completedURL: URL?,
        currentURL: URL?,
        readyState: String,
        printElements: [[String: Any]],
        oneShotConsumed: Bool
    ) -> String? {
        guard isTrackedPopup else { return "not-tracked-popup" }
        guard isVisiblePopup else { return "not-visible-popup" }
        guard livePopupCount == 1 else { return "live-popup-count-\(livePopupCount)" }
        guard !teardownInProgress else { return "teardown-in-progress" }
        guard completedURL == currentURL else { return "stale-probe" }
        guard isExactZscalerSessionURL(currentURL) else { return "url-mismatch" }
        guard !oneShotConsumed else { return "one-shot-already-consumed" }
        guard readyState == "complete" else { return "document-not-complete" }

        let count = qualifyingPrintButtonCount(in: printElements)
        guard count == 1 else { return "qualifying-print-button-count-\(count)" }
        return nil
    }

    /// Stage 1's gate *after* the pre-Stage-1 settle delay has elapsed.
    ///
    /// Identical to `rejectionReason` in every safety guard except the staleness rule. The probe
    /// snapshot that started the delay is five seconds old by the time this runs, and the Zscaler
    /// isolation client evolves its own URL in place while the same Trip Details document stays
    /// open — so `completedURL == currentURL` reported `stale-probe` on every settled run and
    /// nothing could ever invoke. The delay is therefore tied to the tracked popup and its session
    /// identity, never to the probe result remaining current.
    ///
    /// `isSameZscalerSession` is strictly narrower than the `url-mismatch` guard that precedes it:
    /// both sides must independently satisfy `isExactZscalerSessionURL` — https, no port, user,
    /// password or fragment, an `*.isolation.zscaler.com` host and the exact
    /// `/profile/<UUID>/zpa-session` path — and must then agree on scheme, host and path. The only
    /// thing newly tolerated is a query difference within one identical session endpoint.
    ///
    /// `isSamePopupGeneration` closes the one hole an `ObjectIdentifier` alone leaves: an address
    /// recycled by a later popup allocation. Everything else — visibility, singleton liveness,
    /// teardown, document readiness and the exact qualifying Print button — is re-evaluated
    /// against freshly read state, not against the snapshot that started the wait.
    static func settledRejectionReason(
        isTrackedPopup: Bool,
        isVisiblePopup: Bool,
        livePopupCount: Int,
        teardownInProgress: Bool,
        isSamePopupGeneration: Bool,
        settleSessionURL: URL?,
        currentURL: URL?,
        readyState: String,
        printElements: [[String: Any]],
        oneShotConsumed: Bool
    ) -> String? {
        guard isTrackedPopup else { return "not-tracked-popup" }
        guard isVisiblePopup else { return "not-visible-popup" }
        guard livePopupCount == 1 else { return "live-popup-count-\(livePopupCount)" }
        guard !teardownInProgress else { return "teardown-in-progress" }
        guard isSamePopupGeneration else { return "popup-generation-changed" }
        // Order matters. "current URL is not a session URL at all" is more specific than
        // "current URL is a different session", so it is reported first and stays reachable.
        guard isExactZscalerSessionURL(currentURL) else { return "url-mismatch" }
        guard isSameZscalerSession(settleSessionURL, currentURL) else { return "session-changed" }
        guard !oneShotConsumed else { return "one-shot-already-consumed" }
        guard readyState == "complete" else { return "document-not-complete" }

        let count = qualifyingPrintButtonCount(in: printElements)
        guard count == 1 else { return "qualifying-print-button-count-\(count)" }
        return nil
    }

    /// Stage 2 Phase A: read-only structural readiness.
    ///
    /// The dialog Stage 1 opens does not exist yet at the moment Stage 1 runs, so `dialogCount=0`
    /// is a *not-ready* state, not a failed invocation. This script only reads: it never clicks and
    /// never mutates the page, so it is safe to run at the bounded readiness offsets and it must
    /// never consume the Stage 2 one-shot.
    ///
    /// This script reports structural readiness and bounded diagnostics. Swift uses only the exact
    /// dialog/button counts at the bounded 100/250/500ms offsets. DOM stability, mutation state,
    /// and canvas fingerprints are not readiness criteria.
    static let stageTwoReadinessScript = #"""
    (() => {
        try {
            const MAXIMUM_DESCRIBED_BUTTONS = 8;
            const normalize = value => String(value === null || value === undefined ? '' : value)
                .replace(/\s+/g, ' ')
                .replace(/\d{4,}/g, '<n>')
                .trim()
                .slice(0, 60);
            const isExactURL = () => {
                try {
                    const value = new URL(location.href);
                    const host = value.hostname.toLowerCase();
                    const hostMatches = host === 'isolation.zscaler.com'
                        || host.endsWith('.isolation.zscaler.com');
                    const pathMatches = /^\/profile\/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\/zpa-session\/?$/.test(value.pathname);
                    return value.protocol === 'https:'
                        && value.port === ''
                        && value.username === ''
                        && value.password === ''
                        && value.hash === ''
                        && hostMatches
                        && pathMatches;
                } catch (error) {
                    return false;
                }
            };
            const styleOf = node => {
                try {
                    return window.getComputedStyle ? window.getComputedStyle(node) : null;
                } catch (error) {
                    return null;
                }
            };
            const positiveRectOf = node => {
                const rects = node.getClientRects ? node.getClientRects() : [];
                return Array.prototype.slice.call(rects)
                    .find(rect => rect.width > 0 && rect.height > 0) || null;
            };
            const isVisible = node => {
                if (!positiveRectOf(node)) return false;
                if (node.hidden) return false;
                const style = styleOf(node);
                if (!style) return false;
                return style.display !== 'none'
                    && style.visibility !== 'hidden'
                    && style.visibility !== 'collapse'
                    && Number(style.opacity || '1') > 0.01;
            };
            const acceptsPointerEvents = node => {
                const style = styleOf(node);
                return Boolean(style) && style.pointerEvents !== 'none';
            };
            const isEnabled = node => !node.disabled
                && normalize(node.getAttribute ? node.getAttribute('aria-disabled') : null).toLowerCase() !== 'true';
            const describe = button => {
                const style = styleOf(button);
                const rect = positiveRectOf(button) || { width: 0, height: 0 };
                return {
                    normalizedText: normalize(button.textContent),
                    ariaLabel: normalize(button.getAttribute('aria-label')),
                    title: normalize(button.getAttribute('title')),
                    disabled: Boolean(button.disabled),
                    rawAriaDisabled: normalize(button.getAttribute('aria-disabled')),
                    clientRectWidth: Number(rect.width || 0),
                    clientRectHeight: Number(rect.height || 0),
                    computedDisplay: style ? style.display : '<unavailable>',
                    computedVisibility: style ? style.visibility : '<unavailable>',
                    computedOpacity: style ? style.opacity : '<unavailable>',
                    computedPointerEvents: style ? style.pointerEvents : '<unavailable>'
                };
            };
            const notReady = (reason, diagnostic, buttonReady = false) => ({
                ready: false,
                buttonReady: buttonReady,
                reason: reason,
                diagnostic: diagnostic || {
                    dialogCount: 0,
                    qualifyingDialogCount: 0,
                    submitButtonCount: 0,
                    visibleSubmitButtonCount: 0,
                    qualifyingSubmitButtonCount: 0,
                    submitButtons: []
                }
            });

            if (!isExactURL()) {
                return notReady('url-mismatch');
            }
            if (document.readyState !== 'complete') {
                return notReady('document-not-complete');
            }

            const allDialogs = Array.prototype.slice.call(
                document.querySelectorAll('[role="dialog"]')
            );
            const dialogs = allDialogs.filter(
                dialog => isVisible(dialog) && acceptsPointerEvents(dialog)
            );
            if (dialogs.length !== 1) {
                return notReady('qualifying-dialog-count', {
                    dialogCount: allDialogs.length,
                    qualifyingDialogCount: dialogs.length,
                    submitButtonCount: 0,
                    visibleSubmitButtonCount: 0,
                    qualifyingSubmitButtonCount: 0,
                    submitButtons: []
                });
            }

            const dialog = dialogs[0];
            const allSubmitButtons = Array.prototype.slice
                .call(dialog.querySelectorAll('button'))
                .filter(button => button.tagName === 'BUTTON'
                    && button.getAttribute('type') === 'submit');
            const visibleSubmitButtons = allSubmitButtons.filter(isVisible);
            const qualifyingSubmitButtons = visibleSubmitButtons.filter(
                button => isEnabled(button) && acceptsPointerEvents(button)
            );
            const diagnostic = {
                dialogCount: allDialogs.length,
                qualifyingDialogCount: dialogs.length,
                submitButtonCount: allSubmitButtons.length,
                visibleSubmitButtonCount: visibleSubmitButtons.length,
                qualifyingSubmitButtonCount: qualifyingSubmitButtons.length,
                submitButtons: visibleSubmitButtons
                    .slice(0, MAXIMUM_DESCRIBED_BUTTONS)
                    .map(describe)
            };

            if (qualifyingSubmitButtons.length !== 1) {
                return notReady('qualifying-submit-button-count', diagnostic);
            }
            return notReady('report-readiness-unproven', diagnostic, true);
        } catch (error) {
            return {
                ready: false,
                reason: 'readiness-error',
                error: String(error).slice(0, 160),
                diagnostic: {
                    dialogCount: -1,
                    qualifyingDialogCount: -1,
                    submitButtonCount: -1,
                    visibleSubmitButtonCount: -1,
                    qualifyingSubmitButtonCount: -1,
                    submitButtons: []
                }
            };
        }
    })()
    """#

    /// Production Stage 2: the submit control inside the Zscaler Print dialog that Stage 1 opens.
    ///
    /// Physical-device evidence showed the real gesture landing on a `span` inside a
    /// `button[type="submit"]` within a `div[role="dialog"]`, with
    /// `pathContainsVisiblePrintButton=false` — so this is a different control from the toolbar
    /// button Stage 1 drives, and it is resolved structurally rather than by text, because the
    /// observed metadata carried no reliable label.
    ///
    /// Fail-closed: exactly one visible, pointer-accepting document dialog, and inside it exactly
    /// one visible, enabled, pointer-accepting `button` with a raw `type="submit"`. The diagnostic
    /// for every visible submit button is computed before any invocation and is returned on both
    /// the accepted and the rejected path.
    static let stageTwoInvocationScript = #"""
    (() => {
        try {
            const MAXIMUM_DESCRIBED_BUTTONS = 8;
            const normalize = value => String(value === null || value === undefined ? '' : value)
                .replace(/\s+/g, ' ')
                .replace(/\d{4,}/g, '<n>')
                .trim()
                .slice(0, 60);
            const isExactURL = () => {
                try {
                    const value = new URL(location.href);
                    const host = value.hostname.toLowerCase();
                    const hostMatches = host === 'isolation.zscaler.com'
                        || host.endsWith('.isolation.zscaler.com');
                    const pathMatches = /^\/profile\/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\/zpa-session\/?$/.test(value.pathname);
                    return value.protocol === 'https:'
                        && value.port === ''
                        && value.username === ''
                        && value.password === ''
                        && value.hash === ''
                        && hostMatches
                        && pathMatches;
                } catch (error) {
                    return false;
                }
            };
            const styleOf = node => {
                try {
                    return window.getComputedStyle ? window.getComputedStyle(node) : null;
                } catch (error) {
                    return null;
                }
            };
            const positiveRectOf = node => {
                const rects = node.getClientRects ? node.getClientRects() : [];
                return Array.prototype.slice.call(rects)
                    .find(rect => rect.width > 0 && rect.height > 0) || null;
            };
            const isVisible = node => {
                if (!positiveRectOf(node)) return false;
                if (node.hidden) return false;
                const style = styleOf(node);
                if (!style) return false;
                return style.display !== 'none'
                    && style.visibility !== 'hidden'
                    && style.visibility !== 'collapse'
                    && Number(style.opacity || '1') > 0.01;
            };
            const acceptsPointerEvents = node => {
                const style = styleOf(node);
                return Boolean(style) && style.pointerEvents !== 'none';
            };
            const isEnabled = node => !node.disabled
                && normalize(node.getAttribute ? node.getAttribute('aria-disabled') : null).toLowerCase() !== 'true';
            const describe = button => {
                const style = styleOf(button);
                const rect = positiveRectOf(button) || { width: 0, height: 0 };
                return {
                    normalizedText: normalize(button.textContent),
                    ariaLabel: normalize(button.getAttribute('aria-label')),
                    title: normalize(button.getAttribute('title')),
                    disabled: Boolean(button.disabled),
                    rawAriaDisabled: normalize(button.getAttribute('aria-disabled')),
                    clientRectWidth: Number(rect.width || 0),
                    clientRectHeight: Number(rect.height || 0),
                    computedDisplay: style ? style.display : '<unavailable>',
                    computedVisibility: style ? style.visibility : '<unavailable>',
                    computedOpacity: style ? style.opacity : '<unavailable>',
                    computedPointerEvents: style ? style.pointerEvents : '<unavailable>'
                };
            };

            if (!isExactURL()) {
                return { result: 'rejected', reason: 'url-mismatch' };
            }
            if (document.readyState !== 'complete') {
                return { result: 'rejected', reason: 'document-not-complete' };
            }

            const allDialogs = Array.prototype.slice.call(
                document.querySelectorAll('[role="dialog"]')
            );
            const dialogs = allDialogs.filter(
                dialog => isVisible(dialog) && acceptsPointerEvents(dialog)
            );
            if (dialogs.length !== 1) {
                return {
                    result: 'rejected',
                    reason: 'qualifying-dialog-count',
                    count: dialogs.length,
                    diagnostic: {
                        dialogCount: allDialogs.length,
                        qualifyingDialogCount: dialogs.length,
                        submitButtonCount: 0,
                        visibleSubmitButtonCount: 0,
                        submitButtons: []
                    }
                };
            }

            const dialog = dialogs[0];
            const allSubmitButtons = Array.prototype.slice
                .call(dialog.querySelectorAll('button'))
                .filter(button => button.tagName === 'BUTTON'
                    && button.getAttribute('type') === 'submit');
            const visibleSubmitButtons = allSubmitButtons.filter(isVisible);
            const diagnostic = {
                dialogCount: allDialogs.length,
                qualifyingDialogCount: dialogs.length,
                submitButtonCount: allSubmitButtons.length,
                visibleSubmitButtonCount: visibleSubmitButtons.length,
                submitButtons: visibleSubmitButtons
                    .slice(0, MAXIMUM_DESCRIBED_BUTTONS)
                    .map(describe)
            };

            const submitButtons = visibleSubmitButtons.filter(
                button => isEnabled(button) && acceptsPointerEvents(button)
            );
            if (submitButtons.length !== 1) {
                return {
                    result: 'rejected',
                    reason: 'qualifying-submit-button-count',
                    count: submitButtons.length,
                    diagnostic: diagnostic
                };
            }

            submitButtons[0].click();
            return {
                result: 'invoked',
                reason: 'none',
                count: 1,
                diagnostic: diagnostic
            };
        } catch (error) {
            return {
                result: 'rejected',
                reason: 'stage-two-error',
                error: String(error).slice(0, 160)
            };
        }
    })()
    """#

    /// Popup-level gate for Stage 2, mirroring `rejectionReason` and adding the ordering rule:
    /// Stage 2 may only follow a Stage 1 attempt on the same popup.
    static func stageTwoRejectionReason(
        isTrackedPopup: Bool,
        isVisiblePopup: Bool,
        livePopupCount: Int,
        teardownInProgress: Bool,
        completedURL: URL?,
        currentURL: URL?,
        readyState: String,
        stageOneAttempted: Bool,
        oneShotConsumed: Bool
    ) -> String? {
        guard isTrackedPopup else { return "not-tracked-popup" }
        guard isVisiblePopup else { return "not-visible-popup" }
        guard livePopupCount == 1 else { return "live-popup-count-\(livePopupCount)" }
        guard !teardownInProgress else { return "teardown-in-progress" }
        // Order matters. "current URL is not a session URL at all" is more specific than
        // "current URL is a different session", so it is reported first and stays reachable.
        guard isExactZscalerSessionURL(currentURL) else { return "url-mismatch" }
        guard isSameZscalerSession(completedURL, currentURL) else { return "stale-probe" }
        guard stageOneAttempted else { return "stage-one-not-attempted" }
        guard !oneShotConsumed else { return "one-shot-already-consumed" }
        guard readyState == "complete" else { return "document-not-complete" }
        return nil
    }

    static let invocationScript = #"""
    (() => {
        const normalize = value => String(value === null || value === undefined ? '' : value)
            .replace(/\s+/g, ' ')
            .trim();
        const isExactURL = () => {
            try {
                const value = new URL(location.href);
                const host = value.hostname.toLowerCase();
                const hostMatches = host === 'isolation.zscaler.com'
                    || host.endsWith('.isolation.zscaler.com');
                const pathMatches = /^\/profile\/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\/zpa-session\/?$/.test(value.pathname);
                return value.protocol === 'https:'
                    && value.port === ''
                    && value.username === ''
                    && value.password === ''
                    && value.hash === ''
                    && hostMatches
                    && pathMatches;
            } catch (error) {
                return false;
            }
        };
        const isVisibleAndEnabled = button => {
            const rects = Array.from(button.getClientRects ? button.getClientRects() : []);
            const hasPositiveRect = rects.some(rect => rect.width > 0 && rect.height > 0);
            const style = window.getComputedStyle(button);
            const opacity = Number(style.opacity || '1');
            return hasPositiveRect
                && !button.hidden
                && !button.disabled
                && normalize(button.getAttribute('aria-disabled')).toLowerCase() !== 'true'
                && style.display !== 'none'
                && style.visibility !== 'hidden'
                && style.visibility !== 'collapse'
                && opacity > 0.01;
        };

        if (!isExactURL()) {
            return { result: 'rejected', reason: 'url-mismatch' };
        }
        if (document.readyState !== 'complete') {
            return { result: 'rejected', reason: 'document-not-complete' };
        }

        const allButtons = Array.from(document.querySelectorAll('button'));
        const candidates = allButtons.filter(button =>
            button.tagName === 'BUTTON'
                && button.getAttribute('type') === 'button'
                && button.getAttribute('aria-label') === 'Print'
                && isVisibleAndEnabled(button)
        );
        if (candidates.length === 0) {
            const inspectButton = button => {
                const typeAttribute = button.getAttribute('type');
                const ariaLabel = button.getAttribute('aria-label');
                const ariaDisabled = button.getAttribute('aria-disabled');
                const rects = Array.from(button.getClientRects ? button.getClientRects() : []);
                const positiveRect = rects.find(rect => rect.width > 0 && rect.height > 0);
                const reportedRect = positiveRect || rects[0] || { width: 0, height: 0 };
                const style = window.getComputedStyle(button);
                const opacityNumber = Number(style.opacity || '1');
                const predicates = [
                    ['tagNameExactButton', button.tagName === 'BUTTON'],
                    ['typeAttributeExactButton', typeAttribute === 'button'],
                    ['ariaLabelExactPrint', ariaLabel === 'Print'],
                    ['positiveClientRect', Boolean(positiveRect)],
                    ['notHidden', !button.hidden],
                    ['notDisabled', !button.disabled],
                    ['ariaDisabledNotTrue', normalize(ariaDisabled).toLowerCase() !== 'true'],
                    ['displayNotNone', style.display !== 'none'],
                    ['visibilityNotHidden', style.visibility !== 'hidden'],
                    ['visibilityNotCollapse', style.visibility !== 'collapse'],
                    ['opacityGreaterThanPointZeroOne', opacityNumber > 0.01]
                ];

                return {
                    rawTagName: button.tagName,
                    rawTypeAttribute: typeAttribute,
                    rawAriaLabel: ariaLabel,
                    disabled: Boolean(button.disabled),
                    rawAriaDisabled: ariaDisabled,
                    hidden: Boolean(button.hidden),
                    clientRectWidth: Number(reportedRect.width || 0),
                    clientRectHeight: Number(reportedRect.height || 0),
                    computedDisplay: style.display,
                    computedVisibility: style.visibility,
                    computedOpacity: style.opacity,
                    computedPointerEvents: style.pointerEvents,
                    normalizedTextIsPrint: normalize(button.innerText) === 'Print'
                        || normalize(button.textContent) === 'Print',
                    normalizedAriaLabelIsPrint: normalize(ariaLabel) === 'Print',
                    rejectedPredicates: predicates
                        .filter(predicate => !predicate[1])
                        .map(predicate => predicate[0])
                };
            };
            const buttonStates = allButtons.map(inspectButton);
            let survivors = buttonStates;
            const retain = predicate => {
                survivors = survivors.filter(predicate);
                return survivors.length;
            };
            const survivingCounts = {
                afterTagNameExactButton: retain(state => state.rawTagName === 'BUTTON'),
                afterTypeAttributeExactButton: retain(state => state.rawTypeAttribute === 'button'),
                afterAriaLabelExactPrint: retain(state => state.rawAriaLabel === 'Print'),
                afterPositiveClientRect: retain(state => state.clientRectWidth > 0 && state.clientRectHeight > 0),
                afterNotHidden: retain(state => !state.hidden),
                afterNotDisabled: retain(state => !state.disabled),
                afterAriaDisabledNotTrue: retain(
                    state => normalize(state.rawAriaDisabled).toLowerCase() !== 'true'
                ),
                afterDisplayNotNone: retain(state => state.computedDisplay !== 'none'),
                afterVisibilityNotHidden: retain(state => state.computedVisibility !== 'hidden'),
                afterVisibilityNotCollapse: retain(state => state.computedVisibility !== 'collapse'),
                afterOpacityGreaterThanPointZeroOne: retain(
                    state => Number(state.computedOpacity || '1') > 0.01
                )
            };
            const printLikeButtons = buttonStates.filter(state =>
                state.normalizedTextIsPrint || state.normalizedAriaLabelIsPrint
            );

            return {
                result: 'rejected',
                reason: 'qualifying-print-button-count',
                count: 0,
                diagnostic: {
                    totalDocumentButtonCount: allButtons.length,
                    exactPrintAriaLabelCount: allButtons.filter(
                        button => button.getAttribute('aria-label') === 'Print'
                    ).length,
                    survivingCounts: survivingCounts,
                    printLikeButtons: printLikeButtons
                }
            };
        }
        if (candidates.length !== 1) {
            return {
                result: 'rejected',
                reason: 'qualifying-print-button-count',
                count: candidates.length
            };
        }

        const computedPointerEvents = window.getComputedStyle(candidates[0]).pointerEvents;
        candidates[0].click();
        return {
            result: 'invoked',
            reason: 'none',
            count: 1,
            computedPointerEvents: computedPointerEvents
        };
    })()
    """#

    private static func isQualifyingPrintButton(_ element: [String: Any]) -> Bool {
        guard element["root"] as? String == "document",
              element["tagName"] as? String == "button",
              element["tagNameIsExactButton"] as? Bool == true,
              element["type"] as? String == "button",
              element["typeIsExactButton"] as? Bool == true,
              element["ariaLabel"] as? String == "Print",
              element["ariaLabelIsExactPrint"] as? Bool == true,
              element["printMatch"] as? String == "exact",
              element["isVisible"] as? Bool == true,
              element["isDisabled"] as? Bool == false,
              let rect = element["rect"] as? [Any],
              rect.count == 4,
              (rect[2] as? NSNumber)?.doubleValue ?? 0 > 0,
              (rect[3] as? NSNumber)?.doubleValue ?? 0 > 0
        else { return false }

        return true
    }
}

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
        /// The four auto-print JavaScript seams. They ship: the feature ships, and each stage's
        /// read and invocation must stay independently stubbable so a test can drive one without
        /// the other.
        typealias AutoPrintStageOneReadinessEvaluator = @MainActor (
            WKWebView,
            String,
            @escaping @MainActor (Any?, Error?) -> Void
        ) -> Void
        typealias AutoPrintStageOneJavaScriptEvaluator = @MainActor (
            WKWebView,
            String,
            @escaping @MainActor (Any?, Error?) -> Void
        ) -> Void
        typealias AutoPrintStageTwoReadinessEvaluator = @MainActor (
            WKWebView,
            String,
            @escaping @MainActor (Any?, Error?) -> Void
        ) -> Void
        typealias AutoPrintStageTwoJavaScriptEvaluator = @MainActor (
            WKWebView,
            String,
            @escaping @MainActor (Any?, Error?) -> Void
        ) -> Void

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

        /// Popup identity that survives the Stage 1 settle delay. An `ObjectIdentifier` alone can
        /// be recycled by a later allocation at the same address; a monotonic generation assigned
        /// at popup creation and dropped at teardown cannot.
        private var nextPopupGeneration: UInt = 0
        private var popupGenerations: [ObjectIdentifier: UInt] = [:]
        /// Bounded eligibility sampling for the tracked Zscaler session popup. The Trip Details
        /// document keeps changing after `didFinish`, so one read cannot answer whether the
        /// toolbar Print control is present yet; the schedule is finite and is abandoned as soon
        /// as the navigation is superseded or the popup is torn down.
        private var crewAccessProbeSequences: [ObjectIdentifier: UInt] = [:]
        private var nextCrewAccessProbeSequence: UInt = 0
        /// Pending delayed sampling work, keyed by `ObjectIdentifier` so the registry itself never
        /// retains a WebView. The Coordinator owns these tasks; every task body captures the
        /// Coordinator and the WebView weakly, so the ownership only ever points this way.
        private var crewAccessProbeTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
        /// Optimistically consumed immediately before JavaScript evaluation. A failed invocation is
        /// deliberately never retried for the same popup identity.
        var autoPrintStageOneAttemptedPopupIDs: Set<ObjectIdentifier> = []
        /// Stage 2 keeps its own one-shot. Stage 1's is never reused, so neither stage can consume
        /// or unblock the other.
        var autoPrintStageTwoAttemptedPopupIDs: Set<ObjectIdentifier> = []
        /// Stage 1's settle delay runs BEFORE the toolbar Print button is invoked. Each popup has
        /// at most one cancellable sleeping task, keyed without retaining the WebView, and the
        /// Stage 1 one-shot stays available for the whole wait.
        private var autoPrintStageOneSettleTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
        private var autoPrintStageOneSettleSequences: [ObjectIdentifier: UInt] = [:]
        private var nextAutoPrintStageOneSettleSequence: UInt = 0
        /// Mutable only as a test seam; production runs use the single bounded delay declared on
        /// `CrewAccessAutoPrint`.
        var autoPrintStageOneSettleDelayNanoseconds =
            CrewAccessAutoPrint.stageOneSettleDelayNanoseconds
        /// Stage 2 readiness is deliberately independent of the older page-probe schedule. Each
        /// popup has at most one cancellable sleeping task, keyed without retaining the WebView.
        private var autoPrintStageTwoReadinessTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
        private var autoPrintStageTwoReadinessSequences: [ObjectIdentifier: UInt] = [:]
        private var nextAutoPrintStageTwoReadinessSequence: UInt = 0
        /// Mutable only as a test seam; production runs use the bounded offsets declared on
        /// `CrewAccessAutoPrint`.
        var autoPrintStageTwoReadinessOffsetsNanoseconds =
            CrewAccessAutoPrint.stageTwoReadinessOffsetsNanoseconds
        /// Correlates the log lines of a single auto-print run. Monotonic, never reused.
        private var nextAutoPrintRunID: UInt = 0
        var autoPrintStageOneJavaScriptEvaluator: AutoPrintStageOneJavaScriptEvaluator = {
            webView, script, completion in
            webView.evaluateJavaScript(script) { result, error in
                DispatchQueue.main.async {
                    completion(result, error)
                }
            }
        }
        var autoPrintStageTwoJavaScriptEvaluator: AutoPrintStageTwoJavaScriptEvaluator = {
            webView, script, completion in
            webView.evaluateJavaScript(script) { result, error in
                DispatchQueue.main.async {
                    completion(result, error)
                }
            }
        }
        /// Phase A runs on its own seam so a test can drive readiness and invocation independently.
        var autoPrintStageTwoReadinessEvaluator: AutoPrintStageTwoReadinessEvaluator = {
            webView, script, completion in
            webView.evaluateJavaScript(script) { result, error in
                DispatchQueue.main.async {
                    completion(result, error)
                }
            }
        }
        /// Stage 1 re-reads the document once, after its settle delay has elapsed, so the gates
        /// decide on the page as it is at invocation time rather than as it was five seconds
        /// earlier. Read-only: this seam only ever runs `CrewAccessPageProbe.probeExpression`.
        var autoPrintStageOneReadinessEvaluator: AutoPrintStageOneReadinessEvaluator = {
            webView, script, completion in
            webView.evaluateJavaScript(script) { result, error in
                DispatchQueue.main.async {
                    completion(result, error)
                }
            }
        }
        /// Test seam only. `WKWebView.url` cannot be set from a test, and Stage 2's guards are
        /// meaningless without it. Stage 1 deliberately does not share this seam.
        var autoPrintStageTwoCurrentURLProvider: @MainActor (WKWebView) -> URL? = { $0.url }


        private struct PopupFocusAcquisitionState {
            var hasCompletedNavigation = false
            var isResolved = false
        }

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
        }

        deinit {
            crewAccessProbeTasks.values.forEach { $0.cancel() }
            autoPrintStageOneSettleTasks.values.forEach { $0.cancel() }
            autoPrintStageTwoReadinessTasks.values.forEach { $0.cancel() }
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
            // Ships: the Stage 1 settle delay re-resolves its popup by identity after five
            // seconds, and a bare ObjectIdentifier can be recycled by a later allocation at the
            // same address. The generation is what makes that re-resolution sound.
            nextPopupGeneration &+= 1
            popupGenerations[ObjectIdentifier(popup)] = nextPopupGeneration

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

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            let isPopup = popupWebViews.contains(webView)
            DispatchQueue.main.async {
                if !isPopup {
                    self.viewModel.isLoading = true
                }
                self.viewModel.statusMessage = BrowserStatusText.loading
            }
        }


        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let isPopup = popupWebViews.contains(webView)
            let completedURL = webView.url
            if isPopup {
                recordPopupNavigationCompleted(webView)
            }
            DispatchQueue.main.async {
                if !isPopup {
                    self.viewModel.isLoading = false
                    self.viewModel.currentURL = completedURL?.absoluteString ?? ""
                }
            }
            inspectCompletedPage(webView, completedURL: completedURL)
            beginCrewAccessAutoPrintSamplingIfNeeded(webView, completedURL: completedURL)
        }

        /// The single production entry point into auto-print. Only a tracked popup sitting on an
        /// exact Zscaler session URL is ever read: every other surface returns here immediately,
        /// so no other page in the app pays for this feature.
        ///
        /// The eligibility read is the probe expression, evaluated on its own rather than folded
        /// into `pageInspectionScript`, so the production page-inspection path is untouched and
        /// this JavaScript runs only on the one document that can act on it.
        @MainActor
        private func beginCrewAccessAutoPrintSamplingIfNeeded(
            _ webView: WKWebView,
            completedURL: URL?
        ) {
            guard popupWebViews.contains(where: { $0 === webView }),
                  activePopupTeardownGeneration == nil,
                  CrewAccessAutoPrint.isExactZscalerSessionURL(completedURL)
            else { return }

            // Weak: a queued hop must never hold the Coordinator or a popup WebView alive past
            // the point the normal lifecycle would release them.
            autoPrintStageOneReadinessEvaluator(
                webView,
                CrewAccessPageProbe.probeExpression
            ) { [weak self, weak webView] result, _ in
                guard let self, let webView else { return }
                guard webView.url == completedURL else { return }
                self.beginCrewAccessProbe(
                    result as? [String: Any],
                    webView: webView,
                    completedURL: completedURL
                )
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            let isPopup = popupWebViews.contains(webView)
            DispatchQueue.main.async {
                if !isPopup {
                    self.viewModel.isLoading = false
                }
                self.viewModel.statusMessage = BrowserStatusText.networkError
            }
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            let isPopup = popupWebViews.contains(webView)
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
        /// It returns exactly the two fields the status classifier consumes. Auto-print does not
        /// ride on this script: its eligibility read runs `CrewAccessPageProbe.probeExpression`
        /// separately, and only on the one popup that can act on it.
        static func pageInspectionScript() -> String {
            """
            (() => ({
                pageText: document.body ? document.body.innerText : '',
                hasPasswordField: document.querySelector('input[type="password"]') !== null
            }))()
            """
        }

        private func inspectCompletedPage(_ webView: WKWebView, completedURL: URL?) {
            let script = Self.pageInspectionScript()
            webView.evaluateJavaScript(script) { [weak self, weak webView] result, error in
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
                    guard webView.url == completedURL else {
                        return
                    }
                    self.viewModel.statusMessage = status
                }
            }
        }

        /// A stable, non-identifying label for a WebView in a log line. Ships because every
        /// production auto-print log line names the popup it is talking about.
        private func navigationTraceIdentity(_ object: AnyObject?) -> String {
            guard let object else { return "<nil>" }
            return String(describing: ObjectIdentifier(object))
        }

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
                return
            }

            _ = popupFocusAcquirer(popup)
        }

        // MARK: - CrewAccess auto-print

        /// Evaluates one `didFinish` sample and schedules bounded eligibility re-reads for the exact
        /// tracked Zscaler session. The reads are observational; an eligible sample starts the
        /// separately guarded Stage 1 settle path.
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

            evaluateAutoPrintStageOneEligibility(
                probe,
                webView: webView,
                completedURL: completedURL,
                attempt: 0,
                sequence: sequence
            )

            // Nothing is scheduled against a WebView the Coordinator no longer owns, or while a
            // popup teardown is running, and nothing is sampled that auto-print could never act
            // on: only the tracked popup sitting on an exact Zscaler session URL is re-read.
            guard CrewAccessAutoPrint.isExactZscalerSessionURL(completedURL),
                  popupWebViews.contains(where: { $0 === webView }),
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
        private func endCrewAccessProbe(
            for webView: WKWebView,
            sequence: UInt,
            reason: String
        ) {
            let key = ObjectIdentifier(webView)
            guard crewAccessProbeSequences[key] == sequence else { return }
            crewAccessProbeTasks.removeValue(forKey: key)?.cancel()
            crewAccessProbeSequences.removeValue(forKey: key)
            browserAutoPrintLogger.info(
                "[AutoPrint] stage=1 sampling=ended reason=\(reason, privacy: .public) sequence=\(sequence, privacy: .public) popupGeneration=\(self.popupGeneration(for: webView), privacy: .public) webView=\(self.navigationTraceIdentity(webView), privacy: .public) completedSession=\(CrewAccessPageProbe.urlShape(for: webView.url), privacy: .public)"
            )
        }

        /// Names the first failed guard of a sampling chain, so a chain that ends before its bound
        /// says why instead of disappearing. Read-only.
        @MainActor
        private func crewAccessProbeChainEndReason(
            webView: WKWebView,
            completedURL: URL?,
            sequence: UInt
        ) -> String {
            if crewAccessProbeSequences[ObjectIdentifier(webView)] != sequence { return "superseded" }
            if activePopupTeardownGeneration != nil { return "teardown-in-progress" }
            if !ownsCrewAccessProbeTarget(webView) { return "popup-untracked" }
            if !CrewAccessAutoPrint.isSameZscalerSession(completedURL, webView.url) { return "session-changed" }
            return "guard-cleared"
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
                endCrewAccessProbe(for: webView, sequence: sequence, reason: "schedule-exhausted")
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
                // Same-session, not same-URL. The Zscaler isolation client evolves its own query
                // in place while the one Trip Details document stays open, so strict equality here
                // ended the chain before it could ever re-sample. This is the identical predicate
                // the Stage 1 settle gate already uses, and it is strictly narrower than a bare
                // host check: both sides must independently be exact session URLs.
                guard self.crewAccessProbeSequences[ObjectIdentifier(webView)] == sequence,
                      self.activePopupTeardownGeneration == nil,
                      self.ownsCrewAccessProbeTarget(webView),
                      CrewAccessAutoPrint.isSameZscalerSession(completedURL, webView.url) else {
                    self.endCrewAccessProbe(
                        for: webView,
                        sequence: sequence,
                        reason: self.crewAccessProbeChainEndReason(
                            webView: webView,
                            completedURL: completedURL,
                            sequence: sequence
                        )
                    )
                    return
                }

                // The eligibility read is the probe expression itself. The production page
                // inspection script is deliberately not reused here: it also scans page text and
                // password fields, which this path has no use for.
                webView.evaluateJavaScript(CrewAccessPageProbe.probeExpression) { [weak self, weak webView] result, _ in
                    let probe = result as? [String: Any]
                    DispatchQueue.main.async { [weak self, weak webView] in
                        guard let self, let webView else { return }
                        guard self.crewAccessProbeSequences[ObjectIdentifier(webView)] == sequence,
                              self.activePopupTeardownGeneration == nil,
                              self.ownsCrewAccessProbeTarget(webView) else {
                            self.endCrewAccessProbe(
                                for: webView,
                                sequence: sequence,
                                reason: "post-read-" + self.crewAccessProbeChainEndReason(
                                    webView: webView,
                                    completedURL: completedURL,
                                    sequence: sequence
                                )
                            )
                            return
                        }
                        self.evaluateAutoPrintStageOneEligibility(
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

        enum AutoPrintStageTwoReadinessOutcome {
            case ready
            case notReady(reason: String)
            case gateRejected(reason: String)
        }

        /// The sole Stage 1 → Stage 2 bridge. A rejected or malformed Stage 1 result cannot start
        /// settle-delay work; only the page world's confirmed `result=invoked` does.
        @MainActor
        func handleAutoPrintStageOneExecutionResult(
            _ result: String,
            webView: WKWebView,
            completedURL: URL?
        ) {
            guard result == "invoked" else { return }
            startAutoPrintStageTwoReadinessSchedule(
                webView: webView,
                completedURL: completedURL
            )
        }

        /// Stage 2 no longer sleeps a fixed six seconds. Stage 1's settle now happens before the
        /// Print dialog is ever opened, so the only thing left to wait for here is the dialog DOM
        /// becoming structurally ready. The schedule is a small finite list of offsets measured
        /// from the confirmed Stage 1 invocation; it never polls without a bound and never retries
        /// after an attempt.
        @MainActor
        private func startAutoPrintStageTwoReadinessSchedule(
            webView: WKWebView,
            completedURL: URL?
        ) {
            let key = ObjectIdentifier(webView)
            if let reason = autoPrintStageTwoScheduleRejectionReason(
                webView: webView,
                completedURL: completedURL
            ) {
                logAutoPrintStageTwoGateRejection(
                    reason: "start-\(reason)",
                    webView: webView,
                    completedURL: completedURL
                )
                browserAutoPrintLogger.info(
                    "[AutoPrint] stage=2 readiness-schedule=cancelled reason=start-\(reason, privacy: .public) webView=\(self.navigationTraceIdentity(webView), privacy: .public)"
                )
                return
            }

            cancelAutoPrintStageTwoReadinessSchedule(
                for: webView,
                reason: "replaced-by-new-readiness-schedule"
            )
            nextAutoPrintStageTwoReadinessSequence &+= 1
            let sequence = nextAutoPrintStageTwoReadinessSequence
            autoPrintStageTwoReadinessSequences[key] = sequence
            let offsetsDescription = autoPrintStageTwoReadinessOffsetsNanoseconds
                .map { String($0 / 1_000_000) }
                .joined(separator: ",")
            browserAutoPrintLogger.info(
                "[AutoPrint] stage=2 readiness-schedule=started offsetsMilliseconds=\(offsetsDescription, privacy: .public) sequence=\(sequence, privacy: .public) webView=\(self.navigationTraceIdentity(webView), privacy: .public) url=\(CrewAccessPageProbe.urlShape(for: completedURL), privacy: .public)"
            )
            scheduleAutoPrintStageTwoReadinessSample(
                webView: webView,
                completedURL: completedURL,
                index: 0,
                sequence: sequence
            )
        }

        /// One bounded readiness sample. `index` walks a fixed list, so the recursion terminates
        /// after the last offset with `schedule-exhausted` and the Stage 2 one-shot untouched.
        @MainActor
        private func scheduleAutoPrintStageTwoReadinessSample(
            webView: WKWebView,
            completedURL: URL?,
            index: Int,
            sequence: UInt
        ) {
            let key = ObjectIdentifier(webView)
            guard autoPrintStageTwoReadinessSequences[key] == sequence else { return }
            let offsets = autoPrintStageTwoReadinessOffsetsNanoseconds
            guard index >= 0, index < offsets.count else {
                browserAutoPrintLogger.info(
                    "[AutoPrint] stage=2 readiness=schedule-exhausted samples=\(offsets.count, privacy: .public) sequence=\(sequence, privacy: .public) webView=\(self.navigationTraceIdentity(webView), privacy: .public) oneShotState=available retry=false"
                )
                cancelAutoPrintStageTwoReadinessSchedule(
                    for: webView,
                    reason: "schedule-exhausted"
                )
                return
            }

            let previousOffset: UInt64 = index == 0 ? 0 : offsets[index - 1]
            let interval = offsets[index] > previousOffset ? offsets[index] - previousOffset : 0
            let offsetMilliseconds = offsets[index] / 1_000_000
            autoPrintStageTwoReadinessTasks.removeValue(forKey: key)?.cancel()
            autoPrintStageTwoReadinessTasks[key] = Task { @MainActor [weak self, weak webView] in
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled, let self, let webView else { return }
                guard self.autoPrintStageTwoReadinessSequences[key] == sequence else { return }
                self.autoPrintStageTwoReadinessTasks.removeValue(forKey: key)
                browserAutoPrintLogger.info(
                    "[AutoPrint] stage=2 readiness-sample=due index=\(index, privacy: .public) offsetMilliseconds=\(offsetMilliseconds, privacy: .public) sequence=\(sequence, privacy: .public) webView=\(self.navigationTraceIdentity(webView), privacy: .public)"
                )
                self.evaluateAutoPrintStageTwoReadiness(
                    ["readyState": "complete"],
                    webView: webView,
                    completedURL: completedURL,
                    attempt: index + 1,
                    sequence: sequence
                ) { [weak self, weak webView] outcome in
                    guard let self, let webView else { return }
                    guard case .notReady = outcome else { return }
                    self.scheduleAutoPrintStageTwoReadinessSample(
                        webView: webView,
                        completedURL: completedURL,
                        index: index + 1,
                        sequence: sequence
                    )
                }
            }
        }

        /// Records both URL shapes whenever a Stage 2 gate rejects. `stale-probe` previously
        /// reported only that something had changed, never what, which is why a benign in-session
        /// URL evolution could not be told apart from a real navigation.
        ///
        /// `urlShape` keeps scheme, host and path with report UUIDs and long digit runs masked,
        /// and reduces the query to parameter **names only** — a value is never logged.
        @MainActor
        private func logAutoPrintStageTwoGateRejection(
            reason: String,
            webView: WKWebView,
            completedURL: URL?
        ) {
            let currentURL = autoPrintStageTwoCurrentURLProvider(webView)
            browserAutoPrintLogger.info(
                "[AutoPrint] stage=2 gate=rejected reason=\(reason, privacy: .public) completedURL=\(CrewAccessPageProbe.urlShape(for: completedURL), privacy: .public) currentURL=\(CrewAccessPageProbe.urlShape(for: currentURL), privacy: .public) sameSession=\(CrewAccessAutoPrint.isSameZscalerSession(completedURL, currentURL), privacy: .public) webView=\(self.navigationTraceIdentity(webView), privacy: .public)"
            )
        }

        @MainActor
        private func autoPrintStageTwoScheduleRejectionReason(
            webView: WKWebView,
            completedURL: URL?
        ) -> String? {
            let key = ObjectIdentifier(webView)
            return CrewAccessAutoPrint.stageTwoRejectionReason(
                isTrackedPopup: popupWebViews.contains(where: { $0 === webView }),
                isVisiblePopup: viewModel.popupWebView === webView,
                livePopupCount: popupWebViews.count,
                teardownInProgress: activePopupTeardownGeneration != nil,
                completedURL: completedURL,
                currentURL: autoPrintStageTwoCurrentURLProvider(webView),
                readyState: "complete",
                stageOneAttempted: autoPrintStageOneAttemptedPopupIDs.contains(key),
                oneShotConsumed: autoPrintStageTwoAttemptedPopupIDs.contains(key)
            )
        }

        @MainActor
        func cancelAutoPrintStageTwoReadinessSchedule(
            for webView: WKWebView,
            reason: String
        ) {
            let key = ObjectIdentifier(webView)
            let hadSchedule = autoPrintStageTwoReadinessSequences.removeValue(forKey: key) != nil
            let task = autoPrintStageTwoReadinessTasks.removeValue(forKey: key)
            task?.cancel()
            let hadTask = task != nil
            guard hadSchedule || hadTask else { return }
            browserAutoPrintLogger.info(
                "[AutoPrint] stage=2 readiness-schedule=cancelled reason=\(reason, privacy: .public) webView=\(self.navigationTraceIdentity(webView), privacy: .public)"
            )
        }

        @MainActor
        var hasPendingAutoPrintStageTwoReadinessWork: Bool {
            !autoPrintStageTwoReadinessSequences.isEmpty
                || !autoPrintStageTwoReadinessTasks.isEmpty
        }

        /// Stage 2 structural preflight, called exactly once after the minimum settle delay. Only
        /// the exact dialog/button structure can pass; report stability and canvas diagnostics do
        /// not participate in the decision.
        @MainActor
        func evaluateAutoPrintStageTwoReadiness(
            _ probe: [String: Any]?,
            webView: WKWebView,
            completedURL: URL?,
            attempt: Int,
            sequence: UInt,
            completion: (@MainActor (AutoPrintStageTwoReadinessOutcome) -> Void)? = nil
        ) {
            let key = ObjectIdentifier(webView)
            let readyState = probeString(probe ?? [:], "readyState")
            let gateReason = CrewAccessAutoPrint.stageTwoRejectionReason(
                isTrackedPopup: popupWebViews.contains(where: { $0 === webView }),
                isVisiblePopup: viewModel.popupWebView === webView,
                livePopupCount: popupWebViews.count,
                teardownInProgress: activePopupTeardownGeneration != nil,
                completedURL: completedURL,
                currentURL: autoPrintStageTwoCurrentURLProvider(webView),
                readyState: readyState,
                stageOneAttempted: autoPrintStageOneAttemptedPopupIDs.contains(key),
                oneShotConsumed: autoPrintStageTwoAttemptedPopupIDs.contains(key)
            )
            if let gateReason {
                logAutoPrintStageTwoGateRejection(
                    reason: "phase-a-\(gateReason)",
                    webView: webView,
                    completedURL: completedURL
                )
                browserAutoPrintLogger.info(
                    "[AutoPrint] stage=2 readiness=not-ready reason=gate-\(gateReason, privacy: .public) sequence=\(sequence, privacy: .public) attempt=\(attempt, privacy: .public) webView=\(self.navigationTraceIdentity(webView), privacy: .public)"
                )
                cancelAutoPrintStageTwoReadinessSchedule(
                    for: webView,
                    reason: "phase-a-gate-\(gateReason)"
                )
                completion?(.gateRejected(reason: gateReason))
                return
            }

            autoPrintStageTwoReadinessEvaluator(
                webView,
                CrewAccessAutoPrint.stageTwoReadinessScript
            ) { [weak self, weak webView] result, error in
                guard let self, let webView else {
                    completion?(.gateRejected(reason: "readiness-context-released"))
                    return
                }
                let values = result as? [String: Any]
                let isButtonReady = values?["buttonReady"] as? Bool ?? false
                let readinessReason = values?["reason"] as? String ?? "<unavailable>"
                let diagnostic = values?["diagnostic"] as? [String: Any] ?? [:]
                let nsError = error as NSError?

                let submitButtons = diagnostic["submitButtons"] as? [[String: Any]] ?? []
                let submitButtonTexts = submitButtons.map {
                    self.probeString($0, "normalizedText")
                }
                let structuralReadinessPassed = error == nil
                    && isButtonReady
                    && self.probeInt(diagnostic, "dialogCount") == 1
                    && self.probeInt(diagnostic, "qualifyingDialogCount") == 1
                    && self.probeInt(diagnostic, "qualifyingSubmitButtonCount") == 1
                for (index, button) in submitButtons.enumerated() {
                    browserAutoPrintLogger.info(
                        "[AutoPrint] stage=2 diagnostic=submit-button index=\(index, privacy: .public) normalizedText=\(self.probeString(button, "normalizedText"), privacy: .public) ariaLabel=\(self.probeString(button, "ariaLabel"), privacy: .public) title=\(self.probeString(button, "title"), privacy: .public) disabled=\(self.probeBool(button, "disabled"), privacy: .public) rawAriaDisabled=\(self.probeString(button, "rawAriaDisabled"), privacy: .public) clientRectWidth=\(self.probeInt(button, "clientRectWidth"), privacy: .public) clientRectHeight=\(self.probeInt(button, "clientRectHeight"), privacy: .public) computedDisplay=\(self.probeString(button, "computedDisplay"), privacy: .public) computedVisibility=\(self.probeString(button, "computedVisibility"), privacy: .public) computedOpacity=\(self.probeString(button, "computedOpacity"), privacy: .public) computedPointerEvents=\(self.probeString(button, "computedPointerEvents"), privacy: .public)"
                    )
                }

                guard structuralReadinessPassed else {
                    let structuralReason = error == nil ? readinessReason : "readiness-error"
                    browserAutoPrintLogger.info(
                        "[AutoPrint] stage=2 readiness=not-ready reason=\(structuralReason, privacy: .public) sequence=\(sequence, privacy: .public) attempt=\(attempt, privacy: .public) dialogCount=\(self.probeInt(diagnostic, "dialogCount"), privacy: .public) qualifyingDialogCount=\(self.probeInt(diagnostic, "qualifyingDialogCount"), privacy: .public) submitButtonCount=\(self.probeInt(diagnostic, "submitButtonCount"), privacy: .public) visibleSubmitButtonCount=\(self.probeInt(diagnostic, "visibleSubmitButtonCount"), privacy: .public) qualifyingSubmitButtonCount=\(self.probeInt(diagnostic, "qualifyingSubmitButtonCount"), privacy: .public) submitButtonText=\(submitButtonTexts.joined(separator: ","), privacy: .public) webView=\(self.navigationTraceIdentity(webView), privacy: .public) errorDomain=\(nsError?.domain ?? "none", privacy: .public) errorCode=\(nsError?.code ?? 0, privacy: .public) oneShotState=available"
                    )
                    self.logAutoPrintStageTwoGateRejection(
                        reason: "structural-\(structuralReason)",
                        webView: webView,
                        completedURL: completedURL
                    )
                    // Structural not-ready is not a failure: the dialog simply has not appeared
                    // yet. The bounded schedule owns whether another sample follows, so nothing
                    // is cancelled and the Stage 2 one-shot stays available.
                    completion?(.notReady(reason: structuralReason))
                    return
                }

                browserAutoPrintLogger.info(
                    "[AutoPrint] stage=2 gate=accepted reason=all-guards-passed sequence=\(sequence, privacy: .public) attempt=\(attempt, privacy: .public) dialogCount=1 qualifyingDialogCount=1 qualifyingSubmitButtonCount=1 oneShotState=available webView=\(self.navigationTraceIdentity(webView), privacy: .public)"
                )
                self.invokeAutoPrintStageTwo(
                    webView: webView,
                    completedURL: completedURL,
                    readyState: readyState,
                    attempt: attempt,
                    sequence: sequence
                )
                completion?(.ready)
            }
        }

        /// Production Stage 2, Phase B. It re-runs every Swift-side guard, consumes the one-shot
        /// immediately before JavaScript, and never retries after an attempt.
        @MainActor
        private func invokeAutoPrintStageTwo(
            webView: WKWebView,
            completedURL: URL?,
            readyState: String,
            attempt: Int,
            sequence: UInt
        ) {
            let key = ObjectIdentifier(webView)
            let eligibilityReason = CrewAccessAutoPrint.stageTwoRejectionReason(
                isTrackedPopup: popupWebViews.contains(where: { $0 === webView }),
                isVisiblePopup: viewModel.popupWebView === webView,
                livePopupCount: popupWebViews.count,
                teardownInProgress: activePopupTeardownGeneration != nil,
                completedURL: completedURL,
                currentURL: autoPrintStageTwoCurrentURLProvider(webView),
                readyState: readyState,
                stageOneAttempted: autoPrintStageOneAttemptedPopupIDs.contains(key),
                oneShotConsumed: autoPrintStageTwoAttemptedPopupIDs.contains(key)
            )
            if let eligibilityReason {
                browserAutoPrintLogger.info(
                    "[AutoPrint] stage=2 eligibility=rejected reason=\(eligibilityReason, privacy: .public) sequence=\(sequence, privacy: .public) attempt=\(attempt, privacy: .public) webView=\(self.navigationTraceIdentity(webView), privacy: .public)"
                )
                cancelAutoPrintStageTwoReadinessSchedule(
                    for: webView,
                    reason: "phase-b-eligibility-\(eligibilityReason)"
                )
                return
            }

            // Required second Swift-side check immediately before optimistic consumption. Nothing
            // between this check and Set.insert may schedule or execute JavaScript.
            let preConsumptionReason = CrewAccessAutoPrint.stageTwoRejectionReason(
                isTrackedPopup: popupWebViews.contains(where: { $0 === webView }),
                isVisiblePopup: viewModel.popupWebView === webView,
                livePopupCount: popupWebViews.count,
                teardownInProgress: activePopupTeardownGeneration != nil,
                completedURL: completedURL,
                currentURL: autoPrintStageTwoCurrentURLProvider(webView),
                readyState: readyState,
                stageOneAttempted: autoPrintStageOneAttemptedPopupIDs.contains(key),
                oneShotConsumed: autoPrintStageTwoAttemptedPopupIDs.contains(key)
            )
            if let preConsumptionReason {
                browserAutoPrintLogger.info(
                    "[AutoPrint] stage=2 eligibility=rejected reason=preconsume-\(preConsumptionReason, privacy: .public) sequence=\(sequence, privacy: .public) attempt=\(attempt, privacy: .public) webView=\(self.navigationTraceIdentity(webView), privacy: .public)"
                )
                cancelAutoPrintStageTwoReadinessSchedule(
                    for: webView,
                    reason: "phase-b-preconsume-\(preConsumptionReason)"
                )
                return
            }

            let insertion = autoPrintStageTwoAttemptedPopupIDs.insert(key)
            guard insertion.inserted else {
                browserAutoPrintLogger.info(
                    "[AutoPrint] stage=2 eligibility=rejected reason=preconsume-one-shot-already-consumed sequence=\(sequence, privacy: .public) attempt=\(attempt, privacy: .public) webView=\(self.navigationTraceIdentity(webView), privacy: .public)"
                )
                cancelAutoPrintStageTwoReadinessSchedule(
                    for: webView,
                    reason: "phase-b-preconsume-one-shot-already-consumed"
                )
                return
            }
            cancelAutoPrintStageTwoReadinessSchedule(
                for: webView,
                reason: "invocation-attempted"
            )
            browserAutoPrintLogger.info(
                "[AutoPrint] stage=2 oneShot=consumed timing=immediately-before-javascript webView=\(self.navigationTraceIdentity(webView), privacy: .public)"
            )
            browserAutoPrintLogger.info(
                "[AutoPrint] stage=2 execution=attempted sequence=\(sequence, privacy: .public) attempt=\(attempt, privacy: .public) webView=\(self.navigationTraceIdentity(webView), privacy: .public) url=\(CrewAccessPageProbe.urlShape(for: completedURL), privacy: .public)"
            )

            autoPrintStageTwoJavaScriptEvaluator(
                webView,
                CrewAccessAutoPrint.stageTwoInvocationScript
            ) { [weak self, weak webView] result, error in
                guard let self, let webView else { return }
                let values = result as? [String: Any]
                let jsResult = values?["result"] as? String ?? "<unavailable>"
                let jsReason = values?["reason"] as? String ?? "<unavailable>"
                let count = self.probeInt(values ?? [:], "count")
                let diagnostic = values?["diagnostic"] as? [String: Any] ?? [:]
                let nsError = error as NSError?

                browserAutoPrintLogger.info(
                    "[AutoPrint] stage=2 executionResult=\(jsResult, privacy: .public) reason=\(jsReason, privacy: .public) qualifyingCount=\(count, privacy: .public) dialogCount=\(self.probeInt(diagnostic, "dialogCount"), privacy: .public) qualifyingDialogCount=\(self.probeInt(diagnostic, "qualifyingDialogCount"), privacy: .public) submitButtonCount=\(self.probeInt(diagnostic, "submitButtonCount"), privacy: .public) visibleSubmitButtonCount=\(self.probeInt(diagnostic, "visibleSubmitButtonCount"), privacy: .public) webView=\(self.navigationTraceIdentity(webView), privacy: .public) errorDomain=\(nsError?.domain ?? "none", privacy: .public) errorCode=\(nsError?.code ?? 0, privacy: .public) retry=false"
                )
            }
        }

        /// The single Swift-side Stage 1 gate. Every Stage 1 decision — the probe sample that
        /// starts the settle delay, the re-gate after it elapses, and the immediate
        /// pre-consumption re-check — routes through here, so the guards can never drift apart.
        @MainActor
        private func autoPrintStageOneRejectionReason(
            webView: WKWebView,
            completedURL: URL?,
            readyState: String,
            printElements: [[String: Any]]
        ) -> String? {
            CrewAccessAutoPrint.rejectionReason(
                isTrackedPopup: popupWebViews.contains(where: { $0 === webView }),
                isVisiblePopup: viewModel.popupWebView === webView,
                livePopupCount: popupWebViews.count,
                teardownInProgress: activePopupTeardownGeneration != nil,
                completedURL: completedURL,
                currentURL: webView.url,
                readyState: readyState,
                printElements: printElements,
                oneShotConsumed: autoPrintStageOneAttemptedPopupIDs.contains(ObjectIdentifier(webView))
            )
        }

        /// The Swift-side Stage 1 gate used once the settle delay has elapsed. Both the
        /// post-settle re-gate and the immediate pre-consumption re-check route through here, so
        /// the two can never drift apart, and both read live state: the popup collection, the
        /// visible popup, the teardown flag, the popup's own generation and `webView.url` as it is
        /// now — plus the freshly re-read `readyState` and print elements passed in.
        @MainActor
        private func autoPrintStageOneSettledRejectionReason(
            webView: WKWebView,
            settleSessionURL: URL?,
            settleGeneration: UInt,
            readyState: String,
            printElements: [[String: Any]]
        ) -> String? {
            CrewAccessAutoPrint.settledRejectionReason(
                isTrackedPopup: popupWebViews.contains(where: { $0 === webView }),
                isVisiblePopup: viewModel.popupWebView === webView,
                livePopupCount: popupWebViews.count,
                teardownInProgress: activePopupTeardownGeneration != nil,
                isSamePopupGeneration: popupGeneration(for: webView) == settleGeneration,
                settleSessionURL: settleSessionURL,
                currentURL: webView.url,
                readyState: readyState,
                printElements: printElements,
                oneShotConsumed: autoPrintStageOneAttemptedPopupIDs.contains(ObjectIdentifier(webView))
            )
        }

        /// The popup's own trace generation, assigned when the popup is created and removed only by
        /// teardown finalization. Used as the identity that must survive the settle delay.
        @MainActor
        private func popupGeneration(for webView: WKWebView) -> UInt {
            popupGeneration(forKey: ObjectIdentifier(webView))
        }

        @MainActor
        private func popupGeneration(forKey key: ObjectIdentifier) -> UInt {
            popupGenerations[key] ?? 0
        }

        /// Evaluates the already-scheduled production probe sample. It never clicks and it never
        /// consumes: an eligible sample only starts the bounded pre-Stage-1 settle delay, which is
        /// what lets the user look at Trip Details rather than at the Print dialog while the page
        /// settles. The one-shot is deliberately left available for the whole wait, so a later
        /// probe sample still passes the gates; the pending-settle guard below is what stops it
        /// from starting a second delay for the same popup.
        @MainActor
        func evaluateAutoPrintStageOneEligibility(
            _ probe: [String: Any]?,
            webView: WKWebView,
            completedURL: URL?,
            attempt: Int,
            sequence: UInt
        ) {
            let key = ObjectIdentifier(webView)
            let printElements = probe?["printElements"] as? [[String: Any]] ?? []
            let readyState = probeString(probe ?? [:], "readyState")
            let oneShotConsumed = autoPrintStageOneAttemptedPopupIDs.contains(key)
            let reason = autoPrintStageOneRejectionReason(
                webView: webView,
                completedURL: completedURL,
                readyState: readyState,
                printElements: printElements
            )

            if let reason {
                browserAutoPrintLogger.info(
                    "[AutoPrint] stage=1 gate=rejected eligibility=rejected reason=\(reason, privacy: .public) sequence=\(sequence, privacy: .public) attempt=\(attempt, privacy: .public) webView=\(self.navigationTraceIdentity(webView), privacy: .public) oneShotState=\(oneShotConsumed ? "consumed" : "available", privacy: .public)"
                )
                return
            }

            guard autoPrintStageOneSettleSequences[key] == nil else {
                browserAutoPrintLogger.info(
                    "[AutoPrint] stage=1 gate=rejected eligibility=rejected reason=settle-delay-already-pending sequence=\(sequence, privacy: .public) attempt=\(attempt, privacy: .public) webView=\(self.navigationTraceIdentity(webView), privacy: .public) oneShotState=available"
                )
                return
            }

            browserAutoPrintLogger.info(
                "[AutoPrint] stage=1 gate=accepted eligibility=accepted reason=all-guards-passed sequence=\(sequence, privacy: .public) attempt=\(attempt, privacy: .public) webView=\(self.navigationTraceIdentity(webView), privacy: .public) qualifyingPrintButtons=1 oneShotState=available"
            )
            // The session identity the wait is tied to is the popup's live URL, which the gate
            // above has just proven is an exact Zscaler session URL.
            startAutoPrintStageOneSettleDelay(
                webView: webView,
                settleSessionURL: webView.url,
                probeSequence: sequence
            )
        }

        /// One bounded production settle task per popup, taken before the toolbar Print button is
        /// ever invoked.
        ///
        /// What is captured here is deliberately minimal: the popup's identity, the popup's own
        /// trace generation, and the Zscaler **session** the run belongs to. The probe result that
        /// made this popup eligible is NOT carried forward — it is a snapshot of a document that
        /// will have changed by the time the delay elapses, and requiring it to stay current is
        /// what made every settled run report `stale-probe`. Nothing is consumed here.
        @MainActor
        private func startAutoPrintStageOneSettleDelay(
            webView: WKWebView,
            settleSessionURL: URL?,
            probeSequence: UInt
        ) {
            let key = ObjectIdentifier(webView)
            let settleGeneration = popupGeneration(for: webView)
            nextAutoPrintStageOneSettleSequence &+= 1
            let settleSequence = nextAutoPrintStageOneSettleSequence
            autoPrintStageOneSettleSequences[key] = settleSequence
            let delay = autoPrintStageOneSettleDelayNanoseconds
            browserAutoPrintLogger.info(
                "[AutoPrint] stage=1 settle-delay=started milliseconds=\(delay / 1_000_000, privacy: .public) settleSequence=\(settleSequence, privacy: .public) probeSequence=\(probeSequence, privacy: .public) popupGeneration=\(settleGeneration, privacy: .public) webView=\(self.navigationTraceIdentity(webView), privacy: .public) sessionURL=\(CrewAccessPageProbe.urlShape(for: settleSessionURL), privacy: .public) oneShotState=available"
            )
            autoPrintStageOneSettleTasks.removeValue(forKey: key)?.cancel()
            // The WebView is deliberately NOT captured, not even weakly: after the wait the popup
            // identity is re-resolved from `popupWebViews`, so a replaced or untracked popup can
            // never be the thing that gets clicked.
            autoPrintStageOneSettleTasks[key] = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled, let self else { return }
                guard self.autoPrintStageOneSettleSequences[key] == settleSequence else { return }
                self.autoPrintStageOneSettleTasks.removeValue(forKey: key)
                browserAutoPrintLogger.info(
                    "[AutoPrint] stage=1 settle-delay=elapsed settleSequence=\(settleSequence, privacy: .public) webView=\(String(describing: key), privacy: .public)"
                )
                self.runAutoPrintStageOneSettleDelayCheck(
                    key: key,
                    settleSessionURL: settleSessionURL,
                    settleGeneration: settleGeneration,
                    settleSequence: settleSequence
                )
            }
        }

        /// Re-resolves the popup and re-reads the document once. A navigation to a different
        /// session, a replacement, a teardown or a manual interaction during the wait shows up here
        /// as a failed gate, and the settle delay is cancelled with the one-shot still unconsumed.
        /// A newer probe sample arriving during the wait is irrelevant: nothing here consults it.
        @MainActor
        private func runAutoPrintStageOneSettleDelayCheck(
            key: ObjectIdentifier,
            settleSessionURL: URL?,
            settleGeneration: UInt,
            settleSequence: UInt
        ) {
            guard autoPrintStageOneSettleSequences[key] == settleSequence else { return }
            guard activePopupTeardownGeneration == nil else {
                cancelAutoPrintStageOneSettleDelay(
                    forKey: key,
                    identity: String(describing: key),
                    reason: "elapsed-teardown-in-progress"
                )
                return
            }
            guard let webView = popupWebViews.first(where: { ObjectIdentifier($0) == key }) else {
                cancelAutoPrintStageOneSettleDelay(
                    forKey: key,
                    identity: String(describing: key),
                    reason: "elapsed-popup-untracked"
                )
                return
            }

            autoPrintStageOneReadinessEvaluator(
                webView,
                CrewAccessPageProbe.probeExpression
            ) { [weak self, weak webView] result, error in
                guard let self, let webView else { return }
                guard self.autoPrintStageOneSettleSequences[key] == settleSequence else { return }
                guard self.popupWebViews.contains(where: { ObjectIdentifier($0) == key }) else {
                    self.cancelAutoPrintStageOneSettleDelay(
                        forKey: key,
                        identity: String(describing: key),
                        reason: "resample-popup-untracked"
                    )
                    return
                }
                let nsError = error as NSError?
                guard error == nil, let probe = result as? [String: Any] else {
                    browserAutoPrintLogger.info(
                        "[AutoPrint] stage=1 gate=rejected reason=elapsed-resample-error sequence=\(settleSequence, privacy: .public) webView=\(self.navigationTraceIdentity(webView), privacy: .public) errorDomain=\(nsError?.domain ?? "none", privacy: .public) errorCode=\(nsError?.code ?? 0, privacy: .public) oneShotState=available"
                    )
                    self.cancelAutoPrintStageOneSettleDelay(
                        for: webView,
                        reason: "elapsed-resample-error"
                    )
                    return
                }
                self.invokeAutoPrintStageOne(
                    webView: webView,
                    settleSessionURL: settleSessionURL,
                    settleGeneration: settleGeneration,
                    probe: probe,
                    settleSequence: settleSequence
                )
            }
        }

        @MainActor
        func cancelAutoPrintStageOneSettleDelay(
            for webView: WKWebView,
            reason: String
        ) {
            cancelAutoPrintStageOneSettleDelay(
                forKey: ObjectIdentifier(webView),
                identity: navigationTraceIdentity(webView),
                reason: reason
            )
        }

        @MainActor
        private func cancelAutoPrintStageOneSettleDelay(
            forKey key: ObjectIdentifier,
            identity: String,
            reason: String
        ) {
            let hadSchedule = autoPrintStageOneSettleSequences.removeValue(forKey: key) != nil
            let task = autoPrintStageOneSettleTasks.removeValue(forKey: key)
            task?.cancel()
            let hadTask = task != nil
            guard hadSchedule || hadTask else { return }
            browserAutoPrintLogger.info(
                "[AutoPrint] stage=1 settle-delay=cancelled reason=\(reason, privacy: .public) webView=\(identity, privacy: .public)"
            )
        }

        /// Test introspection: whether a pre-Stage-1 settle delay is still pending.
        @MainActor
        var hasPendingAutoPrintStageOneSettleWork: Bool {
            !autoPrintStageOneSettleSequences.isEmpty
                || !autoPrintStageOneSettleTasks.isEmpty
        }

        /// Stage 1, Phase B. Re-runs every gate against the freshly re-read document, consumes the
        /// one-shot immediately before JavaScript, and never retries after an attempt. The
        /// invocation script itself is frozen and unchanged.
        @MainActor
        private func invokeAutoPrintStageOne(
            webView: WKWebView,
            settleSessionURL: URL?,
            settleGeneration: UInt,
            probe: [String: Any],
            settleSequence: UInt
        ) {
            let key = ObjectIdentifier(webView)
            let printElements = probe["printElements"] as? [[String: Any]] ?? []
            let readyState = probeString(probe, "readyState")

            if let reason = autoPrintStageOneSettledRejectionReason(
                webView: webView,
                settleSessionURL: settleSessionURL,
                settleGeneration: settleGeneration,
                readyState: readyState,
                printElements: printElements
            ) {
                browserAutoPrintLogger.info(
                    "[AutoPrint] stage=1 gate=rejected eligibility=rejected reason=elapsed-gate-\(reason, privacy: .public) sequence=\(settleSequence, privacy: .public) webView=\(self.navigationTraceIdentity(webView), privacy: .public) settleSessionURL=\(CrewAccessPageProbe.urlShape(for: settleSessionURL), privacy: .public) currentURL=\(CrewAccessPageProbe.urlShape(for: webView.url), privacy: .public) sameSession=\(CrewAccessAutoPrint.isSameZscalerSession(settleSessionURL, webView.url), privacy: .public) settleGeneration=\(settleGeneration, privacy: .public) currentGeneration=\(self.popupGeneration(for: webView), privacy: .public) oneShotState=available"
                )
                cancelAutoPrintStageOneSettleDelay(
                    for: webView,
                    reason: "elapsed-gate-\(reason)"
                )
                return
            }

            // Required second Swift-side check immediately before optimistic consumption. Nothing
            // between this check and Set.insert may schedule or execute JavaScript.
            if let preConsumptionReason = autoPrintStageOneSettledRejectionReason(
                webView: webView,
                settleSessionURL: settleSessionURL,
                settleGeneration: settleGeneration,
                readyState: readyState,
                printElements: printElements
            ) {
                browserAutoPrintLogger.info(
                    "[AutoPrint] stage=1 gate=rejected eligibility=rejected reason=preconsume-\(preConsumptionReason, privacy: .public) sequence=\(settleSequence, privacy: .public) webView=\(self.navigationTraceIdentity(webView), privacy: .public) oneShotState=available"
                )
                cancelAutoPrintStageOneSettleDelay(
                    for: webView,
                    reason: "preconsume-\(preConsumptionReason)"
                )
                return
            }

            browserAutoPrintLogger.info(
                "[AutoPrint] stage=1 gate=accepted eligibility=accepted reason=all-guards-passed-after-settle sequence=\(settleSequence, privacy: .public) webView=\(self.navigationTraceIdentity(webView), privacy: .public) qualifyingPrintButtons=1 oneShotState=available"
            )

            let insertion = autoPrintStageOneAttemptedPopupIDs.insert(key)
            guard insertion.inserted else {
                browserAutoPrintLogger.info(
                    "[AutoPrint] stage=1 gate=rejected eligibility=rejected reason=preconsume-one-shot-already-consumed sequence=\(settleSequence, privacy: .public) webView=\(self.navigationTraceIdentity(webView), privacy: .public) oneShotState=consumed"
                )
                cancelAutoPrintStageOneSettleDelay(
                    for: webView,
                    reason: "preconsume-one-shot-already-consumed"
                )
                return
            }
            cancelAutoPrintStageOneSettleDelay(
                for: webView,
                reason: "invocation-attempted"
            )

            // Stage 2 is anchored to the session URL as it is at the moment Stage 1 fires — the
            // gate above has just proven it is an exact Zscaler session URL — so Stage 2's own
            // same-session guard starts from live state rather than from a five-second-old value.
            let invocationURL = webView.url
            nextAutoPrintRunID &+= 1
            let runID = nextAutoPrintRunID
            browserAutoPrintLogger.info(
                "[AutoPrint] stage=1 id=\(runID, privacy: .public) oneShot=consumed timing=immediately-before-javascript webView=\(self.navigationTraceIdentity(webView), privacy: .public)"
            )
            browserAutoPrintLogger.info(
                "[AutoPrint] stage=1 id=\(runID, privacy: .public) execution=attempted webView=\(self.navigationTraceIdentity(webView), privacy: .public) url=\(CrewAccessPageProbe.urlShape(for: invocationURL), privacy: .public)"
            )

            autoPrintStageOneJavaScriptEvaluator(
                webView,
                CrewAccessAutoPrint.invocationScript
            ) { [weak self] result, error in
                guard let self else { return }
                // Resolve the already-consumed popup identity from Coordinator ownership. The
                // earlier weak capture could silently become nil after logging Stage 1 `invoked`,
                // dropping the Stage 2 handoff without a scheduler rejection event.
                let stageOneWebView = self.popupWebViews.first {
                    ObjectIdentifier($0) == key
                }
                let nsError = error as NSError?
                let values = result as? [String: Any]
                let jsResult = values?["result"] as? String ?? (error == nil ? "invalid-result" : "js-error")
                let jsReason = values?["reason"] as? String ?? "none"
                let candidateCount = (values?["count"] as? NSNumber)?.intValue ?? -1
                let computedPointerEvents = values?["computedPointerEvents"] as? String ?? "<unavailable>"
                browserAutoPrintLogger.info(
                    "[AutoPrint] id=\(runID, privacy: .public) executionResult=\(jsResult, privacy: .public) reason=\(jsReason, privacy: .public) candidateCount=\(candidateCount, privacy: .public) computedPointerEvents=\(computedPointerEvents, privacy: .public) webView=\(self.navigationTraceIdentity(stageOneWebView), privacy: .public) errorDomain=\(nsError?.domain ?? "none", privacy: .public) errorCode=\(nsError?.code ?? 0, privacy: .public) retry=false"
                )
                if candidateCount == 0,
                   let diagnostic = values?["diagnostic"] as? [String: Any],
                   let survivingCounts = diagnostic["survivingCounts"] as? [String: Any] {
                    let count: (String) -> Int = { key in
                        (survivingCounts[key] as? NSNumber)?.intValue ?? -1
                    }
                    let totalButtonCount = (diagnostic["totalDocumentButtonCount"] as? NSNumber)?.intValue ?? -1
                    let exactPrintAriaLabelCount = (diagnostic["exactPrintAriaLabelCount"] as? NSNumber)?.intValue ?? -1
                    browserAutoPrintLogger.info(
                        "[AutoPrint] id=\(runID, privacy: .public) diagnostic=predicate-counts totalDocumentButtons=\(totalButtonCount, privacy: .public) exactAriaLabelPrint=\(exactPrintAriaLabelCount, privacy: .public) afterTagNameExactButton=\(count("afterTagNameExactButton"), privacy: .public) afterTypeAttributeExactButton=\(count("afterTypeAttributeExactButton"), privacy: .public) afterAriaLabelExactPrint=\(count("afterAriaLabelExactPrint"), privacy: .public) afterPositiveClientRect=\(count("afterPositiveClientRect"), privacy: .public) afterNotHidden=\(count("afterNotHidden"), privacy: .public) afterNotDisabled=\(count("afterNotDisabled"), privacy: .public) afterAriaDisabledNotTrue=\(count("afterAriaDisabledNotTrue"), privacy: .public) afterDisplayNotNone=\(count("afterDisplayNotNone"), privacy: .public) afterVisibilityNotHidden=\(count("afterVisibilityNotHidden"), privacy: .public) afterVisibilityNotCollapse=\(count("afterVisibilityNotCollapse"), privacy: .public) afterOpacityGreaterThanPointZeroOne=\(count("afterOpacityGreaterThanPointZeroOne"), privacy: .public) retry=false"
                    )

                    let printable: (Any?) -> String = { value in
                        guard let value, !(value is NSNull) else { return "<nil>" }
                        if let string = value as? String { return String(reflecting: string) }
                        return String(describing: value)
                    }
                    let printLikeButtons = diagnostic["printLikeButtons"] as? [[String: Any]] ?? []
                    for (index, button) in printLikeButtons.enumerated() {
                        let rejectedPredicates = (button["rejectedPredicates"] as? [String])?.joined(separator: ",") ?? "<unavailable>"
                        browserAutoPrintLogger.info(
                            "[AutoPrint] id=\(runID, privacy: .public) diagnostic=print-like-button index=\(index, privacy: .public) rawTagName=\(printable(button["rawTagName"]), privacy: .public) rawTypeAttribute=\(printable(button["rawTypeAttribute"]), privacy: .public) rawAriaLabel=\(printable(button["rawAriaLabel"]), privacy: .public) disabled=\(printable(button["disabled"]), privacy: .public) rawAriaDisabled=\(printable(button["rawAriaDisabled"]), privacy: .public) hidden=\(printable(button["hidden"]), privacy: .public) clientRectWidth=\(printable(button["clientRectWidth"]), privacy: .public) clientRectHeight=\(printable(button["clientRectHeight"]), privacy: .public) computedDisplay=\(printable(button["computedDisplay"]), privacy: .public) computedVisibility=\(printable(button["computedVisibility"]), privacy: .public) computedOpacity=\(printable(button["computedOpacity"]), privacy: .public) computedPointerEvents=\(printable(button["computedPointerEvents"]), privacy: .public) rejectedPredicates=\(rejectedPredicates, privacy: .public) retry=false"
                        )
                    }
                }
                if jsResult == "invoked", let stageOneWebView {
                    self.handleAutoPrintStageOneExecutionResult(
                        jsResult,
                        webView: stageOneWebView,
                        completedURL: invocationURL
                    )
                } else if jsResult == "invoked" {
                    browserAutoPrintLogger.info(
                        "[AutoPrint] stage=2 schedule=cancelled reason=stage-one-popup-untracked webView=\(String(describing: key), privacy: .public)"
                    )
                }
            }
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
            // Teardown has begun: every pending auto-print task for these popups is made inert
            // immediately, before any of the native cleanup below runs.
            for popup in popups {
                let popupKey = ObjectIdentifier(popup)
                browserAutoPrintLogger.info(
                    "[AutoPrint] popupGeneration=\(self.popupGeneration(forKey: popupKey), privacy: .public) event=teardown-began teardownGeneration=\(generation, privacy: .public) stageOneOneShot=\(self.autoPrintStageOneAttemptedPopupIDs.contains(popupKey) ? "consumed" : "available", privacy: .public) stageTwoOneShot=\(self.autoPrintStageTwoAttemptedPopupIDs.contains(popupKey) ? "consumed" : "available", privacy: .public) webView=\(self.navigationTraceIdentity(popup), privacy: .public)"
                )
                cancelCrewAccessProbe(for: popup)
                cancelAutoPrintStageOneSettleDelay(
                    for: popup,
                    reason: "popup-teardown-began"
                )
                cancelAutoPrintStageTwoReadinessSchedule(
                    for: popup,
                    reason: "popup-teardown-began"
                )
            }
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
                let popupKey = ObjectIdentifier(popup)
                let retiredGeneration = popupGeneration(forKey: popupKey)
                cancelCrewAccessProbe(for: popup)
                cancelAutoPrintStageOneSettleDelay(
                    for: popup,
                    reason: "popup-teardown-finalized"
                )
                cancelAutoPrintStageTwoReadinessSchedule(
                    for: popup,
                    reason: "popup-teardown-finalized"
                )
                let removedStageOneOneShot = autoPrintStageOneAttemptedPopupIDs.remove(popupKey) != nil
                let removedStageTwoOneShot = autoPrintStageTwoAttemptedPopupIDs.remove(popupKey) != nil
                // The generation is retired with the popup, so a recycled address cannot inherit
                // the identity a pending settle delay captured.
                popupGenerations.removeValue(forKey: popupKey)
                browserAutoPrintLogger.info(
                    "[AutoPrint] popupGeneration=\(retiredGeneration, privacy: .public) event=one-shots-cleared teardownGeneration=\(generation, privacy: .public) removedStageOne=\(removedStageOneOneShot, privacy: .public) removedStageTwo=\(removedStageTwoOneShot, privacy: .public) webView=\(self.navigationTraceIdentity(popup), privacy: .public)"
                )
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
