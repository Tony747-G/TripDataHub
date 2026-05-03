import CloudKit
import Foundation

struct FriendScheduleCloudKitLink: Sendable {
    let friendGEMSID: String
    let isAccepted: Bool
    let linkedAt: Date?
}

protocol FriendScheduleCloudKitServicing: Sendable {
    func uploadSchedule(gemsID: String, cloudKitRecordName: String, schedules: [PayPeriodSchedule]) async throws
    func requestFriend(myGEMSID: String, friendGEMSID: String) async throws -> FriendScheduleCloudKitLink
    func refreshConnections(myGEMSID: String, connections: [FriendConnection]) async throws -> [FriendConnection]
}

final class FriendScheduleCloudKitService: FriendScheduleCloudKitServicing, @unchecked Sendable {
    private enum RecordType {
        static let sharedSchedule = "TDHSharedSchedule"
        static let friendLink = "TDHFriendLink"
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

    init(containerIdentifier: String) {
        self.containerIdentifier = containerIdentifier
    }

    func uploadSchedule(gemsID: String, cloudKitRecordName: String, schedules: [PayPeriodSchedule]) async throws {
        let database = CKContainer(identifier: containerIdentifier).publicCloudDatabase
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

    func requestFriend(myGEMSID: String, friendGEMSID: String) async throws -> FriendScheduleCloudKitLink {
        let my = normalizedGEMSID(myGEMSID)
        let friend = normalizedGEMSID(friendGEMSID)
        let database = CKContainer(identifier: containerIdentifier).publicCloudDatabase
        let pair = Self.orderedPair(my, friend)
        let recordID = CKRecord.ID(recordName: Self.friendLinkRecordName(first: pair.first, second: pair.second))
        let record = (try? await database.record(for: recordID))
            ?? CKRecord(recordType: RecordType.friendLink, recordID: recordID)

        record[Field.gemsA] = pair.first as CKRecordValue
        record[Field.gemsB] = pair.second as CKRecordValue
        record[approvalField(for: my, pair: pair)] = true as CKRecordValue
        record[Field.updatedAt] = Date() as CKRecordValue

        let accepted = boolValue(record[Field.approvedA]) && boolValue(record[Field.approvedB])
        if accepted && record[Field.linkedAt] == nil {
            record[Field.linkedAt] = Date() as CKRecordValue
        }

        let saved = try await database.save(record)
        return link(from: saved, myGEMSID: my, friendGEMSID: friend)
    }

    func refreshConnections(myGEMSID: String, connections: [FriendConnection]) async throws -> [FriendConnection] {
        let my = normalizedGEMSID(myGEMSID)
        let database = CKContainer(identifier: containerIdentifier).publicCloudDatabase
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

    private func fetchSchedule(gemsID: String, database: CKDatabase) async throws -> [PayPeriodSchedule] {
        let recordID = CKRecord.ID(recordName: Self.scheduleRecordName(for: gemsID))
        let record = try await database.record(for: recordID)
        guard let data = record[Field.schedulesData] as? Data else { return [] }
        return try JSONDecoder().decode([PayPeriodSchedule].self, from: data)
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

    private static func orderedPair(_ lhs: String, _ rhs: String) -> (first: String, second: String) {
        lhs < rhs ? (lhs, rhs) : (rhs, lhs)
    }

    private static func scheduleRecordName(for gemsID: String) -> String {
        "tdh_schedule_\(normalizedRecordComponent(gemsID))"
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
