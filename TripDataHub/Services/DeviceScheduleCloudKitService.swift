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
        let record = (try? await database.record(for: recordID))
            ?? CKRecord(recordType: RecordType.deviceScheduleSnapshot, recordID: recordID)
        let data = try JSONEncoder().encode(schedules)
        record[Field.ownerGEMSID] = normalizedGEMSID as CKRecordValue
        record[Field.ownerRecordName] = cloudKitRecordName as CKRecordValue
        record[Field.schedulesData] = data as CKRecordValue
        record[Field.schemaVersion] = Int64(Self.schemaVersion) as CKRecordValue
        record[Field.updatedAt] = Date() as CKRecordValue
        record[Field.deviceID] = deviceID as CKRecordValue
        record[Field.source] = source.rawValue as CKRecordValue
        _ = try await database.save(record)
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
              let updatedAt = record[Field.updatedAt] as? Date
        else {
            throw DeviceScheduleDecodeError.missingRequiredField
        }
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
