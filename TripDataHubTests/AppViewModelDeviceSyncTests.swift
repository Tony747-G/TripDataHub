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
            deviceScheduleCloudKitService: deviceService
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
        let leg = TripLeg(
            id: UUID(),
            payPeriod: "PP26-01",
            pairing: id,
            leg: 1,
            flight: "100",
            depAirport: "ANC",
            depLocal: "2026-03-21T22:00:00",
            arrAirport: "SDF",
            arrLocal: "2026-03-22T06:00:00",
            depUTC: "2026-03-22T06:00:00Z",
            arrUTC: "2026-03-22T10:00:00Z",
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
