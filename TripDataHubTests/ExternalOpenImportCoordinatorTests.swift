import XCTest
import JavaScriptCore
import WebKit
import CryptoKit
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
    func test_validTwoLegTripPresentationIncludesSummaryAndEveryLeg() {
        let legs = [
            previewLeg(
                sequence: 1,
                from: "ANC",
                to: "NRT",
                departure: "2026-09-12 08:00",
                arrival: "2026-09-13 11:30"
            ),
            previewLeg(
                sequence: 2,
                from: "NRT",
                to: "ANC",
                departure: "2026-09-15 16:00",
                arrival: "2026-09-15 08:30"
            )
        ]

        let presentation = ImportPreviewTripPresentation(
            tripID: "12345",
            fallbackTripDate: "12Sep2026",
            legs: legs
        )

        XCTAssertEqual(presentation.tripID, "12345")
        XCTAssertEqual(presentation.dateRangeText, "Sep 12 – Sep 15, 2026")
        XCTAssertEqual(presentation.legCountText, "2 legs")
        XCTAssertEqual(presentation.legs.map(\.id), legs.map(\.id))
        XCTAssertEqual(
            presentation.daySections.flatMap(\.legs).map(\.id),
            legs.map(\.id),
            "the two-leg validity boundary must render both legs"
        )
    }

    func test_longTripPresentationDoesNotTruncateOrDeduplicateLegs() {
        let legs = (1...12).map { sequence in
            previewLeg(
                sequence: sequence,
                from: "A\(sequence)",
                to: "B\(sequence)",
                departure: String(format: "2026-09-%02d 08:00", 10 + sequence),
                arrival: String(format: "2026-09-%02d 10:00", 10 + sequence)
            )
        }

        let presentation = ImportPreviewTripPresentation(
            tripID: "LONG01",
            fallbackTripDate: "11Sep2026",
            legs: legs
        )

        XCTAssertEqual(presentation.legCountText, "12 legs")
        XCTAssertEqual(presentation.legs.count, 12)
        XCTAssertEqual(presentation.daySections.flatMap(\.legs).map(\.id), legs.map(\.id))
    }

    func test_previewHidesRoutinePDFStatusButKeepsImportFailureVisible() {
        XCTAssertNil(
            ImportPreviewStatusPolicy.actionableMessage(
                "Parsed CrewAccess PDF. Review and confirm import."
            )
        )
        XCTAssertEqual(
            ImportPreviewStatusPolicy.actionableMessage("Import failed: storage unavailable."),
            "Import failed: storage unavailable."
        )
    }

    func test_previewActionsStillCallExistingImportAndCancelPaths() throws {
        let projectRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: projectRoot.appendingPathComponent("TripDataHub/Views/ImportPreviewView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("confirmPendingImport(expectedReplacementIDs: [])"))
        XCTAssertTrue(source.contains("await viewModel.discardPendingImport()"))
        XCTAssertTrue(source.contains("primaryTitle: replacements.isEmpty ? \"Import\" : \"Replace Trip\""))
        XCTAssertTrue(source.contains("Button(\"Cancel\", action: onCancel)"))
    }

    func test_incompleteImportCancelDismissesAlertWithoutRequestingRetry() {
        let viewModel = BrowserViewModel()
        var retryRequestCount = 0
        viewModel.requestAutoPrintRetry = {
            retryRequestCount += 1
            return true
        }
        viewModel.presentIncompleteImportFailure()

        viewModel.cancelIncompleteImport()

        XCTAssertNil(viewModel.incompleteImportFailure)
        XCTAssertFalse(viewModel.isAutoPrintRetryInProgress)
        XCTAssertFalse(viewModel.isImportingCrewAccessTrip)
        XCTAssertEqual(retryRequestCount, 0)
        XCTAssertEqual(viewModel.statusMessage, "CrewAccess import canceled.")
    }

    func test_importingPresentationObscuresPDFContentWithoutReleasingPopup() throws {
        let viewModel = BrowserViewModel()
        let popup = WKWebView()
        viewModel.popupWebView = popup

        viewModel.beginCrewAccessImportingPresentation()

        XCTAssertTrue(viewModel.isImportingCrewAccessTrip)
        XCTAssertTrue(viewModel.popupWebView === popup)
        XCTAssertEqual(viewModel.statusMessage, "Importing Trip…")

        let projectRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let browserSource = try String(
            contentsOf: projectRoot.appendingPathComponent("TripDataHub/Views/BrowserTabView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(browserSource.contains("ExistingWebViewWrapper(webView: webView)"))
        XCTAssertTrue(browserSource.contains("if viewModel.isImportingCrewAccessTrip"))
        XCTAssertTrue(browserSource.contains("Text(\"Importing Trip…\")"))
    }

    func test_incompleteImportAlertUsesProductionCopyAndActions() throws {
        let projectRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let browserSource = try String(
            contentsOf: projectRoot.appendingPathComponent("TripDataHub/Views/BrowserTabView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(browserSource.contains("Unable to Import Trip"))
        XCTAssertTrue(browserSource.contains("The trip data could not be loaded completely. Please try again with a stable network connection."))
        XCTAssertTrue(browserSource.contains("Button(\"Try Again\")"))
        XCTAssertTrue(browserSource.contains("Button(\"Cancel\", role: .cancel)"))
    }

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

    private func previewLeg(
        sequence: Int,
        from departureAirport: String,
        to arrivalAirport: String,
        departure: String,
        arrival: String
    ) -> TripLeg {
        TripLeg(
            payPeriod: "CA26-09-PREVIEW",
            pairing: "PREVIEW",
            leg: sequence,
            flight: String(100 + sequence),
            depAirport: departureAirport,
            depLocal: departure,
            arrAirport: arrivalAirport,
            arrLocal: arrival,
            status: "",
            block: "2:00"
        )
    }
}

@MainActor
final class BrowserPopupLifecycleTests: XCTestCase {
    private final class FixedURLWebView: WKWebView {
        var fixedURL: URL?

        override var url: URL? {
            fixedURL ?? super.url
        }
    }

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

    func test_incompleteImportRetainsCurrentPopupForUserDecision() {
        let viewModel = BrowserViewModel()
        let popup = WKWebView()
        var importAttemptCount = 0
        let coordinator = BrowserWebView.Coordinator(
            viewModel: viewModel,
            pdfDataHandler: { _, _, completion in
                importAttemptCount += 1
                completion(.incompleteTrip)
            },
            javaScriptEvaluator: { _, _, completion in completion(nil) }
        )
        coordinator.popupWebViews = [popup]
        viewModel.popupWebView = popup
        viewModel.beginCrewAccessImportingPresentation()

        coordinator.handleDownloadedPDFResult(
            data: Data("%PDF incomplete".utf8),
            response: nil,
            error: nil,
            sourceFileName: "incomplete.pdf"
        )
        coordinator.handleDownloadedPDFResult(
            data: Data("%PDF duplicate-callback".utf8),
            response: nil,
            error: nil,
            sourceFileName: "duplicate.pdf"
        )

        XCTAssertEqual(importAttemptCount, 1)
        XCTAssertTrue(viewModel.isImportingCrewAccessTrip)
        XCTAssertEqual(coordinator.popupWebViews.count, 1)
        XCTAssertTrue(coordinator.popupWebViews.first === popup)
        XCTAssertTrue(viewModel.popupWebView === popup)
    }

    func test_retryReentersExistingAutoPrintPathAndRejectsConcurrentRetry() {
        let viewModel = BrowserViewModel()
        let popup = FixedURLWebView()
        popup.fixedURL = URL(
            string: "https://4d8e06f5.isolation.zscaler.com/profile/00000000-0000-4000-8000-000000000000/zpa-session"
        )
        var readinessEvaluationCount = 0
        let coordinator = BrowserWebView.Coordinator(
            viewModel: viewModel,
            pdfDataHandler: { _, _, completion in completion(.incompleteTrip) },
            javaScriptEvaluator: { _, _, completion in completion(nil) }
        )
        coordinator.autoPrintStageOneReadinessEvaluator = { _, script, completion in
            XCTAssertEqual(script, CrewAccessPageProbe.probeExpression)
            readinessEvaluationCount += 1
            completion(nil, nil)
        }
        // A retry now takes a read-only dialog census before it may click Print again.
        coordinator.autoPrintStageTwoReadinessEvaluator = { _, _, completion in
            completion(["diagnostic": ["dialogCount": 0, "qualifyingDialogCount": 0]], nil)
        }
        coordinator.popupWebViews = [popup]
        viewModel.popupWebView = popup
        viewModel.beginCrewAccessImportingPresentation()
        coordinator.handleDownloadedPDFResult(
            data: Data("%PDF incomplete".utf8),
            response: nil,
            error: nil,
            sourceFileName: "attempt-1.pdf"
        )
        let key = ObjectIdentifier(popup)
        coordinator.autoPrintStageOneAttemptedPopupIDs.insert(key)
        coordinator.autoPrintStageTwoAttemptedPopupIDs.insert(key)

        XCTAssertTrue(coordinator.retryCrewAccessAutoPrintIfPossible())
        XCTAssertFalse(coordinator.retryCrewAccessAutoPrintIfPossible())
        XCTAssertTrue(viewModel.isImportingCrewAccessTrip)
        XCTAssertEqual(readinessEvaluationCount, 1)
        XCTAssertTrue(coordinator.isAutoPrintRetryInFlight)
        XCTAssertFalse(coordinator.autoPrintStageOneAttemptedPopupIDs.contains(key))
        XCTAssertFalse(coordinator.autoPrintStageTwoAttemptedPopupIDs.contains(key))
        XCTAssertEqual(
            coordinator.autoPrintStageOneSettleDelayNanoseconds,
            CrewAccessAutoPrint.stageOneSettleDelayNanoseconds
        )

        coordinator.closePopups()
    }

    func test_successfulRetryCompletesNormallyAndCleansUpPopup() {
        let viewModel = BrowserViewModel()
        let popup = FixedURLWebView()
        popup.fixedURL = URL(
            string: "https://4d8e06f5.isolation.zscaler.com/profile/00000000-0000-4000-8000-000000000000/zpa-session"
        )
        var importResults = [CrewAccessPDFImportResult.incompleteTrip, .previewReady]
        var importAttemptCount = 0
        let coordinator = BrowserWebView.Coordinator(
            viewModel: viewModel,
            pdfDataHandler: { _, _, completion in
                importAttemptCount += 1
                completion(importResults.removeFirst())
            },
            javaScriptEvaluator: { _, _, completion in completion(nil) }
        )
        coordinator.autoPrintStageOneReadinessEvaluator = { _, _, completion in
            completion(nil, nil)
        }
        // A retry now takes a read-only dialog census before it may click Print again.
        coordinator.autoPrintStageTwoReadinessEvaluator = { _, _, completion in
            completion(["diagnostic": ["dialogCount": 0, "qualifyingDialogCount": 0]], nil)
        }
        coordinator.popupWebViews = [popup]
        viewModel.popupWebView = popup
        viewModel.beginCrewAccessImportingPresentation()

        coordinator.handleDownloadedPDFResult(
            data: Data("%PDF incomplete".utf8),
            response: nil,
            error: nil,
            sourceFileName: "attempt-1.pdf"
        )
        XCTAssertTrue(viewModel.popupWebView === popup)

        let key = ObjectIdentifier(popup)
        coordinator.autoPrintStageOneAttemptedPopupIDs.insert(key)
        coordinator.autoPrintStageTwoAttemptedPopupIDs.insert(key)
        XCTAssertTrue(coordinator.retryCrewAccessAutoPrintIfPossible())

        coordinator.handleDownloadedPDFResult(
            data: Data("%PDF complete".utf8),
            response: nil,
            error: nil,
            sourceFileName: "attempt-2.pdf"
        )

        XCTAssertEqual(importAttemptCount, 2)
        XCTAssertFalse(coordinator.isAutoPrintRetryInFlight)
        XCTAssertFalse(viewModel.isImportingCrewAccessTrip)
        XCTAssertTrue(coordinator.popupWebViews.isEmpty)
        XCTAssertNil(viewModel.popupWebView)
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
        await waitForPopupStateToBecomeClean(context)
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
            pdfDataHandler: { data, sourceFileName, completion in
                recorder.receivedData.append(data)
                recorder.sourceFileNames.append(sourceFileName)
                completion(.previewReady)
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

    private func waitForPopupStateToBecomeClean(
        _ context: PopupContext,
        timeout: TimeInterval = 2
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if popupStateIsClean(context) {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func popupStateIsClean(_ context: PopupContext) -> Bool {
        context.coordinator.popupWebViews.isEmpty
            && context.coordinator.popupParents.isEmpty
            && context.viewModel.popupWebView == nil
            && context.popups.allSatisfy {
                $0.navigationDelegate == nil && $0.uiDelegate == nil
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


// MARK: - CrewAccess auto-print production regressions
//
// The read-only probe discovers eligibility; the guarded Stage 1 and Stage 2 scripts are the only
// page-mutating operations and must remain present in Release with exactly one `.click()` each.

final class CrewAccessAutoPrintProbeTests: XCTestCase {

    private final class FixedURLWebView: WKWebView {
        var fixedURL: URL?

        override var url: URL? {
            fixedURL ?? super.url
        }
    }

    private func projectFile(_ relativePath: String) throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: projectRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func browserWebViewSource() throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: projectRoot.appendingPathComponent("TripDataHub/Views/BrowserWebView.swift"),
            encoding: .utf8
        )
    }

    /// `true` for every source line that sits inside an active `#if DEBUG` region.
    private func debugRegionFlags(for source: String) -> [Bool] {
        var stack: [Bool] = []
        var debugDepth = 0
        var flags: [Bool] = []
        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if") {
                let introducesDebug = trimmed == "#if DEBUG"
                stack.append(introducesDebug)
                if introducesDebug { debugDepth += 1 }
            } else if trimmed == "#else" || trimmed.hasPrefix("#elseif") {
                if stack.last == true {
                    debugDepth -= 1
                    stack[stack.count - 1] = false
                }
            } else if trimmed.hasPrefix("#endif") {
                if stack.popLast() == true { debugDepth -= 1 }
            }
            flags.append(debugDepth > 0)
        }
        return flags
    }

    private func stageOneInvocationSource(from source: String) throws -> String {
        let startMarker = "    static let invocationScript = #\"\"\"\n"
        let endMarker = "    \"\"\"#\n"
        let start = try XCTUnwrap(source.range(of: startMarker)?.lowerBound)
        let suffix = source[start...]
        let end = try XCTUnwrap(suffix.range(of: endMarker)?.upperBound)
        return String(source[start..<end])
    }

    @MainActor
    func test_productionStageOneSettleDelayResolvesToFourSeconds() {
        let coordinator = BrowserWebView.Coordinator(
            viewModel: BrowserViewModel(),
            javaScriptEvaluator: { _, _, completion in completion(nil) }
        )

        XCTAssertEqual(CrewAccessAutoPrint.stageOneSettleDelayNanoseconds, 4_000_000_000)
        XCTAssertEqual(
            coordinator.autoPrintStageOneSettleDelayNanoseconds,
            CrewAccessAutoPrint.stageOneSettleDelayNanoseconds
        )
    }

    func test_stageOneTimerAndStartLogUseTheSameCapturedPerRunDelay() throws {
        let source = try browserWebViewSource()
        let start = try XCTUnwrap(
            source.range(of: "private func startAutoPrintStageOneSettleDelay(")?.lowerBound
        )
        let end = try XCTUnwrap(
            source.range(
                of: "private func runAutoPrintStageOneSettleDelayCheck(",
                range: start..<source.endIndex
            )?.lowerBound
        )
        let settleFunction = String(source[start..<end])

        XCTAssertEqual(
            settleFunction.components(
                separatedBy: "let delay = autoPrintStageOneSettleDelayNanoseconds"
            ).count - 1,
            1,
            "each run must snapshot the configured delay exactly once"
        )
        XCTAssertTrue(
            settleFunction.contains(
                "configuredMilliseconds=\\(delay / 1_000_000, privacy: .public)"
            ),
            "the start log must report the same captured delay used by the run"
        )
        XCTAssertTrue(
            settleFunction.contains("Task.sleep(nanoseconds: delay)"),
            "the settle timer must use that same captured delay"
        )
        XCTAssertEqual(
            settleFunction.components(
                separatedBy: "CrewAccessAutoPrint.stageOneSettleDelayNanoseconds"
            ).count - 1,
            0,
            "the running task must not re-read the canonical delay after it is captured"
        )
    }

    /// Requirement 14: the auto-print feature ships. Every part of the proven path must compile
    /// into Release, not just into DEBUG.
    func test_autoPrintProductionPathIsPresentInReleaseBuilds() throws {
        let source = try browserWebViewSource()
        let lines = source.components(separatedBy: "\n")
        let flags = debugRegionFlags(for: source)
        XCTAssertEqual(lines.count, flags.count)

        let mustShip = [
            "enum CrewAccessAutoPrint",
            "static let stageOneSettleDelayNanoseconds",
            "static let stageTwoReadinessOffsetsNanoseconds",
            "static func rejectionReason",
            "static func settledRejectionReason",
            "static func stageTwoRejectionReason",
            "static func isExactZscalerSessionURL",
            "static func isSameZscalerSession",
            "static let invocationScript",
            "static let stageTwoReadinessScript",
            "static let stageTwoInvocationScript",
            "candidates[0].click();",
            "submitButtons[0].click();",
            "private var popupGenerations",
            "private func beginCrewAccessAutoPrintSamplingIfNeeded",
            "func beginCrewAccessProbe",
            "private func scheduleCrewAccessProbeResample",
            "func evaluateAutoPrintStageOneEligibility",
            "private func startAutoPrintStageOneSettleDelay",
            "private func runAutoPrintStageOneSettleDelayCheck",
            "private func invokeAutoPrintStageOne",
            "func handleAutoPrintStageOneExecutionResult",
            "private func startAutoPrintStageTwoReadinessSchedule",
            "private func scheduleAutoPrintStageTwoReadinessSample",
            "func evaluateAutoPrintStageTwoReadiness",
            "private func invokeAutoPrintStageTwo",
            "func cancelAutoPrintStageOneSettleDelay",
            "func cancelAutoPrintStageTwoReadinessSchedule"
        ]
        for needle in mustShip {
            let matches = lines.indices.filter { lines[$0].contains(needle) }
            XCTAssertFalse(matches.isEmpty, "auto-print production symbol is missing: \(needle)")
            for index in matches {
                XCTAssertFalse(
                    flags[index],
                    "\(needle) must ship in Release, not sit inside #if DEBUG (line \(index + 1))"
                )
            }
        }
    }

    /// Requirement 15: the experiment-only forensics are gone. They were built to answer "does
    /// this work at all"; that question is answered, so they are deleted rather than gated — the
    /// file now contains no `#if DEBUG` at all.
    func test_autoPrintExperimentDiagnosticsAreDeletedNotMerelyGated() throws {
        let source = try browserWebViewSource()

        let retiredSymbols = [
            // The passive trusted-input forensic observer and its bridge.
            "TrustedInput", "trustedInput", "tdhTrustedInput",
            "BrowserTrustedInputMessageRelay", "WKScriptMessageHandler",
            "browserTrustedInputObserverLogger",
            // The per-sample probe dump.
            "browserProbeLogger", "logCrewAccessProbeSample", "describeProbeElement",
            "crewAccessProbeDidFinishCounts", "AutoPrintProbe",
            // Navigation and popup-performance tracing.
            "logNavigationTrace", "logNavigationFailure", "navigationTraceSurface",
            "navigationTypeDescription", "navigationActionDetails", "nextNavigationTraceEventID",
            "PopupPerformanceTrace", "popupPerformanceTraces", "logPopupPerformanceEvent",
            "startPopupPerformanceTrace", "browserPerformanceLogger", "[BrowserPerf]",
            "beginPopupDOMSamplingIfNeeded", "samplePopupDOM", "installPopupPerformanceHooks",
            // Downstream experiment narration and the diagnostic focus pulse.
            "logAutoPrintDownstream", "logMostRecentAutoPrintOutcome", "mostRecentAutoPrintRunID",
            "autoPrintRunIDsByWebView", "performDiagnosticFocusPulse", "requestDiagnosticFocusPulse",
            // Rejected readiness experiments: DOM stability, canvas fingerprinting, mutation counts.
            "reportSnapshot", "canvasFingerprint", "mutationGeneration", "observedMutationCount",
            // The experiment's own vocabulary.
            "CrewAccessDebugAutoPrintExperiment", "AutoPrintExperiment",
            "debugAutoPrint", "DebugAutoPrint"
        ]
        for symbol in retiredSymbols {
            XCTAssertFalse(
                source.contains(symbol),
                "experiment-only code should be deleted, not gated: \(symbol)"
            )
        }

        // Nothing in the browser surface is conditionally compiled any more.
        XCTAssertFalse(
            source.contains("#if DEBUG"),
            "BrowserWebView is now entirely production code"
        )
        for path in ["TripDataHub/ViewModels/BrowserViewModel.swift", "TripDataHub/Views/BrowserTabView.swift"] {
            let other = try projectFile(path)
            for symbol in ["DiagnosticFocusPulse", "requestDiagnosticFocusPulse"] {
                XCTAssertFalse(other.contains(symbol), "\(symbol) must be gone from \(path)")
            }
        }

        // What replaced them: one concise production logger, still naming the two stages.
        XCTAssertTrue(source.contains("category: \"AutoPrint\""))
        XCTAssertTrue(source.contains("stage=1 gate="))
        XCTAssertTrue(source.contains("stage=2 gate="))
        XCTAssertTrue(source.contains("executionResult="))
    }

    func test_autoPrintExperimentSurfaceAllowsOnlyItsGuardedDOMClickAndNoOtherSyntheticInteraction() throws {
        let source = try browserWebViewSource()

        // Two stages, two invocations, both named: Stage 1 drives the toolbar Print button and
        // Stage 2 drives the submit button inside the dialog Stage 1 opens. Nothing else may click.
        let stageOneInvocation = "candidates[0].click();"
        let stageTwoInvocation = "submitButtons[0].click();"
        XCTAssertEqual(
            source.components(separatedBy: stageOneInvocation).count - 1,
            1,
            "Stage 1 may contain exactly one real DOM button invocation"
        )
        XCTAssertEqual(
            source.components(separatedBy: stageTwoInvocation).count - 1,
            1,
            "Stage 2 may contain exactly one real DOM button invocation"
        )
        XCTAssertFalse(
            source
                .replacingOccurrences(of: stageOneInvocation, with: "")
                .replacingOccurrences(of: stageTwoInvocation, with: "")
                .contains(".click()"),
            "no other DOM click is permitted anywhere in BrowserWebView"
        )

        // The experiment invokes the resolved DOM button only. Event fabrication and alternate
        // execution paths remain forbidden.
        for banned in [
            "window.print(",
            "dispatchEvent(",
            "new MouseEvent",
            "new TouchEvent",
            "new PointerEvent",
            ".submit()",
            "requestSubmit",
            "HTMLElement.prototype"
        ] {
            XCTAssertFalse(source.contains(banned), "production auto-print must not introduce \(banned)")
        }

        // Focus workarounds remain forbidden (see the popup focus-acquisition contract).
        XCTAssertFalse(source.contains("window.focus()"))
        XCTAssertFalse(source.contains("document.body.focus()"))

        // Credentials and session storage are never read.
        for banned in ["document.cookie", "localStorage", "sessionStorage", "indexedDB"] {
            XCTAssertFalse(source.contains(banned), "auto-print must not read \(banned)")
        }

        // The invocation helper ships: it is the feature, not an experiment.
        let autoPrintMarker = "enum CrewAccessAutoPrint"
        let autoPrintOffset = try XCTUnwrap(source.range(of: autoPrintMarker)).lowerBound
        let prefix = String(source[..<autoPrintOffset])
        XCTAssertEqual(
            prefix.components(separatedBy: "#if DEBUG").count,
            prefix.components(separatedBy: "#endif").count,
            "the auto-print helper must be compiled into Release, not wrapped in #if DEBUG"
        )

        let consumption = try XCTUnwrap(
            source.range(of: "autoPrintStageOneAttemptedPopupIDs.insert(key)")
        ).lowerBound
        let invocation = try XCTUnwrap(
            source.range(of: "autoPrintStageOneJavaScriptEvaluator(\n                webView,")
        ).lowerBound
        XCTAssertLessThan(consumption, invocation, "the one-shot must be consumed before JavaScript")
        // Every Stage 1 decision routes through one Swift-side gate helper, so the guards used
        // before the settle delay, after it elapses, and immediately before consumption can never
        // drift apart.
        XCTAssertEqual(
            source.components(separatedBy: "CrewAccessAutoPrint.rejectionReason(").count - 1,
            1,
            "the Stage 1 gate is expressed exactly once, inside its helper"
        )
        XCTAssertEqual(
            source.components(separatedBy: "autoPrintStageOneRejectionReason(").count - 1,
            2,
            "one helper declaration plus the single pre-settle eligibility check"
        )
        // The post-settle gate is a separate helper on purpose: it must not require the probe
        // snapshot that started the wait to still be current.
        XCTAssertEqual(
            source.components(separatedBy: "CrewAccessAutoPrint.settledRejectionReason(").count - 1,
            1,
            "the settled Stage 1 gate is expressed exactly once, inside its helper"
        )
        XCTAssertEqual(
            source.components(separatedBy: "autoPrintStageOneSettledRejectionReason(").count - 1,
            3,
            "one helper declaration plus the post-settle and pre-consumption checks"
        )
    }

    #if DEBUG
    func test_phase0ProbeScriptIsValidJavaScriptAndNeverTouchesThePage() throws {
        let script = BrowserWebView.Coordinator.pageInspectionScript()
        XCTAssertTrue(script.contains("pageText: document.body ? document.body.innerText : ''"))

        for banned in [".click()", "dispatchEvent", ".submit()", "document.cookie", "window.print("] {
            XCTAssertFalse(script.contains(banned), "probe script must not contain \(banned)")
        }

        // Parsing the script inside an uncalled function expression validates its syntax without
        // executing it. There is no DOM in JavaScriptCore, and running it here is neither needed
        // nor meaningful — a syntax error is what would otherwise silently disable the probe.
        let context = try XCTUnwrap(JSContext())
        var thrownMessage: String?
        context.exceptionHandler = { _, value in thrownMessage = value?.toString() }
        _ = context.evaluateScript("(function () { return \(script); })")
        XCTAssertNil(thrownMessage, "page inspection script must be syntactically valid JavaScript")
    }

    func test_autoPrintExperimentAcceptsOnlyExactZscalerSessionURLShape() {
        let uuid = "00000000-0000-4000-8000-000000000000"
        let exact = "https://4d8e06f5.isolation.zscaler.com/profile/\(uuid)/zpa-session"

        XCTAssertTrue(CrewAccessAutoPrint.isExactZscalerSessionURL(URL(string: exact)))
        XCTAssertTrue(CrewAccessAutoPrint.isExactZscalerSessionURL(URL(string: exact + "/?region=test")))

        for rejected in [
            "http://4d8e06f5.isolation.zscaler.com/profile/\(uuid)/zpa-session",
            "https://isolation.zscaler.com.evil.invalid/profile/\(uuid)/zpa-session",
            "https://4d8e06f5.isolation.zscaler.com:443/profile/\(uuid)/zpa-session",
            "https://4d8e06f5.isolation.zscaler.com/profile/not-a-uuid/zpa-session",
            "https://4d8e06f5.isolation.zscaler.com/profile/\(uuid)/zpa-render",
            "https://4d8e06f5.isolation.zscaler.com/profile/\(uuid)/zpa-session#fragment"
        ] {
            XCTAssertFalse(
                CrewAccessAutoPrint.isExactZscalerSessionURL(URL(string: rejected)),
                "unexpected URL admission: \(rejected)"
            )
        }
    }

    func test_autoPrintExperimentRequiresOneExactVisibleEnabledDocumentButton() {
        func element(
            root: String = "document",
            tag: String = "button",
            exactButtonTag: Bool = true,
            type: String = "button",
            exactButtonType: Bool = true,
            ariaLabel: String = "Print",
            exactPrintAriaLabel: Bool = true,
            printMatch: String = "exact",
            visible: Bool = true,
            disabled: Bool = false,
            width: Int = 32,
            height: Int = 32
        ) -> [String: Any] {
            [
                "root": root,
                "tagName": tag,
                "tagNameIsExactButton": exactButtonTag,
                "type": type,
                "typeIsExactButton": exactButtonType,
                "ariaLabel": ariaLabel,
                "ariaLabelIsExactPrint": exactPrintAriaLabel,
                "printMatch": printMatch,
                "isVisible": visible,
                "isDisabled": disabled,
                "rect": [0, 0, width, height]
            ]
        }

        XCTAssertEqual(
            CrewAccessAutoPrint.qualifyingPrintButtonCount(in: [element()]),
            1
        )
        for rejected in [
            element(root: "shadow[0]:div"),
            element(tag: "a"),
            element(exactButtonTag: false),
            element(type: "submit"),
            element(exactButtonType: false),
            element(ariaLabel: "print"),
            element(ariaLabel: "Print Trip"),
            element(exactPrintAriaLabel: false),
            element(printMatch: "label-substring"),
            element(visible: false),
            element(disabled: true),
            element(width: 0),
            element(height: 0)
        ] {
            XCTAssertEqual(
                CrewAccessAutoPrint.qualifyingPrintButtonCount(in: [rejected]),
                0
            )
        }
        XCTAssertEqual(
            CrewAccessAutoPrint.qualifyingPrintButtonCount(in: [element(), element()]),
            2,
            "ambiguity must remain visible to the fail-closed eligibility guard"
        )
    }

    func test_autoPrintExperimentSwiftEligibilityFailsClosedForEveryGuard() {
        let uuid = "00000000-0000-4000-8000-000000000000"
        let url = URL(string: "https://4d8e06f5.isolation.zscaler.com/profile/\(uuid)/zpa-session")
        let printButton: [String: Any] = [
            "root": "document",
            "tagName": "button",
            "tagNameIsExactButton": true,
            "type": "button",
            "typeIsExactButton": true,
            "ariaLabel": "Print",
            "ariaLabelIsExactPrint": true,
            "printMatch": "exact",
            "isVisible": true,
            "isDisabled": false,
            "rect": [0, 0, 32, 32]
        ]

        func reason(
            tracked: Bool = true,
            visible: Bool = true,
            popupCount: Int = 1,
            tearingDown: Bool = false,
            completedURL: URL? = url,
            currentURL: URL? = url,
            readyState: String = "complete",
            elements: [[String: Any]] = [printButton],
            consumed: Bool = false
        ) -> String? {
            CrewAccessAutoPrint.rejectionReason(
                isTrackedPopup: tracked,
                isVisiblePopup: visible,
                livePopupCount: popupCount,
                teardownInProgress: tearingDown,
                completedURL: completedURL,
                currentURL: currentURL,
                readyState: readyState,
                printElements: elements,
                oneShotConsumed: consumed
            )
        }

        XCTAssertNil(reason())
        XCTAssertEqual(reason(tracked: false), "not-tracked-popup")
        XCTAssertEqual(reason(visible: false), "not-visible-popup")
        XCTAssertEqual(reason(popupCount: 0), "live-popup-count-0")
        XCTAssertEqual(reason(popupCount: 2), "live-popup-count-2")
        XCTAssertEqual(reason(tearingDown: true), "teardown-in-progress")
        XCTAssertEqual(reason(currentURL: URL(string: "https://example.invalid")), "url-mismatch")
        XCTAssertEqual(
            reason(completedURL: URL(string: "https://example.invalid"), currentURL: URL(string: "https://example.invalid")),
            "url-mismatch"
        )
        XCTAssertEqual(
            reason(
                completedURL: URL(
                    string: "https://4d8e06f5.isolation.zscaler.com/profile/11111111-1111-4111-8111-111111111111/zpa-session"
                )
            ),
            "session-changed",
            "a genuinely different session is still rejected, by the same name the settled gate uses"
        )
        XCTAssertEqual(reason(readyState: "interactive"), "document-not-complete")
        XCTAssertEqual(reason(elements: []), "qualifying-print-button-count-0")
        XCTAssertEqual(reason(elements: [printButton, printButton]), "qualifying-print-button-count-2")
        XCTAssertEqual(reason(consumed: true), "one-shot-already-consumed")
    }

    /// The post-settle gate keeps every safety guard of `rejectionReason` and changes only the
    /// staleness rule: the wait is tied to the tracked popup and its session, not to the probe
    /// snapshot that started it. Full-URL equality made the isolation client's in-place query
    /// evolution look like a navigation.
    func test_autoPrintSettledEligibilityTracksPopupAndSessionNotTheOriginalProbe() {
        let uuid = "00000000-0000-4000-8000-000000000000"
        let base = "https://4d8e06f5.isolation.zscaler.com/profile/\(uuid)/zpa-session"
        let url = URL(string: base)
        let printButton: [String: Any] = [
            "root": "document",
            "tagName": "button",
            "tagNameIsExactButton": true,
            "type": "button",
            "typeIsExactButton": true,
            "ariaLabel": "Print",
            "ariaLabelIsExactPrint": true,
            "printMatch": "exact",
            "isVisible": true,
            "isDisabled": false,
            "rect": [0, 0, 32, 32]
        ]

        func reason(
            tracked: Bool = true,
            visible: Bool = true,
            popupCount: Int = 1,
            tearingDown: Bool = false,
            sameGeneration: Bool = true,
            settleSessionURL: URL? = url,
            currentURL: URL? = url,
            readyState: String = "complete",
            elements: [[String: Any]] = [printButton],
            consumed: Bool = false
        ) -> String? {
            CrewAccessAutoPrint.settledRejectionReason(
                isTrackedPopup: tracked,
                isVisiblePopup: visible,
                livePopupCount: popupCount,
                teardownInProgress: tearingDown,
                isSamePopupGeneration: sameGeneration,
                settleSessionURL: settleSessionURL,
                currentURL: currentURL,
                readyState: readyState,
                printElements: elements,
                oneShotConsumed: consumed
            )
        }

        XCTAssertNil(reason())

        // The regression this gate exists for: the same session with an evolved query must pass.
        XCTAssertNil(reason(currentURL: URL(string: base + "?printJob=abc123&dialog=open")))
        XCTAssertNil(
            reason(
                settleSessionURL: URL(string: base + "?a=1"),
                currentURL: URL(string: base + "?b=2")
            )
        )

        // Every safety guard is still fail-closed.
        XCTAssertEqual(reason(tracked: false), "not-tracked-popup")
        XCTAssertEqual(reason(visible: false), "not-visible-popup")
        XCTAssertEqual(reason(popupCount: 0), "live-popup-count-0")
        XCTAssertEqual(reason(popupCount: 2), "live-popup-count-2")
        XCTAssertEqual(reason(tearingDown: true), "teardown-in-progress")
        XCTAssertEqual(reason(sameGeneration: false), "popup-generation-changed")
        XCTAssertEqual(
            reason(currentURL: URL(string: "https://example.invalid/not-zscaler")),
            "url-mismatch"
        )
        XCTAssertEqual(
            reason(
                currentURL: URL(
                    string: "https://4d8e06f5.isolation.zscaler.com/profile/11111111-1111-4111-8111-111111111111/zpa-session"
                )
            ),
            "session-changed",
            "a different profile is a different session even on the same host"
        )
        XCTAssertEqual(
            reason(
                currentURL: URL(
                    string: "https://99999999.isolation.zscaler.com/profile/\(uuid)/zpa-session"
                )
            ),
            "session-changed",
            "a different isolation host is a different session"
        )
        XCTAssertEqual(
            reason(settleSessionURL: URL(string: "https://example.invalid/not-zscaler")),
            "session-changed"
        )
        XCTAssertEqual(reason(readyState: "interactive"), "document-not-complete")
        XCTAssertEqual(reason(elements: []), "qualifying-print-button-count-0")
        XCTAssertEqual(reason(elements: [printButton, printButton]), "qualifying-print-button-count-2")
        XCTAssertEqual(reason(consumed: true), "one-shot-already-consumed")

        // Both gates now apply the same staleness rule. The pre-settle gate used to reject the
        // isolation client's in-place query evolution outright, which permanently stranded the
        // first attempt's sampling chain on `stale-probe`.
        XCTAssertNil(
            CrewAccessAutoPrint.rejectionReason(
                isTrackedPopup: true,
                isVisiblePopup: true,
                livePopupCount: 1,
                teardownInProgress: false,
                completedURL: url,
                currentURL: URL(string: base + "?printJob=abc123"),
                readyState: "complete",
                printElements: [printButton],
                oneShotConsumed: false
            ),
            "the pre-settle gate must tolerate the same in-place query evolution as the settled gate"
        )
    }

    func test_autoPrintInvocationScriptIsAtomicAndContainsOneRealDOMClick() throws {
        let script = CrewAccessAutoPrint.invocationScript
        XCTAssertEqual(script.components(separatedBy: ".click()").count - 1, 1)
        XCTAssertTrue(script.contains("candidates[0].click();"))
        XCTAssertTrue(script.contains("document.readyState !== 'complete'"))
        XCTAssertTrue(script.contains("document.querySelectorAll('button')"))
        XCTAssertTrue(script.contains("button.getAttribute('type') === 'button'"))
        XCTAssertTrue(script.contains("button.getAttribute('aria-label') === 'Print'"))
        XCTAssertTrue(script.contains("candidates.length !== 1"))
        XCTAssertFalse(
            script.contains("style.pointerEvents !== 'none'"),
            "pointer-events is diagnostic evidence, not a direct DOM click eligibility guard"
        )
        XCTAssertTrue(script.contains("computedPointerEvents: style.pointerEvents"))
        for retainedGuard in [
            "const hasPositiveRect = rects.some(rect => rect.width > 0 && rect.height > 0)",
            "&& !button.hidden",
            "&& !button.disabled",
            "normalize(button.getAttribute('aria-disabled')).toLowerCase() !== 'true'",
            "&& style.display !== 'none'",
            "&& style.visibility !== 'hidden'",
            "&& style.visibility !== 'collapse'",
            "&& opacity > 0.01"
        ] {
            XCTAssertTrue(script.contains(retainedGuard), "missing retained atomic guard: \(retainedGuard)")
        }
        XCTAssertTrue(script.contains("if (candidates.length === 0)"))
        for diagnosticField in [
            "rawTagName", "rawTypeAttribute", "rawAriaLabel", "disabled",
            "rawAriaDisabled", "hidden", "clientRectWidth", "clientRectHeight",
            "computedDisplay", "computedVisibility", "computedOpacity",
            "computedPointerEvents", "rejectedPredicates", "totalDocumentButtonCount",
            "exactPrintAriaLabelCount", "survivingCounts", "printLikeButtons"
        ] {
            XCTAssertTrue(script.contains(diagnosticField), "missing zero-candidate diagnostic: \(diagnosticField)")
        }

        for banned in [
            "dispatchEvent", "new MouseEvent", "new TouchEvent", "new PointerEvent", "window.print(",
            "window.focus()", "document.body.focus()", "elementFromPoint", "getBoundingClientRect"
        ] {
            XCTAssertFalse(script.contains(banned), "invocation script must not contain \(banned)")
        }

        let context = try XCTUnwrap(JSContext())
        var thrownMessage: String?
        context.exceptionHandler = { _, value in thrownMessage = value?.toString() }
        _ = context.evaluateScript("(function () { return \(script); })")
        XCTAssertNil(thrownMessage, "Stage 1 invocation script must be syntactically valid JavaScript")
    }

    func test_autoPrintPointerEventsNoneDoesNotDisqualifyAndOtherGuardsRemainFailClosed() throws {
        let context = try XCTUnwrap(JSContext())
        var thrownMessage: String?
        context.exceptionHandler = { _, value in thrownMessage = value?.toString() }
        _ = context.evaluateScript(#"""
        var location = {
            href: 'https://4d8e06f5.isolation.zscaler.com/profile/00000000-0000-4000-8000-000000000000/zpa-session'
        };
        function URL(value) {
            this.protocol = 'https:';
            this.hostname = '4d8e06f5.isolation.zscaler.com';
            this.port = '';
            this.username = '';
            this.password = '';
            this.hash = '';
            this.pathname = '/profile/00000000-0000-4000-8000-000000000000/zpa-session';
        }
        var clickCount = 0;
        var computedOpacity = '0';
        var printButton = {
            tagName: 'BUTTON',
            innerText: 'Print',
            textContent: 'Print',
            disabled: false,
            hidden: false,
            getAttribute: function(name) {
                if (name === 'type') return 'button';
                if (name === 'aria-label') return 'Print';
                if (name === 'aria-disabled') return null;
                return null;
            },
            getClientRects: function() { return [{ width: 42, height: 18 }]; },
            click: function() { clickCount += 1; }
        };
        var document = {
            readyState: 'complete',
            querySelectorAll: function(selector) { return selector === 'button' ? [printButton] : []; }
        };
        var window = {
            getComputedStyle: function(element) {
                return {
                    display: 'block',
                    visibility: 'visible',
                    opacity: computedOpacity,
                    pointerEvents: 'none'
                };
            }
        };
        """#)
        XCTAssertNil(thrownMessage, "diagnostic test setup must be valid JavaScript")

        let result = context.evaluateScript(CrewAccessAutoPrint.invocationScript)
        XCTAssertNil(thrownMessage, "diagnostic execution must not throw")
        let values = try XCTUnwrap(result?.toDictionary() as? [String: Any])
        XCTAssertEqual(values["result"] as? String, "rejected")
        XCTAssertEqual(values["reason"] as? String, "qualifying-print-button-count")
        XCTAssertEqual((values["count"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual(context.objectForKeyedSubscript("clickCount")?.toInt32(), 0)

        let diagnostic = try XCTUnwrap(values["diagnostic"] as? [String: Any])
        XCTAssertEqual((diagnostic["totalDocumentButtonCount"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((diagnostic["exactPrintAriaLabelCount"] as? NSNumber)?.intValue, 1)
        let counts = try XCTUnwrap(diagnostic["survivingCounts"] as? [String: Any])
        XCTAssertEqual((counts["afterVisibilityNotCollapse"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((counts["afterOpacityGreaterThanPointZeroOne"] as? NSNumber)?.intValue, 0)

        let printLikeButtons = try XCTUnwrap(diagnostic["printLikeButtons"] as? [[String: Any]])
        let button = try XCTUnwrap(printLikeButtons.first)
        XCTAssertEqual(button["rawTagName"] as? String, "BUTTON")
        XCTAssertEqual(button["rawTypeAttribute"] as? String, "button")
        XCTAssertEqual(button["rawAriaLabel"] as? String, "Print")
        XCTAssertEqual(button["computedPointerEvents"] as? String, "none")
        XCTAssertEqual(button["rejectedPredicates"] as? [String], ["opacityGreaterThanPointZeroOne"])

        context.evaluateScript("computedOpacity = '1'; clickCount = 0;")
        let acceptedResult = context.evaluateScript(CrewAccessAutoPrint.invocationScript)
        XCTAssertNil(thrownMessage, "pointer-events:none execution must not throw")
        let acceptedValues = try XCTUnwrap(acceptedResult?.toDictionary() as? [String: Any])
        XCTAssertEqual(acceptedValues["result"] as? String, "invoked")
        XCTAssertEqual(acceptedValues["reason"] as? String, "none")
        XCTAssertEqual((acceptedValues["count"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual(acceptedValues["computedPointerEvents"] as? String, "none")
        XCTAssertEqual(context.objectForKeyedSubscript("clickCount")?.toInt32(), 1)
    }

    func test_autoPrintStageTwoGateFailsClosedForEveryGuard() {
        func reason(
            isTrackedPopup: Bool = true,
            isVisiblePopup: Bool = true,
            livePopupCount: Int = 1,
            teardownInProgress: Bool = false,
            completedURL: URL? = URL(string: "https://4d8e06f5.isolation.zscaler.com/profile/00000000-0000-4000-8000-000000000000/zpa-session"),
            currentURL: URL? = URL(string: "https://4d8e06f5.isolation.zscaler.com/profile/00000000-0000-4000-8000-000000000000/zpa-session"),
            readyState: String = "complete",
            stageOneAttempted: Bool = true,
            oneShotConsumed: Bool = false
        ) -> String? {
            CrewAccessAutoPrint.stageTwoRejectionReason(
                isTrackedPopup: isTrackedPopup,
                isVisiblePopup: isVisiblePopup,
                livePopupCount: livePopupCount,
                teardownInProgress: teardownInProgress,
                completedURL: completedURL,
                currentURL: currentURL,
                readyState: readyState,
                stageOneAttempted: stageOneAttempted,
                oneShotConsumed: oneShotConsumed
            )
        }

        XCTAssertNil(reason(), "every guard satisfied must be eligible")
        XCTAssertEqual(reason(isTrackedPopup: false), "not-tracked-popup")
        XCTAssertEqual(reason(isVisiblePopup: false), "not-visible-popup")
        XCTAssertEqual(reason(livePopupCount: 2), "live-popup-count-2")
        XCTAssertEqual(reason(livePopupCount: 0), "live-popup-count-0")
        XCTAssertEqual(reason(teardownInProgress: true), "teardown-in-progress")
        XCTAssertEqual(
            reason(completedURL: URL(string: "https://4d8e06f5.isolation.zscaler.com/profile/00000000-0000-4000-8000-000000000000/zpa-session/other")),
            "stale-probe"
        )
        XCTAssertEqual(
            reason(
                completedURL: URL(string: "https://fltops-portal.ups.com/home"),
                currentURL: URL(string: "https://fltops-portal.ups.com/home")
            ),
            "url-mismatch"
        )
        XCTAssertEqual(
            reason(stageOneAttempted: false),
            "stage-one-not-attempted",
            "Stage 2 must never run before Stage 1 has been attempted on this popup"
        )
        XCTAssertEqual(reason(oneShotConsumed: true), "one-shot-already-consumed")
        XCTAssertEqual(reason(readyState: "interactive"), "document-not-complete")
    }

    func test_autoPrintStageTwoResolvesExactlyOneDialogSubmitButtonAndOtherwiseFailsClosed() throws {
        let script = CrewAccessAutoPrint.stageTwoInvocationScript

        func evaluate(_ setup: String) throws -> (values: [String: Any], context: JSContext) {
            let context = try XCTUnwrap(JSContext())
            var thrownMessage: String?
            context.exceptionHandler = { _, value in thrownMessage = value?.toString() }
            _ = context.evaluateScript(#"""
            var location = {
                href: 'https://4d8e06f5.isolation.zscaler.com/profile/00000000-0000-4000-8000-000000000000/zpa-session'
            };
            function URL(value) {
                this.protocol = 'https:';
                this.hostname = '4d8e06f5.isolation.zscaler.com';
                this.port = '';
                this.username = '';
                this.password = '';
                this.hash = '';
                this.pathname = '/profile/00000000-0000-4000-8000-000000000000/zpa-session';
            }
            var clickCount = 0;
            function makeSubmitButton(label, pointerEvents, disabled) {
                return {
                    tagName: 'BUTTON',
                    hidden: false,
                    disabled: disabled === true,
                    textContent: label,
                    pointerEvents: pointerEvents,
                    getAttribute: function(name) {
                        if (name === 'type') return 'submit';
                        if (name === 'aria-label') return null;
                        if (name === 'title') return null;
                        if (name === 'aria-disabled') return null;
                        return null;
                    },
                    getClientRects: function() { return [{ width: 88, height: 36 }]; },
                    click: function() { clickCount += 1; }
                };
            }
            """#)
            XCTAssertNil(thrownMessage, "Stage 2 harness must be valid JavaScript")
            _ = context.evaluateScript(setup)
            XCTAssertNil(thrownMessage, "Stage 2 scenario must be valid JavaScript")
            let values = try XCTUnwrap(context.evaluateScript(script)?.toDictionary() as? [String: Any])
            XCTAssertNil(thrownMessage, "Stage 2 evaluation must not throw")
            return (values, context)
        }

        let dialogScaffold = #"""
        function makeDialog(buttons) {
            return {
                hidden: false,
                pointerEvents: 'auto',
                getClientRects: function() { return [{ width: 320, height: 200 }]; },
                querySelectorAll: function(selector) { return selector === 'button' ? buttons : []; }
            };
        }
        var dialogs = [];
        var document = {
            readyState: 'complete',
            querySelectorAll: function(selector) {
                return selector === '[role="dialog"]' ? dialogs : [];
            }
        };
        var window = {
            getComputedStyle: function(node) {
                return {
                    display: 'flex',
                    visibility: 'visible',
                    opacity: '1',
                    pointerEvents: node.pointerEvents || 'auto'
                };
            }
        };
        """#

        // Exactly one dialog, exactly one qualifying submit button -> invoked once.
        let accepted = try evaluate(dialogScaffold + #"""
        var okButton = makeSubmitButton('Print', 'auto');
        dialogs = [makeDialog([okButton])];
        """#)
        XCTAssertEqual(accepted.values["result"] as? String, "invoked")
        XCTAssertEqual(accepted.values["reason"] as? String, "none")
        XCTAssertEqual((accepted.values["count"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual(accepted.context.objectForKeyedSubscript("clickCount")?.toInt32(), 1)
        let acceptedDiagnostic = try XCTUnwrap(accepted.values["diagnostic"] as? [String: Any])
        XCTAssertEqual((acceptedDiagnostic["dialogCount"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((acceptedDiagnostic["submitButtonCount"] as? NSNumber)?.intValue, 1)
        let describedButtons = try XCTUnwrap(acceptedDiagnostic["submitButtons"] as? [[String: Any]])
        XCTAssertEqual(describedButtons.count, 1, "every visible submit button is described")
        XCTAssertEqual(describedButtons[0]["normalizedText"] as? String, "Print")
        XCTAssertEqual(describedButtons[0]["computedPointerEvents"] as? String, "auto")
        XCTAssertEqual((describedButtons[0]["clientRectWidth"] as? NSNumber)?.intValue, 88)

        // Two qualifying submit buttons -> ambiguous, fail closed, but still fully described.
        let ambiguous = try evaluate(dialogScaffold + #"""
        dialogs = [makeDialog([makeSubmitButton('Print', 'auto'), makeSubmitButton('Cancel', 'auto')])];
        """#)
        XCTAssertEqual(ambiguous.values["result"] as? String, "rejected")
        XCTAssertEqual(ambiguous.values["reason"] as? String, "qualifying-submit-button-count")
        XCTAssertEqual((ambiguous.values["count"] as? NSNumber)?.intValue, 2)
        XCTAssertEqual(ambiguous.context.objectForKeyedSubscript("clickCount")?.toInt32(), 0)
        let ambiguousDiagnostic = try XCTUnwrap(ambiguous.values["diagnostic"] as? [String: Any])
        XCTAssertEqual(
            (ambiguousDiagnostic["submitButtons"] as? [[String: Any]])?.count,
            2,
            "the diagnostic is produced before any invocation decision"
        )

        // pointer-events:none on the submit control disqualifies it, and it is still described.
        let inert = try evaluate(dialogScaffold + #"""
        dialogs = [makeDialog([makeSubmitButton('Print', 'none')])];
        """#)
        XCTAssertEqual(inert.values["result"] as? String, "rejected")
        XCTAssertEqual(inert.values["reason"] as? String, "qualifying-submit-button-count")
        XCTAssertEqual(inert.context.objectForKeyedSubscript("clickCount")?.toInt32(), 0)
        let inertDiagnostic = try XCTUnwrap(inert.values["diagnostic"] as? [String: Any])
        let inertButtons = try XCTUnwrap(inertDiagnostic["submitButtons"] as? [[String: Any]])
        XCTAssertEqual(inertButtons[0]["computedPointerEvents"] as? String, "none")

        // A disabled submit control disqualifies it.
        let disabled = try evaluate(dialogScaffold + #"""
        dialogs = [makeDialog([makeSubmitButton('Print', 'auto', true)])];
        """#)
        XCTAssertEqual(disabled.values["result"] as? String, "rejected")
        XCTAssertEqual(disabled.context.objectForKeyedSubscript("clickCount")?.toInt32(), 0)

        // No dialog, and two dialogs, both fail closed.
        let noDialog = try evaluate(dialogScaffold)
        XCTAssertEqual(noDialog.values["result"] as? String, "rejected")
        XCTAssertEqual(noDialog.values["reason"] as? String, "qualifying-dialog-count")
        XCTAssertEqual(noDialog.context.objectForKeyedSubscript("clickCount")?.toInt32(), 0)

        let twoDialogs = try evaluate(dialogScaffold + #"""
        dialogs = [
            makeDialog([makeSubmitButton('Print', 'auto')]),
            makeDialog([makeSubmitButton('Print', 'auto')])
        ];
        """#)
        XCTAssertEqual(twoDialogs.values["result"] as? String, "rejected")
        XCTAssertEqual(twoDialogs.values["reason"] as? String, "qualifying-dialog-count")
        XCTAssertEqual((twoDialogs.values["count"] as? NSNumber)?.intValue, 2)
        XCTAssertEqual(twoDialogs.context.objectForKeyedSubscript("clickCount")?.toInt32(), 0)
    }

    func test_autoPrintStageTwoUsesStructuralPreflightThenGuardedInvocation() throws {
        let source = try browserWebViewSource()

        // Separate one-shot state: neither stage can consume or unblock the other.
        XCTAssertTrue(source.contains("var autoPrintStageTwoAttemptedPopupIDs: Set<ObjectIdentifier> = []"))
        XCTAssertTrue(source.contains("var autoPrintStageOneAttemptedPopupIDs: Set<ObjectIdentifier> = []"))

        // Phase A is read-only: it never clicks or consumes directly. It now reports exactly the
        // structure the gate consumes — the rejected DOM-stability, canvas-fingerprint and
        // mutation-count experiments are gone.
        let readiness = CrewAccessAutoPrint.stageTwoReadinessScript
        XCTAssertFalse(readiness.contains(".click()"), "readiness must never invoke a control")
        XCTAssertFalse(readiness.contains("dispatchEvent"))
        XCTAssertTrue(readiness.contains("ready: false"))
        XCTAssertTrue(readiness.contains("buttonReady: buttonReady"))
        XCTAssertTrue(readiness.contains("'report-readiness-unproven'"))
        for signal in [
            "dialogCount", "qualifyingDialogCount", "submitButtonCount",
            "visibleSubmitButtonCount", "qualifyingSubmitButtonCount", "submitButtons",
            "normalizedText", "ariaLabel", "rawAriaDisabled",
            "clientRectWidth", "clientRectHeight",
            "computedDisplay", "computedVisibility", "computedOpacity", "computedPointerEvents"
        ] {
            XCTAssertTrue(readiness.contains(signal), "missing Stage 2 structural signal: \(signal)")
        }
        for retired in [
            "reportSnapshot", "canvasFingerprint", "mutationGeneration", "observedMutationCount",
            "bodyTextLength", "visibleCanvasCount", "getImageData", "structuralTokens"
        ] {
            XCTAssertFalse(readiness.contains(retired), "rejected experiment signal remains: \(retired)")
        }
        XCTAssertTrue(readiness.contains("'qualifying-dialog-count'"))

        let phaseA = try XCTUnwrap(
            source
                .components(separatedBy: "func evaluateAutoPrintStageTwoReadiness(")
                .dropFirst()
                .first?
                .components(separatedBy: "private func invokeAutoPrintStageTwo(")
                .first
        )
        XCTAssertFalse(
            phaseA.contains("autoPrintStageTwoAttemptedPopupIDs.insert("),
            "Phase A must never consume the one-shot"
        )
        XCTAssertFalse(
            phaseA.contains("autoPrintStageTwoJavaScriptEvaluator("),
            "Phase A must never run the invocation script"
        )
        XCTAssertTrue(
            phaseA.contains("invokeAutoPrintStageTwo("),
            "a structurally accepted sample after the settle delay enters guarded Phase B"
        )
        XCTAssertTrue(phaseA.contains("stage=2 readiness=not-ready"))
        XCTAssertTrue(phaseA.contains("guard structuralReadinessPassed else"))
        XCTAssertFalse(
            phaseA.contains("reportSnapshotIsStable"),
            "DOM stability must never gate Stage 2"
        )
        XCTAssertFalse(phaseA.contains("unchangedFromPrevious"))
        XCTAssertEqual(
            phaseA.components(separatedBy: "CrewAccessAutoPrint.stageTwoRejectionReason(").count - 1,
            1,
            "Phase A gates once before the read-only readiness check"
        )

        let phaseB = try XCTUnwrap(
            source
                .components(separatedBy: "private func invokeAutoPrintStageTwo(")
                .dropFirst()
                .first?
                .components(separatedBy: "/// Evaluates the already-scheduled production probe sample")
                .first
        )
        XCTAssertEqual(
            phaseB.components(separatedBy: "CrewAccessAutoPrint.stageTwoRejectionReason(").count - 1,
            2,
            "Phase B re-runs eligibility and an immediate pre-consumption check"
        )
        XCTAssertLessThan(
            try XCTUnwrap(phaseB.range(of: "autoPrintStageTwoAttemptedPopupIDs.insert(key)")).lowerBound,
            try XCTUnwrap(phaseB.range(of: "autoPrintStageTwoJavaScriptEvaluator(")).lowerBound,
            "the Stage 2 one-shot must be consumed before JavaScript"
        )
        XCTAssertTrue(phaseB.contains("stage=2 oneShot=consumed"))
        XCTAssertTrue(phaseB.contains("stage=2 execution=attempted"))
        XCTAssertTrue(phaseB.contains("stage=2 executionResult="))
        XCTAssertTrue(phaseB.contains("retry=false"))

        for banned in ["toDataURL", "toBlob", "drawImage", "putImageData"] {
            XCTAssertFalse(readiness.contains(banned), "canvas observation must not serialize or write: \(banned)")
        }

        // Neither phase schedules or retries. The single settle-delay task owns timing.
        func executableLines(of block: String) -> String {
            block
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
        }
        let phaseACode = executableLines(of: phaseA)
        let phaseBCode = executableLines(of: phaseB)
        for banned in ["Task {", "asyncAfter", "Timer", "for attempt in", "while "] {
            XCTAssertFalse(phaseACode.contains(banned), "Phase A must not schedule or retry: \(banned)")
            XCTAssertFalse(phaseBCode.contains(banned), "Phase B must not schedule or retry: \(banned)")
        }

        // Stage 1 safeguards are untouched: one shared gate helper, called three times.
        XCTAssertEqual(
            source.components(separatedBy: "CrewAccessAutoPrint.rejectionReason(").count - 1,
            1,
            "the Stage 1 gate is expressed exactly once, inside its helper"
        )
        XCTAssertEqual(
            source.components(separatedBy: "autoPrintStageOneRejectionReason(").count - 1,
            2,
            "one helper declaration plus the single pre-settle eligibility check"
        )
        XCTAssertEqual(
            source.components(separatedBy: "autoPrintStageOneSettledRejectionReason(").count - 1,
            3,
            "one helper declaration plus the post-settle and pre-consumption checks"
        )
        XCTAssertTrue(source.contains("autoPrintStageTwoAttemptedPopupIDs.remove(popupKey)"))
    }

    func test_autoPrintStageOneInvocationLogicRemainsFrozen() throws {
        let source = try browserWebViewSource()
        let frozenSource = try stageOneInvocationSource(from: source)
        let digest = SHA256.hash(data: Data(frozenSource.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        XCTAssertEqual(
            digest,
            "f674f309342fcc28d071e77e855fb2b2865f2f00010dbd3ea5f91af3de993f79",
            "the proven Stage 1 invocationScript must remain byte-identical"
        )
        XCTAssertEqual(
            source.components(separatedBy: "handleAutoPrintStageOneExecutionResult(").count - 1,
            2,
            "Stage 1 may have exactly one isolated post-result hook plus its helper declaration"
        )
        XCTAssertTrue(source.contains("if jsResult == \"invoked\", let stageOneWebView {"))
        XCTAssertTrue(source.contains("ObjectIdentifier($0) == key"))
        XCTAssertTrue(source.contains("reason=stage-one-popup-untracked"))
    }

    func test_autoPrintStageTwoSessionIdentityToleratesOnlyQueryEvolution() {
        let base = "https://4d8e06f5.isolation.zscaler.com/profile/00000000-0000-4000-8000-000000000000/zpa-session"
        func url(_ value: String) -> URL { URL(string: value)! }
        let session = url(base)

        func sameSession(_ lhs: URL?, _ rhs: URL?) -> Bool {
            CrewAccessAutoPrint.isSameZscalerSession(lhs, rhs)
        }
        func reason(completedURL: URL?, currentURL: URL?) -> String? {
            CrewAccessAutoPrint.stageTwoRejectionReason(
                isTrackedPopup: true,
                isVisiblePopup: true,
                livePopupCount: 1,
                teardownInProgress: false,
                completedURL: completedURL,
                currentURL: currentURL,
                readyState: "complete",
                stageOneAttempted: true,
                oneShotConsumed: false
            )
        }

        // Query evolution inside one session is the benign case this exists for.
        let withQuery = url(base + "?printJob=abc123&dialog=open")
        let withOtherQuery = url(base + "?printJob=def456")
        XCTAssertTrue(sameSession(session, withQuery))
        XCTAssertTrue(sameSession(withQuery, session))
        XCTAssertTrue(sameSession(withQuery, withOtherQuery))
        XCTAssertNil(
            reason(completedURL: session, currentURL: withQuery),
            "a same-session query change must remain eligible"
        )
        XCTAssertNil(reason(completedURL: withQuery, currentURL: withOtherQuery))

        // Different host — same profile, different isolation node — is not the same session.
        let otherHost = url(
            "https://99999999.isolation.zscaler.com/profile/00000000-0000-4000-8000-000000000000/zpa-session"
        )
        XCTAssertFalse(sameSession(session, otherHost))
        XCTAssertEqual(reason(completedURL: session, currentURL: otherHost), "stale-probe")

        // Different profile UUID is a different session.
        let otherProfile = url(
            "https://4d8e06f5.isolation.zscaler.com/profile/11111111-1111-4111-8111-111111111111/zpa-session"
        )
        XCTAssertFalse(sameSession(session, otherProfile))
        XCTAssertEqual(reason(completedURL: session, currentURL: otherProfile), "stale-probe")

        // A different path fails, whichever side carries it.
        XCTAssertFalse(sameSession(session, url(base + "/other")))
        XCTAssertEqual(reason(completedURL: url(base + "/other"), currentURL: session), "stale-probe")

        // A fragment fails: isExactZscalerSessionURL requires none, so neither side may carry one.
        let withFragment = url(base + "#print")
        XCTAssertFalse(sameSession(session, withFragment))
        XCTAssertFalse(sameSession(withFragment, session))
        XCTAssertEqual(
            reason(completedURL: session, currentURL: withFragment),
            "url-mismatch",
            "a fragment on the live URL is reported as url-mismatch, the more specific reason"
        )
        XCTAssertEqual(reason(completedURL: withFragment, currentURL: session), "stale-probe")

        // A nil URL never matches, on either side.
        XCTAssertFalse(sameSession(session, nil))
        XCTAssertFalse(sameSession(nil, session))
        XCTAssertFalse(sameSession(nil, nil))
        XCTAssertEqual(reason(completedURL: session, currentURL: nil), "url-mismatch")
        XCTAssertEqual(reason(completedURL: nil, currentURL: session), "stale-probe")

        // Safety is not weakened: a non-session URL still cannot pass either guard.
        let portal = url("https://fltops-portal.ups.com/home")
        XCTAssertFalse(sameSession(session, portal))
        XCTAssertEqual(reason(completedURL: session, currentURL: portal), "url-mismatch")
    }

    func test_autoPrintStageTwoGateRejectionLogsRedactedShapesWithQueryNamesOnly() throws {
        let source = try browserWebViewSource()

        // Every Stage 2 gate rejection reports both shapes: one declaration plus three call sites.
        // The fourth is gone with the settle delay it belonged to — Stage 2's bounded schedule
        // gates at the start of the schedule, at each sample, and on the structural result.
        XCTAssertEqual(
            source.components(separatedBy: "logAutoPrintStageTwoGateRejection(").count - 1,
            4,
            "the gate-rejection log must cover the start, phase-a and structural gates"
        )
        for prefix in ["start-\\(reason)", "phase-a-\\(gateReason)", "structural-\\(structuralReason)"] {
            XCTAssertTrue(
                source.contains(prefix),
                "a Stage 2 gate rejection reason is no longer reported: \(prefix)"
            )
        }
        XCTAssertTrue(source.contains("stage=2 gate=rejected reason="))
        XCTAssertTrue(
            source.contains("completedURL=\\(CrewAccessPageProbe.urlShape(for: completedURL)")
        )
        XCTAssertTrue(
            source.contains("currentURL=\\(CrewAccessPageProbe.urlShape(for: currentURL)")
        )
        // A raw URL must never be interpolated into a log line.
        XCTAssertFalse(source.contains("completedURL=\\(completedURL"))
        XCTAssertFalse(source.contains("currentURL=\\(currentURL"))

        // The shape itself keeps parameter names and drops every value, fragment and identifier.
        let noisy = try XCTUnwrap(URL(string:
            "https://4d8e06f5.isolation.zscaler.com"
            + "/profile/00000000-0000-4000-8000-000000000000/zpa-session"
            + "?printJobToken=SHOULD-NEVER-BE-LOGGED&sessionState=ALSO-SECRET#printDialog"
        ))
        let shape = CrewAccessPageProbe.urlShape(for: noisy)
        XCTAssertTrue(shape.contains("printJobToken"), "parameter names are kept")
        XCTAssertTrue(shape.contains("sessionState"))
        XCTAssertFalse(shape.contains("SHOULD-NEVER-BE-LOGGED"), "values are never logged")
        XCTAssertFalse(shape.contains("ALSO-SECRET"))
        XCTAssertFalse(shape.contains("printDialog"), "the fragment is never logged")
        XCTAssertTrue(shape.contains("<uuid>"), "the profile identifier is masked")
        XCTAssertFalse(shape.contains("00000000-0000-4000-8000-000000000000"))
    }

    @MainActor
    func test_autoPrintStageTwoSettleCheckAllowsOnlySameSessionQueryEvolution() async {
        let base = "https://4d8e06f5.isolation.zscaler.com/profile/00000000-0000-4000-8000-000000000000/zpa-session"

        func makeContext(
            mutate: @escaping (Int) -> URL?
        ) -> (coordinator: BrowserWebView.Coordinator, popup: WKWebView, readiness: () -> Int, invocations: () -> Int) {
            let viewModel = BrowserViewModel()
            let coordinator = BrowserWebView.Coordinator(
                viewModel: viewModel,
                javaScriptEvaluator: { _, _, completion in completion(nil) }
            )
            let popup = WKWebView()
            coordinator.popupWebViews.append(popup)
            viewModel.popupWebView = popup
            coordinator.autoPrintStageTwoReadinessOffsetsNanoseconds = [0]
            coordinator.autoPrintStageOneAttemptedPopupIDs.insert(ObjectIdentifier(popup))

            let counters = ReadinessCounters()
            var liveURL = URL(string: base)!
            coordinator.autoPrintStageTwoCurrentURLProvider = { _ in liveURL }
            coordinator.autoPrintStageTwoReadinessEvaluator = { _, _, completion in
                counters.readiness += 1
                if let mutated = mutate(counters.readiness) {
                    liveURL = mutated
                }
                completion([
                    "ready": false,
                    "reason": "report-readiness-unproven",
                    "buttonReady": true,
                    "diagnostic": [
                        "dialogCount": 1,
                        "qualifyingDialogCount": 1,
                        "submitButtonCount": 1,
                        "visibleSubmitButtonCount": 1,
                        "qualifyingSubmitButtonCount": 1,
                        "submitButtons": []
                    ]
                ], nil)
            }
            coordinator.autoPrintStageTwoJavaScriptEvaluator = { _, _, completion in
                counters.invocations += 1
                completion(nil, nil)
            }
            return (coordinator, popup, { counters.readiness }, { counters.invocations })
        }

        // Only the query evolves: the single structural check may still invoke.
        let benign = makeContext { call in
            call == 1 ? URL(string: base + "?printJob=abc123&dialog=open") : nil
        }
        benign.coordinator.handleAutoPrintStageOneExecutionResult(
            "invoked",
            webView: benign.popup,
            completedURL: URL(string: base)!
        )
        await waitUntil { benign.invocations() == 1 }
        await Task.yield()
        XCTAssertEqual(benign.readiness(), 1)
        XCTAssertEqual(benign.invocations(), 1)
        XCTAssertFalse(benign.coordinator.autoPrintStageTwoAttemptedPopupIDs.isEmpty)
        XCTAssertFalse(benign.coordinator.hasPendingAutoPrintStageTwoReadinessWork)

        // Negative control: a host change is still a different session and still cancels.
        let hostile = makeContext { call in
            call == 1
                ? URL(string: "https://99999999.isolation.zscaler.com/profile/00000000-0000-4000-8000-000000000000/zpa-session")
                : nil
        }
        hostile.coordinator.handleAutoPrintStageOneExecutionResult(
            "invoked",
            webView: hostile.popup,
            completedURL: URL(string: base)!
        )
        await waitUntil { !hostile.coordinator.hasPendingAutoPrintStageTwoReadinessWork }
        await Task.yield()
        XCTAssertEqual(hostile.readiness(), 1, "a different isolation host must still cancel the schedule")
        XCTAssertEqual(hostile.invocations(), 0)
        XCTAssertTrue(hostile.coordinator.autoPrintStageTwoAttemptedPopupIDs.isEmpty)
        XCTAssertFalse(hostile.coordinator.hasPendingAutoPrintStageTwoReadinessWork)
    }

    /// Requirement 7: the settle wait now sits before Stage 1, and Stage 2 waits only for the
    /// dialog DOM. Requirement: the settle delay is the pre-Stage-1 one and nothing else.
    func test_settleDelayMovedBeforeStageOneAndStageTwoUsesBoundedReadinessOffsets() throws {
        XCTAssertEqual(
            CrewAccessAutoPrint.stageTwoReadinessOffsetsNanoseconds,
            [100_000_000, 250_000_000, 500_000_000]
        )
        let source = try browserWebViewSource()

        // Stage 1 owns the settle delay and logs its whole lifecycle.
        XCTAssertTrue(source.contains("stage=1 settle-delay=started configuredMilliseconds="))
        XCTAssertTrue(source.contains("stage=1 settle-delay=elapsed"))
        XCTAssertTrue(source.contains("stage=1 settle-delay=cancelled reason="))
        XCTAssertTrue(source.contains("stage=1 gate=accepted"))
        XCTAssertTrue(source.contains("stage=1 gate=rejected"))
        XCTAssertTrue(source.contains("stage=1 id="))
        XCTAssertTrue(
            source.contains("oneShot=consumed timing=immediately-before-javascript")
        )

        // Stage 2 no longer has a settle delay of its own.
        XCTAssertFalse(source.contains("stage=2 settle-delay"))
        XCTAssertFalse(source.contains("stageTwoMinimumSettleDelayNanoseconds"))
        XCTAssertFalse(source.contains("startDebugAutoPrintStageTwoSettleDelay"))
        XCTAssertFalse(source.contains("runDebugAutoPrintStageTwoSettleDelayCheck"))
        XCTAssertTrue(source.contains("stage=2 readiness-schedule=started offsetsMilliseconds="))
        XCTAssertTrue(source.contains("stage=2 readiness-sample=due index="))
        XCTAssertTrue(source.contains("stage=2 readiness=schedule-exhausted"))

        // The schedule stays finite: no Timer, no unbounded polling anywhere in the file.
        for banned in ["Timer(", "Timer.scheduledTimer", "while true", "repeat {"] {
            XCTAssertFalse(source.contains(banned), "auto-print timing must stay bounded: \(banned)")
        }
    }

    @MainActor
    func test_autoPrintStageOneExactInvokedRunsOneSettleCheckAndOneInvocation() async {
        let viewModel = BrowserViewModel()
        let coordinator = BrowserWebView.Coordinator(
            viewModel: viewModel,
            javaScriptEvaluator: { _, _, completion in completion(nil) }
        )
        let sessionURL = URL(
            string: "https://4d8e06f5.isolation.zscaler.com/profile/00000000-0000-4000-8000-000000000000/zpa-session"
        )!
        let popup = FixedURLWebView()
        popup.fixedURL = sessionURL
        coordinator.popupWebViews.append(popup)
        viewModel.popupWebView = popup
        coordinator.autoPrintStageOneSettleDelayNanoseconds = 0
        coordinator.autoPrintStageTwoReadinessOffsetsNanoseconds = [0]

        for nonExactResult in ["", "Invoked", "invoked "] {
            coordinator.handleAutoPrintStageOneExecutionResult(
                nonExactResult,
                webView: popup,
                completedURL: sessionURL
            )
            XCTAssertFalse(
                coordinator.hasPendingAutoPrintStageTwoReadinessWork,
                "only the exact Stage 1 executionResult=invoked may start the settle delay"
            )
        }

        var stageOneInvocationCount = 0
        coordinator.autoPrintStageOneJavaScriptEvaluator = { _, script, completion in
            stageOneInvocationCount += 1
            XCTAssertEqual(script, CrewAccessAutoPrint.invocationScript)
            completion(
                ["result": "invoked", "reason": "none", "count": 1],
                nil
            )
        }

        var readinessCallCount = 0
        coordinator.autoPrintStageTwoReadinessEvaluator = { _, script, completion in
            readinessCallCount += 1
            XCTAssertEqual(script, CrewAccessAutoPrint.stageTwoReadinessScript)
            completion([
                "ready": false,
                "buttonReady": true,
                "reason": "report-readiness-unproven",
                "diagnostic": [
                    "dialogCount": 1,
                    "qualifyingDialogCount": 1,
                    "submitButtonCount": 1,
                    "visibleSubmitButtonCount": 1,
                    "qualifyingSubmitButtonCount": 1,
                    "submitButtons": []
                ]
            ], nil)
        }
        var stageTwoInvocationCount = 0
        var stageTwoOneShotWasConsumedImmediatelyBeforeInvocation = false
        coordinator.autoPrintStageTwoJavaScriptEvaluator = { _, _, completion in
            stageTwoInvocationCount += 1
            stageTwoOneShotWasConsumedImmediatelyBeforeInvocation =
                coordinator.autoPrintStageTwoAttemptedPopupIDs.contains(ObjectIdentifier(popup))
            completion(nil, nil)
        }

        let printButton: [String: Any] = [
            "root": "document",
            "tagName": "button",
            "tagNameIsExactButton": true,
            "type": "button",
            "typeIsExactButton": true,
            "ariaLabel": "Print",
            "ariaLabelIsExactPrint": true,
            "printMatch": "exact",
            "isVisible": true,
            "isDisabled": false,
            "rect": [0, 0, 32, 32]
        ]
        let settledProbe: [String: Any] = [
            "readyState": "complete",
            "printElements": [printButton]
        ]
        var stageOneResampleCount = 0
        coordinator.autoPrintStageOneReadinessEvaluator = { _, script, completion in
            stageOneResampleCount += 1
            XCTAssertEqual(script, CrewAccessPageProbe.probeExpression)
            completion(settledProbe, nil)
        }
        coordinator.evaluateAutoPrintStageOneEligibility(
            settledProbe,
            webView: popup,
            completedURL: sessionURL,
            attempt: 0,
            sequence: 1
        )

        await waitUntil { stageTwoInvocationCount == 1 }
        await Task.yield()

        XCTAssertEqual(stageOneResampleCount, 1, "the settle delay re-reads the document exactly once")
        XCTAssertEqual(stageOneInvocationCount, 1)
        XCTAssertEqual(readinessCallCount, 1)
        XCTAssertFalse(coordinator.hasPendingAutoPrintStageOneSettleWork)
        XCTAssertEqual(stageTwoInvocationCount, 1)
        XCTAssertTrue(stageTwoOneShotWasConsumedImmediatelyBeforeInvocation)
        XCTAssertTrue(coordinator.autoPrintStageOneAttemptedPopupIDs.contains(ObjectIdentifier(popup)))
        XCTAssertTrue(coordinator.autoPrintStageTwoAttemptedPopupIDs.contains(ObjectIdentifier(popup)))
        XCTAssertFalse(coordinator.hasPendingAutoPrintStageTwoReadinessWork)
    }

    // MARK: - Pre-Stage-1 settle delay

    @MainActor
    private func makeStageOneSettleContext(
        settleDelayNanoseconds: UInt64
    ) -> (
        coordinator: BrowserWebView.Coordinator,
        viewModel: BrowserViewModel,
        popup: FixedURLWebView,
        sessionURL: URL
    ) {
        let viewModel = BrowserViewModel()
        let coordinator = BrowserWebView.Coordinator(
            viewModel: viewModel,
            javaScriptEvaluator: { _, _, completion in completion(nil) }
        )
        let sessionURL = URL(
            string: "https://4d8e06f5.isolation.zscaler.com/profile/00000000-0000-4000-8000-000000000000/zpa-session"
        )!
        let popup = FixedURLWebView()
        popup.fixedURL = sessionURL
        coordinator.popupWebViews.append(popup)
        viewModel.popupWebView = popup
        coordinator.autoPrintStageOneSettleDelayNanoseconds = settleDelayNanoseconds
        coordinator.autoPrintStageTwoReadinessOffsetsNanoseconds = [0]
        return (coordinator, viewModel, popup, sessionURL)
    }

    private func settledStageOneProbe() -> [String: Any] {
        let printButton: [String: Any] = [
            "root": "document",
            "tagName": "button",
            "tagNameIsExactButton": true,
            "type": "button",
            "typeIsExactButton": true,
            "ariaLabel": "Print",
            "ariaLabelIsExactPrint": true,
            "printMatch": "exact",
            "isVisible": true,
            "isDisabled": false,
            "rect": [0, 0, 32, 32]
        ]
        return ["readyState": "complete", "printElements": [printButton]]
    }

    /// Second-popup regression. Popup generation 2 received its attempt-0 probe but never any
    /// bounded follow-up sample, because the resample guard compared the live URL to the captured
    /// one with `==` while the Zscaler client mutates its own query in place. Every new tracked
    /// popup must get the same sampling lifecycle, independently of the popup before it.
    @MainActor
    func test_eachPopupGenerationIndependentlyReachesStageOneAcceptanceAndSettle() async {
        let base = "https://4d8e06f5.isolation.zscaler.com/profile/00000000-0000-4000-8000-000000000000/zpa-session"
        let viewModel = BrowserViewModel()
        let coordinator = BrowserWebView.Coordinator(
            viewModel: viewModel,
            javaScriptEvaluator: { _, _, completion in completion(nil) }
        )
        // Long enough that a started settle stays observably pending.
        coordinator.autoPrintStageOneSettleDelayNanoseconds = 5_000_000_000

        let incomplete: [String: Any] = ["readyState": "loading", "printElements": []]

        func runGeneration(_ label: String) -> FixedURLWebView {
            let popup = FixedURLWebView()
            popup.fixedURL = URL(string: base)!
            coordinator.popupWebViews.append(popup)
            viewModel.popupWebView = popup

            // 1 / 5: the document is not complete when the popup first finishes navigating.
            coordinator.beginCrewAccessProbe(
                incomplete,
                webView: popup,
                completedURL: popup.fixedURL
            )
            XCTAssertTrue(
                coordinator.autoPrintStageOneAttemptedPopupIDs.isEmpty,
                "\(label): an incomplete document must not consume the Stage 1 one-shot"
            )
            XCTAssertTrue(
                coordinator.hasPendingCrewAccessProbeWork,
                "\(label): an incomplete first sample must still schedule bounded follow-up sampling"
            )
            XCTAssertFalse(
                coordinator.hasPendingAutoPrintStageOneSettleWork,
                "\(label): nothing settles until the document is eligible"
            )

            // 2 / 6: the isolation client evolves its own query inside the same session.
            popup.fixedURL = URL(string: base + "?printJob=\(label)&dialog=open")!

            // 3 / 7: a later sample finds the document eligible.
            coordinator.evaluateAutoPrintStageOneEligibility(
                settledStageOneProbe(),
                webView: popup,
                completedURL: popup.fixedURL,
                attempt: 1,
                sequence: 99
            )
            XCTAssertTrue(
                coordinator.hasPendingAutoPrintStageOneSettleWork,
                "\(label): Stage 1 must be accepted and its settle delay started"
            )
            XCTAssertTrue(
                coordinator.autoPrintStageOneAttemptedPopupIDs.isEmpty,
                "\(label): the one-shot stays available for the whole settle"
            )
            return popup
        }

        _ = runGeneration("gen1")

        // 4: tearing down generation 1 must not disable scheduling for generation 2.
        coordinator.closePopups()
        XCTAssertFalse(coordinator.hasPendingCrewAccessProbeWork)
        XCTAssertFalse(coordinator.hasPendingAutoPrintStageOneSettleWork)
        XCTAssertTrue(coordinator.popupWebViews.isEmpty)
        XCTAssertTrue(coordinator.autoPrintStageOneAttemptedPopupIDs.isEmpty)
        XCTAssertTrue(coordinator.autoPrintStageTwoAttemptedPopupIDs.isEmpty)

        // 5-8: generation 2 gets the identical lifecycle from a clean start.
        _ = runGeneration("gen2")
    }

    /// The guard that ended the chain. Same-session query evolution must not look like a
    /// navigation to the sampling schedule.
    func test_stageOneSamplingChainSurvivesSameSessionQueryEvolution() throws {
        let base = "https://4d8e06f5.isolation.zscaler.com/profile/00000000-0000-4000-8000-000000000000/zpa-session"
        let captured = URL(string: base)!
        let evolved = URL(string: base + "?printJob=abc123&dialog=open")!

        XCTAssertNotEqual(captured, evolved, "this is exactly what strict equality rejected")
        XCTAssertTrue(CrewAccessAutoPrint.isSameZscalerSession(captured, evolved))
        XCTAssertFalse(
            CrewAccessAutoPrint.isSameZscalerSession(
                captured,
                URL(string: "https://4d8e06f5.isolation.zscaler.com/profile/11111111-1111-4111-8111-111111111111/zpa-session")
            ),
            "a different profile is still a different session"
        )

        let source = try browserWebViewSource()
        let resample = try XCTUnwrap(
            source
                .components(separatedBy: "private func scheduleCrewAccessProbeResample(")
                .dropFirst()
                .first?
                .components(separatedBy: "func handleAutoPrintStageOneExecutionResult(")
                .first
        )
        XCTAssertFalse(
            resample.contains("webView.url == completedURL"),
            "the resample guard must not use strict URL equality"
        )
        XCTAssertTrue(
            resample.contains("CrewAccessAutoPrint.isSameZscalerSession(completedURL, webView.url)")
        )
        // A terminated chain now says why instead of disappearing.
        XCTAssertTrue(source.contains("stage=1 sampling=ended reason="))
        for reason in ["superseded", "teardown-in-progress", "popup-untracked", "session-changed", "schedule-exhausted"] {
            XCTAssertTrue(source.contains(reason), "missing sampling end reason: \(reason)")
        }
    }

    /// Requirements 1, 2 and 3: nothing is clicked and nothing is consumed until the settle delay
    /// has elapsed, and a second eligible probe sample during the wait cannot start a second one.
    @MainActor
    func test_stageOneWaitsTheSettleDelayKeepsItsOneShotThenInvokesExactlyOnce() async {
        let context = makeStageOneSettleContext(settleDelayNanoseconds: 150_000_000)
        let probe = settledStageOneProbe()

        var resampleCount = 0
        context.coordinator.autoPrintStageOneReadinessEvaluator = { _, script, completion in
            resampleCount += 1
            XCTAssertEqual(script, CrewAccessPageProbe.probeExpression)
            completion(probe, nil)
        }
        var invocationScripts: [String] = []
        context.coordinator.autoPrintStageOneJavaScriptEvaluator = { _, script, completion in
            invocationScripts.append(script)
            // Stage 1 rejected in the page world: this test is about Stage 1 timing only.
            completion(["result": "rejected", "reason": "none", "count": 1], nil)
        }

        context.coordinator.evaluateAutoPrintStageOneEligibility(
            probe,
            webView: context.popup,
            completedURL: context.sessionURL,
            attempt: 0,
            sequence: 1
        )
        XCTAssertTrue(context.coordinator.hasPendingAutoPrintStageOneSettleWork)

        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(resampleCount, 0, "the document is re-read only after the settle delay")
        XCTAssertTrue(invocationScripts.isEmpty, "Stage 1 must not click before the settle delay")
        XCTAssertTrue(
            context.coordinator.autoPrintStageOneAttemptedPopupIDs.isEmpty,
            "the Stage 1 one-shot stays available for the whole wait"
        )

        // The existing probe schedule keeps sampling while the delay runs. The gates are still
        // open — that is the point of leaving the one-shot available — so only the pending-settle
        // guard may stop a second delay from starting.
        context.coordinator.evaluateAutoPrintStageOneEligibility(
            probe,
            webView: context.popup,
            completedURL: context.sessionURL,
            attempt: 1,
            sequence: 1
        )
        XCTAssertTrue(context.coordinator.autoPrintStageOneAttemptedPopupIDs.isEmpty)

        await waitUntil { invocationScripts.count == 1 }
        await Task.yield()

        XCTAssertEqual(resampleCount, 1, "exactly one re-read, from exactly one settle delay")
        XCTAssertEqual(
            invocationScripts,
            [CrewAccessAutoPrint.invocationScript],
            "Stage 1 invokes the frozen script exactly once"
        )
        XCTAssertTrue(
            context.coordinator.autoPrintStageOneAttemptedPopupIDs.contains(ObjectIdentifier(context.popup))
        )
        XCTAssertFalse(context.coordinator.hasPendingAutoPrintStageOneSettleWork)
    }

    /// The physical-device regression. During the settle wait the Zscaler isolation client
    /// evolves its own URL in place and the probe schedule produces newer samples. Neither may
    /// invalidate the settle task: the wait is tied to the popup and its session, not to the probe
    /// snapshot that started it.
    @MainActor
    func test_stageOneSettleSurvivesInPlaceSessionQueryEvolutionAndNewerProbes() async {
        let context = makeStageOneSettleContext(settleDelayNanoseconds: 120_000_000)
        let probe = settledStageOneProbe()
        let base = "https://4d8e06f5.isolation.zscaler.com/profile/00000000-0000-4000-8000-000000000000/zpa-session"

        var resampleCount = 0
        var currentURLAtResample: URL?
        context.coordinator.autoPrintStageOneReadinessEvaluator = { webView, _, completion in
            resampleCount += 1
            currentURLAtResample = webView.url
            completion(probe, nil)
        }
        var invocationScripts: [String] = []
        context.coordinator.autoPrintStageOneJavaScriptEvaluator = { _, script, completion in
            invocationScripts.append(script)
            completion(["result": "rejected", "reason": "none", "count": 1], nil)
        }

        context.coordinator.evaluateAutoPrintStageOneEligibility(
            probe,
            webView: context.popup,
            completedURL: context.sessionURL,
            attempt: 1,
            sequence: 6
        )
        XCTAssertTrue(context.coordinator.hasPendingAutoPrintStageOneSettleWork)

        // The isolation client mutates its own query while the same document stays open, and a
        // newer probe sample lands on the same probe sequence.
        context.popup.fixedURL = URL(string: base + "?printJob=abc123&dialog=open")!
        context.coordinator.evaluateAutoPrintStageOneEligibility(
            probe,
            webView: context.popup,
            completedURL: context.popup.fixedURL,
            attempt: 2,
            sequence: 6
        )
        XCTAssertTrue(
            context.coordinator.hasPendingAutoPrintStageOneSettleWork,
            "a newer probe during the wait must not invalidate the pending settle task"
        )
        XCTAssertTrue(context.coordinator.autoPrintStageOneAttemptedPopupIDs.isEmpty)

        await waitUntil { invocationScripts.count == 1 }
        await Task.yield()

        XCTAssertEqual(resampleCount, 1, "exactly one settle task, so exactly one re-read")
        XCTAssertEqual(
            currentURLAtResample?.absoluteString,
            base + "?printJob=abc123&dialog=open",
            "the elapsed gate must judge the live document, not the snapshot that started the wait"
        )
        XCTAssertEqual(
            invocationScripts,
            [CrewAccessAutoPrint.invocationScript],
            "an in-place query evolution is the same session and must still invoke Stage 1 once"
        )
        XCTAssertTrue(
            context.coordinator.autoPrintStageOneAttemptedPopupIDs.contains(ObjectIdentifier(context.popup))
        )
        XCTAssertFalse(context.coordinator.hasPendingAutoPrintStageOneSettleWork)
    }

    /// The elapsed decision comes from the freshly re-read document, not from the probe that
    /// started the wait: an eligible starting probe followed by a no-longer-eligible fresh read
    /// must not invoke, and the reverse must.
    @MainActor
    func test_stageOneElapsedGateJudgesFreshStateNotTheStartingProbe() async {
        // Eligible at start, no longer eligible when the delay elapses.
        let stale = makeStageOneSettleContext(settleDelayNanoseconds: 40_000_000)
        stale.coordinator.autoPrintStageOneReadinessEvaluator = { _, _, completion in
            completion(["readyState": "interactive", "printElements": []], nil)
        }
        var staleInvocationCount = 0
        stale.coordinator.autoPrintStageOneJavaScriptEvaluator = { _, _, completion in
            staleInvocationCount += 1
            completion(nil, nil)
        }
        stale.coordinator.evaluateAutoPrintStageOneEligibility(
            settledStageOneProbe(),
            webView: stale.popup,
            completedURL: stale.sessionURL,
            attempt: 0,
            sequence: 1
        )
        await waitUntil { !stale.coordinator.hasPendingAutoPrintStageOneSettleWork }
        await Task.yield()
        XCTAssertEqual(
            staleInvocationCount,
            0,
            "a document that is no longer eligible when the delay elapses must not be clicked"
        )
        XCTAssertTrue(stale.coordinator.autoPrintStageOneAttemptedPopupIDs.isEmpty)

        // Eligible at start and still eligible on the fresh read.
        let fresh = makeStageOneSettleContext(settleDelayNanoseconds: 40_000_000)
        let freshProbe = settledStageOneProbe()
        fresh.coordinator.autoPrintStageOneReadinessEvaluator = { _, _, completion in
            completion(freshProbe, nil)
        }
        var freshInvocationCount = 0
        fresh.coordinator.autoPrintStageOneJavaScriptEvaluator = { _, _, completion in
            freshInvocationCount += 1
            completion(["result": "rejected", "reason": "none", "count": 1], nil)
        }
        fresh.coordinator.evaluateAutoPrintStageOneEligibility(
            freshProbe,
            webView: fresh.popup,
            completedURL: fresh.sessionURL,
            attempt: 0,
            sequence: 1
        )
        await waitUntil { freshInvocationCount == 1 }
        await Task.yield()
        XCTAssertEqual(freshInvocationCount, 1)
        XCTAssertTrue(
            fresh.coordinator.autoPrintStageOneAttemptedPopupIDs.contains(ObjectIdentifier(fresh.popup))
        )
    }

    /// Requirement 4: teardown during the wait cancels the settle delay and spends nothing.
    @MainActor
    func test_stageOneSettleDelayIsCancelledByTeardownBeforeItElapses() async {
        let context = makeStageOneSettleContext(settleDelayNanoseconds: 150_000_000)
        let probe = settledStageOneProbe()

        var resampleCount = 0
        context.coordinator.autoPrintStageOneReadinessEvaluator = { _, _, completion in
            resampleCount += 1
            completion(probe, nil)
        }
        var invocationCount = 0
        context.coordinator.autoPrintStageOneJavaScriptEvaluator = { _, _, completion in
            invocationCount += 1
            completion(nil, nil)
        }

        context.coordinator.evaluateAutoPrintStageOneEligibility(
            probe,
            webView: context.popup,
            completedURL: context.sessionURL,
            attempt: 0,
            sequence: 1
        )
        XCTAssertTrue(context.coordinator.hasPendingAutoPrintStageOneSettleWork)

        context.coordinator.closePopups()
        XCTAssertFalse(
            context.coordinator.hasPendingAutoPrintStageOneSettleWork,
            "teardown makes the pending settle delay inert immediately"
        )

        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(resampleCount, 0)
        XCTAssertEqual(invocationCount, 0, "teardown must prevent every later Stage 1 invocation")
        XCTAssertTrue(context.coordinator.autoPrintStageOneAttemptedPopupIDs.isEmpty)
    }

    /// Requirement 5: a popup that was replaced, untracked or navigated during the wait fails the
    /// re-run gates and can never be the thing that gets clicked.
    @MainActor
    func test_stageOneSettleDelayFailsClosedForReplacedUntrackedOrStalePopup() async {
        for rejection in ["replaced-popup", "untracked-popup", "non-session-url", "different-session"] {
            let context = makeStageOneSettleContext(settleDelayNanoseconds: 40_000_000)
            let probe = settledStageOneProbe()

            context.coordinator.autoPrintStageOneReadinessEvaluator = { _, _, completion in
                completion(probe, nil)
            }
            var invocationCount = 0
            context.coordinator.autoPrintStageOneJavaScriptEvaluator = { _, _, completion in
                invocationCount += 1
                completion(nil, nil)
            }

            context.coordinator.evaluateAutoPrintStageOneEligibility(
                probe,
                webView: context.popup,
                completedURL: context.sessionURL,
                attempt: 0,
                sequence: 1
            )
            XCTAssertTrue(context.coordinator.hasPendingAutoPrintStageOneSettleWork)

            switch rejection {
            case "replaced-popup":
                context.viewModel.popupWebView = WKWebView()
            case "untracked-popup":
                context.coordinator.popupWebViews.removeAll()
            case "non-session-url":
                context.popup.fixedURL = URL(string: "https://example.invalid/not-zscaler")!
            default:
                context.popup.fixedURL = URL(
                    string: "https://4d8e06f5.isolation.zscaler.com/profile/11111111-1111-4111-8111-111111111111/zpa-session"
                )!
            }

            try? await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertEqual(invocationCount, 0, "\(rejection) must never invoke Stage 1")
            XCTAssertTrue(
                context.coordinator.autoPrintStageOneAttemptedPopupIDs.isEmpty,
                "\(rejection) must leave the Stage 1 one-shot unconsumed"
            )
            XCTAssertFalse(context.coordinator.hasPendingAutoPrintStageOneSettleWork)
        }
    }

    /// Requirement 6: the user may press the toolbar Print button by hand during the settle window.
    /// The automatic task must fail closed on the state it finds afterwards and must never produce
    /// a second, duplicate automatic action.
    @MainActor
    func test_manualPrintDuringSettleWindowCannotProduceDuplicateAutomaticStageOne() async {
        let context = makeStageOneSettleContext(settleDelayNanoseconds: 80_000_000)
        let probe = settledStageOneProbe()

        var resampleCount = 0
        // A manual press has already opened the Zscaler Print dialog, so the document no longer
        // resolves exactly one qualifying toolbar Print button.
        context.coordinator.autoPrintStageOneReadinessEvaluator = { _, _, completion in
            resampleCount += 1
            completion(["readyState": "complete", "printElements": []], nil)
        }
        var invocationCount = 0
        context.coordinator.autoPrintStageOneJavaScriptEvaluator = { _, _, completion in
            invocationCount += 1
            completion(nil, nil)
        }

        for attempt in 0...3 {
            context.coordinator.evaluateAutoPrintStageOneEligibility(
                probe,
                webView: context.popup,
                completedURL: context.sessionURL,
                attempt: attempt,
                sequence: 1
            )
        }
        XCTAssertTrue(context.coordinator.hasPendingAutoPrintStageOneSettleWork)

        await waitUntil { !context.coordinator.hasPendingAutoPrintStageOneSettleWork }
        await Task.yield()

        XCTAssertEqual(
            resampleCount,
            1,
            "four eligible probe samples must still produce exactly one settle delay"
        )
        XCTAssertEqual(
            invocationCount,
            0,
            "a manual press during the wait must not be followed by an automatic click"
        )
        XCTAssertTrue(context.coordinator.autoPrintStageOneAttemptedPopupIDs.isEmpty)
    }

    @MainActor
    func test_autoPrintStageTwoDoesNotInvokeBeforeDelayThenInvokesExactlyOnce() async {
        let viewModel = BrowserViewModel()
        let coordinator = BrowserWebView.Coordinator(
            viewModel: viewModel,
            javaScriptEvaluator: { _, _, completion in completion(nil) }
        )
        let popup = WKWebView()
        coordinator.popupWebViews.append(popup)
        viewModel.popupWebView = popup

        let sessionURL = URL(
            string: "https://4d8e06f5.isolation.zscaler.com/profile/00000000-0000-4000-8000-000000000000/zpa-session"
        )!
        coordinator.autoPrintStageTwoCurrentURLProvider = { _ in sessionURL }
        coordinator.autoPrintStageTwoReadinessOffsetsNanoseconds = [100_000_000]
        coordinator.autoPrintStageOneAttemptedPopupIDs.insert(ObjectIdentifier(popup))

        func structurallyReadySnapshot() -> [String: Any] {
            [
                "ready": false,
                "buttonReady": true,
                "reason": "report-readiness-unproven",
                "diagnostic": [
                    "dialogCount": 1,
                    "qualifyingDialogCount": 1,
                    "submitButtonCount": 1,
                    "visibleSubmitButtonCount": 1,
                    "qualifyingSubmitButtonCount": 1,
                    "submitButtons": []
                ]
            ]
        }
        let settledSnapshot = structurallyReadySnapshot()

        var readinessCallCount = 0
        var oneShotWasAvailableAtEverySample = true
        var invocationCount = 0
        var invocationCountsAtReadinessSamples: [Int] = []
        coordinator.autoPrintStageTwoReadinessEvaluator = { _, _, completion in
            readinessCallCount += 1
            invocationCountsAtReadinessSamples.append(invocationCount)
            oneShotWasAvailableAtEverySample = oneShotWasAvailableAtEverySample
                && coordinator.autoPrintStageTwoAttemptedPopupIDs.isEmpty
            completion(settledSnapshot, nil)
        }
        coordinator.autoPrintStageTwoJavaScriptEvaluator = { _, script, completion in
            invocationCount += 1
            XCTAssertEqual(script, CrewAccessAutoPrint.stageTwoInvocationScript)
            completion(["result": "invoked", "reason": "none", "count": 1], nil)
        }

        coordinator.handleAutoPrintStageOneExecutionResult(
            "rejected",
            webView: popup,
            completedURL: sessionURL
        )
        XCTAssertFalse(coordinator.hasPendingAutoPrintStageTwoReadinessWork)

        coordinator.handleAutoPrintStageOneExecutionResult(
            "invoked",
            webView: popup,
            completedURL: sessionURL
        )
        XCTAssertTrue(coordinator.hasPendingAutoPrintStageTwoReadinessWork)

        try? await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(readinessCallCount, 0, "the structural preflight must not run before the delay")
        XCTAssertEqual(invocationCount, 0, "Stage 2 must not invoke before the delay")
        XCTAssertTrue(coordinator.autoPrintStageTwoAttemptedPopupIDs.isEmpty)

        await waitUntil { invocationCount == 1 }
        await Task.yield()

        XCTAssertTrue(oneShotWasAvailableAtEverySample)
        XCTAssertEqual(invocationCountsAtReadinessSamples, [0])
        XCTAssertEqual(readinessCallCount, 1)
        XCTAssertEqual(invocationCount, 1)
        XCTAssertTrue(coordinator.autoPrintStageTwoAttemptedPopupIDs.contains(ObjectIdentifier(popup)))
        XCTAssertFalse(coordinator.hasPendingAutoPrintStageTwoReadinessWork)

        coordinator.handleAutoPrintStageOneExecutionResult(
            "invoked",
            webView: popup,
            completedURL: sessionURL
        )
        await Task.yield()
        XCTAssertEqual(readinessCallCount, 1, "a consumed Stage 2 one-shot must not schedule a retry")
        XCTAssertEqual(invocationCount, 1, "an actual Stage 2 attempt is never retried")
    }

    /// Requirement 9: if the Print dialog never becomes structurally ready, Stage 2 walks its
    /// bounded schedule, exhausts, and leaves the one-shot unconsumed.
    @MainActor
    func test_autoPrintStageTwoStructuralGuardFailureNeverConsumesOrInvokes() async {
        let viewModel = BrowserViewModel()
        let coordinator = BrowserWebView.Coordinator(
            viewModel: viewModel,
            javaScriptEvaluator: { _, _, completion in completion(nil) }
        )
        let popup = WKWebView()
        coordinator.popupWebViews.append(popup)
        viewModel.popupWebView = popup
        let sessionURL = URL(
            string: "https://4d8e06f5.isolation.zscaler.com/profile/00000000-0000-4000-8000-000000000000/zpa-session"
        )!
        coordinator.autoPrintStageTwoCurrentURLProvider = { _ in sessionURL }
        coordinator.autoPrintStageTwoReadinessOffsetsNanoseconds = [0, 0, 0]
        coordinator.autoPrintStageOneAttemptedPopupIDs.insert(ObjectIdentifier(popup))

        var readinessCallCount = 0
        coordinator.autoPrintStageTwoReadinessEvaluator = { _, _, completion in
            readinessCallCount += 1
            completion([
                "ready": false,
                "buttonReady": false,
                "reason": "qualifying-dialog-count",
                "diagnostic": [
                    "dialogCount": 0,
                    "qualifyingDialogCount": 0,
                    "submitButtonCount": 0,
                    "visibleSubmitButtonCount": 0,
                    "qualifyingSubmitButtonCount": 0,
                    "submitButtons": []
                ]
            ], nil)
        }
        var invocationCount = 0
        coordinator.autoPrintStageTwoJavaScriptEvaluator = { _, _, completion in
            invocationCount += 1
            completion(nil, nil)
        }
        // The bounded offsets are now the fast path; the event-driven half is what ends the run.
        coordinator.autoPrintStageTwoObserverEvaluator = { _, _, completion in
            completion(["result": "deadline-expired", "elapsedMilliseconds": 8000], nil)
        }

        coordinator.handleAutoPrintStageOneExecutionResult(
            "invoked",
            webView: popup,
            completedURL: sessionURL
        )
        await waitUntil { !coordinator.hasPendingAutoPrintStageTwoReadinessWork }
        await Task.yield()

        XCTAssertEqual(
            readinessCallCount,
            3,
            "a never-ready dialog is sampled once per bounded offset and then the schedule ends"
        )
        XCTAssertEqual(invocationCount, 0)
        XCTAssertTrue(coordinator.autoPrintStageTwoAttemptedPopupIDs.isEmpty)
        XCTAssertFalse(coordinator.hasPendingAutoPrintStageTwoReadinessWork)
    }

    @MainActor
    func test_autoPrintStageTwoScheduleTeardownCancelsPendingCheck() async {
        let viewModel = BrowserViewModel()
        let coordinator = BrowserWebView.Coordinator(
            viewModel: viewModel,
            javaScriptEvaluator: { _, _, completion in completion(nil) }
        )
        let popup = WKWebView()
        coordinator.popupWebViews.append(popup)
        viewModel.popupWebView = popup
        let sessionURL = URL(
            string: "https://4d8e06f5.isolation.zscaler.com/profile/00000000-0000-4000-8000-000000000000/zpa-session"
        )!
        coordinator.autoPrintStageTwoCurrentURLProvider = { _ in sessionURL }
        coordinator.autoPrintStageTwoReadinessOffsetsNanoseconds = [100_000_000]
        coordinator.autoPrintStageOneAttemptedPopupIDs.insert(ObjectIdentifier(popup))

        var readinessCallCount = 0
        var invocationCount = 0
        coordinator.autoPrintStageTwoReadinessEvaluator = { _, _, completion in
            readinessCallCount += 1
            completion(nil, nil)
        }
        coordinator.autoPrintStageTwoJavaScriptEvaluator = { _, _, completion in
            invocationCount += 1
            completion(nil, nil)
        }

        coordinator.handleAutoPrintStageOneExecutionResult(
            "invoked",
            webView: popup,
            completedURL: sessionURL
        )
        XCTAssertTrue(coordinator.hasPendingAutoPrintStageTwoReadinessWork)
        coordinator.closePopups()
        XCTAssertFalse(coordinator.hasPendingAutoPrintStageTwoReadinessWork)

        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(readinessCallCount, 0)
        XCTAssertEqual(invocationCount, 0, "popup teardown must prevent every later invocation")
    }

    @MainActor
    func test_autoPrintPopupTeardownClearsOldIdentityButNewPopupHasFreshOneShots() throws {
        let viewModel = BrowserViewModel()
        let coordinator = BrowserWebView.Coordinator(
            viewModel: viewModel,
            javaScriptEvaluator: { _, script, completion in
                XCTAssertEqual(script, "window.close()")
                completion(nil)
            }
        )
        let firstPopup = WKWebView()
        let firstKey = ObjectIdentifier(firstPopup)
        coordinator.popupWebViews.append(firstPopup)
        viewModel.popupWebView = firstPopup
        coordinator.autoPrintStageOneAttemptedPopupIDs.insert(firstKey)
        coordinator.autoPrintStageTwoAttemptedPopupIDs.insert(firstKey)

        coordinator.closePopups()

        XCTAssertFalse(coordinator.autoPrintStageOneAttemptedPopupIDs.contains(firstKey))
        XCTAssertFalse(coordinator.autoPrintStageTwoAttemptedPopupIDs.contains(firstKey))
        XCTAssertTrue(coordinator.popupWebViews.isEmpty)

        let secondPopup = WKWebView()
        let secondKey = ObjectIdentifier(secondPopup)
        XCTAssertNotEqual(firstKey, secondKey)
        coordinator.popupWebViews.append(secondPopup)
        viewModel.popupWebView = secondPopup
        XCTAssertFalse(coordinator.autoPrintStageOneAttemptedPopupIDs.contains(secondKey))
        XCTAssertFalse(coordinator.autoPrintStageTwoAttemptedPopupIDs.contains(secondKey))

        let source = try browserWebViewSource()
        XCTAssertTrue(source.contains("event=teardown-began teardownGeneration="))
        XCTAssertTrue(source.contains("event=one-shots-cleared teardownGeneration="))
    }

    @MainActor
    func test_autoPrintStageTwoScheduleRejectsStaleURLAndReplacedPopup() async {
        for rejection in ["stale-url", "replaced-popup"] {
            let viewModel = BrowserViewModel()
            let coordinator = BrowserWebView.Coordinator(
                viewModel: viewModel,
                javaScriptEvaluator: { _, _, completion in completion(nil) }
            )
            let popup = WKWebView()
            coordinator.popupWebViews.append(popup)
            viewModel.popupWebView = popup
            let sessionURL = URL(
                string: "https://4d8e06f5.isolation.zscaler.com/profile/00000000-0000-4000-8000-000000000000/zpa-session"
            )!
            var currentURL = sessionURL
            coordinator.autoPrintStageTwoCurrentURLProvider = { _ in currentURL }
            coordinator.autoPrintStageTwoReadinessOffsetsNanoseconds = [20_000_000, 50_000_000, 90_000_000]
            coordinator.autoPrintStageOneAttemptedPopupIDs.insert(ObjectIdentifier(popup))

            var readinessCallCount = 0
            var invocationCount = 0
            coordinator.autoPrintStageTwoReadinessEvaluator = { _, _, completion in
                readinessCallCount += 1
                completion(nil, nil)
            }
            coordinator.autoPrintStageTwoJavaScriptEvaluator = { _, _, completion in
                invocationCount += 1
                completion(nil, nil)
            }

            coordinator.handleAutoPrintStageOneExecutionResult(
                "invoked",
                webView: popup,
                completedURL: sessionURL
            )
            if rejection == "stale-url" {
                currentURL = URL(string: "https://example.invalid/not-zscaler")!
            } else {
                viewModel.popupWebView = WKWebView()
            }

            try? await Task.sleep(nanoseconds: 60_000_000)
            XCTAssertEqual(readinessCallCount, 0, "\(rejection) must fail before Phase A")
            XCTAssertEqual(invocationCount, 0, "\(rejection) must never invoke")
            XCTAssertFalse(coordinator.hasPendingAutoPrintStageTwoReadinessWork)
        }
    }

    @MainActor
    func test_autoPrintStageTwoDirectStructuralPassIgnoresSnapshotStabilityAndDoesNotRetry() {
        let viewModel = BrowserViewModel()
        let coordinator = BrowserWebView.Coordinator(
            viewModel: viewModel,
            javaScriptEvaluator: { _, _, _ in }
        )
        let popup = WKWebView()
        coordinator.popupWebViews.append(popup)
        viewModel.popupWebView = popup

        let sessionURL = URL(
            string: "https://4d8e06f5.isolation.zscaler.com/profile/00000000-0000-4000-8000-000000000000/zpa-session"
        )!
        coordinator.autoPrintStageTwoCurrentURLProvider = { _ in sessionURL }
        // Stage 1 has been attempted on this popup; Stage 2 may not run before that.
        coordinator.autoPrintStageOneAttemptedPopupIDs.insert(ObjectIdentifier(popup))

        let notReady: [String: Any] = [
            "ready": false,
            "reason": "qualifying-dialog-count",
            "diagnostic": [
                "dialogCount": 0,
                "qualifyingDialogCount": 0,
                "submitButtonCount": 0,
                "visibleSubmitButtonCount": 0,
                "qualifyingSubmitButtonCount": 0,
                "submitButtons": []
            ]
        ]
        func ready() -> [String: Any] { [
            "ready": false,
            "buttonReady": true,
            "reason": "report-readiness-unproven",
            "diagnostic": [
                "dialogCount": 1,
                "qualifyingDialogCount": 1,
                "submitButtonCount": 1,
                "visibleSubmitButtonCount": 1,
                "qualifyingSubmitButtonCount": 1,
                "submitButtons": []
            ]
        ] }

        var readinessResult = notReady
        var readinessCallCount = 0
        coordinator.autoPrintStageTwoReadinessEvaluator = { _, _, completion in
            readinessCallCount += 1
            completion(readinessResult, nil)
        }
        var invocationScripts: [String] = []
        coordinator.autoPrintStageTwoJavaScriptEvaluator = { _, script, completion in
            invocationScripts.append(script)
            completion(["result": "invoked", "reason": "none", "count": 1], nil)
        }

        let probe: [String: Any] = ["readyState": "complete"]
        func sample(_ attempt: Int) {
            coordinator.evaluateAutoPrintStageTwoReadiness(
                probe,
                webView: popup,
                completedURL: sessionURL,
                attempt: attempt,
                sequence: 1
            )
        }

        // The dialog does not exist yet: not ready, repeatedly, and nothing is spent.
        sample(0)
        sample(1)
        XCTAssertEqual(readinessCallCount, 2)
        XCTAssertTrue(invocationScripts.isEmpty, "dialogCount=0 must not invoke anything")
        XCTAssertTrue(
            coordinator.autoPrintStageTwoAttemptedPopupIDs.isEmpty,
            "a not-ready readiness result must never consume the Stage 2 one-shot"
        )

        // A structurally ready result invokes immediately; mutation/stability values are irrelevant.
        readinessResult = ready()
        sample(2)
        XCTAssertEqual(readinessCallCount, 3)
        XCTAssertEqual(
            invocationScripts,
            [CrewAccessAutoPrint.stageTwoInvocationScript]
        )
        XCTAssertTrue(coordinator.autoPrintStageTwoAttemptedPopupIDs.contains(ObjectIdentifier(popup)))

        // A later result cannot run another preflight or invocation after the one-shot is consumed.
        readinessResult = ready()
        sample(3)
        XCTAssertEqual(readinessCallCount, 3)
        XCTAssertEqual(invocationScripts.count, 1)
    }

    @MainActor
    private final class ReadinessCounters {
        var readiness = 0
        var invocations = 0
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !(await condition()) {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    func test_phase0ProbeClassifiesTheSurfacesItMustDistinguish() {
        func kind(_ value: String?) -> CrewAccessPageProbe.PageKind {
            CrewAccessPageProbe.pageKind(for: value.flatMap(URL.init(string:)))
        }

        let reportRoot = "https://crewaccess.inside.ups.com/access/rs/reports"
        let syntheticUUID = "00000000-0000-4000-8000-000000000000"

        XCTAssertEqual(
            kind("\(reportRoot)/\(syntheticUUID)/content/Trip_Information_Z99999_01Jan2099.html"),
            .tripInformationReport
        )
        XCTAssertEqual(kind("\(reportRoot)/\(syntheticUUID)/content/Roster_Z99999.html"), .crewAccessReport)
        XCTAssertEqual(kind("https://crewaccess.inside.ups.com/access/home"), .crewAccessOther)
        XCTAssertEqual(kind("https://fltops-portal.ups.com/"), .fltopsPortal)
        XCTAssertEqual(kind("https://gateway.zscaler.net/print"), .zscaler)
        XCTAssertEqual(kind("https://sso.ups.com/login"), .upsOther)
        XCTAssertEqual(kind("https://example.com/anything"), .other)
        XCTAssertEqual(kind(nil), .unknown)

        // Phase 0 is discovery: every UPS or Zscaler surface is worth re-reading, because the
        // Trip Details document has not yet been proven to live on any particular one of them.
        for resampled: CrewAccessPageProbe.PageKind in [
            .tripInformationReport, .crewAccessReport, .crewAccessOther,
            .fltopsPortal, .zscaler, .upsOther
        ] {
            XCTAssertTrue(CrewAccessPageProbe.warrantsResampling(resampled))
        }
        XCTAssertFalse(CrewAccessPageProbe.warrantsResampling(.other))
        XCTAssertFalse(CrewAccessPageProbe.warrantsResampling(.unknown))
    }

    func test_phase0ProbeUrlShapeRedactsIdentifiersAndDropsQueryValues() throws {
        let url = try XCTUnwrap(URL(string:
            "https://crewaccess.inside.ups.com/access/rs/reports"
            + "/00000000-0000-4000-8000-000000000000"
            + "/content/Trip_Information_Z99999_01Jan2099.html"
            + "?sessionToken=shouldNeverBeLogged&sid=alsoNeverLogged"
        ))
        let shape = CrewAccessPageProbe.urlShape(for: url)

        XCTAssertTrue(shape.contains("<uuid>"))
        XCTAssertFalse(shape.contains("00000000-0000-4000-8000-000000000000"))
        XCTAssertTrue(shape.contains("Trip_Information_Z<n>"))
        XCTAssertFalse(shape.contains("99999"))
        XCTAssertFalse(shape.contains("shouldNeverBeLogged"))
        XCTAssertFalse(shape.contains("alsoNeverLogged"))
        XCTAssertTrue(shape.contains("sessionToken"), "parameter names are kept, values are not")
        XCTAssertTrue(shape.contains("sid"))
        XCTAssertEqual(CrewAccessPageProbe.urlShape(for: nil), "<nil>")
    }

    func test_phase0ProbeResampleScheduleIsBounded() {
        let intervals = CrewAccessPageProbe.resampleIntervals
        XCTAssertEqual(intervals, [1, 2, 3, 4])
        XCTAssertLessThanOrEqual(intervals.count, 5, "the probe must not poll indefinitely")
        XCTAssertEqual(intervals.reduce(0, +), 10, "sampling stops 10 seconds after didFinish")
        XCTAssertTrue(intervals.allSatisfy { $0 > 0 })
    }

    /// Sampling is scoped to the one surface auto-print can act on. Every other page — including
    /// other CrewAccess pages — is not re-read at all, so no unrelated navigation pays for this.
    @MainActor
    func test_autoPrintSamplingOnlyFollowsTheTrackedZscalerSessionPopup() {
        func pendingWork(for url: String, trackAsPopup: Bool) -> Bool {
            let viewModel = BrowserViewModel()
            let coordinator = BrowserWebView.Coordinator(
                viewModel: viewModel,
                javaScriptEvaluator: { _, _, _ in }
            )
            let popup = WKWebView()
            if trackAsPopup {
                coordinator.popupWebViews.append(popup)
                viewModel.popupWebView = popup
            }
            coordinator.beginCrewAccessProbe(
                nil,
                webView: popup,
                completedURL: URL(string: url)
            )
            return coordinator.hasPendingCrewAccessProbeWork
        }

        let session = "https://4d8e06f5.isolation.zscaler.com/profile/00000000-0000-4000-8000-000000000000/zpa-session"
        XCTAssertTrue(pendingWork(for: session, trackAsPopup: true))
        XCTAssertFalse(
            pendingWork(for: session, trackAsPopup: false),
            "an untracked WebView on the session URL is never sampled"
        )
        for other in [
            "https://crewaccess.inside.ups.com/access/home",
            "https://crewaccess.inside.ups.com/access/rs/reports/00000000-0000-4000-8000-000000000000/content/Trip_Information.html",
            "https://fltops-portal.ups.com/",
            "https://example.invalid/"
        ] {
            XCTAssertFalse(
                pendingWork(for: other, trackAsPopup: true),
                "auto-print must not sample \(other)"
            )
        }
    }

    @MainActor
    func test_phase0PopupTeardownMakesPendingProbeWorkHarmlessImmediately() {
        let viewModel = BrowserViewModel()
        let coordinator = BrowserWebView.Coordinator(
            viewModel: viewModel,
            javaScriptEvaluator: { _, _, _ in }
        )
        let popup = WKWebView()
        popup.navigationDelegate = coordinator
        popup.uiDelegate = coordinator
        coordinator.popupWebViews.append(popup)
        coordinator.popupParents[ObjectIdentifier(popup)] = WKWebView()
        viewModel.popupWebView = popup

        coordinator.beginCrewAccessProbe(
            nil,
            webView: popup,
            completedURL: URL(
                string: "https://4d8e06f5.isolation.zscaler.com/profile/00000000-0000-4000-8000-000000000000/zpa-session"
            )
        )
        XCTAssertTrue(
            coordinator.hasPendingCrewAccessProbeWork,
            "the probe must actually be pending for this test to mean anything"
        )

        coordinator.closePopups()

        XCTAssertFalse(
            coordinator.hasPendingCrewAccessProbeWork,
            "popup teardown must cancel pending probe work immediately, not at the end of the schedule"
        )
    }

    @MainActor
    func test_phase0PendingProbeDoesNotExtendCoordinatorLifetime() {
        weak var weakCoordinator: BrowserWebView.Coordinator?

        autoreleasepool {
            let viewModel = BrowserViewModel()
            let coordinator = BrowserWebView.Coordinator(
                viewModel: viewModel,
                javaScriptEvaluator: { _, _, _ in }
            )
            let popup = WKWebView()
            coordinator.popupWebViews.append(popup)

            coordinator.beginCrewAccessProbe(
                nil,
                webView: popup,
                completedURL: URL(
                string: "https://4d8e06f5.isolation.zscaler.com/profile/00000000-0000-4000-8000-000000000000/zpa-session"
            )
            )
            XCTAssertTrue(coordinator.hasPendingCrewAccessProbeWork)
            weakCoordinator = coordinator
        }

        XCTAssertNil(
            weakCoordinator,
            "delayed diagnostic work must not keep BrowserWebView.Coordinator alive"
        )
    }

    func test_phase0DelayedProbeWorkUsesWeakOwnership() throws {
        let source = try browserWebViewSource()

        // The eligibility read that starts sampling is the one queued closure sitting outside the
        // auto-print region, so it is pinned literally.
        let samplingEntry = "            ) { [weak self, weak webView] result, _ in\n"
            + "                guard let self, let webView else { return }\n"
            + "                guard webView.url == completedURL else { return }\n"
            + "                self.beginCrewAccessProbe("
        XCTAssertTrue(
            source.contains(samplingEntry),
            "the sampling entry point must capture self and webView weakly"
        )

        guard let region = source
            .components(separatedBy: "// MARK: - CrewAccess auto-print")
            .dropFirst()
            .first?
            .components(separatedBy: "// MARK: PDF検出")
            .first
        else {
            return XCTFail("CrewAccess auto-print region not found")
        }

        // Delayed work never holds the Coordinator, and never holds a WebView strongly. The
        // Stage 1 settle task is the deliberate stricter case: it captures no WebView at all, not
        // even weakly, because after the wait it re-resolves the popup from tracked state — a
        // captured reference could otherwise outlive the popup's place in that collection.
        var sawSettleTaskWithoutWebViewCapture = false
        for line in region.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("DispatchQueue.") || trimmed.hasPrefix("Task {")
                || trimmed.contains("= Task {") else { continue }
            XCTAssertTrue(
                trimmed.contains("[weak self"),
                "delayed work must capture self weakly: \(trimmed)"
            )
            if trimmed.contains("webView") {
                XCTAssertTrue(
                    trimmed.contains("weak webView"),
                    "delayed work may never capture the WebView strongly: \(trimmed)"
                )
            } else if trimmed.contains("autoPrintStageOneSettleTasks[key] = Task") {
                sawSettleTaskWithoutWebViewCapture = true
            }
        }
        XCTAssertTrue(
            sawSettleTaskWithoutWebViewCapture,
            "the Stage 1 settle task must capture no WebView and re-resolve the popup instead"
        )
        XCTAssertTrue(
            source.contains("guard let webView = popupWebViews.first(where: { ObjectIdentifier($0) == key })"),
            "the settle task must re-resolve its popup from the tracked collection"
        )

        // The probe's own state must never be able to retain a WebView: every collection is keyed
        // by ObjectIdentifier, which does not retain, and none of them stores a WebView.
        XCTAssertTrue(source.contains("crewAccessProbeTasks: [ObjectIdentifier: Task<Void, Never>]"))
        XCTAssertTrue(source.contains("crewAccessProbeSequences: [ObjectIdentifier: UInt]"))
        for line in source.components(separatedBy: "\n")
        where line.contains("var ") && line.lowercased().contains("crewaccessprobe") {
            XCTAssertFalse(
                line.contains("WKWebView"),
                "no probe property may store a WKWebView: \(line.trimmingCharacters(in: .whitespaces))"
            )
        }

        // Teardown cancels; it does not merely mark work stale.
        XCTAssertTrue(source.contains("cancelCrewAccessProbe(for: popup)"))
        XCTAssertTrue(source.contains("crewAccessProbeTasks.removeValue(forKey: key)?.cancel()"))
        XCTAssertTrue(source.contains("guard !Task.isCancelled, let self, let webView else { return }"))
    }
    #endif
}


// MARK: - Terminal auto-print state

/// Every terminal auto-import path has to end in exactly one of three places: Import Preview, the
/// recoverable failure alert, or an explicit cancellation. A path that simply stops — Stage 1's
/// bounded sampling reaching `schedule-exhausted` is the one seen on a physical device — used to
/// leave `Importing Trip…` on screen forever, waiting for a PDF callback that could never arrive.
@MainActor
final class CrewAccessAutoPrintTerminalStateTests: XCTestCase {

    private final class FixedURLWebView: WKWebView {
        var fixedURL: URL?

        override var url: URL? {
            fixedURL ?? super.url
        }
    }

    private static let sessionURLString =
        "https://4d8e06f5.isolation.zscaler.com/profile/00000000-0000-4000-8000-000000000000/zpa-session"

    private struct Fixture {
        let viewModel: BrowserViewModel
        let coordinator: BrowserWebView.Coordinator
        let popup: FixedURLWebView
        let importAttempts: @MainActor () -> Int
        let readinessEvaluations: @MainActor () -> Int
    }

    @MainActor
    private final class Counter {
        var value = 0
    }

    /// A tracked Zscaler session popup with the loading cover already on screen, exactly as
    /// `beginCrewAccessAutoPrintSamplingIfNeeded` leaves it.
    private func makeImportingFixture() -> Fixture {
        let viewModel = BrowserViewModel()
        let imports = Counter()
        let readiness = Counter()
        let coordinator = BrowserWebView.Coordinator(
            viewModel: viewModel,
            pdfDataHandler: { _, _, completion in
                imports.value += 1
                completion(.incompleteTrip)
            },
            javaScriptEvaluator: { _, _, completion in completion(nil) }
        )
        coordinator.autoPrintStageOneReadinessEvaluator = { _, _, completion in
            readiness.value += 1
            completion(nil, nil)
        }
        // Default fixture posture: a clean page (no inherited dialog) and an event-driven Stage 2
        // half that reaches its deadline. Individual tests override either.
        coordinator.autoPrintStageTwoReadinessEvaluator = { _, _, completion in
            completion(["diagnostic": ["dialogCount": 0, "qualifyingDialogCount": 0]], nil)
        }
        coordinator.autoPrintStageTwoObserverEvaluator = { _, _, completion in
            completion(["result": "deadline-expired", "elapsedMilliseconds": 8000], nil)
        }
        let popup = FixedURLWebView()
        popup.fixedURL = URL(string: Self.sessionURLString)
        coordinator.popupWebViews = [popup]
        viewModel.popupWebView = popup
        viewModel.beginCrewAccessImportingPresentation()
        return Fixture(
            viewModel: viewModel,
            coordinator: coordinator,
            popup: popup,
            importAttempts: { imports.value },
            readinessEvaluations: { readiness.value }
        )
    }

    /// A document that is still loading: eligible for sampling, never eligible for invocation.
    private func incompleteProbe() -> [String: Any] {
        ["readyState": "loading", "printElements": []]
    }

    private func settledStageOneProbe() -> [String: Any] {
        let printButton: [String: Any] = [
            "root": "document",
            "tagName": "button",
            "tagNameIsExactButton": true,
            "type": "button",
            "typeIsExactButton": true,
            "ariaLabel": "Print",
            "ariaLabelIsExactPrint": true,
            "printMatch": "exact",
            "isVisible": true,
            "isDisabled": false,
            "rect": [0, 0, 32, 32]
        ]
        return ["readyState": "complete", "printElements": [printButton]]
    }

    /// Drives the production Stage 1 chain to its `schedule-exhausted` terminus without waiting out
    /// the real ten-second schedule: an empty interval list is the same terminal branch the last
    /// real interval reaches, taken on the first resample decision.
    private func exhaustStageOneSampling(_ fixture: Fixture) {
        fixture.coordinator.crewAccessProbeResampleIntervals = []
        fixture.coordinator.beginCrewAccessProbe(
            incompleteProbe(),
            webView: fixture.popup,
            completedURL: fixture.popup.fixedURL
        )
    }

    func test_productionResampleScheduleIsUnchangedByTheTestSeam() {
        let coordinator = BrowserWebView.Coordinator(
            viewModel: BrowserViewModel(),
            javaScriptEvaluator: { _, _, completion in completion(nil) }
        )

        XCTAssertEqual(coordinator.crewAccessProbeResampleIntervals, CrewAccessPageProbe.resampleIntervals)
        XCTAssertEqual(CrewAccessPageProbe.resampleIntervals, [1, 2, 3, 4])
        XCTAssertEqual(
            coordinator.autoPrintStageOneSettleDelayNanoseconds,
            CrewAccessAutoPrint.stageOneSettleDelayNanoseconds,
            "the terminal-state fix must not touch the canonical settle delay"
        )
        XCTAssertEqual(CrewAccessAutoPrint.stageOneSettleDelayNanoseconds, 4_000_000_000)
    }

    // 1. Stage 1 exhaustion clears the loading state.
    func test_stageOneScheduleExhaustionClearsImportingLoadingState() {
        let fixture = makeImportingFixture()
        XCTAssertTrue(fixture.viewModel.isImportingCrewAccessTrip)

        exhaustStageOneSampling(fixture)

        XCTAssertFalse(
            fixture.viewModel.isImportingCrewAccessTrip,
            "a terminal Stage 1 exhaustion must take the Importing Trip… cover down"
        )
        XCTAssertFalse(fixture.coordinator.hasPendingCrewAccessProbeWork)
        XCTAssertFalse(fixture.coordinator.hasPendingCrewAccessAutoPrintWorkForTrackedPopup)
    }

    // 2. Stage 1 exhaustion produces the recoverable failure state.
    func test_stageOneScheduleExhaustionPresentsRecoverableFailure() {
        let fixture = makeImportingFixture()

        exhaustStageOneSampling(fixture)

        XCTAssertNotNil(
            fixture.viewModel.incompleteImportFailure,
            "exhaustion is an import attempt failure, not silence"
        )
        XCTAssertEqual(fixture.viewModel.statusMessage, "⚠️ Unable to import trip")
        XCTAssertFalse(fixture.viewModel.isAutoPrintRetryInProgress)
        XCTAssertTrue(
            fixture.coordinator.popupWebViews.first === fixture.popup,
            "the tracked popup is retained so Try Again has something to act on"
        )
    }

    // 3. Try Again re-enters the existing auto-print path.
    func test_tryAgainAfterStageOneExhaustionReentersExistingAutoPrintPath() {
        let fixture = makeImportingFixture()
        exhaustStageOneSampling(fixture)
        XCTAssertEqual(fixture.readinessEvaluations(), 0)
        fixture.coordinator.crewAccessProbeResampleIntervals = CrewAccessPageProbe.resampleIntervals

        XCTAssertTrue(fixture.viewModel.tryAgainIncompleteImport())

        XCTAssertEqual(
            fixture.readinessEvaluations(),
            1,
            "retry must run the existing beginCrewAccessAutoPrintSamplingIfNeeded path, not a parallel one"
        )
        XCTAssertTrue(fixture.viewModel.isImportingCrewAccessTrip)
        XCTAssertNil(fixture.viewModel.incompleteImportFailure)
        XCTAssertTrue(fixture.coordinator.isAutoPrintRetryInFlight)
        XCTAssertEqual(
            fixture.coordinator.autoPrintStageOneSettleDelayNanoseconds,
            CrewAccessAutoPrint.stageOneSettleDelayNanoseconds,
            "the retry reuses the canonical 4.0-second production delay"
        )

        fixture.coordinator.closePopups()
    }

    // 4. Retry cannot create concurrent sampling tasks.
    func test_retryAfterStageOneExhaustionCannotCreateConcurrentSamplingTasks() {
        let fixture = makeImportingFixture()
        exhaustStageOneSampling(fixture)
        fixture.coordinator.crewAccessProbeResampleIntervals = CrewAccessPageProbe.resampleIntervals

        XCTAssertTrue(fixture.viewModel.tryAgainIncompleteImport())
        XCTAssertFalse(
            fixture.viewModel.tryAgainIncompleteImport(),
            "a retry already in flight cannot start a second one"
        )
        XCTAssertFalse(
            fixture.coordinator.retryCrewAccessAutoPrintIfPossible(),
            "the coordinator refuses a second retry directly as well"
        )
        XCTAssertEqual(fixture.readinessEvaluations(), 1)
        XCTAssertTrue(fixture.coordinator.isAutoPrintRetryInFlight)

        fixture.coordinator.closePopups()
    }

    // 5. Cancel clears the loading state and starts no retry.
    func test_cancelAfterStageOneExhaustionClearsLoadingStateAndStartsNoRetry() {
        let fixture = makeImportingFixture()
        exhaustStageOneSampling(fixture)
        fixture.coordinator.crewAccessProbeResampleIntervals = CrewAccessPageProbe.resampleIntervals

        fixture.viewModel.cancelIncompleteImport()

        XCTAssertNil(fixture.viewModel.incompleteImportFailure)
        XCTAssertFalse(fixture.viewModel.isImportingCrewAccessTrip)
        XCTAssertEqual(fixture.viewModel.statusMessage, "CrewAccess import canceled.")
        XCTAssertEqual(fixture.readinessEvaluations(), 0, "Cancel must not re-enter the auto-print path")
        XCTAssertEqual(fixture.importAttempts(), 0, "Cancel imports nothing")
        XCTAssertFalse(fixture.coordinator.isAutoPrintRetryInFlight)
        XCTAssertFalse(
            fixture.coordinator.hasPendingCrewAccessAutoPrintWorkForTrackedPopup,
            "Cancel stops every remaining sampling task"
        )
        XCTAssertTrue(
            fixture.coordinator.popupWebViews.first === fixture.popup,
            "the browser is left usable rather than torn down underneath the user"
        )
    }

    // 6. Successful Stage 1 behaviour is unchanged.
    func test_successfulStageOneRunIsNotConvertedIntoAFailure() {
        let fixture = makeImportingFixture()
        fixture.coordinator.autoPrintStageOneSettleDelayNanoseconds = 5_000_000_000
        fixture.coordinator.crewAccessProbeResampleIntervals = []

        // The probe chain keeps sampling in parallel with the settle delay, so the chain reaching
        // its bound while Stage 1 is still settling is the normal success path, not a failure.
        fixture.coordinator.beginCrewAccessProbe(
            settledStageOneProbe(),
            webView: fixture.popup,
            completedURL: fixture.popup.fixedURL
        )

        XCTAssertTrue(
            fixture.coordinator.hasPendingAutoPrintStageOneSettleWork,
            "an eligible sample must still start the settle delay"
        )
        XCTAssertTrue(
            fixture.viewModel.isImportingCrewAccessTrip,
            "a run that is still settling must keep its loading state"
        )
        XCTAssertNil(fixture.viewModel.incompleteImportFailure)
        XCTAssertTrue(fixture.coordinator.autoPrintStageOneAttemptedPopupIDs.isEmpty)

        fixture.coordinator.closePopups()
    }

    // 7. The existing incomplete-trip retry still works.
    func test_existingIncompleteTripRetryStillWorks() {
        let fixture = makeImportingFixture()

        fixture.coordinator.handleDownloadedPDFResult(
            data: Data("%PDF incomplete".utf8),
            response: nil,
            error: nil,
            sourceFileName: "attempt-1.pdf"
        )

        XCTAssertEqual(fixture.importAttempts(), 1)
        XCTAssertTrue(
            fixture.viewModel.isImportingCrewAccessTrip,
            "the incomplete-trip path keeps its cover behind the alert, as before"
        )

        let key = ObjectIdentifier(fixture.popup)
        fixture.coordinator.autoPrintStageOneAttemptedPopupIDs.insert(key)
        fixture.coordinator.autoPrintStageTwoAttemptedPopupIDs.insert(key)

        XCTAssertTrue(fixture.coordinator.retryCrewAccessAutoPrintIfPossible())
        XCTAssertEqual(fixture.readinessEvaluations(), 1)
        XCTAssertTrue(fixture.coordinator.isAutoPrintRetryInFlight)
        XCTAssertFalse(fixture.coordinator.autoPrintStageOneAttemptedPopupIDs.contains(key))
        XCTAssertFalse(fixture.coordinator.autoPrintStageTwoAttemptedPopupIDs.contains(key))

        fixture.coordinator.closePopups()
    }

    // 8. No PDF callback is required to escape the loading state.
    func test_noPDFCallbackIsRequiredToEscapeLoadingAfterStageOneExhaustion() {
        let fixture = makeImportingFixture()

        exhaustStageOneSampling(fixture)

        XCTAssertEqual(
            fixture.importAttempts(),
            0,
            "the loading state was left without any PDF ever arriving"
        )
        XCTAssertFalse(fixture.viewModel.isImportingCrewAccessTrip)
        XCTAssertNotNil(fixture.viewModel.incompleteImportFailure)

        // A late callback for a run the user already owns is still ignored, as before.
        fixture.coordinator.handleDownloadedPDFResult(
            data: Data("%PDF late".utf8),
            response: nil,
            error: nil,
            sourceFileName: "late.pdf"
        )
        XCTAssertEqual(fixture.importAttempts(), 0)
    }

    // 9. The equivalent terminal Stage 2 path is audited too.
    func test_stageTwoReadinessScheduleExhaustionAlsoEndsTheImportingState() {
        let fixture = makeImportingFixture()
        let sessionURL = fixture.popup.fixedURL
        fixture.coordinator.autoPrintStageTwoCurrentURLProvider = { _ in sessionURL }
        fixture.coordinator.autoPrintStageTwoReadinessOffsetsNanoseconds = []
        fixture.coordinator.autoPrintStageOneAttemptedPopupIDs.insert(ObjectIdentifier(fixture.popup))

        fixture.coordinator.handleAutoPrintStageOneExecutionResult(
            "invoked",
            webView: fixture.popup,
            completedURL: sessionURL
        )

        XCTAssertFalse(fixture.coordinator.hasPendingAutoPrintStageTwoReadinessWork)
        XCTAssertEqual(fixture.coordinator.lastTerminalFailure?.stage, 2)
        XCTAssertFalse(
            fixture.viewModel.isImportingCrewAccessTrip,
            "Stage 2 exhaustion must not leave Importing Trip… on screen either"
        )
        XCTAssertNotNil(fixture.viewModel.incompleteImportFailure)
        XCTAssertTrue(
            fixture.coordinator.autoPrintStageTwoAttemptedPopupIDs.isEmpty,
            "exhaustion never consumes the Stage 2 one-shot"
        )
    }

    /// Source guard: the terminal funnel is the only writer of the failure state on these paths, so
    /// a future path that forgets to call it is visible here rather than on a device.
    func test_everyTerminalAutoPrintPathFunnelsThroughTheSameConversion() throws {
        let projectRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: projectRoot.appendingPathComponent("TripDataHub/Views/BrowserWebView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("private func failCrewAccessAutoPrintIfTerminal("))
        XCTAssertTrue(source.contains("private func hasPendingCrewAccessAutoPrintWork(forKey key: ObjectIdentifier) -> Bool"))
        XCTAssertTrue(source.contains("terminal=failure"))
        XCTAssertTrue(source.contains("retryAvailable="))
        XCTAssertTrue(source.contains("func cancelCrewAccessAutoPrint()"))
        XCTAssertEqual(
            source.components(separatedBy: "viewModel.presentIncompleteImportFailure()").count - 1,
            1,
            "the coordinator presents the recoverable failure from exactly one place"
        )
        XCTAssertTrue(
            source.contains("static let stageOneSettleDelayNanoseconds: UInt64 = 4_000_000_000")
                || source.contains("stageOneSettleDelayNanoseconds: UInt64 = 4_000_000_000"),
            "the canonical production delay is unchanged"
        )
        // The diagnostic must never carry page contents.
        for line in source.components(separatedBy: "\n") where line.contains("terminal=failure") {
            XCTAssertFalse(line.contains("pageText"))
            XCTAssertFalse(line.contains("innerText"))
        }
    }
}


// MARK: - Stage ownership, event-driven Stage 2 readiness, retry independence

/// The device sequence these cover: Stage 1 succeeded, Stage 2's three fixed samples all reported
/// `dialogCount=0`, and the run was then reported as `stage=1 terminal=failure` — because Stage 1's
/// sampling chain was still registered, muted Stage 2's own report, and was last to finish.
@MainActor
final class CrewAccessAutoPrintStageOwnershipTests: XCTestCase {

    private final class FixedURLWebView: WKWebView {
        var fixedURL: URL?

        override var url: URL? {
            fixedURL ?? super.url
        }
    }

    @MainActor
    private final class Counters {
        var stageOneReadiness = 0
        var stageTwoReadiness = 0
        var stageTwoInvocations = 0
        var observerStarts = 0
        var census = 0
    }

    private static let sessionURLString =
        "https://4d8e06f5.isolation.zscaler.com/profile/00000000-0000-4000-8000-000000000000/zpa-session"

    private struct Fixture {
        let viewModel: BrowserViewModel
        let coordinator: BrowserWebView.Coordinator
        let popup: FixedURLWebView
        let counters: Counters
    }

    private func structurallyReadySnapshot() -> [String: Any] {
        [
            "ready": false,
            "buttonReady": true,
            "reason": "report-readiness-unproven",
            "diagnostic": [
                "dialogCount": 1,
                "qualifyingDialogCount": 1,
                "submitButtonCount": 1,
                "visibleSubmitButtonCount": 1,
                "qualifyingSubmitButtonCount": 1,
                "submitButtons": []
            ]
        ]
    }

    private func noDialogSnapshot() -> [String: Any] {
        [
            "ready": false,
            "buttonReady": false,
            "reason": "qualifying-dialog-count",
            "diagnostic": [
                "dialogCount": 0,
                "qualifyingDialogCount": 0,
                "submitButtonCount": 0,
                "visibleSubmitButtonCount": 0,
                "qualifyingSubmitButtonCount": 0,
                "submitButtons": []
            ]
        ]
    }

    private func settledStageOneProbe() -> [String: Any] {
        let printButton: [String: Any] = [
            "root": "document",
            "tagName": "button",
            "tagNameIsExactButton": true,
            "type": "button",
            "typeIsExactButton": true,
            "ariaLabel": "Print",
            "ariaLabelIsExactPrint": true,
            "printMatch": "exact",
            "isVisible": true,
            "isDisabled": false,
            "rect": [0, 0, 32, 32]
        ]
        return ["readyState": "complete", "printElements": [printButton]]
    }

    /// A tracked session popup with the cover raised, Stage 2's fixed offsets emptied so the fast
    /// path falls straight through to the event-driven half, and every seam declared.
    private func makeFixture(
        observerOutcome: String = "deadline-expired",
        readinessSnapshot: [String: Any]? = nil
    ) -> Fixture {
        let viewModel = BrowserViewModel()
        let counters = Counters()
        let coordinator = BrowserWebView.Coordinator(
            viewModel: viewModel,
            pdfDataHandler: { _, _, completion in completion(.incompleteTrip) },
            javaScriptEvaluator: { _, _, completion in completion(nil) }
        )
        let popup = FixedURLWebView()
        popup.fixedURL = URL(string: Self.sessionURLString)
        let sessionURL = popup.fixedURL

        coordinator.autoPrintStageOneReadinessEvaluator = { _, _, completion in
            counters.stageOneReadiness += 1
            completion(nil, nil)
        }
        coordinator.autoPrintStageTwoCurrentURLProvider = { _ in sessionURL }
        coordinator.autoPrintStageTwoReadinessOffsetsNanoseconds = []
        let snapshot = readinessSnapshot ?? noDialogSnapshot()
        coordinator.autoPrintStageTwoReadinessEvaluator = { _, _, completion in
            counters.stageTwoReadiness += 1
            completion(snapshot, nil)
        }
        coordinator.autoPrintStageTwoObserverEvaluator = { _, script, completion in
            counters.observerStarts += 1
            XCTAssertTrue(script.contains("MutationObserver"), "the observer waits on a DOM event")
            completion(["result": observerOutcome, "elapsedMilliseconds": 1200], nil)
        }
        coordinator.autoPrintStageTwoJavaScriptEvaluator = { _, _, completion in
            counters.stageTwoInvocations += 1
            completion(["result": "invoked", "reason": "none", "count": 1], nil)
        }
        coordinator.popupWebViews = [popup]
        viewModel.popupWebView = popup
        viewModel.beginCrewAccessImportingPresentation()
        return Fixture(viewModel: viewModel, coordinator: coordinator, popup: popup, counters: counters)
    }

    // RCA 1. Stage 1 invoked -> probe chain is no longer registered.
    func test_stageOneInvocationRetiresItsOwnSamplingChain() {
        let fixture = makeFixture()
        fixture.coordinator.crewAccessProbeResampleIntervals = [1, 2, 3, 4]
        fixture.coordinator.beginCrewAccessProbe(
            ["readyState": "loading", "printElements": []],
            webView: fixture.popup,
            completedURL: fixture.popup.fixedURL
        )
        XCTAssertTrue(fixture.coordinator.hasPendingCrewAccessProbeWork)

        fixture.coordinator.autoPrintStageOneAttemptedPopupIDs.insert(ObjectIdentifier(fixture.popup))
        fixture.coordinator.handleAutoPrintStageOneExecutionResult(
            "invoked",
            webView: fixture.popup,
            completedURL: fixture.popup.fixedURL
        )

        XCTAssertFalse(
            fixture.coordinator.hasPendingCrewAccessProbeWork,
            "Stage 2 owns forward progress once Stage 1 has invoked"
        )
    }

    // RCA 2. Stage 2 exhaustion authors a stage=2 failure, never stage=1.
    func test_stageTwoExhaustionAuthorsStageTwoFailure() {
        let fixture = makeFixture(observerOutcome: "deadline-expired")
        fixture.coordinator.autoPrintStageOneAttemptedPopupIDs.insert(ObjectIdentifier(fixture.popup))

        fixture.coordinator.handleAutoPrintStageOneExecutionResult(
            "invoked",
            webView: fixture.popup,
            completedURL: fixture.popup.fixedURL
        )

        XCTAssertEqual(fixture.counters.observerStarts, 1)
        let record = fixture.coordinator.lastTerminalFailure
        XCTAssertEqual(record?.stage, 2, "the stage that diagnosed the failure is the one reported")
        XCTAssertEqual(record?.reason, "readiness-observer-deadline-expired")
        XCTAssertFalse(fixture.viewModel.isImportingCrewAccessTrip)
        XCTAssertNotNil(fixture.viewModel.incompleteImportFailure)
    }

    // RCA 3. Stage 1 sampling exhaustion alone never authors a failure once its one-shot is spent.
    func test_stageOneSamplingExhaustionCannotAuthorFailureAfterOneShotConsumed() {
        let fixture = makeFixture()
        fixture.coordinator.autoPrintStageOneAttemptedPopupIDs.insert(ObjectIdentifier(fixture.popup))
        fixture.coordinator.crewAccessProbeResampleIntervals = []

        fixture.coordinator.beginCrewAccessProbe(
            ["readyState": "loading", "printElements": []],
            webView: fixture.popup,
            completedURL: fixture.popup.fixedURL
        )

        XCTAssertFalse(fixture.coordinator.hasPendingCrewAccessProbeWork)
        XCTAssertEqual(
            fixture.coordinator.terminalFailureCount,
            0,
            "a sampler that can only answer one-shot-already-consumed may not diagnose the run"
        )
        XCTAssertNil(fixture.coordinator.lastTerminalFailure)
    }

    // RCA 4. Regression guard: exactly one terminal failure, loading cleared, no hang.
    func test_stageOneSucceedsStageTwoExhaustsExactlyOneTerminalFailure() {
        let fixture = makeFixture(observerOutcome: "deadline-expired")
        fixture.coordinator.crewAccessProbeResampleIntervals = []
        fixture.coordinator.autoPrintStageOneAttemptedPopupIDs.insert(ObjectIdentifier(fixture.popup))

        fixture.coordinator.handleAutoPrintStageOneExecutionResult(
            "invoked",
            webView: fixture.popup,
            completedURL: fixture.popup.fixedURL
        )
        XCTAssertEqual(fixture.coordinator.terminalFailureCount, 1)

        // A late sampling chain for the same popup must not add a second terminus.
        fixture.coordinator.beginCrewAccessProbe(
            ["readyState": "loading", "printElements": []],
            webView: fixture.popup,
            completedURL: fixture.popup.fixedURL
        )

        XCTAssertEqual(fixture.coordinator.terminalFailureCount, 1)
        XCTAssertEqual(fixture.coordinator.lastTerminalFailure?.stage, 2)
        XCTAssertFalse(fixture.viewModel.isImportingCrewAccessTrip)
        XCTAssertFalse(fixture.coordinator.hasPendingCrewAccessAutoPrintWorkForTrackedPopup)
    }

    // RCA 5. A dialog inserted after the last fixed offset is still detected and invoked.
    func test_dialogInsertedAfterTheFixedOffsetsIsStillDetectedAndInvoked() {
        let fixture = makeFixture(
            observerOutcome: "dialog-inserted",
            readinessSnapshot: structurallyReadySnapshot()
        )
        fixture.coordinator.autoPrintStageOneAttemptedPopupIDs.insert(ObjectIdentifier(fixture.popup))

        fixture.coordinator.handleAutoPrintStageOneExecutionResult(
            "invoked",
            webView: fixture.popup,
            completedURL: fixture.popup.fixedURL
        )

        XCTAssertEqual(fixture.counters.observerStarts, 1)
        XCTAssertEqual(
            fixture.counters.stageTwoInvocations,
            1,
            "a late dialog is invoked, not abandoned at 500 ms"
        )
        XCTAssertEqual(fixture.counters.stageTwoReadiness, 1, "the observer wakes the existing gate")
        XCTAssertTrue(
            fixture.coordinator.autoPrintStageTwoAttemptedPopupIDs.contains(ObjectIdentifier(fixture.popup))
        )
        XCTAssertEqual(fixture.coordinator.terminalFailureCount, 0)
        XCTAssertTrue(
            fixture.viewModel.isImportingCrewAccessTrip,
            "an invoked Stage 2 is still waiting on print output, so the cover stays up"
        )
    }

    // RCA 6. The observer is bounded and a late result after teardown restarts nothing.
    func test_observerResultArrivingAfterTeardownIsInert() {
        let fixture = makeFixture()
        var pendingCompletion: (@MainActor (Any?, Error?) -> Void)?
        fixture.coordinator.autoPrintStageTwoObserverEvaluator = { _, _, completion in
            pendingCompletion = completion
        }
        fixture.coordinator.autoPrintStageOneAttemptedPopupIDs.insert(ObjectIdentifier(fixture.popup))

        fixture.coordinator.handleAutoPrintStageOneExecutionResult(
            "invoked",
            webView: fixture.popup,
            completedURL: fixture.popup.fixedURL
        )
        XCTAssertTrue(fixture.coordinator.hasPendingAutoPrintStageTwoReadinessWork)
        let readinessBefore = fixture.counters.stageTwoReadiness

        fixture.coordinator.closePopups()
        pendingCompletion?(["result": "dialog-inserted", "elapsedMilliseconds": 1200], nil)

        XCTAssertEqual(
            fixture.counters.stageTwoReadiness,
            readinessBefore,
            "a superseded observer result must not restart the Stage 2 gate"
        )
        XCTAssertEqual(fixture.counters.stageTwoInvocations, 0)
        XCTAssertFalse(fixture.coordinator.hasPendingAutoPrintStageTwoReadinessWork)
    }

    // RCA 7. A retry that finds a prior attempt's dialog cannot succeed by inheriting it.
    func test_retryWithPreexistingDialogIsRefusedAndInheritsNothing() {
        let fixture = makeFixture()
        let key = ObjectIdentifier(fixture.popup)
        fixture.coordinator.autoPrintStageOneAttemptedPopupIDs.insert(key)
        fixture.coordinator.autoPrintStageTwoAttemptedPopupIDs.insert(key)
        fixture.coordinator.handleDownloadedPDFResult(
            data: Data("%PDF incomplete".utf8),
            response: nil,
            error: nil,
            sourceFileName: "attempt-1.pdf"
        )
        // The previous attempt left its print dialog mounted.
        fixture.coordinator.autoPrintStageTwoReadinessEvaluator = { _, _, completion in
            fixture.counters.census += 1
            completion(["diagnostic": ["dialogCount": 1, "qualifyingDialogCount": 1]], nil)
        }
        let stageOneReadinessBefore = fixture.counters.stageOneReadiness

        XCTAssertTrue(fixture.coordinator.retryCrewAccessAutoPrintIfPossible())

        XCTAssertEqual(fixture.counters.census, 1, "every retry is censused before it may click Print")
        XCTAssertEqual(
            fixture.counters.stageOneReadiness,
            stageOneReadinessBefore,
            "a refused retry never starts Stage 1 sampling"
        )
        XCTAssertEqual(fixture.counters.stageTwoInvocations, 0, "inherited UI is never submitted")
        XCTAssertEqual(fixture.coordinator.lastTerminalFailure?.reason, "retry-inherited-dialog")
        XCTAssertFalse(fixture.coordinator.isAutoPrintRetryInFlight)
        XCTAssertFalse(fixture.viewModel.isImportingCrewAccessTrip)
        XCTAssertNotNil(fixture.viewModel.incompleteImportFailure)
    }

    /// The clean counterpart: a censused-clean page retries normally through the existing path.
    func test_retryWithCleanCensusReentersTheExistingAutoPrintPath() {
        let fixture = makeFixture()
        let key = ObjectIdentifier(fixture.popup)
        fixture.coordinator.autoPrintStageOneAttemptedPopupIDs.insert(key)
        fixture.coordinator.autoPrintStageTwoAttemptedPopupIDs.insert(key)
        fixture.coordinator.handleDownloadedPDFResult(
            data: Data("%PDF incomplete".utf8),
            response: nil,
            error: nil,
            sourceFileName: "attempt-1.pdf"
        )
        let stageOneReadinessBefore = fixture.counters.stageOneReadiness

        XCTAssertTrue(fixture.coordinator.retryCrewAccessAutoPrintIfPossible())

        XCTAssertEqual(fixture.counters.stageOneReadiness, stageOneReadinessBefore + 1)
        XCTAssertTrue(fixture.coordinator.isAutoPrintRetryInFlight)
        XCTAssertEqual(fixture.coordinator.terminalFailureCount, 0)
        XCTAssertEqual(
            fixture.coordinator.autoPrintStageOneSettleDelayNanoseconds,
            CrewAccessAutoPrint.stageOneSettleDelayNanoseconds
        )

        fixture.coordinator.closePopups()
    }

    // RCA 8. The first attempt survives the isolation client's in-place query evolution.
    func test_stageOneEligibilitySurvivesZscalerQueryEvolution() {
        let base = Self.sessionURLString
        let printButton: [String: Any] = [
            "root": "document",
            "tagName": "button",
            "tagNameIsExactButton": true,
            "type": "button",
            "typeIsExactButton": true,
            "ariaLabel": "Print",
            "ariaLabelIsExactPrint": true,
            "printMatch": "exact",
            "isVisible": true,
            "isDisabled": false,
            "rect": [0, 0, 32, 32]
        ]
        func reason(completedURL: URL?, currentURL: URL?) -> String? {
            CrewAccessAutoPrint.rejectionReason(
                isTrackedPopup: true,
                isVisiblePopup: true,
                livePopupCount: 1,
                teardownInProgress: false,
                completedURL: completedURL,
                currentURL: currentURL,
                readyState: "complete",
                printElements: [printButton],
                oneShotConsumed: false
            )
        }
        let session = URL(string: base)
        let evolved = URL(string: base + "?printJob=abc123")
        let evolvedAgain = URL(string: base + "?printJob=def456&dialog=open")

        XCTAssertNil(reason(completedURL: session, currentURL: evolved))
        XCTAssertNil(reason(completedURL: evolved, currentURL: evolvedAgain))
        XCTAssertEqual(
            reason(
                completedURL: session,
                currentURL: URL(
                    string: "https://99999999.isolation.zscaler.com/profile/00000000-0000-4000-8000-000000000000/zpa-session"
                )
            ),
            "session-changed",
            "a different isolation host is still a different session"
        )
        XCTAssertEqual(
            reason(completedURL: session, currentURL: URL(string: "https://fltops-portal.ups.com/home")),
            "url-mismatch",
            "a genuine URL mismatch is still reported, and more specifically"
        )
        XCTAssertEqual(reason(completedURL: session, currentURL: nil), "url-mismatch")
    }

    /// Attempt A's tail, reproduced: the isolation client mutates its own query in place while the
    /// one Trip Details document stays open. That used to make every remaining sample of the first
    /// chain report `stale-probe`, so only a retry — which re-baselines the captured URL — could
    /// ever reach Stage 1.
    func test_firstAttemptReachesStageOneThroughInPlaceQueryEvolution() {
        let fixture = makeFixture()
        let evolved = URL(string: Self.sessionURLString + "?printJob=abc123")
        fixture.popup.fixedURL = evolved

        fixture.coordinator.evaluateAutoPrintStageOneEligibility(
            settledStageOneProbe(),
            webView: fixture.popup,
            completedURL: URL(string: Self.sessionURLString),
            attempt: 1,
            sequence: 1
        )

        XCTAssertTrue(
            fixture.coordinator.hasPendingAutoPrintStageOneSettleWork,
            "in-place query evolution must no longer strand the first attempt"
        )
        XCTAssertTrue(
            fixture.coordinator.autoPrintStageOneAttemptedPopupIDs.isEmpty,
            "the one-shot stays available for the whole settle"
        )
        XCTAssertEqual(fixture.coordinator.terminalFailureCount, 0)

        fixture.coordinator.closePopups()
    }

    // RCA 9 + 10. Source guards: ownership, boundedness, redaction, frozen constants.
    func test_stageOwnershipAndObserverSourceInvariants() throws {
        let projectRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: projectRoot.appendingPathComponent("TripDataHub/Views/BrowserWebView.swift"),
            encoding: .utf8
        )

        // Ownership transfer, and the invariant that depends on it.
        XCTAssertTrue(source.contains("sampling=retired reason=stage-two-owns-progress"))
        XCTAssertTrue(source.contains("guard !autoPrintStageOneAttemptedPopupIDs.contains(key) else { return }"))

        // The ownership test's pinned sampling entry point is untouched.
        XCTAssertTrue(source.contains(
            "            ) { [weak self, weak webView] result, _ in\n"
            + "                guard let self, let webView else { return }\n"
            + "                guard webView.url == completedURL else { return }\n"
            + "                self.beginCrewAccessProbe("
        ))

        // Frozen production constants.
        XCTAssertTrue(source.contains("static let stageOneSettleDelayNanoseconds: UInt64 = 4_000_000_000"))
        XCTAssertTrue(source.contains("100_000_000,\n        250_000_000,\n        500_000_000"))
        XCTAssertTrue(source.contains("static let stageTwoObserverDeadlineMilliseconds: UInt64 = 8_000"))

        // One deadline, and it lives in the page world so the call always returns.
        let observerScript = CrewAccessAutoPrint.stageTwoDialogObserverScript(deadlineMilliseconds: 8_000)
        XCTAssertTrue(observerScript.contains("const deadlineMilliseconds = 8000;"))
        XCTAssertEqual(observerScript.components(separatedBy: "setTimeout(").count - 1, 1)
        XCTAssertTrue(observerScript.contains("observer.disconnect()"))

        // The observer observes; it never interacts.
        for banned in [".click(", "dispatchEvent", "MouseEvent", "PointerEvent", "TouchEvent", "window.print", "focus()"] {
            XCTAssertFalse(observerScript.contains(banned), "the observer must never interact: \(banned)")
        }
        // It reuses Stage 2's own selectors rather than inventing new ones.
        XCTAssertTrue(observerScript.contains("[role=\"dialog\"] button[type=\"submit\"]"))
        XCTAssertTrue(CrewAccessAutoPrint.stageTwoReadinessScript.contains("[role=\"dialog\"]"))

        // Weak ownership and non-retaining keys hold for the new bookkeeping.
        for line in source.components(separatedBy: "\n")
        where line.contains("var autoPrintStageTwoObserverPopupIDs")
            || line.contains("var autoPrintRetryCensusPopupIDs") {
            XCTAssertTrue(line.contains("Set<ObjectIdentifier>"))
            XCTAssertFalse(line.contains("WKWebView"))
        }
        XCTAssertTrue(source.contains("autoPrintStageTwoObserverEvaluator(\n"))
        XCTAssertTrue(source.contains("            ) { [weak self, weak webView] result, error in\n                guard let self else { return }\n                self.autoPrintStageTwoObserverPopupIDs.remove(key)"))

        // Diagnostics never carry page contents.
        for line in source.components(separatedBy: "\n")
        where line.contains("observer=ended") || line.contains("retry=census") || line.contains("terminal=failure") {
            for banned in ["pageText", "innerText", "textContent", "normalizedText"] {
                XCTAssertFalse(line.contains(banned), "no page contents in diagnostics: \(banned)")
            }
        }

        // The recoverable failure still has exactly one presenter.
        XCTAssertEqual(source.components(separatedBy: "viewModel.presentIncompleteImportFailure()").count - 1, 1)
    }
}


// MARK: - Production help content

/// The help screen is the only place the app explains the import to a pilot, so it has to describe
/// the flow that actually ships. It previously walked through Safari, the iOS share sheet, pop-up
/// blocking and a default-browser workaround — a flow the app stopped using — and it must never
/// describe the capture mechanism, which is an implementation detail that has already changed twice.
final class CrewAccessImportHelpContentTests: XCTestCase {

    private func helpSource() throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: projectRoot.appendingPathComponent("TripDataHub/Views/CrewAccessImportHelpView.swift"),
            encoding: .utf8
        )
    }

    /// Every user-visible string in the help view, which is what these assertions are about — code
    /// comments explaining what was removed are deliberately not part of the scan.
    private func helpUserFacingStrings() throws -> [String] {
        let source = try helpSource()
        var strings: [String] = []
        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("Text(\"") || trimmed.hasPrefix("Section(\"") else { continue }
            guard let first = trimmed.firstIndex(of: "\""),
                  let last = trimmed.lastIndex(of: "\""),
                  first < last
            else { continue }
            strings.append(String(trimmed[trimmed.index(after: first)..<last]))
        }
        return strings
    }

    func test_helpDescribesTheShippingImportFlow() throws {
        let strings = try helpUserFacingStrings()

        XCTAssertTrue(strings.contains("Importing a Trip"))
        XCTAssertTrue(strings.contains("If Import Fails"))
        XCTAssertTrue(strings.contains("Reset the In-App Browser"))

        let body = strings.joined(separator: "\n")
        // The names here must match the strings the app actually shows.
        XCTAssertTrue(body.contains("Importing Trip…"))
        XCTAssertTrue(body.contains("Import Preview"))
        XCTAssertTrue(body.contains("Unable to Import Trip"))
        XCTAssertTrue(body.contains("Try Again"))
        XCTAssertTrue(body.contains("Reset Browser"))
    }

    func test_helpNoLongerDescribesTheLegacyBrowserFlow() throws {
        let body = try helpUserFacingStrings().joined(separator: "\n").lowercased()

        for legacy in [
            "safari",
            "share sheet",
            "share button",
            "block pop-ups",
            "pop-ups",
            "private browsing",
            "default browser",
            "http 500",
            "bad request",
            "website data"
        ] {
            XCTAssertFalse(body.contains(legacy), "legacy instruction still in the help: \(legacy)")
        }
    }

    func test_helpNeverDescribesTheCaptureImplementation() throws {
        let body = try helpUserFacingStrings().joined(separator: "\n").lowercased()

        for internalDetail in [
            "pdf",
            "stage 1",
            "stage 2",
            "poll",
            "observer",
            "sampling",
            "4 second",
            "4-second",
            "4.0"
        ] {
            XCTAssertFalse(body.contains(internalDetail), "implementation detail leaked into help: \(internalDetail)")
        }
    }

    func test_helpIsMateriallyShorterThanTheFlowItReplaced() throws {
        let strings = try helpUserFacingStrings()
        // Section titles plus body rows. The version this replaced carried five sections and
        // twenty-five rows of browser troubleshooting.
        XCTAssertLessThanOrEqual(strings.count, 12, "the production help must stay compact")
        XCTAssertEqual(
            strings.filter { $0.hasPrefix("1. ") || $0.hasPrefix("2. ") || $0.hasPrefix("3. ") || $0.hasPrefix("4. ") }.count,
            4,
            "Importing a Trip is four numbered steps"
        )
    }

    /// The card layout and navigation chrome are unchanged; only the content was rewritten.
    func test_helpKeepsItsExistingPresentation() throws {
        let source = try helpSource()

        XCTAssertTrue(source.contains("List {"))
        XCTAssertTrue(source.contains(".navigationTitle(\"CrewAccess Import Help\")"))
        XCTAssertTrue(source.contains("#if os(iOS)"))
        XCTAssertTrue(source.contains(".navigationBarTitleDisplayMode(.inline)"))
    }

    /// The Settings diagnostics stay development-only, and the CrewAccess timing controls stay gone.
    func test_settingsShipsNoDiagnosticsOrTimingControls() throws {
        let projectRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let settings = try String(
            contentsOf: projectRoot.appendingPathComponent("TripDataHub/Views/SettingsTabView.swift"),
            encoding: .utf8
        )

        // The validation section exists only inside a DEBUG region.
        let debugRegions = settings.components(separatedBy: "#if DEBUG").dropFirst()
            .map { $0.components(separatedBy: "#endif")[0] }
            .joined(separator: "\n")
        XCTAssertTrue(settings.contains("DEBUG Validation"))
        XCTAssertTrue(
            debugRegions.contains("DEBUG Validation"),
            "the validation section must never ship in a TestFlight build"
        )

        // The removed CrewAccess timing/delay controls must not come back.
        for control in [
            "stageOneSettleDelay",
            "autoPrintDelay",
            "Settle Delay",
            "Auto-Print Timing",
            "CrewAccess Timing"
        ] {
            XCTAssertFalse(settings.contains(control), "removed timing control reappeared: \(control)")
        }

        // And the production delay stays where it belongs: fixed, internal, unchanged.
        XCTAssertEqual(CrewAccessAutoPrint.stageOneSettleDelayNanoseconds, 4_000_000_000)
    }
}


// MARK: - Import Preview density

/// The preview is the one screen a pilot reads before committing a trip, and it has to show a
/// four-leg trip plus its action bar without scrolling on a phone. These pin the density work so a
/// later edit cannot quietly reinflate it, and pin the things density must never cost: Dynamic
/// Type, iPad width, tap targets, and the import/replacement logic itself.
final class ImportPreviewDensityTests: XCTestCase {

    private func previewSource() throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: projectRoot.appendingPathComponent("TripDataHub/Views/ImportPreviewView.swift"),
            encoding: .utf8
        )
    }

    func test_compactRowDensityIsTighterThanTheTimelineDefault() {
        let standard = TimelineFlightRow.Density.standard
        let compact = TimelineFlightRow.Density.compact

        XCTAssertLessThan(compact.verticalPadding, standard.verticalPadding)
        XCTAssertLessThan(compact.horizontalPadding, standard.horizontalPadding)
        XCTAssertLessThan(compact.rowSpacing, standard.rowSpacing)
        XCTAssertLessThan(compact.stackSpacing, standard.stackSpacing)
        XCTAssertLessThan(compact.routeSpacing, standard.routeSpacing)
        XCTAssertLessThan(compact.iconSize, standard.iconSize, "the flight icon is slightly smaller")
        XCTAssertGreaterThan(compact.iconSize, standard.iconSize * 0.75, "slightly smaller, not shrunken")

        // The Timeline's own metrics are the ones it has always had.
        XCTAssertEqual(standard.verticalPadding, 7)
        XCTAssertEqual(standard.horizontalPadding, 16)
        XCTAssertEqual(standard.iconSize, 20)
    }

    /// Only Import Preview opts in. Every Timeline surface keeps the default, so the density work
    /// cannot leak into the tab pilots use in flight.
    func test_onlyImportPreviewOptsIntoCompactDensity() throws {
        let projectRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for timelineSurface in [
            "TripDataHub/Views/TimelineTabView.swift",
            "TripDataHub/Views/ScheduleTimelineRendererView.swift",
            "TripDataHub/Views/iPad/iPadTimelineSidebarView.swift"
        ] {
            let source = try String(
                contentsOf: projectRoot.appendingPathComponent(timelineSurface),
                encoding: .utf8
            )
            XCTAssertFalse(
                source.contains("density:"),
                "\(timelineSurface) must keep the standard row density"
            )
        }
        XCTAssertTrue(try previewSource().contains("density: .compact"))

        let rowSource = try String(
            contentsOf: projectRoot.appendingPathComponent("TripDataHub/Views/TimelineRowViews.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            rowSource.contains("var density: Density = .standard"),
            "the default must stay standard so existing callers are unaffected"
        )
    }

    func test_dateHeadersUseTightVerticalListMetrics() throws {
        let source = try previewSource()

        XCTAssertTrue(
            source.contains(".listSectionSpacing(4)"),
            "adjacent date sections keep only a small gap after the preceding divider"
        )
        XCTAssertTrue(
            source.contains(".environment(\\.defaultMinListHeaderHeight, 0)"),
            "the List must not reserve extra height above or below compact date headers"
        )
        XCTAssertTrue(
            source.contains(".padding(.bottom, -8)"),
            "only the date header's lower boundary moves closer to its first flight row"
        )
        XCTAssertFalse(source.contains(".padding(.vertical, 1)"))
    }

    func test_previewCopyIsTheProductionWording() throws {
        let source = try previewSource()

        XCTAssertTrue(source.contains("Open a trip in CrewAccess to start an import."))
        XCTAssertFalse(source.contains("share sheet"), "the legacy empty state is gone")

        XCTAssertTrue(source.contains("\"Replace Trip\""))
        XCTAssertFalse(source.contains("Replace and Import"))

        XCTAssertFalse(source.contains("Changes to Existing Trips"), "the redundant section label is gone")
        XCTAssertTrue(source.contains("\"Existing trip \\(candidate.tripId) will be replaced.\""))
    }

    func test_densityNeverCostsAccessibilityOrIPadLayout() throws {
        let source = try previewSource()

        // Dynamic Type: every string still scales, and both adaptive layouts survive.
        XCTAssertFalse(source.contains(".font(.system(size:"), "no fixed point sizes")
        XCTAssertEqual(
            source.components(separatedBy: "ViewThatFits(in: .horizontal)").count - 1,
            2,
            "the summary and the action bar both keep their adaptive layout"
        )
        XCTAssertTrue(source.contains("scale: fontScale"))

        // iPad: the action bar still centres on a bounded width.
        XCTAssertTrue(source.contains(".frame(maxWidth: 680)"))

        // Tap targets survive the shorter bar.
        XCTAssertTrue(source.contains("private static let minimumTapTarget: CGFloat = 44"))
        XCTAssertEqual(
            source.components(separatedBy: "minHeight: Self.minimumTapTarget").count - 1,
            2,
            "both actions keep a 44pt minimum height"
        )
    }

    func test_cancelIsSecondaryAndThePrimaryActionStaysProminent() throws {
        let source = try previewSource()
        let buttons = try XCTUnwrap(source.range(of: "private var actionButtons: some View"))
        let body = String(source[buttons.lowerBound...])

        XCTAssertTrue(body.contains("Button(\"Cancel\", action: onCancel)"))
        XCTAssertTrue(body.contains(".buttonStyle(.borderless)"), "Cancel is visually secondary")
        XCTAssertTrue(body.contains(".foregroundStyle(.secondary)"))
        XCTAssertTrue(body.contains(".buttonStyle(.borderedProminent)"), "the primary action stays prominent")
        XCTAssertFalse(body.contains(".buttonStyle(.bordered)\n"), "Cancel no longer competes with the primary")
    }

    /// Density is presentation only. The confirm and discard paths are the same ones T25 pins.
    func test_importAndReplacementLogicIsUnchanged() throws {
        let source = try previewSource()

        XCTAssertTrue(source.contains("confirmPendingImport(expectedReplacementIDs: [])"))
        XCTAssertTrue(source.contains("expectedReplacementIDs: confirmation.expectedReplacementIDs"))
        XCTAssertTrue(source.contains("await viewModel.discardPendingImport()"))
        XCTAssertTrue(source.contains(".alert(item: $replacementConfirmation)"))
        XCTAssertFalse(source.contains(".confirmationDialog"))

        // The confirmation alert keeps the fuller wording it is tested on; only the inline row
        // warning was shortened.
        let confirmation = try XCTUnwrap(ImportReplacementConfirmation(candidates: [
            AppViewModel.TripImportReplacementCandidate(
                id: "schedule-12165",
                tripId: "12165",
                pairings: ["12165"],
                reason: .sameTripID
            )
        ]))
        XCTAssertTrue(confirmation.message.contains("Trip 12165 already exists."))
    }
}
