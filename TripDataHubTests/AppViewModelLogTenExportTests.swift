import Foundation
import UserNotifications
import WebKit
import XCTest
@testable import TripDataHub

@MainActor
final class AppViewModelLogTenExportTests: XCTestCase {
    override func setUp() {
        super.setUp()
        clearLogTenDefaults()
    }

    override func tearDown() {
        clearLogTenDefaults()
        super.tearDown()
    }

    func test_logTenExportUsesUTCColumnsAndKeepsFutureFlightsExportable() {
        let viewModel = makeViewModel()
        viewModel.crewAccessSchedules = [
            schedule(id: "CA26-05", legs: [
                leg(
                    flight: "5X62",
                    dep: "SDF",
                    arr: "ANC",
                    stdUTC: "2026-05-08T03:39:00Z",
                    staUTC: "2026-05-08T06:20:00Z"
                )
            ])
        ]

        let output = viewModel.exportCrewAccessFlightsLogTenCSV(nowUTC: date("2026-05-07T00:00:00Z"))
        XCTAssertEqual(csvLines(from: output), [
            "DATE,Flight Number,FROM,TO,STD,STA,ATD,ATA",
            "2026-05-08,5X62,SDF,ANC,03:39,06:20,,"
        ])

        if let output {
            viewModel.markLogTenExportCompleted(output)
        }

        let secondOutput = viewModel.exportCrewAccessFlightsLogTenCSV(nowUTC: date("2026-05-07T00:00:00Z"))
        XCTAssertEqual(csvLines(from: secondOutput), [
            "DATE,Flight Number,FROM,TO,STD,STA,ATD,ATA",
            "2026-05-08,5X62,SDF,ANC,03:39,06:20,,"
        ])
    }

    func test_logTenExportWritesActualTimesForPastFlightsAndSuppressesAfterCompletedExport() {
        let viewModel = makeViewModel()
        viewModel.crewAccessSchedules = [
            schedule(id: "CA26-05", legs: [
                leg(
                    flight: "5X99",
                    dep: "ANC",
                    arr: "SDF",
                    stdUTC: "2026-05-06T14:46:00Z",
                    staUTC: "2026-05-07T00:53:00Z",
                    atdUTC: "2026-05-06T14:50:00Z",
                    ataUTC: "2026-05-07T00:57:00Z"
                )
            ])
        ]

        let output = viewModel.exportCrewAccessFlightsLogTenCSV(nowUTC: date("2026-05-07T12:00:00Z"))
        XCTAssertEqual(csvLines(from: output), [
            "DATE,Flight Number,FROM,TO,STD,STA,ATD,ATA",
            "2026-05-06,5X99,ANC,SDF,14:46,00:53,14:50,00:57"
        ])

        if let output {
            viewModel.markLogTenExportCompleted(output)
        }

        XCTAssertNil(viewModel.exportCrewAccessFlightsLogTenCSV(nowUTC: date("2026-05-07T12:00:00Z")))
        XCTAssertEqual(viewModel.logTenExportMessage, "No new CrewAccess flights to export.")
    }

    func test_deletedPastCrewAccessTripRemainsPendingForLogTenUntilExportCompletes() async {
        let viewModel = makeViewModel()
        viewModel.crewAccessSchedules = [
            schedule(id: "CA26-05", legs: [
                leg(
                    flight: "5X213",
                    dep: "SDF",
                    arr: "CGN",
                    stdUTC: "2026-05-06T04:42:00Z",
                    staUTC: "2026-05-06T18:40:00Z"
                )
            ])
        ]

        await viewModel.deleteCrewAccessTrips(ids: ["CA26-05"])
        XCTAssertTrue(viewModel.crewAccessSchedules.isEmpty)

        let output = viewModel.exportCrewAccessFlightsLogTenCSV(nowUTC: date("2026-05-07T00:00:00Z"))
        XCTAssertEqual(csvLines(from: output), [
            "DATE,Flight Number,FROM,TO,STD,STA,ATD,ATA",
            "2026-05-06,5X213,SDF,CGN,04:42,18:40,,"
        ])

        if let output {
            viewModel.markLogTenExportCompleted(output)
        }

        XCTAssertNil(viewModel.exportCrewAccessFlightsLogTenCSV(nowUTC: date("2026-05-07T00:00:00Z")))
    }

    private func makeViewModel() -> AppViewModel {
        AppViewModel(
            syncService: FakeTripBoardSyncService(),
            authService: FakeTripBoardAuthService(),
            cacheService: FakeScheduleCacheService(),
            notificationService: FakeNextReportNotificationService(),
            crewAccessImportService: FakeCrewAccessPDFImportService(),
            friendScheduleCloudKitService: FakeFriendScheduleCloudKitService(),
            gemsVerificationCloudKitService: FakeGEMSVerificationCloudKitService(),
            tzResolver: FakeIATATimeZoneResolver()
        )
    }

    private func schedule(id: String, legs: [TripLeg]) -> PayPeriodSchedule {
        PayPeriodSchedule(
            id: id,
            label: id,
            tripCount: 1,
            legCount: legs.count,
            openTimeCount: 0,
            updatedAt: date("2026-05-01T00:00:00Z"),
            legs: legs,
            openTimeTrips: []
        )
    }

    private func leg(
        flight: String,
        dep: String,
        arr: String,
        stdUTC: String,
        staUTC: String,
        atdUTC: String? = nil,
        ataUTC: String? = nil
    ) -> TripLeg {
        TripLeg(
            payPeriod: "CA26-05",
            pairing: "A70651",
            leg: 1,
            flight: flight,
            depAirport: dep,
            depLocal: "May 6 0000",
            arrAirport: arr,
            arrLocal: "May 6 0000",
            depUTC: stdUTC,
            arrUTC: staUTC,
            status: "Scheduled",
            block: "0:00",
            stdUTC: stdUTC,
            staUTC: staUTC,
            atdUTC: atdUTC,
            ataUTC: ataUTC
        )
    }

    private func csvLines(from output: LogTenExportOutput?) -> [String] {
        guard let output,
              let text = try? String(contentsOf: output.url, encoding: .utf8) else {
            return []
        }
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private func clearLogTenDefaults() {
        UserDefaults.standard.removeObject(forKey: "logten_export_backlog_v1")
        UserDefaults.standard.removeObject(forKey: "logten_exported_fingerprints_v1")
    }
}

private final class FakeScheduleCacheService: ScheduleCacheServiceProtocol {
    private var snapshot: ScheduleCacheSnapshotV2?

    func load() -> ScheduleCacheSnapshotV2? {
        snapshot
    }

    func save(_ snapshot: ScheduleCacheSnapshotV2) throws {
        self.snapshot = snapshot
    }

    func clear() {
        snapshot = nil
    }
}

private struct FakeTripBoardSyncService: TripBoardSyncServiceProtocol {
    func sync(cookies: [HTTPCookie]) async throws -> [PayPeriodSchedule] {
        []
    }
}

private struct FakeTripBoardAuthService: TripBoardAuthServiceProtocol {
    func loadPersistedCookies() -> [HTTPCookie] { [] }
    func persistCookies(_ cookies: [HTTPCookie]) throws {}
    func clearPersistedCookies() throws {}
    func isAuthenticated(url: URL?, cookies: [HTTPCookie]) -> Bool { false }
    @MainActor func currentWebKitCookies() async -> [HTTPCookie] { [] }
    @MainActor func clearWebKitCookies() async {}
}

private struct FakeNextReportNotificationService: NextReportNotificationServiceProtocol {
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

private struct FakeCrewAccessPDFImportService: CrewAccessPDFImportServiceProtocol {
    func analyzeTrip(pdfData: Data, sourceFileName: String?) -> CrewAccessImportDraft {
        fatalError("Not used in LogTen export tests.")
    }
}

private struct FakeFriendScheduleCloudKitService: FriendScheduleCloudKitServicing {
    func uploadSchedule(gemsID: String, cloudKitRecordName: String, schedules: [PayPeriodSchedule]) async throws {}
    func uploadScheduleSnapshot(gemsID: String, ownerDisplayName: String, crewAccessTrips: [CrewAccessTripJSON]) async throws {}
    func requestFriend(myGEMSID: String, friendGEMSID: String) async throws -> FriendScheduleCloudKitLink {
        FriendScheduleCloudKitLink(friendGEMSID: friendGEMSID, isAccepted: false, linkedAt: nil, requestedAt: nil)
    }
    func cancelFriendRequest(myGEMSID: String, friendGEMSID: String) async throws {}
    func refreshConnections(myGEMSID: String, connections: [FriendConnection]) async throws -> [FriendConnection] {
        connections
    }
}

private struct FakeGEMSVerificationCloudKitService: GEMSVerificationCloudKitServicing {
    func uploadVerificationRecords(
        _ records: [GEMSVerificationImportRecord],
        progress: (@MainActor @Sendable (_ uploaded: Int, _ total: Int) -> Void)?
    ) async throws -> Int {
        records.count
    }
    func verify(gemsID: String, dateOfBirth: String) async throws -> GEMSVerificationResult? { nil }
    func recordVerifiedUser(gemsID: String) async throws {}
    func fetchVerifiedUsers() async throws -> [VerifiedAppUser] { [] }
}

private final class FakeIATATimeZoneResolver: IATATimeZoneResolving, @unchecked Sendable {
    var mappingVersion: String { "test" }
    func resolve(_ iata: String) -> String? { "UTC" }
    func airportName(_ iata: String) -> String? { nil }
    func cityName(_ iata: String) -> String? { nil }
    func setOverride(iata: String, tzID: String?) {}
    func currentOverrides() -> [String: String] { [:] }
}
