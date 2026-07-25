import CloudKit
import XCTest
@testable import TripDataHub

final class DeviceScheduleCloudKitServiceTests: XCTestCase {

    // MARK: - recordName

    func test_recordName_sevenDigitGEMSID() {
        XCTAssertEqual(
            DeviceScheduleCloudKitService.recordName(for: "7793942"),
            "tdh_device_schedule_7793942"
        )
    }

    func test_recordName_sixDigitGEMSIDIsLeftPadded() {
        let normalized = GEMSIDNormalizer.normalize("557068")
        XCTAssertEqual(
            DeviceScheduleCloudKitService.recordName(for: normalized),
            "tdh_device_schedule_0557068"
        )
    }

    // MARK: - upload

    func test_uploadStoresOnlyAllowedFields() async throws {
        let database = DeviceScheduleFakeDatabase()
        let service = DeviceScheduleCloudKitService(databaseProvider: { database })

        try await service.uploadDeviceSchedule(
            gemsID: "7793942",
            cloudKitRecordName: "_abc123",
            schedules: [makeSchedule()],
            deviceID: "device-1",
            source: .iphone
        )

        let record = await database.savedRecord(named: "tdh_device_schedule_7793942")
        XCTAssertNotNil(record)
        XCTAssertEqual(record?["ownerGEMSID"] as? String, "7793942")
        XCTAssertEqual(record?["ownerRecordName"] as? String, "_abc123")
        XCTAssertNotNil(record?["schedulesData"] as? Data)
        XCTAssertEqual(record?["deviceID"] as? String, "device-1")
        XCTAssertEqual(record?["source"] as? String, "iphone")
        XCTAssertNotNil(record?["updatedAt"] as? Date)
        XCTAssertNil(record?["DOB"])
        XCTAssertNil(record?["dateOfBirth"])
    }

    func test_uploadEncodesSixDigitGEMSIDAsNormalized() async throws {
        let database = DeviceScheduleFakeDatabase()
        let service = DeviceScheduleCloudKitService(databaseProvider: { database })

        try await service.uploadDeviceSchedule(
            gemsID: "557068",
            cloudKitRecordName: "_rec",
            schedules: [makeSchedule()],
            deviceID: "d1",
            source: .ipad
        )

        let record = await database.savedRecord(named: "tdh_device_schedule_0557068")
        XCTAssertEqual(record?["ownerGEMSID"] as? String, "0557068")
    }

    func test_uploadEncodesSchedulesAsDecodableJSON() async throws {
        let database = DeviceScheduleFakeDatabase()
        let service = DeviceScheduleCloudKitService(databaseProvider: { database })

        let original = [makeSchedule(id: "CA26-01")]
        try await service.uploadDeviceSchedule(
            gemsID: "7793942",
            cloudKitRecordName: "_rec",
            schedules: original,
            deviceID: "d",
            source: .iphone
        )

        let record = await database.savedRecord(named: "tdh_device_schedule_7793942")
        let data = try XCTUnwrap(record?["schedulesData"] as? Data)
        let decoded = try JSONDecoder().decode([PayPeriodSchedule].self, from: data)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].id, "CA26-01")
    }

    func test_uploadRetriesServerRecordChanged() async throws {
        let database = DeviceScheduleFakeDatabase(conflictFirstSave: true)
        let service = DeviceScheduleCloudKitService(databaseProvider: { database })

        try await service.uploadDeviceSchedule(
            gemsID: "7793942",
            cloudKitRecordName: "_rec",
            schedules: [makeSchedule(id: "CA26-retry")],
            deviceID: "device-retry",
            source: .iphone
        )

        let record = await database.savedRecord(named: "tdh_device_schedule_7793942")
        let data = try XCTUnwrap(record?["schedulesData"] as? Data)
        let decoded = try JSONDecoder().decode([PayPeriodSchedule].self, from: data)
        XCTAssertEqual(decoded.first?.id, "CA26-retry")
        let saveCount = await database.saveCount()
        XCTAssertEqual(saveCount, 2)
    }

    /// Exhausting the retries must surface the real CloudKit error rather than reporting
    /// success, so the caller leaves its upload fingerprint unadvanced and tries again later.
    func test_uploadThrowsRealErrorAfterRetryLimit() async throws {
        let database = DeviceScheduleFakeDatabase(alwaysConflict: true)
        let service = DeviceScheduleCloudKitService(databaseProvider: { database })

        do {
            try await service.uploadDeviceSchedule(
                gemsID: "7793942",
                cloudKitRecordName: "_rec",
                schedules: [makeSchedule(id: "CA26-conflict")],
                deviceID: "device-conflict",
                source: .iphone
            )
            XCTFail("Expected the upload to throw once retries are exhausted")
        } catch let error as CKError {
            XCTAssertEqual(error.code, .serverRecordChanged)
        }

        let saveCount = await database.saveCount()
        XCTAssertEqual(saveCount, DeviceScheduleCloudKitService.conflictRetryLimit)
    }

    // MARK: - fetch

    func test_fetchReturnsNilForUnknownGEMSID() async throws {
        let database = DeviceScheduleFakeDatabase()
        let service = DeviceScheduleCloudKitService(databaseProvider: { database })

        let result = try await service.fetchDeviceSchedule(gemsID: "9999999")
        XCTAssertNil(result)
    }

    func test_fetchDecodesUploadedSchedules() async throws {
        let database = DeviceScheduleFakeDatabase()
        let service = DeviceScheduleCloudKitService(databaseProvider: { database })

        try await service.uploadDeviceSchedule(
            gemsID: "7793942",
            cloudKitRecordName: "_rec",
            schedules: [makeSchedule(id: "CA26-02")],
            deviceID: "device-A",
            source: .ipad
        )

        let snapshot = try await service.fetchDeviceSchedule(gemsID: "7793942")
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.ownerGEMSID, "7793942")
        XCTAssertEqual(snapshot?.schedules.count, 1)
        XCTAssertEqual(snapshot?.schedules[0].id, "CA26-02")
        XCTAssertEqual(snapshot?.deviceID, "device-A")
        XCTAssertEqual(snapshot?.source, .ipad)
    }

    func test_fetchReadsNormalizedGEMSID() async throws {
        let database = DeviceScheduleFakeDatabase()
        let service = DeviceScheduleCloudKitService(databaseProvider: { database })

        try await service.uploadDeviceSchedule(
            gemsID: "557068",
            cloudKitRecordName: "_rec",
            schedules: [makeSchedule()],
            deviceID: "d",
            source: .iphone
        )

        let snapshot = try await service.fetchDeviceSchedule(gemsID: "557068")
        XCTAssertNotNil(snapshot)
    }

    func test_schemaVersionIsStoredAndRead() async throws {
        let database = DeviceScheduleFakeDatabase()
        let service = DeviceScheduleCloudKitService(databaseProvider: { database })

        try await service.uploadDeviceSchedule(
            gemsID: "7793942",
            cloudKitRecordName: "_rec",
            schedules: [makeSchedule()],
            deviceID: "d",
            source: .iphone
        )

        let snapshot = try await service.fetchDeviceSchedule(gemsID: "7793942")
        XCTAssertEqual(snapshot?.schemaVersion, DeviceScheduleCloudKitService.schemaVersion)
    }

    // MARK: - Helpers

    private func makeSchedule(id: String = "CA26-01") -> PayPeriodSchedule {
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

// MARK: - Fake database

private actor DeviceScheduleFakeDatabase: DeviceScheduleCloudKitDatabase {
    private var records: [String: CKRecord] = [:]
    private var conflictFirstSave: Bool
    private var alwaysConflict: Bool
    private var totalSaveCount = 0

    init(conflictFirstSave: Bool = false, alwaysConflict: Bool = false) {
        self.conflictFirstSave = conflictFirstSave
        self.alwaysConflict = alwaysConflict
    }

    func record(for recordID: CKRecord.ID) async throws -> CKRecord {
        guard let record = records[recordID.recordName] else {
            throw CKError(.unknownItem)
        }
        return record
    }

    func save(_ record: CKRecord) async throws -> CKRecord {
        totalSaveCount += 1
        if alwaysConflict {
            records[record.recordID.recordName] = record
            throw CKError(.serverRecordChanged)
        }
        if conflictFirstSave {
            conflictFirstSave = false
            records[record.recordID.recordName] = record
            throw CKError(.serverRecordChanged)
        }
        records[record.recordID.recordName] = record
        return record
    }

    func savedRecord(named name: String) -> CKRecord? {
        records[name]
    }

    func saveCount() -> Int {
        totalSaveCount
    }
}
