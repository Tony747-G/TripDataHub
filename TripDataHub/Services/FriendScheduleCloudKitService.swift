import CloudKit
import Foundation

struct FriendScheduleCloudKitLink: Sendable {
    let friendGEMSID: String
    let isAccepted: Bool
    let linkedAt: Date?
}

protocol FriendScheduleCloudKitServicing: Sendable {
    func uploadSchedule(gemsID: String, cloudKitRecordName: String, schedules: [PayPeriodSchedule]) async throws
    func uploadScheduleSnapshot(gemsID: String, ownerDisplayName: String, schedules: [PayPeriodSchedule]) async throws
    func requestFriend(myGEMSID: String, friendGEMSID: String) async throws -> FriendScheduleCloudKitLink
    func refreshConnections(myGEMSID: String, connections: [FriendConnection]) async throws -> [FriendConnection]
}

protocol FriendScheduleCloudKitDatabase {
    func record(for recordID: CKRecord.ID) async throws -> CKRecord
    func save(_ record: CKRecord) async throws -> CKRecord
}

extension CKDatabase: FriendScheduleCloudKitDatabase {}

final class FriendScheduleCloudKitService: FriendScheduleCloudKitServicing, @unchecked Sendable {
    private enum RecordType {
        static let sharedSchedule = "TDHSharedSchedule"
        static let friendLink = "TDHFriendLink"
        static let snapshot = "TripScheduleSnapshot"
    }

    private enum SnapshotField {
        static let ownerGEMSID = "ownerGEMSID"
        static let ownerDisplayName = "ownerDisplayName"
        static let scheduleJSON = "scheduleJSON"
        static let schemaVersion = "schemaVersion"
        static let updatedAt = "updatedAt"
    }

    private enum Field {
        static let ownerGEMSID = "ownerGEMSID"
        static let ownerRecordName = "ownerRecordName"
        static let schedulesData = "schedulesData"
        static let updatedAt = "updatedAt"
        static let gemsA = "gemsA"
        static let gemsB = "gemsB"
        static let approvedA = "approvedA"
        static let approvedB = "approvedB"
        static let linkedAt = "linkedAt"
    }

    private let containerIdentifier: String
    private let databaseProvider: () -> FriendScheduleCloudKitDatabase

    init(containerIdentifier: String) {
        self.containerIdentifier = containerIdentifier
        self.databaseProvider = {
            CKContainer(identifier: containerIdentifier).publicCloudDatabase
        }
    }

    init(databaseProvider: @escaping () -> FriendScheduleCloudKitDatabase) {
        self.containerIdentifier = "test"
        self.databaseProvider = databaseProvider
    }

    func uploadSchedule(gemsID: String, cloudKitRecordName: String, schedules: [PayPeriodSchedule]) async throws {
        let database = databaseProvider()
        let recordID = CKRecord.ID(recordName: Self.scheduleRecordName(for: gemsID))
        let record = (try? await database.record(for: recordID))
            ?? CKRecord(recordType: RecordType.sharedSchedule, recordID: recordID)
        let data = try JSONEncoder().encode(schedules)
        record[Field.ownerGEMSID] = normalizedGEMSID(gemsID) as CKRecordValue
        record[Field.ownerRecordName] = cloudKitRecordName as CKRecordValue
        record[Field.schedulesData] = data as CKRecordValue
        record[Field.updatedAt] = Date() as CKRecordValue
        _ = try await database.save(record)
    }

    func uploadScheduleSnapshot(gemsID: String, ownerDisplayName: String, schedules: [PayPeriodSchedule]) async throws {
        let database = databaseProvider()
        let recordID = CKRecord.ID(recordName: Self.snapshotRecordName(for: gemsID))
        let record = (try? await database.record(for: recordID))
            ?? CKRecord(recordType: RecordType.snapshot, recordID: recordID)
        let json = try TripScheduleSnapshotEncoder.json(ownerDisplayName: ownerDisplayName, schedules: schedules)
        record[SnapshotField.ownerGEMSID] = normalizedGEMSID(gemsID) as CKRecordValue
        record[SnapshotField.ownerDisplayName] = ownerDisplayName as CKRecordValue
        record[SnapshotField.scheduleJSON] = json as CKRecordValue
        record[SnapshotField.schemaVersion] = Int64(TripScheduleSnapshotEncoder.schemaVersion) as CKRecordValue
        record[SnapshotField.updatedAt] = Date() as CKRecordValue
        _ = try await database.save(record)
    }

    func requestFriend(myGEMSID: String, friendGEMSID: String) async throws -> FriendScheduleCloudKitLink {
        let my = normalizedGEMSID(myGEMSID)
        let friend = normalizedGEMSID(friendGEMSID)
        let database = databaseProvider()
        let pair = Self.orderedPair(my, friend)
        let recordID = CKRecord.ID(recordName: Self.friendLinkRecordName(first: pair.first, second: pair.second))

        var lastError: Error?
        for attempt in 0..<3 {
            do {
                let record = try await friendLinkRecord(recordID: recordID, database: database)
                applyApproval(
                    to: record,
                    myGEMSID: my,
                    pair: pair
                )

                let saved = try await database.save(record)
                return link(from: saved, myGEMSID: my, friendGEMSID: friend)
            } catch let error as CKError where Self.shouldRetryFriendLinkSave(error) && attempt < 2 {
                lastError = error
                try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 150_000_000)
            } catch {
                throw error
            }
        }

        throw lastError ?? CKError(.serverRecordChanged)
    }

    func refreshConnections(myGEMSID: String, connections: [FriendConnection]) async throws -> [FriendConnection] {
        let my = normalizedGEMSID(myGEMSID)
        let database = databaseProvider()
        var refreshed: [FriendConnection] = []

        for connection in connections {
            let friend = normalizedGEMSID(connection.employeeID)
            let pair = Self.orderedPair(my, friend)
            let recordID = CKRecord.ID(recordName: Self.friendLinkRecordName(first: pair.first, second: pair.second))
            let record: CKRecord?
            do {
                record = try await database.record(for: recordID)
            } catch let error as CKError where error.code == .unknownItem {
                record = nil
            } catch {
                throw error
            }
            let link = record.map { self.link(from: $0, myGEMSID: my, friendGEMSID: friend) }

            var updated = connection
            if link?.isAccepted == true {
                updated.status = .accepted
                updated.linkedAt = link?.linkedAt ?? updated.linkedAt ?? Date()
                updated.sharedSchedules = (try? await fetchSchedule(gemsID: friend, database: database)) ?? updated.sharedSchedules
            } else {
                updated.status = .pending
            }
            refreshed.append(updated)
        }

        return refreshed
    }

    private func fetchSchedule(gemsID: String, database: FriendScheduleCloudKitDatabase) async throws -> [PayPeriodSchedule] {
        let recordID = CKRecord.ID(recordName: Self.scheduleRecordName(for: gemsID))
        let record = try await database.record(for: recordID)
        guard let data = record[Field.schedulesData] as? Data else { return [] }
        return try JSONDecoder().decode([PayPeriodSchedule].self, from: data)
    }

    private func friendLinkRecord(
        recordID: CKRecord.ID,
        database: FriendScheduleCloudKitDatabase
    ) async throws -> CKRecord {
        do {
            return try await database.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            return CKRecord(recordType: RecordType.friendLink, recordID: recordID)
        }
    }

    private func applyApproval(
        to record: CKRecord,
        myGEMSID: String,
        pair: (first: String, second: String)
    ) {
        record[Field.gemsA] = pair.first as CKRecordValue
        record[Field.gemsB] = pair.second as CKRecordValue
        record[approvalField(for: myGEMSID, pair: pair)] = true as CKRecordValue
        record[Field.updatedAt] = Date() as CKRecordValue

        let accepted = boolValue(record[Field.approvedA]) && boolValue(record[Field.approvedB])
        if accepted && record[Field.linkedAt] == nil {
            record[Field.linkedAt] = Date() as CKRecordValue
        }
    }

    private func link(from record: CKRecord, myGEMSID: String, friendGEMSID: String) -> FriendScheduleCloudKitLink {
        let accepted = boolValue(record[Field.approvedA]) && boolValue(record[Field.approvedB])
        return FriendScheduleCloudKitLink(
            friendGEMSID: friendGEMSID,
            isAccepted: accepted,
            linkedAt: record[Field.linkedAt] as? Date
        )
    }

    private func approvalField(
        for gemsID: String,
        pair: (first: String, second: String)
    ) -> String {
        gemsID == pair.first ? Field.approvedA : Field.approvedB
    }

    private func boolValue(_ value: CKRecordValue?) -> Bool {
        (value as? NSNumber)?.boolValue ?? (value as? Bool) ?? false
    }

    private static func shouldRetryFriendLinkSave(_ error: CKError) -> Bool {
        switch error.code {
        case .serverRecordChanged,
             .zoneBusy,
             .serviceUnavailable,
             .requestRateLimited,
             .networkFailure,
             .networkUnavailable:
            return true
        default:
            return false
        }
    }

    private static func orderedPair(_ lhs: String, _ rhs: String) -> (first: String, second: String) {
        lhs < rhs ? (lhs, rhs) : (rhs, lhs)
    }

    private static func scheduleRecordName(for gemsID: String) -> String {
        "tdh_schedule_\(normalizedRecordComponent(gemsID))"
    }

    private static func snapshotRecordName(for gemsID: String) -> String {
        "tdh_snapshot_\(normalizedRecordComponent(gemsID))"
    }

    private static func friendLinkRecordName(first: String, second: String) -> String {
        "tdh_friend_\(normalizedRecordComponent(first))_\(normalizedRecordComponent(second))"
    }

    private static func normalizedRecordComponent(_ raw: String) -> String {
        normalizedGEMSID(raw)
            .filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }
}

private func normalizedGEMSID(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
}
