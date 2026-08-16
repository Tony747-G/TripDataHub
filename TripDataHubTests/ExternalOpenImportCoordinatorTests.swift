import XCTest
import WebKit
@testable import TripDataHub

final class ExternalOpenImportCoordinatorTests: XCTestCase {
    func test_enqueueDeduplicatesQueuedKey() async {
        let coordinator = ExternalOpenImportCoordinator(dedupTTL: 30)
        let now = Date(timeIntervalSince1970: 100)

        let first = await coordinator.enqueue(key: "same", url: url("one.pdf"), now: now)
        let second = await coordinator.enqueue(key: "same", url: url("two.pdf"), now: now)

        XCTAssertTrue(first)
        XCTAssertFalse(second)
        let item = await coordinator.dequeueNext()
        XCTAssertEqual(item?.key, "same")
        let next = await coordinator.dequeueNext()
        XCTAssertNil(next)
    }

    func test_concurrentEnqueue_allowsOnlyOneAcceptedKey() async {
        let coordinator = ExternalOpenImportCoordinator(dedupTTL: 30)
        let now = Date(timeIntervalSince1970: 100)

        let acceptedCount = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<40 {
                group.addTask {
                    await coordinator.enqueue(key: "same", url: self.url("file-\(index).pdf"), now: now)
                }
            }

            var count = 0
            for await accepted in group where accepted {
                count += 1
            }
            return count
        }

        XCTAssertEqual(acceptedCount, 1)
    }

    func test_finishFailureAllowsImmediateRetry() async {
        let coordinator = ExternalOpenImportCoordinator(dedupTTL: 30)
        let now = Date(timeIntervalSince1970: 100)

        let initialEnqueue = await coordinator.enqueue(key: "retry", url: url("one.pdf"), now: now)
        XCTAssertTrue(initialEnqueue)
        let item = await coordinator.dequeueNext()
        XCTAssertEqual(item?.key, "retry")
        let markedInFlight = await coordinator.markInFlight("retry")
        XCTAssertTrue(markedInFlight)
        await coordinator.finish(key: "retry", success: false)

        let retryEnqueue = await coordinator.enqueue(key: "retry", url: url("one.pdf"), now: now.addingTimeInterval(1))
        XCTAssertTrue(retryEnqueue)
    }

    func test_finishSuccessSuppressesRetryUntilTTLExpires() async {
        let coordinator = ExternalOpenImportCoordinator(dedupTTL: 30)
        let now = Date(timeIntervalSince1970: 100)

        let initialEnqueue = await coordinator.enqueue(key: "done", url: url("one.pdf"), now: now)
        XCTAssertTrue(initialEnqueue)
        _ = await coordinator.dequeueNext()
        let markedInFlight = await coordinator.markInFlight("done")
        XCTAssertTrue(markedInFlight)
        await coordinator.finish(key: "done", success: true, now: now)

        let earlyRetry = await coordinator.enqueue(key: "done", url: url("one.pdf"), now: now.addingTimeInterval(1))
        let ttlRetry = await coordinator.enqueue(key: "done", url: url("one.pdf"), now: now.addingTimeInterval(31))
        XCTAssertFalse(earlyRetry)
        XCTAssertTrue(ttlRetry)
    }

    func test_parkFrontPreservesFIFOAndDoesNotBecomeFailureRetry() async {
        let coordinator = ExternalOpenImportCoordinator(dedupTTL: 30)
        let now = Date(timeIntervalSince1970: 100)
        let acceptedB = await coordinator.enqueue(key: "B", url: url("b.pdf"), now: now)
        let acceptedC = await coordinator.enqueue(key: "C", url: url("c.pdf"), now: now)
        XCTAssertTrue(acceptedB)
        XCTAssertTrue(acceptedC)

        let parked = await coordinator.dequeueNext()
        XCTAssertEqual(parked?.key, "B")
        let markedInFlight = await coordinator.markInFlight("B")
        XCTAssertTrue(markedInFlight)
        if let parked {
            await coordinator.parkFront(parked)
        }

        let first = await coordinator.dequeueNext()
        let second = await coordinator.dequeueNext()
        XCTAssertEqual(first?.key, "B")
        XCTAssertEqual(second?.key, "C")
    }

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
    }
}

@MainActor
final class ImportPreviewPresentationPolicyTests: XCTestCase {
    func test_browserBottomStatusBarClassifiesRequiredStatesAndSharesPopupSurface() throws {
        XCTAssertEqual(
            BrowserPageStatusClassifier.status(
                url: URL(string: "https://fltops-portal.ups.com/home"),
                pageText: "Schedule ready",
                hasPasswordField: false
            ),
            BrowserStatusText.pageLoaded
        )
        XCTAssertEqual(
            BrowserPageStatusClassifier.status(
                url: URL(string: "https://fltops-portal.ups.com/login"),
                pageText: "",
                hasPasswordField: false
            ),
            BrowserStatusText.loginRequired
        )
        XCTAssertEqual(
            BrowserPageStatusClassifier.status(
                url: URL(string: "https://sso.ups.com/"),
                pageText: "",
                hasPasswordField: true
            ),
            BrowserStatusText.loginRequired
        )
        XCTAssertEqual(
            BrowserPageStatusClassifier.status(
                url: URL(string: "https://fltops-portal.ups.com/report"),
                pageText: "Unable to load report, please close this tab and try again.",
                hasPasswordField: false
            ),
            BrowserStatusText.unableToLoadReport
        )

        let viewModel = BrowserViewModel()
        viewModel.statusMessage = BrowserStatusText.loading
        XCTAssertFalse(viewModel.statusIsError)
        viewModel.statusMessage = BrowserStatusText.pageLoaded
        XCTAssertFalse(viewModel.statusIsError)
        viewModel.statusMessage = BrowserStatusText.loginRequired
        XCTAssertFalse(viewModel.statusIsError)
        viewModel.statusMessage = BrowserStatusText.networkError
        XCTAssertTrue(viewModel.statusIsError)
        viewModel.statusMessage = BrowserStatusText.unableToLoadReport
        XCTAssertTrue(viewModel.statusIsError)

        let projectRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let browserSource = try String(
            contentsOf: projectRoot.appendingPathComponent("TripDataHub/Views/BrowserTabView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(browserSource.contains("minHeight: 30, maxHeight: 30"))
        XCTAssertTrue(browserSource.contains("Text(viewModel.statusMessage)\n                .font(.footnote)"))
        XCTAssertTrue(browserSource.contains("return colorScheme == .dark ? .white : .secondary"))
        XCTAssertTrue(browserSource.contains("if viewModel.statusIsError"))
        XCTAssertTrue(browserSource.contains("return .red"))
        XCTAssertTrue(browserSource.contains("BrowserStatusBar(viewModel: browserViewModel)"))
        XCTAssertTrue(browserSource.contains("BrowserStatusBar(viewModel: viewModel)"))
        XCTAssertFalse(browserSource.contains("Connected via Zscaler"))
    }

    func test_browserPerfInstrumentationCapturesInteractionAndDebouncedStructuralMutation() throws {
        let projectRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let webViewSource = try String(
            contentsOf: projectRoot.appendingPathComponent("TripDataHub/Views/BrowserWebView.swift"),
            encoding: .utf8
        )

        for requiredHook in [
            "window.addEventListener('resize'",
            "window.visualViewport.addEventListener(",
            "window.addEventListener('focus'",
            "window.addEventListener('blur'",
            "document.addEventListener('visibilitychange'",
            "'pointer/touch interaction'",
            "new MutationObserver(mutations =>"
        ] {
            XCTAssertTrue(webViewSource.contains(requiredHook), "missing BrowserPerf hook: \(requiredHook)")
        }
        XCTAssertTrue(webViewSource.contains("}, 250);"), "DOM mutation logging must be debounced")
        XCTAssertTrue(webViewSource.contains("currentSignature !== lastMutationSignature"))
        XCTAssertTrue(webViewSource.contains("trip_information_<redacted>.html"))
        XCTAssertTrue(webViewSource.contains("bodyCharacterCount: bodyText.length"))
        XCTAssertFalse(webViewSource.contains("Waiting for Zscaler"))
        XCTAssertFalse(webViewSource.contains("Zscaler slow"))
    }

    func test_debugFocusPulseUsesOneUIKitMethodAndDoesNotAddProductionWorkaround() throws {
        let projectRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let browserViewSource = try String(
            contentsOf: projectRoot.appendingPathComponent("TripDataHub/Views/BrowserTabView.swift"),
            encoding: .utf8
        )
        let webViewSource = try String(
            contentsOf: projectRoot.appendingPathComponent("TripDataHub/Views/BrowserWebView.swift"),
            encoding: .utf8
        )
        let viewModelSource = try String(
            contentsOf: projectRoot.appendingPathComponent("TripDataHub/ViewModels/BrowserViewModel.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(browserViewSource.contains("Diagnostic Focus Pulse"))
        XCTAssertTrue(browserViewSource.contains("viewModel.sendDiagnosticFocusPulse()"))
        XCTAssertTrue(webViewSource.contains("method=becomeFirstResponder"))
        XCTAssertTrue(webViewSource.contains("let accepted = popup.becomeFirstResponder()"))
        XCTAssertTrue(viewModelSource.contains("#if DEBUG\n    func sendDiagnosticFocusPulse()"))
        XCTAssertFalse(webViewSource.contains("window.focus()"))
        XCTAssertFalse(webViewSource.contains("document.body.focus()"))
        XCTAssertFalse(webViewSource.contains("dispatchEvent(new TouchEvent"))
    }

    func test_browserResetUsesDedicatedEraserAndCentralAlertOnSharedPhonePadView() throws {
        let projectRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let browserSource = try String(
            contentsOf: projectRoot.appendingPathComponent("TripDataHub/Views/BrowserTabView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(browserSource.contains("Image(systemName: \"eraser.fill\")"))
        XCTAssertTrue(
            browserSource.contains(
                "Image(systemName: \"eraser.fill\")\n                    .foregroundStyle(.primary)"
            )
        )
        XCTAssertTrue(browserSource.contains(".alert(\"Reset Browser?\""))
        XCTAssertTrue(
            browserSource.contains("This will clear the in-app browser session and require you to sign in again.")
        )
        XCTAssertTrue(browserSource.contains("Button(\"Cancel\", role: .cancel)"))
        XCTAssertTrue(browserSource.contains("Button(\"Reset\", role: .destructive)"))
        XCTAssertFalse(browserSource.contains(".confirmationDialog("))
        XCTAssertFalse(browserSource.contains("ellipsis.circle"))
        XCTAssertFalse(browserSource.contains("Open Safari View"))
        XCTAssertFalse(BrowserStatusText.unableToLoadReport.contains("red eraser icon"))
        XCTAssertTrue(BrowserStatusText.unableToLoadReport.contains("using the eraser icon"))
    }

    func test_T29_pendingImportNilDismissesAllThreePresentersWithoutExplicitDismiss() throws {
        XCTAssertFalse(
            ImportPreviewPresentationPolicy.browserPreviewIsPresented(
                pendingImportID: nil,
                presentsImportPreview: true
            ),
            "BrowserTabView must close its nested preview when pendingImport clears"
        )
        XCTAssertFalse(
            ImportPreviewPresentationPolicy.externalPreviewIsPresented(
                pendingImportID: nil,
                browserIsPresented: false
            ),
            "RootTabView must close its external-open preview when pendingImport clears"
        )
        XCTAssertFalse(
            ImportPreviewPresentationPolicy.externalPreviewIsPresented(
                pendingImportID: nil,
                browserIsPresented: false
            ),
            "iPadOperationalWorkspaceView must close its external-open preview when pendingImport clears"
        )

        let projectRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let browserSource = try String(
            contentsOf: projectRoot.appendingPathComponent("TripDataHub/Views/BrowserTabView.swift"),
            encoding: .utf8
        )
        let rootSource = try String(
            contentsOf: projectRoot.appendingPathComponent("TripDataHub/Views/RootTabView.swift"),
            encoding: .utf8
        )
        let iPadSource = try String(
            contentsOf: projectRoot.appendingPathComponent("TripDataHub/Views/iPad/iPadOperationalWorkspaceView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(browserSource.contains("ImportPreviewPresentationPolicy.browserPreviewIsPresented"))
        XCTAssertTrue(rootSource.contains("ImportPreviewPresentationPolicy.externalPreviewIsPresented"))
        XCTAssertTrue(iPadSource.contains("ImportPreviewPresentationPolicy.externalPreviewIsPresented"))
        XCTAssertTrue(rootSource.contains("browserIsPresented: showingBrowser"))
        XCTAssertTrue(iPadSource.contains("browserIsPresented: showingBrowser"))
    }

    func test_T29_browserOwnsPreviewWhileBrowserSheetIsPresentedOnBothPlatforms() {
        let pendingID = UUID()
        XCTAssertTrue(
            ImportPreviewPresentationPolicy.browserPreviewIsPresented(
                pendingImportID: pendingID,
                presentsImportPreview: true
            )
        )
        XCTAssertFalse(
            ImportPreviewPresentationPolicy.externalPreviewIsPresented(
                pendingImportID: pendingID,
                browserIsPresented: true
            ),
            "root and iPad external presenters must stand down while BrowserTabView owns Preview"
        )
    }
}

@MainActor
final class BrowserPopupLifecycleTests: XCTestCase {
    func test_T41_productionFocusAcquisitionRunsOnceAfterNavigationAndAttachment() {
        let viewModel = BrowserViewModel()
        let attachment = PopupAttachmentState()
        var focusedPopupIDs: [ObjectIdentifier] = []
        let coordinator = BrowserWebView.Coordinator(
            viewModel: viewModel,
            popupFocusAcquirer: { popup in
                focusedPopupIDs.append(ObjectIdentifier(popup))
                return true
            },
            popupAttachmentChecker: { _ in attachment.isAttached }
        )
        let popup = WKWebView()
        coordinator.popupWebViews.append(popup)
        viewModel.popupWebView = popup

        coordinator.recordPopupNavigationCompleted(popup)
        XCTAssertTrue(focusedPopupIDs.isEmpty, "navigation alone must not focus an unattached popup")

        attachment.isAttached = true
        coordinator.popupDidAttach(popup)
        coordinator.recordPopupNavigationCompleted(popup)
        coordinator.popupDidAttach(popup)

        XCTAssertEqual(focusedPopupIDs, [ObjectIdentifier(popup)])
    }

    func test_T42_productionFocusStateIsScopedToPopupIdentity() {
        let viewModel = BrowserViewModel()
        var focusedPopupIDs: [ObjectIdentifier] = []
        let coordinator = BrowserWebView.Coordinator(
            viewModel: viewModel,
            javaScriptEvaluator: { _, _, completion in completion(nil) },
            popupFocusAcquirer: { popup in
                focusedPopupIDs.append(ObjectIdentifier(popup))
                return true
            },
            popupAttachmentChecker: { _ in true }
        )
        let firstPopup = WKWebView()
        coordinator.popupWebViews.append(firstPopup)
        viewModel.popupWebView = firstPopup
        coordinator.recordPopupNavigationCompleted(firstPopup)
        coordinator.closePopups()

        let secondPopup = WKWebView()
        coordinator.popupWebViews.append(secondPopup)
        viewModel.popupWebView = secondPopup
        coordinator.recordPopupNavigationCompleted(secondPopup)

        XCTAssertEqual(
            focusedPopupIDs,
            [ObjectIdentifier(firstPopup), ObjectIdentifier(secondPopup)]
        )
    }

    func test_T43_failedProductionFocusAcquisitionIsNonFatalAndDoesNotRetry() {
        let viewModel = BrowserViewModel()
        var focusAttempts = 0
        let coordinator = BrowserWebView.Coordinator(
            viewModel: viewModel,
            popupFocusAcquirer: { _ in
                focusAttempts += 1
                return false
            },
            popupAttachmentChecker: { _ in true }
        )
        let parent = WKWebView()
        let popup = WKWebView()
        popup.navigationDelegate = coordinator
        popup.uiDelegate = coordinator
        coordinator.popupWebViews.append(popup)
        coordinator.popupParents[ObjectIdentifier(popup)] = parent
        viewModel.popupWebView = popup

        coordinator.recordPopupNavigationCompleted(popup)
        coordinator.recordPopupNavigationCompleted(popup)
        coordinator.popupDidAttach(popup)

        XCTAssertEqual(focusAttempts, 1)
        XCTAssertEqual(coordinator.popupWebViews.count, 1)
        XCTAssertTrue(coordinator.popupParents[ObjectIdentifier(popup)] === parent)
        XCTAssertTrue(viewModel.popupWebView === popup)
        XCTAssertTrue(popup.navigationDelegate === coordinator)
        XCTAssertTrue(popup.uiDelegate === coordinator)
    }

    func test_T44_mainBrowserNeverReceivesPopupFocusAcquisition() {
        let viewModel = BrowserViewModel()
        var focusAttempts = 0
        let coordinator = BrowserWebView.Coordinator(
            viewModel: viewModel,
            popupFocusAcquirer: { _ in
                focusAttempts += 1
                return true
            },
            popupAttachmentChecker: { _ in true }
        )
        let mainBrowser = WKWebView()
        viewModel.webView = mainBrowser

        coordinator.recordPopupNavigationCompleted(mainBrowser)
        coordinator.popupDidAttach(mainBrowser)

        XCTAssertEqual(focusAttempts, 0)
        XCTAssertTrue(viewModel.webView === mainBrowser)
    }

    #if DEBUG
    func test_diagnosticFocusPulseLeavesPopupLifecycleUntouched() {
        let context = makeContext()

        context.viewModel.sendDiagnosticFocusPulse()

        XCTAssertEqual(context.coordinator.popupWebViews.count, context.popups.count)
        XCTAssertEqual(context.coordinator.popupParents.count, context.popups.count)
        XCTAssertTrue(context.viewModel.popupWebView === context.popups.last)
        XCTAssertTrue(context.popups.allSatisfy { $0.navigationDelegate === context.coordinator })
        XCTAssertTrue(context.popups.allSatisfy { $0.uiDelegate === context.coordinator })
    }
    #endif

    func test_T28_httpsSuccessHandsOffDataBeforeClearingEveryPopupReference() {
        let context = makeContext()
        let data = Data("%PDF synthetic".utf8)

        context.coordinator.handleDownloadedPDFResult(
            data: data,
            response: nil,
            error: nil,
            sourceFileName: "trip-a.pdf"
        )

        XCTAssertEqual(context.recorder.receivedData, [data])
        XCTAssertEqual(context.recorder.sourceFileNames, ["trip-a.pdf"])
        assertPopupStateIsClean(context)
    }

    func test_T28_fetchErrorClearsEveryPopupReference() {
        let context = makeContext()

        context.coordinator.handleDownloadedPDFResult(
            data: nil,
            response: nil,
            error: PopupTestError.expected,
            sourceFileName: "trip-a.pdf"
        )

        XCTAssertTrue(context.viewModel.errorMessage?.contains("PDF fetch failed") == true)
        XCTAssertTrue(context.recorder.receivedData.isEmpty)
        assertPopupStateIsClean(context)
    }

    func test_T28_emptyDownloadClearsEveryPopupReference() {
        let context = makeContext()
        let response = HTTPURLResponse(
            url: URL(string: "https://example.invalid/report.pdf")!,
            statusCode: 204,
            httpVersion: nil,
            headerFields: nil
        )

        context.coordinator.handleDownloadedPDFResult(
            data: Data(),
            response: response,
            error: nil,
            sourceFileName: "trip-a.pdf"
        )

        XCTAssertEqual(context.viewModel.errorMessage, "Empty response (HTTP 204)")
        assertPopupStateIsClean(context)
    }

    func test_T28_blobBase64FailureClearsEveryPopupReference() {
        let context = makeContext()

        context.coordinator.handleBlobExtractionResult(.success("OK:%%%"))

        XCTAssertTrue(context.viewModel.errorMessage?.contains("Base64 decode failed") == true)
        assertPopupStateIsClean(context)
    }

    func test_T28_blobJavaScriptFailuresClearEveryPopupReference() {
        var context = makeContext()
        context.coordinator.handleBlobExtractionResult(.success(42))
        XCTAssertTrue(context.viewModel.errorMessage?.contains("Invalid JS return value") == true)
        assertPopupStateIsClean(context)

        context = makeContext()
        context.coordinator.handleBlobExtractionResult(.success("ERR:fetch failed"))
        XCTAssertTrue(context.viewModel.errorMessage?.contains("JS blob fetch error") == true)
        assertPopupStateIsClean(context)

        context = makeContext()
        context.coordinator.handleBlobExtractionResult(.failure(PopupTestError.expected))
        XCTAssertTrue(context.viewModel.errorMessage?.contains("JS execution failed") == true)
        assertPopupStateIsClean(context)
    }

    func test_T28_browserResetUsesCoordinatorTeardown() {
        let context = makeContext()
        context.viewModel.webView = WKWebView()

        context.viewModel.prepareForBrowserReset()

        XCTAssertNil(context.viewModel.webView)
        XCTAssertEqual(context.viewModel.statusMessage, "Resetting browser...")
        assertPopupStateIsClean(context)
    }

    func test_T28_viewRequestedCloseAndWebViewDidCloseUseCoordinatorTeardown() {
        var context = makeContext()

        context.viewModel.teardownPopups()

        assertPopupStateIsClean(context)

        context = makeContext()
        context.coordinator.webViewDidClose(context.popups[0])

        assertPopupStateIsClean(context)
    }

    func test_T31_teardownExecutesWindowCloseExactlyOncePerPopupBeforeNativeCleanup() {
        let context = makeContext()

        context.coordinator.closePopups()

        XCTAssertEqual(context.javaScriptRecorder.scripts.count, context.popups.count)
        XCTAssertEqual(Set(context.javaScriptRecorder.scripts.map(\.script)), ["window.close()"])
        XCTAssertEqual(
            Set(context.javaScriptRecorder.scripts.map(\.webViewID)).count,
            context.popups.count,
            "each popup context must receive exactly one window.close()"
        )
        assertPopupStateIsClean(context)
    }

    func test_T31_windowCloseCallbackTimeoutStillCompletesNativeCleanup() async {
        let context = makeContext(completesWindowClose: false)

        context.coordinator.closePopups()

        XCTAssertFalse(context.coordinator.popupWebViews.isEmpty)
        try? await Task.sleep(nanoseconds: 800_000_000)
        assertPopupStateIsClean(context)
    }

    func test_T31_popupCreatedDuringTeardownRemainsTrackedAfterCapturedTargetsFinalize() throws {
        let viewModel = BrowserViewModel()
        var firstPopupCloseCompletion: (@MainActor (Error?) -> Void)?
        let coordinator = BrowserWebView.Coordinator(
            viewModel: viewModel,
            javaScriptEvaluator: { _, _, completion in
                firstPopupCloseCompletion = completion
            }
        )
        let firstParent = WKWebView()
        let firstPopup = WKWebView()
        firstPopup.navigationDelegate = coordinator
        firstPopup.uiDelegate = coordinator
        coordinator.popupWebViews.append(firstPopup)
        coordinator.popupParents[ObjectIdentifier(firstPopup)] = firstParent
        viewModel.popupWebView = firstPopup

        coordinator.closePopups()
        let completion = try XCTUnwrap(firstPopupCloseCompletion)

        let secondParent = WKWebView()
        let secondPopup = WKWebView()
        secondPopup.navigationDelegate = coordinator
        secondPopup.uiDelegate = coordinator
        coordinator.popupWebViews.append(secondPopup)
        coordinator.popupParents[ObjectIdentifier(secondPopup)] = secondParent
        viewModel.popupWebView = secondPopup

        completion(nil)

        XCTAssertEqual(coordinator.popupWebViews.count, 1)
        XCTAssertTrue(coordinator.popupWebViews.first === secondPopup)
        XCTAssertNil(coordinator.popupParents[ObjectIdentifier(firstPopup)])
        XCTAssertTrue(coordinator.popupParents[ObjectIdentifier(secondPopup)] === secondParent)
        XCTAssertTrue(viewModel.popupWebView === secondPopup)
        XCTAssertNil(firstPopup.navigationDelegate)
        XCTAssertNil(firstPopup.uiDelegate)
        XCTAssertTrue(secondPopup.navigationDelegate === coordinator)
        XCTAssertTrue(secondPopup.uiDelegate === coordinator)
    }

    private func makeContext(completesWindowClose: Bool = true) -> PopupContext {
        let viewModel = BrowserViewModel()
        let recorder = PopupPDFDataRecorder()
        let javaScriptRecorder = PopupJavaScriptRecorder()
        let coordinator = BrowserWebView.Coordinator(
            viewModel: viewModel,
            pdfDataHandler: { data, sourceFileName in
                recorder.receivedData.append(data)
                recorder.sourceFileNames.append(sourceFileName)
            },
            javaScriptEvaluator: { webView, script, completion in
                javaScriptRecorder.scripts.append(
                    (webViewID: ObjectIdentifier(webView), script: script)
                )
                if completesWindowClose {
                    completion(nil)
                }
            }
        )
        let parent = WKWebView()
        let firstPopup = WKWebView()
        let secondPopup = WKWebView()
        for popup in [firstPopup, secondPopup] {
            popup.navigationDelegate = coordinator
            popup.uiDelegate = coordinator
            coordinator.popupWebViews.append(popup)
            coordinator.popupParents[ObjectIdentifier(popup)] = parent
        }
        viewModel.popupWebView = secondPopup
        return PopupContext(
            coordinator: coordinator,
            viewModel: viewModel,
            recorder: recorder,
            javaScriptRecorder: javaScriptRecorder,
            popups: [firstPopup, secondPopup]
        )
    }

    private func assertPopupStateIsClean(
        _ context: PopupContext,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(context.coordinator.popupWebViews.isEmpty, file: file, line: line)
        XCTAssertTrue(context.coordinator.popupParents.isEmpty, file: file, line: line)
        XCTAssertNil(context.viewModel.popupWebView, file: file, line: line)
        for popup in context.popups {
            XCTAssertNil(popup.navigationDelegate, file: file, line: line)
            XCTAssertNil(popup.uiDelegate, file: file, line: line)
        }
    }

    private struct PopupContext {
        let coordinator: BrowserWebView.Coordinator
        let viewModel: BrowserViewModel
        let recorder: PopupPDFDataRecorder
        let javaScriptRecorder: PopupJavaScriptRecorder
        let popups: [WKWebView]
    }

    private final class PopupPDFDataRecorder {
        var receivedData: [Data] = []
        var sourceFileNames: [String?] = []
    }

    private final class PopupJavaScriptRecorder {
        var scripts: [(webViewID: ObjectIdentifier, script: String)] = []
    }

    private final class PopupAttachmentState {
        var isAttached = false
    }

    private enum PopupTestError: Error {
        case expected
    }
}
