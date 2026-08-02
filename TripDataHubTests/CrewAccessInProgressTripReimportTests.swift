import CloudKit
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
/// Fixtures are synthetic. No real trip, PDF or crew identity appears here.
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

    /// The source JSON is gone by the time reconcile runs (here: the retention policy prunes it,
    /// which is the production path that deletes a just-written import file). The import must
    /// report failure, restore the previous state, and upload nothing.
    ///
    /// The retention window is pinned via the injected reference date, so the outcome does not
    /// depend on the machine date or on where today falls in the Bid Period table.
    func test_sourceJSONLostBeforeReconcile_rollsBackAndUploadsNothing() async throws {
        // Inside BP26-05 (starts 2026-07-12). With "1 previous" retention, BP26-04 and BP26-05 are
        // retained and BP26-01 is not — fixed facts about the Bid Period table, not about today.
        let harness = try makeHarness(retentionReferenceDate: Self.date("2026-07-20T12:00:00Z"))
        let vm = harness.device.viewModel
        pinRetentionSelection("1")

        await harness.confirm(payload: revisedTrip())
        let timelineBefore = vm.crewAccessSchedules
        XCTAssertFalse(timelineBefore.isEmpty, "precondition: a retained trip is on the Timeline")

        let uploadsBefore = await harness.deviceSchedules.uploadCount()
        vm.pendingImport = Self.pendingImport(for: Self.outOfRetentionTrip())
        await vm.confirmPendingImport()
        await harness.settle()

        XCTAssertTrue(
            (vm.crewAccessImportMessage ?? "").hasPrefix("Import failed"),
            "an import whose trip vanished from the rebuilt Timeline must not report success"
        )
        XCTAssertEqual(
            vm.crewAccessSchedules,
            timelineBefore,
            "the previous Timeline must be restored verbatim"
        )
        XCTAssertFalse(
            vm.crewAccessSchedules.isEmpty,
            "the fail-closed path must never leave the Timeline empty"
        )
        XCTAssertFalse(
            harness.device.localFileNames().contains(where: { $0.contains(Self.outOfRetentionTripID) }),
            "the rolled-back JSON must not remain on disk"
        )
        let uploadsAfter = await harness.deviceSchedules.uploadCount()
        XCTAssertEqual(
            uploadsAfter,
            uploadsBefore,
            "no schedule snapshot may be uploaded for a failed import"
        )
        let liveOutOfRetention = await harness.cloud.liveGeneratedAt(tripID: Self.outOfRetentionTripID)
        XCTAssertNil(liveOutOfRetention, "the failed import must not reach CloudKit")
    }

    /// A stale same-trip JSON stored under a *different* file name is removed before verification
    /// runs. When verification then fails, that file must come back too — restoring only the new
    /// file's path would leave the trip with no source at all, which is the very state the
    /// fail-closed path exists to prevent.
    func test_failedImport_restoresStaleSameTripJSONRemovedBeforeVerification() async throws {
        let harness = try makeHarness(retentionReferenceDate: Self.date("2026-07-20T12:00:00Z"))
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

        // This import is pruned by retention, so it fails verification and rolls back.
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
        deadhead: Bool = false
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
            stdUtc: nil,
            staUtc: nil,
            atdUtc: nil,
            ataUtc: nil,
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
        retentionReferenceDate: Date = CrewAccessInProgressTripReimportTests.date("2026-07-20T12:00:00Z")
    ) throws -> Harness {
        let cloud = cloud ?? ImportRaceCloud()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrewAccessReimportTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suiteName = "CrewAccessReimportTests.\(name).\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let deviceSchedules = RecordingDeviceScheduleService()

        let viewModel = AppViewModel(
            cacheService: ReimportTestCacheService(),
            friendScheduleCloudKitService: ReimportTestFriendService(),
            deviceScheduleCloudKitService: deviceSchedules,
            crewAccessImportCloudKitService: ImportRaceService(cloud: cloud),
            syncStateDefaults: defaults,
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
        return Harness(device: device, cloud: cloud, deviceSchedules: deviceSchedules)
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
