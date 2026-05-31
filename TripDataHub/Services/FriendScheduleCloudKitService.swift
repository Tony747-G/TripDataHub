import CloudKit
import Foundation
import os

private let logger = Logger(subsystem: "com.sfune.TripDataHub", category: "FriendLink")

struct FriendScheduleCloudKitLink: Sendable {
    let friendGEMSID: String
    let isAccepted: Bool
    let linkedAt: Date?
    let requestedAt: Date?
}

protocol FriendScheduleCloudKitServicing: Sendable {
    func uploadSchedule(gemsID: String, cloudKitRecordName: String, schedules: [PayPeriodSchedule]) async throws
    func uploadScheduleSnapshot(gemsID: String, ownerDisplayName: String, crewAccessTrips: [CrewAccessTripJSON]) async throws
    func requestFriend(myGEMSID: String, friendGEMSID: String) async throws -> FriendScheduleCloudKitLink
    func cancelFriendRequest(myGEMSID: String, friendGEMSID: String) async throws
    func deleteSharedScheduleData(gemsID: String) async throws
    func deleteFriendSharingData(gemsID: String) async throws
    func refreshConnections(myGEMSID: String, connections: [FriendConnection]) async throws -> [FriendConnection]
}

protocol FriendScheduleCloudKitDatabase {
    func record(for recordID: CKRecord.ID) async throws -> CKRecord
    func save(_ record: CKRecord) async throws -> CKRecord
    func deleteRecord(withID recordID: CKRecord.ID) async throws -> CKRecord.ID
    func records(matching query: CKQuery) async throws -> [CKRecord]
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
        static let requestedAt = "requestedAt"
        static let status = "status"
    }

    private enum LinkStatus {
        static let pending = "pending"
        static let accepted = "accepted"
        static let canceled = "canceled"
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
        record[Field.ownerGEMSID] = GEMSIDNormalizer.normalize(gemsID) as CKRecordValue
        record[Field.ownerRecordName] = nil
        record[Field.schedulesData] = data as CKRecordValue
        record[Field.updatedAt] = Date() as CKRecordValue
        _ = try await database.save(record)
    }

    func uploadScheduleSnapshot(gemsID: String, ownerDisplayName: String, crewAccessTrips: [CrewAccessTripJSON]) async throws {
        let database = databaseProvider()
        let recordID = CKRecord.ID(recordName: Self.snapshotRecordName(for: gemsID))
        let record = (try? await database.record(for: recordID))
            ?? CKRecord(recordType: RecordType.snapshot, recordID: recordID)
        let json = try TripScheduleSnapshotEncoder.json(
            ownerDisplayName: ownerDisplayName,
            crewAccessTrips: crewAccessTrips
        )
        record[SnapshotField.ownerGEMSID] = GEMSIDNormalizer.normalize(gemsID) as CKRecordValue
        record[SnapshotField.ownerDisplayName] = ownerDisplayName as CKRecordValue
        record[SnapshotField.scheduleJSON] = json as CKRecordValue
        record[SnapshotField.schemaVersion] = Int64(TripScheduleSnapshotEncoder.schemaVersion) as CKRecordValue
        record[SnapshotField.updatedAt] = Date() as CKRecordValue
        _ = try await database.save(record)
    }

    func requestFriend(myGEMSID: String, friendGEMSID: String) async throws -> FriendScheduleCloudKitLink {
        let my = GEMSIDNormalizer.normalize(myGEMSID)
        let friend = GEMSIDNormalizer.normalize(friendGEMSID)
        let database = databaseProvider()
        let pair = Self.orderedPair(my, friend)
        let recordID = CKRecord.ID(recordName: Self.friendLinkRecordName(first: pair.first, second: pair.second))

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
            } catch let error as CKError where Self.shouldRetryFriendLinkSave(error) {
                guard attempt < 2 else { throw error }
                try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 150_000_000)
            } catch {
                throw error
            }
        }

        throw CKError(.serverRecordChanged)
    }

    func cancelFriendRequest(myGEMSID: String, friendGEMSID: String) async throws {
        let my = GEMSIDNormalizer.normalize(myGEMSID)
        let friend = GEMSIDNormalizer.normalize(friendGEMSID)
        let database = databaseProvider()
        let pair = Self.orderedPair(my, friend)
        let recordID = CKRecord.ID(recordName: Self.friendLinkRecordName(first: pair.first, second: pair.second))

        for attempt in 0..<3 {
            do {
                let record: CKRecord
                do {
                    record = try await database.record(for: recordID)
                } catch let error as CKError where error.code == .unknownItem {
                    return
                }

                record[Field.approvedA] = false as CKRecordValue
                record[Field.approvedB] = false as CKRecordValue
                record[Field.linkedAt] = nil
                record[Field.updatedAt] = Date() as CKRecordValue

                record[Field.status] = LinkStatus.canceled as CKRecordValue
                _ = try await database.save(record)
                return
            } catch let error as CKError where Self.shouldRetryFriendLinkSave(error) {
                guard attempt < 2 else { throw error }
                try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 150_000_000)
            } catch {
                throw error
            }
        }

        throw CKError(.serverRecordChanged)
    }

    func deleteSharedScheduleData(gemsID: String) async throws {
        let normalizedGEMSID = GEMSIDNormalizer.normalize(gemsID)
        let database = databaseProvider()
        try await deleteRecordIfExists(
            CKRecord.ID(recordName: Self.scheduleRecordName(for: normalizedGEMSID)),
            database: database
        )
        try await deleteRecordIfExists(
            CKRecord.ID(recordName: Self.snapshotRecordName(for: normalizedGEMSID)),
            database: database
        )
    }

    func deleteFriendSharingData(gemsID: String) async throws {
        let normalizedGEMSID = GEMSIDNormalizer.normalize(gemsID)
        let database = databaseProvider()

        async let firstSide = friendLinkRecords(field: Field.gemsA, gemsID: normalizedGEMSID, database: database)
        async let secondSide = friendLinkRecords(field: Field.gemsB, gemsID: normalizedGEMSID, database: database)
        let linkRecords = try await firstSide + secondSide
        var seenRecordNames: Set<String> = []

        for record in linkRecords where seenRecordNames.insert(record.recordID.recordName).inserted {
            record[Field.approvedA] = false as CKRecordValue
            record[Field.approvedB] = false as CKRecordValue
            record[Field.linkedAt] = nil
            record[Field.status] = LinkStatus.canceled as CKRecordValue
            record[Field.updatedAt] = Date() as CKRecordValue
            _ = try await database.save(record)
        }

        try await deleteSharedScheduleData(gemsID: normalizedGEMSID)
    }

    func refreshConnections(myGEMSID: String, connections: [FriendConnection]) async throws -> [FriendConnection] {
        let my = GEMSIDNormalizer.normalize(myGEMSID)
        let database = databaseProvider()
        let cloudConnections = try await cloudConnections(myGEMSID: my, database: database)
        let mergedConnections = mergeConnections(connections + cloudConnections)
        var refreshed = Array(repeating: FriendConnection(employeeID: "", status: .pending), count: mergedConnections.count)

        try await withThrowingTaskGroup(of: (Int, FriendConnection).self) { group in
            for (index, connection) in mergedConnections.enumerated() {
                group.addTask {
                    let updated = try await self.refreshConnection(
                        connection,
                        myGEMSID: my,
                        database: database
                    )
                    return (index, updated)
                }
            }

            for try await (index, connection) in group {
                refreshed[index] = connection
            }
        }

        return refreshed
    }

    private func cloudConnections(
        myGEMSID: String,
        database: FriendScheduleCloudKitDatabase
    ) async throws -> [FriendConnection] {
        async let firstSide = friendLinkRecords(field: Field.gemsA, gemsID: myGEMSID, database: database)
        async let secondSide = friendLinkRecords(field: Field.gemsB, gemsID: myGEMSID, database: database)
        let firstRecords = try await firstSide
        let secondRecords = try await secondSide
        let records = firstRecords + secondRecords
        var seenRecordNames: Set<String> = []
        var connections: [FriendConnection] = []

        for record in records where seenRecordNames.insert(record.recordID.recordName).inserted {
            let gemsA = GEMSIDNormalizer.normalize(record[Field.gemsA] as? String ?? "")
            let gemsB = GEMSIDNormalizer.normalize(record[Field.gemsB] as? String ?? "")
            guard gemsA == myGEMSID || gemsB == myGEMSID else { continue }
            let friend = gemsA == myGEMSID ? gemsB : gemsA
            guard !friend.isEmpty else { continue }
            let link = self.link(from: record, myGEMSID: myGEMSID, friendGEMSID: friend)
            connections.append(
                FriendConnection(
                    employeeID: friend,
                    status: link.isAccepted ? .accepted : .pending,
                    requestedAt: link.requestedAt ?? Date(),
                    linkedAt: link.isAccepted ? (link.linkedAt ?? Date()) : nil
                )
            )
        }

        return mergeConnections(connections)
    }

    private func friendLinkRecords(
        field: String,
        gemsID: String,
        database: FriendScheduleCloudKitDatabase
    ) async throws -> [CKRecord] {
        let query = CKQuery(
            recordType: RecordType.friendLink,
            predicate: NSPredicate(format: "%K == %@", field, gemsID)
        )
        return try await database.records(matching: query)
    }

    private func refreshConnection(
        _ connection: FriendConnection,
        myGEMSID: String,
        database: FriendScheduleCloudKitDatabase
    ) async throws -> FriendConnection {
        let friend = GEMSIDNormalizer.normalize(connection.employeeID)
        let pair = Self.orderedPair(myGEMSID, friend)
        let recordID = CKRecord.ID(recordName: Self.friendLinkRecordName(first: pair.first, second: pair.second))
        let record: CKRecord?
        do {
            record = try await database.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            record = nil
        } catch {
            throw error
        }
        logger.info("[TDHFriendLink] refreshConnection: friend=\(friend, privacy: .private) recordFound=\(record != nil, privacy: .public) connectionStatus=\(connection.status.rawValue, privacy: .public)")

        guard let record else {
            var fallback = connection
            if let restored = try await restoreAcceptedLinkIfPossible(
                connection,
                myGEMSID: myGEMSID,
                pair: pair,
                record: CKRecord(recordType: RecordType.friendLink, recordID: recordID),
                canCreateAcceptedRecord: true,
                database: database
            ) {
                return restored
            }
            if connection.status == .accepted {
                return connection
            }
            if connection.status == .pending {
                let migratedRecord = CKRecord(recordType: RecordType.friendLink, recordID: recordID)
                applyApproval(to: migratedRecord, myGEMSID: myGEMSID, pair: pair)
                do {
                    _ = try await database.save(migratedRecord)
                    logger.info("[TDHFriendLink] refreshConnection: re-applied local approval to pending CloudKit link")
                } catch {
                    logger.error("[TDHFriendLink] local approval re-apply failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            fallback.status = .pending
            fallback.linkedAt = nil
            fallback.sharedSchedules = []
            return fallback
        }

        do {
            try await backfillAcceptedStatusIfNeeded(record, database: database)
        } catch {
            logger.error("[TDHFriendLink] accepted-status backfill failed: \(error.localizedDescription, privacy: .public)")
        }

        let link = self.link(from: record, myGEMSID: myGEMSID, friendGEMSID: friend)
        logger.info("[TDHFriendLink] refreshConnection: link.isAccepted=\(link.isAccepted, privacy: .public) status=\(record["status"] as? String ?? "nil", privacy: .public)")
        var updated = connection
        if link.isAccepted {
            updated.status = .accepted
            updated.linkedAt = link.linkedAt ?? updated.linkedAt ?? Date()
            updated.acceptedAt = updated.acceptedAt ?? updated.linkedAt ?? Date()
            do {
                updated.sharedSchedules = try await fetchSchedule(gemsID: friend, database: database)
            } catch {
                logger.error("[TDHFriendLink] refreshConnection: fetchSchedule failed (accepted): \(error.localizedDescription, privacy: .public)")
                updated.sharedSchedules = connection.sharedSchedules
            }
        } else {
            let isExplicitlyCanceled = (record[Field.status] as? String) == LinkStatus.canceled
            if !isExplicitlyCanceled {
                if let restored = try await restoreAcceptedLinkIfPossible(
                    connection,
                    myGEMSID: myGEMSID,
                    pair: pair,
                    record: record,
                    canCreateAcceptedRecord: false,
                    database: database
                ) {
                    return restored
                }
                applyApproval(to: record, myGEMSID: myGEMSID, pair: pair)
                let healedLink: FriendScheduleCloudKitLink?
                do {
                    let saved = try await database.save(record)
                    healedLink = self.link(from: saved, myGEMSID: myGEMSID, friendGEMSID: friend)
                    logger.info("[TDHFriendLink] refreshConnection: re-apply saved, healedLink.isAccepted=\(healedLink?.isAccepted ?? false, privacy: .public)")
                } catch {
                    logger.error("[TDHFriendLink] approval re-apply failed: \(error.localizedDescription, privacy: .public)")
                    healedLink = nil
                }
                if healedLink?.isAccepted == true {
                    updated.status = .accepted
                    updated.linkedAt = healedLink?.linkedAt ?? updated.linkedAt ?? Date()
                    updated.acceptedAt = updated.acceptedAt ?? updated.linkedAt ?? Date()
                    do {
                        updated.sharedSchedules = try await fetchSchedule(gemsID: friend, database: database)
                    } catch {
                        logger.error("[TDHFriendLink] refreshConnection: fetchSchedule failed (healed): \(error.localizedDescription, privacy: .public)")
                        updated.sharedSchedules = connection.sharedSchedules
                    }
                } else {
                    updated.status = .pending
                    updated.linkedAt = nil
                    updated.acceptedAt = nil
                    updated.sharedSchedules = []
                }
            } else {
                updated.status = .pending
                updated.linkedAt = nil
                updated.acceptedAt = nil
                updated.sharedSchedules = []
            }
        }
        return updated
    }

    private func restoreAcceptedLinkIfPossible(
        _ connection: FriendConnection,
        myGEMSID: String,
        pair: (first: String, second: String),
        record: CKRecord,
        canCreateAcceptedRecord: Bool,
        database: FriendScheduleCloudKitDatabase
    ) async throws -> FriendConnection? {
        guard let acceptedAt = connection.acceptedAt ?? (connection.status == .accepted ? connection.linkedAt : nil) else {
            return nil
        }
        guard canCreateAcceptedRecord || isAccepted(record) else {
            return nil
        }
        record[Field.gemsA] = pair.first as CKRecordValue
        record[Field.gemsB] = pair.second as CKRecordValue
        record[Field.approvedA] = true as CKRecordValue
        record[Field.approvedB] = true as CKRecordValue
        record[Field.status] = LinkStatus.accepted as CKRecordValue
        record[Field.linkedAt] = acceptedAt as CKRecordValue
        if record[Field.requestedAt] == nil {
            record[Field.requestedAt] = connection.requestedAt as CKRecordValue
        }
        record[Field.updatedAt] = Date() as CKRecordValue
        let saved = try await database.save(record)
        let friend = pair.first == myGEMSID ? pair.second : pair.first
        let link = self.link(from: saved, myGEMSID: myGEMSID, friendGEMSID: friend)
        guard link.isAccepted else { return nil }
        var restored = connection
        restored.status = .accepted
        restored.linkedAt = link.linkedAt ?? acceptedAt
        restored.acceptedAt = acceptedAt
        do {
            restored.sharedSchedules = try await fetchSchedule(gemsID: friend, database: database)
        } catch {
            logger.error("[TDHFriendLink] refreshConnection: fetchSchedule failed (accepted-restore): \(error.localizedDescription, privacy: .public)")
            restored.sharedSchedules = connection.sharedSchedules
        }
        logger.info("[TDHFriendLink] restored accepted friend link from local acceptedAt proof")
        return restored
    }

    private func fetchSchedule(gemsID: String, database: FriendScheduleCloudKitDatabase) async throws -> [PayPeriodSchedule] {
        let recordID = CKRecord.ID(recordName: Self.scheduleRecordName(for: gemsID))
        logger.info("[TDHSchedule] fetchSchedule: attempting recordName=\(recordID.recordName, privacy: .private)")
        do {
            let record = try await database.record(for: recordID)
            guard let data = record[Field.schedulesData] as? Data else {
                logger.info("[TDHSchedule] fetchSchedule: record found but no schedulesData field")
                return []
            }
            let schedules = try JSONDecoder().decode([PayPeriodSchedule].self, from: data)
            logger.info("[TDHSchedule] fetchSchedule: success, \(schedules.count, privacy: .public) schedules")
            return schedules
        } catch {
            logger.error("[TDHSchedule] fetchSchedule: FAILED error=\(error.localizedDescription, privacy: .public)")
            throw error
        }
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

    private func deleteRecordIfExists(
        _ recordID: CKRecord.ID,
        database: FriendScheduleCloudKitDatabase
    ) async throws {
        do {
            _ = try await database.deleteRecord(withID: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            return
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
        let now = Date()
        if record[Field.requestedAt] == nil || (record[Field.status] as? String) == LinkStatus.canceled {
            record[Field.requestedAt] = now as CKRecordValue
        }
        record[Field.updatedAt] = now as CKRecordValue

        if isAccepted(record) {
            record[Field.status] = LinkStatus.accepted as CKRecordValue
            if record[Field.linkedAt] == nil {
                record[Field.linkedAt] = now as CKRecordValue
            }
        } else if record[Field.status] == nil || (record[Field.status] as? String) == LinkStatus.canceled {
            record[Field.status] = LinkStatus.pending as CKRecordValue
        }
    }

    private func link(from record: CKRecord, myGEMSID: String, friendGEMSID: String) -> FriendScheduleCloudKitLink {
        return FriendScheduleCloudKitLink(
            friendGEMSID: friendGEMSID,
            isAccepted: isAccepted(record),
            linkedAt: record[Field.linkedAt] as? Date,
            requestedAt: (record[Field.requestedAt] as? Date) ?? record.creationDate ?? (record[Field.updatedAt] as? Date)
        )
    }

    private func backfillAcceptedStatusIfNeeded(
        _ record: CKRecord,
        database: FriendScheduleCloudKitDatabase
    ) async throws {
        guard isAccepted(record) else { return }
        var needsSave = false
        if (record[Field.status] as? String) != LinkStatus.accepted {
            record[Field.status] = LinkStatus.accepted as CKRecordValue
            needsSave = true
        }
        if record[Field.linkedAt] == nil {
            record[Field.linkedAt] = Date() as CKRecordValue
            needsSave = true
        }
        if needsSave {
            record[Field.updatedAt] = Date() as CKRecordValue
            _ = try await database.save(record)
        }
    }

    private func isAccepted(_ record: CKRecord) -> Bool {
        if (record[Field.status] as? String) == LinkStatus.canceled {
            return false
        }
        if (record[Field.status] as? String) == LinkStatus.accepted {
            return true
        }
        if record[Field.linkedAt] != nil {
            return true
        }
        return boolValue(record[Field.approvedA]) && boolValue(record[Field.approvedB])
    }

    private func mergeConnections(_ connections: [FriendConnection]) -> [FriendConnection] {
        var merged: [FriendConnection] = []
        for connection in connections {
            let employeeID = GEMSIDNormalizer.normalize(connection.employeeID)
            guard !employeeID.isEmpty else { continue }
            let normalized = FriendConnection(
                id: connection.id,
                employeeID: employeeID,
                nickname: connection.nickname,
                avatarImageData: connection.avatarImageData,
                status: connection.status,
                requestedAt: connection.requestedAt,
                linkedAt: connection.linkedAt,
                acceptedAt: connection.acceptedAt,
                sharedSchedules: connection.sharedSchedules,
                sharedTimelineCards: connection.sharedTimelineCards
            )
            if let index = merged.firstIndex(where: { $0.employeeID == employeeID }) {
                merged[index] = mergedConnection(merged[index], normalized)
            } else {
                merged.append(normalized)
            }
        }
        return merged
    }

    private func mergedConnection(_ lhs: FriendConnection, _ rhs: FriendConnection) -> FriendConnection {
        let accepted = lhs.status == .accepted || rhs.status == .accepted
        let acceptedAt = lhs.acceptedAt ?? rhs.acceptedAt
        return FriendConnection(
            id: lhs.id,
            employeeID: lhs.employeeID,
            nickname: lhs.nickname ?? rhs.nickname,
            avatarImageData: lhs.avatarImageData ?? rhs.avatarImageData,
            status: (accepted || acceptedAt != nil) ? .accepted : .pending,
            requestedAt: min(lhs.requestedAt, rhs.requestedAt),
            linkedAt: lhs.linkedAt ?? rhs.linkedAt,
            acceptedAt: acceptedAt,
            sharedSchedules: lhs.sharedSchedules.isEmpty ? rhs.sharedSchedules : lhs.sharedSchedules,
            sharedTimelineCards: lhs.sharedTimelineCards.isEmpty ? rhs.sharedTimelineCards : lhs.sharedTimelineCards
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
        GEMSIDNormalizer.normalize(raw)
            .filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }
}
