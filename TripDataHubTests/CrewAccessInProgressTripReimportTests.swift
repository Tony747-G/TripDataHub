import CloudKit
import UserNotifications
import XCTest
@testable import TripDataHub

/// Re-importing a trip that changed while it was in progress.
///
/// The user case: a trip is published as `ANC–SZX → SZX–ANC (DH)`, the pilot flies the first leg,
/// crew scheduling rebuilds the rest as `ANC–SZX → SZX–HKG (GND) → HKG–ANC`, and the pilot imports
/// the new CrewAccess PDF. Same Trip ID, same start date, same Bid Period. The first Confirm
/// sometimes left the Timeline empty — the old trip removed and the new one never showing — and
/// only a second import of the same PDF fixed it.
///
/// The failure was a race, not a parse: `confirmPendingImport` committed the new JSON locally and
/// uploaded it asynchronously, and a foreground/startup sync landing in that window applied the
/// remote tombstone for the file name being replaced. Because the JSON is the Timeline's source of
/// truth (INV-006), reconcile then rebuilt a Timeline without the trip.
///
/// Committed fixtures are synthetic. The opt-in A70393R acceptance test reads externally supplied
/// private fixture paths from environment variables; real schedule data is never copied here.
@MainActor
final class CrewAccessInProgressTripReimportTests: XCTestCase {

    private let gemsID = "5550001"
    private let tripID = "T900026"
    private let tripInformationDate = "2026-07-20"
    private var devices: [Device] = []
    private var retentionSelectionToRestore: String??

    override func tearDown() {
        for device in devices {
            try? FileManager.default.removeItem(at: device.importsDirectory)
            UserDefaults().removePersistentDomain(forName: device.defaultsSuiteName)
        }
        devices = []
        if let retentionSelectionToRestore {
            if let value = retentionSelectionToRestore {
                UserDefaults.standard.set(value, forKey: AppViewModel.crewAccessRetentionSelectionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: AppViewModel.crewAccessRetentionSelectionKey)
            }
        }
        retentionSelectionToRestore = nil
        super.tearDown()
    }

    // MARK: - 1. Same Trip ID replacement for an in-progress trip

    /// One Confirm must leave the whole new trip on the Timeline, including the GND segment and
    /// including the case where the first leg has already been flown.
    func test_inProgressTripReplacement_keepsAllNewLegsAfterOneConfirm() async throws {
        let harness = try makeHarness()
        let vm = harness.device.viewModel

        await harness.confirm(payload: originalTrip())
        XCTAssertEqual(
            legs(in: vm, pairing: tripID).map(\.flight),
            ["61", "8801"],
            "precondition: the original two-leg trip is on the Timeline"
        )

        await harness.confirm(payload: revisedTrip())

        let revisedLegs = legs(in: vm, pairing: tripID)
        XCTAssertEqual(
            revisedLegs.map(\.flight),
            ["61", "GND", "62"],
            "one Confirm must produce the full three-leg revision, GND included"
        )
        XCTAssertEqual(
            revisedLegs.first(where: { $0.flight == "GND" })?.status,
            "GND",
            "the ground segment must keep its GND status"
        )
        XCTAssertFalse(
            revisedLegs.contains { $0.flight == "8801" },
            "the superseded deadhead leg must be gone"
        )
        XCTAssertFalse(
            (vm.crewAccessImportMessage ?? "").hasPrefix("Import failed"),
            "the import must report success: \(vm.crewAccessImportMessage ?? "nil")"
        )
    }

    /// The Timeline source both platform surfaces read is `crewAccessSchedules`, and both refresh
    /// off `scheduleDataRevision`. Regression cover for INV-005: iPhone `TimelineTabView` and iPad
    /// `IPadTimelineSidebarView` must see the same updated trip.
    func test_inProgressTripReplacement_publishesToBothTimelineSurfaces() async throws {
        let harness = try makeHarness()
        let vm = harness.device.viewModel

        await harness.confirm(payload: originalTrip())
        let revisionBefore = vm.scheduleDataRevision

        await harness.confirm(payload: revisedTrip())

        XCTAssertGreaterThan(
            vm.scheduleDataRevision,
            revisionBefore,
            "both Timeline surfaces refresh on scheduleDataRevision; it must advance"
        )
        // The shared source read by TimelineTabView and iPadTimelineSidebarView.
        let sidebarLegs = vm.crewAccessSchedules
            .flatMap(\.legs)
            .filter { $0.pairing == tripID }
            .sorted { $0.leg < $1.leg }
        XCTAssertEqual(sidebarLegs.map(\.flight), ["61", "GND", "62"])
        XCTAssertEqual(
            sidebarLegs.map(\.flight),
            legs(in: vm, pairing: tripID).map(\.flight),
            "crewAccessSchedules and the merged schedules array must not diverge"
        )
    }

    func test_manualRegistrationSurvivesReimportReconcileAndRelaunch() async throws {
        let harness = try makeHarness(name: "registration-original")
        await harness.confirm(payload: originalTrip())
        let firstLeg = try XCTUnwrap(legs(in: harness.device.viewModel, pairing: tripID).first)

        try await harness.device.viewModel.updateCrewAccessRegistration(
            for: firstLeg,
            registration: "n605up"
        )
        await harness.device.viewModel.reconcileCrewAccessSchedulesWithImportFiles()
        XCTAssertEqual(
            legs(in: harness.device.viewModel, pairing: tripID).first?.aircraftRegistration,
            "N605UP"
        )

        await harness.confirm(payload: revisedTrip())
        XCTAssertEqual(
            legs(in: harness.device.viewModel, pairing: tripID).first?.aircraftRegistration,
            "N605UP",
            "re-import must retain manual registration"
        )

        let relaunched = try makeHarness(
            name: "registration-relaunched",
            cloud: harness.cloud,
            importsDirectory: harness.device.importsDirectory
        )
        await relaunched.device.viewModel.reconcileCrewAccessSchedulesWithImportFiles()
        XCTAssertEqual(
            legs(in: relaunched.device.viewModel, pairing: tripID).first?.aircraftRegistration,
            "N605UP"
        )
    }

    func test_realA70393R_preservesScheduleActualExportAndRelaunch() async throws {
        // Opt-in only, and only via explicit environment variables. There is deliberately no
        // default path: guessing at `~/Desktop` / `~/Downloads` made this test silently
        // machine-specific, so "acceptance passed" was only ever true on one developer's laptop
        // while CI and every other machine skipped it without saying so.
        let environment = ProcessInfo.processInfo.environment
        guard let pdfPath = environment["TDH_REAL_A70393R_PDF"],
              let bpJSONPath = environment["TDH_REAL_A70393R_BP_JSON"] else {
            throw XCTSkip(
                "Private-fixture acceptance is opt-in. Set TDH_REAL_A70393R_PDF and "
                + "TDH_REAL_A70393R_BP_JSON to absolute paths to run it."
            )
        }
        let pdfURL = URL(fileURLWithPath: pdfPath)
        let bpJSONURL = URL(fileURLWithPath: bpJSONPath)
        guard FileManager.default.fileExists(atPath: pdfURL.path),
              FileManager.default.fileExists(atPath: bpJSONURL.path) else {
            throw XCTSkip(
                "TDH_REAL_A70393R_PDF / TDH_REAL_A70393R_BP_JSON are set but do not point at "
                + "existing files."
            )
        }

        let preTrip = try Self.a70393RPreTripPayload(
            from: Data(contentsOf: bpJSONURL)
        )
        let draft = CrewAccessPDFImportService().analyzeTrip(
            pdfData: try Data(contentsOf: pdfURL),
            sourceFileName: pdfURL.lastPathComponent
        )
        XCTAssertTrue(draft.errors.isEmpty, draft.errors.map(\.message).joined(separator: " | "))
        let postTrip = try XCTUnwrap(draft.jsonPayload)
        XCTAssertEqual(postTrip.tripId, "A70393R")
        XCTAssertEqual(postTrip.pdfCreatedUtc, "2026-08-09T02:15:00Z")

        let harness = try makeHarness(name: "real-a70393r")
        await harness.confirm(payload: preTrip)
        await harness.confirm(payload: postTrip)
        await harness.device.viewModel.reconcileCrewAccessSchedulesWithImportFiles()

        let immediateLegs = legs(in: harness.device.viewModel, pairing: "A70393R")
        try Self.assertA70393RCanonicalLegs(immediateLegs)

        let canonicalURL = try XCTUnwrap(
            (try FileManager.default.contentsOfDirectory(
                at: harness.device.importsDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )).first { $0.pathExtension.lowercased() == "json" }
        )
        let canonical = try JSONDecoder().decode(
            CrewAccessTripJSON.self,
            from: Data(contentsOf: canonicalURL)
        )
        let canonicalSchedule = try XCTUnwrap(
            AppViewModel.buildCrewAccessSchedule(from: canonical, modifiedAt: Date())
        )
        try Self.assertA70393RCanonicalLegs(canonicalSchedule.legs)

        let exportedFlights = try TripJSONExportService.publicEvents(
            payload: canonical,
            schedule: canonicalSchedule,
            tripID: "trip-a70393r-2026-08-05"
        ).filter { $0.type == .flight || $0.type == .deadhead }
        XCTAssertEqual(exportedFlights.count, 2)
        try Self.assertA70393RExport(exportedFlights)

        let relaunched = try makeHarness(
            name: "real-a70393r-relaunched",
            cloud: harness.cloud,
            importsDirectory: harness.device.importsDirectory
        )
        await relaunched.device.viewModel.reconcileCrewAccessSchedulesWithImportFiles()
        try Self.assertA70393RCanonicalLegs(
            legs(in: relaunched.device.viewModel, pairing: "A70393R")
        )
    }

    /// A schedule change may retain the pairing while changing both its schedule ID and its Bid
    /// Period identity. The old implementation captured the old candidate before mutation, then
    /// re-resolved it *after* reconcile by pairing. That selected the incoming schedule and deleted
    /// both JSON generations, producing the exact "first import empty, second import works" bug.
    func test_timeOverlapWithSharedPairing_deletesOnlyPreImportArtifactAfterOneConfirm() async throws {
        let harness = try makeHarness()
        let vm = harness.device.viewModel
        let oldPayload = crossBidPeriodOldTrip()
        let newPayload = crossBidPeriodReplacementTrip()
        let oldSchedule = try XCTUnwrap(AppViewModel.buildCrewAccessSchedule(from: oldPayload, modifiedAt: Date()))
        let newSchedule = try XCTUnwrap(AppViewModel.buildCrewAccessSchedule(from: newPayload, modifiedAt: Date()))
        XCTAssertNotEqual(oldSchedule.id, newSchedule.id, "precondition: schedule IDs differ")

        await harness.confirm(payload: oldPayload)
        vm.pendingImport = Self.pendingImport(for: newPayload)
        let candidates = vm.pendingImportReplacementCandidates
        XCTAssertEqual(candidates.map(\.id), [oldSchedule.id])
        guard case .timeOverlap = try XCTUnwrap(candidates.first).reason else {
            return XCTFail("precondition: shared pairing crosses BP identity and is a time-overlap candidate")
        }

        await vm.confirmPendingImport()
        await harness.settle()

        XCTAssertEqual(vm.crewAccessSchedules.filter { $0.id == oldSchedule.id }.count, 0)
        XCTAssertEqual(vm.crewAccessSchedules.filter { $0.id == newSchedule.id }.count, 1)
        XCTAssertEqual(vm.schedules.filter { $0.id == oldSchedule.id }.count, 0)
        XCTAssertEqual(vm.schedules.filter { $0.id == newSchedule.id }.count, 1)
        XCTAssertEqual(
            harness.device.localFileNames(),
            [Self.fileName(tripID: newPayload.tripId, date: newPayload.tripInformationDate)],
            "the incoming JSON must survive while the exact pre-import JSON is removed"
        )
        XCTAssertFalse((vm.crewAccessImportMessage ?? "").hasPrefix("Import failed"))

        await vm.reconcileCrewAccessSchedulesWithImportFiles()
        XCTAssertEqual(vm.crewAccessSchedules.filter { $0.id == newSchedule.id }.count, 1)

        let oldFileName = Self.fileName(tripID: oldPayload.tripId, date: oldPayload.tripInformationDate)
        let newFileName = Self.fileName(tripID: newPayload.tripId, date: newPayload.tripInformationDate)
        let oldIsTombstoned = await harness.cloud.isTombstoned(fileName: oldFileName)
        let newIsTombstoned = await harness.cloud.isTombstoned(fileName: newFileName)
        let liveGeneration = await harness.cloud.liveGeneratedAt(tripID: newPayload.tripId)
        XCTAssertTrue(oldIsTombstoned)
        XCTAssertFalse(newIsTombstoned)
        XCTAssertEqual(liveGeneration, newPayload.generatedAt)
    }

    /// Replacement identity is Scheduled-first on both sides of the comparison (INV-012).
    ///
    /// BP26-05 starts 2026-07-12 03:00 ANC-local, i.e. 2026-07-12T11:00Z in July. This trip is
    /// scheduled out at 09:00Z — inside BP26-04 — and actually departs four hours late at 13:00Z,
    /// which lands in BP26-05. The delay is ordinary; the Bid Period boundary it happens to cross
    /// is not.
    ///
    /// `crewAccessTripKeys(for:domicile:)` resolves the *existing* schedule Scheduled-first. The
    /// incoming side used to be derived from `startUtc`, which resolves Actual-first after the
    /// merge, so the two halves of the same comparison disagreed. The same-Trip-ID branch then
    /// missed and the trip fell through to `.timeOverlap`, routing an ordinary re-import of the
    /// same trip down the destructive replacement path.
    ///
    /// The two generations carry different information dates on purpose: that is what makes their
    /// schedule IDs differ, which is the only way to reach the Bid Period key comparison at all.
    func test_lateDepartureCrossingBidPeriodBoundaryStillClassifiesAsSameTripID() async throws {
        // Pinned inside the trip's own Bid Period so retention cannot prune the first generation
        // out from under the comparison.
        let harness = try makeHarness(
            name: "bp-boundary-actual",
            retentionReferenceDate: Self.date("2026-07-12T20:00:00Z")
        )
        let vm = harness.device.viewModel

        let scheduledGeneration = Self.trip(
            tripID: "T900042",
            tripInformationDate: "2026-06-30",
            generatedAt: "2026-06-30T12:00:00Z",
            items: [
                Self.item(
                    sequence: 1,
                    from: "ANC",
                    to: "CVG",
                    flight: "5X900",
                    startUtc: "2026-07-12T09:00:00Z",
                    endUtc: "2026-07-12T15:00:00Z",
                    stdUtc: "2026-07-12T09:00:00Z",
                    staUtc: "2026-07-12T15:00:00Z"
                )
            ]
        )

        // Post-flight generation: the schedule is unchanged, only the actuals are new. `startUtc`
        // and `endUtc` follow the display resolution and therefore carry the actual instants.
        let flownGeneration = Self.trip(
            tripID: "T900042",
            tripInformationDate: "2026-07-12",
            generatedAt: "2026-07-12T20:00:00Z",
            items: [
                Self.item(
                    sequence: 1,
                    from: "ANC",
                    to: "CVG",
                    flight: "5X900",
                    startUtc: "2026-07-12T13:00:00Z",
                    endUtc: "2026-07-12T19:00:00Z",
                    stdUtc: "2026-07-12T09:00:00Z",
                    staUtc: "2026-07-12T15:00:00Z",
                    atdUtc: "2026-07-12T13:00:00Z",
                    ataUtc: "2026-07-12T19:00:00Z"
                )
            ]
        )

        let scheduledSchedule = try XCTUnwrap(
            AppViewModel.buildCrewAccessSchedule(from: scheduledGeneration, modifiedAt: Date())
        )
        let flownSchedule = try XCTUnwrap(
            AppViewModel.buildCrewAccessSchedule(from: flownGeneration, modifiedAt: Date())
        )
        XCTAssertNotEqual(
            scheduledSchedule.id,
            flownSchedule.id,
            "precondition: differing information dates must give differing schedule IDs, otherwise "
                + "the identical-schedule-ID branch answers before the Bid Period key is consulted"
        )
        XCTAssertNotEqual(
            bidPeriod(for: Self.date("2026-07-12T09:00:00Z"), domicile: "ANC")?.id,
            bidPeriod(for: Self.date("2026-07-12T13:00:00Z"), domicile: "ANC")?.id,
            "precondition: the scheduled and actual departures straddle a Bid Period boundary"
        )

        await harness.confirm(payload: scheduledGeneration)
        vm.pendingImport = Self.pendingImport(for: flownGeneration)

        let candidates = vm.pendingImportReplacementCandidates
        XCTAssertEqual(candidates.count, 1)
        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidate.id, scheduledSchedule.id)
        guard case .sameTripID = candidate.reason else {
            return XCTFail(
                "a late departure must not reclassify a same-Trip-ID replacement as a time overlap; "
                    + "got \(candidate.reason)"
            )
        }
    }

    func test_timeOverlapWithSharedPairing_survivesRelaunchReconcile() async throws {
        let harness = try makeHarness(name: "original")
        let newPayload = crossBidPeriodReplacementTrip()
        let newSchedule = try XCTUnwrap(AppViewModel.buildCrewAccessSchedule(from: newPayload, modifiedAt: Date()))
        await harness.confirm(payload: crossBidPeriodOldTrip())
        await harness.confirm(payload: newPayload)

        let relaunched = try makeHarness(
            name: "relaunched",
            cloud: harness.cloud,
            importsDirectory: harness.device.importsDirectory
        )
        await relaunched.device.viewModel.reconcileCrewAccessSchedulesWithImportFiles()

        XCTAssertEqual(
            relaunched.device.viewModel.crewAccessSchedules.filter { $0.id == newSchedule.id }.count,
            1,
            "a second import must not be required after app relaunch"
        )
        XCTAssertEqual(relaunched.device.localFileNames(), [
            Self.fileName(tripID: newPayload.tripId, date: newPayload.tripInformationDate)
        ])
    }

    // MARK: - 2. Tombstone conflict

    /// A foreground sync raised while the import transaction is open must not run against the
    /// half-committed import — and must not be dropped either.
    func test_syncDuringImportTransaction_isDeferredNotLost() async throws {
        let harness = try makeHarness()
        let vm = harness.device.viewModel
        await harness.confirm(payload: originalTrip())

        // Hold the new generation's upload so the transaction stays open, exactly like a slow
        // CloudKit write.
        await harness.cloud.setUploadsPaused(true)
        harness.device.viewModel.pendingImport = Self.pendingImport(for: revisedTrip())
        await vm.confirmPendingImport()
        XCTAssertTrue(vm.isCrewAccessImportTransactionActive, "precondition: the upload is still in flight")

        // Another device tombstones the file name being replaced, then this device foregrounds.
        await harness.cloud.tombstoneAll(tripID: tripID)
        await vm.syncCrewAccessDeviceData(reason: "foreground")

        XCTAssertEqual(
            legs(in: vm, pairing: tripID).map(\.flight),
            ["61", "GND", "62"],
            "a sync during the import transaction must not empty the Timeline"
        )
        XCTAssertTrue(
            harness.device.localFileNames().contains(Self.fileName(tripID: tripID, date: tripInformationDate)),
            "the source JSON must survive the deferred sync"
        )

        // Releasing the upload closes the transaction and replays the deferred sync exactly once.
        await harness.cloud.setUploadsPaused(false)
        let cloud = harness.cloud
        let watchedTripID = tripID
        await awaitOrFail("CloudKit converges on the new generation") {
            await cloud.waitUntilLive(tripID: watchedTripID)
        }
        await harness.settle()

        XCTAssertEqual(
            legs(in: vm, pairing: tripID).map(\.flight),
            ["61", "GND", "62"],
            "the replayed sync must not undo the import either"
        )
        let liveGeneration = await harness.cloud.liveGeneratedAt(tripID: tripID)
        XCTAssertEqual(liveGeneration, Self.revisedGeneratedAt, "CloudKit must end on the new generation")
    }

    func test_T4_replacementUsesOneConfirmationOneTransactionAndOneInvalidationSeam() async throws {
        let spy = ReplacementInvalidationSpy()
        let harness = try makeHarness(
            replacementDerivedStateInvalidator: { await spy.recordCall() }
        )
        let vm = harness.device.viewModel
        await harness.confirm(payload: originalTrip())
        let callsAfterNewImport = await spy.callCount()
        XCTAssertEqual(callsAfterNewImport, 0, "new import must not use the replacement seam")

        vm.pendingImport = Self.pendingImport(for: revisedTrip())
        let expectedIDs = Set(vm.pendingImportReplacementCandidates.map(\.id))
        XCTAssertFalse(expectedIDs.isEmpty, "precondition: the revision is a replacement")
        let transactionsBefore = vm.crewAccessImportTransactionStartCount

        let confirmed = await vm.confirmPendingImport(expectedReplacementIDs: expectedIDs)
        await harness.settle()

        XCTAssertTrue(confirmed)
        XCTAssertEqual(vm.crewAccessImportTransactionStartCount - transactionsBefore, 1)
        let replacementCalls = await spy.callCount()
        XCTAssertEqual(replacementCalls, 1)
        XCTAssertNil(vm.pendingImport)
        XCTAssertEqual(legs(in: vm, pairing: tripID).map(\.flight), ["61", "GND", "62"])
    }

    func test_T25_replacementUsesCenteredAlertWithCapturedCandidatesAndOneFinalConfirmation() throws {
        let sameTrip = AppViewModel.TripImportReplacementCandidate(
            id: "schedule-12165",
            tripId: "12165",
            pairings: ["12165"],
            reason: .sameTripID
        )
        let overlap = AppViewModel.TripImportReplacementCandidate(
            id: "schedule-44321",
            tripId: "44321",
            pairings: ["44321"],
            reason: .timeOverlap
        )
        let confirmation = try XCTUnwrap(ImportReplacementConfirmation(
            candidates: [sameTrip, overlap]
        ))

        XCTAssertEqual(
            confirmation.expectedReplacementIDs,
            ["schedule-12165", "schedule-44321"]
        )
        XCTAssertTrue(confirmation.message.contains("Trip 12165 already exists."))
        XCTAssertTrue(confirmation.message.contains("Trip 44321 overlaps this import."))
        XCTAssertTrue(confirmation.message.contains("will replace the current version"))
        XCTAssertTrue(confirmation.message.contains("removed from Timeline and synced devices"))
        XCTAssertNil(ImportReplacementConfirmation(candidates: []))

        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("TripDataHub/Views/ImportPreviewView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("Button(\"Confirm Import\")"))
        XCTAssertTrue(source.contains("if replacements.isEmpty"))
        XCTAssertTrue(source.contains(".alert(item: $replacementConfirmation)"))
        XCTAssertFalse(source.contains(".confirmationDialog"))

        let previewButtonStart = try XCTUnwrap(
            source.range(of: "Button(\"Replace and Import\", role: .destructive)")
        ).lowerBound
        let previewButtonEnd = try XCTUnwrap(
            source.range(of: ".disabled(!pending.canConfirm)", range: previewButtonStart..<source.endIndex)
        ).upperBound
        let previewButtonSource = source[previewButtonStart..<previewButtonEnd]
        XCTAssertFalse(previewButtonSource.contains("confirmPendingImport"))
        XCTAssertTrue(previewButtonSource.contains("replacementConfirmation ="))

        let alertStart = try XCTUnwrap(
            source.range(of: ".alert(item: $replacementConfirmation)")
        ).lowerBound
        let alertSource = source[alertStart...]
        XCTAssertEqual(alertSource.components(separatedBy: "confirmPendingImport").count - 1, 1)
        XCTAssertTrue(alertSource.contains("expectedReplacementIDs: confirmation.expectedReplacementIDs"))
    }

    func test_confirmFailureDiagnosticsAreVisibleAndBranchSpecific() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let previewSource = try String(
            contentsOf: projectRoot.appendingPathComponent("TripDataHub/Views/ImportPreviewView.swift"),
            encoding: .utf8
        )
        let viewModelSource = try String(
            contentsOf: projectRoot.appendingPathComponent("TripDataHub/ViewModels/AppViewModel.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(previewSource.contains("Section(\"Import Status\")"))
        XCTAssertTrue(previewSource.contains("viewModel.crewAccessImportMessage"))
        for reason in [
            "reason=invalid_preview",
            "reason=replacement_drift",
            "reason=commit_verification",
            "reason=transaction_failure"
        ] {
            XCTAssertEqual(
                viewModelSource.components(separatedBy: reason).count - 1,
                1,
                "confirm exit reason must have exactly one dedicated logger line: \(reason)"
            )
        }
    }

    func test_T7_replacementInvalidatesAllOldNextReportNotifications() async throws {
        let notifications = ReimportNotificationSpy()
        let harness = try makeHarness(
            replacementDerivedStateInvalidator: nil,
            notificationService: notifications,
            flightCountdownCoordinator: FlightCountdownCoordinator(
                snapshotClient: ReimportSnapshotNoop()
            )
        )
        let vm = harness.device.viewModel
        await harness.confirm(payload: originalTrip())
        await notifications.seedOldNotifications([
            "nextreport.12165.old.pending",
            "nextreport.12165.old.delivered"
        ])

        vm.pendingImport = Self.pendingImport(for: revisedTrip())
        let expectedIDs = Set(vm.pendingImportReplacementCandidates.map(\.id))
        let confirmed = await vm.confirmPendingImport(expectedReplacementIDs: expectedIDs)
        await harness.settle()

        XCTAssertTrue(confirmed)
        let invalidationCount = await notifications.invalidationCount()
        let oldNotificationIDs = await notifications.oldNotificationIDs()
        XCTAssertEqual(invalidationCount, 1)
        XCTAssertEqual(oldNotificationIDs, [])
    }

    func test_T30_pendingImportNilClosesPreviewWhileNotificationRescheduleIsStillSuspended() async throws {
        let notifications = SuspendedRescheduleNotificationService()
        let harness = try makeHarness(notificationService: notifications)
        let vm = harness.device.viewModel
        await harness.confirm(payload: originalTrip())

        // Replacement reconcile performs one reschedule before pendingImport is cleared.
        // Suspend the following reschedule, which is the explicit post-nil call in confirm.
        await notifications.suspendReschedule(afterPassingCalls: 1)
        vm.pendingImport = Self.pendingImport(for: revisedTrip())
        let expectedIDs = Set(vm.pendingImportReplacementCandidates.map(\.id))
        let confirmation = Task {
            await vm.confirmPendingImport(expectedReplacementIDs: expectedIDs)
        }

        await notifications.waitUntilRescheduleIsSuspended()

        XCTAssertNil(vm.pendingImport, "the durable local commit clears pendingImport before notification reschedule returns")
        XCTAssertFalse(
            ImportPreviewPresentationPolicy.browserPreviewIsPresented(
                pendingImportID: vm.pendingImport?.id,
                presentsImportPreview: true
            ),
            "Browser Preview must close from pendingImport state without waiting for dismiss()"
        )
        XCTAssertFalse(
            ImportPreviewPresentationPolicy.externalPreviewIsPresented(
                pendingImportID: vm.pendingImport?.id,
                browserIsPresented: false
            ),
            "external Preview must close while confirmPendingImport is still awaiting notifications"
        )

        await notifications.resumeSuspendedReschedule()
        let confirmed = await confirmation.value
        XCTAssertTrue(confirmed)
    }

    func test_replacementInvalidationSeamIsNotCalledWhenLocalCommitRollsBack() async throws {
        let spy = ReplacementInvalidationSpy()
        let verificationFailure = CommitVerificationFileRemover()
        let harness = try makeHarness(
            retentionReferenceDate: Self.date("2026-07-20T12:00:00Z"),
            replacementDerivedStateInvalidator: { await spy.recordCall() },
            importCommitVerificationFaultInjector: { try verificationFailure.removeIfArmed($0) }
        )
        let vm = harness.device.viewModel

        await harness.confirm(payload: Self.outOfRetentionTrip())
        verificationFailure.arm()
        vm.pendingImport = Self.pendingImport(
            for: Self.outOfRetentionTrip(generatedAt: "2026-07-20T09:00:00Z")
        )
        let expectedIDs = Set(vm.pendingImportReplacementCandidates.map(\.id))
        XCTAssertFalse(expectedIDs.isEmpty, "precondition: the failing import replaces an existing trip")

        let confirmed = await vm.confirmPendingImport(expectedReplacementIDs: expectedIDs)

        XCTAssertFalse(confirmed)
        let calls = await spy.callCount()
        XCTAssertEqual(calls, 0)
        XCTAssertNil(vm.pendingImport, "a terminal rollback must release the failed Preview")
    }

    func test_replacementCandidateDriftFailsClosedBeforeTransaction() async throws {
        let spy = ReplacementInvalidationSpy()
        let harness = try makeHarness(
            replacementDerivedStateInvalidator: { await spy.recordCall() }
        )
        let vm = harness.device.viewModel
        await harness.confirm(payload: originalTrip())
        vm.pendingImport = Self.pendingImport(for: revisedTrip())
        let transactionsBefore = vm.crewAccessImportTransactionStartCount

        let confirmed = await vm.confirmPendingImport(expectedReplacementIDs: ["stale-ui-target"])

        XCTAssertFalse(confirmed)
        XCTAssertEqual(vm.crewAccessImportTransactionStartCount, transactionsBefore)
        let calls = await spy.callCount()
        XCTAssertEqual(calls, 0)
        XCTAssertNotNil(vm.pendingImport)
        XCTAssertTrue((vm.crewAccessImportMessage ?? "").contains("changed"))
    }

    func test_replacementInvalidationTimeoutDoesNotFailVerifiedImport() async throws {
        let spy = ReplacementInvalidationSpy(delayNanoseconds: 1_000_000_000)
        let harness = try makeHarness(
            replacementDerivedStateInvalidator: { await spy.recordCall() },
            replacementInvalidationTimeoutNanoseconds: 1_000_000
        )
        let vm = harness.device.viewModel
        await harness.confirm(payload: originalTrip())

        vm.pendingImport = Self.pendingImport(for: revisedTrip())
        let expectedIDs = Set(vm.pendingImportReplacementCandidates.map(\.id))
        let confirmed = await vm.confirmPendingImport(expectedReplacementIDs: expectedIDs)
        await harness.settle()

        XCTAssertTrue(confirmed)
        XCTAssertNil(vm.pendingImport)
        XCTAssertTrue((vm.crewAccessImportMessage ?? "").hasPrefix("CrewAccess import complete"))
        XCTAssertFalse(vm.isCrewAccessImportTransactionActive)
    }

    func test_replacementInvalidationFailureDoesNotFailVerifiedImport() async throws {
        struct ExpectedFailure: Error {}
        let harness = try makeHarness(
            replacementDerivedStateInvalidator: { throw ExpectedFailure() }
        )
        let vm = harness.device.viewModel
        await harness.confirm(payload: originalTrip())

        vm.pendingImport = Self.pendingImport(for: revisedTrip())
        let expectedIDs = Set(vm.pendingImportReplacementCandidates.map(\.id))
        let confirmed = await vm.confirmPendingImport(expectedReplacementIDs: expectedIDs)
        await harness.settle()

        XCTAssertTrue(confirmed)
        XCTAssertNil(vm.pendingImport)
        XCTAssertTrue((vm.crewAccessImportMessage ?? "").hasPrefix("CrewAccess import complete"))
        XCTAssertFalse(vm.isCrewAccessImportTransactionActive)
    }

    /// The tombstone arrives immediately after Confirm, before any sync has acknowledged the new
    /// record. The explicitly confirmed generation wins and is republished.
    func test_tombstoneAfterConfirm_doesNotDeleteExplicitReimport() async throws {
        let harness = try makeHarness()
        let vm = harness.device.viewModel
        await harness.confirm(payload: originalTrip())
        await harness.confirm(payload: revisedTrip())

        // Another device, still holding the pre-revision view, tombstones the file name.
        await harness.cloud.tombstoneAll(tripID: tripID)
        await vm.syncCrewAccessDeviceData(reason: "foreground after tombstone")

        XCTAssertEqual(
            legs(in: vm, pairing: tripID).map(\.flight),
            ["61", "GND", "62"],
            "a tombstone describing the replaced generation must not delete the confirmed one"
        )
        let liveGeneration = await harness.cloud.liveGeneratedAt(tripID: tripID)
        XCTAssertEqual(
            liveGeneration,
            Self.revisedGeneratedAt,
            "the confirmed generation must be republished as the live CloudKit record"
        )
    }

    /// The override is scoped to an explicit local Confirm. A device that merely holds the file
    /// still honours the tombstone — INV-008's no-resurrection guarantee is unchanged.
    func test_deviceWithoutExplicitConfirm_stillHonoursTombstone() async throws {
        let cloud = ImportRaceCloud()
        let harnessA = try makeHarness(name: "A", cloud: cloud)
        let harnessB = try makeHarness(name: "B", cloud: cloud)

        await harnessA.confirm(payload: revisedTrip())
        await harnessB.device.viewModel.syncCrewAccessDeviceData(reason: "seed B")
        XCTAssertFalse(
            harnessB.device.viewModel.crewAccessSchedules.isEmpty,
            "precondition: B received the trip without confirming it"
        )

        await cloud.tombstoneAll(tripID: tripID)
        for pass in 1...3 {
            await harnessB.device.viewModel.syncCrewAccessDeviceData(reason: "stale pass \(pass)")
        }

        XCTAssertTrue(
            harnessB.device.viewModel.crewAccessSchedules.isEmpty,
            "a device that never confirmed must not resurrect a tombstoned trip"
        )
        XCTAssertTrue(harnessB.device.localFileNames().isEmpty)
        let live = await cloud.liveGeneratedAt(tripID: tripID)
        XCTAssertNil(live, "automatic sync alone must never clear a tombstone")
    }

    // MARK: - 3. Reconcile failure protection

    /// T-32: the input PDF may be discarded once Preview owns the parsed value, while the canonical
    /// JSON written at Confirm remains protected from retention until verification completes.
    func test_T32_confirmTimeSourceLifetimeProtectsIncomingCanonicalJSONThroughVerification() async throws {
        let revisedPayload = Self.outOfRetentionTrip(generatedAt: "2026-07-20T09:00:00Z")
        let pdfData = Data("synthetic-replacement-pdf".utf8)
        let importService = ReimportRoutedImportService(payloadsByData: [pdfData: revisedPayload])
        let harness = try makeHarness(
            retentionReferenceDate: Self.date("2026-07-20T12:00:00Z"),
            crewAccessImportService: importService
        )
        let vm = harness.device.viewModel

        await harness.confirm(payload: Self.outOfRetentionTrip())
        pinRetentionSelection("1")

        let inputURL = harness.device.importsDirectory.appendingPathComponent("incoming.pdf")
        try pdfData.write(to: inputURL)
        let materializedPDF = try Data(contentsOf: inputURL)
        let previewAccepted = await vm.importCrewAccessPDFData(
            materializedPDF,
            sourceFileName: inputURL.lastPathComponent
        )
        XCTAssertTrue(previewAccepted)
        let expectedIDs = Set(vm.pendingImportReplacementCandidates.map(\.id))
        XCTAssertFalse(expectedIDs.isEmpty, "precondition: this is a same-trip replacement")
        try FileManager.default.removeItem(at: inputURL)

        let confirmed = await vm.confirmPendingImport(expectedReplacementIDs: expectedIDs)
        await harness.settle()

        XCTAssertTrue(confirmed)
        XCTAssertNil(vm.pendingImport)
        let finalURL = harness.device.importsDirectory.appendingPathComponent(
            Self.fileName(tripID: Self.outOfRetentionTripID, date: revisedPayload.tripInformationDate)
        )
        let committedData = try Data(contentsOf: finalURL)
        let committed = try JSONDecoder().decode(CrewAccessTripJSON.self, from: committedData)
        XCTAssertEqual(committed.generatedAt, revisedPayload.generatedAt)
        XCTAssertTrue(vm.crewAccessSchedules.flatMap(\.legs).contains { $0.pairing == Self.outOfRetentionTripID })
    }

    func test_T33_confirmSourceReadFailureReleasesProcessingStateAndAllowsSamePDFRetry() async throws {
        let pdfData = Data("synthetic-failing-pdf".utf8)
        let payload = revisedTrip()
        let importService = ReimportRoutedImportService(payloadsByData: [pdfData: payload])
        let verificationFailure = CommitVerificationFileRemover()
        let harness = try makeHarness(
            crewAccessImportService: importService,
            importCommitVerificationFaultInjector: { try verificationFailure.removeIfArmed($0) }
        )
        let vm = harness.device.viewModel

        let firstAccepted = await vm.importCrewAccessPDFData(pdfData, sourceFileName: "trip-a.pdf")
        XCTAssertTrue(firstAccepted)
        verificationFailure.arm()
        let confirmed = await vm.confirmPendingImport()
        XCTAssertFalse(confirmed)

        XCTAssertFalse(vm.isCrewAccessImportInProgress)
        XCTAssertNil(vm.pendingImport)
        XCTAssertFalse(vm.isCrewAccessImportTransactionActive)
        let retryAccepted = await vm.importCrewAccessPDFData(
            pdfData,
            sourceFileName: "trip-a-retry.pdf"
        )
        XCTAssertTrue(
            retryAccepted,
            "terminal verification failure must release the same PDF fingerprint immediately"
        )
        XCTAssertEqual(vm.pendingImport?.tripId, payload.tripId)
    }

    func test_T34_distinctImportCreatesExactlyOnePreviewAfterPriorConfirmFailure() async throws {
        let pdfA = Data("synthetic-trip-a".utf8)
        let pdfB = Data("synthetic-trip-b".utf8)
        let payloadA = revisedTrip()
        let payloadB = Self.outOfRetentionTrip()
        let importService = ReimportRoutedImportService(payloadsByData: [
            pdfA: payloadA,
            pdfB: payloadB
        ])
        let verificationFailure = CommitVerificationFileRemover()
        let harness = try makeHarness(
            crewAccessImportService: importService,
            importCommitVerificationFaultInjector: { try verificationFailure.removeIfArmed($0) }
        )
        let vm = harness.device.viewModel

        let tripAAccepted = await vm.importCrewAccessPDFData(pdfA, sourceFileName: "trip-a.pdf")
        XCTAssertTrue(tripAAccepted)
        verificationFailure.arm()
        let tripAConfirmed = await vm.confirmPendingImport()
        XCTAssertFalse(tripAConfirmed)

        let tripBAccepted = await vm.importCrewAccessPDFData(pdfB, sourceFileName: "trip-b.pdf")
        XCTAssertTrue(tripBAccepted)
        let tripBPreviewID = try XCTUnwrap(vm.pendingImport?.id)
        XCTAssertEqual(vm.pendingImport?.tripId, payloadB.tripId)
        XCTAssertEqual(importService.callCount(for: pdfB), 1)

        let duplicateAccepted = await vm.importCrewAccessPDFData(
            pdfB,
            sourceFileName: "trip-b-duplicate.pdf"
        )
        XCTAssertFalse(duplicateAccepted)
        XCTAssertEqual(vm.pendingImport?.id, tripBPreviewID)
        XCTAssertEqual(importService.callCount(for: pdfB), 1, "Trip B Preview must be generated exactly once")
    }

    /// A stale same-trip JSON stored under a *different* file name is removed before verification
    /// runs. When verification then fails, that file must come back too — restoring only the new
    /// file's path would leave the trip with no source at all, which is the very state the
    /// fail-closed path exists to prevent.
    func test_failedImport_restoresStaleSameTripJSONRemovedBeforeVerification() async throws {
        let verificationFailure = CommitVerificationFileRemover()
        let harness = try makeHarness(
            retentionReferenceDate: Self.date("2026-07-20T12:00:00Z"),
            importCommitVerificationFaultInjector: { try verificationFailure.removeIfArmed($0) }
        )
        let vm = harness.device.viewModel
        pinRetentionSelection("1")

        // Same trip key as the out-of-retention fixture, stored under a legacy file name so it is
        // picked up as a stale duplicate rather than overwritten in place.
        let legacyFileName = "legacy_\(Self.outOfRetentionTripID).json"
        let legacyURL = harness.device.importsDirectory.appendingPathComponent(legacyFileName)
        try JSONEncoder().encode(Self.outOfRetentionTrip()).write(to: legacyURL)
        XCTAssertTrue(
            harness.device.localFileNames().contains(legacyFileName),
            "precondition: the stale duplicate exists"
        )

        // Retention keeps the transaction-owned source; the injected read failure exercises rollback.
        verificationFailure.arm()
        vm.pendingImport = Self.pendingImport(for: Self.outOfRetentionTrip(generatedAt: "2026-07-20T09:00:00Z"))
        await vm.confirmPendingImport()
        await harness.settle()

        XCTAssertTrue(
            (vm.crewAccessImportMessage ?? "").hasPrefix("Import failed"),
            "precondition: the import failed verification"
        )
        XCTAssertTrue(
            harness.device.localFileNames().contains(legacyFileName),
            "the stale same-trip JSON removed before verification must be restored on rollback"
        )
        let restored = try Data(contentsOf: legacyURL)
        XCTAssertEqual(
            (try? JSONDecoder().decode(CrewAccessTripJSON.self, from: restored))?.generatedAt,
            Self.outOfRetentionGeneratedAt,
            "the restored file must be the original content, not the failed import's payload"
        )
    }

    private func pinRetentionSelection(_ value: String) {
        retentionSelectionToRestore = UserDefaults.standard
            .string(forKey: AppViewModel.crewAccessRetentionSelectionKey)
        UserDefaults.standard.set(value, forKey: AppViewModel.crewAccessRetentionSelectionKey)
    }

    /// `nonisolated` so it can be used as a default argument value.
    private nonisolated static func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        // Fixture strings are authored here and are always well formed.
        return formatter.date(from: iso)!
    }

    // MARK: - Fixtures

    private static let originalGeneratedAt = "2026-07-18T12:00:00Z"
    private static let revisedGeneratedAt = "2026-07-20T23:45:00Z"

    private static func a70393RPreTripPayload(from data: Data) throws -> CrewAccessTripJSON {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let trips = try XCTUnwrap(root["trips"] as? [[String: Any]])
        let trip = try XCTUnwrap(trips.first { ($0["tripNumber"] as? String) == "A70393R" })
        let events = try XCTUnwrap(trip["events"] as? [[String: Any]])
        let flightEvents = events.filter {
            let type = $0["type"] as? String
            return type == "flight" || type == "deadhead"
        }
        let items = try flightEvents.map { event -> CrewAccessTripItemJSON in
            let start = try XCTUnwrap(event["start"] as? [String: Any])
            let end = try XCTUnwrap(event["end"] as? [String: Any])
            let startInstant = try XCTUnwrap(start["instant"] as? String)
            let endInstant = try XCTUnwrap(end["instant"] as? String)
            return CrewAccessTripItemJSON(
                sequence: try XCTUnwrap(event["sequence"] as? Int),
                depAirport: try XCTUnwrap(event["origin"] as? String),
                arrAirport: try XCTUnwrap(event["destination"] as? String),
                deadhead: (event["type"] as? String) == "deadhead",
                flight: try XCTUnwrap(event["flightNumber"] as? String),
                startUtc: startInstant,
                endUtc: endInstant,
                startLocalDisplay: (start["local"] as? String) ?? startInstant,
                endLocalDisplay: (end["local"] as? String) ?? endInstant,
                originTz: start["timeZone"] as? String,
                destinationTz: end["timeZone"] as? String,
                timeDerivation: "bp-export-real-fixture",
                aircraft: (event["aircraft"] as? String) ?? "",
                block: (event["blockTime"] as? String) ?? "",
                stdUtc: nil,
                staUtc: nil,
                atdUtc: nil,
                ataUtc: nil,
                tailNumber: nil,
                stableLegId: UUID().uuidString
            )
        }
        let tripStart = try XCTUnwrap(trip["start"] as? [String: Any])
        let tripStartInstant = try XCTUnwrap(tripStart["instant"] as? String)
        return CrewAccessTripJSON(
            schemaVersion: 1,
            source: "bp-export-real-fixture",
            sourceVersion: root["schemaVersion"] as? String ?? "unknown",
            mappingVersion: "external",
            generatedAt: root["exportedAt"] as? String ?? "2026-08-05T00:00:00Z",
            tripId: "A70393R",
            tripInformationDate: String(tripStartInstant.prefix(10)),
            creditTime: nil,
            tripDays: nil,
            tafb: nil,
            dutyTotals: [],
            hotelDetails: [],
            crew: [],
            items: items
        )
    }

    private static func assertA70393RCanonicalLegs(
        _ legs: [TripLeg],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let sorted = legs.sorted { $0.leg < $1.leg }
        XCTAssertEqual(sorted.map(\.flight), ["5X059", "5X080"], file: file, line: line)
        let first = try XCTUnwrap(sorted.first, file: file, line: line)
        XCTAssertEqual(first.originalSTDUTC, "2026-08-05T23:34:00Z", file: file, line: line)
        XCTAssertEqual(first.stdUTC, "2026-08-05T23:34:00Z", file: file, line: line)
        XCTAssertEqual(first.atdUTC, "2026-08-05T23:45:00Z", file: file, line: line)
        XCTAssertEqual(first.originalSTAUTC, "2026-08-06T04:36:00Z", file: file, line: line)
        XCTAssertEqual(first.staUTC, "2026-08-06T04:36:00Z", file: file, line: line)
        XCTAssertEqual(first.ataUTC, "2026-08-06T04:43:00Z", file: file, line: line)
        XCTAssertNil(first.scheduledDepartureObservedAtUTC, file: file, line: line)
        XCTAssertNil(first.scheduledArrivalObservedAtUTC, file: file, line: line)
        XCTAssertEqual(first.actualDepartureObservedAtUTC, "2026-08-09T02:15:00Z", file: file, line: line)
        XCTAssertEqual(first.actualArrivalObservedAtUTC, "2026-08-09T02:15:00Z", file: file, line: line)
        XCTAssertEqual(first.block, "04:58", file: file, line: line)
        XCTAssertEqual(first.aircraftType, "747", file: file, line: line)
        XCTAssertNil(first.aircraftRegistration, file: file, line: line)

        let second = try XCTUnwrap(sorted.dropFirst().first, file: file, line: line)
        XCTAssertEqual(second.originalSTDUTC, "2026-08-07T09:10:00Z", file: file, line: line)
        XCTAssertEqual(second.stdUTC, "2026-08-07T09:10:00Z", file: file, line: line)
        XCTAssertEqual(second.atdUTC, "2026-08-07T09:26:00Z", file: file, line: line)
        XCTAssertEqual(second.originalSTAUTC, "2026-08-07T14:19:00Z", file: file, line: line)
        XCTAssertEqual(second.staUTC, "2026-08-07T14:19:00Z", file: file, line: line)
        XCTAssertEqual(second.ataUTC, "2026-08-07T14:11:00Z", file: file, line: line)
        XCTAssertNil(second.scheduledDepartureObservedAtUTC, file: file, line: line)
        XCTAssertNil(second.scheduledArrivalObservedAtUTC, file: file, line: line)
        XCTAssertEqual(second.actualDepartureObservedAtUTC, "2026-08-09T02:15:00Z", file: file, line: line)
        XCTAssertEqual(second.actualArrivalObservedAtUTC, "2026-08-09T02:15:00Z", file: file, line: line)
        XCTAssertEqual(second.block, "04:45", file: file, line: line)
        XCTAssertEqual(second.aircraftType, "747", file: file, line: line)
        XCTAssertNil(second.aircraftRegistration, file: file, line: line)
    }

    private static func assertA70393RExport(
        _ events: [ExportEvent],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let first = try XCTUnwrap(events.first, file: file, line: line)
        XCTAssertEqual(first.start.instant, "2026-08-05T23:45:00Z", file: file, line: line)
        XCTAssertEqual(first.end.instant, "2026-08-06T04:43:00Z", file: file, line: line)
        XCTAssertEqual(first.departure?.originalScheduled?.instant, "2026-08-05T23:34:00Z", file: file, line: line)
        XCTAssertEqual(first.departure?.scheduled?.instant, "2026-08-05T23:34:00Z", file: file, line: line)
        XCTAssertNil(first.departure?.scheduled?.observedAt, file: file, line: line)
        XCTAssertEqual(first.departure?.actual?.instant, "2026-08-05T23:45:00Z", file: file, line: line)
        XCTAssertEqual(first.departure?.actual?.observedAt, "2026-08-09T02:15:00Z", file: file, line: line)
        XCTAssertEqual(first.arrival?.originalScheduled?.instant, "2026-08-06T04:36:00Z", file: file, line: line)
        XCTAssertEqual(first.arrival?.scheduled?.instant, "2026-08-06T04:36:00Z", file: file, line: line)
        XCTAssertEqual(first.arrival?.actual?.instant, "2026-08-06T04:43:00Z", file: file, line: line)
        XCTAssertEqual(first.arrival?.actual?.observedAt, "2026-08-09T02:15:00Z", file: file, line: line)
        XCTAssertEqual(first.blockTime, "04:58", file: file, line: line)
        XCTAssertEqual(first.aircraft, "747", file: file, line: line)
        XCTAssertNil(first.aircraftRegistration, file: file, line: line)

        let second = try XCTUnwrap(events.dropFirst().first, file: file, line: line)
        XCTAssertEqual(second.start.instant, "2026-08-07T09:26:00Z", file: file, line: line)
        XCTAssertEqual(second.end.instant, "2026-08-07T14:11:00Z", file: file, line: line)
        XCTAssertEqual(second.departure?.originalScheduled?.instant, "2026-08-07T09:10:00Z", file: file, line: line)
        XCTAssertEqual(second.departure?.scheduled?.instant, "2026-08-07T09:10:00Z", file: file, line: line)
        XCTAssertEqual(second.departure?.actual?.instant, "2026-08-07T09:26:00Z", file: file, line: line)
        XCTAssertEqual(second.arrival?.originalScheduled?.instant, "2026-08-07T14:19:00Z", file: file, line: line)
        XCTAssertEqual(second.arrival?.scheduled?.instant, "2026-08-07T14:19:00Z", file: file, line: line)
        XCTAssertEqual(second.arrival?.actual?.instant, "2026-08-07T14:11:00Z", file: file, line: line)
        XCTAssertEqual(second.arrival?.actual?.observedAt, "2026-08-09T02:15:00Z", file: file, line: line)
        XCTAssertEqual(second.blockTime, "04:45", file: file, line: line)
        XCTAssertEqual(second.aircraft, "747", file: file, line: line)
        XCTAssertNil(second.aircraftRegistration, file: file, line: line)
    }

    /// Both generations use the same pairing and overlap in UTC. Their departure times straddle
    /// the BP26-04 / BP26-05 03:00 ANC boundary, and their information dates use different months,
    /// so production identity classifies the old one as a different-ID time-overlap replacement.
    private func crossBidPeriodOldTrip() -> CrewAccessTripJSON {
        Self.trip(
            tripID: "T910026",
            tripInformationDate: "2026-06-30",
            generatedAt: "2026-07-12T10:30:00Z",
            items: [
                Self.item(
                    sequence: 1,
                    from: "ANC",
                    to: "SDF",
                    flight: "71",
                    startUtc: "2026-07-12T10:00:00Z",
                    endUtc: "2026-07-12T12:30:00Z"
                )
            ]
        )
    }

    private func crossBidPeriodReplacementTrip() -> CrewAccessTripJSON {
        Self.trip(
            tripID: "T910026",
            tripInformationDate: "2026-07-02",
            generatedAt: "2026-07-12T11:30:00Z",
            items: [
                Self.item(
                    sequence: 1,
                    from: "ANC",
                    to: "SDF",
                    flight: "72",
                    startUtc: "2026-07-12T11:15:00Z",
                    endUtc: "2026-07-12T14:00:00Z"
                )
            ]
        )
    }

    /// `ANC–SZX` then a deadhead `SZX–ANC`.
    private func originalTrip() -> CrewAccessTripJSON {
        Self.trip(
            tripID: tripID,
            tripInformationDate: tripInformationDate,
            generatedAt: Self.originalGeneratedAt,
            items: [
                Self.item(
                    sequence: 1,
                    from: "ANC",
                    to: "SZX",
                    flight: "61",
                    startUtc: "2026-07-20T06:00:00Z",
                    endUtc: "2026-07-20T18:30:00Z"
                ),
                Self.item(
                    sequence: 2,
                    from: "SZX",
                    to: "ANC",
                    flight: "8801",
                    startUtc: "2026-07-21T02:00:00Z",
                    endUtc: "2026-07-21T14:00:00Z",
                    deadhead: true
                )
            ]
        )
    }

    /// The rebuild: the already-flown `ANC–SZX` is unchanged, a GND repositioning is inserted, and
    /// the return operates from HKG.
    private func revisedTrip() -> CrewAccessTripJSON {
        Self.trip(
            tripID: tripID,
            tripInformationDate: tripInformationDate,
            generatedAt: Self.revisedGeneratedAt,
            items: [
                Self.item(
                    sequence: 1,
                    from: "ANC",
                    to: "SZX",
                    flight: "61",
                    startUtc: "2026-07-20T06:00:00Z",
                    endUtc: "2026-07-20T18:30:00Z"
                ),
                Self.item(
                    sequence: 2,
                    from: "SZX",
                    to: "HKG",
                    flight: "GND",
                    startUtc: "2026-07-21T01:00:00Z",
                    endUtc: "2026-07-21T04:00:00Z"
                ),
                Self.item(
                    sequence: 3,
                    from: "HKG",
                    to: "ANC",
                    flight: "62",
                    startUtc: "2026-07-21T09:00:00Z",
                    endUtc: "2026-07-21T20:00:00Z"
                )
            ]
        )
    }

    private static let outOfRetentionTripID = "T900001"
    private static let outOfRetentionGeneratedAt = "2025-12-04T10:00:00Z"

    /// A trip in BP26-01, i.e. outside a "current plus one previous" retention window anchored in
    /// BP26-05.
    private static func outOfRetentionTrip(
        generatedAt: String = outOfRetentionGeneratedAt
    ) -> CrewAccessTripJSON {
        trip(
            tripID: outOfRetentionTripID,
            tripInformationDate: "2025-12-05",
            generatedAt: generatedAt,
            items: [
                item(
                    sequence: 1,
                    from: "ANC",
                    to: "SDF",
                    flight: "70",
                    startUtc: "2025-12-05T06:00:00Z",
                    endUtc: "2025-12-05T12:00:00Z"
                )
            ]
        )
    }

    private static func trip(
        tripID: String,
        tripInformationDate: String,
        generatedAt: String,
        items: [CrewAccessTripItemJSON]
    ) -> CrewAccessTripJSON {
        CrewAccessTripJSON(
            schemaVersion: 1,
            source: "crewaccess_print_pdf",
            sourceVersion: "1",
            mappingVersion: "1",
            generatedAt: generatedAt,
            tripId: tripID,
            tripInformationDate: tripInformationDate,
            creditTime: nil,
            tripDays: nil,
            tafb: nil,
            dutyTotals: [],
            hotelDetails: [],
            crew: [],
            items: items
        )
    }

    private static func item(
        sequence: Int,
        from: String,
        to: String,
        flight: String,
        startUtc: String,
        endUtc: String,
        deadhead: Bool = false,
        stdUtc: String? = nil,
        staUtc: String? = nil,
        atdUtc: String? = nil,
        ataUtc: String? = nil
    ) -> CrewAccessTripItemJSON {
        CrewAccessTripItemJSON(
            sequence: sequence,
            depAirport: from,
            arrAirport: to,
            deadhead: deadhead,
            flight: flight,
            startUtc: startUtc,
            endUtc: endUtc,
            startLocalDisplay: startUtc,
            endLocalDisplay: endUtc,
            originTz: "UTC",
            destinationTz: "UTC",
            timeDerivation: "utc",
            aircraft: "B767",
            block: "0:00",
            stdUtc: stdUtc,
            staUtc: staUtc,
            atdUtc: atdUtc,
            ataUtc: ataUtc,
            tailNumber: nil
        )
    }

    private static func fileName(tripID: String, date: String) -> String {
        "\(date)_\(tripID).json"
    }

    /// Builds the pending import through the same schedule builder the PDF path uses, so the test
    /// asserts against production leg and trip key formats rather than hand-rolled ones.
    private static func pendingImport(for payload: CrewAccessTripJSON) -> PendingImport {
        PendingImport(
            id: UUID(),
            source: .crewAccessPDF,
            sourceFileName: "synthetic-\(payload.tripId).pdf",
            tripId: payload.tripId,
            tripDate: payload.tripInformationDate,
            parsedSchedule: AppViewModel.buildCrewAccessSchedule(from: payload, modifiedAt: Date()),
            jsonPayload: payload,
            warnings: [],
            errors: [],
            createdAt: Date(),
            rawExtractStats: RawExtractStats(pageCount: 1, characterCount: 100, lineCount: 10)
        )
    }

    private func legs(in viewModel: AppViewModel, pairing: String) -> [TripLeg] {
        viewModel.schedules
            .flatMap(\.legs)
            .filter { $0.pairing == pairing }
            .sorted { $0.leg < $1.leg }
    }

    // MARK: - Harness

    @MainActor
    private struct Device {
        let viewModel: AppViewModel
        let importsDirectory: URL
        let defaultsSuiteName: String

        func localFileNames() -> [String] {
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: importsDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            return urls.map(\.lastPathComponent).sorted()
        }
    }

    @MainActor
    private struct Harness {
        let device: Device
        let cloud: ImportRaceCloud
        let deviceSchedules: RecordingDeviceScheduleService
        let importFingerprintLedger: ImportFingerprintLedger

        /// Drives a full Confirm and waits for its CloudKit upload to land, so the import
        /// transaction is closed before the test asserts.
        func confirm(payload: CrewAccessTripJSON) async {
            device.viewModel.pendingImport = CrewAccessInProgressTripReimportTests.pendingImport(for: payload)
            await device.viewModel.confirmPendingImport()
            await settle()
        }

        /// Lets the detached upload task and any deferred sync task run to completion. Bounded and
        /// polling-free waits are impossible here because the work is fire-and-forget; the loop is
        /// a yield loop, not a sleep, and the surrounding assertions catch a genuine hang.
        func settle() async {
            for _ in 0..<200 {
                await Task.yield()
                if !device.viewModel.isCrewAccessImportTransactionActive { break }
            }
            for _ in 0..<200 { await Task.yield() }
        }
    }

    /// - Parameter retentionReferenceDate: pins the retention window. Defaults to a date inside
    ///   BP26-05 so no test depends on the machine clock; the retention *selection* still defaults
    ///   to "ALL", so retention is inert unless a test opts in via `pinRetentionSelection`.
    private func makeHarness(
        name: String = "A",
        cloud: ImportRaceCloud? = nil,
        importsDirectory: URL? = nil,
        retentionReferenceDate: Date = CrewAccessInProgressTripReimportTests.date("2026-07-20T12:00:00Z"),
        replacementDerivedStateInvalidator: (@Sendable () async throws -> Void)? = {},
        replacementInvalidationTimeoutNanoseconds: UInt64 = 2_000_000_000,
        crewAccessImportService: CrewAccessPDFImportServiceProtocol = CrewAccessPDFImportService(),
        importCommitVerificationFaultInjector: (@MainActor @Sendable (URL) throws -> Void)? = nil,
        notificationService: NextReportNotificationServiceProtocol = ReimportNotificationNoop(),
        flightCountdownCoordinator: FlightCountdownCoordinator = FlightCountdownCoordinator()
    ) throws -> Harness {
        let cloud = cloud ?? ImportRaceCloud()
        let directory = importsDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("CrewAccessReimportTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suiteName = "CrewAccessReimportTests.\(name).\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let deviceSchedules = RecordingDeviceScheduleService()
        let importFingerprintLedger = ImportFingerprintLedger(defaults: defaults)

        let viewModel = AppViewModel(
            cacheService: ReimportTestCacheService(),
            notificationService: notificationService,
            crewAccessImportService: crewAccessImportService,
            friendScheduleCloudKitService: ReimportTestFriendService(),
            deviceScheduleCloudKitService: deviceSchedules,
            crewAccessImportCloudKitService: ImportRaceService(cloud: cloud),
            syncStateDefaults: defaults,
            importFingerprintLedger: importFingerprintLedger,
            replacementDerivedStateInvalidator: replacementDerivedStateInvalidator,
            replacementInvalidationTimeoutNanoseconds: replacementInvalidationTimeoutNanoseconds,
            importCommitVerificationFaultInjector: importCommitVerificationFaultInjector,
            flightCountdownCoordinator: flightCountdownCoordinator,
            crewAccessImportsDirectory: directory,
            retentionReferenceDate: { retentionReferenceDate }
        )
        viewModel.verifiedIdentity = VerifiedIdentityProfile(
            cloudKitRecordName: "_rec_\(gemsID)",
            name: "Test Pilot",
            gemsID: gemsID,
            domicile: "ANC",
            equipment: "747",
            seat: "CA",
            dateOfHire: "2000-01-01",
            isAdminEligible: false,
            adminPolicyFingerprint: nil,
            verifiedAt: Date()
        )
        viewModel.currentCloudKitRecordName = "_rec_\(gemsID)"

        let device = Device(viewModel: viewModel, importsDirectory: directory, defaultsSuiteName: suiteName)
        devices.append(device)
        return Harness(
            device: device,
            cloud: cloud,
            deviceSchedules: deviceSchedules,
            importFingerprintLedger: importFingerprintLedger
        )
    }

    /// Failure guard so a never-satisfied continuation fails the test instead of hanging CI.
    private func awaitOrFail(
        _ description: String,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ work: @escaping @Sendable () async -> Void
    ) async {
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await work(); return true }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if !finished {
            XCTFail("Timed out after \(timeout)s waiting for \(description)", file: file, line: line)
        }
    }
}

private actor ReplacementInvalidationSpy {
    private var calls = 0
    private let delayNanoseconds: UInt64

    init(delayNanoseconds: UInt64 = 0) {
        self.delayNanoseconds = delayNanoseconds
    }

    func recordCall() async {
        calls += 1
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
    }

    func callCount() -> Int {
        calls
    }
}

// MARK: - Fake CloudKit collection with a pausable upload

/// Like the deletion-outbox tests' fake, plus the ability to hold an upload open so a test can
/// raise a foreground sync while the import transaction is still in flight.
private actor ImportRaceCloud {
    private struct Stored {
        var jsonData: Data
        var tripInformationDate: String?
        var updatedAt: Date
        var deletedAt: Date?
    }

    private var records: [String: Stored] = [:]
    private var clientTick: TimeInterval = 0
    private var uploadsPaused = false
    private var pausedUploads: [CheckedContinuation<Void, Never>] = []
    private var liveWaiters: [(tripID: String, continuation: CheckedContinuation<Void, Never>)] = []

    func setUploadsPaused(_ paused: Bool) {
        uploadsPaused = paused
        guard !paused else { return }
        let waiting = pausedUploads
        pausedUploads = []
        for continuation in waiting { continuation.resume() }
    }

    func upload(fileName: String, jsonData: Data, tripInformationDate: String?) async {
        if uploadsPaused {
            await withCheckedContinuation { pausedUploads.append($0) }
        }
        clientTick += 1
        records[fileName] = Stored(
            jsonData: jsonData,
            tripInformationDate: tripInformationDate,
            updatedAt: Date(timeIntervalSince1970: 1_000_000 + clientTick),
            deletedAt: nil
        )
        signal()
    }

    func tombstone(fileName: String) {
        guard var record = records[fileName] else { return }
        clientTick += 1
        record.deletedAt = Date(timeIntervalSince1970: 1_000_000 + clientTick)
        records[fileName] = record
    }

    /// Every record for the trip, as another device holding the previous view would tombstone it.
    func tombstoneAll(tripID: String) {
        let fileNames = records
            .filter { Self.tripID(in: $0.value.jsonData) == tripID }
            .map(\.key)
        for fileName in fileNames { tombstone(fileName: fileName) }
    }

    func liveGeneratedAt(tripID: String) -> String? {
        records.values
            .filter { $0.deletedAt == nil }
            .compactMap { try? JSONDecoder().decode(CrewAccessTripJSON.self, from: $0.jsonData) }
            .first { $0.tripId == tripID }?
            .generatedAt
    }

    func isTombstoned(fileName: String) -> Bool {
        records[fileName]?.deletedAt != nil
    }

    func waitUntilLive(tripID: String) async {
        if liveGeneratedAt(tripID: tripID) != nil { return }
        await withCheckedContinuation { liveWaiters.append((tripID, $0)) }
    }

    func allRecords() -> [CrewAccessImportCloudKitRecord] {
        records.map { name, stored in
            CrewAccessImportCloudKitRecord(
                fileName: name,
                jsonData: stored.jsonData,
                tripInformationDate: stored.tripInformationDate,
                firstDepartureUTC: nil,
                updatedAt: stored.updatedAt,
                deletedAt: stored.deletedAt
            )
        }
    }

    private func signal() {
        guard !liveWaiters.isEmpty else { return }
        var remaining: [(tripID: String, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in liveWaiters {
            if liveGeneratedAt(tripID: waiter.tripID) != nil {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        liveWaiters = remaining
    }

    private static func tripID(in jsonData: Data) -> String? {
        (try? JSONDecoder().decode(CrewAccessTripJSON.self, from: jsonData))?.tripId
    }
}

private struct ImportRaceService: CrewAccessImportCloudKitServicing {
    let cloud: ImportRaceCloud

    func uploadImportFile(
        gemsID: String,
        fileName: String,
        jsonData: Data,
        tripInformationDate: String?,
        firstDepartureUTC: String?
    ) async throws {
        await cloud.upload(fileName: fileName, jsonData: jsonData, tripInformationDate: tripInformationDate)
    }

    func fetchImportFiles(gemsID: String) async throws -> [CrewAccessImportCloudKitRecord] {
        await cloud.allRecords()
    }

    func tombstoneImportFile(gemsID: String, fileName: String) async throws {
        await cloud.tombstone(fileName: fileName)
    }
}

// MARK: - Stubs

private final class ReimportRoutedImportService: CrewAccessPDFImportServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private let payloadsByData: [Data: CrewAccessTripJSON]
    private var callCounts: [Data: Int] = [:]

    init(payloadsByData: [Data: CrewAccessTripJSON]) {
        self.payloadsByData = payloadsByData
    }

    func analyzeTrip(pdfData: Data, sourceFileName: String?) -> CrewAccessImportDraft {
        lock.lock()
        callCounts[pdfData, default: 0] += 1
        lock.unlock()

        guard let payload = payloadsByData[pdfData] else {
            return CrewAccessImportDraft(
                sourceFileName: sourceFileName,
                tripId: "",
                tripDate: "",
                parsedSchedule: nil,
                jsonPayload: nil,
                warnings: [],
                errors: [ImportErrorItem(
                    code: .schemaMismatch,
                    message: "Unexpected synthetic PDF payload",
                    remediation: "Register the payload in the routed test service."
                )],
                rawExtractStats: RawExtractStats(pageCount: 0, characterCount: 0, lineCount: 0)
            )
        }
        return CrewAccessImportDraft(
            sourceFileName: sourceFileName,
            tripId: payload.tripId,
            tripDate: payload.tripInformationDate,
            parsedSchedule: AppViewModel.buildCrewAccessSchedule(from: payload, modifiedAt: Date()),
            jsonPayload: payload,
            warnings: [],
            errors: [],
            rawExtractStats: RawExtractStats(pageCount: 1, characterCount: pdfData.count, lineCount: 1)
        )
    }

    func callCount(for data: Data) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return callCounts[data, default: 0]
    }
}

private final class CommitVerificationFileRemover: @unchecked Sendable {
    private let lock = NSLock()
    private var isArmed = false

    func arm() {
        lock.lock()
        isArmed = true
        lock.unlock()
    }

    func removeIfArmed(_ url: URL) throws {
        lock.lock()
        let shouldRemove = isArmed
        isArmed = false
        lock.unlock()
        guard shouldRemove else { return }
        try FileManager.default.removeItem(at: url)
    }
}

private struct ReimportNotificationNoop: NextReportNotificationServiceProtocol {
    func authorizationStatus() async -> UNAuthorizationStatus { .notDetermined }
    func requestAuthorization() async throws -> Bool { false }
    func invalidateNextReportNotifications() async {}
    func reschedule(
        schedules: [PayPeriodSchedule],
        notify48h: Bool,
        notify24h: Bool,
        notify12h: Bool
    ) async -> NotificationRescheduleResult {
        NotificationRescheduleResult(requested: 0, scheduled: 0, failed: 0)
    }
}

private actor ReimportNotificationSpy: NextReportNotificationServiceProtocol {
    private var oldIDs: Set<String> = []
    private var invalidations = 0

    func authorizationStatus() async -> UNAuthorizationStatus { .authorized }
    func requestAuthorization() async throws -> Bool { true }

    func invalidateNextReportNotifications() async {
        invalidations += 1
        oldIDs.removeAll()
    }

    func reschedule(
        schedules: [PayPeriodSchedule],
        notify48h: Bool,
        notify24h: Bool,
        notify12h: Bool
    ) async -> NotificationRescheduleResult {
        NotificationRescheduleResult(requested: 0, scheduled: 0, failed: 0)
    }

    func seedOldNotifications(_ ids: Set<String>) {
        oldIDs = ids
    }

    func invalidationCount() -> Int { invalidations }
    func oldNotificationIDs() -> Set<String> { oldIDs }
}

private actor SuspendedRescheduleNotificationService: NextReportNotificationServiceProtocol {
    private var reschedulesToPassBeforeSuspension: Int?
    private var suspendedRescheduleContinuation: CheckedContinuation<Void, Never>?
    private var suspensionObservedContinuations: [CheckedContinuation<Void, Never>] = []

    func authorizationStatus() async -> UNAuthorizationStatus { .authorized }
    func requestAuthorization() async throws -> Bool { true }
    func invalidateNextReportNotifications() async {}

    func reschedule(
        schedules: [PayPeriodSchedule],
        notify48h: Bool,
        notify24h: Bool,
        notify12h: Bool
    ) async -> NotificationRescheduleResult {
        if let remaining = reschedulesToPassBeforeSuspension, remaining > 0 {
            reschedulesToPassBeforeSuspension = remaining - 1
        } else if reschedulesToPassBeforeSuspension != nil {
            reschedulesToPassBeforeSuspension = nil
            let observers = suspensionObservedContinuations
            suspensionObservedContinuations.removeAll()
            for observer in observers { observer.resume() }
            await withCheckedContinuation { continuation in
                suspendedRescheduleContinuation = continuation
            }
        }
        return NotificationRescheduleResult(requested: 0, scheduled: 0, failed: 0)
    }

    func suspendReschedule(afterPassingCalls callCount: Int) {
        reschedulesToPassBeforeSuspension = callCount
    }

    func waitUntilRescheduleIsSuspended() async {
        if suspendedRescheduleContinuation != nil { return }
        await withCheckedContinuation { continuation in
            suspensionObservedContinuations.append(continuation)
        }
    }

    func resumeSuspendedReschedule() {
        suspendedRescheduleContinuation?.resume()
        suspendedRescheduleContinuation = nil
    }
}

private actor ReimportSnapshotNoop: FlightCountdownSnapshotClient {
    func persist(_ snapshot: FlightCountdownSnapshot?) async {}
    func reloadWidgets() async {}
}

/// Counts snapshot uploads so a test can assert that a failed import published nothing.
private actor RecordingDeviceScheduleService: DeviceScheduleCloudKitServicing {
    private var uploads = 0

    func uploadCount() -> Int { uploads }

    func uploadDeviceSchedule(
        gemsID: String,
        cloudKitRecordName: String,
        schedules: [PayPeriodSchedule],
        deviceID: String,
        source: DeviceScheduleSyncSource
    ) async throws {
        uploads += 1
    }

    func fetchDeviceSchedule(gemsID: String) async throws -> DeviceScheduleSnapshot? { nil }
}

private final class ReimportTestCacheService: ScheduleCacheServiceProtocol, @unchecked Sendable {
    private var snapshot: ScheduleCacheSnapshotV2?
    func load() -> ScheduleCacheSnapshotV2? { snapshot }
    func save(_ snapshot: ScheduleCacheSnapshotV2) throws { self.snapshot = snapshot }
    func clear() { snapshot = nil }
}

private struct ReimportTestFriendService: FriendScheduleCloudKitServicing {
    func uploadSchedule(gemsID: String, cloudKitRecordName: String, schedules: [PayPeriodSchedule]) async throws {}
    func uploadScheduleSnapshot(gemsID: String, ownerDisplayName: String, crewAccessTrips: [CrewAccessTripJSON]) async throws {}
    func requestFriend(myGEMSID: String, friendGEMSID: String, friendResetAt: Date?) async throws -> FriendScheduleCloudKitLink {
        FriendScheduleCloudKitLink(friendGEMSID: friendGEMSID, isAccepted: false, linkedAt: nil, requestedAt: Date())
    }
    func cancelFriendRequest(myGEMSID: String, friendGEMSID: String) async throws {}
    func deleteSharedScheduleData(gemsID: String) async throws {}
    func deleteFriendSharingData(gemsID: String) async throws {}
    func refreshConnections(myGEMSID: String, connections: [FriendConnection], friendResetAt: Date?) async throws -> FriendConnectionRefreshResult {
        FriendConnectionRefreshResult(connections: connections)
    }
}
