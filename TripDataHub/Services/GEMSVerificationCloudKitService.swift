import CloudKit
import CryptoKit
import Foundation

struct GEMSVerificationImportRecord: Equatable, Sendable {
    let gemsID: String
    let dateOfBirth: String
    let domicile: String

    init(gemsID: String, dateOfBirth: String, domicile: String = DomicileSupport.defaultDomicile) {
        self.gemsID = gemsID
        self.dateOfBirth = dateOfBirth
        self.domicile = DomicileSupport.normalize(domicile)
    }
}

struct GEMSVerificationResult: Equatable, Sendable {
    let gemsID: String
    let domicile: String
}

struct VerifiedAppUser: Identifiable, Hashable, Sendable {
    var id: String { gemsID }
    let gemsID: String
    let verifiedAt: Date
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
    func verify(gemsID: String, dateOfBirth: String) async throws -> GEMSVerificationResult?
    func recordVerifiedUser(gemsID: String) async throws
    func fetchVerifiedUsers() async throws -> [VerifiedAppUser]
}

protocol GEMSVerificationCloudKitDatabase {
    func record(for recordID: CKRecord.ID) async throws -> CKRecord
    func save(_ record: CKRecord) async throws -> CKRecord
    func save(_ records: [CKRecord]) async throws -> [CKRecord]
    func records(matching query: CKQuery) async throws -> [CKRecord]
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
    func records(matching query: CKQuery) async throws -> [CKRecord] {
        try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var records: [CKRecord] = []
            var queryError: Error?

            let operation = CKQueryOperation(query: query)
            // CloudKit Dashboard use only: keep this bounded and sorted for the admin list.
            operation.resultsLimit = 500
            operation.qualityOfService = .userInitiated
            operation.recordMatchedBlock = { _, result in
                switch result {
                case let .success(record):
                    lock.lock()
                    records.append(record)
                    lock.unlock()
                case let .failure(error):
                    lock.lock()
                    queryError = queryError ?? error
                    lock.unlock()
                }
            }
            operation.queryResultBlock = { result in
                switch result {
                case .success:
                    lock.lock()
                    let output = records
                    let error = queryError
                    lock.unlock()
                    if output.isEmpty, let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: output)
                    }
                case let .failure(error):
                    continuation.resume(throwing: error)
                }
            }
            add(operation)
        }
    }

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
        static let verifiedUser = "TDHVerifiedUser"
    }

    private enum Field {
        static let gemsID = "gemsID"
        static let dobHash = "dobHash"
        static let domicile = "domicile"
        static let schemaVersion = "schemaVersion"
        static let updatedAt = "updatedAt"
        static let verifiedAt = "verifiedAt"
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
            cloudRecord[Field.domicile] = DomicileSupport.normalize(record.domicile) as CKRecordValue
            cloudRecord[Field.schemaVersion] = Int64(2) as CKRecordValue
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

    func verify(gemsID: String, dateOfBirth: String) async throws -> GEMSVerificationResult? {
        let normalizedGEMS = GEMSIDNormalizer.normalize(gemsID)
        guard let normalizedDOB = Self.normalizedDOB(dateOfBirth), !normalizedGEMS.isEmpty else {
            return nil
        }

        do {
            let recordID = CKRecord.ID(recordName: Self.recordName(for: normalizedGEMS))
            let record = try await databaseProvider().record(for: recordID)
            guard let storedHash = record[Field.dobHash] as? String else {
                throw GEMSVerificationCloudKitError.invalidRecord
            }
            guard storedHash == Self.verificationHash(gemsID: normalizedGEMS, normalizedDOB: normalizedDOB) else {
                return nil
            }
            return GEMSVerificationResult(
                gemsID: normalizedGEMS,
                domicile: DomicileSupport.normalize(record[Field.domicile] as? String)
            )
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    func recordVerifiedUser(gemsID: String) async throws {
        let normalizedGEMS = GEMSIDNormalizer.normalize(gemsID)
        guard !normalizedGEMS.isEmpty else { return }
        let database = databaseProvider()
        let now = Date()
        let recordID = CKRecord.ID(recordName: Self.verifiedUserRecordName(for: normalizedGEMS))
        let record = (try? await database.record(for: recordID))
            ?? CKRecord(recordType: RecordType.verifiedUser, recordID: recordID)
        record[Field.gemsID] = normalizedGEMS as CKRecordValue
        // Keep the first successful verification date; updatedAt tracks later refreshes.
        if record[Field.verifiedAt] == nil {
            record[Field.verifiedAt] = now as CKRecordValue
        }
        record[Field.schemaVersion] = Int64(1) as CKRecordValue
        record[Field.updatedAt] = now as CKRecordValue
        _ = try await database.save(record)
    }

    func fetchVerifiedUsers() async throws -> [VerifiedAppUser] {
        let query = CKQuery(recordType: RecordType.verifiedUser, predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: Field.updatedAt, ascending: false)]
        let records = try await databaseProvider().records(matching: query)
        return records.compactMap { record in
            guard let gemsID = record[Field.gemsID] as? String else { return nil }
            return VerifiedAppUser(
                gemsID: GEMSIDNormalizer.normalize(gemsID),
                verifiedAt: record[Field.verifiedAt] as? Date ?? record.modificationDate ?? Date.distantPast
            )
        }
        .sorted {
            if $0.verifiedAt == $1.verifiedAt { return $0.gemsID < $1.gemsID }
            return $0.verifiedAt > $1.verifiedAt
        }
    }

    static func recordName(for gemsID: String) -> String {
        "tdh_verify_\(GEMSIDNormalizer.normalize(gemsID))"
    }

    static func verifiedUserRecordName(for gemsID: String) -> String {
        "tdh_verified_user_\(GEMSIDNormalizer.normalize(gemsID))"
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
