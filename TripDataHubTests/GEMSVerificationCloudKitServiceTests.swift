import CloudKit
import XCTest
@testable import TripData_Hub

final class GEMSVerificationCloudKitServiceTests: XCTestCase {
    func test_verificationHashMatchesBundledAdminPolicyHash() {
        let hash = GEMSVerificationCloudKitService.verificationHash(
            gemsID: "7793942",
            normalizedDOB: "10/02/1969"
        )

        XCTAssertEqual(hash, "2cddbaa46684d75601717fc3115bb3d0bc6e21963ee5154c8b8afdd571f182f5")
    }

    func test_uploadStoresOnlyGEMSAndDOBHash() async throws {
        let database = GEMSVerificationFakeDatabase()
        let service = GEMSVerificationCloudKitService(databaseProvider: { database })

        let count = try await service.uploadVerificationRecords([
            GEMSVerificationImportRecord(gemsID: " 7793942 ", dateOfBirth: "10/02/1969")
        ])

        XCTAssertEqual(count, 1)
        let record = await database.recordSnapshot(named: "tdh_verify_7793942")
        XCTAssertEqual(record?["gemsID"] as? String, "7793942")
        XCTAssertNotNil(record?["dobHash"] as? String)
        XCTAssertNil(record?["DOB"])
        XCTAssertNil(record?["dateOfBirth"])
        XCTAssertNil(record?["name"])
        XCTAssertNil(record?["dateOfHire"])
    }

    func test_verifyMatchesNormalizedDOB() async throws {
        let database = GEMSVerificationFakeDatabase()
        let service = GEMSVerificationCloudKitService(databaseProvider: { database })
        _ = try await service.uploadVerificationRecords([
            GEMSVerificationImportRecord(gemsID: "7793942", dateOfBirth: "10/02/1969")
        ])

        let verified = try await service.verify(gemsID: "7793942", dateOfBirth: "10-2-69")

        XCTAssertTrue(verified)
    }

    func test_verifyRejectsWrongDOB() async throws {
        let database = GEMSVerificationFakeDatabase()
        let service = GEMSVerificationCloudKitService(databaseProvider: { database })
        _ = try await service.uploadVerificationRecords([
            GEMSVerificationImportRecord(gemsID: "7793942", dateOfBirth: "10/02/1969")
        ])

        let verified = try await service.verify(gemsID: "7793942", dateOfBirth: "10/03/1969")

        XCTAssertFalse(verified)
    }

    func test_uploadAcceptsCSVRowsWithTrailingEmptyColumns() async throws {
        let database = GEMSVerificationFakeDatabase()
        let service = GEMSVerificationCloudKitService(databaseProvider: { database })

        let count = try await service.uploadVerificationRecords([
            GEMSVerificationImportRecord(gemsID: "557068", dateOfBirth: "9/24/64")
        ])

        let snapshot = await database.recordSnapshot(named: "tdh_verify_557068")
        XCTAssertEqual(count, 1)
        XCTAssertNotNil(snapshot)
    }
}

private actor GEMSVerificationFakeDatabase: GEMSVerificationCloudKitDatabase {
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

    func save(_ recordsToSave: [CKRecord]) async throws -> [CKRecord] {
        for record in recordsToSave {
            records[record.recordID.recordName] = record
        }
        return recordsToSave
    }

    func recordSnapshot(named recordName: String) -> CKRecord? {
        records[recordName]
    }
}
