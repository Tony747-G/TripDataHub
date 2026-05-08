import CloudKit
import XCTest
@testable import TripDataHub

final class GEMSVerificationCloudKitServiceTests: XCTestCase {
    func test_gemsIDNormalizerHandlesCurrentSevenDigitRules() {
        XCTAssertEqual(GEMSIDNormalizer.normalize("7793942"), "7793942")
        XCTAssertEqual(GEMSIDNormalizer.normalize(" 557068 "), "0557068")
        XCTAssertEqual(GEMSIDNormalizer.normalize("55706"), "55706")
        XCTAssertEqual(GEMSIDNormalizer.normalize("A57068"), "A57068")
        XCTAssertEqual(GEMSIDNormalizer.normalize("٥٥٧٠٦٨"), "٥٥٧٠٦٨")
    }

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
        XCTAssertEqual(record?["domicile"] as? String, "ANC")
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

        XCTAssertEqual(verified?.gemsID, "7793942")
        XCTAssertEqual(verified?.domicile, "ANC")
    }

    func test_verifyRejectsWrongDOB() async throws {
        let database = GEMSVerificationFakeDatabase()
        let service = GEMSVerificationCloudKitService(databaseProvider: { database })
        _ = try await service.uploadVerificationRecords([
            GEMSVerificationImportRecord(gemsID: "7793942", dateOfBirth: "10/02/1969")
        ])

        let verified = try await service.verify(gemsID: "7793942", dateOfBirth: "10/03/1969")

        XCTAssertNil(verified)
    }

    func test_uploadAcceptsCSVRowsWithTrailingEmptyColumns() async throws {
        let database = GEMSVerificationFakeDatabase()
        let service = GEMSVerificationCloudKitService(databaseProvider: { database })

        let count = try await service.uploadVerificationRecords([
            GEMSVerificationImportRecord(gemsID: "557068", dateOfBirth: "9/24/64")
        ])

        let snapshot = await database.recordSnapshot(named: "tdh_verify_0557068")
        XCTAssertEqual(count, 1)
        XCTAssertNotNil(snapshot)
    }

    func test_sixDigitGEMSIDIsLeftPaddedToSevenDigits() async throws {
        let database = GEMSVerificationFakeDatabase()
        let service = GEMSVerificationCloudKitService(databaseProvider: { database })

        _ = try await service.uploadVerificationRecords([
            GEMSVerificationImportRecord(gemsID: "557068", dateOfBirth: "9/24/64")
        ])

        let unpaddedRecord = await database.recordSnapshot(named: "tdh_verify_557068")
        let paddedRecord = await database.recordSnapshot(named: "tdh_verify_0557068")
        let verifiesUnpaddedInput = try await service.verify(gemsID: "557068", dateOfBirth: "09/24/1964")
        let verifiesPaddedInput = try await service.verify(gemsID: "0557068", dateOfBirth: "09/24/1964")

        XCTAssertNil(unpaddedRecord)
        XCTAssertNotNil(paddedRecord)
        XCTAssertNotNil(verifiesUnpaddedInput)
        XCTAssertNotNil(verifiesPaddedInput)
    }

    func test_uploadAndVerifyPreservesDomicile() async throws {
        let database = GEMSVerificationFakeDatabase()
        let service = GEMSVerificationCloudKitService(databaseProvider: { database })

        _ = try await service.uploadVerificationRecords([
            GEMSVerificationImportRecord(gemsID: "7845209", dateOfBirth: "9/28/69", domicile: "SDFZ")
        ])

        let record = await database.recordSnapshot(named: "tdh_verify_7845209")
        let verified = try await service.verify(gemsID: "7845209", dateOfBirth: "09/28/1969")

        XCTAssertEqual(record?["domicile"] as? String, "SDFZ")
        XCTAssertEqual(verified?.domicile, "SDFZ")
    }

    func test_recordVerifiedUserStoresOnlyGEMSAndTimestamp() async throws {
        let database = GEMSVerificationFakeDatabase()
        let service = GEMSVerificationCloudKitService(databaseProvider: { database })

        try await service.recordVerifiedUser(gemsID: "557068")

        let record = await database.recordSnapshot(named: "tdh_verified_user_0557068")
        XCTAssertEqual(record?["gemsID"] as? String, "0557068")
        XCTAssertNotNil(record?["verifiedAt"] as? Date)
        XCTAssertNil(record?["DOB"])
        XCTAssertNil(record?["dateOfBirth"])
        XCTAssertNil(record?["name"])
    }

    func test_fetchVerifiedUsersReturnsBothUsers() async throws {
        let database = GEMSVerificationFakeDatabase()
        let service = GEMSVerificationCloudKitService(databaseProvider: { database })

        try await service.recordVerifiedUser(gemsID: "557068")
        try await service.recordVerifiedUser(gemsID: "7793942")

        let users = try await service.fetchVerifiedUsers()

        XCTAssertEqual(Set(users.map(\.gemsID)), Set(["0557068", "7793942"]))
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

    func records(matching query: CKQuery) async throws -> [CKRecord] {
        XCTAssertEqual(query.predicate, NSPredicate(value: true))
        return records.values.filter { $0.recordType == query.recordType }
    }

    func recordSnapshot(named recordName: String) -> CKRecord? {
        records[recordName]
    }
}
