import CloudKit
import CryptoKit
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
        let syncStateDefaults = try XCTUnwrap(UserDefaults(
            suiteName: "AppViewModelDeviceSyncTests.Import.\(UUID().uuidString)"
        ))
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
            keychainService: EmptyKeychainService(),
            syncStateDefaults: syncStateDefaults
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
        let syncStateDefaults = try XCTUnwrap(UserDefaults(
            suiteName: "AppViewModelDeviceSyncTests.Import.\(UUID().uuidString)"
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
            keychainService: EmptyKeychainService(),
            syncStateDefaults: syncStateDefaults
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

    func test_T5_samePDFAcrossDirectAndQueuedDeliveryProducesOnePreview() async throws {
        let schedule = makeSchedule(
            id: "CA26-06-T50001",
            pairing: "T50001",
            depUTC: "2026-06-02T08:00:00Z",
            arrUTC: "2026-06-02T10:00:00Z"
        )
        let json = makeCrewAccessJSON(
            tripId: "T50001",
            tripInformationDate: "02Jun2026",
            startUtc: "2026-06-02T08:00:00Z",
            endUtc: "2026-06-02T10:00:00Z"
        )
        let suite = "AppViewModelDeviceSyncTests.T5.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let coordinator = ExternalOpenImportCoordinator(dedupTTL: 30)
        let ledger = ImportFingerprintLedger(defaults: defaults)
        let vm = makeImportViewModel(
            schedule: schedule,
            json: json,
            sourceFileName: "T50001.pdf",
            syncStateDefaults: defaults,
            externalOpenCoordinator: coordinator,
            importFingerprintLedger: ledger
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("T5DuplicateDelivery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = Data("%PDF-1.7 synthetic duplicate".utf8)
        let secondURL = directory.appendingPathComponent("inbox-copy.pdf")
        try data.write(to: secondURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000)],
            ofItemAtPath: secondURL.path
        )

        let accepted = await vm.importCrewAccessPDFData(data, sourceFileName: "browser-download.pdf")
        XCTAssertTrue(accepted)
        let previewID = try XCTUnwrap(vm.pendingImport?.id)

        // External-open and App Group handoffs both enter this queued sink. The direct browser
        // delivery above and this queued delivery must therefore consult the same content ledger.
        vm.queueExternalOpenURL(secondURL)
        for _ in 0..<500 {
            await Task.yield()
        }

        XCTAssertEqual(vm.pendingImport?.id, previewID)
        XCTAssertFalse(vm.hasQueuedImport, "a content duplicate is consumed, not parked")

        await vm.discardPendingImport()
        for _ in 0..<200 { await Task.yield() }
        XCTAssertNil(vm.pendingImport, "the duplicate must not reopen after the first preview closes")
    }

    func test_T26_distinctImportImmediatelyAfterConfirmedImportProducesOneNewPreview() async throws {
        let dataA = Data("%PDF synthetic sequential A".utf8)
        let dataB = Data("%PDF synthetic sequential B".utf8)
        let context = try makeSequentialImportContext([
            dataA: makeSequentialDraft(
                tripID: "A26001",
                tripInformationDate: "02Jun2026",
                startUTC: "2026-06-02T08:00:00Z",
                endUTC: "2026-06-02T10:00:00Z"
            ),
            dataB: makeSequentialDraft(
                tripID: "B26001",
                tripInformationDate: "06Jun2026",
                startUTC: "2026-06-06T08:00:00Z",
                endUTC: "2026-06-06T10:00:00Z"
            )
        ])
        defer { cleanupSequentialImportContext(context) }

        let acceptedA = await context.viewModel.importCrewAccessPDFData(dataA, sourceFileName: "A.pdf")
        XCTAssertTrue(acceptedA)
        let previewA = try XCTUnwrap(context.viewModel.pendingImport?.id)
        let confirmedA = await context.viewModel.confirmPendingImport(expectedReplacementIDs: [])
        XCTAssertTrue(confirmedA)
        XCTAssertNil(context.viewModel.pendingImport)
        XCTAssertEqual(context.ledger.suppressionState(for: fingerprint(dataA)), .consumed)

        let acceptedB = await context.viewModel.importCrewAccessPDFData(dataB, sourceFileName: "B.pdf")
        XCTAssertTrue(acceptedB)
        let previewB = try XCTUnwrap(context.viewModel.pendingImport?.id)
        XCTAssertNotEqual(previewB, previewA)
        XCTAssertEqual(context.viewModel.pendingImport?.tripId, "B26001")
        XCTAssertEqual(context.ledger.suppressionState(for: fingerprint(dataB)), .active)

        let duplicateB = await context.viewModel.importCrewAccessPDFData(dataB, sourceFileName: "B-copy.pdf")
        XCTAssertFalse(duplicateB)
        XCTAssertEqual(context.viewModel.pendingImport?.id, previewB)
        await context.viewModel.discardPendingImport()
    }

    func test_T27_threeDistinctImportsTransitionPreviewAndLedgerExactlyOnceInOneSession() async throws {
        let inputs: [(data: Data, fileName: String, tripID: String, date: String, start: String, end: String)] = [
            (Data("%PDF synthetic sequential A".utf8), "A.pdf", "A27001", "02Jun2026", "2026-06-02T08:00:00Z", "2026-06-02T10:00:00Z"),
            (Data("%PDF synthetic sequential B".utf8), "B.pdf", "B27001", "06Jun2026", "2026-06-06T08:00:00Z", "2026-06-06T10:00:00Z"),
            (Data("%PDF synthetic sequential C".utf8), "C.pdf", "C27001", "10Jun2026", "2026-06-10T08:00:00Z", "2026-06-10T10:00:00Z")
        ]
        let drafts = Dictionary(uniqueKeysWithValues: inputs.map { input in
            (
                input.data,
                makeSequentialDraft(
                    tripID: input.tripID,
                    tripInformationDate: input.date,
                    startUTC: input.start,
                    endUTC: input.end
                )
            )
        })
        let context = try makeSequentialImportContext(drafts)
        defer { cleanupSequentialImportContext(context) }
        var previewIDs: Set<UUID> = []

        for input in inputs {
            let accepted = await context.viewModel.importCrewAccessPDFData(
                input.data,
                sourceFileName: input.fileName
            )
            XCTAssertTrue(accepted)
            let previewID = try XCTUnwrap(context.viewModel.pendingImport?.id)
            XCTAssertTrue(previewIDs.insert(previewID).inserted)
            XCTAssertEqual(context.viewModel.pendingImport?.tripId, input.tripID)
            XCTAssertEqual(context.ledger.suppressionState(for: fingerprint(input.data)), .active)

            let duplicate = await context.viewModel.importCrewAccessPDFData(
                input.data,
                sourceFileName: "duplicate-\(input.fileName)"
            )
            XCTAssertFalse(duplicate)
            XCTAssertEqual(context.viewModel.pendingImport?.id, previewID)

            let confirmed = await context.viewModel.confirmPendingImport(expectedReplacementIDs: [])
            XCTAssertTrue(confirmed)
            XCTAssertNil(context.viewModel.pendingImport)
            XCTAssertEqual(context.ledger.suppressionState(for: fingerprint(input.data)), .consumed)
        }

        XCTAssertEqual(previewIDs.count, 3)
        XCTAssertEqual(
            Set(context.viewModel.crewAccessSchedules.flatMap { $0.legs.map(\.pairing) }),
            Set(inputs.map(\.tripID))
        )
    }

    func test_distinctPDFIsParkedFIFOWhilePreviewIsActive() async throws {
        let schedule = makeSchedule(
            id: "CA26-06-Q00001",
            pairing: "Q00001",
            depUTC: "2026-06-02T08:00:00Z",
            arrUTC: "2026-06-02T10:00:00Z"
        )
        let json = makeCrewAccessJSON(
            tripId: "Q00001",
            tripInformationDate: "02Jun2026",
            startUtc: "2026-06-02T08:00:00Z",
            endUtc: "2026-06-02T10:00:00Z"
        )
        let suite = "AppViewModelDeviceSyncTests.Queue.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let vm = makeImportViewModel(
            schedule: schedule,
            json: json,
            sourceFileName: "Q00001.pdf",
            syncStateDefaults: defaults,
            externalOpenCoordinator: ExternalOpenImportCoordinator(dedupTTL: 30),
            importFingerprintLedger: ImportFingerprintLedger(defaults: defaults)
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DistinctImportQueue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstURL = directory.appendingPathComponent("first.pdf")
        let secondURL = directory.appendingPathComponent("second.pdf")
        try Data("%PDF-1.7 first".utf8).write(to: firstURL)
        try Data("%PDF-1.7 second".utf8).write(to: secondURL)

        vm.queueExternalOpenURL(firstURL)
        for _ in 0..<500 {
            if vm.pendingImport != nil { break }
            await Task.yield()
        }
        let firstPreviewID = try XCTUnwrap(vm.pendingImport?.id)

        vm.queueExternalOpenURL(secondURL)
        for _ in 0..<500 {
            if vm.hasQueuedImport { break }
            await Task.yield()
        }
        XCTAssertTrue(vm.hasQueuedImport)
        XCTAssertEqual(vm.pendingImport?.id, firstPreviewID)

        await vm.discardPendingImport()
        for _ in 0..<500 {
            if let id = vm.pendingImport?.id, id != firstPreviewID { break }
            await Task.yield()
        }

        XCTAssertNotNil(vm.pendingImport)
        XCTAssertNotEqual(vm.pendingImport?.id, firstPreviewID)
        await vm.discardPendingImport()
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
        sourceFileName: String,
        syncStateDefaults: UserDefaults? = nil,
        externalOpenCoordinator: ExternalOpenImportCoordinator = .shared,
        importFingerprintLedger: ImportFingerprintLedger? = nil,
        replacementDerivedStateInvalidator: @escaping @Sendable () async throws -> Void = {}
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
        let resolvedSyncStateDefaults = syncStateDefaults ?? UserDefaults(
            suiteName: "AppViewModelDeviceSyncTests.Import.\(UUID().uuidString)"
        )!
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
            keychainService: EmptyKeychainService(),
            syncStateDefaults: resolvedSyncStateDefaults,
            externalOpenCoordinator: externalOpenCoordinator,
            importFingerprintLedger: importFingerprintLedger,
            replacementDerivedStateInvalidator: replacementDerivedStateInvalidator
        )
    }

    private func makeSequentialImportContext(
        _ draftsByData: [Data: CrewAccessImportDraft]
    ) throws -> SequentialImportContext {
        let suiteName = "AppViewModelDeviceSyncTests.Sequential.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let ledger = ImportFingerprintLedger(defaults: defaults)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SequentialCrewAccessImports-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let viewModel = AppViewModel(
            syncService: NoopSyncService(),
            authService: NoopAuthService(),
            cacheService: InMemoryCacheService(),
            notificationService: NoopNotificationService(),
            crewAccessImportService: RoutedImportService(draftsByData: draftsByData),
            friendScheduleCloudKitService: NoopFriendCloudKitService(),
            gemsVerificationCloudKitService: NoopGEMSVerificationService(),
            deviceScheduleCloudKitService: FakeDeviceScheduleCloudKitService(),
            crewAccessImportCloudKitService: NoopCrewAccessImportCloudKitService(),
            keychainService: EmptyKeychainService(),
            syncStateDefaults: defaults,
            externalOpenCoordinator: ExternalOpenImportCoordinator(dedupTTL: 30),
            importFingerprintLedger: ledger,
            replacementDerivedStateInvalidator: {},
            crewAccessImportsDirectory: directory
        )
        setVerifiedIdentity(on: viewModel)
        return SequentialImportContext(
            viewModel: viewModel,
            ledger: ledger,
            defaults: defaults,
            defaultsSuiteName: suiteName,
            importsDirectory: directory
        )
    }

    private func cleanupSequentialImportContext(_ context: SequentialImportContext) {
        try? FileManager.default.removeItem(at: context.importsDirectory)
        context.defaults.removePersistentDomain(forName: context.defaultsSuiteName)
    }

    private func makeSequentialDraft(
        tripID: String,
        tripInformationDate: String,
        startUTC: String,
        endUTC: String
    ) -> CrewAccessImportDraft {
        let schedule = makeSchedule(
            id: "CA26-06-\(tripID)",
            pairing: tripID,
            depUTC: startUTC,
            arrUTC: endUTC
        )
        let json = makeCrewAccessJSON(
            tripId: tripID,
            tripInformationDate: tripInformationDate,
            startUtc: startUTC,
            endUtc: endUTC
        )
        return CrewAccessImportDraft(
            sourceFileName: "\(tripID).pdf",
            tripId: tripID,
            tripDate: tripInformationDate,
            parsedSchedule: schedule,
            jsonPayload: json,
            warnings: [],
            errors: [],
            rawExtractStats: RawExtractStats(pageCount: 1, characterCount: 1, lineCount: 1)
        )
    }

    private func fingerprint(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct SequentialImportContext {
        let viewModel: AppViewModel
        let ledger: ImportFingerprintLedger
        let defaults: UserDefaults
        let defaultsSuiteName: String
        let importsDirectory: URL
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

    // MARK: - Legacy 12h notification migration

    /// The 12h reminder toggle was removed from Settings, but the scheduler kept reading
    /// `notification_12h_enabled`. Because the key was cleared only from `SettingsTabView.onAppear`,
    /// a user who upgraded with 12h enabled and never opened Settings kept receiving T-12h
    /// reminders with no in-app way to stop them.
    ///
    /// Settings is deliberately never involved in any of these tests — that is the whole point.
    func test_legacy12hPreferenceIsMigratedAtStartupWithoutOpeningSettings() {
        let defaults = makeNotificationDefaults()

        // 1. A user upgrading with the legacy reminder enabled, 48h on and 24h off.
        defaults.set(true, forKey: notification12hKey)
        defaults.set(true, forKey: notification48hKey)
        defaults.set(false, forKey: notification24hKey)

        // 2. Model-layer startup. 3. Settings is never opened.
        let vm = makeMinimalViewModel(syncStateDefaults: defaults)

        // 4. Resolved preferences never report the legacy threshold as enabled.
        let prefs = vm.notificationPreferences
        XCTAssertFalse(prefs.notify12h, "legacy 12h must never resolve as enabled")

        // 5. 48h and 24h keep their prior values.
        XCTAssertTrue(prefs.notify48h, "48h preference must be preserved")
        XCTAssertFalse(prefs.notify24h, "24h preference must be preserved")
        XCTAssertTrue(prefs.anyEnabled, "48h alone still means reminders are enabled")

        // 6. The legacy key is gone from storage.
        XCTAssertNil(
            defaults.object(forKey: notification12hKey),
            "startup migration must clear the legacy key"
        )
    }

    /// Even if the legacy key survives or reappears — a restored backup, or an older build still
    /// writing it — the resolver must not turn it back into a scheduled reminder.
    func test_legacy12hKeyReappearingAfterMigrationStillResolvesDisabled() {
        let defaults = makeNotificationDefaults()

        let vm = makeMinimalViewModel(syncStateDefaults: defaults)
        defaults.set(true, forKey: notification12hKey)

        XCTAssertFalse(
            vm.notificationPreferences.notify12h,
            "the resolver must ignore the legacy key, not merely have cleared it once"
        )
    }

    /// 7. An actual reschedule driven by the legacy preference must not request a T-12h threshold.
    func test_rescheduleFromLegacy12hPreferenceRequestsNoTwelveHourThreshold() async {
        let defaults = makeNotificationDefaults()

        defaults.set(true, forKey: notification12hKey)
        defaults.set(true, forKey: notification48hKey)
        defaults.set(false, forKey: notification24hKey)

        let notifications = RecordingNotificationService()
        let vm = makeMinimalViewModel(
            notificationService: notifications,
            syncStateDefaults: defaults
        )

        await vm.updateNotificationPreferencesFromSettings(triggeredByEnablingToggle: false)

        let requests = await notifications.requests
        XCTAssertFalse(requests.isEmpty, "precondition: a reschedule should have been attempted")
        for request in requests {
            XCTAssertFalse(request.notify12h, "no reschedule may request a T-12h reminder")
        }
        XCTAssertTrue(requests.contains { $0.notify48h }, "48h must still be scheduled")
    }

    /// With only the legacy preference set, nothing is enabled any more, so the reschedule must
    /// clear reminders rather than keep the subsystem armed on a preference with no UI.
    func test_legacy12hAloneNoLongerCountsAsAnyNotificationEnabled() async {
        let defaults = makeNotificationDefaults()

        defaults.set(true, forKey: notification12hKey)
        defaults.set(false, forKey: notification48hKey)
        defaults.set(false, forKey: notification24hKey)

        let notifications = RecordingNotificationService()
        let vm = makeMinimalViewModel(
            notificationService: notifications,
            syncStateDefaults: defaults
        )

        XCTAssertFalse(vm.notificationPreferences.anyEnabled)

        await vm.updateNotificationPreferencesFromSettings(triggeredByEnablingToggle: false)

        let requests = await notifications.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.notify48h, false)
        XCTAssertEqual(requests.first?.notify24h, false)
        XCTAssertEqual(requests.first?.notify12h, false)
    }

    private var notification12hKey: String { "notification_12h_enabled" }
    private var notification48hKey: String { "notification_48h_enabled" }
    private var notification24hKey: String { "notification_24h_enabled" }

    private func makeNotificationDefaults() -> UserDefaults {
        let suiteName = "AppViewModelDeviceSyncTests.notifications.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    // MARK: - Leg-history preservation through schedule-wide transforms (INV-012)

    /// Both of these transforms rebuild *every* leg of *every* schedule they touch, not just the
    /// legs they actually change. They used to do it with a hand-written memberwise `TripLeg(...)`
    /// that stopped at `ataUTC`, so each run silently erased Original Scheduled, all four
    /// observation timestamps, the aircraft type and the manually entered registration.
    ///
    /// `backfillMissingUTCInCachedSchedulesIfNeeded()` runs on every launch and persists its result
    /// to the cache, so the loss was durable and repeated.
    func test_scheduleWideTransformsPreserveLegHistoryAndRegistration() throws {
        let vm = makeMinimalViewModel()
        let schedule = PayPeriodSchedule(
            id: "CA26-08-A70393R",
            label: "CA26-08-A70393R",
            tripCount: 1,
            legCount: 1,
            openTimeCount: 0,
            updatedAt: Date(),
            legs: [Self.legWithFullHistory()],
            openTimeTrips: []
        )

        let backfilled = vm.backfillMissingUTC(in: [schedule]).schedules
        try Self.assertHistoryPreserved(in: backfilled, context: "backfillMissingUTC")

        let refreshed = vm.refreshScheduleTimezones([schedule])
        try Self.assertHistoryPreserved(in: refreshed, context: "refreshScheduleTimezones")
    }

    /// The backfill must not invent a Scheduled time. `depUTC` resolves Actual first, so the old
    /// `stdUTC: leg.stdUTC ?? depUTC` turned an Actual departure into a fabricated Scheduled one
    /// for legs whose schedule was never observed (a post-flight-only first import).
    func test_backfillDoesNotSynthesizeScheduledTimesFromActuals() throws {
        let vm = makeMinimalViewModel()
        var actualOnly = Self.legWithFullHistory()
        actualOnly.stdUTC = nil
        actualOnly.staUTC = nil
        actualOnly.originalSTDUTC = nil
        actualOnly.originalSTAUTC = nil
        actualOnly.scheduledDepartureObservedAtUTC = nil
        actualOnly.scheduledArrivalObservedAtUTC = nil

        let schedule = PayPeriodSchedule(
            id: "CA26-08-A70393R",
            label: "CA26-08-A70393R",
            tripCount: 1,
            legCount: 1,
            openTimeCount: 0,
            updatedAt: Date(),
            legs: [actualOnly],
            openTimeTrips: []
        )

        let result = vm.backfillMissingUTC(in: [schedule]).schedules
        let leg = try XCTUnwrap(result.first?.legs.first)

        XCTAssertNil(leg.stdUTC, "an unobserved Scheduled departure must stay unknown")
        XCTAssertNil(leg.staUTC, "an unobserved Scheduled arrival must stay unknown")
        XCTAssertNil(leg.originalSTDUTC)
        XCTAssertEqual(leg.atdUTC, "2026-08-05T23:45:00Z", "actuals are untouched")
        XCTAssertEqual(leg.aircraftRegistration, "N605UP")
    }

    private func makeMinimalViewModel(
        notificationService: NextReportNotificationServiceProtocol = NoopNotificationService(),
        syncStateDefaults: UserDefaults = .standard
    ) -> AppViewModel {
        AppViewModel(
            syncService: NoopSyncService(),
            authService: NoopAuthService(),
            cacheService: InMemoryCacheService(),
            notificationService: notificationService,
            crewAccessImportService: NoopImportService(),
            friendScheduleCloudKitService: NoopFriendCloudKitService(),
            gemsVerificationCloudKitService: NoopGEMSVerificationService(),
            deviceScheduleCloudKitService: FakeDeviceScheduleCloudKitService(),
            crewAccessImportCloudKitService: NoopCrewAccessImportCloudKitService(),
            keychainService: EmptyKeychainService(),
            syncStateDefaults: syncStateDefaults
        )
    }

    private static func assertHistoryPreserved(
        in schedules: [PayPeriodSchedule],
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let leg = try XCTUnwrap(schedules.first?.legs.first, file: file, line: line)
        XCTAssertEqual(leg.originalSTDUTC, "2026-08-05T23:20:00Z", "\(context): originalSTDUTC", file: file, line: line)
        XCTAssertEqual(leg.originalSTAUTC, "2026-08-06T04:30:00Z", "\(context): originalSTAUTC", file: file, line: line)
        XCTAssertEqual(leg.stdUTC, "2026-08-05T23:34:00Z", "\(context): stdUTC", file: file, line: line)
        XCTAssertEqual(leg.staUTC, "2026-08-06T04:36:00Z", "\(context): staUTC", file: file, line: line)
        XCTAssertEqual(leg.atdUTC, "2026-08-05T23:45:00Z", "\(context): atdUTC", file: file, line: line)
        XCTAssertEqual(leg.ataUTC, "2026-08-06T04:43:00Z", "\(context): ataUTC", file: file, line: line)
        XCTAssertEqual(
            leg.scheduledDepartureObservedAtUTC, "2026-08-05T18:42:00Z",
            "\(context): scheduled departure observation", file: file, line: line
        )
        XCTAssertEqual(
            leg.scheduledArrivalObservedAtUTC, "2026-08-05T18:42:00Z",
            "\(context): scheduled arrival observation", file: file, line: line
        )
        XCTAssertEqual(
            leg.actualDepartureObservedAtUTC, "2026-08-09T02:15:00Z",
            "\(context): actual departure observation", file: file, line: line
        )
        XCTAssertEqual(
            leg.actualArrivalObservedAtUTC, "2026-08-09T02:15:00Z",
            "\(context): actual arrival observation", file: file, line: line
        )
        XCTAssertEqual(leg.aircraftType, "B748", "\(context): aircraft type", file: file, line: line)
        XCTAssertEqual(
            leg.aircraftRegistration, "N605UP",
            "\(context): manual registration", file: file, line: line
        )
        XCTAssertEqual(leg.layoverHotelName, "Original Hotel", "\(context): hotel", file: file, line: line)
    }

    private static func legWithFullHistory() -> TripLeg {
        TripLeg(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555") ?? UUID(),
            payPeriod: "CA26-08-A70393R",
            pairing: "A70393R",
            leg: 1,
            flight: "5X059",
            depAirport: "ANC",
            depLocal: "2026-08-05 15:45",
            arrAirport: "ONT",
            arrLocal: "2026-08-05 21:43",
            depUTC: "2026-08-05T23:45:00Z",
            arrUTC: "2026-08-06T04:43:00Z",
            status: "-",
            block: "04:58",
            layoverStation: "ONT",
            layoverHotelName: "Original Hotel",
            layoverDuration: "18:00",
            stdUTC: "2026-08-05T23:34:00Z",
            staUTC: "2026-08-06T04:36:00Z",
            atdUTC: "2026-08-05T23:45:00Z",
            ataUTC: "2026-08-06T04:43:00Z",
            originalSTDUTC: "2026-08-05T23:20:00Z",
            originalSTAUTC: "2026-08-06T04:30:00Z",
            scheduledDepartureObservedAtUTC: "2026-08-05T18:42:00Z",
            scheduledArrivalObservedAtUTC: "2026-08-05T18:42:00Z",
            actualDepartureObservedAtUTC: "2026-08-09T02:15:00Z",
            actualArrivalObservedAtUTC: "2026-08-09T02:15:00Z",
            aircraftType: "B748",
            aircraftRegistration: "N605UP"
        )
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

/// Authorized notification service that records every reschedule request, so a test can assert on
/// the thresholds the view model actually asked for.
private actor RecordingNotificationService: NextReportNotificationServiceProtocol {
    struct Request: Sendable {
        let notify48h: Bool
        let notify24h: Bool
        let notify12h: Bool
    }

    private(set) var requests: [Request] = []

    func authorizationStatus() async -> UNAuthorizationStatus { .authorized }
    func requestAuthorization() async throws -> Bool { true }
    func invalidateNextReportNotifications() async {}

    func reschedule(
        schedules: [PayPeriodSchedule],
        notify48h: Bool,
        notify24h: Bool,
        notify12h: Bool
    ) async -> NotificationRescheduleResult {
        requests.append(Request(notify48h: notify48h, notify24h: notify24h, notify12h: notify12h))
        return NotificationRescheduleResult(requested: 0, scheduled: 0, failed: 0)
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

private struct RoutedImportService: CrewAccessPDFImportServiceProtocol {
    let draftsByData: [Data: CrewAccessImportDraft]

    func analyzeTrip(pdfData: Data, sourceFileName: String?) -> CrewAccessImportDraft {
        guard let draft = draftsByData[pdfData] else {
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
                    remediation: "Add the payload to the routed test fixture."
                )],
                rawExtractStats: RawExtractStats(pageCount: 0, characterCount: 0, lineCount: 0)
            )
        }
        return draft
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
