import CloudKit
import Foundation

// MARK: - Record model

struct CrewAccessImportCloudKitRecord: Sendable {
    let fileName: String
    let jsonData: Data
    let tripInformationDate: String?
    let firstDepartureUTC: String?
    let updatedAt: Date
    let deletedAt: Date?
}

// MARK: - Database protocol

protocol CrewAccessImportCloudKitDatabase {
    func record(for recordID: CKRecord.ID) async throws -> CKRecord
    func save(_ record: CKRecord) async throws -> CKRecord
    func records(matching query: CKQuery) async throws -> [CKRecord]
}

extension CKDatabase: CrewAccessImportCloudKitDatabase {}

// MARK: - Service protocol

protocol CrewAccessImportCloudKitServicing: Sendable {
    func uploadImportFile(
        gemsID: String,
        fileName: String,
        jsonData: Data,
        tripInformationDate: String?,
        firstDepartureUTC: String?
    ) async throws

    func fetchImportFiles(gemsID: String) async throws -> [CrewAccessImportCloudKitRecord]

    func tombstoneImportFile(gemsID: String, fileName: String) async throws
}

// MARK: - Implementation

final class CrewAccessImportCloudKitService: CrewAccessImportCloudKitServicing, @unchecked Sendable {
    static let schemaVersion: Int = 1

    private enum RecordType {
        static let importFile = "TDHCrewAccessImportFile"
    }

    private enum Field {
        static let ownerGEMSID = "ownerGEMSID"
        static let fileName = "fileName"
        static let jsonData = "jsonData"
        static let tripInformationDate = "tripInformationDate"
        static let firstDepartureUTC = "firstDepartureUTC"
        static let updatedAt = "updatedAt"
        static let deletedAt = "deletedAt"
        static let schemaVersion = "schemaVersion"
    }

    private let databaseProvider: () -> CrewAccessImportCloudKitDatabase

    init(containerIdentifier: String) {
        self.databaseProvider = {
            CKContainer(identifier: containerIdentifier).publicCloudDatabase
        }
    }

    init(databaseProvider: @escaping () -> CrewAccessImportCloudKitDatabase) {
        self.databaseProvider = databaseProvider
    }

    static func recordName(for gemsID: String, fileName: String) -> String {
        let base = fileName.hasSuffix(".json") ? String(fileName.dropLast(5)) : fileName
        let safe = base.replacingOccurrences(of: "/", with: "-")
        return "tdh_import_\(gemsID)_\(safe)"
    }

    func uploadImportFile(
        gemsID: String,
        fileName: String,
        jsonData: Data,
        tripInformationDate: String?,
        firstDepartureUTC: String?
    ) async throws {
        let database = databaseProvider()
        let normalizedGEMS = GEMSIDNormalizer.normalize(gemsID)
        let recordID = CKRecord.ID(recordName: Self.recordName(for: normalizedGEMS, fileName: fileName))
        let record = (try? await database.record(for: recordID))
            ?? CKRecord(recordType: RecordType.importFile, recordID: recordID)

        record[Field.ownerGEMSID] = normalizedGEMS as CKRecordValue
        record[Field.fileName] = fileName as CKRecordValue
        record[Field.jsonData] = jsonData as CKRecordValue
        if let date = tripInformationDate {
            record[Field.tripInformationDate] = date as CKRecordValue
        }
        if let dep = firstDepartureUTC {
            record[Field.firstDepartureUTC] = dep as CKRecordValue
        }
        record[Field.updatedAt] = Date() as CKRecordValue
        record[Field.deletedAt] = nil
        record[Field.schemaVersion] = Int64(Self.schemaVersion) as CKRecordValue

        _ = try await database.save(record)
    }

    func fetchImportFiles(gemsID: String) async throws -> [CrewAccessImportCloudKitRecord] {
        let database = databaseProvider()
        let normalizedGEMS = GEMSIDNormalizer.normalize(gemsID)
        let predicate = NSPredicate(format: "%K == %@", Field.ownerGEMSID, normalizedGEMS)
        let query = CKQuery(recordType: RecordType.importFile, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: Field.updatedAt, ascending: true)]
        let records = try await database.records(matching: query)
        return records.compactMap { decodeRecord($0) }
    }

    func tombstoneImportFile(gemsID: String, fileName: String) async throws {
        let database = databaseProvider()
        let normalizedGEMS = GEMSIDNormalizer.normalize(gemsID)
        let recordID = CKRecord.ID(recordName: Self.recordName(for: normalizedGEMS, fileName: fileName))
        let record: CKRecord
        do {
            record = try await database.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            return
        }
        record[Field.deletedAt] = Date() as CKRecordValue
        record[Field.updatedAt] = Date() as CKRecordValue
        _ = try await database.save(record)
    }

    // MARK: - Helpers

    private func decodeRecord(_ record: CKRecord) -> CrewAccessImportCloudKitRecord? {
        guard let fileName = record[Field.fileName] as? String,
              let jsonData = record[Field.jsonData] as? Data,
              let updatedAt = record[Field.updatedAt] as? Date
        else { return nil }

        return CrewAccessImportCloudKitRecord(
            fileName: fileName,
            jsonData: jsonData,
            tripInformationDate: record[Field.tripInformationDate] as? String,
            firstDepartureUTC: record[Field.firstDepartureUTC] as? String,
            updatedAt: updatedAt,
            deletedAt: record[Field.deletedAt] as? Date
        )
    }
}
