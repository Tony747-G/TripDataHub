import CloudKit
import Foundation

// MARK: - Database protocol (injectable for testing)

protocol DeviceScheduleCloudKitDatabase {
    func record(for recordID: CKRecord.ID) async throws -> CKRecord
    func save(_ record: CKRecord) async throws -> CKRecord
}

extension CKDatabase: DeviceScheduleCloudKitDatabase {}

// MARK: - Service protocol

protocol DeviceScheduleCloudKitServicing: Sendable {
    func uploadDeviceSchedule(
        gemsID: String,
        cloudKitRecordName: String,
        schedules: [PayPeriodSchedule],
        deviceID: String,
        source: DeviceScheduleSyncSource
    ) async throws

    func fetchDeviceSchedule(
        gemsID: String
    ) async throws -> DeviceScheduleSnapshot?
}

// MARK: - Implementation

final class DeviceScheduleCloudKitService: DeviceScheduleCloudKitServicing, @unchecked Sendable {
    static let schemaVersion: Int = 1

    private enum RecordType {
        static let deviceScheduleSnapshot = "TDHDeviceScheduleSnapshot"
    }

    private enum Field {
        static let ownerGEMSID = "ownerGEMSID"
        static let ownerRecordName = "ownerRecordName"
        static let schedulesData = "schedulesData"
        static let schemaVersion = "schemaVersion"
        static let updatedAt = "updatedAt"
        static let deviceID = "deviceID"
        static let source = "source"
    }

    /// Number of save attempts when another device writes the same record between
    /// our fetch and our save.
    static let conflictRetryLimit = 3

    private let containerIdentifier: String
    private let databaseProvider: () -> DeviceScheduleCloudKitDatabase

    init(containerIdentifier: String) {
        self.containerIdentifier = containerIdentifier
        self.databaseProvider = {
            CKContainer(identifier: containerIdentifier).publicCloudDatabase
        }
    }

    init(databaseProvider: @escaping () -> DeviceScheduleCloudKitDatabase) {
        self.containerIdentifier = "test"
        self.databaseProvider = databaseProvider
    }

    /// Writes this device's whole-Timeline snapshot.
    ///
    /// This record is **intentionally last-writer-wins and is NOT merged.** The payload is
    /// a snapshot rebuilt from this device's `CrewAccessImports` files, and those files are
    /// the authoritative, per-trip, tombstoned sync layer (`CrewAccessImportCloudKitService`).
    /// The snapshot exists only as a fallback for installs that cannot rebuild a Timeline
    /// from files. Retrying on `.serverRecordChanged` therefore replaces another device's
    /// snapshot with an equally valid one — it refreshes the change tag, it does not
    /// resolve a data conflict. Do not add per-trip state here that only lives in this
    /// record; it would be silently lost on a concurrent write.
    func uploadDeviceSchedule(
        gemsID: String,
        cloudKitRecordName: String,
        schedules: [PayPeriodSchedule],
        deviceID: String,
        source: DeviceScheduleSyncSource
    ) async throws {
        let database = databaseProvider()
        let normalizedGEMSID = GEMSIDNormalizer.normalize(gemsID)
        let recordID = CKRecord.ID(recordName: Self.recordName(for: normalizedGEMSID))
        let data = try JSONEncoder().encode(schedules)
        let updatedAt = Date()
        var lastConflict: Error?

        for _ in 0..<Self.conflictRetryLimit {
            let record: CKRecord
            do {
                record = try await database.record(for: recordID)
            } catch let error as CKError where error.code == .unknownItem {
                record = CKRecord(recordType: RecordType.deviceScheduleSnapshot, recordID: recordID)
            }
            record[Field.ownerGEMSID] = normalizedGEMSID as CKRecordValue
            record[Field.ownerRecordName] = cloudKitRecordName as CKRecordValue
            record[Field.schedulesData] = data as CKRecordValue
            record[Field.schemaVersion] = Int64(Self.schemaVersion) as CKRecordValue
            record[Field.updatedAt] = updatedAt as CKRecordValue
            record[Field.deviceID] = deviceID as CKRecordValue
            record[Field.source] = source.rawValue as CKRecordValue
            do {
                _ = try await database.save(record)
                return
            } catch let error as CKError where error.code == .serverRecordChanged {
                // Re-fetch to pick up the current change tag, then write the same payload.
                lastConflict = error
            }
        }
        throw lastConflict ?? CKError(.serverRecordChanged)
    }

    func fetchDeviceSchedule(gemsID: String) async throws -> DeviceScheduleSnapshot? {
        let database = databaseProvider()
        let normalizedGEMSID = GEMSIDNormalizer.normalize(gemsID)
        let recordID = CKRecord.ID(recordName: Self.recordName(for: normalizedGEMSID))
        let record: CKRecord
        do {
            record = try await database.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
        return try decodeSnapshot(from: record)
    }

    // MARK: - Helpers

    static func recordName(for normalizedGEMSID: String) -> String {
        "tdh_device_schedule_\(normalizedGEMSID)"
    }

    private func decodeSnapshot(from record: CKRecord) throws -> DeviceScheduleSnapshot {
        guard let ownerGEMSID = record[Field.ownerGEMSID] as? String,
              let ownerRecordName = record[Field.ownerRecordName] as? String,
              let data = record[Field.schedulesData] as? Data,
              let clientUpdatedAt = record[Field.updatedAt] as? Date
        else {
            throw DeviceScheduleDecodeError.missingRequiredField
        }
        let updatedAt = record.modificationDate ?? clientUpdatedAt
        let schedules = try JSONDecoder().decode([PayPeriodSchedule].self, from: data)
        let schemaVersion = (record[Field.schemaVersion] as? Int64).map(Int.init) ?? 1
        let deviceID = record[Field.deviceID] as? String ?? ""
        let sourceRaw = record[Field.source] as? String ?? ""
        let source = DeviceScheduleSyncSource(rawValue: sourceRaw) ?? .unknown
        return DeviceScheduleSnapshot(
            ownerGEMSID: ownerGEMSID,
            ownerRecordName: ownerRecordName,
            schedules: schedules,
            schemaVersion: schemaVersion,
            updatedAt: updatedAt,
            deviceID: deviceID,
            source: source
        )
    }
}

enum DeviceScheduleDecodeError: Error {
    case missingRequiredField
}

// MARK: - Manual Event Sync

protocol ManualEventCloudKitServicing: Sendable {
    func uploadManualEvents(
        gemsID: String,
        cloudKitRecordName: String,
        snapshot: ManualEventStoreSnapshot,
        deviceID: String,
        source: DeviceScheduleSyncSource
    ) async throws

    func fetchManualEvents(gemsID: String) async throws -> ManualEventCloudKitSnapshot?
}

final class ManualEventCloudKitService: ManualEventCloudKitServicing, @unchecked Sendable {
    static let schemaVersion: Int = 1

    private enum RecordType {
        static let manualEventSnapshot = "TDHManualEventSnapshot"
    }

    private enum Field {
        static let ownerGEMSID = "ownerGEMSID"
        static let ownerRecordName = "ownerRecordName"
        static let manualEventsData = "manualEventsData"
        static let schemaVersion = "schemaVersion"
        static let updatedAt = "updatedAt"
        static let deviceID = "deviceID"
        static let source = "source"
    }

    private let containerIdentifier: String
    private let databaseProvider: () -> DeviceScheduleCloudKitDatabase

    init(containerIdentifier: String) {
        self.containerIdentifier = containerIdentifier
        self.databaseProvider = {
            CKContainer(identifier: containerIdentifier).publicCloudDatabase
        }
    }

    init(databaseProvider: @escaping () -> DeviceScheduleCloudKitDatabase) {
        self.containerIdentifier = "test"
        self.databaseProvider = databaseProvider
    }

    /// Writes the manual-event snapshot.
    ///
    /// Unlike `uploadDeviceSchedule`, this **is** real conflict resolution: the server
    /// snapshot is decoded and merged into the payload with `mergeManualEventSnapshots`
    /// (per-ID last-writer-wins plus tombstones) on every attempt, so a concurrent write
    /// from another device is preserved rather than overwritten. The merge is idempotent,
    /// so accumulating it across retries is safe.
    func uploadManualEvents(
        gemsID: String,
        cloudKitRecordName: String,
        snapshot: ManualEventStoreSnapshot,
        deviceID: String,
        source: DeviceScheduleSyncSource
    ) async throws {
        let database = databaseProvider()
        let normalizedGEMSID = GEMSIDNormalizer.normalize(gemsID)
        let recordID = CKRecord.ID(recordName: Self.recordName(for: normalizedGEMSID))
        let updatedAt = Date()
        var snapshotToSave = snapshot
        var lastConflict: Error?

        for _ in 0..<DeviceScheduleCloudKitService.conflictRetryLimit {
            let record: CKRecord
            do {
                record = try await database.record(for: recordID)
                if let serverData = record[Field.manualEventsData] as? Data,
                   let serverSnapshot = try? JSONDecoder().decode(ManualEventStoreSnapshot.self, from: serverData) {
                    snapshotToSave = mergeManualEventSnapshots(local: snapshotToSave, remote: serverSnapshot)
                }
            } catch let error as CKError where error.code == .unknownItem {
                record = CKRecord(recordType: RecordType.manualEventSnapshot, recordID: recordID)
            }
            let data = try JSONEncoder().encode(snapshotToSave)
            record[Field.ownerGEMSID] = normalizedGEMSID as CKRecordValue
            record[Field.ownerRecordName] = cloudKitRecordName as CKRecordValue
            record[Field.manualEventsData] = data as CKRecordValue
            record[Field.schemaVersion] = Int64(Self.schemaVersion) as CKRecordValue
            record[Field.updatedAt] = updatedAt as CKRecordValue
            record[Field.deviceID] = deviceID as CKRecordValue
            record[Field.source] = source.rawValue as CKRecordValue
            do {
                _ = try await database.save(record)
                return
            } catch let error as CKError where error.code == .serverRecordChanged {
                // Re-fetch so the next attempt merges the newly written server state.
                lastConflict = error
            }
        }
        throw lastConflict ?? CKError(.serverRecordChanged)
    }

    func fetchManualEvents(gemsID: String) async throws -> ManualEventCloudKitSnapshot? {
        let database = databaseProvider()
        let normalizedGEMSID = GEMSIDNormalizer.normalize(gemsID)
        let recordID = CKRecord.ID(recordName: Self.recordName(for: normalizedGEMSID))
        let record: CKRecord
        do {
            record = try await database.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
        return try decodeSnapshot(from: record)
    }

    static func recordName(for normalizedGEMSID: String) -> String {
        "tdh_manual_events_\(normalizedGEMSID)"
    }

    private func decodeSnapshot(from record: CKRecord) throws -> ManualEventCloudKitSnapshot {
        guard let ownerGEMSID = record[Field.ownerGEMSID] as? String,
              let ownerRecordName = record[Field.ownerRecordName] as? String,
              let data = record[Field.manualEventsData] as? Data,
              let clientUpdatedAt = record[Field.updatedAt] as? Date
        else {
            throw DeviceScheduleDecodeError.missingRequiredField
        }
        let updatedAt = record.modificationDate ?? clientUpdatedAt
        let manualEvents = try JSONDecoder().decode(ManualEventStoreSnapshot.self, from: data)
        let schemaVersion = (record[Field.schemaVersion] as? Int64).map(Int.init) ?? 1
        let deviceID = record[Field.deviceID] as? String ?? ""
        let sourceRaw = record[Field.source] as? String ?? ""
        let source = DeviceScheduleSyncSource(rawValue: sourceRaw) ?? .unknown
        return ManualEventCloudKitSnapshot(
            ownerGEMSID: ownerGEMSID,
            ownerRecordName: ownerRecordName,
            manualEvents: manualEvents,
            schemaVersion: schemaVersion,
            updatedAt: updatedAt,
            deviceID: deviceID,
            source: source
        )
    }
}
