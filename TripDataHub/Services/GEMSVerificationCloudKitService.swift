import CloudKit
import CryptoKit
import Foundation

struct GEMSVerificationImportRecord: Equatable, Sendable {
    let gemsID: String
    let dateOfBirth: String
}

enum GEMSVerificationCloudKitError: LocalizedError {
    case invalidRecord
    case uploadTimedOut

    var errorDescription: String? {
        switch self {
        case .invalidRecord:
            return "Verification record is invalid."
        case .uploadTimedOut:
            return "Verification upload timed out. Check CloudKit Dashboard and try again."
        }
    }
}

protocol GEMSVerificationCloudKitServicing: Sendable {
    func uploadVerificationRecords(
        _ records: [GEMSVerificationImportRecord],
        progress: (@MainActor @Sendable (_ uploaded: Int, _ total: Int) -> Void)?
    ) async throws -> Int
    func verify(gemsID: String, dateOfBirth: String) async throws -> Bool
}

protocol GEMSVerificationCloudKitDatabase {
    func record(for recordID: CKRecord.ID) async throws -> CKRecord
    func save(_ record: CKRecord) async throws -> CKRecord
    func save(_ records: [CKRecord]) async throws -> [CKRecord]
}

extension CKDatabase: GEMSVerificationCloudKitDatabase {}

extension GEMSVerificationCloudKitDatabase {
    func save(_ records: [CKRecord]) async throws -> [CKRecord] {
        var saved: [CKRecord] = []
        saved.reserveCapacity(records.count)
        for record in records {
            saved.append(try await save(record))
        }
        return saved
    }
}

extension CKDatabase {
    func save(_ records: [CKRecord]) async throws -> [CKRecord] {
        guard !records.isEmpty else { return [] }
        return try await withCheckedThrowingContinuation { continuation in
            let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
            operation.savePolicy = .allKeys
            operation.qualityOfService = .userInitiated
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: records)
                case let .failure(error):
                    continuation.resume(throwing: error)
                }
            }
            add(operation)
        }
    }
}

final class GEMSVerificationCloudKitService: GEMSVerificationCloudKitServicing, @unchecked Sendable {
    private enum RecordType {
        static let verification = "TDHGEMSVerification"
    }

    private enum Field {
        static let gemsID = "gemsID"
        static let dobHash = "dobHash"
        static let schemaVersion = "schemaVersion"
        static let updatedAt = "updatedAt"
    }

    private static let hashPrefix = "TDH_GEMS_VERIFY_V1"
    private static let hashPepper = "TripDataHub-GEMSVerification-v1"
    private static let uploadBatchSize = 50
    private static let batchTimeoutNanoseconds: UInt64 = 20_000_000_000
    private static let maxBatchSaveAttempts = 3
    private let databaseProvider: () -> GEMSVerificationCloudKitDatabase

    init(containerIdentifier: String) {
        self.databaseProvider = {
            CKContainer(identifier: containerIdentifier).publicCloudDatabase
        }
    }

    init(databaseProvider: @escaping () -> GEMSVerificationCloudKitDatabase) {
        self.databaseProvider = databaseProvider
    }

    func uploadVerificationRecords(
        _ records: [GEMSVerificationImportRecord],
        progress: (@MainActor @Sendable (_ uploaded: Int, _ total: Int) -> Void)? = nil
    ) async throws -> Int {
        let database = databaseProvider()
        var savedCount = 0
        var recordsToSave: [CKRecord] = []
        recordsToSave.reserveCapacity(records.count)

        for record in records {
            let normalizedGEMS = GEMSIDNormalizer.normalize(record.gemsID)
            guard let normalizedDOB = Self.normalizedDOB(record.dateOfBirth), !normalizedGEMS.isEmpty else {
                continue
            }

            let recordID = CKRecord.ID(recordName: Self.recordName(for: normalizedGEMS))
            let cloudRecord = CKRecord(recordType: RecordType.verification, recordID: recordID)
            cloudRecord[Field.gemsID] = normalizedGEMS as CKRecordValue
            cloudRecord[Field.dobHash] = Self.verificationHash(gemsID: normalizedGEMS, normalizedDOB: normalizedDOB) as CKRecordValue
            cloudRecord[Field.schemaVersion] = Int64(1) as CKRecordValue
            cloudRecord[Field.updatedAt] = Date() as CKRecordValue
            recordsToSave.append(cloudRecord)
        }

        for batchStart in stride(from: 0, to: recordsToSave.count, by: Self.uploadBatchSize) {
            let batchEnd = min(batchStart + Self.uploadBatchSize, recordsToSave.count)
            let batch = Array(recordsToSave[batchStart..<batchEnd])
            savedCount += try await Self.saveBatchWithRetry(batch, database: database)
            await progress?(savedCount, recordsToSave.count)
        }
        return savedCount
    }

    func verify(gemsID: String, dateOfBirth: String) async throws -> Bool {
        let normalizedGEMS = GEMSIDNormalizer.normalize(gemsID)
        guard let normalizedDOB = Self.normalizedDOB(dateOfBirth), !normalizedGEMS.isEmpty else {
            return false
        }

        do {
            let recordID = CKRecord.ID(recordName: Self.recordName(for: normalizedGEMS))
            let record = try await databaseProvider().record(for: recordID)
            guard let storedHash = record[Field.dobHash] as? String else {
                throw GEMSVerificationCloudKitError.invalidRecord
            }
            return storedHash == Self.verificationHash(gemsID: normalizedGEMS, normalizedDOB: normalizedDOB)
        } catch let error as CKError where error.code == .unknownItem {
            return false
        }
    }

    static func recordName(for gemsID: String) -> String {
        "tdh_verify_\(GEMSIDNormalizer.normalize(gemsID))"
    }

    static func normalizedDOB(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let separators = CharacterSet(charactersIn: "/-. ")
        let parts = trimmed
            .components(separatedBy: separators)
            .filter { !$0.isEmpty }
        guard parts.count == 3,
              let month = Int(parts[0]),
              let day = Int(parts[1]),
              let yearRaw = Int(parts[2]),
              month >= 1, month <= 12,
              day >= 1, day <= 31
        else {
            return nil
        }

        let fullYear: Int
        if parts[2].count == 2 {
            let currentYearTwoDigits = Calendar.current.component(.year, from: Date()) % 100
            fullYear = yearRaw > currentYearTwoDigits ? 1900 + yearRaw : 2000 + yearRaw
        } else if parts[2].count == 4 {
            fullYear = yearRaw
        } else {
            return nil
        }

        return String(format: "%02d/%02d/%04d", month, day, fullYear)
    }

    static func verificationHash(gemsID: String, normalizedDOB: String) -> String {
        let payload = "\(hashPrefix)|\(GEMSIDNormalizer.normalize(gemsID))|\(normalizedDOB)|\(hashPepper)"
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func verificationHash(gemsID: String, dateOfBirth: String) -> String? {
        guard let normalizedDOB = normalizedDOB(dateOfBirth) else { return nil }
        return verificationHash(gemsID: gemsID, normalizedDOB: normalizedDOB)
    }

    private static func withUploadTimeout<T: Sendable>(
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: batchTimeoutNanoseconds)
                throw GEMSVerificationCloudKitError.uploadTimedOut
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    private static func saveBatchWithRetry(
        _ batch: [CKRecord],
        database: GEMSVerificationCloudKitDatabase
    ) async throws -> Int {
        var lastError: Error?
        for attempt in 1...maxBatchSaveAttempts {
            do {
                return try await withUploadTimeout {
                    try await database.save(batch).count
                }
            } catch {
                lastError = error
                guard attempt < maxBatchSaveAttempts else { break }
                let delay = UInt64(attempt) * 500_000_000
                try? await Task.sleep(nanoseconds: delay)
            }
        }
        throw lastError ?? GEMSVerificationCloudKitError.uploadTimedOut
    }
}
