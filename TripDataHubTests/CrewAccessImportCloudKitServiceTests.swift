import CloudKit
import XCTest
@testable import TripDataHub

final class CrewAccessImportCloudKitServiceTests: XCTestCase {

    func test_uploadClearsExistingTombstoneForReimportedFile() async throws {
        let database = CrewAccessImportFakeDatabase()
        let service = CrewAccessImportCloudKitService(databaseProvider: { database })

        try await service.uploadImportFile(
            gemsID: "557068",
            fileName: "2026-06-01_A00001.json",
            jsonData: Data(#"{"tripId":"A00001"}"#.utf8),
            tripInformationDate: "2026-06-01",
            firstDepartureUTC: "2026-06-01T10:00:00Z"
        )
        try await service.tombstoneImportFile(gemsID: "557068", fileName: "2026-06-01_A00001.json")

        let tombstoned = try await service.fetchImportFiles(gemsID: "557068")
        XCTAssertNotNil(tombstoned.first?.deletedAt)

        try await service.uploadImportFile(
            gemsID: "557068",
            fileName: "2026-06-01_A00001.json",
            jsonData: Data(#"{"tripId":"A00001","reimported":true}"#.utf8),
            tripInformationDate: "2026-06-01",
            firstDepartureUTC: "2026-06-01T10:00:00Z"
        )

        let reimportedRecords = try await service.fetchImportFiles(gemsID: "557068")
        let reimported = try XCTUnwrap(reimportedRecords.first)
        XCTAssertNil(reimported.deletedAt)
        XCTAssertEqual(reimported.fileName, "2026-06-01_A00001.json")
        XCTAssertTrue(String(decoding: reimported.jsonData, as: UTF8.self).contains("reimported"))
    }
}

private actor CrewAccessImportFakeDatabase: CrewAccessImportCloudKitDatabase {
    private var records: [String: CKRecord] = [:]

    func record(for recordID: CKRecord.ID) async throws -> CKRecord {
        guard let record = records[recordID.recordName] else {
            throw CKError(.unknownItem)
        }
        return record
    }

    func save(_ record: CKRecord) async throws -> CKRecord {
        records[record.recordID.recordName] = record
        return record
    }

    func records(matching query: CKQuery) async throws -> [CKRecord] {
        records.values.sorted { lhs, rhs in
            lhs.recordID.recordName < rhs.recordID.recordName
        }
    }
}
