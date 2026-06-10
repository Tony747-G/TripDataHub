import CloudKit
import Foundation

// MARK: - Database protocol (injectable for testing)

protocol ProfileCloudKitDatabase {
    func record(for recordID: CKRecord.ID) async throws -> CKRecord
    func save(_ record: CKRecord) async throws -> CKRecord
    @discardableResult
    func deleteRecord(withID recordID: CKRecord.ID) async throws -> CKRecord.ID
}

extension CKDatabase: ProfileCloudKitDatabase {}

// MARK: - Service protocol

protocol ProfileCloudKitServicing: Sendable {
    func fetchProfile() async throws -> ProfileSnapshot?
    func saveProfile(_ snapshot: ProfileSnapshot) async throws
    func deleteProfile() async throws
}

// MARK: - Serial write queue

/// Serializes profile record writes so two `saveProfile` calls (e.g. an in-flight
/// settings upload and the account-delete tombstone) never modify the shared
/// `currentUserProfile` CKRecord concurrently. Concurrent saves would race on the
/// record change tag — one would fail with `serverRecordChanged` and, for the
/// tombstone, silently leave the account on CloudKit. Chaining also guarantees the
/// last-enqueued write (the tombstone, enqueued after any pending upload) wins.
private actor ProfileWriteQueue {
    private var tail: Task<Void, Never> = Task {}

    func run(_ work: @escaping @Sendable () async throws -> Void) async throws {
        // Runs atomically on the actor up to the first `await`: capture the current
        // tail and append this write before yielding, so writes execute strictly in
        // enqueue order.
        let previous = tail
        let task = Task<Result<Void, Error>, Never> {
            await previous.value
            do {
                try await work()
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        tail = Task { _ = await task.value }

        switch await task.value {
        case .success:
            return
        case .failure(let error):
            throw error
        }
    }
}

// MARK: - Implementation

final class ProfileCloudKitService: ProfileCloudKitServicing, @unchecked Sendable {

    private let writeQueue = ProfileWriteQueue()

    private enum RecordType {
        static let profile = "Profile"
    }

    private enum Field {
        static let gemsID = "gemsID"
        static let displayName = "displayName"
        static let fleet = "fleet"
        static let base = "base"
        static let position = "position"
        static let avatarAsset = "avatarAsset"
        static let faaMedicalExpiryDate = "faaMedicalExpiryDate"
        static let passportExpiryDate = "passportExpiryDate"
        static let chinaVisaExpiryDate = "chinaVisaExpiryDate"
        static let updatedAt = "updatedAt"
        static let lastSeenAt = "lastSeenAt"
    }

    /// Fixed record ID — one profile per iCloud user.
    /// GEMS ID is NOT used in the record ID to protect privacy.
    static let recordID = CKRecord.ID(recordName: "currentUserProfile")

    private let containerIdentifier: String
    private let databaseProvider: () -> ProfileCloudKitDatabase
    private let avatarTemporaryDirectory: URL

    init(containerIdentifier: String) {
        self.containerIdentifier = containerIdentifier
        self.avatarTemporaryDirectory = FileManager.default.temporaryDirectory
        self.databaseProvider = {
            CKContainer(identifier: containerIdentifier).privateCloudDatabase
        }
    }

    init(
        databaseProvider: @escaping () -> ProfileCloudKitDatabase,
        avatarTemporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.containerIdentifier = "test"
        self.avatarTemporaryDirectory = avatarTemporaryDirectory
        self.databaseProvider = databaseProvider
    }

    // MARK: - Fetch

    func fetchProfile() async throws -> ProfileSnapshot? {
        let database = databaseProvider()
        let record: CKRecord
        do {
            record = try await database.record(for: Self.recordID)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
        return profileSnapshot(from: record)
    }

    // MARK: - Save

    func saveProfile(_ snapshot: ProfileSnapshot) async throws {
        try await writeQueue.run { [self] in
            try await performSave(snapshot)
        }
    }

    private func performSave(_ snapshot: ProfileSnapshot) async throws {
        let database = databaseProvider()
        let record: CKRecord
        do {
            record = try await database.record(for: Self.recordID)
            // Last-write-wins guard: never let an older snapshot overwrite a newer
            // cloud record. This rejects a stale upload that began before — but
            // executed after — a newer write such as the account-delete tombstone,
            // so a deleted account cannot be resurrected even if the writes race.
            if let existingUpdatedAt = record[Field.updatedAt] as? Date,
               existingUpdatedAt > snapshot.updatedAt {
                return
            }
        } catch let error as CKError where error.code == .unknownItem {
            record = CKRecord(recordType: RecordType.profile, recordID: Self.recordID)
        }

        record[Field.gemsID] = snapshot.gemsID as CKRecordValue
        record[Field.displayName] = snapshot.displayName as CKRecordValue
        record[Field.fleet] = snapshot.fleet as CKRecordValue
        record[Field.base] = snapshot.base as CKRecordValue
        record[Field.position] = snapshot.position as CKRecordValue
        record[Field.faaMedicalExpiryDate] = (snapshot.faaMedicalExpiryDate ?? "") as CKRecordValue
        record[Field.passportExpiryDate] = (snapshot.passportExpiryDate ?? "") as CKRecordValue
        record[Field.chinaVisaExpiryDate] = (snapshot.chinaVisaExpiryDate ?? "") as CKRecordValue
        record[Field.updatedAt] = snapshot.updatedAt as CKRecordValue
        if let lastSeen = snapshot.lastSeenAt {
            record[Field.lastSeenAt] = lastSeen as CKRecordValue
        } else {
            record[Field.lastSeenAt] = nil
        }

        // Avatar: write to a temp file, create CKAsset, clean up after save.
        var tempURL: URL?
        if let avatarData = snapshot.avatarImageData, !avatarData.isEmpty {
            let url = avatarTemporaryDirectory
                .appendingPathComponent("profile_avatar_\(UUID().uuidString).jpg")
            do {
                try avatarData.write(to: url)
                record[Field.avatarAsset] = CKAsset(fileURL: url)
                tempURL = url
            } catch {
                record[Field.avatarAsset] = nil
            }
        } else {
            record[Field.avatarAsset] = nil
        }

        defer {
            if let url = tempURL {
                try? FileManager.default.removeItem(at: url)
            }
        }

        _ = try await database.save(record)
    }

    // MARK: - Delete

    func deleteProfile() async throws {
        let database = databaseProvider()
        do {
            try await database.deleteRecord(withID: Self.recordID)
        } catch let error as CKError where error.code == .unknownItem {
            // Already gone — treat as success.
        }
    }

    // MARK: - Mapping

    private func profileSnapshot(from record: CKRecord) -> ProfileSnapshot {
        let avatarData: Data? = (record[Field.avatarAsset] as? CKAsset)
            .flatMap { $0.fileURL }
            .flatMap { try? Data(contentsOf: $0) }

        return ProfileSnapshot(
            gemsID: record[Field.gemsID] as? String ?? "",
            displayName: record[Field.displayName] as? String ?? "",
            fleet: record[Field.fleet] as? String ?? ProfileFleet.fleet757.rawValue,
            base: record[Field.base] as? String ?? OperationalSettings.defaultCrewBase.rawValue,
            position: record[Field.position] as? String ?? ProfilePosition.ca.rawValue,
            avatarImageData: avatarData,
            faaMedicalExpiryDate: normalizedOptionalDate(record[Field.faaMedicalExpiryDate] as? String),
            passportExpiryDate: normalizedOptionalDate(record[Field.passportExpiryDate] as? String),
            chinaVisaExpiryDate: normalizedOptionalDate(record[Field.chinaVisaExpiryDate] as? String),
            updatedAt: record[Field.updatedAt] as? Date ?? Date(timeIntervalSince1970: 0),
            lastSeenAt: record[Field.lastSeenAt] as? Date
        )
    }

    private func normalizedOptionalDate(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
