import CloudKit
import UserNotifications
import XCTest
@testable import TripDataHub

@MainActor
final class AppViewModelDeviceSyncTests: XCTestCase {

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

    func test_fetchDeviceSchedule_newerRemote_replacesLocalSchedule() async throws {
        let deviceService = FakeDeviceScheduleCloudKitService()
        // Snapshot must be newer than any local schedule (local schedule uses Date() at creation).
        // Use a future timestamp to guarantee remote wins Gate 3 (local-wins protection).
        let futureSnapshot = Date(timeIntervalSinceNow: 60)
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
        vm.crewAccessSchedules = [makeSchedule(id: "CA26-01")]

        await vm.fetchDeviceScheduleIfNeeded(reason: "test")

        XCTAssertEqual(vm.crewAccessSchedules.count, 1)
        XCTAssertEqual(vm.crewAccessSchedules[0].id, "CA26-99")
    }

    func test_fetchDeviceSchedule_olderRemote_keepsLocalSchedule() async throws {
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

        let vm = makeViewModel(deviceService: deviceService)
        setVerifiedIdentity(on: vm)
        vm.crewAccessSchedules = [makeSchedule(id: "CA26-local")]
        let fetchKey = "device_schedule_last_fetch_at_v1"
        UserDefaults.standard.set(newerDate, forKey: fetchKey)
        defer { UserDefaults.standard.removeObject(forKey: fetchKey) }

        await vm.fetchDeviceScheduleIfNeeded(reason: "test")

        XCTAssertEqual(vm.crewAccessSchedules[0].id, "CA26-local")
    }

    func test_fetchDeviceSchedule_sameDevice_keepsLocalSchedule() async throws {
        let deviceService = FakeDeviceScheduleCloudKitService()
        let knownDeviceID = "this-device-id-\(UUID().uuidString)"
        let idKey = "device_id_v1"
        UserDefaults.standard.set(knownDeviceID, forKey: idKey)
        defer { UserDefaults.standard.removeObject(forKey: idKey) }

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
        vm.crewAccessSchedules = [makeSchedule(id: "CA26-local")]

        await vm.fetchDeviceScheduleIfNeeded(reason: "test")

        XCTAssertEqual(vm.crewAccessSchedules[0].id, "CA26-local")
    }

    func test_fetchDeviceSchedule_localNewer_preventsRollback() async throws {
        // Gate 3: if local schedule is newer than the remote snapshot, reject the remote.
        // Scenario: local import succeeded but CloudKit upload failed; remote has older data.
        let deviceService = FakeDeviceScheduleCloudKitService()
        let pastSnapshot = Date(timeIntervalSinceNow: -3600)
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
        // Local schedule has updatedAt: Date() which is newer than pastSnapshot
        vm.crewAccessSchedules = [makeSchedule(id: "CA26-local-new")]

        await vm.fetchDeviceScheduleIfNeeded(reason: "test")

        XCTAssertEqual(vm.crewAccessSchedules[0].id, "CA26-local-new")
    }

    func test_fetchDeviceSchedule_noVerifiedIdentity_skips() async throws {
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
        vm.crewAccessSchedules = [makeSchedule(id: "CA26-local")]

        await vm.fetchDeviceScheduleIfNeeded(reason: "test")

        XCTAssertEqual(vm.crewAccessSchedules[0].id, "CA26-local")
    }

    // MARK: - LogTen backlog survival

    func test_fetchDeviceSchedule_logTenBacklogSurvivesRemoteReplacement() async throws {
        let deviceService = FakeDeviceScheduleCloudKitService()
        let futureSnapshot = Date(timeIntervalSinceNow: 60)
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
        vm.crewAccessSchedules = [makeSchedule(id: "CA26-01")]

        await vm.fetchDeviceScheduleIfNeeded(reason: "test")

        // Remote schedule replaced local
        XCTAssertEqual(vm.crewAccessSchedules[0].id, "CA26-99")
        // LogTen export must not crash after replacement
        _ = vm.exportCrewAccessFlightsLogTenCSV()
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
            crewAccessImportCloudKitService: NoopCrewAccessImportCloudKitService()
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
            crewAccessImportCloudKitService: NoopCrewAccessImportCloudKitService()
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

    func test_confirmImport_removesExistingTripWhenBaseLocalDatesOverlapWithoutUTCIntersection() async throws {
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
            crewAccessImportCloudKitService: NoopCrewAccessImportCloudKitService()
        )
        setVerifiedIdentity(on: vm)

        let existingJSON = makeCrewAccessJSON(
            tripId: "B00001",
            tripInformationDate: "01Jun2026",
            startUtc: "2026-06-01T08:00:00Z",
            endUtc: "2026-06-01T10:00:00Z"
        )
        try writeCrewAccessJSON(existingJSON)
        vm.crewAccessSchedules = [
            makeSchedule(
                id: "CA26-06-B00001",
                pairing: "B00001",
                depUTC: "2026-06-01T08:00:00Z",
                arrUTC: "2026-06-01T10:00:00Z"
            )
        ]

        let sampleURL = repositoryRootURL()
            .appendingPathComponent("web")
            .appendingPathComponent("sample")
            .appendingPathComponent("TripDataHub_App_Review_Sample_A00001.pdf")
        let data = try Data(contentsOf: sampleURL)

        let importAccepted = await vm.importCrewAccessPDFData(data, sourceFileName: sampleURL.lastPathComponent)
        XCTAssertTrue(importAccepted)
        XCTAssertTrue(vm.pendingImportReplacementCandidates.contains { candidate in
            candidate.tripId == "B00001" && candidate.reason == .timeOverlap
        })

        await vm.confirmPendingImport()

        XCTAssertEqual(Set(vm.crewAccessSchedules.flatMap { $0.legs.map(\.pairing) }), ["A00001"])
        XCTAssertTrue(crewAccessImportJSONFiles().allSatisfy { !$0.lastPathComponent.contains("B00001") })
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
            crewAccessImportCloudKitService: NoopCrewAccessImportCloudKitService()
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

    private func makeViewModel(deviceService: DeviceScheduleCloudKitServicing) -> AppViewModel {
        AppViewModel(
            syncService: NoopSyncService(),
            authService: NoopAuthService(),
            cacheService: InMemoryCacheService(),
            notificationService: NoopNotificationService(),
            crewAccessImportService: NoopImportService(),
            friendScheduleCloudKitService: NoopFriendCloudKitService(),
            gemsVerificationCloudKitService: NoopGEMSVerificationService(),
            deviceScheduleCloudKitService: deviceService,
            crewAccessImportCloudKitService: NoopCrewAccessImportCloudKitService()
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
    private(set) var lastUploadedSchedules: [PayPeriodSchedule]?
    private var snapshot: DeviceScheduleSnapshot?

    func setSnapshot(_ s: DeviceScheduleSnapshot) { snapshot = s }

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
        snapshot
    }
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
    func requestFriend(myGEMSID: String, friendGEMSID: String) async throws -> FriendScheduleCloudKitLink {
        FriendScheduleCloudKitLink(friendGEMSID: friendGEMSID, isAccepted: false, linkedAt: nil, requestedAt: nil)
    }
    func cancelFriendRequest(myGEMSID: String, friendGEMSID: String) async throws {}
    func refreshConnections(myGEMSID: String, connections: [FriendConnection]) async throws -> [FriendConnection] { connections }
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
