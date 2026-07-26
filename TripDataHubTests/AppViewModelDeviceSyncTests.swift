import CloudKit
import UIKit
import UserNotifications
import XCTest
@testable import TripDataHub

@MainActor
final class AppViewModelDeviceSyncTests: XCTestCase {

    private let crewAccessOutboxStateKeys = [
        "crewaccess_tombstone_observed_v1",
        "crewaccess_deleted_payload_fingerprints_v1",
        "crewaccess_reimported_trip_keys_v1"
    ]

    override func setUp() {
        super.setUp()
        clearCrewAccessOutboxState()
    }

    override func tearDown() {
        clearCrewAccessOutboxState()
        super.tearDown()
    }

    func test_uploadDeviceSchedule_differentSchedules_uploadsAgain() async throws {
        let deviceService = FakeDeviceScheduleCloudKitService()
        let vm = makeViewModel(deviceService: deviceService)
        setVerifiedIdentity(on: vm)

        vm.crewAccessSchedules = [makeSchedule(id: "CA26-01")]
        await vm.uploadDeviceScheduleIfNeeded(reason: "first")

        vm.crewAccessSchedules = [makeSchedule(id: "CA26-02")]
        await vm.uploadDeviceScheduleIfNeeded(reason: "second")

        let count = await deviceService.uploadCallCount
        XCTAssertEqual(count, 2)
    }

    func test_uploadDeviceSchedule_noVerifiedIdentity_skips() async throws {
        let deviceService = FakeDeviceScheduleCloudKitService()
        let vm = makeViewModel(deviceService: deviceService)
        vm.crewAccessSchedules = [makeSchedule(id: "CA26-01")]
        // no setVerifiedIdentity

        await vm.uploadDeviceScheduleIfNeeded(reason: "test")

        let count = await deviceService.uploadCallCount
        XCTAssertEqual(count, 0)
    }

    func test_uploadDeviceSchedule_emptySchedules_uploadsEmptySnapshot() async throws {
        // Empty crewAccessSchedules must still upload to propagate "all trips deleted" to other devices.
        let deviceService = FakeDeviceScheduleCloudKitService()
        let vm = makeViewModel(deviceService: deviceService)
        setVerifiedIdentity(on: vm)
        // crewAccessSchedules stays empty

        await vm.uploadDeviceScheduleIfNeeded(reason: "test")

        let count = await deviceService.uploadCallCount
        XCTAssertEqual(count, 1)
        let uploaded = await deviceService.lastUploadedSchedules
        XCTAssertEqual(uploaded?.count, 0)
    }

    // MARK: - Fetch: newer remote replaces local

    func test_fetchLegacyFallback_appliesSnapshotWhenTimelineIsEmpty() async throws {
        let deviceService = FakeDeviceScheduleCloudKitService()
        let fetchKey = "device_schedule_last_fetch_at_v1"
        UserDefaults.standard.removeObject(forKey: fetchKey)
        defer { UserDefaults.standard.removeObject(forKey: fetchKey) }
        await deviceService.setSnapshot(DeviceScheduleSnapshot(
            ownerGEMSID: "7793942",
            ownerRecordName: "_rec",
            schedules: [makeSchedule(id: "CA26-99")],
            schemaVersion: 1,
            updatedAt: Date(),
            deviceID: "other-device",
            source: .iphone
        ))

        let vm = makeViewModel(deviceService: deviceService)
        setVerifiedIdentity(on: vm)
        vm.crewAccessSchedules = []

        await vm.fetchLegacyDeviceScheduleFallbackIfNeeded(reason: "test")

        XCTAssertEqual(vm.crewAccessSchedules.count, 1)
        XCTAssertEqual(vm.crewAccessSchedules[0].id, "CA26-99")
    }

    /// The legacy snapshot has no per-trip merge, so it must never overwrite a Timeline that
    /// the file-backed sync layer already rebuilt — regardless of how new the snapshot looks.
    func test_fetchLegacyFallback_neverOverwritesTimelineRebuiltFromFiles() async throws {
        let deviceService = FakeDeviceScheduleCloudKitService()
        let fetchKey = "device_schedule_last_fetch_at_v1"
        UserDefaults.standard.removeObject(forKey: fetchKey)
        defer { UserDefaults.standard.removeObject(forKey: fetchKey) }
        await deviceService.setSnapshot(DeviceScheduleSnapshot(
            ownerGEMSID: "7793942",
            ownerRecordName: "_rec",
            schedules: [makeSchedule(id: "CA26-99")],
            schemaVersion: 1,
            updatedAt: Date(timeIntervalSinceNow: 3600),
            deviceID: "other-device",
            source: .iphone
        ))

        let vm = makeViewModel(deviceService: deviceService)
        setVerifiedIdentity(on: vm)
        vm.crewAccessSchedules = [makeSchedule(id: "CA26-from-files")]

        await vm.fetchLegacyDeviceScheduleFallbackIfNeeded(reason: "test")

        XCTAssertEqual(vm.crewAccessSchedules.map(\.id), ["CA26-from-files"])
        let fetchCount = await deviceService.fetchCallCount
        XCTAssertEqual(fetchCount, 0, "A non-empty Timeline must short-circuit before the network call")
    }

    func test_fetchLegacyFallback_alreadySeenSnapshot_isSkipped() async throws {
        let deviceService = FakeDeviceScheduleCloudKitService()
        let olderDate = Date(timeIntervalSinceNow: -3600)
        let newerDate = Date()
        await deviceService.setSnapshot(DeviceScheduleSnapshot(
            ownerGEMSID: "7793942",
            ownerRecordName: "_rec",
            schedules: [makeSchedule(id: "CA26-remote")],
            schemaVersion: 1,
            updatedAt: olderDate,
            deviceID: "other-device",
            source: .iphone
        ))

        let fetchKey = "device_schedule_last_fetch_at_v1"
        UserDefaults.standard.set(newerDate, forKey: fetchKey)
        defer { UserDefaults.standard.removeObject(forKey: fetchKey) }
        let vm = makeViewModel(deviceService: deviceService)
        setVerifiedIdentity(on: vm)
        vm.crewAccessSchedules = []

        await vm.fetchLegacyDeviceScheduleFallbackIfNeeded(reason: "test")

        XCTAssertTrue(vm.crewAccessSchedules.isEmpty)
    }

    func test_fetchLegacyFallback_sameDevice_isSkipped() async throws {
        let deviceService = FakeDeviceScheduleCloudKitService()
        let knownDeviceID = try XCTUnwrap(UIDevice.current.identifierForVendor?.uuidString)
        let fetchKey = "device_schedule_last_fetch_at_v1"
        UserDefaults.standard.removeObject(forKey: fetchKey)
        defer { UserDefaults.standard.removeObject(forKey: fetchKey) }

        await deviceService.setSnapshot(DeviceScheduleSnapshot(
            ownerGEMSID: "7793942",
            ownerRecordName: "_rec",
            schedules: [makeSchedule(id: "CA26-remote")],
            schemaVersion: 1,
            updatedAt: Date(),
            deviceID: knownDeviceID,
            source: .iphone
        ))

        let vm = makeViewModel(deviceService: deviceService)
        setVerifiedIdentity(on: vm)
        vm.crewAccessSchedules = []

        await vm.fetchLegacyDeviceScheduleFallbackIfNeeded(reason: "test")

        XCTAssertTrue(vm.crewAccessSchedules.isEmpty)
    }

    /// Server modification dates and local file mtimes measure different events, so the
    /// fallback must not compare them. With an empty Timeline a snapshot older than local
    /// file mtimes is still the best available data.
    func test_fetchLegacyFallback_doesNotCompareServerSnapshotToLocalFileTimestamp() async throws {
        let deviceService = FakeDeviceScheduleCloudKitService()
        let pastSnapshot = Date(timeIntervalSinceNow: -3600)
        let fetchKey = "device_schedule_last_fetch_at_v1"
        UserDefaults.standard.removeObject(forKey: fetchKey)
        defer { UserDefaults.standard.removeObject(forKey: fetchKey) }
        await deviceService.setSnapshot(DeviceScheduleSnapshot(
            ownerGEMSID: "7793942",
            ownerRecordName: "_rec",
            schedules: [makeSchedule(id: "CA26-remote-old")],
            schemaVersion: 1,
            updatedAt: pastSnapshot,
            deviceID: "other-device",
            source: .iphone
        ))

        let vm = makeViewModel(deviceService: deviceService)
        setVerifiedIdentity(on: vm)
        // makeSchedule stamps updatedAt with Date(), i.e. newer than the snapshot.
        vm.crewAccessSchedules = []
        vm.bidproSchedules = [makeSchedule(id: "PP26-local-new")]

        await vm.fetchLegacyDeviceScheduleFallbackIfNeeded(reason: "test")

        XCTAssertEqual(vm.crewAccessSchedules.map(\.id), ["CA26-remote-old"])
    }

    func test_fetchLegacyFallback_noVerifiedIdentity_skips() async throws {
        let deviceService = FakeDeviceScheduleCloudKitService()
        await deviceService.setSnapshot(DeviceScheduleSnapshot(
            ownerGEMSID: "7793942",
            ownerRecordName: "_rec",
            schedules: [makeSchedule(id: "CA26-remote")],
            schemaVersion: 1,
            updatedAt: Date(),
            deviceID: "other",
            source: .iphone
        ))

        let vm = makeViewModel(deviceService: deviceService)
        vm.crewAccessSchedules = []

        await vm.fetchLegacyDeviceScheduleFallbackIfNeeded(reason: "test")

        XCTAssertTrue(vm.crewAccessSchedules.isEmpty)
    }

    func test_syncCrewAccessDeviceData_importFetchFailure_preservesLocalAndSkipsSnapshot() async throws {
        try removeCrewAccessImportDirectory()
        defer { try? removeCrewAccessImportDirectory() }

        let deviceService = FakeDeviceScheduleCloudKitService()
        let vm = makeViewModel(
            deviceService: deviceService,
            importCloudKitService: FailingCrewAccessImportCloudKitService()
        )
        setVerifiedIdentity(on: vm)
        vm.crewAccessSchedules = [makeSchedule(id: "CA26-local")]

        await vm.syncCrewAccessDeviceData(reason: "import fetch failure")

        XCTAssertEqual(vm.crewAccessSchedules.map(\.id), ["CA26-local"])
        let fetchCount = await deviceService.fetchCallCount
        let uploadCount = await deviceService.uploadCallCount
        XCTAssertEqual(fetchCount, 0)
        XCTAssertEqual(uploadCount, 0)
    }

    func test_syncCrewAccessDeviceData_snapshotFetchFailure_preservesLocalAndSkipsUpload() async throws {
        try removeCrewAccessImportDirectory()
        defer { try? removeCrewAccessImportDirectory() }

        let deviceService = FakeDeviceScheduleCloudKitService()
        await deviceService.setShouldFailFetch(true)
        let vm = makeViewModel(deviceService: deviceService)
        setVerifiedIdentity(on: vm)
        vm.crewAccessSchedules = [makeSchedule(id: "CA26-local")]

        await vm.syncCrewAccessDeviceData(reason: "snapshot fetch failure")

        XCTAssertEqual(vm.crewAccessSchedules.map(\.id), ["CA26-local"])
        let fetchCount = await deviceService.fetchCallCount
        let uploadCount = await deviceService.uploadCallCount
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(uploadCount, 0)
    }

    func test_fetchCrewAccessImports_retriesPreviouslySkippedLocalUpload() async throws {
        try removeCrewAccessImportDirectory()
        defer { try? removeCrewAccessImportDirectory() }

        let fileName = "2026-06-01_RETRY01.json"
        let payload = makeCrewAccessJSON(
            tripId: "RETRY01",
            tripInformationDate: "01Jun2026",
            startUtc: "2026-06-01T08:00:00Z",
            endUtc: "2026-06-01T10:00:00Z"
        )
        try writeCrewAccessJSON(payload, fileName: fileName)

        let importCloudKitService = CapturingCrewAccessImportCloudKitService()
        let vm = makeViewModel(
            deviceService: FakeDeviceScheduleCloudKitService(),
            importCloudKitService: importCloudKitService
        )
        setVerifiedIdentity(on: vm)

        await vm.fetchCrewAccessImportFilesIfNeeded(reason: "test recovery")

        let uploadedFileNames = await importCloudKitService.uploadedFileNames
        XCTAssertEqual(uploadedFileNames, [fileName])
    }

    func test_fetchCrewAccessImports_legacyDeletionIntentTombstonesLiveRemoteOnFirstSync() async throws {
        try removeCrewAccessImportDirectory()
        defer { try? removeCrewAccessImportDirectory() }

        let legacyDeletionKey = "deleted_crewaccess_trip_keys_v1"
        let deletionIntentsKey = "deleted_crewaccess_trip_intents_v2"
        UserDefaults.standard.removeObject(forKey: deletionIntentsKey)
        UserDefaults.standard.set(["2605:40303"], forKey: legacyDeletionKey)
        defer {
            UserDefaults.standard.removeObject(forKey: legacyDeletionKey)
            UserDefaults.standard.removeObject(forKey: deletionIntentsKey)
        }

        let trip40303 = makeCrewAccessJSON(
            tripId: "40303",
            tripInformationDate: "12Jul2026",
            startUtc: "2026-07-12T21:55:00Z",
            endUtc: "2026-07-14T13:56:00Z"
        )
        let tripA70606 = makeCrewAccessJSON(
            tripId: "A70606",
            tripInformationDate: "15Jul2026",
            startUtc: "2026-07-15T07:13:00Z",
            endUtc: "2026-07-18T19:32:00Z"
        )
        let encoder = JSONEncoder()
        let reimportedAt = Date()
        let importCloudKitService = StatefulCrewAccessImportCloudKitService(records: [
            CrewAccessImportCloudKitRecord(
                fileName: "2026-07-12_40303.json",
                jsonData: try encoder.encode(trip40303),
                tripInformationDate: trip40303.tripInformationDate,
                firstDepartureUTC: trip40303.items.first?.startUtc,
                updatedAt: reimportedAt,
                deletedAt: nil
            ),
            CrewAccessImportCloudKitRecord(
                fileName: "2026-07-15_A70606.json",
                jsonData: try encoder.encode(tripA70606),
                tripInformationDate: tripA70606.tripInformationDate,
                firstDepartureUTC: tripA70606.items.first?.startUtc,
                updatedAt: reimportedAt,
                deletedAt: nil
            )
        ])
        let vm = makeViewModel(
            deviceService: FakeDeviceScheduleCloudKitService(),
            importCloudKitService: importCloudKitService
        )
        setVerifiedIdentity(on: vm)

        let fetched = await vm.fetchCrewAccessImportFilesIfNeeded(reason: "iPad cold sync")
        await vm.reconcileCrewAccessSchedulesWithImportFiles()

        XCTAssertTrue(fetched)
        XCTAssertEqual(
            Set(vm.crewAccessSchedules.flatMap { $0.legs.map(\.pairing) }),
            ["A70606"]
        )
        let tombstonedAfterReimport = await importCloudKitService.tombstonedFileNames
        XCTAssertEqual(tombstonedAfterReimport, ["2026-07-12_40303.json"])
        let storedIntents = UserDefaults.standard.dictionary(forKey: deletionIntentsKey) ?? [:]
        XCTAssertNotNil(storedIntents["2605:40303"])
        XCTAssertNil(UserDefaults.standard.object(forKey: legacyDeletionKey))
    }

    func test_fetchCrewAccessImports_deletionIntentTombstonesLiveRemoteWithoutClockComparison() async throws {
        try removeCrewAccessImportDirectory()
        defer { try? removeCrewAccessImportDirectory() }

        let legacyDeletionKey = "deleted_crewaccess_trip_keys_v1"
        let deletionIntentsKey = "deleted_crewaccess_trip_intents_v2"
        UserDefaults.standard.removeObject(forKey: legacyDeletionKey)
        UserDefaults.standard.set(
            ["2605:40303": Date(timeIntervalSinceNow: 60).timeIntervalSince1970],
            forKey: deletionIntentsKey
        )
        defer {
            UserDefaults.standard.removeObject(forKey: legacyDeletionKey)
            UserDefaults.standard.removeObject(forKey: deletionIntentsKey)
        }

        let trip40303 = makeCrewAccessJSON(
            tripId: "40303",
            tripInformationDate: "12Jul2026",
            startUtc: "2026-07-12T21:55:00Z",
            endUtc: "2026-07-14T13:56:00Z"
        )
        let importCloudKitService = StatefulCrewAccessImportCloudKitService(records: [
            CrewAccessImportCloudKitRecord(
                fileName: "2026-07-12_40303.json",
                jsonData: try JSONEncoder().encode(trip40303),
                tripInformationDate: trip40303.tripInformationDate,
                firstDepartureUTC: trip40303.items.first?.startUtc,
                updatedAt: Date(),
                deletedAt: nil
            )
        ])
        let vm = makeViewModel(
            deviceService: FakeDeviceScheduleCloudKitService(),
            importCloudKitService: importCloudKitService
        )
        setVerifiedIdentity(on: vm)

        let fetched = await vm.fetchCrewAccessImportFilesIfNeeded(reason: "newer delete")
        await vm.reconcileCrewAccessSchedulesWithImportFiles()

        XCTAssertTrue(fetched)
        XCTAssertTrue(vm.crewAccessSchedules.isEmpty)
        let tombstonedAfterDelete = await importCloudKitService.tombstonedFileNames
        XCTAssertEqual(tombstonedAfterDelete, ["2026-07-12_40303.json"])
    }

    func test_fetchCrewAccessImports_automaticLocalFileDoesNotOverrideRemoteTombstone() async throws {
        try removeCrewAccessImportDirectory()
        defer { try? removeCrewAccessImportDirectory() }

        let legacyDeletionKey = "deleted_crewaccess_trip_keys_v1"
        let deletionIntentsKey = "deleted_crewaccess_trip_intents_v2"
        UserDefaults.standard.removeObject(forKey: legacyDeletionKey)
        UserDefaults.standard.set(
            ["2605:40303": Date(timeIntervalSinceNow: -120).timeIntervalSince1970],
            forKey: deletionIntentsKey
        )
        defer {
            UserDefaults.standard.removeObject(forKey: legacyDeletionKey)
            UserDefaults.standard.removeObject(forKey: deletionIntentsKey)
        }

        let fileName = "2026-07-12_40303.json"
        let trip40303 = makeCrewAccessJSON(
            tripId: "40303",
            tripInformationDate: "12Jul2026",
            startUtc: "2026-07-12T21:55:00Z",
            endUtc: "2026-07-14T13:56:00Z"
        )
        try writeCrewAccessJSON(trip40303, fileName: fileName)
        let encodedTrip = try JSONEncoder().encode(trip40303)
        let importCloudKitService = StatefulCrewAccessImportCloudKitService(records: [
            CrewAccessImportCloudKitRecord(
                fileName: fileName,
                jsonData: encodedTrip,
                tripInformationDate: trip40303.tripInformationDate,
                firstDepartureUTC: trip40303.items.first?.startUtc,
                updatedAt: Date(timeIntervalSinceNow: -120),
                deletedAt: Date(timeIntervalSinceNow: -120)
            )
        ])
        let vm = makeViewModel(
            deviceService: FakeDeviceScheduleCloudKitService(),
            importCloudKitService: importCloudKitService
        )
        setVerifiedIdentity(on: vm)

        let fetched = await vm.fetchCrewAccessImportFilesIfNeeded(reason: "local reimport recovery")
        await vm.reconcileCrewAccessSchedulesWithImportFiles()

        XCTAssertTrue(fetched)
        XCTAssertTrue(vm.crewAccessSchedules.isEmpty)
        let uploadedAfterRecovery = await importCloudKitService.uploadedFileNames
        XCTAssertTrue(uploadedAfterRecovery.isEmpty)
        let storedIntents = UserDefaults.standard.dictionary(forKey: deletionIntentsKey) ?? [:]
        XCTAssertNotNil(storedIntents["2605:40303"])
    }

    // MARK: - LogTen backlog survival

    func test_fetchLegacyFallback_logTenBacklogSurvivesRemoteReplacement() async throws {
        let deviceService = FakeDeviceScheduleCloudKitService()
        let futureSnapshot = Date(timeIntervalSinceNow: 60)
        let fetchKey = "device_schedule_last_fetch_at_v1"
        UserDefaults.standard.removeObject(forKey: fetchKey)
        defer { UserDefaults.standard.removeObject(forKey: fetchKey) }
        await deviceService.setSnapshot(DeviceScheduleSnapshot(
            ownerGEMSID: "7793942",
            ownerRecordName: "_rec",
            schedules: [makeSchedule(id: "CA26-99")],
            schemaVersion: 1,
            updatedAt: futureSnapshot,
            deviceID: "other-device",
            source: .iphone
        ))

        let vm = makeViewModel(deviceService: deviceService)
        setVerifiedIdentity(on: vm)
        vm.crewAccessSchedules = []

        await vm.fetchLegacyDeviceScheduleFallbackIfNeeded(reason: "test")

        // Remote schedule applied to the empty Timeline
        XCTAssertEqual(vm.crewAccessSchedules[0].id, "CA26-99")
        // LogTen export must not crash after replacement
        _ = vm.exportCrewAccessFlightsLogTenCSV()
    }

    /// reconcile → prune wipes the LogTen reference times when the Timeline rebuilds to empty.
    /// A failed fallback fetch rolls the Timeline back, and the reference times must roll back
    /// with it — otherwise a plain network error silently destroys the export backlog.
    func test_syncCrewAccessDeviceData_snapshotFetchFailure_restoresLogTenReferenceTimes() async throws {
        try removeCrewAccessImportDirectory()
        defer { try? removeCrewAccessImportDirectory() }

        let referenceKey = "crewaccess_leg_import_reference_times_v1"
        UserDefaults.standard.removeObject(forKey: referenceKey)
        defer { UserDefaults.standard.removeObject(forKey: referenceKey) }

        let deviceService = FakeDeviceScheduleCloudKitService()
        await deviceService.setShouldFailFetch(true)
        let vm = makeViewModel(deviceService: deviceService)
        setVerifiedIdentity(on: vm)
        vm.crewAccessSchedules = [makeSchedule(id: "CA26-local")]
        // Backfill derives reference times from the current schedules and persists them.
        vm.backfillCrewAccessLegImportReferenceTimesIfNeeded()
        let referenceTimesBefore = vm.crewAccessLegImportReferenceTimes
        XCTAssertFalse(referenceTimesBefore.isEmpty, "precondition: backlog reference times exist")

        await vm.syncCrewAccessDeviceData(reason: "snapshot fetch failure")

        XCTAssertEqual(vm.crewAccessSchedules.map(\.id), ["CA26-local"])
        XCTAssertEqual(
            vm.crewAccessLegImportReferenceTimes,
            referenceTimesBefore,
            "LogTen reference times must be restored alongside the rolled-back Timeline"
        )
        let persisted = UserDefaults.standard.dictionary(forKey: referenceKey) as? [String: Double]
        XCTAssertEqual(persisted?.count, referenceTimesBefore.count, "restore must also persist")
    }

    /// The success path is the easier one to get wrong: the fallback preserves whatever
    /// reference-time map it finds on entry, so if reconcile's prune is not undone *before*
    /// the fallback runs, a successful fetch quietly persists the emptied map.
    func test_syncCrewAccessDeviceData_snapshotFetchSuccess_restoresLogTenReferenceTimes() async throws {
        try removeCrewAccessImportDirectory()
        defer { try? removeCrewAccessImportDirectory() }

        let referenceKey = "crewaccess_leg_import_reference_times_v1"
        let fetchKey = "device_schedule_last_fetch_at_v1"
        UserDefaults.standard.removeObject(forKey: referenceKey)
        UserDefaults.standard.removeObject(forKey: fetchKey)
        defer {
            UserDefaults.standard.removeObject(forKey: referenceKey)
            UserDefaults.standard.removeObject(forKey: fetchKey)
        }

        let deviceService = FakeDeviceScheduleCloudKitService()
        await deviceService.setSnapshot(DeviceScheduleSnapshot(
            ownerGEMSID: "7793942",
            ownerRecordName: "_rec",
            schedules: [makeSchedule(id: "CA26-remote")],
            schemaVersion: 1,
            updatedAt: Date(),
            deviceID: "other-device",
            source: .iphone
        ))

        let vm = makeViewModel(deviceService: deviceService)
        setVerifiedIdentity(on: vm)
        vm.crewAccessSchedules = [makeSchedule(id: "CA26-local")]
        vm.backfillCrewAccessLegImportReferenceTimesIfNeeded()
        let referenceTimesBefore = vm.crewAccessLegImportReferenceTimes
        XCTAssertFalse(referenceTimesBefore.isEmpty, "precondition: backlog reference times exist")

        await vm.syncCrewAccessDeviceData(reason: "snapshot fetch success")

        XCTAssertEqual(
            vm.crewAccessSchedules.map(\.id),
            ["CA26-remote"],
            "precondition: the fallback actually applied the snapshot"
        )
        XCTAssertEqual(
            vm.crewAccessLegImportReferenceTimes,
            referenceTimesBefore,
            "LogTen reference times must survive a successful fallback, not just a failed one"
        )
        let persisted = UserDefaults.standard.dictionary(forKey: referenceKey) as? [String: Double]
        XCTAssertEqual(persisted?.count, referenceTimesBefore.count, "restore must also persist")
    }

    // MARK: - CrewAccess deletion

    func test_deleteImportedCrewAccessTrip_removesJSONSoReconciliationDoesNotResurrect() async throws {
        try removeCrewAccessImportDirectory()
        defer { try? removeCrewAccessImportDirectory() }

        let deviceService = FakeDeviceScheduleCloudKitService()
        let vm = AppViewModel(
            syncService: NoopSyncService(),
            authService: NoopAuthService(),
            cacheService: InMemoryCacheService(),
            notificationService: NoopNotificationService(),
            crewAccessImportService: CrewAccessPDFImportService(),
            friendScheduleCloudKitService: NoopFriendCloudKitService(),
            gemsVerificationCloudKitService: NoopGEMSVerificationService(),
            deviceScheduleCloudKitService: deviceService,
            crewAccessImportCloudKitService: NoopCrewAccessImportCloudKitService(),
            keychainService: EmptyKeychainService()
        )

        let sampleURL = repositoryRootURL()
            .appendingPathComponent("web")
            .appendingPathComponent("sample")
            .appendingPathComponent("TripDataHub_App_Review_Sample_A00001.pdf")
        let data = try Data(contentsOf: sampleURL)

        let importAccepted = await vm.importCrewAccessPDFData(data, sourceFileName: sampleURL.lastPathComponent)
        XCTAssertTrue(importAccepted)
        XCTAssertEqual(vm.pendingImport?.tripId, "A00001")
        await vm.confirmPendingImport()

        XCTAssertNil(vm.pendingImport)
        XCTAssertEqual(Set(vm.crewAccessSchedules.flatMap { $0.legs.map(\.pairing) }), ["A00001"])
        XCTAssertFalse(crewAccessImportJSONFiles().isEmpty)

        await vm.deleteCrewAccessTrips(ids: Set(vm.crewAccessSchedules.map(\.id)))

        XCTAssertTrue(crewAccessImportJSONFiles().isEmpty)

        await vm.applyCrewAccessRetentionPolicy()

        XCTAssertTrue(vm.crewAccessSchedules.isEmpty)
        XCTAssertTrue(vm.schedules.allSatisfy { schedule in
            !schedule.legs.contains { $0.pairing == "A00001" }
        })
    }

    func test_deleteImportedCrewAccessTrip_removesLegacyNamedJSONByPayloadTripID() async throws {
        try removeCrewAccessImportDirectory()
        defer { try? removeCrewAccessImportDirectory() }

        let deviceService = FakeDeviceScheduleCloudKitService()
        let vm = AppViewModel(
            syncService: NoopSyncService(),
            authService: NoopAuthService(),
            cacheService: InMemoryCacheService(),
            notificationService: NoopNotificationService(),
            crewAccessImportService: CrewAccessPDFImportService(),
            friendScheduleCloudKitService: NoopFriendCloudKitService(),
            gemsVerificationCloudKitService: NoopGEMSVerificationService(),
            deviceScheduleCloudKitService: deviceService,
            crewAccessImportCloudKitService: NoopCrewAccessImportCloudKitService(),
            keychainService: EmptyKeychainService()
        )

        let payload = makeCrewAccessJSON(
            tripId: "B00001",
            tripInformationDate: "01Jun2026",
            startUtc: "2026-06-01T08:00:00Z",
            endUtc: "2026-06-01T10:00:00Z"
        )
        try writeCrewAccessJSON(payload, fileName: "legacy-import-\(UUID().uuidString).json")
        vm.crewAccessSchedules = [
            makeSchedule(
                id: "CA26-06-B00001",
                pairing: "B00001",
                depUTC: "2026-06-01T08:00:00Z",
                arrUTC: "2026-06-01T10:00:00Z"
            )
        ]

        await vm.deleteCrewAccessTrips(ids: Set(vm.crewAccessSchedules.map(\.id)))

        XCTAssertFalse(crewAccessImportJSONFilesContainTripID("B00001"))

        await vm.applyCrewAccessRetentionPolicy()

        XCTAssertFalse(vm.crewAccessSchedules.contains { schedule in
            schedule.legs.contains { $0.pairing == "B00001" }
        })
    }

    func test_confirmImport_preserves40303AndA70606WhenOnlyBaseLocalDatesOverlap() async throws {
        try removeCrewAccessImportDirectory()
        defer { try? removeCrewAccessImportDirectory() }

        let existingJSON = makeCrewAccessJSON(
            tripId: "40303",
            tripInformationDate: "12Jul2026",
            startUtc: "2026-07-12T21:55:00Z",
            endUtc: "2026-07-14T13:56:00Z"
        )
        let incomingJSON = makeCrewAccessJSON(
            tripId: "A70606",
            tripInformationDate: "15Jul2026",
            startUtc: "2026-07-15T07:13:00Z",
            endUtc: "2026-07-18T19:32:00Z"
        )
        try writeCrewAccessJSON(existingJSON, fileName: "2026-07-12_40303.json")

        let incomingSchedule = makeSchedule(
            id: "CA26-05-A70606",
            pairing: "A70606",
            depUTC: "2026-07-15T07:13:00Z",
            arrUTC: "2026-07-18T19:32:00Z"
        )
        let vm = makeImportViewModel(
            schedule: incomingSchedule,
            json: incomingJSON,
            sourceFileName: "Trip_Id_A70606.pdf"
        )
        setVerifiedIdentity(on: vm)
        vm.crewAccessSchedules = [
            makeSchedule(
                id: "CA26-05-40303",
                pairing: "40303",
                depUTC: "2026-07-12T21:55:00Z",
                arrUTC: "2026-07-14T13:56:00Z"
            )
        ]

        let importAccepted = await vm.importCrewAccessPDFData(
            Data([0x25, 0x50, 0x44, 0x46]),
            sourceFileName: "Trip_Id_A70606.pdf"
        )
        XCTAssertTrue(importAccepted)
        XCTAssertFalse(vm.pendingImportReplacementCandidates.contains { candidate in
            candidate.tripId == "40303" && candidate.reason == .timeOverlap
        })

        await vm.confirmPendingImport()

        XCTAssertEqual(
            Set(vm.crewAccessSchedules.flatMap { $0.legs.map(\.pairing) }),
            ["40303", "A70606"]
        )
        XCTAssertTrue(crewAccessImportJSONFilesContainTripID("40303"))
        XCTAssertTrue(crewAccessImportJSONFilesContainTripID("A70606"))
    }

    func test_pendingImport_preservesMorningArrivalAndNoonDepartureOnSameLocalDay() async throws {
        let sourceFileName = "NOON02-\(UUID().uuidString).pdf"
        let pdfData = Data("%PDF-NOON02-\(UUID().uuidString)".utf8)
        let incomingJSON = makeCrewAccessJSON(
            tripId: "NOON02",
            tripInformationDate: "20Jul2026",
            // 12:00 in Anchorage (AKDT). Report begins at 10:30 local.
            startUtc: "2026-07-20T20:00:00Z",
            endUtc: "2026-07-20T22:00:00Z"
        )
        let incomingSchedule = makeSchedule(
            id: "CA26-05-NOON02",
            pairing: "NOON02",
            depUTC: "2026-07-20T20:00:00Z",
            arrUTC: "2026-07-20T22:00:00Z"
        )
        let vm = makeImportViewModel(
            schedule: incomingSchedule,
            json: incomingJSON,
            sourceFileName: sourceFileName
        )
        setVerifiedIdentity(on: vm)
        vm.crewAccessSchedules = [
            makeSchedule(
                id: "CA26-05-MORN01",
                pairing: "MORN01",
                depUTC: "2026-07-20T12:00:00Z",
                // 10:00 in Anchorage; post-flight duty ends at 10:30 local.
                arrUTC: "2026-07-20T18:00:00Z"
            )
        ]

        let importAccepted = await vm.importCrewAccessPDFData(
            pdfData,
            sourceFileName: sourceFileName
        )

        XCTAssertTrue(importAccepted)
        XCTAssertFalse(vm.pendingImportReplacementCandidates.contains { candidate in
            candidate.tripId == "MORN01" && candidate.reason == .timeOverlap
        })
        await vm.discardPendingImport()
    }

    func test_pendingImport_detectsOverlapWhenOperationalDutyBuffersIntersect() async throws {
        let sourceFileName = "NEXT02-\(UUID().uuidString).pdf"
        let pdfData = Data("%PDF-NEXT02-\(UUID().uuidString)".utf8)
        let incomingJSON = makeCrewAccessJSON(
            tripId: "NEXT02",
            tripInformationDate: "20Jul2026",
            // Flight times do not overlap, but the 17:30Z report is before the
            // existing trip's 18:30Z post-flight release.
            startUtc: "2026-07-20T19:00:00Z",
            endUtc: "2026-07-20T21:00:00Z"
        )
        let incomingSchedule = makeSchedule(
            id: "CA26-05-NEXT02",
            pairing: "NEXT02",
            depUTC: "2026-07-20T19:00:00Z",
            arrUTC: "2026-07-20T21:00:00Z"
        )
        let vm = makeImportViewModel(
            schedule: incomingSchedule,
            json: incomingJSON,
            sourceFileName: sourceFileName
        )
        setVerifiedIdentity(on: vm)
        vm.crewAccessSchedules = [
            makeSchedule(
                id: "CA26-05-FIRST01",
                pairing: "FIRST01",
                depUTC: "2026-07-20T12:00:00Z",
                arrUTC: "2026-07-20T18:00:00Z"
            )
        ]

        let importAccepted = await vm.importCrewAccessPDFData(
            pdfData,
            sourceFileName: sourceFileName
        )

        XCTAssertTrue(importAccepted)
        XCTAssertTrue(vm.pendingImportReplacementCandidates.contains { candidate in
            candidate.tripId == "FIRST01" && candidate.reason == .timeOverlap
        })
        await vm.discardPendingImport()
    }

    func test_pendingImport_usesBaseLocalDayFallbackWhenIncomingUTCMissing() async throws {
        let sourceFileName = "NO-UTC-\(UUID().uuidString).pdf"
        let pdfData = Data("%PDF-NO-UTC-\(UUID().uuidString)".utf8)
        let incomingJSON = makeCrewAccessJSON(
            tripId: "NO-UTC",
            tripInformationDate: "20Jul2026",
            startUtc: "",
            endUtc: ""
        )
        let incomingSchedule = makeSchedule(
            id: "CA26-05-NO-UTC",
            pairing: "NO-UTC",
            depUTC: "",
            arrUTC: ""
        )
        let vm = makeImportViewModel(
            schedule: incomingSchedule,
            json: incomingJSON,
            sourceFileName: sourceFileName
        )
        setVerifiedIdentity(on: vm)
        vm.crewAccessSchedules = [
            makeSchedule(
                id: "CA26-05-EXISTING",
                pairing: "EXISTING",
                depUTC: "2026-07-20T12:00:00Z",
                arrUTC: "2026-07-20T18:00:00Z"
            )
        ]

        let importAccepted = await vm.importCrewAccessPDFData(
            pdfData,
            sourceFileName: sourceFileName
        )

        XCTAssertTrue(importAccepted)
        XCTAssertTrue(vm.pendingImportReplacementCandidates.contains { candidate in
            candidate.tripId == "EXISTING" && candidate.reason == .timeOverlap
        })
        await vm.discardPendingImport()
    }

    func test_confirmImport_removesCommittedJSONBackup() async throws {
        try removeCrewAccessImportDirectory()
        defer { try? removeCrewAccessImportDirectory() }

        let existingJSON = makeCrewAccessJSON(
            tripId: "BACKUP1",
            tripInformationDate: "20Jul2026",
            startUtc: "2026-07-20T12:00:00Z",
            endUtc: "2026-07-20T18:00:00Z"
        )
        let incomingJSON = makeCrewAccessJSON(
            tripId: "BACKUP1",
            tripInformationDate: "20Jul2026",
            startUtc: "2026-07-20T13:00:00Z",
            endUtc: "2026-07-20T19:00:00Z"
        )
        try writeCrewAccessJSON(existingJSON, fileName: "2026-07-20_BACKUP1.json")

        let incomingSchedule = makeSchedule(
            id: "CA26-05-BACKUP1",
            pairing: "BACKUP1",
            depUTC: "2026-07-20T13:00:00Z",
            arrUTC: "2026-07-20T19:00:00Z"
        )
        let vm = makeImportViewModel(
            schedule: incomingSchedule,
            json: incomingJSON,
            sourceFileName: "BACKUP1.pdf"
        )
        setVerifiedIdentity(on: vm)
        vm.crewAccessSchedules = [
            makeSchedule(
                id: "CA26-05-BACKUP1",
                pairing: "BACKUP1",
                depUTC: "2026-07-20T12:00:00Z",
                arrUTC: "2026-07-20T18:00:00Z"
            )
        ]

        let importAccepted = await vm.importCrewAccessPDFData(
            Data([0x25, 0x50, 0x44, 0x46]),
            sourceFileName: "BACKUP1.pdf"
        )
        XCTAssertTrue(importAccepted)
        await vm.confirmPendingImport()

        let allFiles = try FileManager.default.contentsOfDirectory(
            at: crewAccessImportDirectory(),
            includingPropertiesForKeys: nil,
            options: []
        )
        XCTAssertFalse(allFiles.contains { $0.lastPathComponent.contains(".bak-") })
    }

    func test_confirmImport_replacesSameTripIDWithinBidPeriodButPreservesDifferentBidPeriod() async throws {
        try removeCrewAccessImportDirectory()
        defer { try? removeCrewAccessImportDirectory() }

        let previousBPJSON = makeCrewAccessJSON(
            tripId: "B00001",
            tripInformationDate: "01Dec2025",
            startUtc: "2025-12-01T08:00:00Z",
            endUtc: "2025-12-01T10:00:00Z"
        )
        let existingSameBPJSON = makeCrewAccessJSON(
            tripId: "B00001",
            tripInformationDate: "01Jun2026",
            startUtc: "2026-06-01T08:00:00Z",
            endUtc: "2026-06-01T10:00:00Z"
        )
        let incomingJSON = makeCrewAccessJSON(
            tripId: "B00001",
            tripInformationDate: "02Jun2026",
            startUtc: "2026-06-02T08:00:00Z",
            endUtc: "2026-06-02T10:00:00Z"
        )
        try writeCrewAccessJSON(previousBPJSON, fileName: "2025-12-01_B00001.json")
        try writeCrewAccessJSON(existingSameBPJSON, fileName: "2026-06-01_B00001.json")

        let incomingSchedule = makeSchedule(
            id: "CA26-06-B00001",
            pairing: "B00001",
            depUTC: "2026-06-02T08:00:00Z",
            arrUTC: "2026-06-02T10:00:00Z"
        )
        let importService = FixedImportService(draft: CrewAccessImportDraft(
            sourceFileName: "B00001.pdf",
            tripId: "B00001",
            tripDate: "02Jun2026",
            parsedSchedule: incomingSchedule,
            jsonPayload: incomingJSON,
            warnings: [],
            errors: [],
            rawExtractStats: RawExtractStats(pageCount: 1, characterCount: 1, lineCount: 1)
        ))
        let vm = AppViewModel(
            syncService: NoopSyncService(),
            authService: NoopAuthService(),
            cacheService: InMemoryCacheService(),
            notificationService: NoopNotificationService(),
            crewAccessImportService: importService,
            friendScheduleCloudKitService: NoopFriendCloudKitService(),
            gemsVerificationCloudKitService: NoopGEMSVerificationService(),
            deviceScheduleCloudKitService: FakeDeviceScheduleCloudKitService(),
            crewAccessImportCloudKitService: NoopCrewAccessImportCloudKitService(),
            keychainService: EmptyKeychainService()
        )
        setVerifiedIdentity(on: vm)
        vm.crewAccessSchedules = [
            makeSchedule(
                id: "CA25-12-B00001",
                pairing: "B00001",
                depUTC: "2025-12-01T08:00:00Z",
                arrUTC: "2025-12-01T10:00:00Z"
            ),
            makeSchedule(
                id: "CA26-06-B00001",
                pairing: "B00001",
                depUTC: "2026-06-01T08:00:00Z",
                arrUTC: "2026-06-01T10:00:00Z"
            )
        ]

        let importAccepted = await vm.importCrewAccessPDFData(Data([0x25, 0x50, 0x44, 0x46]), sourceFileName: "B00001.pdf")
        XCTAssertTrue(importAccepted)
        await vm.confirmPendingImport()

        let starts = Set(vm.crewAccessSchedules.flatMap { $0.legs.compactMap(\.depUTC) })
        XCTAssertEqual(starts, ["2025-12-01T08:00:00Z", "2026-06-02T08:00:00Z"])
        XCTAssertTrue(crewAccessImportJSONFilesContainTripID("B00001", tripInformationDate: "01Dec2025"))
        XCTAssertTrue(crewAccessImportJSONFilesContainTripID("B00001", tripInformationDate: "02Jun2026"))
        XCTAssertFalse(crewAccessImportJSONFilesContainTripID("B00001", tripInformationDate: "01Jun2026"))
    }

    // MARK: - Helpers

    private func clearCrewAccessOutboxState() {
        for key in crewAccessOutboxStateKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func makeViewModel(
        deviceService: DeviceScheduleCloudKitServicing,
        importCloudKitService: CrewAccessImportCloudKitServicing = NoopCrewAccessImportCloudKitService()
    ) -> AppViewModel {
        AppViewModel(
            syncService: NoopSyncService(),
            authService: NoopAuthService(),
            cacheService: InMemoryCacheService(),
            notificationService: NoopNotificationService(),
            crewAccessImportService: NoopImportService(),
            friendScheduleCloudKitService: NoopFriendCloudKitService(),
            gemsVerificationCloudKitService: NoopGEMSVerificationService(),
            deviceScheduleCloudKitService: deviceService,
            crewAccessImportCloudKitService: importCloudKitService,
            keychainService: EmptyKeychainService()
        )
    }

    private func makeImportViewModel(
        schedule: PayPeriodSchedule,
        json: CrewAccessTripJSON,
        sourceFileName: String
    ) -> AppViewModel {
        let importService = FixedImportService(draft: CrewAccessImportDraft(
            sourceFileName: sourceFileName,
            tripId: json.tripId,
            tripDate: json.tripInformationDate,
            parsedSchedule: schedule,
            jsonPayload: json,
            warnings: [],
            errors: [],
            rawExtractStats: RawExtractStats(pageCount: 1, characterCount: 1, lineCount: 1)
        ))
        return AppViewModel(
            syncService: NoopSyncService(),
            authService: NoopAuthService(),
            cacheService: InMemoryCacheService(),
            notificationService: NoopNotificationService(),
            crewAccessImportService: importService,
            friendScheduleCloudKitService: NoopFriendCloudKitService(),
            gemsVerificationCloudKitService: NoopGEMSVerificationService(),
            deviceScheduleCloudKitService: FakeDeviceScheduleCloudKitService(),
            crewAccessImportCloudKitService: NoopCrewAccessImportCloudKitService(),
            keychainService: EmptyKeychainService()
        )
    }

    private func setVerifiedIdentity(on vm: AppViewModel, gemsID: String = "7793942") {
        let recordName = "_cloudkit_record_\(gemsID)"
        let identity = VerifiedIdentityProfile(
            cloudKitRecordName: recordName,
            name: "Test Pilot",
            gemsID: gemsID,
            domicile: "ANC",
            equipment: "737",
            seat: "CA",
            dateOfHire: "2000-01-01",
            isAdminEligible: false,
            adminPolicyFingerprint: nil,
            verifiedAt: Date()
        )
        vm.verifiedIdentity = identity
        vm.currentCloudKitRecordName = recordName
    }

    private func makeSchedule(id: String) -> PayPeriodSchedule {
        makeSchedule(
            id: id,
            pairing: id,
            depUTC: "2026-03-22T06:00:00Z",
            arrUTC: "2026-03-22T10:00:00Z"
        )
    }

    private func makeSchedule(id: String, pairing: String, depUTC: String, arrUTC: String) -> PayPeriodSchedule {
        let leg = TripLeg(
            id: UUID(),
            payPeriod: "PP26-01",
            pairing: pairing,
            leg: 1,
            flight: "100",
            depAirport: "ANC",
            depLocal: "2026-03-21T22:00:00",
            arrAirport: "SDF",
            arrLocal: "2026-03-22T06:00:00",
            depUTC: depUTC,
            arrUTC: arrUTC,
            status: "SCH",
            block: "4:00",
            layoverStation: nil,
            layoverHotelName: nil,
            layoverDuration: nil,
            stdUTC: nil,
            staUTC: nil,
            atdUTC: nil,
            ataUTC: nil
        )
        return PayPeriodSchedule(
            id: id,
            label: id,
            tripCount: 1,
            legCount: 1,
            openTimeCount: 0,
            updatedAt: Date(),
            legs: [leg],
            openTimeTrips: []
        )
    }

    private func makeCrewAccessJSON(
        tripId: String,
        tripInformationDate: String,
        startUtc: String,
        endUtc: String
    ) -> CrewAccessTripJSON {
        CrewAccessTripJSON(
            schemaVersion: 1,
            source: "crewaccess-pdf",
            sourceVersion: "test",
            mappingVersion: "test",
            generatedAt: "2026-05-22T00:00:00Z",
            tripId: tripId,
            tripInformationDate: tripInformationDate,
            creditTime: nil,
            tripDays: nil,
            tafb: nil,
            dutyTotals: [],
            hotelDetails: [],
            crew: [],
            items: [
                CrewAccessTripItemJSON(
                    sequence: 1,
                    depAirport: "ANC",
                    arrAirport: "SDF",
                    deadhead: false,
                    flight: "100",
                    startUtc: startUtc,
                    endUtc: endUtc,
                    startLocalDisplay: "2026-06-01 00:00",
                    endLocalDisplay: "2026-06-01 02:00",
                    originTz: "America/Anchorage",
                    destinationTz: "America/Kentucky/Louisville",
                    timeDerivation: "test",
                    aircraft: "747",
                    block: "2:00",
                    stdUtc: startUtc,
                    staUtc: endUtc,
                    atdUtc: nil,
                    ataUtc: nil,
                    tailNumber: nil
                )
            ]
        )
    }

    private func writeCrewAccessJSON(_ payload: CrewAccessTripJSON, fileName: String? = nil) throws {
        let dir = try crewAccessImportDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(fileName ?? "2026-06-01_\(payload.tripId).json")
        let data = try JSONEncoder().encode(payload)
        try data.write(to: url, options: .atomic)
    }

    private func repositoryRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func crewAccessImportDirectory() throws -> URL {
        let documents = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        return documents.appendingPathComponent("CrewAccessImports", isDirectory: true)
    }

    private func crewAccessImportJSONFiles() -> [URL] {
        guard let dir = try? crewAccessImportDirectory(),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }
        return urls.filter { $0.pathExtension.lowercased() == "json" }
    }

    private func crewAccessImportJSONFilesContainTripID(
        _ tripID: String,
        tripInformationDate: String? = nil
    ) -> Bool {
        crewAccessImportJSONFiles().contains { url in
            guard let data = try? Data(contentsOf: url),
                  let payload = try? JSONDecoder().decode(CrewAccessTripJSON.self, from: data)
            else {
                return false
            }
            let tripMatches = payload.tripId.caseInsensitiveCompare(tripID) == .orderedSame
            let dateMatches = tripInformationDate.map { payload.tripInformationDate == $0 } ?? true
            return tripMatches && dateMatches
        }
    }

    private func removeCrewAccessImportDirectory() throws {
        let dir = try crewAccessImportDirectory()
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }
}

// MARK: - Fake DeviceScheduleCloudKitService

private actor FakeDeviceScheduleCloudKitService: DeviceScheduleCloudKitServicing {
    private(set) var uploadCallCount = 0
    private(set) var fetchCallCount = 0
    private(set) var lastUploadedSchedules: [PayPeriodSchedule]?
    private var snapshot: DeviceScheduleSnapshot?
    private var shouldFailFetch = false

    func setSnapshot(_ s: DeviceScheduleSnapshot) { snapshot = s }
    func setShouldFailFetch(_ value: Bool) { shouldFailFetch = value }

    func uploadDeviceSchedule(
        gemsID: String,
        cloudKitRecordName: String,
        schedules: [PayPeriodSchedule],
        deviceID: String,
        source: DeviceScheduleSyncSource
    ) async throws {
        uploadCallCount += 1
        lastUploadedSchedules = schedules
    }

    func fetchDeviceSchedule(gemsID: String) async throws -> DeviceScheduleSnapshot? {
        fetchCallCount += 1
        if shouldFailFetch {
            throw TestSyncFailure.expected
        }
        return snapshot
    }
}

private enum TestSyncFailure: Error {
    case expected
}

// MARK: - Noop service stubs

private struct NoopSyncService: TripBoardSyncServiceProtocol {
    func sync(cookies: [HTTPCookie]) async throws -> [PayPeriodSchedule] { [] }
}

private struct NoopAuthService: TripBoardAuthServiceProtocol {
    func loadPersistedCookies() -> [HTTPCookie] { [] }
    func persistCookies(_ cookies: [HTTPCookie]) throws {}
    func clearPersistedCookies() throws {}
    func isAuthenticated(url: URL?, cookies: [HTTPCookie]) -> Bool { false }
    @MainActor func currentWebKitCookies() async -> [HTTPCookie] { [] }
    @MainActor func clearWebKitCookies() async {}
}

private final class InMemoryCacheService: ScheduleCacheServiceProtocol {
    private var stored: ScheduleCacheSnapshotV2?
    func load() -> ScheduleCacheSnapshotV2? { stored }
    func save(_ snapshot: ScheduleCacheSnapshotV2) throws { stored = snapshot }
    func clear() { stored = nil }
}

private struct NoopNotificationService: NextReportNotificationServiceProtocol {
    func authorizationStatus() async -> UNAuthorizationStatus { .notDetermined }
    func requestAuthorization() async throws -> Bool { false }
    func reschedule(
        schedules: [PayPeriodSchedule],
        notify48h: Bool,
        notify24h: Bool,
        notify12h: Bool
    ) async -> NotificationRescheduleResult {
        NotificationRescheduleResult(requested: 0, scheduled: 0, failed: 0)
    }
}

private struct NoopImportService: CrewAccessPDFImportServiceProtocol {
    func analyzeTrip(pdfData: Data, sourceFileName: String?) -> CrewAccessImportDraft {
        CrewAccessImportDraft(
            sourceFileName: nil,
            tripId: "",
            tripDate: "",
            parsedSchedule: nil,
            jsonPayload: nil,
            warnings: [],
            errors: [],
            rawExtractStats: RawExtractStats(pageCount: 0, characterCount: 0, lineCount: 0)
        )
    }
}

private struct FixedImportService: CrewAccessPDFImportServiceProtocol {
    let draft: CrewAccessImportDraft

    func analyzeTrip(pdfData: Data, sourceFileName: String?) -> CrewAccessImportDraft {
        draft
    }
}

private struct NoopFriendCloudKitService: FriendScheduleCloudKitServicing {
    func uploadSchedule(gemsID: String, cloudKitRecordName: String, schedules: [PayPeriodSchedule]) async throws {}
    func uploadScheduleSnapshot(gemsID: String, ownerDisplayName: String, crewAccessTrips: [CrewAccessTripJSON]) async throws {}
    func requestFriend(myGEMSID: String, friendGEMSID: String, friendResetAt: Date?) async throws -> FriendScheduleCloudKitLink {
        FriendScheduleCloudKitLink(friendGEMSID: friendGEMSID, isAccepted: false, linkedAt: nil, requestedAt: nil)
    }
    func cancelFriendRequest(myGEMSID: String, friendGEMSID: String) async throws {}
    func deleteSharedScheduleData(gemsID: String) async throws {}
    func deleteFriendSharingData(gemsID: String) async throws {}
    func refreshConnections(myGEMSID: String, connections: [FriendConnection], friendResetAt: Date?) async throws -> FriendConnectionRefreshResult { FriendConnectionRefreshResult(connections: connections) }
}

private struct NoopGEMSVerificationService: GEMSVerificationCloudKitServicing {
    func uploadVerificationRecords(
        _ records: [GEMSVerificationImportRecord],
        progress: (@MainActor @Sendable (Int, Int) -> Void)?
    ) async throws -> Int { 0 }
    func verify(gemsID: String, dateOfBirth: String) async throws -> GEMSVerificationResult? { nil }
    func recordVerifiedUser(gemsID: String) async throws {}
    func fetchVerifiedUsers() async throws -> [VerifiedAppUser] { [] }
}

private struct NoopCrewAccessImportCloudKitService: CrewAccessImportCloudKitServicing {
    func uploadImportFile(
        gemsID: String,
        fileName: String,
        jsonData: Data,
        tripInformationDate: String?,
        firstDepartureUTC: String?
    ) async throws {}

    func fetchImportFiles(gemsID: String) async throws -> [CrewAccessImportCloudKitRecord] { [] }

    func tombstoneImportFile(gemsID: String, fileName: String) async throws {}
}

private struct FailingCrewAccessImportCloudKitService: CrewAccessImportCloudKitServicing {
    func uploadImportFile(
        gemsID: String,
        fileName: String,
        jsonData: Data,
        tripInformationDate: String?,
        firstDepartureUTC: String?
    ) async throws {}

    func fetchImportFiles(gemsID: String) async throws -> [CrewAccessImportCloudKitRecord] {
        throw TestSyncFailure.expected
    }

    func tombstoneImportFile(gemsID: String, fileName: String) async throws {}
}

private final class EmptyKeychainService: KeychainServiceProtocol {
    func save(data: Data, account: String) throws {}
    func load(account: String) throws -> Data? { nil }
    func delete(account: String) throws {}
}

private actor CapturingCrewAccessImportCloudKitService: CrewAccessImportCloudKitServicing {
    private(set) var uploadedFileNames: [String] = []

    func uploadImportFile(
        gemsID: String,
        fileName: String,
        jsonData: Data,
        tripInformationDate: String?,
        firstDepartureUTC: String?
    ) async throws {
        uploadedFileNames.append(fileName)
    }

    func fetchImportFiles(gemsID: String) async throws -> [CrewAccessImportCloudKitRecord] {
        []
    }

    func tombstoneImportFile(gemsID: String, fileName: String) async throws {}
}

private actor StatefulCrewAccessImportCloudKitService: CrewAccessImportCloudKitServicing {
    private var records: [CrewAccessImportCloudKitRecord]
    private(set) var uploadedFileNames: [String] = []
    private(set) var tombstonedFileNames: [String] = []

    init(records: [CrewAccessImportCloudKitRecord]) {
        self.records = records
    }

    func uploadImportFile(
        gemsID: String,
        fileName: String,
        jsonData: Data,
        tripInformationDate: String?,
        firstDepartureUTC: String?
    ) async throws {
        uploadedFileNames.append(fileName)
    }

    func fetchImportFiles(gemsID: String) async throws -> [CrewAccessImportCloudKitRecord] {
        records
    }

    func tombstoneImportFile(gemsID: String, fileName: String) async throws {
        tombstonedFileNames.append(fileName)
    }
}
